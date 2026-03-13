//! Test module - imports all modules to verify compilation

// Core modules
const runtime = @import("core/runtime.zig");

// Agent modules
const agent_mod = @import("agent/mod.zig");
const planner = @import("agent/planner.zig");

// Tool modules
const registry = @import("tools/registry.zig");

// Channel modules
const repl = @import("channel/repl.zig");

// Root module (public API)
const omniclaw = @import("omniclaw.zig");

// Main entry point
const main = @import("main.zig");

// Re-export all for testing
pub const Runtime = runtime.Runtime;
pub const Config = runtime.Config;
pub const Agent = agent_mod.Agent;
pub const Planner = planner.Planner;
pub const Plan = planner.Plan;
pub const ToolRegistry = registry.ToolRegistry;
pub const Tool = registry.Tool;
pub const ToolExecutor = registry.ToolExecutor;

// Test that all modules compile
test {
    _ = runtime;
    _ = agent_mod;
    _ = planner;
    _ = registry;
    _ = repl;
    _ = omniclaw;
    _ = main;
}
