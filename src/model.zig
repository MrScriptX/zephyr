const std = @import("std");

/// A resolved reference to a type used as a struct/union member or a command parameter.
pub const TypeRef = struct {
    /// The C base type name, e.g. "VkInstance", "uint32_t", "void", "char".
    base: []const u8,
    /// Number of `*` indirections (0 = value, 1 = pointer, 2 = pointer-to-pointer).
    pointer_depth: u2 = 0,
    /// Whether the pointee (or the value itself, for depth 0) was declared `const`.
    is_const: bool = false,
    /// Whether the vk.xml attribute `optional="true"` was present.
    is_optional: bool = false,
    /// Fixed-size C array length, e.g. "4" or the symbolic name "VK_UUID_SIZE" (resolved
    /// against `Registry.constants` at emit time). Null if this is not an array member.
    array_len: ?[]const u8 = null,
};

pub const Member = struct {
    name: []const u8,
    type: TypeRef,
};

pub const EnumValue = struct {
    name: []const u8,
    value: i64,

    pub fn deinit(self: *EnumValue, gpa: std.mem.Allocator) void {
        gpa.free(self.name);
    }
};

pub const Handle = struct {
    name: []const u8,
    dispatchable: bool,

    pub fn deinit(self: *Handle, gpa: std.mem.Allocator) void {
        gpa.free(self.name);
    }
};

pub const EnumType = struct {
    name: []const u8,
    is_bitmask: bool,
    bit_width: u8, // 32 or 64
    values: []EnumValue,

    pub fn deinit(self: *EnumType, gpa: std.mem.Allocator) void {
        gpa.free(self.name);
        for (self.values) |value| {
            value.deinit(gpa);
        }
    }
};

pub const AggType = struct {
    name: []const u8,
    is_union: bool,
    members: []Member,
};

pub const CommandLevel = enum { global, instance, device };

pub const Command = struct {
    c_name: []const u8,
    return_type: []const u8, // "void" or a Vk*/base type name
    params: []Member,
    /// True if required unconditionally by <feature name="VK_VERSION_1_0"> --
    /// guaranteed present on every conformant Vulkan 1.0+ driver, so it's
    /// safe to bind statically. False means "gated": only introduced by a
    /// later core version or by an extension, and must be resolved
    /// dynamically (see emit.zig's writeCommands).
    is_baseline: bool = true,
    /// Which PFN loader (vkGetInstanceProcAddr vs vkGetDeviceProcAddr, or
    /// neither) resolves this command, derived from its first parameter's
    /// handle type. Only consulted for gated commands.
    level: CommandLevel = .global,
    /// Human-readable "what introduced this" label (e.g. "Vulkan 1.4" or
    /// "VK_KHR_maintenance6"), baked into the gated wrapper's log message.
    /// Empty string for baseline commands.
    origin: []const u8 = "",
};

pub const Registry = struct {
    arena: std.heap.ArenaAllocator,
    /// Name -> value, from `<enums type="constants">` (the "API Constants"
    /// block). Insertion-ordered so the emitted constants keep the registry's
    /// own order rather than a hash order that shifts between runs.
    constants: std.StringArrayHashMapUnmanaged(Value) = .empty,
    /// Name -> underlying primitive Zig type, from `<type category="basetype">`.
    basetypes: std.StringHashMapUnmanaged([]const u8) = .empty,
    handles: []Handle = &.{},
    enums: []EnumType = &.{},
    aggregates: []AggType = &.{},
    commands: []Command = &.{},

    pub fn deinit(self: *Registry, gpa: std.mem.Allocator) void {
        for (self.handles) |*h| {
            h.deinit(gpa);
        }
        self.arena.deinit();
    }
};

/// One "API Constants" entry, typed by vk.xml's `type` attribute. The
/// distinction matters: the previous integer-only representation silently
/// dropped every `type="float"` constant (VK_LOD_CLAMP_NONE and friends)
/// because they don't fit an i64.
pub const Value = union(enum) {
    uint32: u32,
    uint64: u64,
    float: f32,
    /// A value with no `type` attribute, or a negative one.
    int: i64,
};
