const std = @import("std");
const omniclaw = @import("omniclaw.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    const max_iterations: usize = 1000;

    var runtime = try omniclaw.Runtime.init(allocator, max_iterations);
    defer runtime.deinit();

    try runtime.start();
}
