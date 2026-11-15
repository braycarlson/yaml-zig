const std = @import("std");

const parser_module = @import("parser.zig");
const round_trip = @import("round_trip.zig");
const writer_module = @import("writer.zig");

const assert = std.debug.assert;
const testing = std.testing;

const Event = parser_module.Event;
const Parser = parser_module.Parser;
const Writer = writer_module.Writer;

const event_count_max: u32 = 1024;
const output_bytes_max: u32 = 64 * 1024;
const staged_count_max: u32 = 64;

const options_default: Writer.Options = .{
    .indent = 2,
    .layout = .preserve,
    .sequence_indentless = false,
    .utf8 = .checked,
    .version_directive = false,
    .width = 0,
};

const Place = enum {
    block_item,
    block_key,
    block_value,
    flow_item,
    flow_key,
    flow_value,
    root,
};

const Case = struct {
    expected: []const u8,
    place: Place,
    scalar: Event.Scalar,
};

const Row = struct {
    block: []const u8,
    flow: []const u8,
    text: []const u8,
};

const Styled = struct {
    expected: []const u8,
    style: parser_module.ScalarStyle,
};

const Fixture = struct {
    events: [event_count_max]Event,
    output: [output_bytes_max]u8,
    parser: Parser,
    rewritten: [output_bytes_max]u8,
    staged: [staged_count_max]Event,
    text: [output_bytes_max]u8,

    fn stream_written(
        fixture: *Fixture,
        events: []const Event,
        options: Writer.Options,
    ) ![]const u8 {
        assert(events.len >= 2);
        assert(options.indent >= 1);

        const written = try events_write(events, options, &fixture.output);
        const reparsed = try fixture.reparse(written);

        const sources: round_trip.Sources = .{
            .original = .{ .events = events },
            .written = .{ .events = reparsed },
        };

        const verdict = try round_trip.streams_equivalent(sources, .{
            .layout = options.layout,
            .style_exact = false,
            .version_directive = options.version_directive,
        });

        if (verdict == .differed) {
            std.debug.print("{s}, written as:\n{s}\n", .{ verdict.differed, written });
        }

        try testing.expect(verdict == .matched);

        const rewritten = try events_write(reparsed, options, &fixture.rewritten);

        try testing.expectEqualStrings(written, rewritten);

        assert(written.len <= output_bytes_max);

        return written;
    }

    fn document_written(
        fixture: *Fixture,
        nodes: []const Event,
        options: Writer.Options,
    ) ![]const u8 {
        assert(nodes.len > 0);
        assert(nodes.len + 4 <= staged_count_max);
        assert(options.indent >= 1);

        const staged = &fixture.staged;

        staged[0] = .stream_start;
        staged[1] = .{ .document_start = .{ .explicit = false } };

        @memcpy(staged[2..][0..nodes.len], nodes);

        staged[nodes.len + 2] = .{ .document_end = .{ .explicit = false } };
        staged[nodes.len + 3] = .stream_end;

        return fixture.stream_written(staged[0 .. nodes.len + 4], options);
    }

    fn scalar_written(
        fixture: *Fixture,
        place: Place,
        scalar: *const Event.Scalar,
        options: Writer.Options,
    ) ![]const u8 {
        assert(scalar.text.len < output_bytes_max);
        assert(options.indent >= 1);

        const node: Event = .{ .scalar = scalar.* };
        const key: Event = .{ .scalar = .{ .text = "k" } };
        const value: Event = .{ .scalar = .{ .text = "v" } };
        const block_mapping: Event = .{ .mapping_start = .{ .style = .block } };
        const block_sequence: Event = .{ .sequence_start = .{ .style = .block } };
        const flow_mapping: Event = .{ .mapping_start = .{ .style = .flow } };
        const flow_sequence: Event = .{ .sequence_start = .{ .style = .flow } };

        const nodes: []const Event = switch (place) {
            .block_item => &.{ block_sequence, node, .sequence_end },
            .block_key => &.{ block_mapping, node, value, .mapping_end },
            .block_value => &.{ block_mapping, key, node, .mapping_end },
            .flow_item => &.{ flow_sequence, node, .sequence_end },
            .flow_key => &.{ flow_mapping, node, value, .mapping_end },
            .flow_value => &.{ flow_mapping, key, node, .mapping_end },
            .root => &.{node},
        };

        return fixture.document_written(nodes, options);
    }

    fn reparse(fixture: *Fixture, source: []const u8) ![]const Event {
        assert(source.len < output_bytes_max);
        assert(fixture.events.len == event_count_max);

        fixture.parser.init(&fixture.text, source);

        for (&fixture.events, 0..) |*slot, index| {
            const event = fixture.parser.next() catch |err| {
                std.debug.print("the written bytes do not parse ({t}):\n{s}\n", .{ err, source });

                return err;
            };

            slot.* = event.*;

            if (event.* == .stream_end) return fixture.events[0 .. index + 1];
        }

        return error.EventsExhausted;
    }

    fn cases_check(fixture: *Fixture, cases: []const Case, options: Writer.Options) !void {
        assert(cases.len > 0);
        assert(options.indent >= 1);

        for (cases) |*case| {
            const written = try fixture.scalar_written(case.place, &case.scalar, options);

            try testing.expectEqualStrings(case.expected, written);
        }
    }
};

fn events_write(events: []const Event, options: Writer.Options, buffer: []u8) ![]const u8 {
    assert(events.len >= 2);
    assert(buffer.len == output_bytes_max);
    assert(options.indent >= 1);

    var sink: std.Io.Writer = .fixed(buffer);
    var writer: Writer = undefined;

    writer.init(&sink, options);

    for (events) |*event| try writer.emit(event);

    assert(writer.depth == 0);

    return sink.buffered();
}

test "plain text stays plain only where it reads back the same, in block and in flow" {
    const fixture = try testing.allocator.create(Fixture);
    defer testing.allocator.destroy(fixture);

    const rows = [_]Row{
        .{ .text = "-a", .block = "k: -a\n", .flow = "[-a]\n" },
        .{ .text = "- a", .block = "k: '- a'\n", .flow = "['- a']\n" },
        .{ .text = "-", .block = "k: '-'\n", .flow = "['-']\n" },
        .{ .text = "--", .block = "k: --\n", .flow = "[--]\n" },
        .{ .text = "---", .block = "k: '---'\n", .flow = "['---']\n" },
        .{ .text = "--- x", .block = "k: '--- x'\n", .flow = "['--- x']\n" },
        .{ .text = "---x", .block = "k: ---x\n", .flow = "[---x]\n" },
        .{ .text = "?a", .block = "k: ?a\n", .flow = "['?a']\n" },
        .{ .text = ":a", .block = "k: :a\n", .flow = "[':a']\n" },
        .{ .text = "a:b", .block = "k: a:b\n", .flow = "[a:b]\n" },
        .{ .text = "a:", .block = "k: 'a:'\n", .flow = "['a:']\n" },
        .{ .text = "a: b", .block = "k: 'a: b'\n", .flow = "['a: b']\n" },
        .{ .text = "a #b", .block = "k: 'a #b'\n", .flow = "['a #b']\n" },
        .{ .text = "a#b", .block = "k: a#b\n", .flow = "[a#b]\n" },
        .{ .text = "a,b", .block = "k: a,b\n", .flow = "['a,b']\n" },
        .{ .text = "[x", .block = "k: '[x'\n", .flow = "['[x']\n" },
        .{ .text = "~", .block = "k: ~\n", .flow = "[~]\n" },
        .{ .text = "", .block = "k:\n", .flow = "[null]\n" },
        .{ .text = " a", .block = "k: ' a'\n", .flow = "[' a']\n" },
        .{ .text = "a ", .block = "k: 'a '\n", .flow = "['a ']\n" },
        .{ .text = "\ta", .block = "k: '\ta'\n", .flow = "['\ta']\n" },
        .{ .text = "a\t", .block = "k: 'a\t'\n", .flow = "['a\t']\n" },
        .{ .text = "a\tb", .block = "k: a\tb\n", .flow = "[a\tb]\n" },
        .{ .text = "a\n- b", .block = "k: a\n\n  - b\n", .flow = "[a\n\n  - b]\n" },
        .{ .text = "a\n#b", .block = "k: 'a\n\n  #b'\n", .flow = "['a\n\n  #b']\n" },
        .{ .text = "%a", .block = "k: '%a'\n", .flow = "['%a']\n" },
        .{ .text = "@a", .block = "k: '@a'\n", .flow = "['@a']\n" },
        .{ .text = "a'b", .block = "k: a'b\n", .flow = "[a'b]\n" },
    };

    for (rows) |row| {
        const scalar: Event.Scalar = .{ .text = row.text };
        const block = try fixture.scalar_written(.block_value, &scalar, options_default);

        try testing.expectEqualStrings(row.block, block);

        const flow = try fixture.scalar_written(.flow_item, &scalar, options_default);

        try testing.expectEqualStrings(row.flow, flow);
    }
}

test "quoting falls back from single to double only where single quotes cannot hold the text" {
    const fixture = try testing.allocator.create(Fixture);
    defer testing.allocator.destroy(fixture);

    const cases = [_]Case{
        .{
            .expected = "k: 'it''s'\n",
            .place = .block_value,
            .scalar = .{ .style = .single_quoted, .text = "it's" },
        },
        .{
            .expected = "k: 'a\n\n  b'\n",
            .place = .block_value,
            .scalar = .{ .style = .single_quoted, .text = "a\nb" },
        },
        .{
            .expected = "k: 'a\n\n  '\n",
            .place = .block_value,
            .scalar = .{ .style = .single_quoted, .text = "a\n" },
        },
        .{
            .expected = "k: '\n\n  a'\n",
            .place = .block_value,
            .scalar = .{ .style = .single_quoted, .text = "\na" },
        },
        .{
            .expected = "k: \"a\\n b\"\n",
            .place = .block_value,
            .scalar = .{ .text = "a\n b" },
        },
        .{
            .expected = "k: \"a \\nb\"\n",
            .place = .block_value,
            .scalar = .{ .text = "a \nb" },
        },
        .{
            .expected = "k: \"a\\n\tb\"\n",
            .place = .block_value,
            .scalar = .{ .style = .single_quoted, .text = "a\n\tb" },
        },
    };

    try fixture.cases_check(&cases, options_default);
    try testing.expectEqual(@as(usize, 7), cases.len);
}

test "double quotes escape every special codepoint and nothing else" {
    const fixture = try testing.allocator.create(Fixture);
    defer testing.allocator.destroy(fixture);

    const text = "\x00\x07\x08\t\n\x0b\x0c\r\x1b\"\\\u{85}\u{2028}\u{2029}" ++
        "\x01\x7f\u{80}\u{9f}\u{feff}\u{fffe}\u{ffff}\u{a0}\u{e9}\u{1f600}/ ";

    const expected = "\"\\0\\a\\b\t\\n\\v\\f\\r\\e\\\"\\\\\\N\\L\\P" ++
        "\\x01\\x7F\\x80\\x9F\\uFEFF\\uFFFE\\uFFFF\u{a0}\u{e9}\u{1f600}/ \"\n";

    const cases = [_]Case{
        .{
            .expected = expected,
            .place = .root,
            .scalar = .{ .style = .double_quoted, .text = text },
        },
        .{
            .expected = "\"\\N\"\n",
            .place = .root,
            .scalar = .{ .text = "\u{85}" },
        },
        .{
            .expected = "\"a\\rb\\n\"\n",
            .place = .root,
            .scalar = .{ .style = .literal, .text = "a\rb\n" },
        },
        .{
            .expected = "[\"\\x7F\"]\n",
            .place = .flow_item,
            .scalar = .{ .style = .single_quoted, .text = "\x7f" },
        },
    };

    try fixture.cases_check(&cases, options_default);
    try testing.expect(std.unicode.utf8ValidateSlice(expected));
}

test "block scalar headers carry the indentation and chomping each text needs" {
    const fixture = try testing.allocator.create(Fixture);
    defer testing.allocator.destroy(fixture);

    const texts = [_][2][]const u8{
        .{ "", "- |-\n" },
        .{ "a", "- |-\n  a\n" },
        .{ "a\n", "- |\n  a\n" },
        .{ "a\n\n", "- |+\n  a\n\n" },
        .{ "\n", "- |2+\n\n" },
        .{ "\n\n", "- |2+\n\n\n" },
        .{ " x", "- |2-\n   x\n" },
        .{ "\tx", "- |2-\n  \tx\n" },
    };

    for (texts) |pair| {
        const scalar: Event.Scalar = .{ .style = .literal, .text = pair[0] };
        const written = try fixture.scalar_written(.block_item, &scalar, options_default);

        try testing.expectEqualStrings(pair[1], written);
    }

    const cases = [_]Case{
        .{
            .expected = "- >2\n\n\n  # detected\n",
            .place = .block_item,
            .scalar = .{ .style = .folded, .text = "\n\n# detected\n" },
        },
        .{
            .expected = "|\n  a\n",
            .place = .root,
            .scalar = .{ .style = .literal, .text = "a\n" },
        },
        .{
            .expected = "|\n\n  a\n",
            .place = .root,
            .scalar = .{ .style = .literal, .text = "\na\n" },
        },
        .{
            .expected = "\" x\\n\"\n",
            .place = .root,
            .scalar = .{ .style = .literal, .text = " x\n" },
        },
        .{
            .expected = "\"\\n\tx\"\n",
            .place = .root,
            .scalar = .{ .style = .folded, .text = "\n\tx" },
        },
    };

    try fixture.cases_check(&cases, options_default);
}

test "folded scalars keep more indented lines and trailing spaces exactly" {
    const fixture = try testing.allocator.create(Fixture);
    defer testing.allocator.destroy(fixture);

    const texts = [_][2][]const u8{
        .{ "a\nb\n", "- >\n  a\n\n  b\n" },
        .{ "a\n b\nc\n", "- >\n  a\n   b\n  c\n" },
        .{ "a  \nb\n", "- >\n  a  \n\n  b\n" },
        .{ "a\n\nb", "- >-\n  a\n\n\n  b\n" },
        .{ " a\nb", "- >2-\n   a\n  b\n" },
    };

    for (texts) |pair| {
        const scalar: Event.Scalar = .{ .style = .folded, .text = pair[0] };
        const written = try fixture.scalar_written(.block_item, &scalar, options_default);

        try testing.expectEqualStrings(pair[1], written);
    }

    const literal: Event.Scalar = .{ .style = .literal, .text = "a  \nb" };
    const written = try fixture.scalar_written(.block_item, &literal, options_default);

    try testing.expectEqualStrings("- |-\n  a  \n  b\n", written);
}

test "a key is simple up to 1024 bound columns and explicit beyond" {
    const fixture = try testing.allocator.create(Fixture);
    defer testing.allocator.destroy(fixture);

    const simple: [1019]u8 = @splat('k');
    const explicit: [1020]u8 = @splat('k');

    const cases = [_]Case{
        .{
            .expected = &simple ++ ": v\n",
            .place = .block_key,
            .scalar = .{ .text = &simple },
        },
        .{
            .expected = "? " ++ &explicit ++ "\n: v\n",
            .place = .block_key,
            .scalar = .{ .text = &explicit },
        },
        .{
            .expected = "{? " ++ &explicit ++ " : v}\n",
            .place = .flow_key,
            .scalar = .{ .text = &explicit },
        },
        .{
            .expected = "'" ++ simple[0..1017] ++ "': v\n",
            .place = .block_key,
            .scalar = .{ .style = .single_quoted, .text = simple[0..1017] },
        },
        .{
            .expected = "? '" ++ simple[0..1018] ++ "'\n: v\n",
            .place = .block_key,
            .scalar = .{ .style = .single_quoted, .text = simple[0..1018] },
        },
    };

    try fixture.cases_check(&cases, options_default);
    try testing.expectEqual(@as(usize, 1019), simple.len);
}

test "an alias key stays simple until its name pushes the key past 1024 columns" {
    const fixture = try testing.allocator.create(Fixture);
    defer testing.allocator.destroy(fixture);

    const name: [1023]u8 = @splat('a');

    const simple = [_]Event{
        .{ .mapping_start = .{ .style = .block } },
        .{ .alias = .{ .anchor = name[0..1022] } },
        .{ .scalar = .{ .text = "v" } },
        .mapping_end,
    };

    const explicit = [_]Event{
        .{ .mapping_start = .{ .style = .block } },
        .{ .alias = .{ .anchor = &name } },
        .{ .scalar = .{ .text = "v" } },
        .mapping_end,
    };

    const short = try fixture.document_written(&simple, options_default);

    try testing.expectEqualStrings("*" ++ name[0..1022] ++ " : v\n", short);

    const long = try fixture.document_written(&explicit, options_default);

    try testing.expectEqualStrings("? *" ++ &name ++ "\n: v\n", long);
}

const keys_collections = [_]Event{
    .{ .mapping_start = .{ .style = .block } },
    .{ .sequence_start = .{ .style = .flow } },
    .{ .scalar = .{ .text = "a" } },
    .{ .scalar = .{ .text = "b" } },
    .sequence_end,
    .{ .scalar = .{ .text = "v" } },
    .{ .sequence_start = .{ .style = .block } },
    .{ .scalar = .{ .text = "a" } },
    .{ .scalar = .{ .text = "b" } },
    .sequence_end,
    .{ .mapping_start = .{ .style = .block } },
    .{ .scalar = .{ .text = "c" } },
    .{ .scalar = .{ .text = "d" } },
    .mapping_end,
    .mapping_end,
};

const keys_aliases = [_]Event{
    .{ .sequence_start = .{ .style = .block } },
    .{ .scalar = .{ .anchor = "a:b", .text = "x" } },
    .{ .mapping_start = .{ .style = .block } },
    .{ .alias = .{ .anchor = "a:b" } },
    .{ .alias = .{ .anchor = "a:b" } },
    .mapping_end,
    .{ .mapping_start = .{ .style = .flow } },
    .{ .alias = .{ .anchor = "a:b" } },
    .{ .scalar = .{ .text = "v" } },
    .mapping_end,
    .sequence_end,
};

test "keys holding collections, aliases, empty text, and bare properties" {
    const fixture = try testing.allocator.create(Fixture);
    defer testing.allocator.destroy(fixture);

    const collections = try fixture.document_written(&keys_collections, options_default);

    try testing.expectEqualStrings("? [a, b]\n: v\n? - a\n  - b\n: c: d\n", collections);

    const aliases = try fixture.document_written(&keys_aliases, options_default);

    try testing.expectEqualStrings("- &a:b x\n- *a:b : *a:b\n- {*a:b : v}\n", aliases);

    const cases = [_]Case{
        .{ .expected = "?\n: v\n", .place = .block_key, .scalar = .{ .text = "" } },
        .{ .expected = "{: v}\n", .place = .flow_key, .scalar = .{ .text = "" } },
        .{ .expected = "{k: }\n", .place = .flow_value, .scalar = .{ .text = "" } },
        .{
            .expected = "? &a\n: v\n",
            .place = .block_key,
            .scalar = .{ .anchor = "a", .text = "" },
        },
        .{
            .expected = "? !t\n: v\n",
            .place = .block_key,
            .scalar = .{ .tag = "!t", .text = "" },
        },
        .{
            .expected = "{? &a : v}\n",
            .place = .flow_key,
            .scalar = .{ .anchor = "a", .text = "" },
        },
        .{
            .expected = "? |\n  a\n: v\n",
            .place = .block_key,
            .scalar = .{ .style = .literal, .text = "a\n" },
        },
        .{
            .expected = "\"a\\nb\": v\n",
            .place = .block_key,
            .scalar = .{ .style = .double_quoted, .text = "a\nb" },
        },
    };

    try fixture.cases_check(&cases, options_default);
}

test "tags take the shortest form that reads back, percent-encoding what they must" {
    const fixture = try testing.allocator.create(Fixture);
    defer testing.allocator.destroy(fixture);

    const tags = [_][2][]const u8{
        .{ "!", "! x\n" },
        .{ "!local", "!local x\n" },
        .{ "!e!x", "!e%21x x\n" },
        .{ "!a%b", "!a%25b x\n" },
        .{ "tag:yaml.org,2002:str", "!!str x\n" },
        .{ "tag:yaml.org,2002:a,b", "!!a%2Cb x\n" },
        .{ "tag:yaml.org,2002:[\u{e9}]", "!!%5B%C3%A9%5D x\n" },
        .{ "tag:yaml.org,2002:", "!<tag:yaml.org,2002:> x\n" },
        .{ "tag:example.com,2000:v", "!<tag:example.com,2000:v> x\n" },
        .{ "x y>", "!<x%20y%3E> x\n" },
    };

    for (tags) |pair| {
        const scalar: Event.Scalar = .{ .tag = pair[0], .text = "x" };
        const written = try fixture.scalar_written(.root, &scalar, options_default);

        try testing.expectEqualStrings(pair[1], written);
    }

    const cases = [_]Case{
        .{
            .expected = "[!t ]\n",
            .place = .flow_item,
            .scalar = .{ .tag = "!t", .text = "" },
        },
        .{
            .expected = "[&\u{e9} ]\n",
            .place = .flow_item,
            .scalar = .{ .anchor = "\u{e9}", .text = "" },
        },
    };

    try fixture.cases_check(&cases, options_default);
}

const markers_implicit = [_]Event{
    .stream_start,
    .{ .document_start = .{ .explicit = false } },
    .{ .scalar = .{ .text = "a" } },
    .{ .document_end = .{ .explicit = false } },
    .{ .document_start = .{ .explicit = false } },
    .{ .scalar = .{ .text = "b" } },
    .{ .document_end = .{ .explicit = true } },
    .{ .document_start = .{ .explicit = false } },
    .{ .scalar = .{ .text = "c" } },
    .{ .document_end = .{ .explicit = false } },
    .stream_end,
};

const markers_version = [_]Event{
    .stream_start,
    .{ .document_start = .{ .explicit = false } },
    .{ .scalar = .{ .text = "a" } },
    .{ .document_end = .{ .explicit = false } },
    .{ .document_start = .{ .explicit = false } },
    .{ .sequence_start = .{ .style = .block } },
    .{ .scalar = .{ .text = "b" } },
    .sequence_end,
    .{ .document_end = .{ .explicit = false } },
    .stream_end,
};

test "document markers appear exactly where the stream needs them" {
    const fixture = try testing.allocator.create(Fixture);
    defer testing.allocator.destroy(fixture);

    const nothing = try fixture.stream_written(&.{ .stream_start, .stream_end }, options_default);

    try testing.expectEqualStrings("", nothing);

    const empty: Event.Scalar = .{ .text = "" };
    const forced = try fixture.scalar_written(.root, &empty, options_default);

    try testing.expectEqualStrings("---\n", forced);

    const implicit = try fixture.stream_written(&markers_implicit, options_default);

    try testing.expectEqualStrings("a\n--- b\n...\nc\n", implicit);

    var options = options_default;

    options.version_directive = true;

    const version = try fixture.stream_written(&markers_version, options);

    try testing.expectEqualStrings("%YAML 1.2\n--- a\n...\n%YAML 1.2\n---\n- b\n", version);
}

const nested_events = [_]Event{
    .{ .mapping_start = .{ .style = .flow } },
    .{ .scalar = .{ .text = "name" } },
    .{ .scalar = .{ .text = "warbler" } },
    .{ .scalar = .{ .text = "ports" } },
    .{ .sequence_start = .{ .style = .flow } },
    .{ .scalar = .{ .text = "8080" } },
    .{ .scalar = .{ .text = "8443" } },
    .sequence_end,
    .{ .scalar = .{ .text = "nested" } },
    .{ .mapping_start = .{ .style = .block } },
    .{ .scalar = .{ .text = "a" } },
    .{ .sequence_start = .{ .style = .block } },
    .{ .scalar = .{ .text = "b" } },
    .{ .mapping_start = .{ .style = .block } },
    .{ .scalar = .{ .text = "c" } },
    .{ .scalar = .{ .text = "d" } },
    .mapping_end,
    .sequence_end,
    .mapping_end,
    .mapping_end,
};

test "the block, flow, and indentless layouts override the requested styles" {
    const fixture = try testing.allocator.create(Fixture);
    defer testing.allocator.destroy(fixture);

    var options = options_default;

    options.layout = .block;

    const block =
        \\name: warbler
        \\ports:
        \\  - 8080
        \\  - 8443
        \\nested:
        \\  a:
        \\    - b
        \\    - c: d
        \\
    ;

    try testing.expectEqualStrings(block, try fixture.document_written(&nested_events, options));

    options.sequence_indentless = true;

    const indentless =
        \\name: warbler
        \\ports:
        \\- 8080
        \\- 8443
        \\nested:
        \\  a:
        \\  - b
        \\  - c: d
        \\
    ;

    const written = try fixture.document_written(&nested_events, options);

    try testing.expectEqualStrings(indentless, written);

    const flow = "{name: warbler, ports: [8080, 8443], nested: {a: [b, {c: d}]}}\n";

    options.layout = .flow;

    try testing.expectEqualStrings(flow, try fixture.document_written(&nested_events, options));

    options.layout = .preserve;

    try testing.expectEqualStrings(flow, try fixture.document_written(&nested_events, options));
}

const steps_events = [_]Event{
    .{ .mapping_start = .{ .style = .block } },
    .{ .scalar = .{ .text = "a" } },
    .{ .mapping_start = .{ .style = .block } },
    .{ .scalar = .{ .text = "b" } },
    .{ .sequence_start = .{ .style = .block } },
    .{ .scalar = .{ .text = "x" } },
    .{ .mapping_start = .{ .style = .block } },
    .{ .scalar = .{ .text = "c" } },
    .{ .scalar = .{ .text = "d" } },
    .mapping_end,
    .sequence_end,
    .{ .scalar = .{ .text = "e" } },
    .{ .scalar = .{ .style = .literal, .text = "f\n" } },
    .mapping_end,
    .mapping_end,
};

test "every indentation step from one to nine" {
    const fixture = try testing.allocator.create(Fixture);
    defer testing.allocator.destroy(fixture);

    inline for (1..10) |step| {
        const pad: [step]u8 = @splat(' ');
        const deep: [2 * step]u8 = @splat(' ');
        const triple: [3 * step]u8 = @splat(' ');
        const gap: [step - 1]u8 = @splat(' ');
        const compact = if (step == 1) "-\n" ++ triple ++ "c: d\n" else "-" ++ gap ++ "c: d\n";

        const expected = "a:\n" ++ pad ++ "b:\n" ++ deep ++ "- x\n" ++ deep ++ compact ++
            pad ++ "e: |\n" ++ deep ++ "f\n";

        var options = options_default;

        options.indent = step;

        const written = try fixture.document_written(&steps_events, options);

        try testing.expectEqualStrings(expected, written);
    }
}

test "a width folds plain, quoted, and folded text at spaces" {
    const fixture = try testing.allocator.create(Fixture);
    defer testing.allocator.destroy(fixture);

    const text = "the quick brown fox jumps over the lazy dog";
    const lines = "the quick brown fox\n  jumps over the lazy\n  dog";

    var options = options_default;

    options.width = 80;

    const wide = try fixture.scalar_written(.block_value, &.{ .text = text }, options);

    try testing.expectEqualStrings("k: " ++ text ++ "\n", wide);

    options.width = 20;

    const styles = [_]Styled{
        .{ .expected = "k: " ++ lines ++ "\n", .style = .plain },
        .{ .expected = "k: '" ++ lines ++ "'\n", .style = .single_quoted },
        .{ .expected = "k: \"" ++ lines ++ "\"\n", .style = .double_quoted },
        .{ .expected = "k: >-\n  " ++ lines ++ "\n", .style = .folded },
    };

    for (styles) |styled| {
        const scalar: Event.Scalar = .{ .style = styled.style, .text = text };
        const written = try fixture.scalar_written(.block_value, &scalar, options);

        try testing.expectEqualStrings(styled.expected, written);
    }

    options.width = 1;

    const cases = [_]Case{
        .{
            .expected = "k: the\n  quick\n  brown\n  fox\n  jumps\n  over\n  the\n  lazy\n  dog\n",
            .place = .block_value,
            .scalar = .{ .text = text },
        },
        .{ .expected = "a b c: v\n", .place = .block_key, .scalar = .{ .text = "a b c" } },
        .{
            .expected = "\"a\n  \\ b\t c\"\n",
            .place = .root,
            .scalar = .{ .style = .double_quoted, .text = "a  b\t c" },
        },
        .{
            .expected = "\"a\n  \\\tb\"\n",
            .place = .root,
            .scalar = .{ .style = .double_quoted, .text = "a \tb" },
        },
        .{ .expected = "a \tb\n  c\n", .place = .root, .scalar = .{ .text = "a \tb c" } },
        .{ .expected = "[a\n  b]\n", .place = .flow_item, .scalar = .{ .text = "a b" } },
        .{
            .expected = "- >2-\n   a b\n  c\n  d\n",
            .place = .block_item,
            .scalar = .{ .style = .folded, .text = " a b\nc d" },
        },
    };

    try fixture.cases_check(&cases, options);
}

test "invalid text leaves the output and the writer exactly as they were" {
    var buffer: [64]u8 = undefined;
    var sink: std.Io.Writer = .fixed(&buffer);
    var writer: Writer = undefined;

    writer.init(&sink, options_default);

    try writer.document_begin(&.{ .explicit = false });
    try writer.sequence_begin(&.{ .style = .block });
    try writer.scalar(&.{ .text = "a" });

    const invalids = [_][]const u8{
        "\xff",
        "a\xc3",
        "\xc0\x80",
        "\xed\xa0\x80",
        "\xf4\x90\x80\x80",
    };

    for (invalids) |invalid| {
        const before = std.mem.toBytes(writer);
        const written = sink.buffered().len;

        try testing.expectError(error.TextInvalid, writer.scalar(&.{ .text = invalid }));
        try testing.expectEqual(written, sink.buffered().len);
        try testing.expectEqualSlices(u8, &before, std.mem.asBytes(&writer));
    }

    try writer.scalar(&.{ .text = "b" });
    try writer.sequence_end();
    try writer.document_end(&.{ .explicit = false });

    writer.finish();

    try testing.expectEqualStrings("- a\n- b\n", sink.buffered());

    var trusted = options_default;

    trusted.utf8 = .trusted;
    sink = .fixed(&buffer);

    writer.init(&sink, trusted);

    try writer.document_begin(&.{ .explicit = false });
    try writer.scalar(&.{ .style = .double_quoted, .text = "a\xffb" });
    try writer.document_end(&.{ .explicit = false });

    try testing.expectEqualStrings("\"a\xffb\"\n", sink.buffered());
}

test "the depth limit refuses the collection past 520 and leaves the writer usable" {
    const buffer = try testing.allocator.alloc(u8, 4096);
    defer testing.allocator.free(buffer);

    var sink: std.Io.Writer = .fixed(buffer);
    var writer: Writer = undefined;

    writer.init(&sink, options_default);

    try writer.document_begin(&.{ .explicit = false });

    for (0..writer_module.depth_max) |_| try writer.sequence_begin(&.{ .style = .flow });

    const before = std.mem.toBytes(writer);
    const written = sink.buffered().len;

    try testing.expectError(error.DepthExceeded, writer.sequence_begin(&.{ .style = .flow }));
    try testing.expectError(error.DepthExceeded, writer.mapping_begin(&.{ .style = .block }));
    try testing.expectEqual(written, sink.buffered().len);
    try testing.expectEqualSlices(u8, &before, std.mem.asBytes(&writer));

    try writer.scalar(&.{ .text = "x" });

    for (0..writer_module.depth_max) |_| try writer.sequence_end();

    try writer.document_end(&.{ .explicit = false });

    writer.finish();

    const opens: [writer_module.depth_max]u8 = @splat('[');
    const closes: [writer_module.depth_max]u8 = @splat(']');

    try testing.expectEqualStrings(&opens ++ "x" ++ &closes ++ "\n", sink.buffered());
}

test "a full sink fails every call with WriteFailed" {
    var buffer: [16]u8 = undefined;
    var sink: std.Io.Writer = .fixed(&buffer);
    var writer: Writer = undefined;

    writer.init(&sink, options_default);

    try writer.document_begin(&.{ .explicit = true });
    try writer.mapping_begin(&.{ .style = .block });
    try writer.scalar(&.{ .text = "key" });
    try testing.expectError(error.WriteFailed, writer.scalar(&.{ .text = "a long value" }));

    const escaped: Event.Scalar = .{ .style = .double_quoted, .text = "\x01\x02\x03\x04\x05" };

    sink = .fixed(&buffer);

    writer.init(&sink, options_default);

    try writer.document_begin(&.{ .explicit = false });
    try testing.expectError(error.WriteFailed, writer.scalar(&escaped));

    const literal: Event.Scalar = .{ .style = .literal, .text = "abc\n" };

    sink = .fixed(&buffer);

    writer.init(&sink, options_default);

    try writer.document_begin(&.{ .explicit = false });
    try writer.sequence_begin(&.{ .style = .block });

    for (0..3) |_| try writer.scalar(&.{ .text = "ab" });

    try testing.expectError(error.WriteFailed, writer.scalar(&literal));
}
