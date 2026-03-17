//! Omni-Claw Root Module
//!
//! This is the public API for the Omni-Claw agent runtime.
//! Import this module to access all public types and functions.

const std = @import("std");

// Public API exports
pub const Runtime = @import("core/runtime.zig").Runtime;
pub const Config = @import("core/runtime.zig").Config;

pub const Agent = @import("agent/mod.zig").Agent;
pub const Planner = @import("agent/planner.zig").Planner;
pub const Plan = @import("agent/planner.zig").Plan;

pub const Repl = @import("channel/repl.zig");

// Tools registry
pub const tools = struct {
    pub const Registry = @import("tools/registry.zig").ToolRegistry;
    pub const Tool = @import("tools/registry.zig").Tool;
    pub const ToolExecutor = @import("tools/registry.zig").ToolExecutor;
    pub const createDefaultRegistry = @import("tools/registry.zig").createDefaultRegistry;
};

/// Version of the Omni-Claw runtime
pub const VERSION = "0.15.2";

/// Initialize the runtime with default settings
pub fn initRuntime(allocator: std.mem.Allocator) !Runtime {
    return Runtime.init(allocator, 10);
}

/// Initialize the runtime with custom max_iterations
pub fn initRuntimeWithMaxIterations(allocator: std.mem.Allocator, max_iterations: usize) !Runtime {
    return Runtime.init(allocator, max_iterations);
}
