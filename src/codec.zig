const std = @import("std");

const document_module = @import("document.zig");
const merge_module = @import("merge.zig");
const region_module = @import("region.zig");
const scanner_module = @import("scanner.zig");
const schema = @import("schema.zig");
const writer_module = @import("writer.zig");

const assert = std.debug.assert;

const Document = document_module.Document;
const KindSet = std.EnumSet(Kind);
const Merge = merge_module.Merge;
const Merged = merge_module.EntriesType(Document);
const Node = document_module.Node;
const Position = document_module.Position;
const Region = region_module.Region;
const Sources = merge_module.StackType(Document);
const Writer = writer_module.Writer;

pub const float_bytes_max: u32 = 32;
const float_point_max: i32 = 21;
const float_zeros_max: i32 = 6;
const integer_bytes_max: u32 = 24;
const kind_count = @typeInfo(Kind).@"enum".field_names.len;
const significand_digits_max: u32 = 17;
const type_depth_max: u32 = 64;

comptime {
    assert(type_depth_max >= 16);
    assert(kind_count == 7);
    assert(integer_bytes_max > std.math.log10_int(@as(u64, std.math.maxInt(u64))) + 2);
    assert(float_bytes_max >= 1 + @as(u32, float_point_max) + 2);
    assert(float_bytes_max >= 3 + @as(u32, float_zeros_max) + significand_digits_max);
}

pub const DecodeError = region_module.Error || MismatchError || error{MergesExceeded};

pub const DecodeOptions = struct {
    diagnostic: ?*Position = null,
    merge: Merge = .ignored,
    unknown_members: UnknownMembers = .ignored,

    pub const UnknownMembers = enum {
        ignored,
        refused,
    };
};

pub const EncodeOptions = struct {
    null_members: NullMembers = .omitted,

    pub const NullMembers = enum {
        emitted,
        omitted,
    };
};

pub const MismatchError = error{
    MemberMissing,
    MemberUnknown,
    Mismatch,
};

const Decoder = struct {
    document: *const Document,
    merge: Merge,
    node: Node,
    region: *Region,
    unknown_members: DecodeOptions.UnknownMembers,
};

const FloatForm = struct {
    digits: []const u8,
    point: i32,
    sign: bool,
};

const Kind = enum {
    boolean,
    float,
    integer,
    mapping,
    null_value,
    sequence,
    string,
};

const Shape = enum {
    boolean,
    choice,
    enumeration,
    float,
    integer,
    map,
    object,
    optional,
    sequence,
    string,
};

pub fn EntryType(comptime Value: type) type {
    return struct {
        key: []const u8,
        value: Value,
    };
}

fn shape_of(comptime T: type) Shape {
    switch (@typeInfo(T)) {
        .bool => return .boolean,
        .@"enum" => |enumeration| {
            if (enumeration.mode == .nonexhaustive) {
                @compileError("the enumeration " ++ @typeName(T) ++
                    " is non-exhaustive; declare an unrecognized member instead");
            }

            return .enumeration;
        },
        .float => return .float,
        .int => return .integer,
        .optional => return .optional,
        .pointer => |pointer| {
            if (pointer.size != .slice) {
                @compileError("the pointer type " ++ @typeName(T) ++ " is not a slice");
            }

            if (!pointer.attrs.@"const") {
                @compileError("the slice type " ++ @typeName(T) ++ " is not const");
            }

            return slice_shape(T, pointer.child);
        },
        .@"struct" => {
            if (entry_is(T)) {
                @compileError("the entry type " ++ @typeName(T) ++ " is coded only in a map");
            }

            return .object;
        },
        .@"union" => |choice| {
            if (choice.tag_type == null) {
                @compileError("the union " ++ @typeName(T) ++ " has no tag");
            }

            return .choice;
        },
        else => @compileError("the type " ++ @typeName(T) ++ " has no YAML shape"),
    }
}

fn slice_shape(comptime T: type, comptime Element: type) Shape {
    if (Element == u8) return .string;

    if (@sizeOf(Element) == 0) {
        @compileError("the type " ++ @typeName(T) ++ " holds elements of zero size");
    }

    if (@alignOf(Element) > region_module.alignment_bytes) {
        @compileError("the type " ++ @typeName(T) ++ " holds elements aligned past " ++
            std.fmt.comptimePrint("{d}", .{region_module.alignment_bytes}) ++ " bytes");
    }

    if (entry_is(Element)) return .map;
    return .sequence;
}

fn depth_valid(comptime T: type, comptime depth: u32) bool {
    comptime assert(depth <= type_depth_max);

    if (depth < type_depth_max) return true;

    @compileError("the type " ++ @typeName(T) ++ " nests deeper than " ++
        std.fmt.comptimePrint("{d}", .{type_depth_max}) ++ " levels or contains itself");
}

fn sentinel_check(comptime T: type) void {
    const pointer = @typeInfo(T).pointer;
    if (pointer.sentinel_ptr == null) return;

    @compileError("the type " ++ @typeName(T) ++ " has a sentinel that decode cannot write; " ++
        "use []const " ++ @typeName(pointer.child));
}

fn entry_is(comptime T: type) bool {
    if (@typeInfo(T) != .@"struct") return false;
    if (!@hasField(T, "value")) return false;
    return T == EntryType(@FieldType(T, "value"));
}

fn names_check(comptime T: type) void {
    if (!@hasDecl(T, "yaml")) return;

    for (@typeInfo(@TypeOf(T.yaml)).@"struct".field_names) |name| {
        if (!@hasField(T, name)) {
            @compileError("the type " ++ @typeName(T) ++ " names " ++ name ++
                " in its yaml declaration, which is not one of its fields");
        }
    }
}

fn name_of(comptime T: type, comptime field_name: []const u8) []const u8 {
    comptime assert(@hasField(T, field_name));

    names_check(T);

    if (@hasDecl(T, "yaml")) {
        if (@hasField(@TypeOf(T.yaml), field_name)) return @field(T.yaml, field_name);
    }

    return field_name;
}

fn names_of(comptime T: type) std.StaticStringMap(T) {
    const field_names = @typeInfo(T).@"enum".field_names;

    @setEvalBranchQuota(64 * field_names.len * field_names.len + 1000);

    var entries: [field_names.len]struct { []const u8, T } = undefined;
    var count: u32 = 0;

    for (field_names) |name| {
        if (std.mem.eql(u8, name, "unrecognized")) continue;

        entries[count] = .{ name_of(T, name), @field(T, name) };
        count += 1;
    }

    const result: std.StaticStringMap(T) = .initComptime(entries[0..count]);

    for (entries[0..count]) |entry| assert(result.get(entry[0]).? == entry[1]);

    return result;
}

fn kinds_of(comptime T: type) KindSet {
    if (T == void) return .initOne(.null_value);

    return switch (shape_of(T)) {
        .boolean => .initOne(.boolean),
        .choice => choice_kinds(T),
        .enumeration, .string => .initOne(.string),
        .float => .initOne(.float),
        .integer => .initOne(.integer),
        .map, .object => .initOne(.mapping),
        .optional => optional_kinds(T),
        .sequence => .initOne(.sequence),
    };
}

fn optional_kinds(comptime T: type) KindSet {
    var result = kinds_of(@typeInfo(T).optional.child);

    result.insert(.null_value);

    return result;
}

fn choice_kinds(comptime T: type) KindSet {
    const table = choice_table(T);

    var result: KindSet = .empty;

    for (table, 0..) |slot, index| {
        if (slot != null) result.insert(@fromBackingInt(index));
    }

    return result;
}

fn choice_table(comptime T: type) [kind_count]?u32 {
    const choice = @typeInfo(T).@"union";

    var table: [kind_count]?u32 = @splat(null);
    var float_index: ?u32 = null;

    for (choice.field_types, choice.field_names, 0..) |Payload, name, index| {
        const kinds = kinds_of(Payload);

        if (kinds.contains(.float)) float_index = index;

        for (std.enums.values(Kind)) |kind| {
            if (!kinds.contains(kind)) continue;

            if (table[@backingInt(kind)] != null) {
                @compileError("the union " ++ @typeName(T) ++ " has two variants that claim " ++
                    @tagName(kind) ++ ", one of them " ++ name);
            }

            table[@backingInt(kind)] = index;
        }
    }

    if (table[@backingInt(Kind.integer)] == null) table[@backingInt(Kind.integer)] = float_index;

    return table;
}

fn null_taken(comptime T: type) bool {
    return switch (shape_of(T)) {
        .choice => choice_table(T)[@backingInt(Kind.null_value)] != null,
        .optional => true,
        .boolean, .enumeration, .float, .integer, .map, .object, .sequence, .string => false,
    };
}

fn default_null_is(comptime T: type, comptime index: usize) bool {
    comptime assert(index < @typeInfo(T).@"struct".field_names.len);

    const structure = @typeInfo(T).@"struct";
    const Field = structure.field_types[index];
    if (shape_of(Field) != .optional) return false;

    const default = structure.field_attrs[index].defaultValue(Field) orelse return false;
    return default == null;
}

pub fn decode(
    comptime T: type,
    region: *Region,
    document: *const Document,
    node: Node,
    target: *T,
    options: DecodeOptions,
) DecodeError!void {
    comptime assert(@sizeOf(@TypeOf(options)) <= 16);
    assert(@backingInt(node) < document.node_count);
    assert(region.used <= region.top);

    const used = region.used;
    const top = region.top;

    var decoder: Decoder = .{
        .document = document,
        .merge = options.merge,
        .node = node,
        .region = region,
        .unknown_members = options.unknown_members,
    };

    element_decode(T, 0, &decoder, node, target) catch |err| {
        region.used = used;
        region.top = top;

        if (options.diagnostic) |diagnostic| diagnostic.* = document.position_of(decoder.node);

        return err;
    };

    assert(region.top == top);
    assert(region.used >= used);
}

fn element_decode(
    comptime T: type,
    comptime depth: u32,
    decoder: *Decoder,
    node: Node,
    target: *T,
) DecodeError!void {
    comptime assert(depth_valid(T, depth));
    assert(@backingInt(node) < decoder.document.node_count);

    decoder.node = node;

    if (kind_of(decoder.document, node) == .null_value) {
        if (comptime !null_taken(T)) return error.Mismatch;
    }

    try value_decode(T, depth, decoder, node, target);
}

fn value_decode(
    comptime T: type,
    comptime depth: u32,
    decoder: *Decoder,
    node: Node,
    target: *T,
) DecodeError!void {
    comptime assert(depth_valid(T, depth));
    assert(@backingInt(node) < decoder.document.node_count);

    const document = decoder.document;

    switch (comptime shape_of(T)) {
        .boolean => target.* = document.boolean_of(node) orelse return error.Mismatch,
        .choice => try choice_decode(T, depth + 1, decoder, node, target),
        .enumeration => target.* = try enumeration_of(T, document, node),
        .float => target.* = try float_of(T, document, node),
        .integer => target.* = try integer_of(T, document, node),
        .map => {
            comptime sentinel_check(T);

            try map_decode(T, depth + 1, decoder, node, target);
        },
        .object => try object_decode(T, depth + 1, decoder, node, target),
        .optional => try optional_decode(T, depth + 1, decoder, node, target),
        .sequence => {
            comptime sentinel_check(T);

            try sequence_decode(T, depth + 1, decoder, node, target);
        },
        .string => {
            comptime sentinel_check(T);

            target.* = try string_of(document, node);
        },
    }
}

fn optional_decode(
    comptime T: type,
    comptime depth: u32,
    decoder: *Decoder,
    node: Node,
    target: *T,
) DecodeError!void {
    comptime assert(shape_of(T) == .optional);
    comptime assert(depth_valid(T, depth));
    assert(@backingInt(node) < decoder.document.node_count);

    const Child = @typeInfo(T).optional.child;

    if (kind_of(decoder.document, node) == .null_value) {
        target.* = null;

        return;
    }

    var value: Child = undefined;

    try value_decode(Child, depth + 1, decoder, node, &value);

    target.* = value;
}

fn object_decode(
    comptime T: type,
    comptime depth: u32,
    decoder: *Decoder,
    node: Node,
    target: *T,
) DecodeError!void {
    comptime assert(shape_of(T) == .object);
    comptime assert(depth_valid(T, depth));
    assert(@backingInt(node) < decoder.document.node_count);

    if (decoder.document.kind_of(node) != .mapping) return error.Mismatch;

    comptime names_check(T);

    var sources: Sources = undefined;
    const list = try sources_of(decoder, node, &sources);

    if (decoder.unknown_members == .refused) try members_known_check(T, decoder, node, list);

    inline for (@typeInfo(T).@"struct".field_names, 0..) |name, index| {
        const wire_name = comptime name_of(T, name);

        if (member_of(decoder, node, list, wire_name)) |value| {
            try field_decode(T, index, depth, decoder, value, target);
        } else {
            try field_absent(T, index, decoder, node, &@field(target, name));
        }
    }
}

fn sources_of(decoder: *Decoder, mapping: Node, sources: *Sources) DecodeError![]const Node {
    assert(decoder.document.kind_of(mapping) == .mapping);
    assert(@backingInt(mapping) < decoder.document.node_count);

    sources.count = 0;

    if (decoder.merge == .ignored) return sources.nodes[0..0];

    const list = sources.flatten(decoder.document, mapping) catch |err| switch (err) {
        error.MergeInvalid => {
            decoder.node = sources.failure;

            return error.Mismatch;
        },
        error.MergesExceeded => |exceeded| {
            decoder.node = mapping;

            return exceeded;
        },
    };

    assert(list.len == sources.count);

    return list;
}

noinline fn members_known_check(
    comptime T: type,
    decoder: *Decoder,
    mapping: Node,
    list: []const Node,
) MismatchError!void {
    comptime assert(shape_of(T) == .object);
    assert(decoder.unknown_members == .refused);
    assert(decoder.document.kind_of(mapping) == .mapping);
    assert(list.len <= merge_module.source_count_max);

    const document = decoder.document;
    const wire_names = comptime wire_names_of(T);
    var merged: Merged = .init(document, mapping, list);
    var raw = document.entries(mapping);
    const step_count_max = merged.step_count_max;

    for (0..step_count_max) |_| {
        const entry = if (decoder.merge == .applied) merged.next() else raw.next();
        const pair = entry orelse return;
        const known = if (document.text_of(pair.key)) |key| wire_names.has(key) else false;

        if (!known) {
            decoder.node = pair.key;

            return error.MemberUnknown;
        }
    }

    unreachable;
}

fn wire_names_of(comptime T: type) std.StaticStringMap(void) {
    const field_names = @typeInfo(T).@"struct".field_names;

    @setEvalBranchQuota(64 * field_names.len * field_names.len + 1000);

    var entries: [field_names.len]struct { []const u8 } = undefined;

    for (field_names, &entries) |name, *entry| entry.* = .{name_of(T, name)};

    const result: std.StaticStringMap(void) = .initComptime(entries);

    for (field_names) |name| assert(result.has(name_of(T, name)));

    return result;
}

fn member_of(decoder: *const Decoder, mapping: Node, list: []const Node, key: []const u8) ?Node {
    assert(decoder.document.kind_of(mapping) == .mapping);
    assert(list.len <= merge_module.source_count_max);
    assert(key.len <= scanner_module.source_bytes_max);

    const document = decoder.document;
    if (decoder.merge == .ignored) return document.member(mapping, key);
    return merge_module.member_merged(Document, document, mapping, list, key);
}

fn field_absent(
    comptime T: type,
    comptime index: usize,
    decoder: *Decoder,
    mapping: Node,
    field: *@typeInfo(T).@"struct".field_types[index],
) MismatchError!void {
    const structure = @typeInfo(T).@"struct";

    comptime assert(index < structure.field_names.len);
    assert(decoder.document.kind_of(mapping) == .mapping);

    const Field = structure.field_types[index];

    if (comptime structure.field_attrs[index].defaultValue(Field)) |default| {
        field.* = default;
    } else {
        decoder.node = mapping;

        return error.MemberMissing;
    }
}

fn field_decode(
    comptime T: type,
    comptime index: usize,
    comptime depth: u32,
    decoder: *Decoder,
    node: Node,
    target: *T,
) DecodeError!void {
    comptime assert(index < @typeInfo(T).@"struct".field_names.len);
    comptime assert(depth_valid(T, depth));
    assert(@backingInt(node) < decoder.document.node_count);

    const structure = @typeInfo(T).@"struct";
    const Field = structure.field_types[index];
    const field = &@field(target, structure.field_names[index]);

    decoder.node = node;

    if (kind_of(decoder.document, node) == .null_value) {
        if (comptime !null_taken(Field)) return field_null_assign(T, index, field);
    }

    try value_decode(Field, depth + 1, decoder, node, field);
}

fn field_null_assign(
    comptime T: type,
    comptime index: usize,
    field: *@typeInfo(T).@"struct".field_types[index],
) MismatchError!void {
    const structure = @typeInfo(T).@"struct";

    comptime assert(index < structure.field_names.len);
    comptime assert(!null_taken(structure.field_types[index]));

    const Field = structure.field_types[index];

    if (comptime structure.field_attrs[index].defaultValue(Field)) |default| {
        field.* = default;
    } else {
        return error.Mismatch;
    }
}

fn sequence_decode(
    comptime T: type,
    comptime depth: u32,
    decoder: *Decoder,
    node: Node,
    target: *T,
) DecodeError!void {
    comptime assert(shape_of(T) == .sequence);
    comptime assert(depth_valid(T, depth));
    assert(@backingInt(node) < decoder.document.node_count);

    const Element = @typeInfo(T).pointer.child;
    const document = decoder.document;
    if (document.kind_of(node) != .sequence) return error.Mismatch;

    const count = document.count_of(node);
    if (count > decoder.region.unused_bytes()) return error.RegionFull;

    const elements = try decoder.region.reserve(Element, count);

    var items = document.items(node);

    for (elements) |*element| {
        const item = items.next() orelse break;

        try element_decode(Element, depth + 1, decoder, item, element);
    }

    assert(items.remaining == 0);

    target.* = elements;
}

fn map_decode(
    comptime T: type,
    comptime depth: u32,
    decoder: *Decoder,
    node: Node,
    target: *T,
) DecodeError!void {
    comptime assert(shape_of(T) == .map);
    comptime assert(depth_valid(T, depth));
    assert(@backingInt(node) < decoder.document.node_count);

    const Entry = @typeInfo(T).pointer.child;
    const Value = @FieldType(Entry, "value");
    const document = decoder.document;
    if (document.kind_of(node) != .mapping) return error.Mismatch;
    if (decoder.merge == .applied) return map_merged_decode(T, depth, decoder, node, target);

    const count = document.count_of(node);
    if (count > decoder.region.unused_bytes()) return error.RegionFull;

    const entries = try decoder.region.reserve(Entry, count);

    var iterator = document.entries(node);

    for (entries) |*entry| {
        const pair = iterator.next() orelse break;

        try entry_decode(Value, depth, decoder, pair, entry);
    }

    assert(iterator.remaining == 0);

    target.* = entries;
}

fn map_merged_decode(
    comptime T: type,
    comptime depth: u32,
    decoder: *Decoder,
    node: Node,
    target: *T,
) DecodeError!void {
    comptime assert(shape_of(T) == .map);
    comptime assert(depth_valid(T, depth));
    assert(decoder.merge == .applied);
    assert(@backingInt(node) < decoder.document.node_count);

    const Entry = @typeInfo(T).pointer.child;
    const Value = @FieldType(Entry, "value");
    const document = decoder.document;

    var sources: Sources = undefined;
    const list = try sources_of(decoder, node, &sources);
    var counter: Merged = .init(document, node, list);
    var count: u32 = 0;

    for (0..counter.step_count_max) |_| {
        _ = counter.next() orelse break;

        count += 1;
    }

    if (count > decoder.region.unused_bytes()) return error.RegionFull;

    const entries = try decoder.region.reserve(Entry, count);

    var iterator: Merged = .init(document, node, list);

    for (entries) |*entry| {
        const pair = iterator.next() orelse break;

        try entry_decode(Value, depth, decoder, pair, entry);
    }

    assert(entries.len == count);

    target.* = entries;
}

fn entry_decode(
    comptime Value: type,
    comptime depth: u32,
    decoder: *Decoder,
    pair: document_module.Entries.Entry,
    entry: *EntryType(Value),
) DecodeError!void {
    comptime assert(depth_valid(Value, depth));
    assert(@backingInt(pair.key) < decoder.document.node_count);

    const document = decoder.document;

    entry.key = document.text_of(pair.key) orelse {
        decoder.node = pair.key;

        return error.Mismatch;
    };

    try element_decode(Value, depth + 1, decoder, pair.value, &entry.value);
}

fn choice_decode(
    comptime T: type,
    comptime depth: u32,
    decoder: *Decoder,
    node: Node,
    target: *T,
) DecodeError!void {
    comptime assert(shape_of(T) == .choice);
    comptime assert(depth_valid(T, depth));
    assert(@backingInt(node) < decoder.document.node_count);

    const choice = @typeInfo(T).@"union";
    const table = comptime choice_table(T);
    const kind = kind_of(decoder.document, node);
    const index = table[@backingInt(kind)] orelse return error.Mismatch;

    switch (index) {
        inline 0...choice.field_names.len - 1 => |variant_index| {
            const name = choice.field_names[variant_index];
            const Payload = choice.field_types[variant_index];

            if (Payload == void) {
                assert(kind == .null_value);

                target.* = @unionInit(T, name, {});
            } else {
                var payload: Payload = undefined;

                try value_decode(Payload, depth + 1, decoder, node, &payload);

                target.* = @unionInit(T, name, payload);
            }
        },
        else => unreachable,
    }
}

fn kind_of(document: *const Document, node: Node) Kind {
    assert(@backingInt(node) < document.node_count);
    assert(document.root_count() > 0);

    if (document.text_of(node)) |text| return scalar_kind_of(document, node, text);

    return switch (document.kind_of(node)) {
        .mapping => .mapping,
        .scalar => unreachable,
        .sequence => .sequence,
    };
}

fn scalar_kind_of(document: *const Document, node: Node, text: []const u8) Kind {
    assert(@backingInt(node) < document.node_count);
    assert(document.kind_of(node) == .scalar);
    assert(text.len <= scanner_module.source_bytes_max);

    const tag = document.tag_of(node);
    const plain = document.style_of(node).scalar == .plain;

    const resolution = resolution: {
        if (tag.len > 0) break :resolution schema.tag_resolution_of(tag);
        if (!plain) break :resolution .string;

        break :resolution schema.resolution_of(text, document.schema);
    };

    return switch (resolution) {
        .boolean => .boolean,
        .float => .float,
        .integer => .integer,
        .null_value => .null_value,
        .string => .string,
    };
}

fn string_of(document: *const Document, node: Node) MismatchError![]const u8 {
    assert(@backingInt(node) < document.node_count);
    assert(kind_of(document, node) != .null_value);

    return document.text_of(node) orelse error.Mismatch;
}

fn integer_of(comptime T: type, document: *const Document, node: Node) MismatchError!T {
    comptime assert(@typeInfo(T) == .int);
    assert(@backingInt(node) < document.node_count);

    if (@typeInfo(T).int.bits > 64) {
        @compileError("the integer type " ++ @typeName(T) ++ " is wider than 64 bits");
    }

    if (kind_of(document, node) != .integer) return error.Mismatch;

    const text = document.text_of(node).?;
    return schema.integer_text_of(T, text, document.schema) orelse error.Mismatch;
}

fn float_of(comptime T: type, document: *const Document, node: Node) MismatchError!T {
    comptime assert(@typeInfo(T) == .float);
    assert(@backingInt(node) < document.node_count);

    if (@bitSizeOf(T) > 64) @compileError("the float type " ++ @typeName(T) ++ " is too wide");

    const value = document.float_of(node) orelse return error.Mismatch;
    const result: T = @floatCast(value);

    if (std.math.isFinite(value)) {
        if (!std.math.isFinite(result)) return error.Mismatch;
    }

    assert(std.math.isNan(result) == std.math.isNan(value));

    return result;
}

fn enumeration_of(comptime T: type, document: *const Document, node: Node) MismatchError!T {
    comptime assert(@typeInfo(T) == .@"enum");
    assert(@backingInt(node) < document.node_count);

    const text = document.text_of(node) orelse return error.Mismatch;
    const names = comptime names_of(T);

    return names.get(text) orelse enumeration_unknown(T);
}

fn enumeration_unknown(comptime T: type) MismatchError!T {
    comptime assert(@typeInfo(T) == .@"enum");

    if (comptime @hasField(T, "unrecognized")) {
        return .unrecognized;
    } else {
        return error.Mismatch;
    }
}

pub fn encode(
    comptime T: type,
    writer: *Writer,
    value: *const T,
    options: EncodeOptions,
) Writer.Error!void {
    comptime assert(@sizeOf(@TypeOf(options)) <= 16);
    assert(writer.depth <= writer_module.depth_max);
    assert(writer.options.indent >= 1);

    try enumeration_check(T, value);

    if (writer.document_state != .closed) return value_encode(T, 0, writer, value, &options);

    try writer.document_begin(&.{ .explicit = false });
    try value_encode(T, 0, writer, value, &options);
    try writer.document_end(&.{ .explicit = false });
}

fn value_encode(
    comptime T: type,
    comptime depth: u32,
    writer: *Writer,
    value: *const T,
    options: *const EncodeOptions,
) Writer.Error!void {
    comptime assert(depth_valid(T, depth));
    assert(writer.depth <= writer_module.depth_max);

    switch (comptime shape_of(T)) {
        .boolean => try plain_write(writer, if (value.*) "true" else "false"),
        .choice => try choice_encode(T, depth + 1, writer, value, options),
        .enumeration => try string_write(writer, try enumeration_text(T, value)),
        .float => try float_encode(T, writer, value),
        .integer => try integer_encode(T, writer, value),
        .map => try map_encode(T, depth + 1, writer, value, options),
        .object => try object_encode(T, depth + 1, writer, value, options),
        .optional => try optional_encode(T, depth + 1, writer, value, options),
        .sequence => try sequence_encode(T, depth + 1, writer, value, options),
        .string => try string_write(writer, value.*),
    }
}

fn plain_write(writer: *Writer, text: []const u8) Writer.Error!void {
    assert(text.len > 0);
    assert(schema.resolution_of(text, .core) != .string);

    try writer.scalar(&.{ .style = .plain, .text = text });
}

fn string_write(writer: *Writer, text: []const u8) Writer.Error!void {
    assert(text.len <= scanner_module.source_bytes_max);
    assert(writer.depth <= writer_module.depth_max);

    try writer.scalar(&.{ .style = schema.string_style_of(text), .text = text });
}

fn enumeration_text(comptime T: type, value: *const T) Writer.ValueError![]const u8 {
    comptime assert(@typeInfo(T) == .@"enum");

    switch (value.*) {
        inline else => |tag| {
            if (comptime std.mem.eql(u8, @tagName(tag), "unrecognized")) {
                return error.EnumerationUnrecognized;
            } else {
                return comptime name_of(T, @tagName(tag));
            }
        },
    }
}

fn enumeration_check(comptime T: type, value: *const T) Writer.ValueError!void {
    switch (comptime shape_of(T)) {
        .enumeration => {
            if (comptime @hasField(T, "unrecognized")) {
                if (value.* == .unrecognized) return error.EnumerationUnrecognized;
            }
        },
        .optional => {
            const Child = @typeInfo(T).optional.child;
            if (comptime shape_of(Child) != .enumeration) return;
            if (comptime !@hasField(Child, "unrecognized")) return;

            if (value.*) |child| {
                if (child == .unrecognized) return error.EnumerationUnrecognized;
            }
        },
        .boolean, .choice, .float, .integer, .map, .object, .sequence, .string => {},
    }
}

fn float_encode(comptime T: type, writer: *Writer, value: *const T) Writer.Error!void {
    comptime assert(@typeInfo(T) == .float);
    assert(writer.depth <= writer_module.depth_max);

    if (@bitSizeOf(T) > 64) @compileError("the float type " ++ @typeName(T) ++ " is too wide");

    if (std.math.isNan(value.*)) return plain_write(writer, ".nan");
    if (std.math.isPositiveInf(value.*)) return plain_write(writer, ".inf");
    if (std.math.isNegativeInf(value.*)) return plain_write(writer, "-.inf");

    var buffer: [float_bytes_max]u8 = undefined;

    try plain_write(writer, float_text_render(T, &buffer, value.*));
}

pub fn float_text_render(comptime T: type, buffer: *[float_bytes_max]u8, value: T) []const u8 {
    comptime assert(@typeInfo(T) == .float);
    comptime assert(@bitSizeOf(T) <= 64);
    assert(std.math.isFinite(value));

    var digits: [integer_bytes_max]u8 = undefined;
    var sink: std.Io.Writer = .fixed(buffer);
    const form = float_form_of(T, value, &digits);

    float_form_write(&sink, form) catch |err| switch (err) {
        error.WriteFailed => unreachable,
    };

    const result = sink.buffered();

    assert(std.mem.findScalar(u8, result, '.') != null);
    assert(result.len <= float_bytes_max);

    return result;
}

fn float_form_of(comptime T: type, value: T, digits: *[integer_bytes_max]u8) FloatForm {
    comptime assert(@typeInfo(T) == .float);
    assert(std.math.isFinite(value));

    const Bits = @Int(.unsigned, @bitSizeOf(T));

    const decimal = std.fmt.float.binaryToDecimal(
        u64,
        @as(Bits, @bitCast(value)),
        std.math.floatMantissaBits(T),
        std.math.floatExponentBits(T),
        false,
        &std.fmt.float.Backend64_TablesFull,
    );

    const text = std.mem.print(digits, "{d}", .{decimal.mantissa}) catch |err| switch (err) {
        error.NoSpaceLeft => unreachable,
    };

    const point = @as(i32, @intCast(text.len)) + decimal.exponent;
    const result: FloatForm = .{ .digits = text, .point = point, .sign = decimal.sign };

    assert(result.digits.len >= 1);
    assert(result.digits.len <= significand_digits_max);
    assert(result.sign == std.math.signbit(value));

    return result;
}

fn float_form_write(sink: *std.Io.Writer, form: FloatForm) std.Io.Writer.Error!void {
    assert(form.digits.len >= 1);
    assert(form.digits.len <= significand_digits_max);

    const positional = form.point > -float_zeros_max and form.point <= float_point_max;

    if (form.sign) try sink.writeByte('-');

    if (positional) {
        try float_positional_write(sink, form);
    } else {
        try float_exponent_write(sink, form);
    }
}

fn float_positional_write(sink: *std.Io.Writer, form: FloatForm) std.Io.Writer.Error!void {
    assert(form.point > -float_zeros_max);
    assert(form.point <= float_point_max);

    const count: i32 = @intCast(form.digits.len);

    if (form.point <= 0) {
        try sink.writeAll("0.");
        try sink.splatByteAll('0', @intCast(-form.point));
        try sink.writeAll(form.digits);
    } else if (form.point < count) {
        const split: u32 = @intCast(form.point);

        try sink.writeAll(form.digits[0..split]);
        try sink.writeByte('.');
        try sink.writeAll(form.digits[split..]);
    } else {
        try sink.writeAll(form.digits);
        try sink.splatByteAll('0', @intCast(form.point - count));
        try sink.writeAll(".0");
    }
}

fn float_exponent_write(sink: *std.Io.Writer, form: FloatForm) std.Io.Writer.Error!void {
    assert(form.digits.len >= 1);
    assert(form.digits[0] != '0');

    const exponent = form.point - 1;
    const fraction = if (form.digits.len > 1) form.digits[1..] else "0";

    try sink.print("{c}.{s}e{c}{d}", .{
        form.digits[0],
        fraction,
        @as(u8, if (exponent < 0) '-' else '+'),
        @abs(exponent),
    });
}

fn integer_encode(comptime T: type, writer: *Writer, value: *const T) Writer.Error!void {
    comptime assert(@typeInfo(T) == .int);
    assert(writer.depth <= writer_module.depth_max);

    if (@typeInfo(T).int.bits > 64) {
        @compileError("the integer type " ++ @typeName(T) ++ " is wider than 64 bits");
    }

    var buffer: [integer_bytes_max]u8 = undefined;

    const text = std.mem.print(&buffer, "{d}", .{value.*}) catch |err| switch (err) {
        error.NoSpaceLeft => unreachable,
    };

    try plain_write(writer, text);
}

fn optional_encode(
    comptime T: type,
    comptime depth: u32,
    writer: *Writer,
    value: *const T,
    options: *const EncodeOptions,
) Writer.Error!void {
    comptime assert(shape_of(T) == .optional);
    comptime assert(depth_valid(T, depth));

    const Child = @typeInfo(T).optional.child;

    if (value.*) |*child| {
        try value_encode(Child, depth + 1, writer, child, options);
    } else {
        try plain_write(writer, "null");
    }
}

fn object_encode(
    comptime T: type,
    comptime depth: u32,
    writer: *Writer,
    value: *const T,
    options: *const EncodeOptions,
) Writer.Error!void {
    comptime assert(shape_of(T) == .object);
    comptime assert(depth_valid(T, depth));

    const structure = @typeInfo(T).@"struct";

    comptime names_check(T);

    try writer.mapping_begin(&.{ .style = .block });

    inline for (structure.field_names, structure.field_types, 0..) |name, Field, index| {
        if (!member_omitted(T, index, value, options)) {
            const field = &@field(value, name);

            try enumeration_check(Field, field);
            try string_write(writer, comptime name_of(T, name));
            try value_encode(Field, depth + 1, writer, field, options);
        }
    }

    try writer.mapping_end();
}

fn member_omitted(
    comptime T: type,
    comptime index: usize,
    value: *const T,
    options: *const EncodeOptions,
) bool {
    const structure = @typeInfo(T).@"struct";

    comptime assert(index < structure.field_names.len);

    if (options.null_members == .emitted) return false;
    if (comptime !default_null_is(T, index)) return false;
    return @field(value, structure.field_names[index]) == null;
}

fn sequence_encode(
    comptime T: type,
    comptime depth: u32,
    writer: *Writer,
    value: *const T,
    options: *const EncodeOptions,
) Writer.Error!void {
    comptime assert(shape_of(T) == .sequence);
    comptime assert(depth_valid(T, depth));
    assert(value.len <= std.math.maxInt(u32));

    const Element = @typeInfo(T).pointer.child;

    try writer.sequence_begin(&.{ .style = .block });

    for (value.*) |*item| {
        try enumeration_check(Element, item);
        try value_encode(Element, depth + 1, writer, item, options);
    }

    try writer.sequence_end();
}

fn map_encode(
    comptime T: type,
    comptime depth: u32,
    writer: *Writer,
    value: *const T,
    options: *const EncodeOptions,
) Writer.Error!void {
    comptime assert(shape_of(T) == .map);
    comptime assert(depth_valid(T, depth));
    assert(value.len <= std.math.maxInt(u32));

    const Value = @FieldType(@typeInfo(T).pointer.child, "value");

    try writer.mapping_begin(&.{ .style = .block });

    for (value.*) |*entry| {
        try enumeration_check(Value, &entry.value);
        try string_write(writer, entry.key);
        try value_encode(Value, depth + 1, writer, &entry.value, options);
    }

    try writer.mapping_end();
}

fn choice_encode(
    comptime T: type,
    comptime depth: u32,
    writer: *Writer,
    value: *const T,
    options: *const EncodeOptions,
) Writer.Error!void {
    comptime assert(shape_of(T) == .choice);
    comptime assert(depth_valid(T, depth));

    switch (value.*) {
        inline else => |*payload| {
            const Payload = @TypeOf(payload.*);

            if (Payload == void) {
                try plain_write(writer, "null");
            } else {
                try value_encode(Payload, depth + 1, writer, payload, options);
            }
        },
    }
}

const testing = std.testing;

const test_output_bytes: u32 = 16 * 1024;
const test_region_bytes: u32 = 64 * 1024;

const test_capacity: document_module.Capacity = .{
    .anchor_count_max = 16,
    .comment_count_max = null,
    .node_count_max = 1024,
    .text_bytes_max = 16 * 1024,
};

const test_decode_options: DecodeOptions = .{ .diagnostic = null };
const test_encode_options: EncodeOptions = .{ .null_members = .omitted };

const test_writer_options: Writer.Options = .{
    .indent = 2,
    .layout = .preserve,
    .sequence_indentless = false,
    .utf8 = .checked,
    .version_directive = false,
    .width = 0,
};

const TestDocument = document_module.DocumentType(test_capacity);

const TestProtocol = enum {
    sctp,
    tcp,
    udp,
    unrecognized,

    pub const yaml = .{ .sctp = "SCTP", .tcp = "TCP", .udp = "UDP" };
};

const TestPort = struct {
    port_private: ?u16 = null,
    port_public: ?u16 = null,
    protocol: ?TestProtocol = null,

    pub const yaml = .{
        .port_private = "PrivatePort",
        .port_public = "PublicPort",
        .protocol = "Type",
    };
};

const TestContainer = struct {
    created: ?i64 = null,
    id: ?[]const u8 = null,
    labels: ?[]const EntryType([]const u8) = null,
    names: ?[]const []const u8 = null,
    ports: ?[]const TestPort = null,
    processes: ?[]const []const []const u8 = null,
    ratio: ?f64 = null,
    running: ?bool = null,

    pub const yaml = .{
        .created = "Created",
        .id = "Id",
        .labels = "Labels",
        .names = "Names",
        .ports = "Ports",
        .processes = "Processes",
        .ratio = "Ratio",
        .running = "Running",
    };
};

const TestValue = union(enum) {
    count: i64,
    flag: bool,
    label: []const u8,
    list: []const u32,
    none,
    ratio: f64,
    record: TestPort,
};

const TestTicket = struct {
    id: u64,
    owner: ?[]const u8,
    port: u16 = 8080,
    state: TestValue,

    pub const yaml = .{ .owner = "Owner" };
};

const TestFixture = struct {
    buffer: [test_region_bytes]u8 align(region_module.alignment_bytes),
    document: TestDocument,
    output: [test_output_bytes]u8,
    region: Region,
    sink: std.Io.Writer,
    writer: Writer,

    fn create() !*TestFixture {
        assert(test_region_bytes >= region_module.alignment_bytes);
        assert(test_output_bytes > 0);

        const fixture = try testing.allocator.create(TestFixture);

        fixture.region = .init(&fixture.buffer);

        assert(fixture.region.used == 0);

        return fixture;
    }

    fn root_parse(fixture: *TestFixture, source: []const u8) !Node {
        assert(source.len < test_capacity.text_bytes_max);
        assert(fixture.region.used <= fixture.region.top);

        try fixture.document.parse(source, .{ .schema = .core });

        return fixture.document.root(0);
    }

    fn decoded(fixture: *TestFixture, comptime T: type, source: []const u8, target: *T) !void {
        assert(source.len < test_capacity.text_bytes_max);
        assert(fixture.region.used <= fixture.region.top);

        const root = try fixture.root_parse(source);
        const document = &fixture.document.document;

        try decode(T, &fixture.region, document, root, target, test_decode_options);
    }

    fn encoded(
        fixture: *TestFixture,
        comptime T: type,
        value: *const T,
        options: EncodeOptions,
    ) ![]const u8 {
        comptime assert(@sizeOf(@TypeOf(options)) <= 16);
        assert(fixture.output.len == test_output_bytes);

        fixture.sink = .fixed(&fixture.output);

        fixture.writer.init(&fixture.sink, test_writer_options);

        try encode(T, &fixture.writer, value, options);

        fixture.writer.finish();

        return fixture.sink.buffered();
    }
};

test "a nested document decodes into the model and unknown members are ignored" {
    const fixture = try TestFixture.create();
    defer testing.allocator.destroy(fixture);

    const source =
        \\Id: 8dfafdbc3a40
        \\Names: [/boring_feynman]
        \\Created: 1367854155
        \\Unknown: {Nested: [1, 2, {Deep: ~}]}
        \\Running: true
        \\Ratio: 0.25
        \\Ports:
        \\  - {PrivatePort: 2222, PublicPort: 3333, Type: TCP}
        \\  - PrivatePort: 0x50
        \\    Type: QUIC
        \\Labels:
        \\  com.example.vendor: Acme é
        \\Processes: [[root, '13642'], []]
        \\
    ;

    var container: TestContainer = undefined;

    try fixture.decoded(TestContainer, source, &container);

    try testing.expectEqualStrings("8dfafdbc3a40", container.id.?);
    try testing.expectEqualStrings("/boring_feynman", container.names.?[0]);
    try testing.expectEqual(@as(i64, 1367854155), container.created.?);
    try testing.expect(container.running.?);
    try testing.expectEqual(@as(f64, 0.25), container.ratio.?);
    try testing.expectEqual(@as(usize, 2), container.ports.?.len);
    try testing.expectEqual(@as(u16, 3333), container.ports.?[0].port_public.?);
    try testing.expectEqual(TestProtocol.tcp, container.ports.?[0].protocol.?);
    try testing.expectEqual(@as(u16, 80), container.ports.?[1].port_private.?);
    try testing.expectEqual(@as(?u16, null), container.ports.?[1].port_public);
    try testing.expectEqual(TestProtocol.unrecognized, container.ports.?[1].protocol.?);
    try testing.expectEqualStrings("com.example.vendor", container.labels.?[0].key);
    try testing.expectEqualStrings("Acme \u{e9}", container.labels.?[0].value);
    try testing.expectEqualStrings("13642", container.processes.?[0][1]);
    try testing.expectEqual(@as(usize, 0), container.processes.?[1].len);
}

test "a required member that is missing is MemberMissing at the mapping that lacks it" {
    const Envelope = struct {
        ticket: TestTicket,

        pub const yaml = .{};
    };

    const fixture = try TestFixture.create();
    defer testing.allocator.destroy(fixture);

    const missing = [_][]const u8{
        "ticket:\n  Owner: a\n  state: 1\n",
        "ticket:\n  id: 1\n  state: 1\n",
        "ticket:\n  id: 1\n  Owner: a\n  port: 2\n",
        "ticket: {}\n",
    };

    for (missing) |source| {
        var envelope: Envelope = undefined;
        var diagnostic: Position = undefined;
        const root = try fixture.root_parse(source);
        const document = &fixture.document.document;

        const decoded = decode(Envelope, &fixture.region, document, root, &envelope, .{
            .diagnostic = &diagnostic,
        });

        const ticket = fixture.document.member(root, "ticket") orelse return error.TicketMissing;

        try testing.expectError(error.MemberMissing, decoded);
        try testing.expectEqual(fixture.document.position_of(ticket), diagnostic);
        try testing.expect(diagnostic.line <= 2);
    }

    var envelope: Envelope = undefined;

    try fixture.decoded(Envelope, "ticket: {id: 1, Owner: a, state: 2}\n", &envelope);

    try testing.expectEqual(@as(u64, 1), envelope.ticket.id);
    try testing.expectEqual(@as(u16, 8080), envelope.ticket.port);
    try testing.expectEqual(@as(i64, 2), envelope.ticket.state.count);
}

test "null keeps a declared default, nulls an optional, and refuses a required value" {
    const fixture = try TestFixture.create();
    defer testing.allocator.destroy(fixture);

    var ticket: TestTicket = undefined;

    try fixture.decoded(TestTicket, "id: 3\nOwner: ~\nport: null\nstate:\n", &ticket);

    try testing.expectEqual(@as(u64, 3), ticket.id);
    try testing.expectEqual(@as(?[]const u8, null), ticket.owner);
    try testing.expectEqual(@as(u16, 8080), ticket.port);
    try testing.expectEqual(TestValue.none, ticket.state);

    const refused = [_][]const u8{
        "id: ~\nOwner: a\nstate: 1\n",
        "~\n",
        "[~]\n",
    };

    for (refused) |source| {
        try testing.expectError(error.Mismatch, fixture.decoded(TestTicket, source, &ticket));
    }

    var ports: []const u16 = undefined;

    try testing.expectError(error.Mismatch, fixture.decoded([]const u16, "[1, ~]\n", &ports));
}

test "an enumeration falls back to unrecognized only when the type declares it" {
    const Color = enum {
        blue,
        red,

        pub const yaml = .{ .red = "Red" };
    };

    const fixture = try TestFixture.create();
    defer testing.allocator.destroy(fixture);

    var color: Color = undefined;

    try fixture.decoded(Color, "Red\n", &color);
    try testing.expectEqual(Color.red, color);
    try fixture.decoded(Color, "'blue'\n", &color);
    try testing.expectEqual(Color.blue, color);

    for ([_][]const u8{ "red\n", "green\n", "~\n", "[Red]\n" }) |source| {
        try testing.expectError(error.Mismatch, fixture.decoded(Color, source, &color));
    }

    var protocol: TestProtocol = undefined;

    try fixture.decoded(TestProtocol, "QUIC\n", &protocol);
    try testing.expectEqual(TestProtocol.unrecognized, protocol);

    const blue = try fixture.encoded(Color, &color, test_encode_options);

    try testing.expectEqualStrings("blue\n", blue);

    const port: TestPort = .{ .port_private = 1, .protocol = .unrecognized };
    const refused = fixture.encoded(TestPort, &port, test_encode_options);

    try testing.expectError(error.EnumerationUnrecognized, refused);
    try testing.expectEqualStrings("PrivatePort: 1", fixture.sink.buffered());

    const alone = fixture.encoded(TestProtocol, &protocol, test_encode_options);

    try testing.expectError(error.EnumerationUnrecognized, alone);
    try testing.expectEqual(@as(usize, 0), fixture.sink.buffered().len);
}

test "a union picks its variant by core resolution and encodes its payload" {
    const fixture = try TestFixture.create();
    defer testing.allocator.destroy(fixture);

    const sources = [_][]const u8{
        "true\n",
        "-3\n",
        "x\n",
        "'7'\n",
        "- 1\n- 2\n",
        "PrivatePort: 1\n",
        "null\n",
        "2.5\n",
    };

    const tags = [_]std.meta.Tag(TestValue){
        .flag,
        .count,
        .label,
        .label,
        .list,
        .record,
        .none,
        .ratio,
    };

    for (sources, tags) |source, tag| {
        var value: TestValue = undefined;

        try fixture.decoded(TestValue, source, &value);
        try testing.expectEqual(tag, std.meta.activeTag(value));

        const encoded = try fixture.encoded(TestValue, &value, test_encode_options);

        try testing.expectEqualStrings(source, encoded);
    }

    var value: TestValue = undefined;

    try testing.expectError(error.Mismatch, fixture.decoded(TestValue, "[a]\n", &value));

    const Measure = union(enum) {
        label: []const u8,
        ratio: f64,
    };

    var measure: Measure = undefined;

    try fixture.decoded(Measure, "3\n", &measure);
    try testing.expectEqual(@as(f64, 3), measure.ratio);
    try testing.expectError(error.Mismatch, fixture.decoded(Measure, "~\n", &measure));
}

test "a union whose variants claim one kind still encodes, because only decode needs the table" {
    const Size = union(enum) {
        big: u64,
        small: u8,
    };

    const fixture = try TestFixture.create();
    defer testing.allocator.destroy(fixture);

    const size: Size = .{ .small = 7 };

    try testing.expectEqualStrings("7\n", try fixture.encoded(Size, &size, test_encode_options));
}

test "an alias decodes as the node its anchor names" {
    const Network = struct {
        base: TestPort,
        copies: []const TestPort,

        pub const yaml = .{};
    };

    const fixture = try TestFixture.create();
    defer testing.allocator.destroy(fixture);

    const source =
        \\base: &base {PrivatePort: 22, Type: TCP}
        \\copies: [*base, *base]
        \\
    ;

    var network: Network = undefined;

    try fixture.decoded(Network, source, &network);

    try testing.expectEqual(@as(usize, 2), network.copies.len);
    try testing.expectEqualDeep(network.base, network.copies[0]);
    try testing.expectEqualDeep(network.base, network.copies[1]);
    try testing.expectEqual(@as(u16, 22), network.copies[1].port_private.?);
}

test "a document larger than the region is RegionFull and the region is restored" {
    const fixture = try TestFixture.create();
    defer testing.allocator.destroy(fixture);

    var buffer: [96]u8 align(region_module.alignment_bytes) = undefined;
    var region: Region = .init(&buffer);
    var names: []const []const u8 = undefined;
    var rows: []const []const []const u8 = undefined;

    const flat = try fixture.root_parse("[a, b, c, d, e, f, g]\n");
    const document = &fixture.document.document;

    const refused = decode([]const []const u8, &region, document, flat, &names, .{
        .diagnostic = null,
    });

    try testing.expectError(error.RegionFull, refused);
    try testing.expectEqual(@as(u32, 0), region.used);
    try testing.expectEqual(@as(u32, 96), region.top);

    _ = try region.reserve(u8, 3);

    const nested = try fixture.root_parse("[[a, b], [c, d, e, f]]\n");

    const partial = decode([]const []const []const u8, &region, document, nested, &rows, .{
        .diagnostic = null,
    });

    try testing.expectError(error.RegionFull, partial);
    try testing.expectEqual(@as(u32, 3), region.used);
    try testing.expectEqual(@as(u32, 96), region.top);

    const small = try fixture.root_parse("[a, b]\n");

    try decode([]const []const u8, &region, document, small, &names, test_decode_options);
    try testing.expectEqualStrings("b", names[1]);
}

test "a node of the wrong kind is a mismatch reported at its own position" {
    const fixture = try TestFixture.create();
    defer testing.allocator.destroy(fixture);

    const Case = struct {
        line: u32,
        source: []const u8,
    };

    const cases = [_]Case{
        .{ .line = 1, .source = "Created: yesterday\n" },
        .{ .line = 2, .source = "Id: a\nRunning: 1\n" },
        .{ .line = 1, .source = "Names: one\n" },
        .{ .line = 3, .source = "Ports:\n  - PrivatePort: 1\n  - PrivatePort: 70000\n" },
        .{ .line = 1, .source = "Labels: [a]\n" },
        .{ .line = 1, .source = "Labels: {[k]: v}\n" },
        .{ .line = 1, .source = "Ratio: fast\n" },
        .{ .line = 1, .source = "Created: '12'\n" },
        .{ .line = 1, .source = "Created: 1_000\n" },
        .{ .line = 1, .source = "- 1\n" },
    };

    for (cases) |case| {
        var container: TestContainer = undefined;
        var diagnostic: Position = undefined;
        const root = try fixture.root_parse(case.source);
        const document = &fixture.document.document;

        const decoded = decode(TestContainer, &fixture.region, document, root, &container, .{
            .diagnostic = &diagnostic,
        });

        try testing.expectError(error.Mismatch, decoded);
        try testing.expectEqual(case.line, diagnostic.line);
    }
}

test "a string that reads as another type is quoted and reads back as a string" {
    const fixture = try TestFixture.create();
    defer testing.allocator.destroy(fixture);

    const texts = [_][]const u8{
        "true",
        "1",
        "null",
        "",
        "yes",
        "-.inf",
        "12345678901234567890",
        "0x1F",
        "warbler",
    };

    const expected = [_][]const u8{
        "'true'\n",
        "'1'\n",
        "'null'\n",
        "''\n",
        "'yes'\n",
        "'-.inf'\n",
        "'12345678901234567890'\n",
        "'0x1F'\n",
        "warbler\n",
    };

    for (texts, expected) |text, bytes| {
        const encoded = try fixture.encoded([]const u8, &text, test_encode_options);

        try testing.expectEqualStrings(bytes, encoded);

        var decoded: []const u8 = undefined;

        try fixture.decoded([]const u8, encoded, &decoded);
        try testing.expectEqualStrings(text, decoded);
    }
}

test "a multi-line string is written as a literal block" {
    const Note = struct {
        text: []const u8,

        pub const yaml = .{};
    };

    const fixture = try TestFixture.create();
    defer testing.allocator.destroy(fixture);

    const notes = [_]Note{
        .{ .text = "line one\nline two\n" },
        .{ .text = "a\nb" },
        .{ .text = " indented\nnext\n\n" },
    };

    const expected = [_][]const u8{
        "text: |\n  line one\n  line two\n",
        "text: |-\n  a\n  b\n",
        "text: |2+\n   indented\n  next\n\n",
    };

    for (notes, expected) |note, bytes| {
        const encoded = try fixture.encoded(Note, &note, test_encode_options);

        try testing.expectEqualStrings(bytes, encoded);

        var decoded: Note = undefined;

        try fixture.decoded(Note, encoded, &decoded);
        try testing.expectEqualStrings(note.text, decoded.text);
    }
}

test "a float is positional from 1e-6 below 1e21 and reads back to the same bits" {
    const fixture = try TestFixture.create();
    defer testing.allocator.destroy(fixture);

    const values = [_]f64{
        0.25,
        100,
        1000,
        1e300,
        5e-324,
        -0.0,
        0,
        123456789.125,
        1.7976931348623157e308,
        1.5e9,
        -2.5e-3,
        70000,
        1e20,
        1e21,
        1e-6,
        1e-7,
        1.23e-18,
        std.math.inf(f64),
        -std.math.inf(f64),
    };

    const texts = [_][]const u8{
        "0.25\n",
        "100.0\n",
        "1000.0\n",
        "1.0e+300\n",
        "5.0e-324\n",
        "-0.0\n",
        "0.0\n",
        "123456789.125\n",
        "1.7976931348623157e+308\n",
        "1500000000.0\n",
        "-0.0025\n",
        "70000.0\n",
        "100000000000000000000.0\n",
        "1.0e+21\n",
        "0.000001\n",
        "1.0e-7\n",
        "1.23e-18\n",
        ".inf\n",
        "-.inf\n",
    };

    for (values, texts) |value, text| {
        const encoded = try fixture.encoded(f64, &value, test_encode_options);

        try testing.expectEqualStrings(text, encoded);

        const schemas = [_]schema.Schema{ .core, .v1_1, .json };
        const finite = std.math.isFinite(value);

        for (schemas[0..if (finite) 3 else 2]) |read| {
            var decoded: f64 = undefined;

            try fixture.document.parse(encoded, .{ .schema = read });

            const root = fixture.document.root(0);
            const document = &fixture.document.document;

            try decode(f64, &fixture.region, document, root, &decoded, test_decode_options);
            try testing.expectEqual(@as(u64, @bitCast(value)), @as(u64, @bitCast(decoded)));
        }
    }
}

test "an f32 takes its own shortest form, and a value past its range is a mismatch" {
    const fixture = try TestFixture.create();
    defer testing.allocator.destroy(fixture);

    const narrow = [_]f32{ 0.1, 3.4028235e38, 1e-45, 16777216, 70000, 1e-7 };

    const narrow_texts = [_][]const u8{
        "0.1\n",
        "3.4028235e+38\n",
        "1.0e-45\n",
        "16777216.0\n",
        "70000.0\n",
        "1.0e-7\n",
    };

    for (narrow, narrow_texts) |value, text| {
        const encoded = try fixture.encoded(f32, &value, test_encode_options);

        try testing.expectEqualStrings(text, encoded);

        var decoded: f32 = undefined;

        try fixture.decoded(f32, encoded, &decoded);
        try testing.expectEqual(@as(u32, @bitCast(value)), @as(u32, @bitCast(decoded)));
    }

    const nan = std.math.nan(f64);
    var decoded: f64 = undefined;

    try testing.expectEqualStrings(".nan\n", try fixture.encoded(f64, &nan, test_encode_options));
    try fixture.decoded(f64, ".nan\n", &decoded);
    try testing.expect(std.math.isNan(decoded));

    var narrowed: f32 = undefined;

    try testing.expectError(error.Mismatch, fixture.decoded(f32, "1e300\n", &narrowed));
}

test "text that is not UTF-8 is refused with TextInvalid" {
    const fixture = try TestFixture.create();
    defer testing.allocator.destroy(fixture);

    const text: []const u8 = "caf\xe9";
    const refused = fixture.encoded([]const u8, &text, test_encode_options);

    try testing.expectError(error.TextInvalid, refused);
    try testing.expectEqual(@as(usize, 0), fixture.sink.buffered().len);
}

test "encoding, parsing, and decoding reproduce the value" {
    const labels = [_]EntryType([]const u8){
        .{ .key = "quote'key", .value = "line\nbreak" },
        .{ .key = "plain", .value = "" },
        .{ .key = "yes", .value = "-.inf" },
    };

    const ports = [_]TestPort{
        .{ .port_private = 80, .port_public = null, .protocol = .udp },
        .{},
    };

    const original: TestContainer = .{
        .created = -42,
        .id = "\u{1f600} x",
        .labels = &labels,
        .names = &.{ "/a", "- b", "#c", " padded " },
        .ports = &ports,
        .processes = &.{ &.{ "root", "1" }, &.{} },
        .ratio = 0.5,
        .running = false,
    };

    const fixture = try TestFixture.create();
    defer testing.allocator.destroy(fixture);

    const encoded = try fixture.encoded(TestContainer, &original, test_encode_options);

    var decoded: TestContainer = undefined;

    try fixture.decoded(TestContainer, encoded, &decoded);
    try testing.expectEqualDeep(original, decoded);

    const tickets = [_]TestTicket{
        .{ .id = 1, .owner = null, .state = .none },
        .{ .id = 2, .owner = "x", .port = 1, .state = .{ .list = &.{ 3, 4 } } },
        .{ .id = 3, .owner = "y", .state = .{ .record = .{ .protocol = .sctp } } },
    };

    const encoded_tickets = try fixture.encoded([]const TestTicket, &tickets[0..], .{
        .null_members = .emitted,
    });

    var decoded_tickets: []const TestTicket = undefined;

    try fixture.decoded([]const TestTicket, encoded_tickets, &decoded_tickets);
    try testing.expectEqualDeep(@as([]const TestTicket, &tickets), decoded_tickets);
}

test "absent optional members are omitted unless nulls are emitted" {
    const fixture = try TestFixture.create();
    defer testing.allocator.destroy(fixture);

    const port: TestPort = .{ .port_private = 22 };
    const omitted = try fixture.encoded(TestPort, &port, test_encode_options);

    try testing.expectEqualStrings("PrivatePort: 22\n", omitted);

    const emitted = try fixture.encoded(TestPort, &port, .{ .null_members = .emitted });

    try testing.expectEqualStrings("PrivatePort: 22\nPublicPort: null\nType: null\n", emitted);

    const ticket: TestTicket = .{ .id = 9, .owner = null, .state = .{ .flag = true } };
    const required = try fixture.encoded(TestTicket, &ticket, test_encode_options);

    try testing.expectEqualStrings("id: 9\nOwner: null\nport: 8080\nstate: true\n", required);
}

test "a value is written where the writer stands inside an open document" {
    const fixture = try TestFixture.create();
    defer testing.allocator.destroy(fixture);

    var sink: std.Io.Writer = .fixed(&fixture.output);
    var writer: Writer = undefined;
    const ports = [_]u16{ 80, 443 };

    writer.init(&sink, test_writer_options);

    try writer.document_begin(&.{ .explicit = true });
    try writer.mapping_begin(&.{ .style = .block });
    try writer.scalar(&.{ .text = "ports" });
    try encode([]const u16, &writer, &ports[0..], test_encode_options);
    try writer.mapping_end();
    try writer.document_end(&.{ .explicit = true });

    writer.finish();

    try testing.expectEqualStrings("---\nports:\n  - 80\n  - 443\n...\n", sink.buffered());
}

test "decode applies merge keys to a map in merged order and positions an invalid merge" {
    const fixture = try TestFixture.create();
    defer testing.allocator.destroy(fixture);

    const source =
        \\base: &base {tier: edge, zone: west}
        \\labels: {zone: east, <<: *base, app: web}
        \\broken: {<<: [*base, 3]}
        \\
    ;

    const root = try fixture.root_parse(source);
    const document = &fixture.document.document;
    const labels = fixture.document.member(root, "labels") orelse return error.LabelsMissing;
    const broken = fixture.document.member(root, "broken") orelse return error.BrokenMissing;
    const Labels = []const EntryType([]const u8);

    var decoded: Labels = undefined;

    try decode(Labels, &fixture.region, document, labels, &decoded, .{
        .diagnostic = null,
        .merge = .applied,
    });

    const keys = [_][]const u8{ "zone", "tier", "app" };
    const values = [_][]const u8{ "east", "edge", "web" };

    try testing.expectEqual(keys.len, decoded.len);

    for (decoded, keys, values) |entry, key, value| {
        try testing.expectEqualStrings(key, entry.key);
        try testing.expectEqualStrings(value, entry.value);
    }

    var position: Position = undefined;

    const refused = decode(Labels, &fixture.region, document, broken, &decoded, .{
        .diagnostic = &position,
        .merge = .applied,
    });

    try testing.expectError(error.Mismatch, refused);
    try testing.expectEqual(Position{ .column = 22, .line = 3, .offset = 100 }, position);

    const ignored = decode(Labels, &fixture.region, document, labels, &decoded, .{
        .diagnostic = &position,
        .merge = .ignored,
    });

    try testing.expectError(error.Mismatch, ignored);
    try testing.expectEqual(Position{ .column = 7, .line = 1, .offset = 6 }, position);
}

test "decode reports MergesExceeded at the mapping whose sources pass the bound" {
    const fixture = try TestFixture.create();
    defer testing.allocator.destroy(fixture);

    var source: [4096]u8 = undefined;
    var sink: std.Io.Writer = .fixed(&source);

    try sink.writeAll("base: &base {kept: v}\nwide: {<<: [");

    for (0..merge_module.source_count_max + 1) |index| {
        try sink.writeAll(if (index == 0) "*base" else ", {}");
    }

    try sink.writeAll("]}\n");

    const Wide = struct {
        kept: ?[]const u8 = null,

        pub const yaml = .{};
    };

    const root = try fixture.root_parse(sink.buffered());
    const wide = fixture.document.member(root, "wide") orelse return error.WideMissing;
    const document = &fixture.document.document;

    var position: Position = undefined;
    var target: Wide = undefined;

    const refused = decode(Wide, &fixture.region, document, wide, &target, .{
        .diagnostic = &position,
        .merge = .applied,
    });

    try testing.expectError(error.MergesExceeded, refused);
    try testing.expectEqual(fixture.document.position_of(wide), position);

    try decode(Wide, &fixture.region, document, wide, &target, .{
        .diagnostic = null,
        .merge = .ignored,
    });

    try testing.expectEqual(@as(?[]const u8, null), target.kept);
}

test "decode reads scalars through the schema the document was parsed with" {
    const Settings = struct {
        big: u32,
        count: i64,
        flag: bool,
        mask: u8,
        ratio: f64,
        value: TestValue,

        pub const yaml = .{};
    };

    const fixture = try TestFixture.create();
    defer testing.allocator.destroy(fixture);

    const source = "{big: 1_000, count: 0x1F, flag: yes, mask: 0b101, ratio: 1:30.5, value: on}\n";
    const document = &fixture.document.document;

    var settings: Settings = undefined;

    try fixture.document.parse(source, .{ .schema = .v1_1 });

    try decode(Settings, &fixture.region, document, document.root(0), &settings, .{
        .diagnostic = null,
        .merge = .ignored,
    });

    try testing.expectEqual(@as(u32, 1000), settings.big);
    try testing.expectEqual(@as(i64, 31), settings.count);
    try testing.expect(settings.flag);
    try testing.expectEqual(@as(u8, 5), settings.mask);
    try testing.expectEqual(@as(f64, 90.5), settings.ratio);
    try testing.expectEqual(TestValue{ .flag = true }, settings.value);

    try fixture.document.parse(source, .{ .schema = .core });

    const core = decode(Settings, &fixture.region, document, document.root(0), &settings, .{
        .diagnostic = null,
        .merge = .ignored,
    });

    try testing.expectError(error.Mismatch, core);

    var value: TestValue = undefined;

    try fixture.document.parse("~\n", .{ .schema = .json });

    try decode(TestValue, &fixture.region, document, document.root(0), &value, .{
        .diagnostic = null,
        .merge = .ignored,
    });

    try testing.expectEqualStrings("~", value.label);
}

test decode {
    const Server = struct {
        host: []const u8,
        port: u16 = 8080,

        pub const yaml = .{ .host = "Host" };
    };

    const Fixed = document_module.DocumentType(test_capacity);
    const document = try testing.allocator.create(Fixed);
    defer testing.allocator.destroy(document);

    var buffer: [256]u8 = undefined;
    var region: Region = .init(&buffer);
    var server: Server = undefined;

    try document.parse("Host: localhost\nport: ~\n", .{ .schema = .core });

    try decode(Server, &region, &document.document, document.root(0), &server, .{
        .diagnostic = null,
    });

    try testing.expectEqualStrings("localhost", server.host);
    try testing.expectEqual(@as(u16, 8080), server.port);

    var diagnostic: Position = undefined;

    try document.parse("Host: x\nport: [1]\n", .{ .schema = .core });

    const refused = decode(Server, &region, &document.document, document.root(0), &server, .{
        .diagnostic = &diagnostic,
    });

    try testing.expectError(error.Mismatch, refused);
    try testing.expectEqual(@as(u32, 2), diagnostic.line);
}

test encode {
    const Server = struct {
        host: []const u8,
        port: u16 = 8080,
        tags: ?[]const []const u8 = null,

        pub const yaml = .{ .host = "Host" };
    };

    var buffer: [256]u8 = undefined;
    var sink: std.Io.Writer = .fixed(&buffer);
    var writer: Writer = undefined;
    const server: Server = .{ .host = "localhost", .tags = &.{ "edge", "true" } };

    writer.init(&sink, test_writer_options);

    try encode(Server, &writer, &server, .{ .null_members = .omitted });

    writer.finish();

    const expected =
        \\Host: localhost
        \\port: 8080
        \\tags:
        \\  - edge
        \\  - 'true'
        \\
    ;

    try testing.expectEqualStrings(expected, sink.buffered());
}

test EntryType {
    const fixture = try TestFixture.create();
    defer testing.allocator.destroy(fixture);

    const Labels = []const EntryType([]const u8);

    var labels: Labels = undefined;

    try fixture.decoded(Labels, "tier: edge\nzone: west\n", &labels);

    try testing.expectEqual(@as(usize, 2), labels.len);
    try testing.expectEqualStrings("tier", labels[0].key);
    try testing.expectEqualStrings("west", labels[1].value);

    const encoded = try fixture.encoded(Labels, &labels, test_encode_options);

    try testing.expectEqualStrings("tier: edge\nzone: west\n", encoded);
}

test "a struct without a yaml declaration decodes and encodes by its field names" {
    const Plain = struct {
        name: []const u8,
        port: u16 = 8080,
        tags: []const []const u8 = &.{},
    };

    const fixture = try TestFixture.create();
    defer testing.allocator.destroy(fixture);

    var plain: Plain = undefined;

    try fixture.decoded(Plain, "name: web\ntags: [edge]\nextra: 1\n", &plain);

    try testing.expectEqualStrings("web", plain.name);
    try testing.expectEqual(@as(u16, 8080), plain.port);
    try testing.expectEqualStrings("edge", plain.tags[0]);

    const encoded = try fixture.encoded(Plain, &plain, test_encode_options);

    try testing.expectEqualStrings("name: web\nport: 8080\ntags:\n  - edge\n", encoded);
}

const TestUnknownCase = struct {
    merge: Merge,
    position: ?Position,
    source: []const u8,
};

const TestServer = struct {
    host: []const u8,
    port: u16 = 8080,

    pub const yaml = .{ .host = "Host" };
};

fn test_unknown_expect(fixture: *TestFixture, case: *const TestUnknownCase) !void {
    assert(case.source.len < test_capacity.text_bytes_max);
    assert(fixture.region.used <= fixture.region.top);

    const root = try fixture.root_parse(case.source);
    const document = &fixture.document.document;
    const node = fixture.document.member(root, "server") orelse root;

    var position: Position = undefined;
    var server: TestServer = undefined;

    const refused = decode(TestServer, &fixture.region, document, node, &server, .{
        .diagnostic = &position,
        .merge = case.merge,
        .unknown_members = .refused,
    });

    if (case.position) |expected| {
        try testing.expectError(error.MemberUnknown, refused);
        try testing.expectEqual(expected, position);
    } else {
        try refused;
    }

    try decode(TestServer, &fixture.region, document, node, &server, .{
        .diagnostic = null,
        .merge = case.merge,
        .unknown_members = .ignored,
    });

    try testing.expectEqualStrings("a", server.host);
}

test "a refused unknown member is MemberUnknown at its key, and an ignored one is skipped" {
    const fixture = try TestFixture.create();
    defer testing.allocator.destroy(fixture);

    const cases = [_]TestUnknownCase{
        .{ .merge = .ignored, .position = null, .source = "Host: a\nport: 1\n" },
        .{
            .merge = .ignored,
            .position = .{ .column = 1, .line = 2, .offset = 8 },
            .source = "Host: a\nhost: b\n",
        },
        .{
            .merge = .ignored,
            .position = .{ .column = 11, .line = 1, .offset = 10 },
            .source = "{Host: a, [k]: v}\n",
        },
        .{
            .merge = .ignored,
            .position = .{ .column = 10, .line = 2, .offset = 28 },
            .source = "base: &b {port: 2}\nserver: {<<: *b, Host: a}\n",
        },
        .{
            .merge = .applied,
            .position = null,
            .source = "base: &b {port: 2}\nserver: {<<: *b, Host: a}\n",
        },
        .{
            .merge = .applied,
            .position = .{ .column = 11, .line = 1, .offset = 10 },
            .source = "base: &b {mode: 2}\nserver: {<<: *b, Host: a}\n",
        },
    };

    for (&cases) |*case| try test_unknown_expect(fixture, case);
}

test "a mismatch is reported at the value, not at its key" {
    const Port = struct {
        port: u16,
    };

    const fixture = try TestFixture.create();
    defer testing.allocator.destroy(fixture);

    const Case = struct {
        position: Position,
        source: []const u8,
    };

    const cases = [_]Case{
        .{ .position = .{ .column = 7, .line = 1, .offset = 6 }, .source = "port: [1]\n" },
        .{ .position = .{ .column = 3, .line = 2, .offset = 8 }, .source = "port:\n  a: 1\n" },
        .{ .position = .{ .column = 3, .line = 2, .offset = 9 }, .source = "? port\n: x\n" },
        .{ .position = .{ .column = 8, .line = 1, .offset = 7 }, .source = "{port: x}\n" },
        .{ .position = .{ .column = 7, .line = 1, .offset = 6 }, .source = "port: !!str 80\n" },
    };

    for (cases) |case| {
        const root = try fixture.root_parse(case.source);
        const document = &fixture.document.document;

        var position: Position = undefined;
        var port: Port = undefined;

        const refused = decode(Port, &fixture.region, document, root, &port, .{
            .diagnostic = &position,
        });

        try testing.expectError(error.Mismatch, refused);
        try testing.expectEqual(case.position, position);
    }
}
