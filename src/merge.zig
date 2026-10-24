const std = @import("std");

const codec = @import("codec.zig");
const document_module = @import("document.zig");
const region_module = @import("region.zig");
const scanner_module = @import("scanner.zig");
const schema_module = @import("schema.zig");

const assert = std.debug.assert;

pub const Merge = enum {
    applied,
    ignored,
};

pub const Error = error{
    MergeInvalid,
    MergesExceeded,
};

pub const source_count_max: u32 = 64;

const key_bytes_max: u32 = scanner_module.source_bytes_max;
const key_merge = "<<";
const visit_count_max: u32 = source_count_max * (source_count_max + 1);

comptime {
    assert(source_count_max >= 2);
    assert(visit_count_max > source_count_max * source_count_max);
}

pub fn NodeOf(comptime Source: type) type {
    return @typeInfo(@TypeOf(Source.root)).@"fn".return_type.?;
}

pub fn RawEntriesOf(comptime Source: type) type {
    return @typeInfo(@TypeOf(Source.entries)).@"fn".return_type.?;
}

pub fn ItemsOf(comptime Source: type) type {
    return @typeInfo(@TypeOf(Source.items)).@"fn".return_type.?;
}

pub fn StackType(comptime Source: type) type {
    const Node = NodeOf(Source);

    return struct {
        count: u32,
        failure: Node,
        nodes: [source_count_max]Node,

        const Stack = @This();

        const Pending = struct {
            count: u32,
            nodes: [source_count_max]Node,
        };

        pub fn flatten(stack: *Stack, source: *const Source, mapping: Node) Error![]const Node {
            assert(stack.count <= source_count_max);
            assert(@backingInt(mapping) < source.node_count);
            assert(source.kind_of(mapping) == .mapping);

            const start = stack.count;

            var pending: Pending = .{ .count = 0, .nodes = undefined };

            try stack.sources_push(source, mapping, &pending);

            for (0..visit_count_max) |_| {
                if (pending.count == 0) break;

                pending.count -= 1;

                const node = pending.nodes[pending.count];
                const visited = stack.nodes[start..stack.count];
                if (std.mem.findScalar(Node, visited, node) != null) continue;
                if (stack.count == source_count_max) return error.MergesExceeded;

                stack.nodes[stack.count] = node;
                stack.count += 1;

                try stack.sources_push(source, node, &pending);
            }

            assert(pending.count == 0);
            assert(stack.count >= start);

            return stack.nodes[start..stack.count];
        }

        pub fn pop(stack: *Stack, list: []const Node) void {
            assert(list.len <= stack.count);

            const start = stack.count - @as(u32, @intCast(list.len));

            if (list.len > 0) assert(list.ptr == stack.nodes[start..].ptr);

            stack.count = start;
        }

        fn sources_push(
            stack: *Stack,
            source: *const Source,
            mapping: Node,
            pending: *Pending,
        ) Error!void {
            assert(@backingInt(mapping) < source.node_count);
            assert(pending.count <= source_count_max);

            const value = value_of(Source, source, mapping) orelse return;

            switch (source.kind_of(value)) {
                .mapping => return pending_push(source, pending, value),
                .scalar => {
                    stack.failure = value;

                    return error.MergeInvalid;
                },
                .sequence => {},
            }

            const first = pending.count;
            var items = source.items(value);

            for (0..source.count_of(value)) |_| {
                const item = items.next() orelse break;

                if (source.kind_of(item) != .mapping) {
                    stack.failure = item;

                    return error.MergeInvalid;
                }

                try pending_push(source, pending, item);
            }

            assert(pending.count - first == source.count_of(value));

            std.mem.reverse(Node, pending.nodes[first..pending.count]);
        }

        fn pending_push(source: *const Source, pending: *Pending, node: Node) Error!void {
            assert(@backingInt(node) < source.node_count);
            assert(pending.count <= source_count_max);

            if (pending.count == source_count_max) return error.MergesExceeded;

            pending.nodes[pending.count] = identity_of(Source, source, node);
            pending.count += 1;
        }
    };
}

pub fn EntriesType(comptime Source: type) type {
    const Node = NodeOf(Source);
    const Raw = RawEntriesOf(Source);

    return struct {
        inner: Raw,
        list: []const Node,
        mapping: Node,
        outer: Raw,
        phase: Phase,
        position: u32,
        source: *const Source,
        step_count_max: u32,

        const Merged = @This();

        const Phase = enum {
            merged,
            own,
            rest,
        };

        pub fn init(source: *const Source, mapping: Node, list: []const Node) Merged {
            assert(@backingInt(mapping) < source.node_count);
            assert(source.kind_of(mapping) == .mapping);
            assert(list.len <= source_count_max);

            var step_count_max = source.count_of(mapping) + 2;

            for (list) |node| step_count_max += source.count_of(node) + 1;

            return .{
                .inner = source.entries(mapping),
                .list = list,
                .mapping = mapping,
                .outer = source.entries(mapping),
                .phase = .own,
                .position = 0,
                .source = source,
                .step_count_max = step_count_max,
            };
        }

        pub fn next(merged: *Merged) ?Raw.Entry {
            assert(merged.position <= merged.list.len);
            assert(merged.step_count_max > 0);

            for (0..merged.step_count_max) |_| {
                switch (merged.phase) {
                    .merged => {
                        const entry = merged.inner.next() orelse {
                            merged.source_advance();

                            continue;
                        };

                        if (merged.visible_is(entry)) return entry;
                    },
                    .own, .rest => {
                        const entry = merged.outer.next() orelse return null;
                        if (!entry_merge_is(Source, merged.source, entry.key)) return entry;

                        assert(merged.phase == .own);

                        merged.merge_enter();
                    },
                }
            }

            unreachable;
        }

        fn merge_enter(merged: *Merged) void {
            assert(merged.phase == .own);
            assert(merged.position == 0);

            if (merged.list.len == 0) {
                merged.phase = .rest;
            } else {
                merged.phase = .merged;
                merged.inner = merged.source.entries(merged.list[0]);
            }
        }

        fn source_advance(merged: *Merged) void {
            assert(merged.phase == .merged);
            assert(merged.position < merged.list.len);

            merged.position += 1;

            if (merged.position == merged.list.len) {
                merged.phase = .rest;
            } else {
                merged.inner = merged.source.entries(merged.list[merged.position]);
            }
        }

        fn visible_is(merged: *const Merged, entry: Raw.Entry) bool {
            assert(merged.phase == .merged);
            assert(@backingInt(entry.key) < merged.source.node_count);
            assert(@backingInt(entry.value) < merged.source.node_count);

            const source = merged.source;
            if (entry_merge_is(Source, source, entry.key)) return false;

            const key = source.text_of(entry.key) orelse return true;
            return visible(Source, source, merged.mapping, merged.list[0..merged.position], key);
        }
    };
}

pub fn value_of(
    comptime Source: type,
    source: *const Source,
    mapping: NodeOf(Source),
) ?NodeOf(Source) {
    assert(@backingInt(mapping) < source.node_count);
    assert(source.kind_of(mapping) == .mapping);

    const value = source.member(mapping, key_merge) orelse return null;
    var entries = source.entries(mapping);

    assert(source.count_of(mapping) > 0);

    for (0..source.count_of(mapping)) |_| {
        const entry = entries.next() orelse break;
        if (entry.value != value) continue;
        if (!key_text_is(Source, source, entry.key)) continue;
        return if (key_merge_is(Source, source, entry.key)) value else null;
    }

    unreachable;
}

pub fn member_merged(
    comptime Source: type,
    source: *const Source,
    mapping: NodeOf(Source),
    list: []const NodeOf(Source),
    key: []const u8,
) ?NodeOf(Source) {
    assert(@backingInt(mapping) < source.node_count);
    assert(list.len <= source_count_max);
    assert(key.len <= key_bytes_max);

    if (ordinary_member(Source, source, mapping, key)) |value| return value;

    for (list) |node| {
        if (ordinary_member(Source, source, node, key)) |value| return value;
    }

    return null;
}

pub fn visible(
    comptime Source: type,
    source: *const Source,
    mapping: NodeOf(Source),
    earlier: []const NodeOf(Source),
    key: []const u8,
) bool {
    assert(@backingInt(mapping) < source.node_count);
    assert(earlier.len < source_count_max);
    assert(key.len <= key_bytes_max);

    if (ordinary_member(Source, source, mapping, key) != null) return false;

    for (earlier) |node| {
        if (ordinary_member(Source, source, node, key) != null) return false;
    }

    return true;
}

fn ordinary_member(
    comptime Source: type,
    source: *const Source,
    mapping: NodeOf(Source),
    key: []const u8,
) ?NodeOf(Source) {
    assert(@backingInt(mapping) < source.node_count);
    assert(source.kind_of(mapping) == .mapping);
    assert(key.len <= key_bytes_max);

    const value = source.member(mapping, key) orelse return null;
    if (!std.mem.eql(u8, key, key_merge)) return value;
    if (value_of(Source, source, mapping) != null) return null;
    return value;
}

pub fn entry_merge_is(comptime Source: type, source: *const Source, key: NodeOf(Source)) bool {
    assert(@backingInt(key) < source.node_count);
    assert(schema_module.tag_merge.len > 0);

    if (!key_text_is(Source, source, key)) return false;
    return key_merge_is(Source, source, key);
}

fn identity_of(
    comptime Source: type,
    source: *const Source,
    node: NodeOf(Source),
) NodeOf(Source) {
    assert(@backingInt(node) < source.node_count);
    assert(source.kind_of(node) != .scalar);

    if (!@hasDecl(Source, "alias_of")) return node;
    return source.alias_of(node) orelse node;
}

fn key_text_is(comptime Source: type, source: *const Source, key: NodeOf(Source)) bool {
    assert(@backingInt(key) < source.node_count);
    assert(key_merge.len == 2);

    const text = source.text_of(key) orelse return false;
    return std.mem.eql(u8, text, key_merge);
}

fn key_merge_is(comptime Source: type, source: *const Source, key: NodeOf(Source)) bool {
    assert(source.kind_of(key) == .scalar);
    assert(std.mem.eql(u8, source.text_of(key).?, key_merge));

    const tag = source.tag_of(key);
    if (tag.len > 0) return std.mem.eql(u8, tag, schema_module.tag_merge);
    return source.style_of(key).scalar == .plain;
}

const testing = std.testing;

const TestDocument = document_module.DocumentType(.{
    .anchor_count_max = 256,
    .comment_count_max = null,
    .node_count_max = 1024,
    .text_bytes_max = 16 * 1024,
});

const TestNode = document_module.Node;
const TestMerged = EntriesType(document_module.Document);
const TestStack = StackType(document_module.Document);

const TestFixture = struct {
    document: TestDocument,
    stack: TestStack,

    fn node_find(fixture: *const TestFixture, segments: []const []const u8) !TestNode {
        assert(segments.len > 0);
        assert(fixture.document.root_count() == 1);

        const root = fixture.document.root(0);
        return fixture.document.path_find(root, segments) orelse error.NodeMissing;
    }

    fn flattened(fixture: *TestFixture, segments: []const []const u8) ![]const TestNode {
        assert(segments.len > 0);
        assert(fixture.document.root_count() == 1);

        const mapping = try fixture.node_find(segments);

        fixture.stack.count = 0;

        return fixture.stack.flatten(&fixture.document.document, mapping);
    }

    fn merged_text(
        fixture: *TestFixture,
        segments: []const []const u8,
        key: []const u8,
    ) ![]const u8 {
        assert(segments.len > 0);
        assert(key.len > 0);

        const list = try fixture.flattened(segments);
        const mapping = try fixture.node_find(segments);
        const document = &fixture.document.document;
        const value = member_merged(document_module.Document, document, mapping, list, key);

        return fixture.document.text_of(value orelse return error.MemberMissing).?;
    }

    fn keys_join(fixture: *TestFixture, segments: []const []const u8, buffer: []u8) ![]const u8 {
        assert(segments.len > 0);
        assert(buffer.len > 0);

        const list = try fixture.flattened(segments);
        const mapping = try fixture.node_find(segments);
        var merged: TestMerged = .init(&fixture.document.document, mapping, list);
        var sink: std.Io.Writer = .fixed(buffer);

        for (0..merged.step_count_max) |_| {
            const entry = merged.next() orelse break;

            try sink.writeAll(fixture.document.text_of(entry.key).?);
        }

        return sink.buffered();
    }
};

const test_sources =
    \\x: &x {k: x, a: 1}
    \\y: &y {k: y, b: 2}
    \\list: &list [*x, *y]
    \\single: {<<: *x, c: 3}
    \\ordered: {<<: [*x, *y]}
    \\explicit: {k: own, <<: [*x, *y]}
    \\inline: {<<: {k: inline, d: 4}, e: 5}
    \\aliased: {<<: *list}
    \\quoted: {"<<": *x}
    \\tagged: {!!merge <<: *y}
    \\string: {!!str <<: *y}
    \\iteration: {f: 0, <<: [*x, *y], g: 9}
    \\
;

test "a merge key supplies the keys the mapping lacks, and the first source wins" {
    const fixture = try testing.allocator.create(TestFixture);
    defer testing.allocator.destroy(fixture);

    try fixture.document.parse(test_sources, .{ .schema = .core });

    try testing.expectEqualStrings("x", try fixture.merged_text(&.{"single"}, "k"));
    try testing.expectEqualStrings("1", try fixture.merged_text(&.{"single"}, "a"));
    try testing.expectEqualStrings("3", try fixture.merged_text(&.{"single"}, "c"));
    try testing.expectEqualStrings("x", try fixture.merged_text(&.{"ordered"}, "k"));
    try testing.expectEqualStrings("2", try fixture.merged_text(&.{"ordered"}, "b"));
    try testing.expectEqualStrings("own", try fixture.merged_text(&.{"explicit"}, "k"));
    try testing.expectEqualStrings("inline", try fixture.merged_text(&.{"inline"}, "k"));
    try testing.expectEqualStrings("5", try fixture.merged_text(&.{"inline"}, "e"));
    try testing.expectEqualStrings("x", try fixture.merged_text(&.{"aliased"}, "k"));
    try testing.expectEqualStrings("2", try fixture.merged_text(&.{"aliased"}, "b"));
    try testing.expectEqualStrings("y", try fixture.merged_text(&.{"tagged"}, "k"));
    try testing.expectError(error.MemberMissing, fixture.merged_text(&.{"single"}, "<<"));
    try testing.expectError(error.MemberMissing, fixture.merged_text(&.{"string"}, "k"));

    const quoted = try fixture.node_find(&.{ "quoted", "<<" });

    try testing.expectEqual(try fixture.node_find(&.{"x"}), quoted);
    try testing.expectEqual(@as(usize, 0), (try fixture.flattened(&.{"quoted"})).len);
    try testing.expectEqual(@as(usize, 0), (try fixture.flattened(&.{"string"})).len);
}

test "merged entries replace the merge entry in place and skip keys an earlier source holds" {
    const fixture = try testing.allocator.create(TestFixture);
    defer testing.allocator.destroy(fixture);

    var buffer: [64]u8 = undefined;

    try fixture.document.parse(test_sources, .{ .schema = .core });

    try testing.expectEqualStrings("fkabg", try fixture.keys_join(&.{"iteration"}, &buffer));
    try testing.expectEqualStrings("kab", try fixture.keys_join(&.{"explicit"}, &buffer));
    try testing.expectEqualStrings("kac", try fixture.keys_join(&.{"single"}, &buffer));
    try testing.expectEqualStrings("kab", try fixture.keys_join(&.{"ordered"}, &buffer));
}

test "nested merges flatten in preorder and visit a shared source once, as PyYAML's priority" {
    const fixture = try testing.allocator.create(TestFixture);
    defer testing.allocator.destroy(fixture);

    try fixture.document.parse(
        \\c: &c {k: c, c: 1}
        \\d: &d {k: d, d: 1, c: 2}
        \\a: &a {<<: [*c], a: 1}
        \\b: &b {<<: [*d, *c], b: 1}
        \\x: {<<: [*a, *b]}
        \\
    , .{ .schema = .core });

    const expected = [_]TestNode{
        try fixture.node_find(&.{"a"}),
        try fixture.node_find(&.{"c"}),
        try fixture.node_find(&.{"b"}),
        try fixture.node_find(&.{"d"}),
    };

    try testing.expectEqualSlices(TestNode, &expected, try fixture.flattened(&.{"x"}));
    try testing.expectEqualStrings("c", try fixture.merged_text(&.{"x"}, "k"));
    try testing.expectEqualStrings("1", try fixture.merged_text(&.{"x"}, "c"));
    try testing.expectEqualStrings("1", try fixture.merged_text(&.{"x"}, "d"));

    var buffer: [64]u8 = undefined;

    try testing.expectEqualStrings("akcbd", try fixture.keys_join(&.{"x"}, &buffer));
    try testing.expectEqualStrings("d", try fixture.merged_text(&.{"b"}, "k"));
    try testing.expectEqualStrings("2", try fixture.merged_text(&.{"b"}, "c"));
}

test "a merge value that is not a mapping or a sequence of mappings is invalid at that value" {
    const fixture = try testing.allocator.create(TestFixture);
    defer testing.allocator.destroy(fixture);

    try fixture.document.parse(
        \\s: &s 5
        \\x: &x {k: x}
        \\scalar: {<<: 6}
        \\aliased: {<<: *s}
        \\holding: {<<: [*x, 7]}
        \\nothing: {<<: ~}
        \\empty: {<<: []}
        \\
    , .{ .schema = .core });

    const cases = [_][]const u8{ "scalar", "aliased", "holding", "nothing" };
    const failures = [_][]const u8{ "6", "5", "7", "~" };

    for (cases, failures) |case, failure| {
        try testing.expectError(error.MergeInvalid, fixture.flattened(&.{case}));
        try testing.expectEqualStrings(failure, fixture.document.text_of(fixture.stack.failure).?);
    }

    try testing.expectEqual(@as(usize, 0), (try fixture.flattened(&.{"empty"})).len);
}

test "an alias key names the merge key it points at" {
    const fixture = try testing.allocator.create(TestFixture);
    defer testing.allocator.destroy(fixture);

    try fixture.document.parse(
        \\first: {&m <<: {a: 1}}
        \\second: {*m : {b: 2}}
        \\
    , .{ .schema = .core });

    try testing.expectEqualStrings("1", try fixture.merged_text(&.{"first"}, "a"));
    try testing.expectEqualStrings("2", try fixture.merged_text(&.{"second"}, "b"));
}

test "more than sixty-four sources is MergesExceeded, in one sequence or along a chain" {
    const fixture = try testing.allocator.create(TestFixture);
    defer testing.allocator.destroy(fixture);

    var source: [8192]u8 = undefined;
    var sink: std.Io.Writer = .fixed(&source);

    for (0..source_count_max + 1) |index| {
        try sink.print("m{d}: &m{d} {{k{d}: {d}}}\n", .{ index, index, index, index });
    }

    try sink.writeAll("wide: {<<: [");

    for (0..source_count_max + 1) |index| {
        try sink.print("{s}*m{d}", .{ if (index == 0) "" else ", ", index });
    }

    try sink.writeAll("]}\nfull: {<<: [");

    for (0..source_count_max) |index| {
        try sink.print("{s}*m{d}", .{ if (index == 0) "" else ", ", index });
    }

    try sink.writeAll("]}\nc0: &c0 {}\n");

    for (1..source_count_max + 1) |index| {
        try sink.print("c{d}: &c{d} {{<<: *c{d}}}\n", .{ index, index, index - 1 });
    }

    try sink.print("chain: {{<<: *c{d}}}\n", .{source_count_max});

    try fixture.document.parse(sink.buffered(), .{ .schema = .core });

    try testing.expectError(error.MergesExceeded, fixture.flattened(&.{"wide"}));
    try testing.expectError(error.MergesExceeded, fixture.flattened(&.{"chain"}));

    const full = try fixture.flattened(&.{"full"});

    try testing.expectEqual(@as(usize, source_count_max), full.len);
    try testing.expectEqualStrings("63", try fixture.merged_text(&.{"full"}, "k63"));
}

test Merge {
    const Service = struct {
        image: []const u8,
        restart: []const u8 = "no",

        pub const yaml = .{};
    };

    const document = try testing.allocator.create(TestDocument);
    defer testing.allocator.destroy(document);

    try document.parse(
        \\defaults: &defaults {image: base, restart: always}
        \\web: {<<: *defaults, image: nginx}
        \\
    , .{ .schema = .core });

    var buffer: [256]u8 align(region_module.alignment_bytes) = undefined;
    var region: region_module.Region = .init(&buffer);
    var web: Service = undefined;

    const node = document.member(document.root(0), "web") orelse return error.WebMissing;

    try codec.decode(Service, &region, &document.document, node, &web, .{
        .diagnostic = null,
        .merge = .applied,
    });

    try testing.expectEqualStrings("nginx", web.image);
    try testing.expectEqualStrings("always", web.restart);

    try codec.decode(Service, &region, &document.document, node, &web, .{
        .diagnostic = null,
        .merge = .ignored,
    });

    try testing.expectEqualStrings("no", web.restart);
}
