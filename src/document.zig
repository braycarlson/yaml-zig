const std = @import("std");

const comment_module = @import("comment.zig");
const composer = @import("composer.zig");
const json_writer = @import("json_writer.zig");
const parser_module = @import("parser.zig");
const scanner_module = @import("scanner.zig");
const schema_module = @import("schema.zig");
const storage_module = @import("storage.zig");
const writer_module = @import("writer.zig");

const assert = std.debug.assert;

const Comment = comment_module.Comment;
const CommentSlot = storage_module.CommentSlot;
const Comments = comment_module.Comments;
const Event = parser_module.Event;
const JSONOptions = json_writer.JSONOptions;
const Range = comment_module.Range;
const Record = storage_module.Record;
const Shape = comment_module.Shape;
const Writer = writer_module.Writer;
const WriterQuiet = writer_module.WriterQuiet;
const WriterRun = writer_module.WriterRun;

pub const Capacity = storage_module.Capacity;
pub const CollectionStyle = parser_module.CollectionStyle;
pub const Position = parser_module.Position;
pub const ScalarStyle = parser_module.ScalarStyle;
pub const Schema = schema_module.Schema;
pub const Storage = storage_module.Storage;

const KeyProbe = storage_module.KeyProbe;

const index_none = storage_module.index_none;
const probe_count_max = storage_module.probe_count_max;
const scan_entry_count_max = storage_module.scan_entry_count_max;
const writer_depth_max = writer_module.depth_max;

comptime {
    assert(writer_depth_max == composer.frame_capacity);
}

pub const CapacityError = parser_module.CapacityError || error{
    AnchorsExhausted,
    KeyCollision,
    NodesExhausted,
};

pub const SyntaxError = parser_module.SyntaxError || error{
    AliasRecursive,
    AliasUndefined,
    KeyDuplicate,
};

pub const Kind = enum {
    mapping,
    scalar,
    sequence,
};

pub const Node = enum(u32) { _ };

pub const Style = union(Kind) {
    mapping: CollectionStyle,
    scalar: ScalarStyle,
    sequence: CollectionStyle,
};

const Frame = struct {
    end: u32,
    mapping: bool,
};

const KeptFrame = struct {
    cold: bool,
    end: u32,
    mapping: bool,
};

const KeptState = struct {
    flow: bool,
    key_range: Range,
    key_shape: Shape,
    key_value: u32,
    range: Range,
    value: bool,
};

const Resume = struct {
    position: u32,
    tail: bool,
};

const Segment = struct {
    bound: u32,
    start: u32,
};

const Step = enum {
    node,
    resumed,
    run,
    tail,
};

const Taken = struct {
    position: u32,
    step: Step,
};

pub const Entries = struct {
    cursor: u32,
    document: *const Document,
    remaining: u32,

    pub const Entry = struct {
        key: Node,
        value: Node,
    };

    pub fn next(entries: *Entries) ?Entry {
        assert(entries.remaining <= entries.document.node_count);
        assert(entries.cursor <= entries.document.node_count);

        if (entries.remaining == 0) return null;

        const document = entries.document;
        const key = entries.cursor;
        const value = key + document.storage.nodes[key].span;

        entries.cursor = value + document.storage.nodes[value].span;
        entries.remaining -= 1;

        return .{ .key = document.handle_of(key), .value = document.handle_of(value) };
    }
};

pub const Items = struct {
    cursor: u32,
    document: *const Document,
    remaining: u32,

    pub fn next(items: *Items) ?Node {
        assert(items.remaining <= items.document.node_count);
        assert(items.cursor <= items.document.node_count);

        if (items.remaining == 0) return null;

        const document = items.document;
        const item = items.cursor;

        items.cursor = item + document.storage.nodes[item].span;
        items.remaining -= 1;

        return document.handle_of(item);
    }
};

pub const Document = struct {
    comment_count: u32,
    composer: composer.State,
    diagnostic: Position,
    document_count: u32,
    key_bucket_count: u32,
    node_count: u32,
    schema: Schema,
    source: []const u8,
    storage: Storage,

    pub const Error = CapacityError || SyntaxError;

    pub const Options = struct {
        schema: Schema = .core,
    };

    pub fn parse(
        document: *Document,
        storage: Storage,
        source: []const u8,
        options: Options,
    ) Error!void {
        comptime assert(@sizeOf(@TypeOf(options)) <= 16);
        assert(source.len <= scanner_module.source_bytes_max);
        assert(storage.nodes.len > 0);

        document.schema = options.schema;

        try composer.compose(document, storage, source);

        assert(document.schema == options.schema);
        assert(document.diagnostic.line == 0);
        assert(document.composer.frame_count == 0);
    }

    fn handle_of(document: *const Document, index: u32) Node {
        assert(index < document.node_count);
        assert(document.node_count <= document.storage.nodes.len);

        const target = storage_module.resolved(document.storage.nodes, index);
        return @fromBackingInt(target);
    }

    fn record_of(document: *const Document, node: Node) *const Record {
        assert(@backingInt(node) < document.node_count);
        assert(document.storage.nodes[@backingInt(node)].kind != .alias);

        return &document.storage.nodes[@backingInt(node)];
    }

    pub fn root_count(document: *const Document) u32 {
        assert(document.document_count <= document.storage.roots.len);
        assert(document.composer.frame_count == 0);

        return document.document_count;
    }

    pub fn comments(document: *const Document, node: Node) Comments {
        assert(@backingInt(node) < document.node_count);
        assert(document.comment_count <= document.storage.comments.len);

        const slots = document.storage.comments[0..document.comment_count];
        const index = @backingInt(node);
        const range = if (slots.len == 0) Range.empty else comment_module.range_of(slots, index);
        const blank = document.storage.nodes[index].markers.blank_before;

        return comment_module.comments_of(slots, range, blank);
    }

    pub fn root(document: *const Document, index: u32) Node {
        assert(index < document.document_count);
        assert(document.document_count <= document.storage.roots.len);

        return document.handle_of(document.storage.roots[index]);
    }

    pub fn kind_of(document: *const Document, node: Node) Kind {
        assert(@backingInt(node) < document.node_count);
        assert(document.composer.frame_count == 0);

        return switch (document.record_of(node).kind) {
            .alias => unreachable,
            .mapping => .mapping,
            .scalar => .scalar,
            .sequence => .sequence,
        };
    }

    pub fn text_of(document: *const Document, node: Node) ?[]const u8 {
        assert(@backingInt(node) < document.node_count);
        assert(document.composer.frame_count == 0);

        const record = document.record_of(node);
        if (record.kind != .scalar) return null;
        return record.text;
    }

    pub fn style_of(document: *const Document, node: Node) Style {
        assert(@backingInt(node) < document.node_count);
        assert(document.composer.frame_count == 0);

        const record = document.record_of(node);

        return switch (record.kind) {
            .alias => unreachable,
            .mapping => .{ .mapping = @fromBackingInt(@intCast(record.style)) },
            .scalar => .{ .scalar = @fromBackingInt(@intCast(record.style)) },
            .sequence => .{ .sequence = @fromBackingInt(@intCast(record.style)) },
        };
    }

    pub fn tag_of(document: *const Document, node: Node) []const u8 {
        assert(@backingInt(node) < document.node_count);
        assert(document.composer.frame_count == 0);

        return document.record_of(node).tag;
    }

    pub fn anchor_of(document: *const Document, node: Node) []const u8 {
        assert(@backingInt(node) < document.node_count);
        assert(document.composer.frame_count == 0);

        return document.record_of(node).anchor;
    }

    pub fn position_of(document: *const Document, node: Node) Position {
        assert(@backingInt(node) < document.node_count);
        assert(document.composer.frame_count == 0);

        return storage_module.position_of(document.record_of(node));
    }

    pub fn count_of(document: *const Document, node: Node) u32 {
        assert(@backingInt(node) < document.node_count);

        const record = document.record_of(node);
        const result = record.link.count;

        if (record.kind == .scalar) assert(result == 0);

        assert(result < document.node_count);

        return result;
    }

    pub fn entries(document: *const Document, mapping: Node) Entries {
        assert(@backingInt(mapping) < document.node_count);

        const record = document.record_of(mapping);
        const count = if (record.kind == .mapping) record.link.count else 0;

        assert(count < document.node_count);

        return .{
            .cursor = @backingInt(mapping) + 1,
            .document = document,
            .remaining = count,
        };
    }

    pub fn items(document: *const Document, sequence: Node) Items {
        assert(@backingInt(sequence) < document.node_count);

        const record = document.record_of(sequence);
        const count = if (record.kind == .sequence) record.link.count else 0;

        assert(count < document.node_count);

        return .{
            .cursor = @backingInt(sequence) + 1,
            .document = document,
            .remaining = count,
        };
    }

    pub fn member(document: *const Document, mapping: Node, key: []const u8) ?Node {
        assert(@backingInt(mapping) < document.node_count);
        assert(key.len <= scanner_module.source_bytes_max);

        const mapping_index = @backingInt(mapping);

        if (document.record_of(mapping).kind != .mapping) return null;

        const nodes = document.storage.nodes;
        const count = document.record_of(mapping).link.count;

        if (count <= scan_entry_count_max) {
            const scan: storage_module.EntryScan = .{ .count = count, .mapping = mapping_index };
            const value = storage_module.entry_find(nodes, scan, key) orelse return null;

            return document.handle_of(value);
        }

        const hash = storage_module.hash_of(mapping_index, key);
        const probe: KeyProbe = .{ .hash = hash, .mapping = mapping_index, .text = key };
        const mask = document.key_bucket_count - 1;
        var bucket = hash & mask;

        for (0..probe_count_max) |_| {
            const entry = document.storage.key_buckets[bucket];
            if (entry == index_none) return null;

            const slot = &document.storage.keys[entry];

            if (storage_module.slot_matches(nodes, slot, &probe)) {
                return document.handle_of(slot.value);
            }

            bucket = (bucket + 1) & mask;
        }

        return null;
    }

    pub fn item(document: *const Document, sequence: Node, index: u32) ?Node {
        assert(@backingInt(sequence) < document.node_count);
        assert(index < scanner_module.source_bytes_max);

        const record = document.record_of(sequence);
        if (record.kind != .sequence) return null;
        if (record.link.count <= index) return null;

        const nodes = document.storage.nodes;
        const end = @backingInt(sequence) + record.span;
        var cursor = @backingInt(sequence) + 1;

        for (0..index) |_| cursor += nodes[cursor].span;

        assert(cursor < end);

        return document.handle_of(cursor);
    }

    pub fn path_find(document: *const Document, start: Node, segments: []const []const u8) ?Node {
        assert(@backingInt(start) < document.node_count);
        assert(segments.len <= scanner_module.source_bytes_max);

        var node = start;

        for (segments) |segment| {
            node = document.step_find(node, segment) orelse return null;
        }

        return node;
    }

    fn step_find(document: *const Document, node: Node, segment: []const u8) ?Node {
        assert(@backingInt(node) < document.node_count);
        assert(segment.len <= scanner_module.source_bytes_max);

        switch (document.kind_of(node)) {
            .mapping => return document.member(node, segment),
            .scalar => return null,
            .sequence => {
                const index = segment_index_of(segment) orelse return null;
                return document.item(node, index);
            },
        }
    }

    pub fn write(
        document: *const Document,
        sink: *std.Io.Writer,
        options: Writer.Options,
    ) std.Io.Writer.Error!void {
        comptime assert(@sizeOf(@TypeOf(options)) <= 16);
        assert(options.indent >= 1);
        assert(document.composer.frame_count == 0);

        var trusted = options;

        trusted.utf8 = .trusted;

        const quiet = document.comment_count == 0 and !document.blanks_any();
        if (quiet) return document.documents_write(WriterQuiet, sink, trusted);

        try document.documents_write(Writer, sink, trusted);
    }

    pub fn write_json(
        document: *const Document,
        sink: *std.Io.Writer,
        options: JSONOptions,
    ) JSONOptions.Error!void {
        comptime assert(@sizeOf(@TypeOf(options)) <= 16);
        assert(options.node_count_max > 0);
        assert(document.composer.frame_count == 0);

        const counted = try json_writer.json_write(Document, .count, document, sink, &options);

        const emitted = json_writer.json_write(
            Document,
            .emit,
            document,
            sink,
            &options,
        ) catch |err| switch (err) {
            error.DepthExceeded,
            error.ExpansionExceeded,
            error.FloatNonFinite,
            error.KeyInvalid,
            error.MergeInvalid,
            error.MergesExceeded,
            => unreachable,
            error.WriteFailed => |failed| return failed,
        };

        assert(emitted == counted);
    }

    fn blanks_any(document: *const Document) bool {
        assert(document.document_count <= document.node_count);

        for (0..document.document_count) |index| {
            if (document.blanks_of(@intCast(index))) return true;
        }

        return false;
    }

    fn blanks_of(document: *const Document, index: u32) bool {
        assert(index < document.document_count);

        const markers = document.storage.nodes[document.storage.roots[index]].markers;
        return markers.blank_before or markers.blank_inside;
    }

    fn document_write(
        document: *const Document,
        comptime Emitter: type,
        writer: *Emitter,
        index: u32,
    ) Writer.Error!void {
        assert(index < document.document_count);
        assert(writer.depth == 0);

        if (Emitter == Writer) {
            const kept = document.comment_count > 0 or document.blanks_of(index);
            if (kept) return document.document_comments_write(writer, index);
        } else {
            assert(document.comment_count == 0);
            assert(!document.blanks_of(index));
        }

        const start = document.storage.roots[index];
        const markers = document.storage.nodes[start].markers;

        try writer.document_begin(&.{ .explicit = markers.start_explicit });
        try document.records_write(Emitter, writer, start);
        try writer.document_end(&.{ .explicit = markers.end_explicit });
    }

    fn documents_write(
        document: *const Document,
        comptime Emitter: type,
        sink: *std.Io.Writer,
        options: Writer.Options,
    ) std.Io.Writer.Error!void {
        assert(options.utf8 == .trusted);
        assert(Emitter == Writer or document.comment_count == 0);

        var writer: Emitter = undefined;

        writer.init(sink, options);

        if (Emitter == Writer) {
            const comments_only = document.document_count == 0 and document.comment_count > 0;

            if (comments_only) {
                document.stray_comments_write(&writer) catch |err| switch (err) {
                    error.DepthExceeded,
                    error.EnumerationUnrecognized,
                    error.TextInvalid,
                    => unreachable,
                    error.WriteFailed => |failed| return failed,
                };
            }
        }

        for (0..document.document_count) |index| {
            document.document_write(Emitter, &writer, @intCast(index)) catch |err| switch (err) {
                error.DepthExceeded,
                error.EnumerationUnrecognized,
                error.TextInvalid,
                => unreachable,
                error.WriteFailed => |failed| return failed,
            };
        }

        writer.finish();
    }

    fn document_comments_write(
        document: *const Document,
        writer: *Writer,
        index: u32,
    ) Writer.Error!void {
        assert(index < document.document_count);
        assert(document.comment_count > 0 or document.blanks_of(index));

        const start = document.storage.roots[index];
        const markers = document.storage.nodes[start].markers;
        const slots = document.storage.comments[0..document.comment_count];
        const range = comment_module.range_of(slots, start);

        try comment_module.prefix_heads_write(writer, slots, range);
        try writer.document_begin(&.{ .explicit = markers.start_explicit });
        try document.records_comments_write(writer, start, range);
        try writer.document_end(&.{ .explicit = markers.end_explicit });
        try comment_module.feet_write(writer, slots, range, true, .all);
    }

    fn stray_comments_write(document: *const Document, writer: *Writer) Writer.Error!void {
        assert(document.document_count == 0);
        assert(writer.depth == 0);

        const slots = document.storage.comments[0..document.comment_count];

        for (slots) |*slot| {
            assert(slot.node == index_none);

            if (slot.flags.blank_before) try writer.comment(.foot, "");

            try writer.comment(.foot, slot.text);
        }
    }

    noinline fn records_comments_write(
        document: *const Document,
        writer: *Writer,
        start: u32,
        range: Range,
    ) Writer.Error!void {
        assert(start < document.node_count);
        assert(writer.depth == 0);
        assert(range.first <= range.end);

        const nodes = document.storage.nodes;
        const slots = document.storage.comments[0..document.comment_count];
        const slot_first = if (range.first == slots.len) index_none else slots[range.first].node;
        const quiet_start = writer_module.quiet_enter(writer) != null;

        var walk: KeptWalk = .{
            .cursor = range.first,
            .depth = 0,
            .document = document,
            .end = start + nodes[start].span,
            .frames = undefined,
            .hold_depth = 0,
            .slots = slots,
            .states = undefined,
            .stop_next = if (quiet_start) slot_first else start,
            .tail_due = false,
            .tail_range = Range.empty,
            .tail_value = false,
            .writer = writer,
        };

        try walk.runs_write(@ptrCast(writer), start);
        try walk.closes_write(walk.end);

        assert(walk.depth == 0);
        assert(writer.depth == 0);
    }

    fn records_write(
        document: *const Document,
        comptime Emitter: type,
        writer: *Emitter,
        start: u32,
    ) align(64) Writer.Error!void {
        assert(start < document.node_count);
        assert(writer.depth <= writer_depth_max);

        try subtree_write(document, Emitter, writer, start);
    }

    inline fn subtree_write(
        document: *const Document,
        comptime Emitter: type,
        writer: *Emitter,
        start: u32,
    ) Writer.Error!void {
        assert(start < document.node_count);
        assert(writer.depth <= writer_depth_max);

        const depth_entry = writer.depth;
        const nodes = document.storage.nodes;
        const end = start + nodes[start].span;
        var frames: [writer_depth_max]Frame = undefined;
        var depth: u32 = 0;

        assert(end <= document.node_count);

        for (start..end) |position| {
            for (0..depth) |_| {
                if (frames[depth - 1].end != position) break;

                depth -= 1;

                try collection_end_write(Emitter, writer, frames[depth].mapping);
            }

            const record = &nodes[position];

            if (Emitter == Writer) {
                const blank = position > start and record.markers.blank_before;

                if (blank) try writer.comment(.head, "");
            }

            switch (record.kind) {
                .alias => try writer.alias(&.{ .anchor = nodes[record.link.target].anchor }),
                .mapping, .sequence => {
                    try collection_begin_write(Emitter, writer, record);

                    frames[depth] = .{
                        .end = @intCast(position + record.span),
                        .mapping = record.kind == .mapping,
                    };

                    depth += 1;
                },
                .scalar => try writer.scalar(&.{
                    .anchor = record.anchor,
                    .style = @fromBackingInt(@intCast(record.style)),
                    .tag = record.tag,
                    .text = record.text,
                }),
            }
        }

        for (0..depth) |_| {
            depth -= 1;

            assert(frames[depth].end == end);

            try collection_end_write(Emitter, writer, frames[depth].mapping);
        }

        assert(writer.depth == depth_entry);
    }

    pub fn null_is(document: *const Document, node: Node) bool {
        assert(@backingInt(node) < document.node_count);
        assert(document.composer.frame_count == 0);

        const text = document.core_text_of(node, schema_module.tag_null) orelse return false;
        return schema_module.null_text_is(text, document.schema);
    }

    pub fn boolean_of(document: *const Document, node: Node) ?bool {
        assert(@backingInt(node) < document.node_count);
        assert(document.composer.frame_count == 0);

        const text = document.core_text_of(node, schema_module.tag_boolean) orelse return null;
        return schema_module.boolean_text_of(text, document.schema);
    }

    pub fn integer_of(document: *const Document, node: Node) ?i64 {
        assert(@backingInt(node) < document.node_count);
        assert(document.composer.frame_count == 0);

        const text = document.core_text_of(node, schema_module.tag_integer) orelse return null;
        return schema_module.integer_text_of(i64, text, document.schema);
    }

    pub fn float_of(document: *const Document, node: Node) ?f64 {
        assert(@backingInt(node) < document.node_count);
        assert(document.composer.frame_count == 0);

        const text = document.core_text_of(node, schema_module.tag_float) orelse return null;

        if (schema_module.integer_text_of(i64, text, document.schema)) |integer| {
            const result: f64 = @floatFromInt(integer);

            assert(@abs(result) <= 0x1p63);

            return result;
        }

        return schema_module.float_text_of(text, document.schema);
    }

    fn core_text_of(document: *const Document, node: Node, tag: []const u8) ?[]const u8 {
        assert(@backingInt(node) < document.node_count);
        assert(tag.len > 0);

        const record = document.record_of(node);
        if (record.kind != .scalar) return null;
        if (std.mem.eql(u8, record.tag, tag)) return record.text;
        if (record.tag.len > 0) return null;

        const style: ScalarStyle = @fromBackingInt(@intCast(record.style));
        if (style != .plain) return null;
        return record.text;
    }
};

pub fn segment_index_of(segment: []const u8) ?u32 {
    assert(segment.len <= scanner_module.source_bytes_max);
    assert(scanner_module.source_bytes_max < std.math.maxInt(u32));

    if (segment.len == 0) return null;
    if (segment[0] == '0') return if (segment.len == 1) 0 else null;

    for (segment) |byte| {
        if (!std.ascii.isDigit(byte)) return null;
    }

    const result = std.fmt.parseUnsigned(u32, segment, 10) catch return null;
    if (result >= scanner_module.source_bytes_max) return null;
    return result;
}

fn collection_begin_write(
    comptime Emitter: type,
    writer: *Emitter,
    record: *const Record,
) Writer.Error!void {
    assert(record.kind == .mapping or record.kind == .sequence);
    assert(record.span > 0);

    const properties: Event.CollectionStart = .{
        .anchor = record.anchor,
        .style = @fromBackingInt(@intCast(record.style)),
        .tag = record.tag,
    };

    if (record.kind == .mapping) {
        try writer.mapping_begin(&properties);
    } else {
        try writer.sequence_begin(&properties);
    }
}

const KeptWalk = struct {
    cursor: u32,
    depth: u32,
    document: *const Document,
    end: u32,
    frames: [writer_depth_max]KeptFrame,
    hold_depth: u32,
    slots: []const CommentSlot,
    states: [writer_depth_max]KeptState,
    stop_next: u32,
    tail_due: bool,
    tail_range: Range,
    tail_value: bool,
    writer: *Writer,

    inline fn blank_quiet_write(walk: *KeptWalk, record: *const Record) Writer.Error!void {
        assert(walk.depth <= writer_depth_max);
        assert(record.span > 0);

        if (!record.markers.blank_before) return;

        if (walk.writer.depth == 0) {
            try walk.writer.comment(.head, "");
        } else {
            try writer_module.blank_quiet_write(walk.writer);
        }
    }

    fn block_scalar_next_is(walk: *const KeptWalk, position: u32) bool {
        assert(position <= walk.end);
        assert(walk.end <= walk.document.node_count);

        if (position == walk.end) return false;

        const record = &walk.document.storage.nodes[position];
        if (record.kind != .scalar) return false;

        const style: ScalarStyle = @fromBackingInt(@intCast(record.style));
        return style == .literal or style == .folded;
    }

    fn close(walk: *KeptWalk) Writer.Error!void {
        assert(walk.depth > 0);
        assert(walk.frames[walk.depth - 1].cold);

        walk.depth -= 1;

        const frame = &walk.frames[walk.depth];
        const state = &walk.states[walk.depth];
        const writer = walk.writer;
        const shape: Shape = .of_collection(state.flow);

        if (state.range.end == state.range.first) {
            try collection_end_write(Writer, writer, frame.mapping);

            return walk.finish(state.range, shape, state.value, frame.end);
        }

        try comment_module.collection_feet_write(writer, walk.slots, state.range, state.flow);
        try collection_end_write(Writer, writer, frame.mapping);
        try comment_module.line_write(writer, walk.slots, state.range, .closing);
        try walk.finish(state.range, shape, state.value, frame.end);
    }

    fn closes_write(walk: *KeptWalk, position: u32) Writer.Error!void {
        assert(position <= walk.end);
        assert(walk.depth <= writer_depth_max);

        for (0..walk.depth) |_| {
            const frame = &walk.frames[walk.depth - 1];
            if (frame.end != position) break;

            if (frame.cold) {
                try walk.close();
            } else {
                walk.depth -= 1;

                try collection_end_write(Writer, walk.writer, frame.mapping);
            }
        }
    }

    fn cold_closing_is(walk: *const KeptWalk, position: u32) bool {
        assert(position <= walk.end);
        assert(walk.depth <= writer_depth_max);

        var depth = walk.depth;

        for (0..walk.depth) |_| {
            const frame = &walk.frames[depth - 1];
            if (frame.end != position) return false;
            if (frame.cold) return true;

            depth -= 1;
        }

        return false;
    }

    fn finish(
        walk: *KeptWalk,
        range: Range,
        shape: Shape,
        value: bool,
        next: u32,
    ) Writer.Error!void {
        assert(range.first <= range.end);
        assert(range.end <= walk.slots.len);
        assert(@backingInt(shape) <= 2);
        assert(next <= walk.end);

        const writer = walk.writer;
        const commented = range.end > range.first;
        const mapped = walk.depth > 0 and walk.frames[walk.depth - 1].mapping;

        if (!mapped) {
            if (commented) try comment_module.feet_after_write(writer, walk.slots, range, shape);

            return;
        }

        const state = &walk.states[walk.depth - 1];

        if (!value) {
            assert(state.key_value == index_none);

            const deferred = commented and shape != .block;

            if (deferred) {
                assert(next < walk.frames[walk.depth - 1].end);

                state.key_range = range;
                state.key_shape = shape;
                state.key_value = next;
                walk.hold_depth = @max(walk.hold_depth, walk.depth);
                walk.stop_next = @min(walk.stop_next, next);
            }

            return;
        }

        if (commented) try comment_module.feet_after_write(writer, walk.slots, range, shape);

        if (state.key_value != index_none) {
            const key_range = state.key_range;
            const key_shape = state.key_shape;

            state.key_value = index_none;

            try comment_module.feet_after_write(writer, walk.slots, key_range, key_shape);
        }
    }

    fn flow_written_is(walk: *const KeptWalk, record: *const Record) bool {
        assert(record.kind == .mapping or record.kind == .sequence);
        assert(record.span > 0);

        return switch (walk.writer.options.layout) {
            .block => false,
            .flow => true,
            .preserve => record.style == @backingInt(CollectionStyle.flow),
        };
    }

    inline fn frame_push(walk: *KeptWalk, record: *const Record, position: u32, cold: bool) void {
        assert(position < walk.end);
        assert(walk.depth < writer_depth_max);
        assert(walk.writer.depth == walk.depth + 1);

        walk.frames[walk.depth] = .{
            .cold = cold,
            .end = position + record.span,
            .mapping = record.kind == .mapping,
        };

        walk.states[walk.depth].key_value = index_none;
        walk.depth += 1;

        if (cold) walk.hold_depth = @max(walk.hold_depth, walk.depth);
    }

    fn heads_placed_is(walk: *const KeptWalk, position: u32) bool {
        assert(position < walk.end);
        assert(walk.depth > 0);
        assert(walk.writer.depth == walk.depth);

        const frame = &walk.frames[walk.depth - 1];
        if (frame.end == position) return false;
        if (!frame.mapping) return true;
        if (walk.states[walk.depth - 1].key_value != index_none) return false;
        return !walk.writer.frames[walk.writer.depth - 1].value_next;
    }

    fn heads_take(walk: *KeptWalk, record: *const Record, position: u32) Writer.Error!bool {
        assert(position < walk.end);
        assert(walk.cursor <= walk.slots.len);

        const writer = walk.writer;
        const collection = record.kind == .mapping or record.kind == .sequence;

        if (collection) {
            if (walk.flow_written_is(record)) return false;
        }

        if (walk.depth > 0) {
            if (!walk.heads_placed_is(position)) return false;
        }

        if (writer_module.quiet_enter(writer) == null) return false;

        const slots = walk.slots;
        const first = walk.cursor;
        var end = first;

        for (slots[first..]) |*slot| {
            if (slot.node != position) break;
            if (slot.placement != .head) return false;

            end += 1;
        }

        if (end == first) return false;

        walk.cursor = end;

        const range: Range = .{ .end = end, .first = first };

        try comment_module.heads_write(writer, slots, range, record.markers.blank_before);

        assert(writer_module.quiet_enter(writer) != null);

        walk.stop_next_settle(position);

        return true;
    }

    fn line_append_is(walk: *const KeptWalk, range: Range, position: u32) bool {
        assert(position < walk.end);
        assert(range.first <= range.end);
        assert(range.end <= walk.slots.len);

        if (range.end != range.first + 1) return false;
        if (walk.slots[range.first].placement != .line) return false;
        if (walk.depth == 0) return false;
        if (walk.cold_closing_is(position + 1)) return false;
        if (walk.block_scalar_next_is(position + 1)) return false;

        const mapped = walk.frames[walk.depth - 1].mapping;

        if (mapped) {
            if (walk.states[walk.depth - 1].key_value != index_none) return false;
        }

        return writer_module.line_append_is(walk.writer);
    }

    fn pending_flush(walk: *KeptWalk, position: u32) Writer.Error!bool {
        assert(position < walk.end);
        assert(walk.depth <= writer_depth_max);

        const record = &walk.document.storage.nodes[position];
        const marked = record.markers.blank_before or record.markers.blank_inside;

        if (walk.depth == 0) return false;
        if (walk.frames[walk.depth - 1].end == position) return false;
        if (marked) return false;

        if (!walk.quiet_is(record, position)) {
            if (!walk.trailing_only_is(record, position)) return false;
        }

        return writer_module.pending_flush(walk.writer);
    }

    fn quiet_is(walk: *const KeptWalk, record: *const Record, position: u32) bool {
        assert(position < walk.end);
        assert(walk.stop_next >= position);

        if (position == walk.stop_next) return false;

        const collection = record.kind == .mapping or record.kind == .sequence;
        const inner = position + record.span > walk.stop_next or record.markers.blank_inside;
        const flow_inner = collection and inner and walk.flow_written_is(record);
        if (flow_inner) return false;
        if (!record.markers.blank_before) return true;
        if (walk.writer.depth == 0) return true;
        return writer_module.blank_quiet_is(walk.writer);
    }

    fn quiet_write(walk: *KeptWalk, record: *const Record, position: u32) Writer.Error!void {
        assert(position < walk.end);
        assert(walk.depth < writer_depth_max);

        const writer = walk.writer;

        switch (record.kind) {
            .alias => {
                const target = &walk.document.storage.nodes[record.link.target];

                try writer.alias(&.{ .anchor = target.anchor });
            },
            .mapping, .sequence => {
                try collection_begin_write(Writer, writer, record);

                walk.frame_push(record, position, false);
            },
            .scalar => try writer.scalar(&.{
                .anchor = record.anchor,
                .style = @fromBackingInt(@intCast(record.style)),
                .tag = record.tag,
                .text = record.text,
            }),
        }
    }

    fn range_next(walk: *KeptWalk, position: u32) Range {
        assert(position < walk.end);
        assert(walk.cursor <= walk.slots.len);

        const first = walk.cursor;

        for (walk.cursor..walk.slots.len) |slot_index| {
            if (walk.slots[slot_index].node != position) break;

            walk.cursor += 1;
        }

        return .{ .end = walk.cursor, .first = first };
    }

    inline fn run_closes_write(
        walk: *KeptWalk,
        run: *WriterRun,
        depth: *u32,
        position: u32,
        closable: bool,
    ) Writer.Error!void {
        assert(depth.* <= writer_depth_max);
        assert(position <= walk.end);

        for (0..depth.*) |_| {
            const frame = &walk.frames[depth.* - 1];
            if (frame.end != position) break;
            if (frame.cold) break;
            if (!closable) break;

            if (position == walk.end) {
                if (writer_module.quiet_enter(walk.writer) == null) break;
            }

            depth.* -= 1;

            try collection_end_write(WriterRun, run, frame.mapping);
        }
    }

    inline fn run_node_write(
        walk: *KeptWalk,
        run: *WriterRun,
        record: *const Record,
        position: u32,
        depth: *u32,
    ) Writer.Error!void {
        assert(position < walk.end);
        assert(depth.* < writer_depth_max);

        switch (record.kind) {
            .alias => {
                const target = &walk.document.storage.nodes[record.link.target];

                try run.alias(&.{ .anchor = target.anchor });
            },
            .mapping, .sequence => {
                try collection_begin_write(WriterRun, run, record);

                walk.frames[depth.*] = .{
                    .cold = false,
                    .end = position + record.span,
                    .mapping = record.kind == .mapping,
                };

                walk.states[depth.*].key_value = index_none;
                depth.* += 1;
            },
            .scalar => try run.scalar(&.{
                .anchor = record.anchor,
                .style = @fromBackingInt(@intCast(record.style)),
                .tag = record.tag,
                .text = record.text,
            }),
        }
    }

    inline fn runs_write(walk: *KeptWalk, run: *WriterRun, start: u32) Writer.Error!void {
        assert(start < walk.end);
        assert(walk.depth == 0);

        var depth: u32 = 0;
        var position = start;
        var stop_next = walk.stop_next;
        var stop = walk.stop_find(position);

        for (start..walk.end) |_| {
            if (position == walk.end) break;

            try walk.run_closes_write(run, &depth, position, stop_next > position);

            var step: Step = .run;

            if (position == stop) {
                walk.depth = depth;

                const taken = try walk.stop_take(position);

                depth = walk.depth;
                position = taken.position;
                stop_next = walk.stop_next;
                step = taken.step;

                if (step == .resumed) {
                    stop = walk.stop_find(position);

                    continue;
                }
            }

            const bound = switch (step) {
                .node => walk.stop_find(position + 1),
                .resumed => unreachable,
                .run => stop,
                .tail => position + 1,
            };

            try walk.segment_write(run, &depth, .{ .bound = bound, .start = position });

            position = bound;
            stop = bound;

            if (step == .tail) {
                walk.depth = depth;

                try walk.tail_take_write(position - 1);

                stop_next = walk.stop_next;
                stop = walk.stop_find(position);
            }
        }

        assert(position == walk.end);

        try walk.run_closes_write(run, &depth, walk.end, true);

        walk.depth = depth;
    }

    fn scalar_write(walk: *KeptWalk, record: *const Record, range: Range) Writer.Error!void {
        assert(record.kind == .scalar);
        assert(range.first <= range.end);

        const writer = walk.writer;
        const style: ScalarStyle = @fromBackingInt(@intCast(record.style));
        const block = style == .literal or style == .folded;
        const commented = range.end > range.first;
        const line_first = if (commented) block else false;
        const line_last = if (commented) !block else false;

        if (line_first) try comment_module.line_write(writer, walk.slots, range, .node);

        try writer.scalar(&.{
            .anchor = record.anchor,
            .style = style,
            .tag = record.tag,
            .text = record.text,
        });

        if (line_last) try comment_module.line_write(writer, walk.slots, range, .node);
    }

    noinline fn segment_write(
        walk: *KeptWalk,
        run: *WriterRun,
        depth_entry: *u32,
        segment: Segment,
    ) align(2048) Writer.Error!void {
        assert(segment.start < segment.bound);
        assert(segment.bound <= walk.end);
        assert(depth_entry.* <= writer_depth_max);

        const nodes = walk.document.storage.nodes;
        const bound = segment.bound;
        const start = segment.start;
        var depth = depth_entry.*;
        var position = start;

        for (start..bound) |_| {
            try walk.run_node_write(run, &nodes[position], position, &depth);

            position += 1;

            if (position == bound) break;

            for (0..depth) |_| {
                const frame = &walk.frames[depth - 1];
                if (frame.end != position) break;

                assert(!frame.cold);

                depth -= 1;

                try collection_end_write(WriterRun, run, frame.mapping);
            }
        }

        assert(position == bound);

        depth_entry.* = depth;
    }

    noinline fn slow_write(walk: *KeptWalk, position: u32) Writer.Error!Resume {
        assert(position < walk.end);
        assert(!walk.tail_due);

        const nodes = walk.document.storage.nodes;
        var cursor = position;

        for (position..walk.end) |_| {
            try walk.closes_write(cursor);

            const record = &nodes[cursor];
            const stop = record.markers.blank_before or !walk.quiet_is(record, cursor);

            if (stop) {
                cursor = try walk.stop_write(cursor);

                if (walk.tail_due) break;
            } else {
                try walk.quiet_write(record, cursor);

                cursor += 1;
            }

            if (cursor == walk.end) break;
            if (writer_module.quiet_enter(walk.writer) != null) break;
            if (try walk.pending_flush(cursor)) break;
        }

        assert(cursor >= position);
        assert(cursor <= walk.end);

        const tail = walk.tail_due;

        walk.tail_due = false;

        return .{ .position = cursor, .tail = tail };
    }

    fn stop_find(walk: *const KeptWalk, start: u32) u32 {
        assert(start <= walk.end);
        assert(walk.stop_next >= start);

        const nodes = walk.document.storage.nodes;
        const limit = @min(walk.stop_next, walk.end);
        var position = start;

        for (start..limit) |_| {
            if (position >= limit) break;

            const markers = nodes[position].markers;
            if (markers.blank_before) return position;

            position += if (markers.blank_inside) 1 else nodes[position].span;
        }

        return limit;
    }

    fn stop_next_settle(walk: *KeptWalk, position: u32) void {
        assert(position < walk.end);
        assert(walk.cursor <= walk.slots.len);
        assert(walk.depth <= writer_depth_max);

        const count = @min(walk.hold_depth, walk.depth);
        var next = if (walk.cursor == walk.slots.len) index_none else walk.slots[walk.cursor].node;
        var held: u32 = 0;

        for (walk.frames[count..walk.depth], walk.states[count..walk.depth]) |*frame, *state| {
            assert(!frame.cold);
            assert(state.key_value == index_none);
        }

        for (walk.frames[0..count], walk.states[0..count], 1..) |*frame, *state, height| {
            const cold_end = if (frame.cold) frame.end else index_none;
            const key_next = if (state.key_value > position) state.key_value else index_none;
            const holds = frame.cold or state.key_value != index_none;

            if (holds) held = @intCast(height);

            next = @min(next, cold_end, key_next);
        }

        assert(next > position);
        assert(held <= count);

        walk.hold_depth = held;
        walk.stop_next = next;
    }

    fn stop_take(walk: *KeptWalk, position: u32) Writer.Error!Taken {
        assert(position < walk.end);
        assert(walk.depth <= writer_depth_max);

        const record = &walk.document.storage.nodes[position];
        if (walk.trailing_take(record, position)) return .{ .position = position, .step = .tail };

        if (walk.quiet_is(record, position)) {
            try walk.blank_quiet_write(record);

            return .{ .position = position, .step = .node };
        }

        if (try walk.heads_take(record, position)) return .{ .position = position, .step = .node };

        const resumed = try walk.slow_write(position);
        return .{ .position = resumed.position, .step = if (resumed.tail) .tail else .resumed };
    }

    fn stop_write(walk: *KeptWalk, position: u32) Writer.Error!u32 {
        assert(position < walk.end);
        assert(walk.depth <= writer_depth_max);

        const nodes = walk.document.storage.nodes;
        const record = &nodes[position];
        const range = walk.range_next(position);
        const writer = walk.writer;
        const blank = record.markers.blank_before;
        const commented = range.end > range.first;
        const headed = commented or blank;

        const value = walk.depth > 0 and walk.frames[walk.depth - 1].mapping and
            writer.frames[writer.depth - 1].value_next;

        if (headed) try comment_module.heads_write(writer, walk.slots, range, blank);

        switch (record.kind) {
            .alias => {
                try writer.alias(&.{ .anchor = nodes[record.link.target].anchor });

                if (commented) try comment_module.line_write(writer, walk.slots, range, .node);

                try walk.finish(range, .leaf, value, position + 1);
            },
            .mapping, .sequence => {
                try collection_begin_write(Writer, writer, record);

                if (commented) try comment_module.line_write(writer, walk.slots, range, .opening);

                walk.frame_push(record, position, true);

                walk.states[walk.depth - 1] = .{
                    .flow = record.style == @backingInt(CollectionStyle.flow),
                    .key_range = Range.empty,
                    .key_shape = .block,
                    .key_value = index_none,
                    .range = range,
                    .value = value,
                };
            },
            .scalar => {
                const style: ScalarStyle = @fromBackingInt(@intCast(record.style));
                const block = style == .literal or style == .folded;
                const tail_due = !block and writer_module.quiet_enter(writer) != null;

                if (tail_due) {
                    walk.tail_due = true;
                    walk.tail_range = range;
                    walk.tail_value = value;

                    return position;
                }

                try walk.scalar_write(record, range);
                try walk.finish(range, .leaf, value, position + 1);
            },
        }

        walk.stop_next_settle(position);

        const next = position + 1;

        assert(next <= walk.end);

        return next;
    }

    inline fn tail_take_write(walk: *KeptWalk, position: u32) Writer.Error!void {
        assert(!walk.tail_due);
        assert(position < walk.end);

        const range = walk.tail_range;

        if (walk.line_append_is(range, position)) {
            try writer_module.line_append(walk.writer, walk.slots[range.first].text);

            walk.stop_next_settle(position);
        } else {
            try walk.tail_write(position);
        }
    }

    noinline fn tail_write(walk: *KeptWalk, position: u32) Writer.Error!void {
        assert(!walk.tail_due);
        assert(position < walk.end);

        const range = walk.tail_range;
        const next = position + 1;

        if (range.end > range.first) {
            try comment_module.line_write(walk.writer, walk.slots, range, .node);
        }

        try walk.finish(range, .leaf, walk.tail_value, next);

        walk.stop_next_settle(position);

        if (writer_module.quiet_enter(walk.writer) != null) return;

        const flushed = next < walk.end and try walk.pending_flush(next);

        if (!flushed) walk.stop_next = next;
    }

    fn trailing_only_is(walk: *const KeptWalk, record: *const Record, position: u32) bool {
        assert(position < walk.end);
        assert(walk.cursor <= walk.slots.len);

        if (record.kind != .scalar) return false;

        const style: ScalarStyle = @fromBackingInt(@intCast(record.style));
        const block = style == .literal or style == .folded;
        if (block) return false;

        for (walk.slots[walk.cursor..]) |*slot| {
            if (slot.node != position) break;
            if (slot.placement == .head) return false;
        }

        return true;
    }

    inline fn trailing_take(walk: *KeptWalk, record: *const Record, position: u32) bool {
        assert(position < walk.end);
        assert(walk.depth <= writer_depth_max);

        if (walk.depth == 0) return false;
        if (position != walk.stop_next) return false;
        if (record.kind != .scalar) return false;
        if (record.markers.blank_before) return false;
        if (walk.frames[walk.depth - 1].end == position) return false;

        const slots = walk.slots;
        const cursor = walk.cursor;
        if (cursor == slots.len) return false;
        if (slots[cursor].node != position) return false;
        if (slots[cursor].placement != .line) return false;

        const single = cursor + 1 == slots.len or slots[cursor + 1].node != position;
        const style: ScalarStyle = @fromBackingInt(@intCast(record.style));
        const block = style == .literal or style == .folded;
        const writer = walk.writer;

        if (!single) return false;
        if (block) return false;
        if (writer_module.quiet_enter(writer) == null) return false;

        walk.cursor = cursor + 1;
        walk.tail_range = .{ .end = cursor + 1, .first = cursor };

        walk.tail_value = walk.frames[walk.depth - 1].mapping and
            writer.frames[writer.depth - 1].value_next;

        return true;
    }
};

fn collection_end_write(comptime Emitter: type, writer: *Emitter, mapping: bool) Writer.Error!void {
    assert(writer.depth > 0);
    assert(writer.depth <= writer_depth_max);

    if (mapping) {
        try writer.mapping_end();
    } else {
        try writer.sequence_end();
    }
}

pub fn DocumentType(comptime capacity: Capacity) type {
    comptime assert(capacity.node_count_max > 0);
    comptime assert(capacity.text_bytes_max > 0);

    return struct {
        document: Document,
        storage: storage_module.StorageType(capacity),

        const Fixed = @This();

        pub fn parse(
            fixed: *Fixed,
            source: []const u8,
            options: Document.Options,
        ) Document.Error!void {
            comptime assert(@sizeOf(@TypeOf(options)) <= 16);
            assert(source.len <= scanner_module.source_bytes_max);
            assert(fixed.storage.nodes.len == capacity.node_count_max);

            return fixed.document.parse(fixed.storage.storage(), source, options);
        }

        pub fn diagnostic(fixed: *const Fixed) Position {
            assert(fixed.document.node_count <= capacity.node_count_max);
            assert(fixed.document.document_count <= capacity.node_count_max);

            return fixed.document.diagnostic;
        }

        pub fn root_count(fixed: *const Fixed) u32 {
            assert(fixed.document.document_count <= capacity.node_count_max);
            assert(fixed.document.composer.frame_count == 0);

            return fixed.document.root_count();
        }

        pub fn comments(fixed: *const Fixed, node: Node) Comments {
            assert(@backingInt(node) < fixed.document.node_count);
            assert(fixed.document.comment_count <= fixed.storage.comments.len);

            return fixed.document.comments(node);
        }

        pub fn root(fixed: *const Fixed, index: u32) Node {
            assert(index < fixed.document.document_count);
            assert(fixed.document.document_count <= capacity.node_count_max);

            return fixed.document.root(index);
        }

        pub fn kind_of(fixed: *const Fixed, node: Node) Kind {
            assert(@backingInt(node) < fixed.document.node_count);
            assert(fixed.document.node_count <= capacity.node_count_max);

            return fixed.document.kind_of(node);
        }

        pub fn text_of(fixed: *const Fixed, node: Node) ?[]const u8 {
            assert(@backingInt(node) < fixed.document.node_count);
            assert(fixed.document.node_count <= capacity.node_count_max);

            return fixed.document.text_of(node);
        }

        pub fn style_of(fixed: *const Fixed, node: Node) Style {
            assert(@backingInt(node) < fixed.document.node_count);
            assert(fixed.document.node_count <= capacity.node_count_max);

            return fixed.document.style_of(node);
        }

        pub fn tag_of(fixed: *const Fixed, node: Node) []const u8 {
            assert(@backingInt(node) < fixed.document.node_count);
            assert(fixed.document.node_count <= capacity.node_count_max);

            return fixed.document.tag_of(node);
        }

        pub fn anchor_of(fixed: *const Fixed, node: Node) []const u8 {
            assert(@backingInt(node) < fixed.document.node_count);
            assert(fixed.document.node_count <= capacity.node_count_max);

            return fixed.document.anchor_of(node);
        }

        pub fn position_of(fixed: *const Fixed, node: Node) Position {
            assert(@backingInt(node) < fixed.document.node_count);
            assert(fixed.document.node_count <= capacity.node_count_max);

            return fixed.document.position_of(node);
        }

        pub fn count_of(fixed: *const Fixed, node: Node) u32 {
            assert(@backingInt(node) < fixed.document.node_count);
            assert(fixed.document.node_count <= capacity.node_count_max);

            return fixed.document.count_of(node);
        }

        pub fn entries(fixed: *const Fixed, mapping: Node) Entries {
            assert(@backingInt(mapping) < fixed.document.node_count);
            assert(fixed.document.node_count <= capacity.node_count_max);

            return fixed.document.entries(mapping);
        }

        pub fn items(fixed: *const Fixed, sequence: Node) Items {
            assert(@backingInt(sequence) < fixed.document.node_count);
            assert(fixed.document.node_count <= capacity.node_count_max);

            return fixed.document.items(sequence);
        }

        pub fn member(fixed: *const Fixed, mapping: Node, key: []const u8) ?Node {
            assert(@backingInt(mapping) < fixed.document.node_count);
            assert(key.len <= scanner_module.source_bytes_max);

            return fixed.document.member(mapping, key);
        }

        pub fn item(fixed: *const Fixed, sequence: Node, index: u32) ?Node {
            assert(@backingInt(sequence) < fixed.document.node_count);
            assert(index < scanner_module.source_bytes_max);

            return fixed.document.item(sequence, index);
        }

        pub fn path_find(fixed: *const Fixed, start: Node, segments: []const []const u8) ?Node {
            assert(@backingInt(start) < fixed.document.node_count);
            assert(segments.len <= scanner_module.source_bytes_max);

            return fixed.document.path_find(start, segments);
        }

        pub fn write(
            fixed: *const Fixed,
            sink: *std.Io.Writer,
            options: Writer.Options,
        ) std.Io.Writer.Error!void {
            comptime assert(@sizeOf(@TypeOf(options)) <= 16);
            assert(options.indent >= 1);
            assert(fixed.document.document_count <= capacity.node_count_max);

            return fixed.document.write(sink, options);
        }

        pub fn write_json(
            fixed: *const Fixed,
            sink: *std.Io.Writer,
            options: JSONOptions,
        ) JSONOptions.Error!void {
            comptime assert(@sizeOf(@TypeOf(options)) <= 16);
            assert(options.node_count_max > 0);
            assert(fixed.document.document_count <= capacity.node_count_max);

            return fixed.document.write_json(sink, options);
        }

        pub fn null_is(fixed: *const Fixed, node: Node) bool {
            assert(@backingInt(node) < fixed.document.node_count);
            assert(fixed.document.node_count <= capacity.node_count_max);

            return fixed.document.null_is(node);
        }

        pub fn boolean_of(fixed: *const Fixed, node: Node) ?bool {
            assert(@backingInt(node) < fixed.document.node_count);
            assert(fixed.document.node_count <= capacity.node_count_max);

            return fixed.document.boolean_of(node);
        }

        pub fn integer_of(fixed: *const Fixed, node: Node) ?i64 {
            assert(@backingInt(node) < fixed.document.node_count);
            assert(fixed.document.node_count <= capacity.node_count_max);

            return fixed.document.integer_of(node);
        }

        pub fn float_of(fixed: *const Fixed, node: Node) ?f64 {
            assert(@backingInt(node) < fixed.document.node_count);
            assert(fixed.document.node_count <= capacity.node_count_max);

            return fixed.document.float_of(node);
        }
    };
}

const test_capacity: Capacity = .{
    .anchor_count_max = 16,
    .comment_count_max = null,
    .node_count_max = 256,
    .text_bytes_max = 4096,
};

test DocumentType {
    const TestDocument = DocumentType(test_capacity);
    const document = try std.testing.allocator.create(TestDocument);
    defer std.testing.allocator.destroy(document);

    try document.parse("server:\n  name: warbler\n  ports: [8080, 8443]\n", .{ .schema = .core });

    const root = document.root(0);
    const server = document.member(root, "server") orelse return error.ServerMissing;
    const name = document.member(server, "name") orelse return error.NameMissing;
    const path = [_][]const u8{ "server", "ports" };
    const ports = document.path_find(root, &path) orelse return error.PortsMissing;
    const second = document.item(ports, 1) orelse return error.PortMissing;
    const indexed = [_][]const u8{ "server", "ports", "0" };
    const first = document.path_find(root, &indexed) orelse return error.PortMissing;

    try std.testing.expectEqualStrings("warbler", document.text_of(name).?);
    try std.testing.expectEqual(@as(?[]const u8, null), document.text_of(server));
    try std.testing.expectEqual(@as(u32, 2), document.count_of(ports));
    try std.testing.expectEqual(@as(?i64, 8443), document.integer_of(second));
    try std.testing.expectEqual(@as(?i64, 8080), document.integer_of(first));
    try std.testing.expectEqual(@as(?Node, null), document.item(ports, 2));
    try std.testing.expectEqual(@as(?Node, null), document.path_find(root, &.{ "server", "host" }));

    var buffer: [128]u8 = undefined;
    var sink: std.Io.Writer = .fixed(&buffer);

    try document.write(&sink, .{
        .indent = 2,
        .layout = .block,
        .sequence_indentless = true,
        .utf8 = .checked,
        .version_directive = false,
        .width = 0,
    });

    const written = "server:\n  name: warbler\n  ports:\n  - 8080\n  - 8443\n";

    try std.testing.expectEqualStrings(written, sink.buffered());

    sink = .fixed(&buffer);

    try document.write_json(&sink, .{
        .merge = .ignored,
        .node_count_max = 64,
        .non_finite = .refused,
    });

    const json = "{\"server\":{\"name\":\"warbler\",\"ports\":[8080,8443]}}\n";

    try std.testing.expectEqualStrings(json, sink.buffered());

    const refused = document.parse("a: b\nc: d: e\n", .{ .schema = .core });
    const failure: Position = .{ .column = 5, .line = 2, .offset = 9 };

    try std.testing.expectError(error.ValueInvalid, refused);
    try std.testing.expectEqual(failure, document.diagnostic());
}

test Document {
    const TestStorage = storage_module.StorageType(test_capacity);
    const storage = try std.testing.allocator.create(TestStorage);
    defer std.testing.allocator.destroy(storage);

    const document = try std.testing.allocator.create(Document);
    defer std.testing.allocator.destroy(document);

    try document.parse(storage.storage(), "totals:\n  daily: [1, 2, 3]\n", .{ .schema = .core });

    const root = document.root(0);
    const path = [_][]const u8{ "totals", "daily" };
    const daily = document.path_find(root, &path) orelse return error.DailyMissing;
    const indexed = [_][]const u8{ "totals", "daily", "2" };
    const last = document.path_find(root, &indexed) orelse return error.LastMissing;

    try std.testing.expectEqual(Kind.sequence, document.kind_of(daily));
    try std.testing.expectEqual(@as(u32, 3), document.count_of(daily));
    try std.testing.expectEqual(@as(?Node, null), document.path_find(daily, &.{"totals"}));
    try std.testing.expectEqual(@as(?Node, null), document.path_find(daily, &.{"03"}));
    try std.testing.expectEqual(document.item(daily, 2), last);
    try std.testing.expectEqual(@as(?[]const u8, null), document.text_of(daily));

    var items = document.items(daily);
    var total: i64 = 0;

    for (0..document.count_of(daily)) |_| {
        const item = items.next() orelse break;

        total += document.integer_of(item) orelse return error.ItemInvalid;
    }

    const after = items.next();

    try std.testing.expectEqual(@as(i64, 6), total);
    try std.testing.expectEqual(@as(?Node, null), after);

    var buffer: [64]u8 = undefined;
    var sink: std.Io.Writer = .fixed(&buffer);

    try document.write_json(&sink, .{
        .merge = .ignored,
        .node_count_max = 16,
        .non_finite = .refused,
    });

    try std.testing.expectEqualStrings("{\"totals\":{\"daily\":[1,2,3]}}\n", sink.buffered());
}
