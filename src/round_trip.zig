const std = @import("std");

const document_module = @import("document.zig");
const parser_module = @import("parser.zig");
const schema = @import("schema.zig");
const storage_module = @import("storage.zig");
const writer_module = @import("writer.zig");

const assert = std.debug.assert;

const CollectionStyle = parser_module.CollectionStyle;
const Document = document_module.Document;
const Event = parser_module.Event;
const Parser = parser_module.Parser;
const Record = storage_module.Record;
const ScalarStyle = parser_module.ScalarStyle;
const Writer = writer_module.Writer;

const depth_max: u32 = writer_module.depth_max;

pub const Error = parser_module.Parser.Error;

pub const Source = union(enum) {
    events: []const Event,
    parser: *Parser,
};

pub const Sources = struct {
    original: Source,
    written: Source,
};

pub const Documents = struct {
    original: *const Document,
    written: *const Document,
};

pub const Options = struct {
    layout: Writer.Layout,
    style_exact: bool,
    version_directive: bool,
};

pub const Context = enum {
    block,
    flow,
    flow_sequence_item,
    root,
};

pub const Fallback = enum {
    block_in_flow,
    content_white,
    document_marker,
    flow_sign,
    indicator_last,
    special,
};

pub const Verdict = union(enum) {
    differed: []const u8,
    matched,
};

const ScalarClass = enum {
    boolean,
    float,
    integer,
    null_value,
    string,
    tagged,
};

const Level = struct {
    empty: bool,
    end: u32,
    flow: bool,
    mapping: bool,
    style_pending: bool,
};

const Walk = struct {
    depth: u32,
    document_index: u32,
    end_previous_explicit: bool,
    levels: [depth_max]Level,
    options: Options,
    start_pending: bool,

    fn init(walk: *Walk, options: Options) void {
        assert(depth_max > 0);
        assert(@backingInt(options.layout) <= 2);

        walk.depth = 0;
        walk.document_index = 0;
        walk.end_previous_explicit = false;
        walk.options = options;
        walk.start_pending = false;
    }

    fn context_of(walk: *const Walk) Context {
        assert(walk.depth <= depth_max);
        assert(walk.document_index <= std.math.maxInt(u32));

        if (walk.depth == 0) return .root;

        const level = walk.levels[walk.depth - 1];
        if (!level.flow) return .block;
        if (level.mapping) return .flow;
        return .flow_sequence_item;
    }

    fn style_expected_of(walk: *const Walk, original: CollectionStyle) CollectionStyle {
        assert(walk.depth <= depth_max);
        assert(@backingInt(original) <= 1);

        if (walk.depth > 0) {
            if (walk.levels[walk.depth - 1].flow) return .flow;
        }

        return switch (walk.options.layout) {
            .block => .block,
            .flow => .flow,
            .preserve => original,
        };
    }

    fn child_enter(walk: *Walk, root_empty: bool) ?[]const u8 {
        assert(walk.depth <= depth_max);

        if (root_empty) assert(walk.depth == 0);

        if (walk.depth == 0) {
            const pending = walk.start_pending;

            walk.start_pending = false;

            if (!pending) return null;
            if (root_empty) return null;
            return "a document start marker was added to a document that needs none";
        }

        const level = &walk.levels[walk.depth - 1];
        const pending = "a block collection with children was written in flow style";
        if (level.style_pending) return pending;

        level.empty = false;

        return null;
    }

    fn level_push(walk: *Walk, level: Level) ?[]const u8 {
        assert(walk.depth <= depth_max);
        assert(level.empty);

        if (level.style_pending) assert(level.flow);

        if (walk.depth == depth_max) return "the stream nests deeper than the writer allows";

        walk.levels[walk.depth] = level;
        walk.depth += 1;

        assert(walk.depth <= depth_max);

        return null;
    }

    fn document_start_compare(walk: *Walk, pair: PairType(Event.DocumentStart)) ?[]const u8 {
        assert(walk.depth == 0);
        assert(pair.original.mark.column <= pair.original.mark.index);

        if (walk.options.version_directive) return null;
        if (pair.original.explicit == pair.written.explicit) return null;
        if (!pair.written.explicit) return "a document start marker was dropped";

        const later = walk.document_index > 0;

        if (later) {
            if (!walk.end_previous_explicit) return null;
        }

        walk.start_pending = true;

        return null;
    }

    fn document_end_compare(walk: *Walk, pair: PairType(Event.DocumentEnd)) ?[]const u8 {
        assert(walk.depth == 0);
        assert(pair.original.mark.column <= pair.original.mark.index);

        const explicit = pair.original.explicit;

        walk.document_index += 1;
        walk.end_previous_explicit = explicit;

        if (walk.options.version_directive) return null;
        if (explicit != pair.written.explicit) return "the document end markers differ";
        return null;
    }

    fn alias_compare(walk: *Walk, pair: PairType(Event.Alias)) ?[]const u8 {
        assert(pair.original.anchor.len > 0);
        assert(walk.depth > 0);

        if (walk.child_enter(false)) |difference| return difference;
        if (!std.mem.eql(u8, pair.original.anchor, pair.written.anchor)) return "aliases differ";
        return null;
    }

    fn collection_compare(
        walk: *Walk,
        mapping: bool,
        pair: PairType(Event.CollectionStart),
    ) ?[]const u8 {
        assert(walk.depth <= depth_max);
        assert(@backingInt(pair.original.style) <= 1);

        const expected = walk.style_expected_of(pair.original.style);

        if (walk.child_enter(false)) |difference| return difference;
        if (!std.mem.eql(u8, pair.original.anchor, pair.written.anchor)) return "anchors differ";
        if (!std.mem.eql(u8, pair.original.tag, pair.written.tag)) return "tags differ";

        const flow_written = pair.written.style == .flow;
        const style_pending = expected == .block and flow_written;

        if (expected == .flow) {
            if (!flow_written) return "a collection that must be flow was written in block style";
        }

        return walk.level_push(.{
            .empty = true,
            .end = 0,
            .flow = flow_written,
            .mapping = mapping,
            .style_pending = style_pending,
        });
    }

    fn collection_end(walk: *Walk, mapping: bool) ?[]const u8 {
        assert(walk.depth <= depth_max);
        assert(walk.document_index <= std.math.maxInt(u32));

        if (walk.depth == 0) return "a collection ended that never started";
        if (walk.levels[walk.depth - 1].mapping != mapping) return "collection kinds differ";

        walk.depth -= 1;

        assert(walk.depth < depth_max);

        return null;
    }

    fn scalar_compare(walk: *Walk, pair: PairType(Event.Scalar)) ?[]const u8 {
        assert(pair.original.text.len <= std.math.maxInt(u32));
        assert(walk.depth <= depth_max);

        const original = pair.original;
        const written = pair.written;
        const context = walk.context_of();
        const empty_plain = original.style == .plain and empty_bare_is(original);
        const root_empty = empty_plain and context == .root;
        if (walk.child_enter(root_empty)) |difference| return difference;
        if (!std.mem.eql(u8, original.anchor, written.anchor)) return "anchors differ";
        if (!std.mem.eql(u8, original.tag, written.tag)) return "tags differ";

        const substituted = empty_plain and context == .flow_sequence_item;

        if (substituted) {
            if (written.style != .plain) return "an empty flow item was not written as null";
            if (!std.mem.eql(u8, written.text, "null")) return "an empty flow item changed";
            return null;
        }

        if (!std.mem.eql(u8, original.text, written.text)) return "scalar texts differ";
        if (class_of(original) != class_of(written)) return "scalar resolutions differ";
        if (!walk.options.style_exact) return null;
        if (original.style == written.style) return null;

        const fallback = fallback_style_of(original.text, original.style, context);
        if (fallback == written.style) return null;
        return "scalar styles differ";
    }
};

fn PairType(comptime T: type) type {
    return struct {
        original: *const T,
        written: *const T,
    };
}

const Cursor = struct {
    index: u32,
    source: Source,

    fn next(cursor: *Cursor) Error!*const Event {
        assert(cursor.index < std.math.maxInt(u32));
        assert(source_bound_of(cursor.source) > 0);

        switch (cursor.source) {
            .events => |events| {
                assert(cursor.index < events.len);

                const event = &events[cursor.index];

                cursor.index += 1;

                return event;
            },
            .parser => |parser| {
                cursor.index += 1;

                return parser.next();
            },
        }
    }
};

pub fn streams_equivalent(sources: Sources, options: Options) Error!Verdict {
    assert(source_bound_of(sources.original) > 0);
    assert(source_bound_of(sources.written) > 0);

    if (options.style_exact) assert(options.layout != .flow);

    var walk: Walk = undefined;
    var original: Cursor = .{ .index = 0, .source = sources.original };
    var written: Cursor = .{ .index = 0, .source = sources.written };

    walk.init(options);

    const bound = @max(source_bound_of(sources.original), source_bound_of(sources.written));

    for (0..bound) |_| {
        const left = try original.next();
        const right = try written.next();

        if (event_compare(&walk, .{ .original = left, .written = right })) |difference| {
            return .{ .differed = difference };
        }

        if (left.* == .stream_end) return .matched;
    }

    return .{ .differed = "the streams did not end within their bound" };
}

fn event_compare(walk: *Walk, pair: PairType(Event)) ?[]const u8 {
    assert(walk.depth <= depth_max);

    if (pair.original.* == .stream_start) assert(walk.document_index == 0);

    const original = pair.original;
    const written = pair.written;
    const kind: std.meta.Tag(Event) = original.*;
    if (kind != @as(std.meta.Tag(Event), written.*)) return "event kinds differ";

    return switch (original.*) {
        .alias => |*alias| walk.alias_compare(.{ .original = alias, .written = &written.alias }),
        .document_end => |*end| walk.document_end_compare(.{
            .original = end,
            .written = &written.document_end,
        }),
        .document_start => |*start| walk.document_start_compare(.{
            .original = start,
            .written = &written.document_start,
        }),
        .mapping_end => walk.collection_end(true),
        .mapping_start => |*start| walk.collection_compare(true, .{
            .original = start,
            .written = &written.mapping_start,
        }),
        .scalar => |*scalar| walk.scalar_compare(.{
            .original = scalar,
            .written = &written.scalar,
        }),
        .sequence_end => walk.collection_end(false),
        .sequence_start => |*start| walk.collection_compare(false, .{
            .original = start,
            .written = &written.sequence_start,
        }),
        .stream_end, .stream_start => null,
    };
}

fn source_bound_of(source: Source) u64 {
    assert(@backingInt(std.meta.activeTag(source)) <= 1);
    assert(depth_max > 0);

    return switch (source) {
        .events => |events| events.len,
        .parser => |parser| 16 * @as(u64, parser.scanner.source.len) + 16,
    };
}

pub fn documents_equivalent(documents: Documents, options: Options) ?[]const u8 {
    assert(documents.original.composer.frame_count == 0);
    assert(documents.written.composer.frame_count == 0);

    if (options.style_exact) assert(options.layout != .flow);

    const original = documents.original;
    const written = documents.written;
    if (original.document_count != written.document_count) return "document counts differ";
    if (original.node_count != written.node_count) return "node counts differ";

    var walk: Walk = undefined;

    walk.init(options);

    for (0..original.document_count) |document| {
        const root = original.storage.roots[document];
        if (written.storage.roots[document] != root) return "documents start at different records";
        if (markers_compare(&walk, documents, root)) |difference| return difference;
    }

    for (0..original.node_count) |position| {
        const index: u32 = @intCast(position);

        levels_close(&walk, index);

        if (record_compare(&walk, documents, index)) |difference| return difference;
    }

    return null;
}

fn markers_compare(walk: *Walk, documents: Documents, root: u32) ?[]const u8 {
    assert(root < documents.original.node_count);
    assert(walk.depth == 0);

    const original = &documents.original.storage.nodes[root];
    const markers = original.markers;
    const written = documents.written.storage.nodes[root].markers;
    const later = walk.document_index > 0;
    const after_implicit = later and !walk.end_previous_explicit;

    walk.document_index += 1;
    walk.end_previous_explicit = markers.end_explicit;

    if (walk.options.version_directive) return null;
    if (markers.end_explicit != written.end_explicit) return "document end markers differ";
    if (markers.start_explicit == written.start_explicit) return null;
    if (!written.start_explicit) return "a document start marker was dropped";
    if (after_implicit) return null;
    if (record_empty_plain_is(original)) return null;
    return "a document start marker was added to a document that needs none";
}

fn levels_close(walk: *Walk, index: u32) void {
    assert(walk.depth <= depth_max);
    assert(index < std.math.maxInt(u32));

    for (0..walk.depth) |_| {
        if (walk.levels[walk.depth - 1].end != index) return;

        walk.depth -= 1;
    }

    assert(walk.depth == 0);
}

fn record_compare(walk: *Walk, documents: Documents, index: u32) ?[]const u8 {
    assert(index < documents.original.node_count);
    assert(walk.depth <= depth_max);

    const original = &documents.original.storage.nodes[index];
    const written = &documents.written.storage.nodes[index];
    if (original.kind != written.kind) return "record kinds differ";
    if (original.span != written.span) return "record spans differ";

    switch (original.kind) {
        .alias => {
            if (original.link.target != written.link.target) return "alias targets differ";
            return null;
        },
        .mapping, .sequence => return record_collection_compare(walk, documents, index),
        .scalar => {
            const pair: PairType(Record) = .{ .original = original, .written = written };
            return record_scalar_compare(walk, pair);
        },
    }
}

fn record_collection_compare(walk: *Walk, documents: Documents, index: u32) ?[]const u8 {
    assert(index < documents.original.node_count);
    assert(walk.depth <= depth_max);

    const original = &documents.original.storage.nodes[index];
    const written = &documents.written.storage.nodes[index];
    const original_style: CollectionStyle = @fromBackingInt(@intCast(original.style));
    const written_style: CollectionStyle = @fromBackingInt(@intCast(written.style));
    const expected = walk.style_expected_of(original_style);

    if (original.link.count != written.link.count) return "record counts differ";
    if (!std.mem.eql(u8, original.anchor, written.anchor)) return "anchors differ";
    if (!std.mem.eql(u8, original.tag, written.tag)) return "tags differ";

    if (expected != written_style) {
        const empty_block = expected == .block and original.link.count == 0;
        if (!empty_block) return "collection styles differ";
    }

    return walk.level_push(.{
        .empty = true,
        .end = index + original.span,
        .flow = written_style == .flow,
        .mapping = original.kind == .mapping,
        .style_pending = false,
    });
}

fn record_scalar_compare(walk: *Walk, pair: PairType(Record)) ?[]const u8 {
    assert(pair.original.kind == .scalar);
    assert(pair.written.kind == .scalar);

    const original = pair.original;
    const written = pair.written;
    const context = walk.context_of();
    const original_style: ScalarStyle = @fromBackingInt(@intCast(original.style));
    const written_style: ScalarStyle = @fromBackingInt(@intCast(written.style));

    if (!std.mem.eql(u8, original.anchor, written.anchor)) return "anchors differ";
    if (!std.mem.eql(u8, original.tag, written.tag)) return "tags differ";

    const substituted = record_empty_plain_is(original) and context == .flow_sequence_item;

    if (substituted) {
        if (written_style != .plain) return "an empty flow item was not written as null";
        if (!std.mem.eql(u8, written.text, "null")) return "an empty flow item changed";
        return null;
    }

    if (!std.mem.eql(u8, original.text, written.text)) return "scalar texts differ";

    const original_class = class_of(&.{
        .style = original_style,
        .tag = original.tag,
        .text = original.text,
    });

    const written_class = class_of(&.{
        .style = written_style,
        .tag = written.tag,
        .text = written.text,
    });

    if (original_class != written_class) return "scalar resolutions differ";
    if (!walk.options.style_exact) return null;
    if (original_style == written_style) return null;
    if (fallback_style_of(original.text, original_style, context) == written_style) return null;
    return "scalar styles differ";
}

pub fn fallback_style_of(text: []const u8, style: ScalarStyle, context: Context) ?ScalarStyle {
    assert(text.len <= std.math.maxInt(u32));
    assert(@backingInt(style) <= 4);

    const fallback = fallback_of(text, style, context) orelse return null;

    return switch (fallback) {
        .block_in_flow, .content_white, .special => .double_quoted,
        .document_marker, .flow_sign, .indicator_last => .single_quoted,
    };
}

pub fn fallback_of(text: []const u8, style: ScalarStyle, context: Context) ?Fallback {
    assert(std.unicode.utf8ValidateSlice(text));
    assert(@backingInt(style) <= 4);

    if (style == .double_quoted) return null;
    if (special_has(text)) return .special;

    const flow = context == .flow or context == .flow_sequence_item;

    switch (style) {
        .double_quoted => unreachable,
        .folded, .literal => {
            if (flow) return .block_in_flow;
            if (context != .root) return null;
            if (content_white_has(text)) return .content_white;
            return null;
        },
        .plain => {
            if (marker_starts(text)) return .document_marker;
            if (indicator_last_is(text)) return .indicator_last;
            if (!flow) return null;
            if (text.len == 0) return null;
            if (text[0] == '?') return .flow_sign;
            if (text[0] == ':') return .flow_sign;
            return null;
        },
        .single_quoted => return null,
    }
}

fn special_has(text: []const u8) bool {
    assert(std.unicode.utf8ValidateSlice(text));
    assert(text.len <= std.math.maxInt(u32));

    var iterator = std.unicode.Utf8View.initUnchecked(text).iterator();

    for (0..text.len) |_| {
        const codepoint = iterator.nextCodepoint() orelse return false;
        if (codepoint_special_is(codepoint)) return true;
    }

    return false;
}

fn codepoint_special_is(codepoint: u21) bool {
    assert(codepoint <= 0x10ffff);
    assert(codepoint < 0xd800 or codepoint > 0xdfff);

    if (codepoint == '\t') return false;
    if (codepoint == '\n') return false;
    if (codepoint < 0x20) return true;
    if (codepoint == 0x7f) return true;

    if (codepoint >= 0x80) {
        if (codepoint <= 0x9f) return true;
    }

    return switch (codepoint) {
        0x2028, 0x2029, 0xfeff, 0xfffe, 0xffff => true,
        else => false,
    };
}

fn content_white_has(text: []const u8) bool {
    assert(text.len <= std.math.maxInt(u32));
    assert(depth_max > 0);

    for (text) |byte| {
        if (byte == '\n') continue;
        return byte == ' ' or byte == '\t';
    }

    return false;
}

fn marker_starts(text: []const u8) bool {
    assert(text.len <= std.math.maxInt(u32));
    assert(depth_max > 0);

    const marked = std.mem.startsWith(u8, text, "---") or std.mem.startsWith(u8, text, "...");
    if (!marked) return false;
    if (text.len == 3) return true;
    return std.mem.findScalar(u8, " \t\n", text[3]) != null;
}

fn indicator_last_is(text: []const u8) bool {
    assert(text.len <= std.math.maxInt(u32));
    assert(depth_max > 0);

    if (text.len == 0) return false;
    if (text[text.len - 1] == ':') return true;
    if (text.len > 1) return false;
    return text[0] == '-' or text[0] == '?';
}

fn empty_bare_is(scalar: *const Event.Scalar) bool {
    assert(scalar.text.len <= std.math.maxInt(u32));
    assert(scalar.anchor.len <= std.math.maxInt(u32));

    if (scalar.text.len > 0) return false;
    if (scalar.anchor.len > 0) return false;
    return scalar.tag.len == 0;
}

fn record_empty_plain_is(record: *const Record) bool {
    assert(record.text.len <= std.math.maxInt(u32));
    assert(record.anchor.len <= std.math.maxInt(u32));

    if (record.kind != .scalar) return false;
    if (record.style != @backingInt(ScalarStyle.plain)) return false;
    if (record.text.len > 0) return false;
    if (record.anchor.len > 0) return false;
    return record.tag.len == 0;
}

fn class_of(scalar: *const Event.Scalar) ScalarClass {
    assert(scalar.text.len <= std.math.maxInt(u32));
    assert(scalar.tag.len <= std.math.maxInt(u32));

    if (scalar.tag.len > 0) return .tagged;
    if (scalar.style != .plain) return .string;

    return switch (schema.resolution_of(scalar.text, .core)) {
        .boolean => .boolean,
        .float => .float,
        .integer => .integer,
        .null_value => .null_value,
        .string => .string,
    };
}

const testing = std.testing;

const test_capacity: document_module.Capacity = .{
    .anchor_count_max = 16,
    .comment_count_max = null,
    .node_count_max = 256,
    .text_bytes_max = 4096,
};

const TestDocument = document_module.DocumentType(test_capacity);

const TestEvents = struct {
    original: []const Event,
    written: []const Event,
};

const TestScalars = struct {
    original: Event.Scalar,
    written: Event.Scalar,
};

const TestDocuments = struct {
    original: TestDocument,
    written: TestDocument,
};

const options_class: Options = .{
    .layout = .preserve,
    .style_exact = false,
    .version_directive = false,
};

const options_exact: Options = .{
    .layout = .preserve,
    .style_exact = true,
    .version_directive = false,
};

const events_base = [_]Event{
    .stream_start,
    .{ .document_start = .{ .explicit = false } },
    .{ .mapping_start = .{ .style = .block } },
    .{ .scalar = .{ .text = "name" } },
    .{ .scalar = .{ .anchor = "a", .text = "warbler" } },
    .{ .scalar = .{ .text = "items" } },
    .{ .sequence_start = .{ .style = .flow, .tag = "!list" } },
    .{ .scalar = .{ .text = "1" } },
    .{ .alias = .{ .anchor = "a" } },
    .sequence_end,
    .mapping_end,
    .{ .document_end = .{ .explicit = false } },
    .stream_end,
};

fn test_verdict(events: TestEvents, options: Options) !Verdict {
    assert(events.original.len >= 2);
    assert(events.written.len >= 2);

    if (options.style_exact) assert(options.layout != .flow);

    const sources: Sources = .{
        .original = .{ .events = events.original },
        .written = .{ .events = events.written },
    };

    return streams_equivalent(sources, options);
}

fn test_expect(verdict: Verdict, expected: ?[]const u8) !void {
    assert(@backingInt(std.meta.activeTag(verdict)) <= 1);

    if (expected) |text| assert(text.len > 0);

    switch (verdict) {
        .differed => |difference| {
            const wanted = expected orelse {
                std.debug.print("unexpected difference: {s}\n", .{difference});

                return error.TestUnexpectedDifference;
            };

            try testing.expectEqualStrings(wanted, difference);
        },
        .matched => try testing.expectEqual(@as(?[]const u8, null), expected),
    }
}

fn test_scalar_root(scalars: TestScalars) !Verdict {
    assert(scalars.original.text.len <= 64);
    assert(scalars.written.text.len <= 64);

    const original = [_]Event{
        .stream_start,
        .{ .document_start = .{ .explicit = false } },
        .{ .scalar = scalars.original },
        .{ .document_end = .{ .explicit = false } },
        .stream_end,
    };

    var written = original;

    written[2] = .{ .scalar = scalars.written };

    return test_verdict(.{ .original = &original, .written = &written }, options_exact);
}

fn test_scalar_flow(scalars: TestScalars) !Verdict {
    assert(scalars.original.text.len <= 64);
    assert(scalars.written.text.len <= 64);

    const original = [_]Event{
        .stream_start,
        .{ .document_start = .{ .explicit = false } },
        .{ .sequence_start = .{ .style = .flow } },
        .{ .scalar = scalars.original },
        .sequence_end,
        .{ .document_end = .{ .explicit = false } },
        .stream_end,
    };

    var written = original;

    written[3] = .{ .scalar = scalars.written };

    return test_verdict(.{ .original = &original, .written = &written }, options_exact);
}

fn test_documents(documents: *const TestDocuments, options: Options) ?[]const u8 {
    assert(documents.original.document.node_count > 0);
    assert(documents.written.document.node_count > 0);

    if (options.style_exact) assert(options.layout != .flow);

    const pair: Documents = .{
        .original = &documents.original.document,
        .written = &documents.written.document,
    };

    return documents_equivalent(pair, options);
}

test "the stream comparator catches a style flip, a text change, an anchor, a tag, and a style" {
    var written = events_base;
    const events: TestEvents = .{ .original = &events_base, .written = &written };

    try test_expect(try test_verdict(events, options_exact), null);

    written[4].scalar.style = .single_quoted;

    try test_expect(try test_verdict(events, options_exact), "scalar styles differ");
    try test_expect(try test_verdict(events, options_class), null);

    written = events_base;
    written[4].scalar.text = "warblers";

    try test_expect(try test_verdict(events, options_class), "scalar texts differ");

    written = events_base;
    written[4].scalar.anchor = "";

    try test_expect(try test_verdict(events, options_class), "anchors differ");

    written = events_base;
    written[6].sequence_start.tag = "!other";

    try test_expect(try test_verdict(events, options_class), "tags differ");

    written = events_base;
    written[6].sequence_start.style = .block;

    const block = "a collection that must be flow was written in block style";

    try test_expect(try test_verdict(events, options_class), block);

    written = events_base;
    written[7].scalar.style = .single_quoted;

    try test_expect(try test_verdict(events, options_class), "scalar resolutions differ");

    written = events_base;
    written[8].alias.anchor = "b";

    try test_expect(try test_verdict(events, options_class), "aliases differ");
}

test "the stream comparator accepts every listed fallback" {
    const special = try test_scalar_root(.{
        .original = .{ .text = "a\x01b" },
        .written = .{ .style = .double_quoted, .text = "a\x01b" },
    });

    try test_expect(special, null);

    const white = try test_scalar_root(.{
        .original = .{ .style = .literal, .text = " x\n" },
        .written = .{ .style = .double_quoted, .text = " x\n" },
    });

    try test_expect(white, null);

    const marker = try test_scalar_root(.{
        .original = .{ .text = "--- x" },
        .written = .{ .style = .single_quoted, .text = "--- x" },
    });

    try test_expect(marker, null);

    const sign = try test_scalar_flow(.{
        .original = .{ .text = "?a" },
        .written = .{ .style = .single_quoted, .text = "?a" },
    });

    try test_expect(sign, null);

    const block = try test_scalar_flow(.{
        .original = .{ .style = .folded, .text = "a\n" },
        .written = .{ .style = .double_quoted, .text = "a\n" },
    });

    try test_expect(block, null);

    const empty = try test_scalar_flow(.{
        .original = .{ .text = "" },
        .written = .{ .text = "null" },
    });

    try test_expect(empty, null);
}

test "the stream comparator accepts a quoted key whose last character was an indicator" {
    const colon = try test_scalar_root(.{
        .original = .{ .text = "a::" },
        .written = .{ .style = .single_quoted, .text = "a::" },
    });

    try testing.expect(colon == .matched);

    const lone = try test_scalar_root(.{
        .original = .{ .text = "?" },
        .written = .{ .style = .single_quoted, .text = "?" },
    });

    try testing.expect(lone == .matched);
}

test "the stream comparator refuses a style change no rule explains" {
    const quoted = try test_scalar_root(.{
        .original = .{ .text = "x" },
        .written = .{ .style = .single_quoted, .text = "x" },
    });

    try test_expect(quoted, "scalar styles differ");

    const white_flow = try test_scalar_flow(.{
        .original = .{ .style = .literal, .text = " x\n" },
        .written = .{ .style = .single_quoted, .text = " x\n" },
    });

    try test_expect(white_flow, "scalar styles differ");
}

test "the stream comparator accepts only the document markers the writer must add" {
    const empty = [_]Event{
        .stream_start,
        .{ .document_start = .{ .explicit = false } },
        .{ .scalar = .{ .text = "" } },
        .{ .document_end = .{ .explicit = false } },
        .stream_end,
    };

    var empty_marked = empty;

    empty_marked[1].document_start.explicit = true;

    var full = empty;

    full[2].scalar.text = "x";

    var full_marked = full;

    full_marked[1].document_start.explicit = true;

    const added = "a document start marker was added to a document that needs none";
    const dropped = "a document start marker was dropped";
    const forced: TestEvents = .{ .original = &empty, .written = &empty_marked };
    const extra: TestEvents = .{ .original = &full, .written = &full_marked };
    const lost: TestEvents = .{ .original = &full_marked, .written = &full };

    try test_expect(try test_verdict(forced, options_class), null);
    try test_expect(try test_verdict(extra, options_class), added);
    try test_expect(try test_verdict(lost, options_class), dropped);
}

test "an empty block collection may come back in flow style and a full one may not" {
    const original = [_]Event{
        .stream_start,
        .{ .document_start = .{ .explicit = false } },
        .{ .sequence_start = .{ .style = .block } },
        .{ .mapping_start = .{ .style = .block } },
        .mapping_end,
        .sequence_end,
        .{ .document_end = .{ .explicit = false } },
        .stream_end,
    };

    var written = original;
    const events: TestEvents = .{ .original = &original, .written = &written };

    written[3].mapping_start.style = .flow;

    try test_expect(try test_verdict(events, options_exact), null);

    written = original;
    written[2].sequence_start.style = .flow;

    const pending = "a block collection with children was written in flow style";

    try test_expect(try test_verdict(events, options_exact), pending);
}

test "the document comparator catches a style flip, a text change, an anchor, a tag, and a style" {
    const documents = try testing.allocator.create(TestDocuments);
    defer testing.allocator.destroy(documents);

    const base = "name: &n warbler\nitems: !list [1, 2]\nmarker: --- x\n";

    const cases = [_]struct { source: []const u8, expected: ?[]const u8 }{
        .{ .source = base, .expected = null },
        .{
            .source = "name: &n 'warbler'\nitems: !list [1, 2]\nmarker: --- x\n",
            .expected = "scalar styles differ",
        },
        .{
            .source = "name: &n warblers\nitems: !list [1, 2]\nmarker: --- x\n",
            .expected = "scalar texts differ",
        },
        .{
            .source = "name: warbler\nitems: !list [1, 2]\nmarker: --- x\n",
            .expected = "anchors differ",
        },
        .{
            .source = "name: &n warbler\nitems: !other [1, 2]\nmarker: --- x\n",
            .expected = "tags differ",
        },
        .{
            .source = "name: &n warbler\nitems: !list\n  - 1\n  - 2\nmarker: --- x\n",
            .expected = "collection styles differ",
        },
        .{
            .source = "name: &n warbler\nitems: !list [1, 2]\nmarker: '--- x'\n",
            .expected = null,
        },
    };

    try documents.original.parse(base, .{ .schema = .core });

    for (cases) |case| {
        try documents.written.parse(case.source, .{ .schema = .core });

        const difference = test_documents(documents, options_exact);

        if (case.expected) |expected| {
            try testing.expectEqualStrings(expected, difference orelse "");
        } else {
            try testing.expectEqual(@as(?[]const u8, null), difference);
        }
    }
}

test "the document comparator accepts the fallbacks a parsed document can need" {
    const documents = try testing.allocator.create(TestDocuments);
    defer testing.allocator.destroy(documents);

    try documents.original.parse("[?a]\n", .{ .schema = .core });
    try documents.written.parse("['?a']\n", .{ .schema = .core });
    try testing.expectEqual(@as(?[]const u8, null), test_documents(documents, options_exact));

    try documents.original.parse("a:: v\n", .{ .schema = .core });
    try documents.written.parse("'a:': v\n", .{ .schema = .core });
    try testing.expectEqual(@as(?[]const u8, null), test_documents(documents, options_exact));

    try documents.written.parse("\"a:\": v\n", .{ .schema = .core });

    const doubled = test_documents(documents, options_exact);

    try testing.expectEqualStrings("scalar styles differ", doubled orelse "");
}

test "the document comparator reads the markers on each root record" {
    const documents = try testing.allocator.create(TestDocuments);
    defer testing.allocator.destroy(documents);

    try documents.original.parse("--- |1\n  x\n", .{ .schema = .core });
    try documents.written.parse("\"  x\\n\"\n", .{ .schema = .core });

    const dropped = test_documents(documents, options_exact);

    try testing.expectEqualStrings("a document start marker was dropped", dropped orelse "");

    try documents.written.parse("--- \"  x\\n\"\n", .{ .schema = .core });

    try testing.expectEqual(@as(?[]const u8, null), test_documents(documents, options_exact));

    try documents.original.parse("a\n---\nb\n...\n", .{ .schema = .core });
    try documents.written.parse("a\n---\nb\n", .{ .schema = .core });

    const ended = test_documents(documents, options_exact);

    try testing.expectEqualStrings("document end markers differ", ended orelse "");
}
