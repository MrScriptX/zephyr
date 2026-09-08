const std = @import("std");
const model = @import("model.zig");
const registry = @import("registry.zig");

/// The set of every top-level Zig type name this generator will emit
/// (handles ∪ enums/bitmasks ∪ structs/unions), used to decide whether a
/// member/param base type resolves to a named generated type.
const Universe = struct {
    known_types: std.StringHashMapUnmanaged(void) = .empty,

    /// `dropped` excludes aggregates already determined unrepresentable
    /// (directly, or because they embed -- by value -- another dropped
    /// aggregate) so that anything referencing one of them by value is
    /// correctly treated as unresolvable too, rather than pointing at a
    /// type that was never actually emitted. See `computeDroppedAggregates`.
    fn build(gpa: std.mem.Allocator, reg: *const model.Registry, dropped: *const std.StringHashMapUnmanaged(void)) !Universe {
        var u = Universe{};
        for (reg.handles) |h| try u.known_types.put(gpa, h.name, {});
        for (reg.enums) |e| try u.known_types.put(gpa, e.name, {});
        for (reg.aggregates) |a| {
            if (dropped.contains(a.name)) continue;
            try u.known_types.put(gpa, a.name, {});
        }
        return u;
    }
};

/// Struct/union members can embed another struct/union BY VALUE (not just
/// by pointer), so dropping one aggregate (unrepresentable member) can
/// cascade: anything embedding it by value becomes unrepresentable too.
/// Iterates to a fixpoint so every such cascade is caught -- without this,
/// a dropped-but-still-"known" aggregate name would let some other struct
/// resolve a member against a type that is never actually emitted, which
/// is a straight compile error in the generated file, not a graceful skip.
fn computeDroppedAggregates(gpa: std.mem.Allocator, reg: *const model.Registry) !std.StringHashMapUnmanaged(void) {
    var dropped: std.StringHashMapUnmanaged(void) = .empty;
    var round: usize = 0;
    while (round < 64) : (round += 1) {
        const universe = try Universe.build(gpa, reg, &dropped);
        var scratch: std.ArrayList(u8) = .empty;
        defer scratch.deinit(gpa);
        var changed = false;
        for (reg.aggregates) |agg| {
            if (dropped.contains(agg.name)) continue;
            var ok = true;
            for (agg.members) |m| {
                scratch.clearRetainingCapacity();
                if (!try writeFieldType(&scratch, gpa, reg, &universe, m.type)) {
                    ok = false;
                    break;
                }
            }
            if (!ok) {
                try dropped.put(gpa, agg.name, {});
                changed = true;
            }
        }
        if (!changed) break;
    } else {
        std.log.warn("vk_generator: aggregate drop cascade did not converge after 64 rounds", .{});
    }
    return dropped;
}

const BaseKind = union(enum) {
    primitive: []const u8,
    named: []const u8,
    void_type,
    funcptr,
    unknown,
};

fn classifyBase(gpa: std.mem.Allocator, reg: *const model.Registry, universe: *const Universe, base: []const u8) BaseKind {
    if (std.mem.eql(u8, base, "void")) return .void_type;
    if (std.mem.startsWith(u8, base, "PFN_")) return .funcptr;
    if (registryMapPrimitive(base)) |zig_text| return .{ .primitive = zig_text };
    if (reg.basetypes.get(base)) |zig_text| return .{ .primitive = zig_text };
    if (universe.known_types.contains(base)) return .{ .named = registry.zigTypeName(base) };
    // Some members/params are typed directly as a *FlagBits* enum (a single
    // flag value, e.g. `VkImageCreateInfo.samples: VkSampleCountFlagBits`)
    // rather than the `*Flags` bitmask typedef -- the generated bitmask
    // type is stored under the Flags name, so retry against
    // "FlagBits"->"Flags" (vendor suffix and any trailing "2" are
    // preserved, e.g. "VkSurfaceTransformFlagBitsKHR" -> "...FlagsKHR").
    if (std.mem.indexOf(u8, base, "FlagBits")) |idx| {
        const candidate = std.fmt.allocPrint(gpa, "{s}Flags{s}", .{ base[0..idx], base[idx + "FlagBits".len ..] }) catch return .unknown;
        if (universe.known_types.contains(candidate)) return .{ .named = registry.zigTypeName(candidate) };
    }
    return .unknown;
}

/// Mirrors registry.zig's internal primitive table for the (rarer) case
/// where a member/param uses the raw C primitive directly rather than
/// through one of vk.xml's `<type category="basetype">` typedefs.
fn registryMapPrimitive(c_name: []const u8) ?[]const u8 {
    const table = [_]struct { c: []const u8, zig: []const u8 }{
        .{ .c = "char", .zig = "u8" },
        .{ .c = "float", .zig = "f32" },
        .{ .c = "double", .zig = "f64" },
        .{ .c = "int8_t", .zig = "i8" },
        .{ .c = "uint8_t", .zig = "u8" },
        .{ .c = "int16_t", .zig = "i16" },
        .{ .c = "uint16_t", .zig = "u16" },
        .{ .c = "int32_t", .zig = "i32" },
        .{ .c = "uint32_t", .zig = "u32" },
        .{ .c = "int64_t", .zig = "i64" },
        .{ .c = "uint64_t", .zig = "u64" },
        .{ .c = "size_t", .zig = "usize" },
        .{ .c = "int", .zig = "c_int" },
    };
    for (table) |entry| {
        if (std.mem.eql(u8, entry.c, c_name)) return entry.zig;
    }
    return null;
}

fn resolveArrayLen(reg: *const model.Registry, raw: []const u8) ?i64 {
    if (std.fmt.parseInt(i64, raw, 10)) |v| return v else |_| {}
    // Symbolic lengths always name an integer constant; a float one would be
    // a malformed registry rather than something to round.
    return switch (reg.constants.get(raw) orelse return null) {
        .uint32 => |v| @intCast(v),
        .uint64 => |v| std.math.cast(i64, v),
        .int => |v| v,
        .float => null,
    };
}

/// Renders one member/param's Zig field type into `w`. Returns `false`
/// (without partially writing anything usable) when the type can't be
/// represented at all -- the only case where the caller must drop the
/// *entire* containing struct/command rather than just this field, since an
/// `extern struct` can't skip a field without corrupting the ABI layout of
/// every field after it.
fn writeFieldType(w: *std.ArrayList(u8), gpa: std.mem.Allocator, reg: *const model.Registry, universe: *const Universe, t: model.TypeRef) !bool {
    const kind = classifyBase(gpa, reg, universe, t.base);

    if (kind == .funcptr) {
        try w.appendSlice(gpa, "?*const anyopaque");
        return true;
    }

    if (t.array_len) |raw_len| {
        const len = resolveArrayLen(reg, raw_len) orelse return false;
        const elem = switch (kind) {
            .primitive => |p| p,
            .named => |n| n,
            .void_type, .funcptr, .unknown => return false, // arrays of opaque/void elements never occur in practice
        };
        try w.print(gpa, "[{d}]{s}", .{ len, elem });
        return true;
    }

    if (t.pointer_depth == 0) {
        return switch (kind) {
            .primitive => |p| blk: {
                try w.appendSlice(gpa, p);
                break :blk true;
            },
            .named => |n| blk: {
                try w.appendSlice(gpa, n);
                break :blk true;
            },
            .void_type, .funcptr, .unknown => false,
        };
    }

    const elem: []const u8 = switch (kind) {
        .primitive => |p| p,
        .named => |n| n,
        .void_type, .funcptr, .unknown => "anyopaque", // pointer to an unresolved/opaque type is still ABI-safe
    };

    // Pointers are rendered as C pointers (`[*c]T`), exactly like
    // addTranslateC's own output, rather than native Zig `?[*]`/`?*`
    // pointers: `[*c]` is what lets call sites keep writing `&some_var`,
    // `slice.ptr`, a bare string literal, or `null` interchangeably without
    // an explicit cast at every single pointer field -- the same ergonomics
    // the pre-existing `c.VkXxx` struct literals throughout this codebase
    // already rely on. The one exception is a pointer to an unresolved
    // type (rendered as `anyopaque`): `[*c]anyopaque`, like `[*]anyopaque`,
    // is illegal in Zig (a C-pointer's pointee must still be sized), so
    // that case keeps the single-item optional pointer form instead (which
    // is also the semantically correct shape for e.g. `pNext`).
    const is_opaque_elem = std.mem.eql(u8, elem, "anyopaque");

    if (t.pointer_depth == 1) {
        if (is_opaque_elem) {
            try w.appendSlice(gpa, if (t.is_const) "?*const anyopaque" else "?*anyopaque");
        } else {
            try w.print(gpa, "[*c]{s}{s}", .{ if (t.is_const) "const " else "", elem });
        }
        return true;
    }

    // pointer_depth >= 2, generic fallback (constness of the outer pointer
    // is assumed to match the inner one -- vk.xml's occasional finer-grained
    // multi-level constness, e.g. `const char* const*`, collapses to this).
    if (is_opaque_elem) {
        try w.appendSlice(gpa, if (t.is_const) "?*const anyopaque" else "?*anyopaque");
    } else {
        try w.print(gpa, "[*c]{s}[*c]{s}{s}", .{ if (t.is_const) "const " else "", if (t.is_const) "const " else "", elem });
    }
    return true;
}

fn writeReturnType(w: *std.ArrayList(u8), gpa: std.mem.Allocator, reg: *const model.Registry, universe: *const Universe, return_type: []const u8) !bool {
    if (std.mem.eql(u8, return_type, "void")) {
        try w.appendSlice(gpa, "void");
        return true;
    }
    const kind = classifyBase(gpa, reg, universe, return_type);
    return switch (kind) {
        .primitive => |p| blk: {
            try w.appendSlice(gpa, p);
            break :blk true;
        },
        .named => |n| blk: {
            try w.appendSlice(gpa, n);
            break :blk true;
        },
        .void_type, .funcptr, .unknown => false,
    };
}

const Seen = struct {
    map: std.StringHashMapUnmanaged(void) = .empty,

    fn reserve(self: *Seen, gpa: std.mem.Allocator, name: []const u8) !void {
        const owned_name = try gpa.dupe(u8, name);
        errdefer gpa.free(owned_name);

        try self.map.put(gpa, owned_name, {});
    }

    fn tryReserve(self: *Seen, gpa: std.mem.Allocator, name: []const u8) !bool {
        if (self.map.contains(name))
            return false;
        
        const owned_name = try gpa.dupe(u8, name);
        errdefer gpa.free(owned_name);

        try self.map.put(gpa, owned_name, {});
        return true;
    }

    fn deinit(self: *Seen, gpa: std.mem.Allocator) void {
        var it = self.map.iterator();

        while (it.next()) |entry| {
            gpa.free(entry.key_ptr.*);
        }

        self.map.deinit(gpa);
    }
};

pub fn write(gpa: std.mem.Allocator, reg: *const model.Registry, out: *std.ArrayList(u8)) !void {
    const dropped = try computeDroppedAggregates(gpa, reg);
    const universe = try Universe.build(gpa, reg, &dropped);
   
    var seen = Seen{};
    defer seen.deinit(gpa);

    try seen.reserve(gpa, "Error");
    try seen.reserve(gpa, "check_result");

    try writeHandles(gpa, out, reg, &seen);
    try writeEnums(gpa, out, reg, &seen);
    try writeAggregates(gpa, out, reg, &universe, &seen);
    try writeCommands(gpa, out, reg, &universe, &seen);
    // Last, so that a constant whose stripped name collides with a type never
    // displaces the type -- types are what the rest of the codebase names.
    try writeConstants(gpa, out, reg, &seen);
}

/// The `<enums type="constants">` block: `VK_UUID_SIZE` and friends. These are
/// emitted with their declared C type, so the float constants
/// (VK_LOD_CLAMP_NONE, the VK_COMPUTE_OCCUPANCY_PRIORITY_*_NV set) come
/// through as `f32` rather than being dropped for not fitting an integer.
fn writeConstants(gpa: std.mem.Allocator, out: *std.ArrayList(u8), reg: *const model.Registry, seen: *Seen) !void {
    var it = reg.constants.iterator();
    while (it.next()) |entry| {
        const name = registry.zigConstantName(entry.key_ptr.*);
        if (!try seen.tryReserve(gpa, name)) {
            std.log.warn("vk_generator: skipping constant '{s}' (name already taken)", .{name});
            continue;
        }
        switch (entry.value_ptr.*) {
            .uint32 => |v| try out.print(gpa, "pub const {s}: u32 = {d};\n", .{ name, v }),
            .uint64 => |v| try out.print(gpa, "pub const {s}: u64 = {d};\n", .{ name, v }),
            .int => |v| try out.print(gpa, "pub const {s}: i64 = {d};\n", .{ name, v }),
            .float => |v| try out.print(gpa, "pub const {s}: f32 = {d};\n", .{ name, v }),
        }
    }
    try out.appendSlice(gpa, "\n");
}

fn writeHandles(gpa: std.mem.Allocator, out: *std.ArrayList(u8), reg: *const model.Registry, seen: *Seen) !void {
    for (reg.handles) |h| {
        const name = registry.zigTypeName(h.name);
        if (!try seen.tryReserve(gpa, name)) {
            std.log.warn("vk_generator: skipping duplicate handle '{s}'", .{name});
            continue;
        }
        const backing: []const u8 = if (h.dispatchable) "usize" else "u64";
        try out.print(gpa, "pub const {s} = enum({s}) {{ null_handle = 0, _ }};\n", .{ name, backing });
    }
    try out.appendSlice(gpa, "\n");
}

fn writeEnums(gpa: std.mem.Allocator, out: *std.ArrayList(u8), reg: *const model.Registry, seen: *Seen) !void {
    for (reg.enums) |e| {
        // "Result" is hand-written in preamble.vk.zig on top of the raw
        // extern-fn return codes; the enum itself is still generated here
        // under its normal name so check_result has real values to switch
        // on, matching vk.xml's VkResult exactly.
        const name = registry.zigTypeName(e.name);
        if (!try seen.tryReserve(gpa, name)) {
            std.log.warn("vk_generator: skipping duplicate enum/bitmask '{s}'", .{name});
            continue;
        }

        if (e.is_bitmask) {
            try writeBitmask(gpa, out, name, e);
        } else {
            try writePlainEnum(gpa, out, name, e);
        }
    }
    try out.appendSlice(gpa, "\n");
}

fn writePlainEnum(gpa: std.mem.Allocator, out: *std.ArrayList(u8), name: []const u8, e: model.EnumType) !void {
    try out.print(gpa, "pub const {s} = enum(i32) {{\n", .{name});
    var member_names: std.StringHashMapUnmanaged(void) = .empty;
    defer member_names.deinit(gpa);
    var prefix_buf: [256]u8 = undefined;
    const prefix = memberPrefix(&prefix_buf, name);
    for (e.values) |v| {
        const field = enumFieldName(gpa, name, prefix, v.name);
        if (member_names.contains(field)) continue; // distinct C names occasionally collapse to the same field
        try member_names.put(gpa, field, {});
        try out.print(gpa, "    {s} = {d},\n", .{ field, v.value });
    }
    try out.appendSlice(gpa, "    _,\n};\n");
}

fn writeBitmask(gpa: std.mem.Allocator, out: *std.ArrayList(u8), name: []const u8, e: model.EnumType) !void {
    try out.print(gpa, "pub const {s} = packed struct({s}) {{\n", .{ name, if (e.bit_width == 64) "u64" else "u32" });
    var member_names: std.StringHashMapUnmanaged(void) = .empty;
    defer member_names.deinit(gpa);

    // Bitmask values are declared via `bitpos` (see registry.zig), so every
    // value here is a power of two; emit one `bool` field per known bit,
    // in ascending bit-position order, padding the gaps with reserved bits
    // so the struct stays exactly `bit_width` bits wide.
    var by_bit: std.AutoHashMapUnmanaged(u7, []const u8) = .empty;
    defer by_bit.deinit(gpa);
    var prefix_buf: [256]u8 = undefined;
    const prefix = memberPrefix(&prefix_buf, name);
    for (e.values) |v| {
        if (v.value <= 0) continue;
        const bitpos = std.math.log2_int(u64, @bitCast(v.value));
        if (@as(u64, 1) << bitpos != @as(u64, @bitCast(v.value))) continue; // not a single-bit value; skip
        const field = enumFieldName(gpa, name, prefix, v.name);
        if (member_names.contains(field)) continue;
        try member_names.put(gpa, field, {});
        try by_bit.put(gpa, @intCast(bitpos), field);
    }

    var bit: u7 = 0;
    var reserved_run: u32 = 0;
    while (bit < e.bit_width) : (bit += 1) {
        if (by_bit.get(bit)) |field| {
            if (reserved_run > 0) {
                try out.print(gpa, "    _reserved{d}: u{d} = 0,\n", .{ bit - reserved_run, reserved_run });
                reserved_run = 0;
            }
            try out.print(gpa, "    {s}: bool = false,\n", .{field});
        } else {
            reserved_run += 1;
        }
    }
    if (reserved_run > 0) {
        try out.print(gpa, "    _reserved{d}: u{d} = 0,\n", .{ e.bit_width - reserved_run, reserved_run });
    }
    try out.appendSlice(gpa, "};\n");
}

const VENDOR_TAGS = [_][]const u8{ "KHR", "EXT", "NV", "NVX", "AMD", "AMDX", "ARM", "IMG", "QCOM", "INTEL", "MVK", "FUCHSIA", "GOOGLE", "HUAWEI", "VALVE", "MSFT", "QNX", "SEC", "GGP", "OHOS" };

/// Derives the lowercase, underscore-joined prefix shared by every
/// enumerant of `type_name` (already Vk-stripped and Zig-cased), e.g.
/// "ImageUsageFlags" -> "image_usage", "SurfaceTransformFlagsKHR" ->
/// "surface_transform", "AccessFlags2" -> "access_2" (the trailing version
/// digit becomes its own underscore-separated token, matching how vk.xml
/// actually names 64-bit-flag enumerants, e.g. "VK_ACCESS_2_...").
/// Plain (non-bitmask) enums have no "Flags"/"FlagBits" suffix to strip, so
/// the whole Vk-stripped name becomes the prefix, e.g. "ImageLayout" ->
/// "image_layout".
/// The vendor tag (if any) the type's own name ends with, e.g.
/// "ColorSpaceKHR" -> "KHR", "ImageUsageFlags" -> "" (none). Every value of
/// a tagged type conventionally repeats that same tag at its own end too
/// (`VK_COLOR_SPACE_SRGB_NONLINEAR_KHR`), which is redundant once the
/// prefix already carries it -- `enumFieldName` uses this (not just any
/// vendor tag) to know which trailing tag is safe to also strip from the
/// value name, while leaving a *different* tag alone (an extension-
/// contributed value on an otherwise-untagged core enum, e.g.
/// `VK_ERROR_SURFACE_LOST_KHR` on the untagged `VkResult`, where the tag is
/// the only thing distinguishing it and must be kept).
fn typeVendorTag(type_name: []const u8) []const u8 {
    for (VENDOR_TAGS) |tag| {
        if (std.mem.endsWith(u8, type_name, tag) and type_name.len > tag.len) return tag;
    }
    return "";
}

fn memberPrefix(buf: *[256]u8, type_name: []const u8) []const u8 {
    var core = type_name;
    const vendor_tag = typeVendorTag(type_name);
    if (vendor_tag.len > 0) core = core[0 .. core.len - vendor_tag.len];

    var trailing_2 = false;
    if (std.mem.endsWith(u8, core, "FlagBits2")) {
        core = core[0 .. core.len - "FlagBits2".len];
        trailing_2 = true;
    } else if (std.mem.endsWith(u8, core, "Flags2")) {
        core = core[0 .. core.len - "Flags2".len];
        trailing_2 = true;
    } else if (std.mem.endsWith(u8, core, "FlagBits")) {
        core = core[0 .. core.len - "FlagBits".len];
    } else if (std.mem.endsWith(u8, core, "Flags")) {
        core = core[0 .. core.len - "Flags".len];
    }

    var len: usize = 0;
    for (core, 0..) |c, i| {
        if (len >= buf.len) break;
        if (i > 0 and std.ascii.isUpper(c) and (std.ascii.isLower(core[i - 1]) or std.ascii.isDigit(core[i - 1]))) {
            buf[len] = '_';
            len += 1;
        }
        if (len >= buf.len) break;
        buf[len] = std.ascii.toLower(c);
        len += 1;
    }
    if (trailing_2 and len + 2 <= buf.len) {
        buf[len] = '_';
        buf[len + 1] = '2';
        len += 2;
    }
    return buf[0..len];
}

/// "VK_IMAGE_USAGE_TRANSFER_SRC_BIT" (with `prefix` = "image_usage",
/// derived from the enum's own type name by `memberPrefix`) -> "transfer_src_bit".
/// Falls back to the raw name when the mechanical strip doesn't cleanly
/// apply (vk.xml has a handful of acronym-adjacency names this simple rule
/// mis-splits, or a value contributed by an unrelated vendor) -- an ugly
/// but correct (and always identifier-safe, since raw vk.xml names are
/// themselves valid Zig identifiers) field name is preferred over a build
/// failure.
fn enumFieldName(gpa: std.mem.Allocator, type_name: []const u8, prefix: []const u8, raw: []const u8) []const u8 {
    var lower_buf: [256]u8 = undefined;
    if (raw.len > lower_buf.len) return raw;
    for (raw, 0..) |c, i| lower_buf[i] = std.ascii.toLower(c);
    var name: []const u8 = lower_buf[0..raw.len];

    if (std.mem.startsWith(u8, name, "vk_")) name = name[3..];

    if (prefix.len > 0 and name.len > prefix.len + 1 and
        std.mem.startsWith(u8, name, prefix) and name[prefix.len] == '_')
    {
        name = name[prefix.len + 1 ..];
    }

    // Only strip a trailing vendor tag from the VALUE when it's the SAME
    // tag already carried by the TYPE's own name (redundant repetition,
    // e.g. every "VkColorSpaceKHR" value also ends in "_KHR"). A tag that
    // appears on the value but NOT on the type (an extension-contributed
    // value merged into an otherwise-untagged core enum, e.g.
    // `VK_ERROR_SURFACE_LOST_KHR` on plain `VkResult`) is the only thing
    // distinguishing that value and must be kept.
    const type_tag_upper = typeVendorTag(type_name);
    if (type_tag_upper.len > 0) {
        var tag_buf: [16]u8 = undefined;
        const tag = std.ascii.lowerString(tag_buf[0..type_tag_upper.len], type_tag_upper);
        if (std.mem.endsWith(u8, name, tag) and name.len > tag.len + 1 and name[name.len - tag.len - 1] == '_') {
            name = name[0 .. name.len - tag.len - 1];
        }
    }

    if (name.len == 0) return raw;
    if (std.ascii.isDigit(name[0])) return std.fmt.allocPrint(gpa, "@\"{s}\"", .{name}) catch raw;
    return quoteIfNeeded(gpa, name) catch raw;
}

/// Zig reserves both real keywords ("and", "error", "struct", ...) and
/// primitive value/type literals ("undefined", "true", "void", ...) --
/// vk.xml enumerant/member names collide with a few of these often enough
/// (e.g. `VK_ATTACHMENT_LOAD_OP_LOAD` -> bare suffix "load" is fine, but a
/// bitmask's "clear"/"and"-shaped names do occur) that this must be
/// checked, not assumed away.
fn quoteIfNeeded(gpa: std.mem.Allocator, name: []const u8) ![]const u8 {
    if (std.zig.Token.getKeyword(name) == null and !std.zig.primitives.isPrimitive(name)) return gpa.dupe(u8, name);
    return std.fmt.allocPrint(gpa, "@\"{s}\"", .{name});
}

fn writeAggregates(gpa: std.mem.Allocator, out: *std.ArrayList(u8), reg: *const model.Registry, universe: *const Universe, seen: *Seen) !void {
    for (reg.aggregates) |agg| {
        const name = registry.zigTypeName(agg.name);
        var body: std.ArrayList(u8) = .empty;
        defer body.deinit(gpa);

        var ok = true;
        var bad_member: []const u8 = "";
        var bad_base: []const u8 = "";
        for (agg.members) |m| {
            var type_text: std.ArrayList(u8) = .empty;
            defer type_text.deinit(gpa);
            if (!try writeFieldType(&type_text, gpa, reg, universe, m.type)) {
                ok = false;
                bad_member = m.name;
                bad_base = m.type.base;
                break;
            }
            // Every struct field defaults to its zero value, matching
            // addTranslateC's own convention for C structs -- this is what
            // lets call sites write partial struct literals
            // (`.{ .sType = ..., .format = ... }`) instead of having to
            // specify every single field. Unions can't have field defaults
            // at all in Zig (`= expr` on a union field is tag-value syntax,
            // not a default), so those are left bare. Pointer fields are
            // always optional (`?[*]...`/`?[*:0]...`, see writeFieldType),
            // so `null` is used directly rather than `std.mem.zeroes`,
            // which rejects pointers to unsized types like `anyopaque`.
            if (agg.is_union) {
                try body.print(gpa, "    {s}: {s},\n", .{ zigFieldName(gpa, m.name), type_text.items });
            } else if (std.mem.startsWith(u8, type_text.items, "?[*") or std.mem.startsWith(u8, type_text.items, "?*")) {
                try body.print(gpa, "    {s}: {s} = null,\n", .{ zigFieldName(gpa, m.name), type_text.items });
            } else {
                try body.print(gpa, "    {s}: {s} = std.mem.zeroes({s}),\n", .{ zigFieldName(gpa, m.name), type_text.items, type_text.items });
            }
        }
        if (!ok) {
            std.log.warn("vk_generator: skipping struct/union '{s}' (unrepresentable member '{s}': base='{s}')", .{ name, bad_member, bad_base });
            continue;
        }
        if (!try seen.tryReserve(gpa, name)) {
            std.log.warn("vk_generator: skipping duplicate struct/union '{s}'", .{name});
            continue;
        }

        const kind_kw = if (agg.is_union) "extern union" else "extern struct";
        try out.print(gpa, "pub const {s} = {s} {{\n", .{ name, kind_kw });
        try out.appendSlice(gpa, body.items);
        try out.appendSlice(gpa, "};\n");
    }
    try out.appendSlice(gpa, "\n");
}

/// Member/param names are kept byte-identical to vk.xml (camelCase, e.g.
/// `sType`, `pNext`) so existing call sites' struct-literal field names
/// never need to change -- only the container type name is Zig-cased.
fn zigFieldName(gpa: std.mem.Allocator, name: []const u8) []const u8 {
    if (isValidZigIdentifier(name)) return name;
    return std.fmt.allocPrint(gpa, "@\"{s}\"", .{name}) catch name;
}

fn isValidZigIdentifier(name: []const u8) bool {
    if (name.len == 0) return false;
    if (!std.ascii.isAlphabetic(name[0]) and name[0] != '_') return false;
    for (name) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '_') return false;
    }
    if (std.zig.Token.getKeyword(name) != null or std.zig.primitives.isPrimitive(name)) return false;
    return true;
}

fn writeCommands(gpa: std.mem.Allocator, out: *std.ArrayList(u8), reg: *const model.Registry, universe: *const Universe, seen: *Seen) !void {
    var instance_level_gated: std.ArrayList([]const u8) = .empty;
    defer instance_level_gated.deinit(gpa);
    var device_level_gated: std.ArrayList([]const u8) = .empty;
    defer device_level_gated.deinit(gpa);

    // Every command becomes a top-level `pub fn {zig_name}` wrapper (see
    // below), so a parameter whose vk.xml name happens to match some other
    // command's zig-cased name (e.g. a `signalSemaphore: Semaphore` param
    // on a command other than vkSignalSemaphore) would shadow that
    // declaration. Collect every zig-cased command name up front so
    // parameter names can be disambiguated against the full set, regardless
    // of where in `reg.commands` the colliding command appears.
    var command_names: std.StringHashMapUnmanaged(void) = .empty;
    defer {
        var it = command_names.keyIterator();
        while (it.next()) |k| gpa.free(k.*);
        command_names.deinit(gpa);
    }
    {
        var name_buf: [256]u8 = undefined;
        for (reg.commands) |cmd| {
            const zig_name = registry.zigCommandName(&name_buf, cmd.c_name);
            if (!command_names.contains(zig_name)) {
                const owned = try gpa.dupe(u8, zig_name);
                try command_names.put(gpa, owned, {});
            }
        }
    }

    for (reg.commands) |cmd| {
        var sig: std.ArrayList(u8) = .empty;
        defer sig.deinit(gpa);
        var call_args: std.ArrayList(u8) = .empty;
        defer call_args.deinit(gpa);

        var ok = true;
        for (cmd.params, 0..) |p, i| {
            if (i > 0) {
                try sig.appendSlice(gpa, ", ");
                try call_args.appendSlice(gpa, ", ");
            }
            var field = zigFieldName(gpa, p.name);
            if (command_names.contains(field)) {
                field = try std.fmt.allocPrint(gpa, "{s}_param", .{field});
            }
            try sig.print(gpa, "{s}: ", .{field});
            if (!try writeFieldType(&sig, gpa, reg, universe, p.type)) {
                ok = false;
                break;
            }
            try call_args.appendSlice(gpa, field);
        }

        if (!ok) {
            std.log.warn("vk_generator: skipping command '{s}' (unrepresentable parameter type)", .{cmd.c_name});
            continue;
        }

        var ret: std.ArrayList(u8) = .empty;
        defer ret.deinit(gpa);

        if (!try writeReturnType(&ret, gpa, reg, universe, cmd.return_type)) {
            std.log.warn("vk_generator: skipping command '{s}' (unrepresentable return type)", .{cmd.c_name});
            continue;
        }

        const is_result = std.mem.eql(u8, cmd.return_type, "VkResult");

        if (!cmd.is_baseline) {
            // Zig can't compile a function *body* under callconv(.c) (which
            // resolves to the Windows x64 C convention here) that takes a
            // by-value fixed-size array parameter -- only extern
            // declarations (no body to lower) are exempt. Affects a literal
            // handful of commands registry-wide (e.g. the fragment shading
            // rate combiner-ops commands); skip generating an unsafe
            // reroute for them rather than emit code that fails to compile.
            var has_value_array_param = false;
            for (cmd.params) |p| {
                if (p.type.pointer_depth == 0 and p.type.array_len != null) {
                    has_value_array_param = true;
                    break;
                }
            }
            if (has_value_array_param) {
                std.log.warn("vk_generator: skipping gated command '{s}' (by-value array parameter can't be given a stub body under this callconv)", .{cmd.c_name});
                continue;
            }
        }

        if (cmd.is_baseline) {
            // 1a. the raw extern fn -- resolved by the linker directly
            //     against the statically-linked Vulkan loader. Safe: every
            //     VK_VERSION_1_0-required command is guaranteed present.
            try out.print(gpa, "pub extern fn {s}({s}) callconv(.c) {s};\n", .{ cmd.c_name, sig.items, ret.items });
        }
        else {
            // 1b. gated command: not guaranteed present. Reroute to a stub
            //     of the identical signature until (if ever) resolved to the
            //     real driver function by loadInstanceCommands/
            //     loadDeviceCommands. The stub logs and reports
            //     unavailability the same way Vulkan itself would report a
            //     missing extension/version.
            try out.print(gpa, "fn {s}_unavailable({s}) callconv(.c) {s} {{\n", .{ cmd.c_name, sig.items, ret.items });
            try out.print(gpa, "    _ = .{{ {s} }};\n", .{call_args.items});
            try out.print(gpa,
                \\    std.log.err("zephyr: {s} is not available (requires {s}); the active instance/device does not support it", .{{}});
                \\
            , .{ cmd.c_name, cmd.origin });
            if (is_result) {
                try out.print(gpa, "    return .error_extension_not_present;\n}}\n", .{});
            } else if (std.mem.eql(u8, ret.items, "void")) {
                try out.print(gpa, "}}\n", .{});
            } else {
                try out.print(gpa, "    return std.mem.zeroes({s});\n}}\n", .{ret.items});
            }
            try out.print(gpa, "pub var {s}: *const fn ({s}) callconv(.c) {s} = &{s}_unavailable;\n", .{ cmd.c_name, sig.items, ret.items, cmd.c_name });

            switch (cmd.level) {
                .global, .instance => try instance_level_gated.append(gpa, cmd.c_name),
                .device => try device_level_gated.append(gpa, cmd.c_name),
            }
        }

        // 2. a Zig-cased convenience wrapper on top of it -- identical
        //    regardless of whether {c_name} above is an extern fn or a var
        //    holding a function pointer; both call with the same syntax.
        var name_buf: [256]u8 = undefined;
        const zig_name = registry.zigCommandName(&name_buf, cmd.c_name);

        if (!try seen.tryReserve(gpa, zig_name))
        {
            std.log.warn("vk_generator: skipping duplicate command wrapper '{s}' ({s})", .{ zig_name, cmd.c_name });
            continue;
        }

        if (is_result)
        {
            try out.print(gpa, "pub fn {s}({s}) Error!void {{\n    try check_result({s}({s}));\n}}\n\n", .{ zig_name, sig.items, cmd.c_name, call_args.items });
        }
        else
        {
            try out.print(gpa, "pub fn {s}({s}) {s} {{\n    return {s}({s});\n}}\n\n", .{ zig_name, sig.items, ret.items, cmd.c_name, call_args.items });
        }
    }

    try out.appendSlice(gpa, "pub fn loadInstanceCommands(instance: Instance) void {\n");
    for (instance_level_gated.items) |name| {
        try out.print(gpa, "    if (vkGetInstanceProcAddr(instance, \"{s}\")) |raw| {{ {s} = @ptrCast(raw); }}\n", .{ name, name });
    }
    try out.appendSlice(gpa, "}\n\n");

    try out.appendSlice(gpa, "pub fn loadDeviceCommands(device: Device) void {\n");
    for (device_level_gated.items) |name| {
        try out.print(gpa, "    if (vkGetDeviceProcAddr(device, \"{s}\")) |raw| {{ {s} = @ptrCast(raw); }}\n", .{ name, name });
    }
    try out.appendSlice(gpa, "}\n\n");
}
