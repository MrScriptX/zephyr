pub const model = @import("model.zig");
pub const registry = @import("registry.zig");
pub const emit = @import("emit.zig");

test {
    // `zig test` only collects tests from files the root module actually
    // references, so the submodules have to be pulled in explicitly --
    // without this the parser and emitter tests silently never run.
    _ = model;
    _ = registry;
    _ = emit;
}
