const std = @import("std");
const xml = @import("xml");
const model = @import("model.zig");

// ---------------------------------------------------------------------------
// Document-order walk over a real XML pull parser.
//
// vk.xml is parsed in a single pass with `xml.Reader.Static`: every element is
// visited once, in document order, and structure comes from the parser rather
// than from substring heuristics. Malformed input surfaces as
// `error.MalformedXml` (with `errorLocation()` available) instead of a panic.
// ---------------------------------------------------------------------------

/// Every string the reader hands back points into its own buffers and is
/// invalidated by the next `read()` -- and `attributeValue`/`readElementText`
/// share one scratch buffer, so consecutive calls on the *same* node clobber
/// each other too. Anything that survives into `model.*` therefore has to be
/// duped into the registry arena straight away, hence the `Dup` suffixes.
const Cursor = struct {
    r: *xml.Reader,
    arena: std.mem.Allocator,

    /// Attribute of the current `element_start`, duped, or null if absent.
    fn attrDup(c: *Cursor, name: []const u8) !?[]const u8 {
        const idx = c.r.attributeIndex(name) orelse return null;
        return try c.arena.dupe(u8, try c.r.attributeValue(idx));
    }

    /// Attribute of the current `element_start`, borrowed -- valid only until
    /// the next reader call, so use it before touching the reader again.
    fn attr(c: *Cursor, name: []const u8) !?[]const u8 {
        const idx = c.r.attributeIndex(name) orelse return null;
        return try c.r.attributeValue(idx);
    }

    fn hasAttr(c: *Cursor, name: []const u8) bool {
        return c.r.attributeIndex(name) != null;
    }

    /// Text content of the current element, duped. Consumes the element.
    fn textDup(self: *Cursor) ![]const u8 {
        return try self.arena.dupe(u8, try self.r.readElementText());
    }

    /// Returns the element text. Consumes the element.
    /// Caller does not owned the memory. 
    fn text(self: *Cursor) ![]const u8 {
        return try self.r.readElementText();
    }

    /// Consumes the current element and everything inside it.
    fn skip(c: *Cursor) !void {
        try c.r.skipElement();
    }

    /// Call just after an `element_start` to iterate that element's direct
    /// children: yields each child's name with the reader positioned on its
    /// `element_start`, then null once the parent's `element_end` has been
    /// consumed.
    ///
    /// The caller MUST consume every child it is handed -- either by
    /// descending into it until its own `nextChild` returns null, or via
    /// `skip`/`textDup`. Coming back to `nextChild` without doing so would
    /// silently start iterating the child's children instead of the siblings.
    fn nextChild(c: *Cursor) !?[]const u8 {
        while (true) switch (try c.r.read()) {
            .element_start => return c.r.elementName(),
            .element_end => return null,
            .eof => return error.MalformedXml,
            // Text, comments, PIs and entity/character references between
            // child elements carry no structure at this level.
            else => {},
        };
    }
};

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

/// vk.xml gates types/commands/params to a specific API surface via
/// `api="vulkan"` or `api="vulkan,vulkansc"`. Absence means "all APIs". This
/// project only wants "vulkan", never "vulkansc" (safety-critical) variants.
fn apiIncludesVulkan(api: ?[]const u8) bool {
    const value = api orelse return true;
    var it = std.mem.splitScalar(u8, value, ',');
    while (it.next()) |token| {
        if (eql(token, "vulkan")) return true;
    }
    return false;
}

/// Parses a decimal (optionally negative) integer, ignoring a trailing
/// unsigned/long-long C literal suffix (`U`, `UL`, `ULL`, `L`, `LL`, `F`).
/// Also understands the handful of `(~0U)`-style bitwise-not sentinels used
/// by vk.xml's "API Constants" block. Returns null (rather than erroring) for
/// anything else (float literals, quoted strings) so callers can skip them.
fn parseCLiteralInt(raw: []const u8) ?i64 {
    var text = std.mem.trim(u8, raw, " \t");
    if (std.mem.startsWith(u8, text, "(~") and std.mem.endsWith(u8, text, ")")) {
        const inner = text[2 .. text.len - 1];
        var digits_end: usize = 0;
        while (digits_end < inner.len and std.ascii.isDigit(inner[digits_end])) digits_end += 1;
        const base = std.fmt.parseInt(u64, inner[0..digits_end], 10) catch return null;
        const is64 = std.mem.indexOfScalar(u8, inner[digits_end..], 'L') != null;
        const max: u64 = if (is64) std.math.maxInt(u64) else std.math.maxInt(u32);
        return @bitCast(max -% base);
    }
    var negative = false;
    if (text.len > 0 and text[0] == '-') {
        negative = true;
        text = text[1..];
    }
    var digits_end: usize = 0;
    while (digits_end < text.len and std.ascii.isDigit(text[digits_end])) digits_end += 1;
    if (digits_end == 0) return null;
    if (digits_end < text.len and text[digits_end] == '.') return null; // float literal, e.g. "1000.0F"
    const magnitude = std.fmt.parseInt(i64, text[0..digits_end], 10) catch return null;
    return if (negative) -magnitude else magnitude;
}

/// Typed counterpart of `parseCLiteralInt` for the "API Constants" block,
/// where vk.xml states the C type explicitly (`type="uint32_t"|"uint64_t"|
/// "float"`). Keeping the type is what lets float constants through at all --
/// `parseCLiteralInt` drops every one of them.
fn parseCValue(type_attr: ?[]const u8, raw: []const u8) ?model.Value {
    const text = std.mem.trim(u8, raw, " \t");
    const ty = type_attr orelse "";

    if (eql(ty, "float")) {
        // Suffix casing is inconsistent in vk.xml: "1000.0F" but "0.25f".
        const digits = std.mem.trimEnd(u8, text, "fF");
        return .{ .float = std.fmt.parseFloat(f32, digits) catch return null };
    }

    // `(~0U)` / `(~0ULL)` sentinels: VK_REMAINING_MIP_LEVELS, VK_WHOLE_SIZE, ...
    if (std.mem.startsWith(u8, text, "(~") and std.mem.endsWith(u8, text, ")")) {
        const inner = text[2 .. text.len - 1];
        var digits_end: usize = 0;
        while (digits_end < inner.len and std.ascii.isDigit(inner[digits_end])) digits_end += 1;
        const base = std.fmt.parseInt(u64, inner[0..digits_end], 10) catch return null;
        const is64 = std.mem.indexOfScalar(u8, inner[digits_end..], 'L') != null;
        if (is64) return .{ .uint64 = std.math.maxInt(u64) -% base };
        return .{ .uint32 = @truncate(@as(u64, std.math.maxInt(u32)) -% base) };
    }

    var digits = text;
    var negative = false;
    if (digits.len > 0 and digits[0] == '-') {
        negative = true;
        digits = digits[1..];
    }
    var digits_end: usize = 0;
    while (digits_end < digits.len and std.ascii.isDigit(digits[digits_end])) digits_end += 1;
    if (digits_end == 0) return null;
    if (digits_end < digits.len and digits[digits_end] == '.') return null; // float without type="float"
    digits = digits[0..digits_end];

    if (!negative and eql(ty, "uint64_t")) {
        return .{ .uint64 = std.fmt.parseInt(u64, digits, 10) catch return null };
    }
    if (!negative and eql(ty, "uint32_t")) {
        return .{ .uint32 = std.fmt.parseInt(u32, digits, 10) catch return null };
    }
    const magnitude = std.fmt.parseInt(i64, digits, 10) catch return null;
    return .{ .int = if (negative) -magnitude else magnitude };
}

// ---------------------------------------------------------------------------
// `<enums>` value-list builder: used both for the base `<enums name="X">`
// blocks and for extension/feature-contributed values, so both paths can
// merge into the same growable list before the registry is finalized.
// ---------------------------------------------------------------------------

const EnumBuilder = struct {
    name: []const u8,
    is_bitmask: bool,
    bit_width: u8,
    values: std.ArrayList(model.EnumValue) = .empty,
    seen: std.StringHashMapUnmanaged(void) = .empty,

    fn addValue(self: *EnumBuilder, gpa: std.mem.Allocator, name: []const u8, value: i64) !void {
        if (self.seen.contains(name)) return;
        try self.seen.put(gpa, name, {});
        try self.values.append(gpa, .{ .name = name, .value = value });
    }
};

const Registry_ = struct {
    gpa: std.mem.Allocator,
    /// FlagBits enum name -> its Flags typedef name, e.g.
    /// "VkImageUsageFlagBits" -> "VkImageUsageFlags". Bitmask value blocks
    /// and extension-contributed bitmask values are always keyed by the
    /// FlagBits name in vk.xml, but struct/command members reference the
    /// Flags typedef -- so the EnumType itself is stored under the Flags
    /// name, and this map lets both `<enums>` blocks and extension/feature
    /// `<enum extends="FooFlagBits">` entries find the right builder.
    flag_bits_to_flags: std.StringHashMapUnmanaged([]const u8) = .empty,
    builders: std.ArrayList(*EnumBuilder) = .empty,
    builder_index: std.StringHashMapUnmanaged(usize) = .empty,

    fn builderFor(self: *Registry_, name: []const u8, is_bitmask: bool, bit_width: u8) !*EnumBuilder {
        const key = self.flag_bits_to_flags.get(name) orelse name;
        if (self.builder_index.get(key)) |idx| return self.builders.items[idx];
        const b = try self.gpa.create(EnumBuilder);
        b.* = .{ .name = key, .is_bitmask = is_bitmask, .bit_width = bit_width };
        try self.builder_index.put(self.gpa, key, self.builders.items.len);
        try self.builders.append(self.gpa, b);
        return b;
    }
};

/// Command-name -> "is it in the VK_VERSION_1_0 baseline" classification, plus
/// (for gated commands only) a human-readable origin label used purely for
/// the generated wrapper's log message -- never for correctness. A command is
/// treated as gated (dynamically resolved at runtime, see emit.zig) unless
/// it's required unconditionally by the VK_VERSION_1_0 <feature> block; being
/// conservative here (gated when actually always-available) is safe, the
/// opposite mistake is not.
const CommandGating = struct {
    baseline: std.StringHashMapUnmanaged(void) = .empty,
    origin: std.StringHashMapUnmanaged([]const u8) = .empty,

    fn markBaseline(self: *CommandGating, arena: std.mem.Allocator, name: []const u8) !void {
        try self.baseline.put(arena, name, {});
    }

    /// First contributor wins (feature blocks are scanned before extension
    /// blocks, so a later core-promoted command's origin reads as the core
    /// version, e.g. "Vulkan 1.4", not the extension it started as).
    fn markGated(self: *CommandGating, arena: std.mem.Allocator, name: []const u8, label: []const u8) !void {
        if (self.baseline.contains(name)) return;
        if (self.origin.contains(name)) return;
        try self.origin.put(arena, name, label);
    }
};

// ---------------------------------------------------------------------------
// Public entry point
// ---------------------------------------------------------------------------

/// Parses a Vulkan registry document. `xml_text` only has to stay alive for
/// the duration of the call: every string reachable from the result is copied
/// into the returned registry's arena.
pub fn parse(gpa: std.mem.Allocator, xml_text: []const u8) !model.Registry {
    var registry = model.Registry{ .arena = std.heap.ArenaAllocator.init(gpa) };
    errdefer registry.deinit(gpa);

    const arena = registry.arena.allocator();

    var doc: xml.Reader.Static = .init(gpa, xml_text, .{ .namespace_aware = false });
    defer doc.deinit();
    var c = Cursor{ .r = &doc.interface, .arena = arena };

    var reg = Registry_{ .gpa = arena };
    var gating = CommandGating{};
    var handles: std.ArrayList(model.Handle) = .empty;
    var aggregates: std.ArrayList(model.AggType) = .empty;
    var commands: std.ArrayList(model.Command) = .empty;

    try c.r.skipProlog(); // positions on <registry>
    while (try c.nextChild()) |tag| {
        if (eql(tag, "types")) {
            try parseTypes(gpa, &c, &registry, &reg, &handles, &aggregates);
        } else if (eql(tag, "enums")) {
            try parseEnumsBlock(&c, &registry, &reg);
        } else if (eql(tag, "commands")) {
            try parseCommands(&c, &commands);
        } else if (eql(tag, "feature")) {
            try parseFeature(&c, &reg, &gating);
        } else if (eql(tag, "extensions")) {
            try parseExtensions(&c, &reg, &gating);
        } else {
            // <comment>, <platforms>, <tags>, <formats>, <spirvextensions>,
            // <spirvcapabilities>, <sync>, <videocodecs>.
            try c.skip();
        }
    }

    // vk.xml puts <commands> *before* the <feature>/<extensions> blocks that
    // classify them, so gating can only be resolved once the whole document
    // has been walked. (The multi-pass scanner this replaced parsed
    // <commands> last and could read `gating` inline.)
    for (commands.items) |*cmd| {
        cmd.is_baseline = gating.baseline.contains(cmd.c_name);
        cmd.origin = if (cmd.is_baseline)
            ""
        else
            gating.origin.get(cmd.c_name) orelse "an unspecified Vulkan version/extension";
    }

    var enums: std.ArrayList(model.EnumType) = .empty;
    for (reg.builders.items) |b| {
        try enums.append(arena, .{
            .name = b.name,
            .is_bitmask = b.is_bitmask,
            .bit_width = b.bit_width,
            .values = try b.values.toOwnedSlice(arena),
        });
    }

    registry.handles = try handles.toOwnedSlice(arena);
    registry.enums = try enums.toOwnedSlice(arena);
    registry.aggregates = try aggregates.toOwnedSlice(arena);
    registry.commands = try commands.toOwnedSlice(arena);
    return registry;
}

// ---------------------------------------------------------------------------
// `<types>`: handles, bitmask typedefs, enum forward-decls, struct/union
// definitions (with full member lists), basetype typedefs.
// ---------------------------------------------------------------------------

fn parseTypes(gpa: std.mem.Allocator, c: *Cursor, registry: *model.Registry, reg: *Registry_,
    handles: *std.ArrayList(model.Handle), aggregates: *std.ArrayList(model.AggType),
) !void {
    while (try c.nextChild()) |tag| {
        if (eql(tag, "type")) {
            try parseType(gpa, c, registry, reg, handles, aggregates);
        } else {
            try c.skip();
        }
    }
}

fn parseType(gpa: std.mem.Allocator, c: *Cursor, registry: *model.Registry, reg: *Registry_,
    handles: *std.ArrayList(model.Handle), aggregates: *std.ArrayList(model.AggType)) !void {
    // Attributes have to be read up front: the first child `read()`
    // invalidates them.
    const is_alias = c.hasAttr("alias");
    const api = try c.attrDup("api");
    const category = try c.attrDup("category");
    const name_attr = try c.attrDup("name");
    const requires = try c.attrDup("requires");
    const bitvalues = try c.attrDup("bitvalues");

    if (is_alias or !apiIncludesVulkan(api) or category == null) {
        // Aliases are covered by their target.
        try c.skip();
        return;
    }
    const cat = category.?;

    if (eql(cat, "basetype")) {
        // typedef <type>uint64_t</type> <name>VkDeviceSize</name>;
        var inner: ?[]const u8 = null;
        var name: ?[]const u8 = null;
        while (try c.nextChild()) |child| {
            if (eql(child, "type") and inner == null) {
                inner = try c.textDup();
            } else if (eql(child, "name") and name == null) {
                name = try c.textDup();
            } else {
                try c.skip();
            }
        }
        const n = name orelse return;
        const i = inner orelse return;
        const zig_base = mapPrimitive(i) orelse return;
        try registry.basetypes.put(c.arena, n, zig_base);
    } 
    else if (eql(cat, "handle")) {
        // <type>VK_DEFINE_HANDLE</type>(<name>VkInstance</name>)
        var name: ?[]const u8 = null;
        
        // A handle declared without a body carries no macro to inspect;
        // default to non-dispatchable (u64), as the old scanner did.
        var dispatchable = false;
        var saw_macro = false;
        
        while (try c.nextChild()) |child| {
            if (eql(child, "type") and !saw_macro) {
                saw_macro = true;
                dispatchable = !eql(try c.r.readElementText(), "VK_DEFINE_NON_DISPATCHABLE_HANDLE");
            } 
            else if (eql(child, "name") and name == null) {
                name = try c.text();
            } 
            else {
                try c.skip();
            }
        }
        
        const n = name orelse name_attr orelse return;

        try handles.append(c.arena, .{ .name = try gpa.dupe(u8, n), .dispatchable = dispatchable });
    } 
    else if (eql(cat, "bitmask")) {
        // typedef <type>VkFlags</type> <name>VkImageUsageFlags</name>;
        var inner: ?[]const u8 = null;
        var flags_name: ?[]const u8 = null;
        while (try c.nextChild()) |child| {
            if (eql(child, "type") and inner == null) {
                inner = try c.textDup();
            } else if (eql(child, "name") and flags_name == null) {
                flags_name = try c.textDup();
            } else {
                try c.skip();
            }
        }
        const n = flags_name orelse return;
        const bit_width: u8 = if (eql(inner orelse "VkFlags", "VkFlags64")) 64 else 32;
        // Registered under the Flags name *before* the FlagBits mapping is
        // recorded, so the builder ends up keyed by the Flags typedef.
        _ = try reg.builderFor(n, true, bit_width);
        if (requires orelse bitvalues) |bits_name| {
            try reg.flag_bits_to_flags.put(c.arena, bits_name, n);
        }
    } 
    else if (eql(cat, "struct") or eql(cat, "union")) {
        const n = name_attr orelse {
            try c.skip();
            return;
        };
        var members: std.ArrayList(model.Member) = .empty;
        while (try c.nextChild()) |child| {
            if (eql(child, "member")) {
                if (try parseTypeSlot(c)) |m| try members.append(c.arena, m);
            } else {
                try c.skip();
            }
        }
        try aggregates.append(c.arena, .{
            .name = n,
            .is_union = eql(cat, "union"),
            .members = try members.toOwnedSlice(c.arena),
        });
    } 
    else if (eql(cat, "enum")) {
        // Forward declaration; the values arrive in a top-level <enums> block.
        // Usually self-closing, occasionally an empty body -- with a real
        // parser both look identical, so there is only one path.
        if (name_attr) |n| _ = try reg.builderFor(n, false, 32);
        try c.skip();
    } 
    else {
        // "include", "define", "funcpointer".
        try c.skip();
    }
}

fn mapPrimitive(c_name: []const u8) ?[]const u8 {
    const table = [_]struct { c: []const u8, zig: []const u8 }{
        .{ .c = "void", .zig = "anyopaque" },
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
        if (eql(entry.c, c_name)) return entry.zig;
    }
    return null;
}

// ---------------------------------------------------------------------------
// Member / parameter type slots, shared by struct/union members and command
// parameters. These are mixed content -- a C declaration interleaved with
// markup:
//   <member optional="true">const <type>char</type>* const* <name>foo</name>[4]</member>
// ---------------------------------------------------------------------------

/// Consumes one `<member>`/`<param>` element. Returns null for the slots that
/// carry no usable `<type>`/`<name>` pair, or that don't apply to the "vulkan"
/// API (both were dropped by the previous scanner too).
fn parseTypeSlot(c: *Cursor) !?model.Member {
    const is_optional = c.hasAttr("optional");
    const api = try c.attrDup("api");

    var base: ?[]const u8 = null;
    var name: ?[]const u8 = null;
    var array_len: ?[]const u8 = null;

    // Text runs, bucketed by position: `const` may appear before `<type>` or
    // between `</type>` and `<name>`, `*` only in the latter.
    var pre: std.ArrayList(u8) = .empty;
    var mid: std.ArrayList(u8) = .empty;
    var stage: enum { pre, mid, post } = .pre;

    // Only the *first* text run after `</name>` can be an array marker. A `[`
    // appearing later belongs to a trailing `<comment>`'s prose (Vulkan doc
    // comments use bracket notation for ranges) -- the old scanner had to
    // infer that from byte offsets.
    var post_seen = false;
    // `[` seen with no closing `]` in that run: the length is the <enum>
    // child that follows, as in `<name>x</name>[<enum>VK_UUID_SIZE</enum>]`.
    var want_enum_len = false;

    while (true) switch (try c.r.read()) {
        // Every child below is consumed whole, so the only `element_end` that
        // can reach this level is the slot's own closing tag.
        .element_end => break,
        .eof => return error.MalformedXml,
        .element_start => {
            const child = c.r.elementName();
            if (eql(child, "type") and base == null) {
                base = try c.textDup();
                stage = .mid;
            } else if (eql(child, "name") and name == null) {
                name = try c.textDup();
                stage = .post;
            } else if (eql(child, "enum") and want_enum_len and array_len == null) {
                array_len = try c.textDup();
            } else {
                try c.skip();
            }
        },
        .text, .cdata => {
            const run = if (c.r.node == .text) try c.r.text() else try c.r.cdata();
            switch (stage) {
                .pre => try pre.appendSlice(c.arena, run),
                .mid => try mid.appendSlice(c.arena, run),
                .post => if (!post_seen) {
                    post_seen = true;
                    if (run.len > 0 and run[0] == '[') {
                        if (std.mem.indexOfScalar(u8, run, ']')) |close| {
                            array_len = try c.arena.dupe(u8, std.mem.trim(u8, run[1..close], " \t"));
                            if (std.mem.indexOfScalarPos(u8, run, close + 1, '[') != null) {
                                std.log.warn(
                                    "vk_generator: multi-dimensional array '{s}' kept only its first dimension",
                                    .{name orelse ""},
                                );
                            }
                        } else {
                            want_enum_len = true;
                        }
                    }
                },
            }
        },
        .character_reference => {
            var buf: [4]u8 = undefined;
            const len = std.unicode.utf8Encode(c.r.characterReferenceChar(), &buf) catch unreachable;
            switch (stage) {
                .pre => try pre.appendSlice(c.arena, buf[0..len]),
                .mid => try mid.appendSlice(c.arena, buf[0..len]),
                .post => {},
            }
        },
        .entity_reference => {
            const expanded = xml.predefined_entities.get(c.r.entityReferenceName()) orelse "";
            switch (stage) {
                .pre => try pre.appendSlice(c.arena, expanded),
                .mid => try mid.appendSlice(c.arena, expanded),
                .post => {},
            }
        },
        // Comments and PIs carry no declaration text.
        else => {},
    };

    if (!apiIncludesVulkan(api)) return null;
    const b = base orelse return null;
    const n = name orelse return null;

    var pointer_depth: u2 = 0;
    for (mid.items) |ch| {
        if (ch == '*') pointer_depth +|= 1;
    }

    return .{
        .name = n,
        .type = .{
            .base = b,
            .pointer_depth = pointer_depth,
            .is_const = std.mem.indexOf(u8, pre.items, "const") != null or
                std.mem.indexOf(u8, mid.items, "const") != null,
            .is_optional = is_optional,
            .array_len = array_len,
        },
    };
}

// ---------------------------------------------------------------------------
// Top-level `<enums>` blocks: the enum/bitmask value lists, plus the single
// `type="constants"` block holding the API's hardcoded constants.
// ---------------------------------------------------------------------------

fn parseEnumsBlock(c: *Cursor, registry: *model.Registry, reg: *Registry_) !void {
    const block_name = try c.attrDup("name");
    const block_type = try c.attrDup("type");
    const bitwidth = try c.attrDup("bitwidth");

    const bt = block_type orelse {
        std.log.warn("no block type found.", .{});
        try c.skip();
        return;
    };
    if (eql(bt, "constants")) return parseConstants(c, registry);

    const is_bitmask = eql(bt, "bitmask");
    if (!is_bitmask and !eql(bt, "enum")) {
        std.log.info("enums block skipped. name {any}", .{ block_name });

        try c.skip();
        return;
    }

    const name = block_name orelse {
        std.log.warn("No name found for enums block.", .{});
        try c.skip();
        return;
    };

    const bit_width: u8 = if (bitwidth) |w| (std.fmt.parseInt(u8, w, 10) catch 32) else 32;
    const builder = try reg.builderFor(name, is_bitmask, bit_width);

    while (try c.nextChild()) |child| {
        if (eql(child, "enum")) try addEnumValue(c, builder, null);
        // `<enum>` is self-closing and `<comment>`/`<unused>` are irrelevant
        // here; either way the element still has to be consumed.
        try c.skip();
    }
}

/// `<enums name="API Constants" type="constants">`: the typed constants block.
fn parseConstants(c: *Cursor, registry: *model.Registry) !void {
    while (try c.nextChild()) |child| {
        if (eql(child, "enum")) {
            const name = try c.attrDup("name");
            const type_attr = try c.attrDup("type");
            const raw = try c.attrDup("value");
            if (name != null and raw != null) {
                if (parseCValue(type_attr, raw.?)) |value| {
                    try registry.constants.put(c.arena, name.?, value);
                } else {
                    std.log.warn(
                        "vk_generator: skipping constant '{s}' (unparsable value '{s}')",
                        .{ name.?, raw.? },
                    );
                }
            }
        }
        try c.skip();
    }
}

/// Extracts one `<enum ...>` entry's value, used both by base `<enums>` blocks
/// and by extension/feature `<require>` contributions. Does not consume the
/// element -- the caller does. `owning_ext_number` is the enclosing
/// `<extension number="N">` (null inside `<feature>` blocks, which always
/// specify `extnumber` explicitly).
fn addEnumValue(c: *Cursor, builder: *EnumBuilder, owning_ext_number: ?i64) !void {
    if (c.hasAttr("alias")) return;
    const name = (try c.attrDup("name")) orelse return;

    if (try c.attr("bitpos")) |bp_raw| {
        const bitpos = std.fmt.parseInt(u6, bp_raw, 10) catch return;
        try builder.addValue(c.arena, name, @as(i64, 1) << bitpos);
        return;
    }
    if (try c.attr("value")) |v_raw| {
        const value = parseCLiteralInt(v_raw) orelse return;
        try builder.addValue(c.arena, name, value);
        return;
    }
    if (try c.attr("offset")) |off_raw| {
        const offset = std.fmt.parseInt(i64, off_raw, 10) catch return;
        const ext_number = blk: {
            if (try c.attr("extnumber")) |n| break :blk std.fmt.parseInt(i64, n, 10) catch return;
            break :blk owning_ext_number orelse return;
        };
        const dir: i64 = if (try c.attr("dir")) |d| (if (eql(d, "-")) -1 else 1) else 1;
        const abs = dir * (1_000_000_000 + (ext_number - 1) * 1000 + offset);
        try builder.addValue(c.arena, name, abs);
        return;
    }
    // Plain spec-version / extension-name-string constants: not a type value, skip.
}

// ---------------------------------------------------------------------------
// `<feature>` and `<extensions>`/`<extension>`: their `<require>` blocks
// contribute extra values to enums/bitmasks declared elsewhere
// (extension-numbered VkResult/VkStructureType/*FlagBits entries) and classify
// each command as baseline or gated. This is load-bearing, not a cosmetic
// extra -- engine.zig relies on several extension-contributed
// StructureType/Result values.
// ---------------------------------------------------------------------------

fn parseFeature(c: *Cursor, reg: *Registry_, gating: *CommandGating) !void {
    const api = try c.attrDup("api");
    const feature_name = (try c.attrDup("name")) orelse "";
    const number = (try c.attrDup("number")) orelse "";

    if (!apiIncludesVulkan(api)) {
        try c.skip();
        return;
    }

    // Recent vk.xml splits VK_VERSION_1_0 into several internal sub-features
    // joined by `depends` -- VK_BASE_VERSION_1_0, VK_COMPUTE_VERSION_1_0 and
    // VK_GRAPHICS_VERSION_1_0 each carry a slice of the "baseline" commands
    // (e.g. vkCreateInstance lives in VK_BASE_VERSION_1_0, not
    // VK_VERSION_1_0 itself). Matching on the literal name "VK_VERSION_1_0"
    // alone missed those, wrongly gating baseline commands. All four
    // number="1.0" blocks are unconditionally required together for the
    // "vulkan" api (already filtered above), so classify by version number
    // instead of by block name.
    const is_baseline_block = eql(number, "1.0");
    const label = if (number.len > 0)
        try std.fmt.allocPrint(c.arena, "Vulkan {s}", .{number})
    else
        feature_name;

    while (try c.nextChild()) |child| {
        if (eql(child, "require")) {
            try parseRequire(c, reg, gating, null, is_baseline_block, label);
        } else {
            // `<remove>` strips features from an API variant rather than
            // adding any, and `<comment>` carries prose.
            try c.skip();
        }
    }
}

fn parseExtensions(c: *Cursor, reg: *Registry_, gating: *CommandGating) !void {
    while (try c.nextChild()) |tag| {
        if (!eql(tag, "extension")) {
            try c.skip();
            continue;
        }

        const supported = try c.attrDup("supported");
        const number_attr = try c.attrDup("number");
        const ext_name = (try c.attrDup("name")) orelse "an unspecified extension";

        if (supported) |s| {
            if (eql(s, "disabled")) {
                try c.skip();
                continue;
            }
        }
        const number: ?i64 = if (number_attr) |n| (std.fmt.parseInt(i64, n, 10) catch null) else null;

        while (try c.nextChild()) |child| {
            if (eql(child, "require")) {
                try parseRequire(c, reg, gating, number, false, ext_name);
            } else {
                try c.skip();
            }
        }
    }
}

fn parseRequire(
    c: *Cursor,
    reg: *Registry_,
    gating: *CommandGating,
    owning_ext_number: ?i64,
    is_baseline_block: bool,
    label: []const u8,
) !void {
    while (try c.nextChild()) |child| {
        if (eql(child, "enum")) {
            if (try c.attrDup("extends")) |extends| {
                // `extends` should always already have a builder from the
                // <types> pass; `false, 32` are just fallback defaults for
                // the (unexpected) case where it doesn't.
                const builder = try reg.builderFor(extends, false, 32);
                try addEnumValue(c, builder, owning_ext_number);
            }
        } else if (eql(child, "command")) {
            if (try c.attrDup("name")) |name| {
                if (is_baseline_block) {
                    try gating.markBaseline(c.arena, name);
                } else {
                    try gating.markGated(c.arena, name, label);
                }
            }
        }
        try c.skip();
    }
}

// ---------------------------------------------------------------------------
// `<commands>`
// ---------------------------------------------------------------------------

/// Global commands aren't dispatched through any handle's table; instance-
/// level commands take VkInstance/VkPhysicalDevice first; device-level take
/// VkDevice/VkQueue/VkCommandBuffer first. Mirrors the classification Vulkan
/// itself uses to decide between vkGetInstanceProcAddr/vkGetDeviceProcAddr.
fn classifyLevel(params: []const model.Member) model.CommandLevel {
    if (params.len == 0) return .global;
    const base = params[0].type.base;
    if (eql(base, "VkInstance") or eql(base, "VkPhysicalDevice")) return .instance;
    if (eql(base, "VkDevice") or eql(base, "VkQueue") or eql(base, "VkCommandBuffer")) return .device;
    return .global;
}

fn parseCommands(c: *Cursor, commands: *std.ArrayList(model.Command)) !void {
    while (try c.nextChild()) |tag| {
        if (eql(tag, "command")) {
            try parseCommand(c, commands);
        } else {
            try c.skip();
        }
    }
}

/// `is_baseline` and `origin` are left at their defaults here and filled in by
/// `parse` once the <feature>/<extensions> blocks -- which come *after*
/// <commands> in the document -- have been walked.
fn parseCommand(c: *Cursor, commands: *std.ArrayList(model.Command)) !void {
    // A pure alias command (`<command name="X" alias="Y"/>`): the aliased
    // target is already covered under its own name.
    const is_alias = c.hasAttr("alias");
    const api = try c.attrDup("api");
    if (is_alias or !apiIncludesVulkan(api)) {
        try c.skip();
        return;
    }

    var c_name: ?[]const u8 = null;
    var return_type: []const u8 = "void";
    var params: std.ArrayList(model.Member) = .empty;

    while (try c.nextChild()) |child| {
        if (eql(child, "proto")) {
            // <proto><type>VkResult</type> <name>vkCreateInstance</name></proto>
            var saw_return = false;
            while (try c.nextChild()) |p| {
                if (eql(p, "type") and !saw_return) {
                    saw_return = true;
                    return_type = try c.textDup();
                } else if (eql(p, "name") and c_name == null) {
                    c_name = try c.textDup();
                } else {
                    try c.skip();
                }
            }
        } else if (eql(child, "param")) {
            if (try parseTypeSlot(c)) |param| try params.append(c.arena, param);
        } else {
            // <implicitexternsyncparams> is trailing prose wrapped in its own
            // <param> tags -- skipping the element wholesale is enough now
            // that nesting is real, no truncation heuristic needed.
            try c.skip();
        }
    }

    const n = c_name orelse return;
    const param_slice = try params.toOwnedSlice(c.arena);
    try commands.append(c.arena, .{
        .c_name = n,
        .return_type = return_type,
        .params = param_slice,
        .level = classifyLevel(param_slice),
    });
}

// ---------------------------------------------------------------------------
// Name mangling helpers, shared with emit.zig
// ---------------------------------------------------------------------------

/// "vkCreateInstance" -> "createInstance" / "VkInstanceCreateInfo" -> "InstanceCreateInfo":
/// strip the leading "vk"/"Vk" and lowercase (commands) or keep (types) the
/// case of the first remaining character.
pub fn zigCommandName(buf: []u8, c_name: []const u8) []const u8 {
    std.debug.assert(std.mem.startsWith(u8, c_name, "vk"));
    const rest = c_name[2..];
    std.debug.assert(rest.len <= buf.len);
    @memcpy(buf[0..rest.len], rest);
    buf[0] = std.ascii.toLower(buf[0]);
    return buf[0..rest.len];
}

pub fn zigTypeName(c_name: []const u8) []const u8 {
    if (std.mem.startsWith(u8, c_name, "Vk")) return c_name[2..];
    return c_name;
}

/// "VK_UUID_SIZE" -> "UUID_SIZE", mirroring `zigTypeName`'s "Vk" strip.
pub fn zigConstantName(c_name: []const u8) []const u8 {
    if (std.mem.startsWith(u8, c_name, "VK_")) return c_name[3..];
    return c_name;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

/// Parses a whole (tiny) registry document, so the tests exercise the same
/// walk the real vk.xml goes through rather than a hand-picked fragment.
fn testParse(doc: []const u8) !model.Registry {
    return parse(std.testing.allocator, doc);
}

test "feature/extension blocks mark 1.0 commands baseline and the rest gated" {
    var reg = try testParse(
        \\<registry>
        \\  <commands>
        \\    <command><proto><type>VkResult</type> <name>vkCreateInstance</name></proto></command>
        \\    <command><proto>void <name>vkCmdBindDescriptorSets2</name></proto></command>
        \\  </commands>
        \\  <feature api="vulkan" name="VK_BASE_VERSION_1_0" number="1.0">
        \\    <require><command name="vkCreateInstance"/></require>
        \\  </feature>
        \\  <extensions>
        \\    <extension name="VK_KHR_maintenance6" number="576" supported="vulkan">
        \\      <require><command name="vkCmdBindDescriptorSets2"/></require>
        \\    </extension>
        \\  </extensions>
        \\</registry>
    );
    defer reg.deinit();

    try std.testing.expectEqual(@as(usize, 2), reg.commands.len);
    try std.testing.expect(reg.commands[0].is_baseline);
    try std.testing.expectEqualStrings("", reg.commands[0].origin);
    try std.testing.expect(!reg.commands[1].is_baseline);
    try std.testing.expectEqualStrings("VK_KHR_maintenance6", reg.commands[1].origin);
}

test "extension offset resolves to the documented absolute value" {
    // VK_ERROR_SURFACE_LOST_KHR: extension number 1, offset 0, dir "-" -> -1000000000
    var reg = try testParse(
        \\<registry>
        \\  <types><type category="enum" name="VkResult"/></types>
        \\  <extensions>
        \\    <extension name="VK_KHR_surface" number="1" supported="vulkan">
        \\      <require>
        \\        <enum offset="0" extends="VkResult" dir="-" name="VK_ERROR_SURFACE_LOST_KHR"/>
        \\      </require>
        \\    </extension>
        \\  </extensions>
        \\</registry>
    );
    defer reg.deinit();

    try std.testing.expectEqual(@as(usize, 1), reg.enums.len);
    try std.testing.expectEqualStrings("VkResult", reg.enums[0].name);
    try std.testing.expectEqual(@as(usize, 1), reg.enums[0].values.len);
    try std.testing.expectEqual(@as(i64, -1_000_000_000), reg.enums[0].values[0].value);
}

test "disabled extensions contribute nothing" {
    var reg = try testParse(
        \\<registry>
        \\  <types><type category="enum" name="VkResult"/></types>
        \\  <extensions>
        \\    <extension name="VK_KHR_dead" number="1" supported="disabled">
        \\      <require><enum offset="0" extends="VkResult" name="VK_SOMETHING"/></require>
        \\    </extension>
        \\  </extensions>
        \\</registry>
    );
    defer reg.deinit();
    try std.testing.expectEqual(@as(usize, 0), reg.enums[0].values.len);
}

test "member slots carry pointer depth, const, optional and array length" {
    var reg = try testParse(
        \\<registry><types>
        \\  <type category="struct" name="VkApplicationInfo">
        \\    <member optional="true" len="null-terminated">const <type>char</type>*     <name>pApplicationName</name></member>
        \\    <member><type>uint8_t</type>        <name>pipelineCacheUUID</name>[<enum>VK_UUID_SIZE</enum>]</member>
        \\    <member><type>uint32_t</type> <name>counts</name>[4]</member>
        \\    <member><type>VkBool32</type> <name alias="VkPhysicalDeviceShaderDrawParametersFeatures::shaderDrawParameters">shaderDrawParameters</name></member>
        \\  </type>
        \\</types></registry>
    );
    defer reg.deinit();

    const members = reg.aggregates[0].members;
    try std.testing.expectEqual(@as(usize, 4), members.len);

    try std.testing.expectEqualStrings("pApplicationName", members[0].name);
    try std.testing.expectEqualStrings("char", members[0].type.base);
    try std.testing.expectEqual(@as(u2, 1), members[0].type.pointer_depth);
    try std.testing.expect(members[0].type.is_const);
    try std.testing.expect(members[0].type.is_optional);

    try std.testing.expectEqualStrings("VK_UUID_SIZE", members[1].type.array_len.?);
    try std.testing.expectEqualStrings("4", members[2].type.array_len.?);

    // Promoted-feature structs render their members as
    // `<name alias="Original::field">name</name>`; the alias must not leak.
    try std.testing.expectEqualStrings("shaderDrawParameters", members[3].name);
    try std.testing.expectEqualStrings("VkBool32", members[3].type.base);
    try std.testing.expectEqual(@as(?[]const u8, null), members[3].type.array_len);
}

test "a bracket in a trailing comment is not an array length" {
    // The substring scanner had to infer this from byte offsets; with real
    // parsing the comment is simply a different element.
    var reg = try testParse(
        \\<registry><types>
        \\  <type category="struct" name="S">
        \\    <member><type>uint32_t</type> <name>x</name><comment>valid range is [0,1]</comment></member>
        \\  </type>
        \\</types></registry>
    );
    defer reg.deinit();
    try std.testing.expectEqual(@as(?[]const u8, null), reg.aggregates[0].members[0].type.array_len);
}

test "implicitexternsyncparams are not mistaken for real parameters" {
    var reg = try testParse(
        \\<registry><commands>
        \\  <command>
        \\    <proto><type>VkResult</type> <name>vkQueueSubmit</name></proto>
        \\    <param><type>VkQueue</type> <name>queue</name></param>
        \\    <implicitexternsyncparams>
        \\      <param>the sname:VkCommandPool that each element of pname:pCommandBuffers was allocated from</param>
        \\    </implicitexternsyncparams>
        \\  </command>
        \\</commands></registry>
    );
    defer reg.deinit();
    try std.testing.expectEqual(@as(usize, 1), reg.commands[0].params.len);
    try std.testing.expectEqualStrings("queue", reg.commands[0].params[0].name);
    try std.testing.expectEqual(model.CommandLevel.device, reg.commands[0].level);
}

test "handles derive their backing width from the definition macro" {
    var reg = try testParse(
        \\<registry><types>
        \\  <type category="handle"><type>VK_DEFINE_HANDLE</type>(<name>VkInstance</name>)</type>
        \\  <type category="handle"><type>VK_DEFINE_NON_DISPATCHABLE_HANDLE</type>(<name>VkBuffer</name>)</type>
        \\</types></registry>
    );
    defer reg.deinit();
    try std.testing.expect(reg.handles[0].dispatchable);
    try std.testing.expect(!reg.handles[1].dispatchable);
}

test "bitmask values contributed under the FlagBits name land on the Flags typedef" {
    var reg = try testParse(
        \\<registry>
        \\  <types>
        \\    <type category="bitmask" requires="VkQueueFlagBits">typedef <type>VkFlags</type> <name>VkQueueFlags</name>;</type>
        \\  </types>
        \\  <enums name="VkQueueFlagBits" type="bitmask">
        \\    <enum bitpos="0" name="VK_QUEUE_GRAPHICS_BIT"/>
        \\  </enums>
        \\</registry>
    );
    defer reg.deinit();
    try std.testing.expectEqual(@as(usize, 1), reg.enums.len);
    try std.testing.expectEqualStrings("VkQueueFlags", reg.enums[0].name);
    try std.testing.expect(reg.enums[0].is_bitmask);
    try std.testing.expectEqual(@as(i64, 1), reg.enums[0].values[0].value);
}

test "typed constants keep floats, which the integer-only parse dropped" {
    var reg = try testParse(
        \\<registry>
        \\  <enums name="API Constants" type="constants">
        \\    <enum type="uint32_t" value="16" name="VK_UUID_SIZE"/>
        \\    <enum type="uint32_t" value="(~0U)" name="VK_REMAINING_MIP_LEVELS"/>
        \\    <enum type="uint64_t" value="(~0ULL)" name="VK_WHOLE_SIZE"/>
        \\    <enum type="float" value="1000.0F" name="VK_LOD_CLAMP_NONE"/>
        \\    <enum type="float" value="0.25f" name="VK_COMPUTE_OCCUPANCY_PRIORITY_LOW_NV"/>
        \\  </enums>
        \\</registry>
    );
    defer reg.deinit();

    try std.testing.expectEqual(@as(usize, 5), reg.constants.count());
    try std.testing.expectEqual(model.Value{ .uint32 = 16 }, reg.constants.get("VK_UUID_SIZE").?);
    try std.testing.expectEqual(
        model.Value{ .uint32 = std.math.maxInt(u32) },
        reg.constants.get("VK_REMAINING_MIP_LEVELS").?,
    );
    try std.testing.expectEqual(
        model.Value{ .uint64 = std.math.maxInt(u64) },
        reg.constants.get("VK_WHOLE_SIZE").?,
    );
    try std.testing.expectEqual(model.Value{ .float = 1000.0 }, reg.constants.get("VK_LOD_CLAMP_NONE").?);
    try std.testing.expectEqual(
        model.Value{ .float = 0.25 },
        reg.constants.get("VK_COMPUTE_OCCUPANCY_PRIORITY_LOW_NV").?,
    );
}

test "vulkansc-only entries are filtered out" {
    var reg = try testParse(
        \\<registry>
        \\  <types>
        \\    <type category="struct" name="VkScOnly" api="vulkansc"><member><type>uint32_t</type> <name>x</name></member></type>
        \\    <type category="struct" name="VkBoth" api="vulkan,vulkansc"><member><type>uint32_t</type> <name>y</name></member></type>
        \\  </types>
        \\</registry>
    );
    defer reg.deinit();
    try std.testing.expectEqual(@as(usize, 1), reg.aggregates.len);
    try std.testing.expectEqualStrings("VkBoth", reg.aggregates[0].name);
}

test "malformed input is an error, not a panic" {
    // The substring scanner used to @panic on anything it couldn't find.
    try std.testing.expectError(error.MalformedXml, testParse("<registry><types></registry>"));
}

test "entity references in attributes are decoded" {
    var reg = try testParse(
        \\<registry>
        \\<commands><command><proto>void <name>vkFoo</name></proto></command></commands>
        \\<extensions>
        \\  <extension name="VK_a&quot;b" number="1" supported="vulkan">
        \\    <require><command name="vkFoo"/></require>
        \\  </extension>
        \\</extensions>
        \\</registry>
    );
    defer reg.deinit();
    try std.testing.expectEqualStrings("VK_a\"b", reg.commands[0].origin);
}

test "parseCLiteralInt handles plain, negative and bitwise-not forms" {
    try std.testing.expectEqual(@as(?i64, 256), parseCLiteralInt("256"));
    try std.testing.expectEqual(@as(?i64, -13), parseCLiteralInt("-13"));
    try std.testing.expectEqual(@as(?i64, @as(i64, std.math.maxInt(u32))), parseCLiteralInt("(~0U)"));
    try std.testing.expectEqual(@as(?i64, null), parseCLiteralInt("1000.0F"));
}

test "parseCValue keeps the declared C type" {
    try std.testing.expectEqual(model.Value{ .uint32 = 16 }, parseCValue("uint32_t", "16").?);
    try std.testing.expectEqual(model.Value{ .uint64 = 1 }, parseCValue("uint64_t", "1").?);
    try std.testing.expectEqual(model.Value{ .float = 0.5 }, parseCValue("float", "0.50f").?);
    try std.testing.expectEqual(model.Value{ .int = -1 }, parseCValue(null, "-1").?);
    try std.testing.expectEqual(@as(?model.Value, null), parseCValue(null, "\"a string\""));
}

test "classifyLevel derives command level from first parameter's handle type" {
    const instance_param = [_]model.Member{.{ .name = "instance", .type = .{ .base = "VkInstance" } }};
    const device_param = [_]model.Member{.{ .name = "device", .type = .{ .base = "VkDevice" } }};
    try std.testing.expectEqual(model.CommandLevel.instance, classifyLevel(&instance_param));
    try std.testing.expectEqual(model.CommandLevel.device, classifyLevel(&device_param));
    try std.testing.expectEqual(model.CommandLevel.global, classifyLevel(&.{}));
}

test "zigCommandName strips leading vk and lowercases only the first letter" {
    var buf: [128]u8 = undefined;
    try std.testing.expectEqualStrings("createInstance", zigCommandName(&buf, "vkCreateInstance"));
}

test "zigTypeName strips leading Vk" {
    try std.testing.expectEqualStrings("InstanceCreateInfo", zigTypeName("VkInstanceCreateInfo"));
}

test "zigConstantName strips leading VK_" {
    try std.testing.expectEqualStrings("UUID_SIZE", zigConstantName("VK_UUID_SIZE"));
}
