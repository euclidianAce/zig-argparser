const std = @import("std");

const TypeInfo = std.builtin.TypeInfo;
const mem = std.mem;
const meta = std.meta;
const process = std.process;

pub const ExitOptions = struct {
    exit_code: u8 = 1,
    log_error: bool = true,
    log_usage: bool = true,
};

pub const Error = error{ MissingArg, DuplicateOption, Parse, Overflow, MissingOption } ||
    process.ArgIterator.NextError ||
    mem.Allocator.Error;

pub fn init(comptime Opts: type) type {
    const opts_info = comptime b: {
        const i = @typeInfo(Opts);
        if (i != .Struct)
            @compileError("Expected a struct");
        break :b i.Struct;
    };

    const OptionFlags = comptime b: {
        var flag_fields: [opts_info.fields.len]TypeInfo.StructField = undefined;
        inline for (opts_info.fields) |field, i| {
            flag_fields[i] = .{
                .name = field.name,
                .field_type = bool,
                .default_value = false,
                .is_comptime = false,
                .alignment = @alignOf(bool),
            };
        }

        break :b @Type(.{ .Struct = .{
            .layout = .Auto,
            .fields = &flag_fields,
            .decls = &[_]TypeInfo.Declaration{},
            .is_tuple = false,
        } });
    };

    const longest_name = comptime b: {
        var longest: usize = 0;
        inline for (opts_info.fields) |field| {
            if (field.name.len > longest)
                longest = field.name.len;
        }
        break :b longest + 1;
    };

    return struct {
        pub const Parsed = struct {
            opts: Opts,
            allocator: mem.Allocator,

            args: []const [:0]u8,
            pub fn deinit(self: *const @This()) void {
                process.argsFree(self.allocator, self.args);
            }
        };

        var err_data: struct {
            err: ?Error = null,
            buf: [longest_name]u8 = [_]u8{0} ** longest_name,
            buf_len: usize = 0, // written length
        } = .{};

        inline fn getErrData() [:0]const u8 {
            return err_data.buf[0..err_data.buf_len :0];
        }

        const State = struct {
            args: []const [:0]u8,
            opts: Opts,
            opts_set: OptionFlags,
            allocator: mem.Allocator,

            pub fn init(allocator: mem.Allocator) !@This() {
                return @This(){
                    .allocator = allocator,
                    .args = try process.argsAlloc(allocator),
                    .opts = b: {
                        var o: Opts = undefined;
                        inline for (opts_info.fields) |field| {
                            const field_info = @typeInfo(field.field_type);
                            if (field.default_value) |val| {
                                @field(o, field.name) = val;
                            } else if (field_info == .Optional) {
                                @field(o, field.name) = null;
                            } else {
                                @field(o, field.name) = undefined;
                            }
                        }
                        break :b o;
                    },
                    .opts_set = .{},
                };
            }

            pub fn deinit(self: *const @This()) void {
                process.argsFree(self.allocator, self.args);
            }

            pub fn err(comptime e: Error, comptime name: []const u8) Error {
                mem.copy(u8, &err_data.buf, name);
                err_data.buf_len = name.len;
                err_data.err = e;
                return e;
            }

            pub fn ok(self: *@This()) Parsed {
                return .{ .opts = self.opts, .args = self.args, .allocator = self.allocator };
            }
        };

        pub fn parse(allocator: mem.Allocator) Error!Parsed {
            var state = try State.init(allocator);
            errdefer state.deinit();

            var i: usize = 0;
            while (i < state.args.len) : (i += 1) {
                const arg = state.args[i];
                inline for (opts_info.fields) |field, j| {
                    if (arg.len > 2 and mem.eql(u8, arg[0..2], "--")) {
                        if (mem.eql(u8, arg[2..], field.name)) {
                            i += 1;

                            std.log.debug("1: {} {} GOT FIELD {s}", .{ j, i, field.name });

                            if (i >= state.args.len) {
                                std.log.debug("returning...", .{});
                                return State.err(Error.MissingArg, field.name);
                            }

                            std.log.debug("2: {} {} GOT FIELD {s}", .{ j, i, field.name });

                            const is_duplicate = @field(state.opts_set, field.name);
                            if (is_duplicate) {
                                std.log.debug("returning...", .{});
                                return State.err(Error.DuplicateOption, field.name);
                            }

                            std.log.debug("3: {} {} GOT FIELD {s}", .{ j, i, field.name });

                            const value = parseOption(
                                DiscardOptional(field.field_type),
                                state.args[i],
                            ) catch return State.err(Error.Parse, field.name);

                            @field(state.opts, field.name) = value;
                            std.log.debug("4: {} {} GOT FIELD {s}", .{ j, i, field.name });

                            @field(state.opts_set, field.name) = true;

                            std.log.debug("5: {} {} GOT FIELD {s}", .{ j, i, field.name });
                        }
                    }
                }
            }

            inline for (opts_info.fields) |field| {
                const field_info = @typeInfo(field.field_type);
                if ((field.default_value == null) and (field_info != .Optional)) {
                    if (!@field(state.opts_set, field.name))
                        return State.err(Error.MissingOption, field.name);
                }
            }

            return state.ok();
        }

        pub fn parseOrExit(allocator: mem.Allocator, exit_opts: ExitOptions) Parsed {
            return parse(allocator) catch {
                if (exit_opts.log_usage) {
                    const writer = std.io.getStdErr().writer();
                    printUsage(writer) catch {};
                    writer.print("\n", .{}) catch {};
                }
                if (exit_opts.log_error) {
                    logError();
                }
                std.process.exit(exit_opts.exit_code);
            };
        }

        pub fn logError() void {
            std.debug.assert(err_data.err != null);
            switch (err_data.err.?) {
                Error.OutOfMemory => std.log.err("Out Of Memory", .{}),
                Error.InvalidCmdLine => std.log.err("Invalid Command Line", .{}),
                Error.Overflow => std.log.err("Integer Overflow", .{}),

                Error.MissingOption => std.log.err("Missing Required Option '{s}'", .{getErrData()}),
                Error.MissingArg => std.log.err("Missing Argument For Option '{s}'", .{getErrData()}),
                Error.DuplicateOption => std.log.err("Duplicate Option '{s}'", .{getErrData()}),
                Error.Parse => std.log.err("Parsing Argument For Option '{s}'", .{getErrData()}),
            }
        }

        pub fn printUsage(writer: anytype) !void {
            try writer.print("Usage: (TODO :D)\n", .{});

            if (@hasDecl(Opts, "description")) {
                if (comptime meta.trait.isZigString(@TypeOf(Opts.description))) {
                    try writer.print("Description: {s}\n", .{Opts.description});
                } else {
                    @compileError("expected a zig string for `description`");
                }
            }

            if (opts_info.fields.len > 0) {
                try writer.print("Options:\n", .{});
                inline for (opts_info.fields) |f| {
                    try writer.print("    --" ++ f.name ++ " ", .{});
                    const T = if (@typeInfo(f.field_type) == .Optional or f.default_value != null) b: {
                        try writer.print("Optional", .{});
                        break :b DiscardOptional(f.field_type);
                    } else b: {
                        try writer.print("Required", .{});
                        break :b f.field_type;
                    };

                    try writer.print(" <", .{});
                    if (comptime meta.trait.isZigString(T)) {
                        try writer.print("String", .{});
                    } else {
                        switch (@typeInfo(T)) {
                            .Int => try writer.print("Integer [{},{}]", .{ std.math.minInt(T), std.math.maxInt(T) }),
                            .Enum => |e| {
                                try writer.print("One of [", .{});
                                inline for (e.fields) |field, i| {
                                    if (i > 0)
                                        try writer.print(", ", .{});
                                    try writer.print(field.name, .{});
                                }
                                try writer.print("]", .{});
                            },
                            else => @compileError(comptime std.fmt.comptimePrint("unhandled type in printUsage: {}", .{T})),
                        }
                    }
                    try writer.print(">", .{});

                    if (f.default_value) |val| {
                        const spec = if (comptime meta.trait.isZigString(@TypeOf(val)))
                            "{s}"
                        else
                            "{}";
                        try writer.print(" (default=" ++ spec ++ ")", .{val});
                    }

                    try writer.print("\n", .{});
                }
            }
        }
    };
}

fn DiscardOptional(comptime T: type) type {
    return switch (@typeInfo(T)) {
        .Optional => |o| o.child,
        else => T,
    };
}

fn parseOption(comptime T: type, opt: []const u8) !T {
    if (comptime T == []const u8) {
        return opt;
    }

    const info = @typeInfo(T);
    switch (info) {
        .Optional => @compileError("unreachable?"),
        .Int => return if (info.Int.signedness == .signed)
            std.fmt.parseInt(T, opt, 10)
        else
            std.fmt.parseUnsigned(T, opt, 10),
        .Enum => {
            inline for (info.Enum.fields) |f| {
                if (mem.eql(u8, opt, comptime f.name)) {
                    return @intToEnum(T, f.value);
                }
            }
            return error.Parse;
        },
        else => @compileError(comptime std.fmt.comptimePrint("Unsupported type: {}", .{T})),
    }
}
