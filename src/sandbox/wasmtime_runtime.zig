const std = @import("std");

pub fn run(module: []const u8, argument: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const manifest_path = try std.fmt.allocPrint(allocator, "plugins/{s}/manifest.json", .{module});
    const manifest_data = try std.fs.cwd().readFileAlloc(allocator, manifest_path, 64 * 1024);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, manifest_data, .{});
    defer parsed.deinit();

    const obj = parsed.value.object;
    const wasm_name_val = obj.get("wasm") orelse return error.InvalidManifest;
    if (wasm_name_val != .string) return error.InvalidManifest;

    const wasm_path = try std.fmt.allocPrint(allocator, "plugins/{s}/{s}", .{ module, wasm_name_val.string });
    _ = try std.fs.cwd().statFile(wasm_path);

    var child = std.process.Child.init(
        &.{ "wasmtime", wasm_path, argument },
        allocator,
    );
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Inherit;
    child.stderr_behavior = .Inherit;

    const term = child.spawnAndWait() catch |err| switch (err) {
        error.FileNotFound => return error.WasmtimeNotInstalled,
        else => return err,
    };

    switch (term) {
        .Exited => |code| if (code != 0) return error.ToolExecutionFailed,
        else => return error.ToolExecutionFailed,
    }
}
