const std = @import("std");

const comment_module = @import("comment.zig");
const document_module = @import("document.zig");
const parser_module = @import("parser.zig");
const round_trip = @import("round_trip.zig");
const storage_module = @import("storage.zig");
const writer_module = @import("writer.zig");

const assert = std.debug.assert;
const testing = std.testing;

const Comment = comment_module.Comment;
const Node = document_module.Node;
const Parser = parser_module.Parser;
const Writer = writer_module.Writer;

const capacity: document_module.Capacity = .{
    .anchor_count_max = 64,
    .comment_count_max = null,
    .node_count_max = 1024,
    .text_bytes_max = 64 * 1024,
};

const Document = document_module.DocumentType(capacity);

const Fixture = struct {
    document: Document,

    fn parse(fixture: *Fixture, source: []const u8) document_module.Document.Error!*const Document {
        assert(source.len <= capacity.text_bytes_max);
        assert(fixture.document.storage.nodes.len == capacity.node_count_max);

        try fixture.document.parse(source, .{ .schema = .core });

        return &fixture.document;
    }
};

fn items_collect(document: *const Document, sequence: Node, buffer: []Node) []const Node {
    assert(document.kind_of(sequence) == .sequence);
    assert(buffer.len > document.count_of(sequence));

    var items = document.items(sequence);
    var count: u32 = 0;

    for (buffer) |*slot| {
        slot.* = items.next() orelse break;
        count += 1;
    }

    return buffer[0..count];
}

fn entries_collect(
    document: *const Document,
    mapping: Node,
    buffer: []document_module.Entries.Entry,
) []const document_module.Entries.Entry {
    assert(document.kind_of(mapping) == .mapping);
    assert(buffer.len > document.count_of(mapping));

    var entries = document.entries(mapping);
    var count: u32 = 0;

    for (buffer) |*slot| {
        slot.* = entries.next() orelse break;
        count += 1;
    }

    return buffer[0..count];
}

const EventKind = enum {
    alias,
    document_end,
    document_start,
    mapping_end,
    mapping_start,
    scalar,
    sequence_end,
    sequence_start,
    stream_end,
    stream_start,
};

const Expected = struct {
    kind: EventKind,
    text: []const u8 = "",
};

fn events_expect(source: []const u8, expected: []const Expected) !void {
    assert(source.len > 0);
    assert(expected.len >= 2);

    const parser = try testing.allocator.create(Parser);
    defer testing.allocator.destroy(parser);

    var text: [4096]u8 = undefined;

    parser.init(&text, source);

    for (expected) |want| {
        const event = try parser.next();
        const kind: EventKind = @fromBackingInt(@intCast(@backingInt(event.*)));

        try testing.expectEqual(want.kind, kind);

        switch (event.*) {
            .scalar => |scalar| try testing.expectEqualStrings(want.text, scalar.text),
            .alias => |alias| try testing.expectEqualStrings(want.text, alias.anchor),
            .mapping_start, .sequence_start => |start| try testing.expectEqualStrings(
                want.text,
                start.anchor,
            ),
            else => {},
        }
    }
}

test "spec example 2.3 maps scalars to block sequences" {
    try events_expect(
        \\american:
        \\  - Boston Red Sox
        \\  - Detroit Tigers
        \\national:
        \\  - New York Mets
        \\
    , &.{
        .{ .kind = .stream_start },
        .{ .kind = .document_start },
        .{ .kind = .mapping_start },
        .{ .kind = .scalar, .text = "american" },
        .{ .kind = .sequence_start },
        .{ .kind = .scalar, .text = "Boston Red Sox" },
        .{ .kind = .scalar, .text = "Detroit Tigers" },
        .{ .kind = .sequence_end },
        .{ .kind = .scalar, .text = "national" },
        .{ .kind = .sequence_start },
        .{ .kind = .scalar, .text = "New York Mets" },
        .{ .kind = .sequence_end },
        .{ .kind = .mapping_end },
        .{ .kind = .document_end },
        .{ .kind = .stream_end },
    });
}

test "spec example 2.10 anchors a node and aliases it later" {
    try events_expect(
        \\---
        \\hr:
        \\  - Mark McGwire
        \\  - &SS Sammy Sosa
        \\rbi:
        \\  - *SS
        \\
    , &.{
        .{ .kind = .stream_start },
        .{ .kind = .document_start },
        .{ .kind = .mapping_start },
        .{ .kind = .scalar, .text = "hr" },
        .{ .kind = .sequence_start },
        .{ .kind = .scalar, .text = "Mark McGwire" },
        .{ .kind = .scalar, .text = "Sammy Sosa" },
        .{ .kind = .sequence_end },
        .{ .kind = .scalar, .text = "rbi" },
        .{ .kind = .sequence_start },
        .{ .kind = .alias, .text = "SS" },
        .{ .kind = .sequence_end },
        .{ .kind = .mapping_end },
        .{ .kind = .document_end },
        .{ .kind = .stream_end },
    });
}

test "block scalars keep, clip, and strip their trailing line breaks" {
    try events_expect(
        \\strip: |-
        \\  text
        \\
        \\clip: |
        \\  text
        \\
        \\keep: |+
        \\  text
        \\
        \\folded: >
        \\  one
        \\  two
        \\
        \\   indented
        \\  three
        \\last: end
        \\
    , &.{
        .{ .kind = .stream_start },
        .{ .kind = .document_start },
        .{ .kind = .mapping_start },
        .{ .kind = .scalar, .text = "strip" },
        .{ .kind = .scalar, .text = "text" },
        .{ .kind = .scalar, .text = "clip" },
        .{ .kind = .scalar, .text = "text\n" },
        .{ .kind = .scalar, .text = "keep" },
        .{ .kind = .scalar, .text = "text\n\n" },
        .{ .kind = .scalar, .text = "folded" },
        .{ .kind = .scalar, .text = "one two\n\n indented\nthree\n" },
        .{ .kind = .scalar, .text = "last" },
        .{ .kind = .scalar, .text = "end" },
        .{ .kind = .mapping_end },
    });
}

test "end of input closes the last line of a block scalar exactly once" {
    const fixture = try testing.allocator.create(Fixture);
    defer testing.allocator.destroy(fixture);

    const cases = [_]struct { source: []const u8, text: []const u8 }{
        .{ .source = " |+\n   |+\n     ", .text = "|+\n  \n" },
        .{ .source = "foo: |\n  x\n   ", .text = "x\n \n" },
        .{ .source = "- |+\n   ", .text = "\n" },
        .{ .source = "a: |\n  x", .text = "x\n" },
        .{ .source = "a: |-\n  x", .text = "x" },
        .{ .source = "a: >+\n  x\n\n", .text = "x\n\n" },
    };

    for (cases) |case| {
        const document = try fixture.parse(case.source);
        const root = document.root(0);
        var entries = if (document.kind_of(root) == .mapping) document.entries(root) else null;
        var items = if (document.kind_of(root) == .sequence) document.items(root) else null;

        const node = switch (document.kind_of(root)) {
            .mapping => entries.?.next().?.value,
            .sequence => items.?.next().?,
            .scalar => root,
        };

        try testing.expectEqualStrings(case.text, document.text_of(node).?);
    }
}

test "quoted scalars fold lines and decode every escape" {
    try events_expect(
        \\- "a\tb\\c\"d\x41é\U0001F600\N\_\L\P\0\a\e\/"
        \\- 'it''s
        \\
        \\  folded'
        \\- "joined \
        \\  here"
        \\
    , &.{
        .{ .kind = .stream_start },
        .{ .kind = .document_start },
        .{ .kind = .sequence_start },
        .{
            .kind = .scalar,
            .text = "a\tb\\c\"dA\u{e9}\u{1f600}\u{85}\u{a0}\u{2028}\u{2029}\x00\x07\x1b/",
        },
        .{ .kind = .scalar, .text = "it's\nfolded" },
        .{ .kind = .scalar, .text = "joined here" },
        .{ .kind = .sequence_end },
    });
}

test "an escaped line break drops itself but keeps the empty lines after it" {
    try events_expect("[\"a\\\n\n  b\", \"a\\\n\n\n  b \\\n  c\"]\n", &.{
        .{ .kind = .stream_start },
        .{ .kind = .document_start },
        .{ .kind = .sequence_start },
        .{ .kind = .scalar, .text = "a\nb" },
        .{ .kind = .scalar, .text = "a\n\nb c" },
        .{ .kind = .sequence_end },
    });
}

test "a hexadecimal escape accepts only hexadecimal digits" {
    const fixture = try testing.allocator.create(Fixture);
    defer testing.allocator.destroy(fixture);

    try testing.expectError(error.EscapeInvalid, fixture.parse("\"\\u00_9\""));
    try testing.expectError(error.EscapeInvalid, fixture.parse("\"\\x4\""));
    try testing.expectError(error.EscapeInvalid, fixture.parse("\"\\U+0000041\""));
    try testing.expectError(error.EscapeInvalid, fixture.parse("\"\\uD800\""));

    const document = try fixture.parse("\"\\x4a\\u004B\\U0000004c\"");

    try testing.expectEqualStrings("JKL", document.text_of(document.root(0)).?);
}

test "flow collections, single pairs, and adjacent JSON values" {
    try events_expect(
        \\{a: [1, b: c, "d":e], ? f : g, "h":i}
        \\
    , &.{
        .{ .kind = .stream_start },
        .{ .kind = .document_start },
        .{ .kind = .mapping_start },
        .{ .kind = .scalar, .text = "a" },
        .{ .kind = .sequence_start },
        .{ .kind = .scalar, .text = "1" },
        .{ .kind = .mapping_start },
        .{ .kind = .scalar, .text = "b" },
        .{ .kind = .scalar, .text = "c" },
        .{ .kind = .mapping_end },
        .{ .kind = .mapping_start },
        .{ .kind = .scalar, .text = "d" },
        .{ .kind = .scalar, .text = "e" },
        .{ .kind = .mapping_end },
        .{ .kind = .sequence_end },
        .{ .kind = .scalar, .text = "f" },
        .{ .kind = .scalar, .text = "g" },
        .{ .kind = .scalar, .text = "h" },
        .{ .kind = .scalar, .text = "i" },
        .{ .kind = .mapping_end },
    });
}

test "tags resolve through the default and declared handles" {
    const parser = try testing.allocator.create(Parser);
    defer testing.allocator.destroy(parser);

    var text: [1024]u8 = undefined;

    const source =
        \\%TAG !e! tag:example.com,2000:app/
        \\---
        \\- !local a
        \\- !!str b
        \\- !e!tag%21 c
        \\- !<tag:verbatim> d
        \\- ! e
        \\
    ;

    parser.init(&text, source);

    const expected = [_][]const u8{
        "!local",
        "tag:yaml.org,2002:str",
        "tag:example.com,2000:app/tag!",
        "tag:verbatim",
        "!",
    };

    for (0..3) |_| _ = try parser.next();

    const local = try parser.next();
    const source_start = @intFromPtr(source.ptr);

    try testing.expectEqualStrings(expected[0], local.scalar.tag);
    try testing.expect(@intFromPtr(local.scalar.tag.ptr) >= source_start);
    try testing.expect(@intFromPtr(local.scalar.tag.ptr) < source_start + source.len);

    for (expected[1..]) |tag| {
        const event = try parser.next();

        try testing.expectEqualStrings(tag, event.scalar.tag);
    }
}

test "the document answers members, entries, items, and positions" {
    const fixture = try testing.allocator.create(Fixture);
    defer testing.allocator.destroy(fixture);

    const document = try fixture.parse(
        \\name: docker
        \\ports:
        \\  - 80
        \\  - 443
        \\nested: {a: 1, b: [x, y]}
        \\
    );

    try testing.expectEqual(@as(u32, 1), document.root_count());

    const root = document.root(0);

    try testing.expectEqual(document_module.Kind.mapping, document.kind_of(root));
    try testing.expectEqual(@as(u32, 3), document.count_of(root));
    try testing.expectEqualStrings("docker", document.text_of(document.member(root, "name").?).?);
    try testing.expectEqual(@as(?Node, null), document.member(root, "absent"));

    var item_buffer: [8]Node = undefined;
    var entry_buffer: [8]document_module.Entries.Entry = undefined;
    const ports = items_collect(document, document.member(root, "ports").?, &item_buffer);
    const members = entries_collect(document, root, &entry_buffer);

    try testing.expectEqual(@as(usize, 2), ports.len);
    try testing.expectEqual(@as(?i64, 80), document.integer_of(ports[0]));
    try testing.expectEqual(@as(?i64, 443), document.integer_of(ports[1]));
    try testing.expectEqual(@as(usize, 3), members.len);
    try testing.expectEqualStrings("name", document.text_of(members[0].key).?);
    try testing.expectEqualStrings("ports", document.text_of(members[1].key).?);
    try testing.expectEqualStrings("nested", document.text_of(members[2].key).?);

    const nested = document.member(root, "nested").?;
    const position = document.position_of(nested);

    try testing.expectEqual(@as(u32, 5), position.line);
    try testing.expectEqual(@as(u32, 9), position.column);
    try testing.expectEqual(document_module.Style{ .mapping = .flow }, document.style_of(nested));
}

test "an alias resolves to the very node its anchor names" {
    const fixture = try testing.allocator.create(Fixture);
    defer testing.allocator.destroy(fixture);

    const document = try fixture.parse(
        \\base: &base {size: 8}
        \\copy: *base
        \\list: [*base, *base]
        \\
    );

    const root = document.root(0);
    const base = document.member(root, "base").?;

    try testing.expectEqual(base, document.member(root, "copy").?);

    var buffer: [4]Node = undefined;
    const list = items_collect(document, document.member(root, "list").?, &buffer);

    try testing.expectEqual(@as(usize, 2), list.len);
    try testing.expectEqual(base, list[0]);
    try testing.expectEqual(base, list[1]);
    try testing.expectEqualStrings("base", document.anchor_of(base));
}

test "a billion laughs costs one node per alias" {
    const fixture = try testing.allocator.create(Fixture);
    defer testing.allocator.destroy(fixture);

    const document = try fixture.parse(
        \\a: &a [x, x, x, x, x, x, x, x, x, x]
        \\b: &b [*a, *a, *a, *a, *a, *a, *a, *a, *a, *a]
        \\c: &c [*b, *b, *b, *b, *b, *b, *b, *b, *b, *b]
        \\d: &d [*c, *c, *c, *c, *c, *c, *c, *c, *c, *c]
        \\
    );

    try testing.expect(document.document.node_count < 64);
}

test "documents in a stream keep separate roots and separate anchors" {
    const fixture = try testing.allocator.create(Fixture);
    defer testing.allocator.destroy(fixture);

    const document = try fixture.parse(
        \\--- &a first
        \\--- second
        \\...
        \\third
        \\
    );

    try testing.expectEqual(@as(u32, 3), document.root_count());
    try testing.expectEqualStrings("first", document.text_of(document.root(0)).?);
    try testing.expectEqualStrings("third", document.text_of(document.root(2)).?);

    const crossing = fixture.parse("--- &a x\n--- *a\n");

    try testing.expectError(error.AliasUndefined, crossing);
    try testing.expectEqual(@as(u32, 2), fixture.document.diagnostic().line);
    try testing.expectEqual(@as(u32, 5), fixture.document.diagnostic().column);
}

test "duplicate keys, recursive aliases, and undefined aliases are refused" {
    const fixture = try testing.allocator.create(Fixture);
    defer testing.allocator.destroy(fixture);

    try testing.expectError(error.KeyDuplicate, fixture.parse("a: 1\nb: 2\na: 3\n"));
    try testing.expectEqual(@as(u32, 3), fixture.document.diagnostic().line);
    try testing.expectError(error.KeyDuplicate, fixture.parse("{x: 1, \"x\": 2}"));
    try testing.expectError(error.AliasRecursive, fixture.parse("&a [*a]\n"));
    try testing.expectError(error.AliasUndefined, fixture.parse("- *missing\n"));
}

test "the core schema helpers resolve plain scalars and honor explicit tags" {
    const fixture = try testing.allocator.create(Fixture);
    defer testing.allocator.destroy(fixture);

    const document = try fixture.parse(
        \\[~, null, true, False, 0x1F, -12, 1.5e3, .inf, "12", !!int "7", !!str 8]
        \\
    );

    var buffer: [16]Node = undefined;
    const values = items_collect(document, document.root(0), &buffer);

    try testing.expectEqual(@as(usize, 11), values.len);
    try testing.expect(document.null_is(values[0]));
    try testing.expect(document.null_is(values[1]));
    try testing.expectEqual(@as(?bool, true), document.boolean_of(values[2]));
    try testing.expectEqual(@as(?bool, false), document.boolean_of(values[3]));
    try testing.expectEqual(@as(?i64, 31), document.integer_of(values[4]));
    try testing.expectEqual(@as(?i64, -12), document.integer_of(values[5]));
    try testing.expectEqual(@as(?f64, 1500), document.float_of(values[6]));
    try testing.expect(std.math.isPositiveInf(document.float_of(values[7]).?));
    try testing.expectEqual(@as(?i64, null), document.integer_of(values[8]));
    try testing.expectEqual(@as(?i64, 7), document.integer_of(values[9]));
    try testing.expectEqual(@as(?i64, null), document.integer_of(values[10]));
}

test "simple scalars are slices of the source and processed ones live in storage" {
    const fixture = try testing.allocator.create(Fixture);
    defer testing.allocator.destroy(fixture);

    const source = "plain: value\nfolded: two\n  lines\n";
    const document = try fixture.parse(source);
    const root = document.root(0);
    const plain = document.text_of(document.member(root, "plain").?).?;
    const folded = document.text_of(document.member(root, "folded").?).?;
    const source_start = @intFromPtr(source.ptr);
    const text_start = @intFromPtr(&fixture.document.storage.text);

    try testing.expectEqualStrings("value", plain);
    try testing.expectEqualStrings("two lines", folded);
    try testing.expect(@intFromPtr(plain.ptr) >= source_start);
    try testing.expect(@intFromPtr(plain.ptr) < source_start + source.len);
    try testing.expect(@intFromPtr(folded.ptr) >= text_start);
}

test "errors carry the line and column where the input went wrong" {
    const fixture = try testing.allocator.create(Fixture);
    defer testing.allocator.destroy(fixture);

    const cases = [_]struct { column: u32, line: u32, source: []const u8 }{
        .{ .column = 5, .line = 2, .source = "a: b\nc: d: e\n" },
        .{ .column = 1, .line = 3, .source = "key:\n  - x\n\t- y\n" },
        .{ .column = 6, .line = 1, .source = "a: \"b" },
        .{ .column = 3, .line = 1, .source = "- \x01\n" },
        .{ .column = 3, .line = 1, .source = "{a" },
        .{ .column = 3, .line = 1, .source = "\xef\xbb\xbfab\x01" },
        .{ .column = 1, .line = 2, .source = "a\r\x01" },
    };

    for (cases) |case| {
        const parsed = fixture.parse(case.source);

        try testing.expect(std.meta.isError(parsed));
        try testing.expectEqual(case.line, fixture.document.diagnostic().line);
        try testing.expectEqual(case.column, fixture.document.diagnostic().column);
    }
}

test "a byte order mark may open any document in a stream" {
    const fixture = try testing.allocator.create(Fixture);
    defer testing.allocator.destroy(fixture);

    const bom = "\xef\xbb\xbf";

    const accepted = [_]struct { count: u32, source: []const u8 }{
        .{ .count = 2, .source = bom ++ "first\n...\n" ++ bom ++ "# note\nsecond\n" },
        .{ .count = 1, .source = bom ++ bom ++ "only\n" },
        .{ .count = 2, .source = "first\n" ++ bom ++ "# note\n---\nsecond\n" },
        .{ .count = 1, .source = "first\n" ++ bom ++ "# trailing note\n" },
        .{ .count = 1, .source = "\"quoted " ++ bom ++ " content\"\n" },
    };

    for (accepted) |case| {
        const document = try fixture.parse(case.source);

        try testing.expectEqual(case.count, document.root_count());
    }

    const rejected = [_][]const u8{
        "key: value\n" ++ bom ++ "other: value\n",
        "plain " ++ bom ++ "\n",
        "# comment " ++ bom ++ "\n",
        "first\n" ++ bom ++ "...\n",
        "|\n  text" ++ bom ++ "\n",
    };

    for (rejected) |source| {
        try testing.expectError(error.CharacterInvalid, fixture.parse(source));
    }
}

test "node properties need separation before flow collection content" {
    const fixture = try testing.allocator.create(Fixture);
    defer testing.allocator.destroy(fixture);

    try testing.expectError(error.TagInvalid, fixture.parse("[![b]]"));
    try testing.expectError(error.TagInvalid, fixture.parse("- !local{a: b}"));
    try testing.expectError(error.AnchorInvalid, fixture.parse("[&a[b]]"));
    try testing.expectError(error.AnchorInvalid, fixture.parse("key: &a{b: c}"));

    const document = try fixture.parse("[!local , &a ]\n");

    var buffer: [4]Node = undefined;
    const values = items_collect(document, document.root(0), &buffer);

    try testing.expectEqual(@as(usize, 2), values.len);
    try testing.expectEqualStrings("!local", document.tag_of(values[0]));
    try testing.expectEqualStrings("a", document.anchor_of(values[1]));
}

test "storage limits fail with a named error instead of corrupting memory" {
    const fixture = try testing.allocator.create(Fixture);
    defer testing.allocator.destroy(fixture);

    var many: [2300]u8 = undefined;

    for (&many, 0..) |*byte, index| byte.* = if (index % 2 == 1) 'a' else ',';

    many[0] = '[';

    many[many.len - 1] = ']';

    try testing.expectError(error.NodesExhausted, fixture.parse(&many));

    var deep: [600]u8 = @splat('[');

    try testing.expectError(error.DepthExceeded, fixture.parse(&deep));
}

test "a node of the wrong kind answers with zero, empty iterators, and null" {
    const fixture = try testing.allocator.create(Fixture);
    defer testing.allocator.destroy(fixture);

    const document = try fixture.parse("name: warbler\nports: [8080]\n");
    const root = document.root(0);
    const name = document.member(root, "name") orelse return error.NameMissing;

    var name_entries = document.entries(name);
    var name_items = document.items(name);

    const name_entry = name_entries.next();
    const name_item = name_items.next();

    try testing.expectEqual(@as(u32, 0), document.count_of(name));
    try testing.expectEqual(@as(u32, 0), name_entries.remaining);
    try testing.expectEqual(@as(?document_module.Entries.Entry, null), name_entry);
    try testing.expectEqual(@as(?Node, null), name_item);
    try testing.expectEqual(@as(?Node, null), document.member(name, "name"));
    try testing.expectEqual(@as(?Node, null), document.item(name, 0));
    try testing.expectEqual(@as(?Node, null), document.path_find(name, &.{"0"}));

    const ports = document.member(root, "ports") orelse return error.PortsMissing;

    var root_items = document.items(root);
    var ports_entries = document.entries(ports);

    const root_item = root_items.next();
    const ports_entry = ports_entries.next();

    try testing.expectEqual(@as(?Node, null), root_item);
    try testing.expectEqual(@as(?document_module.Entries.Entry, null), ports_entry);
    try testing.expectEqual(@as(?Node, null), document.member(ports, "0"));
    try testing.expectEqual(@as(?Node, null), document.item(root, 0));
    try testing.expectEqual(@as(u32, 2), document.count_of(root));
    try testing.expectEqual(@as(u32, 1), document.count_of(ports));
}

test "item and path_find index a sequence by the RFC 6901 index rule and see through aliases" {
    const fixture = try testing.allocator.create(Fixture);
    defer testing.allocator.destroy(fixture);

    const document = try fixture.parse(
        \\base: &base [d, e]
        \\list: [a, [b, c], {0: zero, 01: one}, *base]
        \\
    );

    const root = document.root(0);
    const base = document.member(root, "base") orelse return error.BaseMissing;
    const list = document.member(root, "list") orelse return error.ListMissing;

    const found = [_][]const []const u8{
        &.{ "list", "0" },
        &.{ "list", "1", "1" },
        &.{ "list", "2", "0" },
        &.{ "list", "2", "01" },
        &.{ "list", "3", "1" },
    };

    const texts = [_][]const u8{ "a", "c", "zero", "one", "e" };

    for (found, texts) |segments, expected| {
        const node = document.path_find(root, segments) orelse return error.PathMissing;

        try testing.expectEqualStrings(expected, document.text_of(node).?);
    }

    try testing.expectEqual(@as(?Node, base), document.item(list, 3));
    try testing.expectEqual(@as(?Node, root), document.path_find(root, &.{}));

    const refused = [_][]const u8{
        "",
        "4",
        "01",
        "+1",
        "-1",
        "1_0",
        " 1",
        "1 ",
        "x",
        "4294967295",
        "4294967296",
        "99999999999999999999",
    };

    for (refused) |segment| {
        try testing.expectEqual(@as(?Node, null), document.path_find(list, &.{segment}));
    }

    try testing.expectEqual(@as(?Node, null), document.path_find(root, &.{ "list", "0", "0" }));
    try testing.expectEqual(@as(?Node, null), document.item(list, 4));
    try testing.expectEqual(@as(?Node, null), document.item(list, std.math.maxInt(u31)));
}

test "explicit tags resolve examples 10.4 to 10.7 under every schema" {
    const fixture = try testing.allocator.create(Fixture);
    defer testing.allocator.destroy(fixture);

    const source =
        \\- !!null null
        \\- !!bool true
        \\- !!int -12
        \\- !!int 34
        \\- !!float -1
        \\- !!float 2.3e4
        \\- !!str 7
        \\
    ;

    for (std.enums.values(document_module.Schema)) |schema| {
        try fixture.document.parse(source, .{ .schema = schema });

        var buffer: [8]Node = undefined;
        const values = items_collect(&fixture.document, fixture.document.root(0), &buffer);
        const document = &fixture.document;

        try testing.expect(document.null_is(values[0]));
        try testing.expectEqual(@as(?bool, true), document.boolean_of(values[1]));
        try testing.expectEqual(@as(?i64, -12), document.integer_of(values[2]));
        try testing.expectEqual(@as(?i64, 34), document.integer_of(values[3]));
        try testing.expectEqual(@as(?f64, -1), document.float_of(values[4]));
        try testing.expectEqual(@as(?i64, null), document.integer_of(values[4]));
        try testing.expectEqual(@as(?i64, null), document.integer_of(values[6]));
    }

    try fixture.document.parse(source, .{ .schema = .core });

    var buffer: [8]Node = undefined;
    const values = items_collect(&fixture.document, fixture.document.root(0), &buffer);

    try testing.expectEqual(@as(?f64, 23000), fixture.document.float_of(values[5]));
}

test "the JSON schema resolves example 10.8 and leaves the values it calls invalid as strings" {
    const fixture = try testing.allocator.create(Fixture);
    defer testing.allocator.destroy(fixture);

    try fixture.document.parse(
        \\- null
        \\- [true, false]
        \\- [0, -0, 3, -19]
        \\- [0., -0.0, 12e03, -2E+05]
        \\- [True, Null, 0o7, 0x3A, +12.3]
        \\
    , .{ .schema = .json });

    const document = &fixture.document;
    const root = document.root(0);
    const falsehood = document.path_find(root, &.{ "1", "1" }) orelse return error.BooleanMissing;

    try testing.expect(document.null_is(document.item(root, 0).?));
    try testing.expectEqual(@as(?bool, false), document.boolean_of(falsehood));

    const integers = [_]i64{ 0, 0, 3, -19 };

    for (integers, 0..) |expected, index| {
        const node = document.item(document.item(root, 2).?, @intCast(index)).?;

        try testing.expectEqual(@as(?i64, expected), document.integer_of(node));
    }

    const floats = [_]f64{ 0, -0.0, 12000, -200000 };

    for (floats, 0..) |expected, index| {
        const node = document.item(document.item(root, 3).?, @intCast(index)).?;
        const value = document.float_of(node) orelse return error.FloatMissing;

        try testing.expectEqual(@as(?i64, null), document.integer_of(node));
        try testing.expectEqual(@as(u64, @bitCast(expected)), @as(u64, @bitCast(value)));
    }

    const invalid = document.item(root, 4).?;

    for (0..document.count_of(invalid)) |index| {
        const node = document.item(invalid, @intCast(index)).?;

        try testing.expect(!document.null_is(node));
        try testing.expectEqual(@as(?bool, null), document.boolean_of(node));
        try testing.expectEqual(@as(?i64, null), document.integer_of(node));
        try testing.expectEqual(@as(?f64, null), document.float_of(node));
    }
}

test "the core schema resolves example 10.9" {
    const fixture = try testing.allocator.create(Fixture);
    defer testing.allocator.destroy(fixture);

    try fixture.document.parse(
        \\A null: null
        \\Also a null: # Empty
        \\Not a null: ""
        \\Booleans: [ true, True, false, FALSE ]
        \\Integers: [ 0, 0o7, 0x3A, -19 ]
        \\Floats: [ 0., -0.0, .5, +12e03, -2E+05 ]
        \\Also floats: [ .inf, -.Inf, +.INF, .NAN ]
        \\
    , .{ .schema = .core });

    const document = &fixture.document;
    const root = document.root(0);

    try testing.expect(document.null_is(document.member(root, "A null").?));
    try testing.expect(document.null_is(document.member(root, "Also a null").?));
    try testing.expect(!document.null_is(document.member(root, "Not a null").?));

    const booleans = [_]bool{ true, true, false, false };

    for (booleans, 0..) |expected, index| {
        const digit: [1]u8 = .{'0' + @as(u8, @intCast(index))};
        const node = document.path_find(root, &.{ "Booleans", &digit }) orelse return error.Missing;

        try testing.expectEqual(@as(?bool, expected), document.boolean_of(node));
    }

    const integers = [_]i64{ 0, 7, 58, -19 };

    for (integers, 0..) |expected, index| {
        const node = document.item(document.member(root, "Integers").?, @intCast(index)).?;

        try testing.expectEqual(@as(?i64, expected), document.integer_of(node));
    }

    const floats = [_]f64{ 0, -0.0, 0.5, 12000, -200000 };

    for (floats, 0..) |expected, index| {
        const node = document.item(document.member(root, "Floats").?, @intCast(index)).?;
        const value = document.float_of(node) orelse return error.FloatMissing;

        try testing.expectEqual(@as(u64, @bitCast(expected)), @as(u64, @bitCast(value)));
    }

    const special = document.member(root, "Also floats").?;

    try testing.expect(std.math.isPositiveInf(document.float_of(document.item(special, 0).?).?));
    try testing.expect(std.math.isNegativeInf(document.float_of(document.item(special, 1).?).?));
    try testing.expect(std.math.isPositiveInf(document.float_of(document.item(special, 2).?).?));
    try testing.expect(std.math.isNan(document.float_of(document.item(special, 3).?).?));
}

const MemberLayout = enum {
    alias,
    block,
    complex,
    flow,
    nested,
};

const grid_key_count: u32 = 24;
const grid_mapping_count: u32 = 6;
const scan_entry_count_max = @import("storage.zig").scan_entry_count_max;

fn member_source(writer: *std.Io.Writer, layout: MemberLayout, count: u32) !void {
    assert(count > 0);
    assert(count <= 64);

    switch (layout) {
        .alias, .block, .complex => {},
        .flow => try writer.writeAll("{"),
        .nested => try writer.writeAll("outer:\n"),
    }

    for (0..count) |index| {
        try member_entry_write(writer, layout, @intCast(index));
    }

    if (layout == .flow) try writer.writeAll("}\n");
}

fn member_entry_write(writer: *std.Io.Writer, layout: MemberLayout, index: u32) !void {
    assert(index < 64);
    assert(writer.buffered().len > 0 or index == 0);

    switch (layout) {
        .alias => {
            if (index == 0) try writer.writeAll("&first ");

            try writer.print("k{d}: {d}\n", .{ index, index });
        },
        .block => try writer.print("k{d}: {d}\n", .{ index, index }),
        .complex => {
            if (index == scan_entry_count_max) try writer.writeAll("? [x]\n: c\n");

            try writer.print("k{d}: {d}\n", .{ index, index });
        },
        .flow => {
            if (index > 0) try writer.writeAll(", ");

            try writer.print("k{d}: {d}", .{ index, index });
        },
        .nested => try writer.print("  k{d}: {d}\n", .{ index, index }),
    }
}

fn member_mapping(document: *const Document, layout: MemberLayout) Node {
    assert(document.root_count() == 1);
    assert(document.kind_of(document.root(0)) == .mapping);

    const root = document.root(0);

    const result = switch (layout) {
        .alias, .block, .complex, .flow => root,
        .nested => outer: {
            var entries = document.entries(root);

            break :outer entries.next().?.value;
        },
    };

    assert(document.kind_of(result) == .mapping);

    return result;
}

fn member_reference(document: *const Document, mapping: Node, key: []const u8) ?Node {
    assert(document.kind_of(mapping) == .mapping);
    assert(key.len > 0);

    var entries = document.entries(mapping);

    for (0..document.count_of(mapping)) |_| {
        const entry = entries.next() orelse return null;
        if (document.kind_of(entry.key) != .scalar) continue;
        if (std.mem.eql(u8, document.text_of(entry.key).?, key)) return entry.value;
    }

    return null;
}

test "member lookups agree with an entries scan on both sides of the index threshold" {
    const fixture = try testing.allocator.create(Fixture);
    defer testing.allocator.destroy(fixture);

    var buffer: [2048]u8 = undefined;
    var key_buffer: [8]u8 = undefined;

    for (std.enums.values(MemberLayout)) |layout| {
        for (1..41) |count| {
            var writer: std.Io.Writer = .fixed(&buffer);

            try member_source(&writer, layout, @intCast(count));

            const document = try fixture.parse(writer.buffered());
            const mapping = member_mapping(document, layout);

            for (0..count + 1) |index| {
                const key = try std.mem.print(&key_buffer, "k{d}", .{index});
                const found = document.member(mapping, key);

                try testing.expectEqual(member_reference(document, mapping, key), found);

                if (index < count) {
                    const expected: i64 = @intCast(index);

                    try testing.expectEqual(@as(?i64, expected), document.integer_of(found.?));
                }
            }
        }
    }
}

fn duplicate_refuse(fixture: *Fixture, source: []const u8, start: usize) !void {
    assert(start < source.len);
    assert(source[source.len - 1] == '\n');

    const line: u32 = @intCast(std.mem.countScalar(u8, source[0..start], '\n') + 1);
    const indent = std.mem.findNone(u8, source[start..], " ").?;
    const column: u32 = @intCast(indent + 1);

    try testing.expectError(error.KeyDuplicate, fixture.parse(source));
    try testing.expectEqual(line, fixture.document.diagnostic().line);
    try testing.expectEqual(column, fixture.document.diagnostic().column);
}

test "a duplicate key is refused at its own position for every mapping size" {
    const fixture = try testing.allocator.create(Fixture);
    defer testing.allocator.destroy(fixture);

    var buffer: [2048]u8 = undefined;

    for ([_]MemberLayout{ .alias, .block, .complex, .nested }) |layout| {
        for (1..41) |count| {
            for ([_]usize{ 0, count - 1 }) |duplicate| {
                var writer: std.Io.Writer = .fixed(&buffer);

                try member_source(&writer, layout, @intCast(count));

                const start = writer.buffered().len;

                if (layout == .nested) try writer.writeAll("  ");

                try writer.print("k{d}: 0\n", .{duplicate});
                try duplicate_refuse(fixture, writer.buffered(), start);
            }
        }
    }
}

test "an alias key that repeats an earlier key is refused at every mapping size" {
    const fixture = try testing.allocator.create(Fixture);
    defer testing.allocator.destroy(fixture);

    var buffer: [2048]u8 = undefined;

    for (1..41) |count| {
        var writer: std.Io.Writer = .fixed(&buffer);

        try member_source(&writer, .alias, @intCast(count));

        const start = writer.buffered().len;

        try writer.writeAll("*first : 9\n");
        try duplicate_refuse(fixture, writer.buffered(), start);
    }
}

test "lookups stay exact while the index grows across several large mappings" {
    const fixture = try testing.allocator.create(Fixture);
    defer testing.allocator.destroy(fixture);

    const sentinel: u32 = 0xaaaa_aaaa;
    var buffer: [4096]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    for (0..grid_mapping_count) |mapping| {
        try writer.print("m{d}:\n", .{mapping});

        for (0..grid_key_count) |key| try writer.print("  k{d}: {d}\n", .{ key, key });
    }

    @memset(&fixture.document.storage.key_buckets, sentinel);

    const document = try fixture.parse(writer.buffered());
    const indexed = grid_mapping_count * grid_key_count;
    const unused = fixture.document.storage.key_buckets[document.document.key_bucket_count..];

    try testing.expectEqual(indexed, document.document.composer.key_count);
    try testing.expect(document.document.key_bucket_count >= indexed * 2);
    try testing.expect(unused.len > 0);
    try testing.expect(std.mem.allEqual(u32, unused, sentinel));
    try grid_lookups_check(document);
}

fn grid_lookups_check(document: *const Document) !void {
    assert(document.root_count() == 1);
    assert(document.count_of(document.root(0)) == grid_mapping_count);

    var name_buffer: [8]u8 = undefined;
    var key_buffer: [8]u8 = undefined;

    for (0..grid_mapping_count) |mapping_index| {
        const name = try std.mem.print(&name_buffer, "m{d}", .{mapping_index});
        const mapping = document.member(document.root(0), name).?;

        for (0..grid_key_count + 1) |key_index| {
            const key = try std.mem.print(&key_buffer, "k{d}", .{key_index});
            const found = document.member(mapping, key);

            try testing.expectEqual(member_reference(document, mapping, key), found);
        }
    }
}

const LongKey = struct {
    depth: u32,
    length: u32,
};

fn long_key_source(buffer: []u8, key: LongKey) []const u8 {
    assert(key.depth <= 8);
    assert(2 * key.depth + key.length + 4 <= buffer.len);

    const depth = key.depth;
    const length = key.length;
    const end = 2 * depth + length + 4;

    @memset(buffer[0..depth], '[');
    @memset(buffer[depth..][0..length], 'k');
    @memcpy(buffer[depth + length ..][0..3], ": v");
    @memset(buffer[depth + length + 3 ..][0..depth], ']');
    buffer[end - 1] = '\n';

    const result = buffer[0..end];

    assert(result[result.len - 1] == '\n');

    return result;
}

test "an implicit key may span 1024 columns but not 1025 at any flow depth" {
    const fixture = try testing.allocator.create(Fixture);
    defer testing.allocator.destroy(fixture);

    var buffer: [1200]u8 = undefined;

    for (0..7) |depth| {
        const accepted = long_key_source(&buffer, .{ .depth = @intCast(depth), .length = 1024 });

        _ = try fixture.parse(accepted);

        const refused = long_key_source(&buffer, .{ .depth = @intCast(depth), .length = 1025 });
        const expected: anyerror = if (depth == 0) error.ValueInvalid else error.FlowInvalid;
        const column: u32 = @intCast(if (depth == 0) 1026 else 1026 + depth);

        try testing.expectError(expected, fixture.parse(refused));
        try testing.expectEqual(@as(u32, 1), fixture.document.diagnostic().line);
        try testing.expectEqual(column, fixture.document.diagnostic().column);
    }

    try testing.expectError(error.KeyInvalid, fixture.parse("a: b\nc\n: d\n"));
    try testing.expectEqual(@as(u32, 2), fixture.document.diagnostic().line);
    try testing.expectEqual(@as(u32, 1), fixture.document.diagnostic().column);
}

const output_bytes_max: u32 = 64 * 1024;

const write_options: Writer.Options = .{
    .indent = 2,
    .layout = .preserve,
    .sequence_indentless = false,
    .utf8 = .checked,
    .version_directive = false,
    .width = 0,
};

const WriteFixture = struct {
    original: Document,
    output: [output_bytes_max]u8,
    rewritten: [output_bytes_max]u8,
    written: Document,

    fn written_of(fixture: *WriteFixture, source: []const u8, options: Writer.Options) ![]const u8 {
        assert(source.len < capacity.text_bytes_max);
        assert(options.indent >= 1);

        var sink: std.Io.Writer = .fixed(&fixture.output);
        var again: std.Io.Writer = .fixed(&fixture.rewritten);

        try fixture.original.parse(source, .{ .schema = .core });
        try fixture.original.write(&sink, options);
        try fixture.written.parse(sink.buffered(), .{ .schema = .core });

        const documents: round_trip.Documents = .{
            .original = &fixture.original.document,
            .written = &fixture.written.document,
        };

        const difference = round_trip.documents_equivalent(documents, .{
            .layout = options.layout,
            .style_exact = options.layout == .preserve,
            .version_directive = options.version_directive,
        });

        if (difference) |reason| {
            std.debug.print("{s}, written as:\n{s}\n", .{ reason, sink.buffered() });

            return error.DocumentsDiffer;
        }

        try fixture.written.write(&again, options);
        try testing.expectEqualStrings(sink.buffered(), again.buffered());

        return sink.buffered();
    }
};

test "a written document reads back as the same records, properties and aliases included" {
    const fixture = try testing.allocator.create(WriteFixture);
    defer testing.allocator.destroy(fixture);

    const source =
        \\%TAG !e! tag:example.com,2000:
        \\--- !e!root
        \\name: &n warbler
        \\tags: [a, 'b c', "d\"e", !!str 7]
        \\copy: *n
        \\? [complex, key]
        \\: >-
        \\  folded
        \\  text
        \\nested:
        \\- {x: 1, y: ~}
        \\- - deep
        \\  - ''
        \\
    ;

    const expected =
        \\--- !<tag:example.com,2000:root>
        \\name: &n warbler
        \\tags: [a, 'b c', "d\"e", !!str 7]
        \\copy: *n
        \\? [complex, key]
        \\: >-
        \\  folded text
        \\nested:
        \\  - {x: 1, y: ~}
        \\  - - deep
        \\    - ''
        \\
    ;

    try testing.expectEqualStrings(expected, try fixture.written_of(source, write_options));
}

test "an alias is written as an alias, so a billion laughs stays the size of its source" {
    const fixture = try testing.allocator.create(WriteFixture);
    defer testing.allocator.destroy(fixture);

    const source =
        \\a: &a [x, x, x, x, x, x, x, x, x, x]
        \\b: &b [*a, *a, *a, *a, *a, *a, *a, *a, *a, *a]
        \\c: &c [*b, *b, *b, *b, *b, *b, *b, *b, *b, *b]
        \\d: &d [*c, *c, *c, *c, *c, *c, *c, *c, *c, *c]
        \\
    ;

    const written = try fixture.written_of(source, write_options);

    try testing.expectEqualStrings(source, written);

    var block = write_options;

    block.layout = .block;

    const expanded = try fixture.written_of(source, block);

    try testing.expect(expanded.len < 2 * source.len);
    try testing.expectEqual(@as(usize, 30), std.mem.count(u8, expanded, "*"));
}

test "document markers come from the root records" {
    const fixture = try testing.allocator.create(WriteFixture);
    defer testing.allocator.destroy(fixture);

    const sources = [_][]const u8{
        "a\n--- b\n...\n--- c\n",
        "--- a\n...\n",
        "---\n...\n",
        "",
    };

    for (sources) |source| {
        try testing.expectEqualStrings(source, try fixture.written_of(source, write_options));
    }

    var versioned = write_options;

    versioned.version_directive = true;

    const expected = "%YAML 1.2\n--- a\n...\n%YAML 1.2\n--- b\n";

    try testing.expectEqualStrings(expected, try fixture.written_of("a\n--- b\n", versioned));
}

test "the layouts reshape a written document and keep its records" {
    const fixture = try testing.allocator.create(WriteFixture);
    defer testing.allocator.destroy(fixture);

    const source = "a: [1, {b: c}]\nd:\n  - e\n  - []\n";

    var options = write_options;

    options.layout = .block;
    options.sequence_indentless = true;
    options.indent = 4;

    const block = "a:\n- 1\n-   b: c\nd:\n- e\n- []\n";

    try testing.expectEqualStrings(block, try fixture.written_of(source, options));

    options.layout = .flow;
    options.indent = 2;

    const flow = "{a: [1, {b: c}], d: [e, []]}\n";

    try testing.expectEqualStrings(flow, try fixture.written_of(source, options));
}

test "a sink too small for the document fails the write with WriteFailed" {
    const fixture = try testing.allocator.create(WriteFixture);
    defer testing.allocator.destroy(fixture);

    var buffer: [16]u8 = undefined;
    var sink: std.Io.Writer = .fixed(&buffer);

    try fixture.original.parse("name: warbler\nports: [8080, 8443]\n", .{ .schema = .core });

    const refused = fixture.original.write(&sink, write_options);

    try testing.expectError(error.WriteFailed, refused);
    try testing.expectEqualStrings("name: warbler\npo", sink.buffered());
}

const kept_capacity: document_module.Capacity = .{
    .anchor_count_max = 64,
    .comment_count_max = 256,
    .node_count_max = 1024,
    .text_bytes_max = 64 * 1024,
};

const KeptDocument = document_module.DocumentType(kept_capacity);

const AttachmentFrame = struct {
    count: u32,
    end: u32,
    key: []const u8,
    mapping: bool,
    path_length: u32,
};

const Attachments = struct {
    buffer: [16 * 1024]u8,
    frames: [64]AttachmentFrame,
    path: [1024]u8,
};

fn attachments_render(document: *const KeptDocument, attachments: *Attachments) ![]const u8 {
    assert(document.document.comment_count <= kept_capacity.comment_count_max.?);
    assert(document.document.node_count <= kept_capacity.node_count_max);

    const nodes = document.storage.nodes[0..document.document.node_count];
    const slots = document.storage.comments[0..document.document.comment_count];
    var sink: std.Io.Writer = .fixed(&attachments.buffer);
    var path: std.Io.Writer = .fixed(&attachments.path);
    var depth: u32 = 0;
    var root_index: u32 = 0;
    var cursor: u32 = 0;

    for (nodes, 0..) |*record, position| {
        for (0..depth) |_| {
            if (attachments.frames[depth - 1].end > position) break;

            depth -= 1;
        }

        if (depth == 0) {
            path.end = 0;

            try path.print("d{d}", .{root_index});

            root_index += 1;
        } else {
            try segment_write(&path, &attachments.frames[depth - 1], record);
        }

        for (cursor..slots.len) |slot_index| {
            if (slots[slot_index].node != position) break;

            const slot = &slots[slot_index];

            try sink.print("{s} {t} {s}\n", .{ path.buffered(), slot.placement, slot.text });

            cursor += 1;
        }

        const collection = record.kind == .mapping or record.kind == .sequence;

        if (collection) {
            attachments.frames[depth] = .{
                .count = 0,
                .end = @intCast(position + record.span),
                .key = "",
                .mapping = record.kind == .mapping,
                .path_length = @intCast(path.end),
            };

            depth += 1;
        }
    }

    for (slots[cursor..]) |*slot| {
        assert(slot.node == storage_module.index_none);

        try sink.print("none {t} {s}\n", .{ slot.placement, slot.text });
    }

    return sink.buffered();
}

fn segment_write(
    path: *std.Io.Writer,
    frame: *AttachmentFrame,
    record: *const storage_module.Record,
) !void {
    assert(frame.path_length <= path.buffer.len);
    assert(frame.count < kept_capacity.node_count_max);

    path.end = frame.path_length;

    if (!frame.mapping) {
        try path.print("/{d}", .{frame.count});
    } else if (frame.count % 2 == 0) {
        frame.key = if (record.kind == .scalar) record.text else "?";

        try path.print("/{s}!key", .{frame.key});
    } else {
        try path.print("/{s}", .{frame.key});
    }

    frame.count += 1;
}

fn attachments_expect(golden: *const Golden) !void {
    assert(golden.source.len > 0);
    assert(golden.expected.len <= 1 << 16);

    const document = try testing.allocator.create(KeptDocument);
    defer testing.allocator.destroy(document);

    const attachments = try testing.allocator.create(Attachments);
    defer testing.allocator.destroy(attachments);

    try document.parse(golden.source, .{ .schema = .core });

    try testing.expectEqualStrings(golden.expected, try attachments_render(document, attachments));
}

const Golden = struct {
    expected: []const u8,
    source: []const u8,
};

fn goldens_expect(goldens: []const Golden) !void {
    assert(goldens.len > 0);
    assert(goldens.len <= 64);

    for (goldens) |*golden| try attachments_expect(golden);
}

const suite_goldens = [_]Golden{
    .{
        .expected =
        \\d0/a line # lala
        \\d0/b line # lala
        \\d0/c!key line #lala
        \\d0/?!key line # lala
        \\d0/? line # lala
        \\d0/?/0 line #lala
        \\d0/e line # lala
        \\d0/block line # lala
        \\
        ,
        .source =
        \\a: "double
        \\  quotes" # lala
        \\b: plain
        \\ value  # lala
        \\c  : #lala
        \\  d
        \\? # lala
        \\ - seq1
        \\: # lala
        \\ - #lala
        \\  seq2
        \\e: &node # lala
        \\ - x: y
        \\block: > # lala
        \\  abcde
        \\
        ,
    },
    .{
        .expected =
        \\d0 head # Leading comment line spaces are
        \\d0 head # neither content nor indentation.
        \\d0/Not indented/Flow style line # Leading spaces
        \\d0/Not indented/Flow style line # indentation.
        \\d0/Not indented/Flow style/0 line # in flow style
        \\d0/Not indented/Flow style/1 line # are neither
        \\d0/Not indented/Flow style/2 line # content nor
        \\
        ,
        .source = "  # Leading comment line spaces are\n" ++
            "   # neither content nor indentation.\n" ++
            "    \n" ++
            "Not indented:\n" ++
            " By one space: |\n" ++
            "    By four\n" ++
            "      spaces\n" ++
            " Flow style: [    # Leading spaces\n" ++
            "   By two,        # in flow style\n" ++
            "  Also by two,    # are neither\n" ++
            "  \tStill by two   # content nor\n" ++
            "    ]             # indentation.\n",
    },
    .{
        .expected =
        \\d0/1 head # comment
        \\
        ,
        .source =
        \\---
        \\[ word1
        \\# comment
        \\, word2]
        \\
        ,
    },
    .{
        .expected =
        \\d0/hr!key line # 1998 hr ranking
        \\d0/rbi/0 head # 1998 rbi ranking
        \\
        ,
        .source =
        \\---
        \\hr: # 1998 hr ranking
        \\  - Mark McGwire
        \\  - Sammy Sosa
        \\rbi:
        \\  # 1998 rbi ranking
        \\  - Sammy Sosa
        \\  - Ken Griffey
        \\
        ,
    },
};

test "golden attachment for suite cases RZP5, 6HB6, 7TMG, and J9HZ" {
    try goldens_expect(&suite_goldens);
}

const node_test_goldens = [_]Golden{
    .{
        .expected =
        \\d0/a!key line # AI
        \\
        ,
        .source =
        \\a: # AI
        \\  - b
        \\c:
        \\  - d
        \\
        ,
    },
    .{
        .expected =
        \\d0/a/0 head # HM
        \\d0/a/0 line # HB1
        \\d0/a/0/b!key head # HB2
        \\d0/a/0/b!key line # IB
        \\d0/a/0/b line # IC
        \\
        ,
        .source =
        \\a:
        \\  # HM
        \\  - # HB1
        \\    # HB2
        \\    b: # IB
        \\      c # IC
        \\
        ,
    },
    .{
        .expected =
        \\d0 head # DH1
        \\d0 head # DH2
        \\d0 head # H1
        \\d0 head # H2
        \\d0 line # I
        \\d0 foot # F1
        \\d0 foot # F2
        \\d0 foot # DF1
        \\d0 foot # DF2
        \\
        ,
        .source =
        \\# DH1
        \\
        \\# DH2
        \\
        \\# H1
        \\# H2
        \\true # I
        \\# F1
        \\# F2
        \\
        \\# DF1
        \\
        \\# DF2
        \\
        ,
    },
    .{
        .expected =
        \\d0 head # DH1
        \\d0 head # DH2
        \\d0 head # HA1
        \\d0 head # HA2
        \\d0 foot # DF1
        \\d0 foot # DF2
        \\d0/ka!key foot # FA1
        \\d0/ka!key foot # FA2
        \\d0/ka line # IA
        \\d0/kb!key head # HB1
        \\d0/kb!key head # HB2
        \\d0/kb!key foot # FB1
        \\d0/kb!key foot # FB2
        \\d0/kb line # IB
        \\
        ,
        .source =
        \\# DH1
        \\
        \\# DH2
        \\
        \\# HA1
        \\# HA2
        \\ka: va # IA
        \\# FA1
        \\# FA2
        \\
        \\# HB1
        \\# HB2
        \\kb: vb # IB
        \\# FB1
        \\# FB2
        \\
        \\# DF1
        \\
        \\# DF2
        \\
        ,
    },
    .{
        .expected =
        \\d0 head # DH1
        \\d0 head # DH2
        \\d0 head # HA1
        \\d0 head # HA2
        \\d0 foot # DF1
        \\d0 foot # DF2
        \\d0/0 line # IA
        \\d0/0 foot # FA1
        \\d0/0 foot # FA2
        \\d0/1 head # HB1
        \\d0/1 head # HB2
        \\d0/1 line # IB
        \\d0/1 foot # FB1
        \\d0/1 foot # FB2
        \\
        ,
        .source =
        \\# DH1
        \\
        \\# DH2
        \\
        \\# HA1
        \\# HA2
        \\- la # IA
        \\# FA1
        \\# FA2
        \\
        \\# HB1
        \\# HB2
        \\- lb # IB
        \\# FB1
        \\# FB2
        \\
        \\# DF1
        \\
        \\# DF2
        \\
        ,
    },
    .{
        .expected =
        \\d0 head # DH1
        \\d0/0 line # IA
        \\d0/1 head # HB1
        \\
        ,
        .source =
        \\# DH1
        \\
        \\- la # IA
        \\# HB1
        \\- lb
        \\
        ,
    },
    .{
        .expected =
        \\d0/0 line # IA
        \\d0/1 line # IB
        \\d0/2 line # IC
        \\
        ,
        .source =
        \\- la # IA
        \\- lb # IB
        \\- lc # IC
        \\
        ,
    },
    .{
        .expected =
        \\d0 head # DH1
        \\d0 head # HL1
        \\d0/0/1 head # HB1
        \\
        ,
        .source =
        \\# DH1
        \\
        \\# HL1
        \\- - la
        \\  # HB1
        \\  - lb
        \\
        ,
    },
    .{
        .expected =
        \\d0 head # DH1
        \\d0 head # HL1
        \\d0/0 line # HA1
        \\d0/0/1 head # HB1
        \\
        ,
        .source =
        \\# DH1
        \\
        \\# HL1
        \\- # HA1
        \\  - la
        \\  # HB1
        \\  - lb
        \\
        ,
    },
    .{
        .expected =
        \\d0 head # DH1
        \\d0 head # HL1
        \\d0/0 line # HA1
        \\d0/0/1 head # HB1
        \\
        ,
        .source =
        \\# DH1
        \\
        \\# HL1
        \\- # HA1
        \\
        \\  - la
        \\  # HB1
        \\  - lb
        \\
        ,
    },
    .{
        .expected =
        \\d0 head # DH1
        \\d0 head # HA1
        \\d0 foot # DF1
        \\d0/ka/kb!key head # HB1
        \\d0/ka/kb/0 head # HC1
        \\d0/ka/kb/0 head # HC2
        \\d0/ka/kb/0 line # IC
        \\d0/ka/kb/0 foot # FC1
        \\d0/ka/kb/0 foot # FC2
        \\d0/ka/kb/1 head # HD1
        \\d0/ka/kb/1 line # ID
        \\d0/ka/kb/1 foot # FD1
        \\
        ,
        .source =
        \\# DH1
        \\
        \\# HA1
        \\ka:
        \\  # HB1
        \\  kb:
        \\    # HC1
        \\    # HC2
        \\    - lc # IC
        \\    # FC1
        \\    # FC2
        \\
        \\    # HD1
        \\    - ld # ID
        \\    # FD1
        \\
        \\# DF1
        \\
        ,
    },
    .{
        .expected =
        \\d0 head # DH1
        \\d0 head # HA1
        \\d0 foot # DF1
        \\d0/ka/kb!key head # HB1
        \\d0/ka/kb/0 head # HC1
        \\d0/ka/kb/0 head # HC2
        \\d0/ka/kb/0 line # IC
        \\d0/ka/kb/0 foot # FC1
        \\d0/ka/kb/0 foot # FC2
        \\d0/ka/kb/1 head # HD1
        \\d0/ka/kb/1 line # ID
        \\d0/ka/kb/1 foot # FD1
        \\
        ,
        .source =
        \\# DH1
        \\
        \\# HA1
        \\ka:
        \\  # HB1
        \\  kb:
        \\    # HC1
        \\    # HC2
        \\    - lc # IC
        \\    # FC1
        \\    # FC2
        \\
        \\    # HD1
        \\    - ld # ID
        \\    # FD1
        \\ke: ve
        \\
        \\# DF1
        \\
        ,
    },
    .{
        .expected =
        \\d0 head # DH1
        \\d0 head # DH2
        \\d0 head # HA1
        \\d0 head # HA2
        \\d0 foot # DF1
        \\d0 foot # DF2
        \\d0/ka!key foot # FA1
        \\d0/ka!key foot # FA2
        \\d0/ka/kb!key head # HB1
        \\d0/ka/kb!key head # HB2
        \\d0/ka/kb!key foot # FB1
        \\d0/ka/kb!key foot # FB2
        \\d0/ka/kb/kc!key head # HC1
        \\d0/ka/kb/kc!key head # HC2
        \\d0/ka/kb/kc!key foot # FC1
        \\d0/ka/kb/kc!key foot # FC2
        \\d0/ka/kb/kc/kd!key head # HD1
        \\d0/ka/kb/kc/kd!key head # HD2
        \\d0/ka/kb/kc/kd!key foot # FD1
        \\d0/ka/kb/kc/kd!key foot # FD2
        \\d0/ke!key head # HE1
        \\d0/ke!key head # HE2
        \\d0/ke!key foot # FE1
        \\d0/ke!key foot # FE2
        \\
        ,
        .source =
        \\# DH1
        \\
        \\# DH2
        \\
        \\# HA1
        \\# HA2
        \\ka:
        \\  # HB1
        \\  # HB2
        \\  kb:
        \\    # HC1
        \\    # HC2
        \\    kc:
        \\      # HD1
        \\      # HD2
        \\      kd: vd
        \\      # FD1
        \\      # FD2
        \\    # FC1
        \\    # FC2
        \\  # FB1
        \\  # FB2
        \\# FA1
        \\# FA2
        \\
        \\# HE1
        \\# HE2
        \\ke: ve
        \\# FE1
        \\# FE2
        \\
        \\# DF1
        \\
        \\# DF2
        \\
        ,
    },
    .{
        .expected =
        \\d0/ka!key foot # FA1
        \\
        ,
        .source =
        \\ka:
        \\  kb: vb
        \\# FA1
        \\
        \\kc: vc
        \\
        ,
    },
    .{
        .expected =
        \\d0/kc!key head # HC1
        \\
        ,
        .source =
        \\ka:
        \\  kb: vb
        \\# HC1
        \\kc: vc
        \\
        ,
    },
    .{
        .expected =
        \\d0/ka!key line # IA
        \\d0/ka/kb!key line # IB
        \\
        ,
        .source =
        \\ka: # IA
        \\  kb: # IB
        \\
        ,
    },
    .{
        .expected =
        \\d0 head # HA1
        \\d0/ka/kb!key head # HB1
        \\d0/ka/kb!key foot # FB1
        \\d0/kc!key head # HC1
        \\d0/kc!key head # HC2
        \\d0/kc!key foot # FC1
        \\d0/kc!key foot # FC2
        \\
        ,
        .source =
        \\# HA1
        \\ka:
        \\  # HB1
        \\  kb: vb
        \\  # FB1
        \\# HC1
        \\# HC2
        \\kc: vc
        \\# FC1
        \\# FC2
        \\
        ,
    },
    .{
        .expected =
        \\d0 head # H1
        \\d0 line # I
        \\d0 foot # F1
        \\
        ,
        .source =
        \\# H1
        \\[la, lb] # I
        \\# F1
        \\
        ,
    },
    .{
        .expected =
        \\d0 head # DH1
        \\d0 head # SH1
        \\d0 foot # SF1
        \\d0 foot # DF1
        \\d0/0 head # HA1
        \\d0/0 line # IA
        \\d0/0 foot # FA1
        \\d0/1 head # HB1
        \\d0/1 line # IB
        \\d0/1 foot # FB1
        \\
        ,
        .source =
        \\# DH1
        \\
        \\# SH1
        \\[
        \\  # HA1
        \\  la, # IA
        \\  # FA1
        \\
        \\  # HB1
        \\  lb, # IB
        \\  # FB1
        \\]
        \\# SF1
        \\
        \\# DF1
        \\
        ,
    },
    .{
        .expected =
        \\d0 head # DH1
        \\d0 head # SH1
        \\d0 foot # SF1
        \\d0 foot # DF1
        \\d0/0 head # HA1
        \\d0/0 foot # FA1
        \\d0/1 head # HB1
        \\d0/1 foot # FB1
        \\
        ,
        .source =
        \\# DH1
        \\
        \\# SH1
        \\[
        \\  # HA1
        \\  la,
        \\  # FA1
        \\
        \\  # HB1
        \\  lb,
        \\  # FB1
        \\]
        \\# SF1
        \\
        \\# DF1
        \\
        ,
    },
    .{
        .expected =
        \\d0 head # DH1
        \\d0 head # MH1
        \\d0 foot # MF1
        \\d0 foot # DF1
        \\d0/ka!key head # HA1
        \\d0/ka!key foot # FA1
        \\d0/ka line # IA
        \\d0/kb!key head # HB1
        \\d0/kb!key foot # FB1
        \\d0/kb line # IB
        \\
        ,
        .source =
        \\# DH1
        \\
        \\# MH1
        \\{
        \\  # HA1
        \\  ka: va, # IA
        \\  # FA1
        \\
        \\  # HB1
        \\  kb: vb, # IB
        \\  # FB1
        \\}
        \\# MF1
        \\
        \\# DF1
        \\
        ,
    },
    .{
        .expected =
        \\d0 head # DH1
        \\d0 head # MH1
        \\d0 foot # MF1
        \\d0 foot # DF1
        \\d0/ka!key head # HA1
        \\d0/ka!key foot # FA1
        \\d0/kb!key head # HB1
        \\d0/kb!key foot # FB1
        \\
        ,
        .source =
        \\# DH1
        \\
        \\# MH1
        \\{
        \\  # HA1
        \\  ka: va,
        \\  # FA1
        \\
        \\  # HB1
        \\  kb: vb,
        \\  # FB1
        \\}
        \\# MF1
        \\
        \\# DF1
        \\
        ,
    },
    .{
        .expected =
        \\d0 head # DH1
        \\d0 head # DH2
        \\d0 head # HA1
        \\d0 head # HA2
        \\d0 foot # DF1
        \\d0 foot # DF2
        \\d0/0 line # IA
        \\d0/0 foot # FA1
        \\d0/0 foot # FA2
        \\d0/1 head # HB1
        \\d0/1 head # HB2
        \\d0/1 line # IB
        \\d0/1 foot # FB1
        \\d0/1 foot # FB2
        \\
        ,
        .source =
        \\# DH1
        \\
        \\# DH2
        \\
        \\# HA1
        \\# HA2
        \\- &x la # IA
        \\# FA1
        \\# FA2
        \\
        \\# HB1
        \\# HB2
        \\- *x # IB
        \\# FB1
        \\# FB2
        \\
        \\# DF1
        \\
        \\# DF2
        \\
        ,
    },
};

test "golden attachment for the comment cases of go-yaml node_test.go" {
    try goldens_expect(&node_test_goldens);
}

const marker_goldens = [_]Golden{
    .{
        .expected =
        \\d0/key/0 head # above the first item
        \\d0/key/0 line # on a
        \\d0/key/1 head # between
        \\d0/next!key head # after the last item
        \\
        ,
        .source =
        \\key:
        \\# above the first item
        \\- a # on a
        \\# between
        \\- b
        \\# after the last item
        \\next: c
        \\
        ,
    },
    .{
        .expected =
        \\d0/0/key/0 head # head of b
        \\d0/0/key/0 line # line of b
        \\d0/0/key/0 foot # foot of b
        \\
        ,
        .source =
        \\- key:
        \\  # head of b
        \\  - b # line of b
        \\  # foot of b
        \\
        ,
    },
    .{
        .expected =
        \\d0 head # before the start marker
        \\d0 head # on the start marker
        \\d0/a!key foot # before the end marker
        \\d0/a line # on a
        \\d1 head # on the end marker
        \\d1 head # between documents
        \\d1 foot # after the last document
        \\
        ,
        .source =
        \\# before the start marker
        \\--- # on the start marker
        \\a: 1 # on a
        \\# before the end marker
        \\... # on the end marker
        \\# between documents
        \\--- b
        \\# after the last document
        \\
        ,
    },
    .{
        .expected =
        \\d0 head # after the directive
        \\
        ,
        .source =
        \\%YAML 1.2
        \\# after the directive
        \\--- a
        \\
        ,
    },
    .{
        .expected =
        \\none foot # only
        \\none foot # comments
        \\
        ,
        .source =
        \\# only
        \\
        \\# comments
        \\
        ,
    },
};

test "golden attachment for indentless sequences, document markers, and a comment-only stream" {
    try goldens_expect(&marker_goldens);
}

test "a blank line above the lone key indicator of a first entry survives a property line" {
    const source =
        \\k: &h
        \\
        \\  ?
        \\    # c
        \\    - x
        \\  : v
        \\
    ;

    const document = try testing.allocator.create(KeptDocument);
    defer testing.allocator.destroy(document);

    try document.parse(source, .{ .schema = .core });

    var buffer: [256]u8 = undefined;
    var sink: std.Io.Writer = .fixed(&buffer);

    try document.write(&sink, .{ .indent = 2, .layout = .block });
    try testing.expectEqualStrings(source, sink.buffered());
}

test "a comment left of a pending empty item stays ahead of the comments below it" {
    const source =
        \\- - a:
        \\      - k: v
        \\        # f
        \\#
        \\      -
        \\      # a: b
        \\  - x
        \\
    ;

    const expected =
        \\- - a:
        \\      - k: v
        \\        # f
        \\      -
        \\      #
        \\      # a: b
        \\  - x
        \\
    ;

    const document = try testing.allocator.create(KeptDocument);
    defer testing.allocator.destroy(document);

    try document.parse(source, .{ .schema = .core });

    var buffer: [256]u8 = undefined;
    var sink: std.Io.Writer = .fixed(&buffer);

    try document.write(&sink, .{ .indent = 2, .layout = .block });
    try testing.expectEqualStrings(expected, sink.buffered());
}

test "a comment between a tagged collection and its flow body heads the collection" {
    const cases = [_]struct { source: []const u8, expected: []const u8 }{
        .{ .source = "- !!seq\n# c\n  [a]\n", .expected = "# c\n- !!seq [a]\n" },
        .{ .source = "[ !!seq\n# c\n [a]]\n", .expected = "[\n  # c\n  !!seq [a]]\n" },
    };

    const document = try testing.allocator.create(KeptDocument);
    defer testing.allocator.destroy(document);

    for (cases) |case| {
        var first: [256]u8 = undefined;
        var second: [256]u8 = undefined;
        var sink: std.Io.Writer = .fixed(&first);

        try document.parse(case.source, .{ .schema = .core });
        try document.write(&sink, .{ .indent = 2, .layout = .preserve });
        try testing.expectEqualStrings(case.expected, sink.buffered());

        sink = .fixed(&second);

        try document.parse(case.expected, .{ .schema = .core });
        try document.write(&sink, .{ .indent = 2, .layout = .preserve });
        try testing.expectEqualStrings(case.expected, sink.buffered());
    }
}

test "a blank line before a hoisted comment merges with the blank line before its parent" {
    const cases = [_]struct { layout: Writer.Layout, source: []const u8, expected: []const u8 }{
        .{
            .layout = .preserve,
            .source = "# a\n\n- &h !local\n\n  # b\n  {}\n",
            .expected = "# a\n\n# b\n- &h !local {}\n",
        },
        .{
            .layout = .block,
            .source = "# a\n\n{\n\nb: c}\n",
            .expected = "# a\n\nb: c\n",
        },
    };

    const document = try testing.allocator.create(KeptDocument);
    defer testing.allocator.destroy(document);

    for (cases) |case| {
        var first: [256]u8 = undefined;
        var second: [256]u8 = undefined;
        var sink: std.Io.Writer = .fixed(&first);

        try document.parse(case.source, .{ .schema = .core });
        try document.write(&sink, .{ .indent = 2, .layout = case.layout });
        try testing.expectEqualStrings(case.expected, sink.buffered());

        sink = .fixed(&second);

        try document.parse(case.expected, .{ .schema = .core });
        try document.write(&sink, .{ .indent = 2, .layout = case.layout });
        try testing.expectEqualStrings(case.expected, sink.buffered());
    }
}

test "a blank line after a document marker stays when a block scalar ends the document before" {
    const source =
        \\--- >-
        \\  a
        \\...
        \\---
        \\
        \\- x
        \\--- >+
        \\  b
        \\
        \\---
        \\
        \\y
        \\
    ;

    const document = try testing.allocator.create(KeptDocument);
    defer testing.allocator.destroy(document);

    try document.parse(source, .{ .schema = .core });

    var buffer: [256]u8 = undefined;
    var sink: std.Io.Writer = .fixed(&buffer);

    try document.write(&sink, .{ .indent = 2, .layout = .block });
    try testing.expectEqualStrings(source, sink.buffered());
}

test "a blank line above a compact key or item stays above it, so a second write changes nothing" {
    const sources = [_][]const u8{
        "m: !t\n\n  ? - a\n  : v\n",
        "k: !t\n\n  - - a\n",
        "k:\n\n  !t\n  ? - - a\n  : v\n",
    };

    const document = try testing.allocator.create(KeptDocument);
    defer testing.allocator.destroy(document);

    for (sources) |source| {
        var first: [256]u8 = undefined;
        var second: [256]u8 = undefined;
        var sink: std.Io.Writer = .fixed(&first);

        try document.parse(source, .{ .schema = .core });
        try document.write(&sink, .{ .indent = 2, .layout = .block });

        const written = sink.buffered();

        try testing.expect(std.mem.indexOf(u8, written, "\n\n") != null);

        sink = .fixed(&second);

        try document.parse(written, .{ .schema = .core });
        try document.write(&sink, .{ .indent = 2, .layout = .block });
        try testing.expectEqualStrings(written, sink.buffered());
    }
}

test "a blank line above a node with no head comment comes back as an empty head" {
    const document = try testing.allocator.create(KeptDocument);
    defer testing.allocator.destroy(document);

    try document.parse("a: 1\n\nb: 2\n\n# c\nd: 3\n", .{ .schema = .core });

    var entries = document.entries(document.root(0));
    const first = entries.next() orelse return error.EntryMissing;
    const second = entries.next() orelse return error.EntryMissing;
    const third = entries.next() orelse return error.EntryMissing;
    var quiet = document.comments(first.key);
    const nothing = quiet.next();

    try testing.expectEqual(@as(?Comment, null), nothing);

    var blank = document.comments(second.key);
    const lone = blank.next() orelse return error.BlankMissing;
    const lone_after = blank.next();

    try testing.expectEqual(Comment.Placement.head, lone.placement);
    try testing.expectEqualStrings("", lone.text);
    try testing.expectEqual(@as(?Comment, null), lone_after);

    var headed = document.comments(third.key);
    const above = headed.next() orelse return error.BlankMissing;
    const comment = headed.next() orelse return error.CommentMissing;
    const headed_after = headed.next();

    try testing.expectEqualStrings("", above.text);
    try testing.expectEqualStrings("# c", comment.text);
    try testing.expectEqual(@as(?Comment, null), headed_after);
}

test "a flow item after a scalar holding a blank line takes no blank, so a write keeps the source" {
    const Case = struct {
        indent: u8,
        source: []const u8,
    };

    const cases = [_]Case{
        .{ .indent = 6, .source = "[\\\n\n\n      ---?, chain]\n" },
        .{ .indent = 2, .source = "? &k [a, b?\n\n    ---, c]\n: *k\n" },
    };

    const document = try testing.allocator.create(KeptDocument);
    defer testing.allocator.destroy(document);

    for (cases) |case| {
        var buffer: [256]u8 = undefined;
        var sink: std.Io.Writer = .fixed(&buffer);

        try document.parse(case.source, .{ .schema = .core });
        try document.write(&sink, .{ .indent = case.indent, .layout = .preserve });
        try testing.expectEqualStrings(case.source, sink.buffered());
    }
}

test "a comment above an empty flow key with line comments after it stays ahead of them" {
    const source = "a: {\n\n    # x\n    :  # c\n    , # t\n    k: v}\n";
    const document = try testing.allocator.create(KeptDocument);
    defer testing.allocator.destroy(document);

    var buffer: [256]u8 = undefined;
    var sink: std.Io.Writer = .fixed(&buffer);

    try document.parse(source, .{ .schema = .core });
    try document.write(&sink, .{ .indent = 2, .layout = .preserve });
    try testing.expectEqualStrings(source, sink.buffered());
}
