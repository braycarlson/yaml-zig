const std = @import("std");

const comment_module = @import("comment.zig");
const document_module = @import("document.zig");
const parser_module = @import("parser.zig");
const scanner_module = @import("scanner.zig");

const assert = std.debug.assert;

const Comment = comment_module.Comment;
const Parser = parser_module.Parser;
const TokenKind = scanner_module.TokenKind;

pub const index_none: u32 = std.math.maxInt(u32);
pub const key_bucket_count_min: u32 = 64;
pub const probe_count_max: u32 = 256;
pub const scan_entry_count_max: u32 = 16;
const anchor_count_limit: u32 = 1 << 30;

comptime {
    assert(std.math.isPowerOfTwo(key_bucket_count_min));
    assert(key_bucket_count_min >= (scan_entry_count_max + 1) * 2);
    assert(probe_count_max >= 16);
    assert(scanner_module.source_bytes_max < index_none);
}

pub const Capacity = struct {
    anchor_count_max: u32,
    comment_count_max: ?u32,
    node_count_max: u32,
    text_bytes_max: u32,
};

pub const NodeKind = enum(u8) {
    alias,
    mapping,
    scalar,
    sequence,
};

pub const Record = struct {
    anchor: []const u8,
    column: u32,
    kind: NodeKind,
    line: u32,
    link: Link,
    markers: Markers,
    offset: u32,
    span: u32,
    style: u8,
    tag: []const u8,
    text: []const u8,

    pub const Link = extern union {
        count: u32,
        target: u32,
    };

    pub const Markers = packed struct(u8) {
        end_explicit: bool = false,
        start_explicit: bool = false,
        blank_before: bool = false,
        blank_inside: bool = false,
        padding: u4 = 0,
    };
};

pub const CommentSlot = struct {
    column: u32,
    flags: Flags,
    flow_depth: u16,
    line: u32,
    node: u32,
    placement: Comment.Placement,
    previous: TokenKind,
    text: []const u8,

    pub const Flags = packed struct(u8) {
        blank_before: bool,
        inside: bool,
        prefix: bool,
        trailing: bool,
        padding: u4,
    };
};

comptime {
    assert(@sizeOf(Record) == 72);
    assert(@sizeOf(CommentSlot) == 40);
}

pub const KeySlot = struct {
    hash: u32,
    key: u32,
    mapping: u32,
    value: u32,
};

pub const KeyProbe = struct {
    hash: u32,
    mapping: u32,
    text: []const u8,
};

pub const EntryScan = struct {
    count: u32,
    mapping: u32,
};

pub const AnchorSlot = struct {
    epoch: u32,
    hash: u32,
    name: []const u8,
    node: u32,
};

pub const Storage = struct {
    anchors: []AnchorSlot,
    comments: []CommentSlot,
    key_buckets: []u32,
    keys: []KeySlot,
    nodes: []Record,
    parser: *Parser,
    roots: []u32,
    text: []u8,

    pub fn init(gpa: std.mem.Allocator, capacity: Capacity) std.mem.Allocator.Error!Storage {
        assert(capacity.node_count_max > 0);
        assert(capacity.anchor_count_max > 0);

        const lengths = lengths_of(capacity);
        const anchors = try gpa.alloc(AnchorSlot, lengths.anchors);
        errdefer gpa.free(anchors);

        const comments = try gpa.alloc(CommentSlot, lengths.comments);
        errdefer gpa.free(comments);

        const key_buckets = try gpa.alloc(u32, lengths.key_buckets);
        errdefer gpa.free(key_buckets);

        const keys = try gpa.alloc(KeySlot, lengths.keys);
        errdefer gpa.free(keys);

        const nodes = try gpa.alloc(Record, lengths.nodes);
        errdefer gpa.free(nodes);

        const parser = try gpa.create(Parser);
        errdefer gpa.destroy(parser);

        const roots = try gpa.alloc(u32, lengths.nodes);
        errdefer gpa.free(roots);

        const text = try gpa.alloc(u8, lengths.text);

        return .{
            .anchors = anchors,
            .comments = comments,
            .key_buckets = key_buckets,
            .keys = keys,
            .nodes = nodes,
            .parser = parser,
            .roots = roots,
            .text = text,
        };
    }

    pub fn deinit(storage: *Storage, gpa: std.mem.Allocator) void {
        assert(storage.nodes.len == storage.roots.len);
        assert(std.math.isPowerOfTwo(storage.key_buckets.len));

        gpa.free(storage.anchors);
        gpa.free(storage.comments);
        gpa.free(storage.key_buckets);
        gpa.free(storage.keys);
        gpa.free(storage.nodes);
        gpa.destroy(storage.parser);
        gpa.free(storage.roots);
        gpa.free(storage.text);

        storage.* = undefined;
    }
};

const Lengths = struct {
    anchors: u32,
    comments: u32,
    key_buckets: u32,
    keys: u32,
    nodes: u32,
    text: u32,
};

fn lengths_of(capacity: Capacity) Lengths {
    assert(capacity.node_count_max > 0);
    assert(capacity.node_count_max < @divFloor(index_none, 2));
    assert(capacity.anchor_count_max > 0);
    assert(capacity.anchor_count_max <= anchor_count_limit);

    if (capacity.comment_count_max) |count| assert(count > 0);

    const result: Lengths = .{
        .anchors = 2 * std.math.ceilPowerOfTwoAssert(u32, capacity.anchor_count_max),
        .comments = capacity.comment_count_max orelse 0,
        .key_buckets = std.math.ceilPowerOfTwoAssert(u32, capacity.node_count_max),
        .keys = @divFloor(capacity.node_count_max, 2) + 1,
        .nodes = capacity.node_count_max,
        .text = capacity.text_bytes_max,
    };

    assert(result.keys * 2 > result.nodes);
    assert(result.key_buckets >= result.nodes);

    return result;
}

pub fn StorageType(comptime capacity: Capacity) type {
    comptime assert(capacity.node_count_max > 0);
    comptime assert(capacity.anchor_count_max > 0);

    const lengths = comptime lengths_of(capacity);

    return struct {
        anchors: [lengths.anchors]AnchorSlot,
        comments: [lengths.comments]CommentSlot,
        key_buckets: [lengths.key_buckets]u32,
        keys: [lengths.keys]KeySlot,
        nodes: [lengths.nodes]Record,
        parser: Parser,
        roots: [lengths.nodes]u32,
        text: [lengths.text]u8,

        const StorageArrays = @This();

        pub fn storage(arrays: *StorageArrays) Storage {
            assert(arrays.nodes.len == capacity.node_count_max);
            assert(std.math.isPowerOfTwo(arrays.key_buckets.len));
            assert(arrays.keys.len * 2 > arrays.nodes.len);

            return .{
                .anchors = &arrays.anchors,
                .comments = &arrays.comments,
                .key_buckets = &arrays.key_buckets,
                .keys = &arrays.keys,
                .nodes = &arrays.nodes,
                .parser = &arrays.parser,
                .roots = &arrays.roots,
                .text = &arrays.text,
            };
        }
    };
}

pub fn hash_of(mapping: u32, text: []const u8) u32 {
    assert(text.len <= scanner_module.source_bytes_max);
    assert(mapping < index_none);

    const hash = std.hash.Wyhash.hash(mapping, text);
    const result: u32 = @truncate(hash);

    assert(result == hash & std.math.maxInt(u32));

    return result;
}

pub fn position_of(record: *const Record) parser_module.Position {
    assert(record.offset >= record.column);
    assert(record.line < index_none);

    return .{ .column = record.column + 1, .line = record.line + 1, .offset = record.offset };
}

pub fn resolved(nodes: []const Record, index: u32) u32 {
    assert(index < nodes.len);
    assert(nodes.len < index_none);

    const node = &nodes[index];
    if (node.kind != .alias) return index;

    assert(node.link.target < index);
    assert(nodes[node.link.target].kind != .alias);

    return node.link.target;
}

pub fn slot_matches(nodes: []const Record, slot: *const KeySlot, probe: *const KeyProbe) bool {
    assert(slot.mapping != index_none);
    assert(probe.mapping < nodes.len);
    assert(probe.text.len <= scanner_module.source_bytes_max);

    if (slot.mapping != probe.mapping) return false;
    if (slot.hash != probe.hash) return false;

    const key = resolved(nodes, slot.key);
    return std.mem.eql(u8, nodes[key].text, probe.text);
}

pub fn entry_find(nodes: []const Record, scan: EntryScan, text: []const u8) ?u32 {
    assert(scan.mapping < nodes.len);
    assert(scan.count <= scan_entry_count_max);
    assert(text.len <= scanner_module.source_bytes_max);

    var cursor = scan.mapping + 1;
    var result: ?u32 = null;

    for (0..scan.count) |_| {
        const key = resolved(nodes, cursor);
        const value = cursor + nodes[cursor].span;

        if (key_text_is(&nodes[key], text)) {
            result = value;

            break;
        }

        cursor = value + nodes[value].span;
    }

    if (result) |value| assert(value < nodes.len);

    return result;
}

fn key_text_is(node: *const Record, text: []const u8) bool {
    assert(node.kind != .alias);
    assert(text.len <= scanner_module.source_bytes_max);

    if (node.kind != .scalar) return false;
    if (node.text.len != text.len) return false;
    return std.mem.eql(u8, node.text, text);
}

test Storage {
    const capacity: Capacity = .{
        .anchor_count_max = 5,
        .comment_count_max = 3,
        .node_count_max = 100,
        .text_bytes_max = 1000,
    };

    var storage = try Storage.init(std.testing.allocator, capacity);
    defer storage.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 16), storage.anchors.len);
    try std.testing.expectEqual(@as(usize, 3), storage.comments.len);
    try std.testing.expectEqual(@as(usize, 128), storage.key_buckets.len);
    try std.testing.expectEqual(@as(usize, 51), storage.keys.len);
    try std.testing.expectEqual(@as(usize, 100), storage.nodes.len);
    try std.testing.expectEqual(@as(usize, 100), storage.roots.len);
    try std.testing.expectEqual(@as(usize, 1000), storage.text.len);

    const Fixed = StorageType(capacity);
    const fixed_anchors = @typeInfo(@FieldType(Fixed, "anchors")).array.len;
    const fixed_keys = @typeInfo(@FieldType(Fixed, "keys")).array.len;

    try std.testing.expectEqual(fixed_anchors, storage.anchors.len);
    try std.testing.expectEqual(fixed_keys, storage.keys.len);

    const document = try std.testing.allocator.create(document_module.Document);
    defer std.testing.allocator.destroy(document);

    try document.parse(storage, "- &a 1\n- *a\n", .{ .schema = .core });

    const root = document.root(0);

    try std.testing.expectEqual(@as(u32, 2), document.count_of(root));
}

test StorageType {
    const capacity: Capacity = .{
        .anchor_count_max = 16,
        .comment_count_max = null,
        .node_count_max = 256,
        .text_bytes_max = 4096,
    };

    const Fixed = struct {
        document: document_module.Document,
        storage: StorageType(capacity),
    };

    const fixed = try std.testing.allocator.create(Fixed);
    defer std.testing.allocator.destroy(fixed);

    const source = "name: warbler\nports: [8080, 8443]\n";

    try fixed.document.parse(fixed.storage.storage(), source, .{ .schema = .core });

    const root = fixed.document.root(0);
    const name = fixed.document.member(root, "name") orelse return error.NameMissing;
    const ports = fixed.document.member(root, "ports") orelse return error.PortsMissing;

    try std.testing.expectEqualStrings("warbler", fixed.document.text_of(name).?);
    try std.testing.expectEqual(@as(u32, 2), fixed.document.count_of(ports));
}
