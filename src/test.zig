const std = @import("std");
const argparser = @import("argparser.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const Parser = argparser.init(struct {
        smol: u8 = 1,
        str: []const u8 = "",
        beeg: u32,

        pub const description = "This is an example for testing";
    });

    const result = Parser.parseOrExit(
        gpa.allocator(),
        .{ .exit_code = if (@import("builtin").mode == .Debug) 0 else 1 },
    );
    defer result.deinit();

    std.log.info("result: {s}", .{result.args});
}
