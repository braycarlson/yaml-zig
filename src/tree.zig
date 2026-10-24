const std = @import("std");

const codec = @import("codec.zig");
const comment_module = @import("comment.zig");
const document_module = @import("document.zig");
const json_writer = @import("json_writer.zig");
const merge = @import("merge.zig");
const parser_module = @import("parser.zig");
const scanner_module = @import("scanner.zig");
const schema_module = @import("schema.zig");
const storage_module = @import("storage.zig");
const writer_module = @import("writer.zig");

const assert = std.debug.assert;

const Capacity = storage_module.Capacity;
const CollectionStyle = parser_module.CollectionStyle;
const Comment = comment_module.Comment;
const CommentSlot = storage_module.CommentSlot;
const Comments = comment_module.Comments;
const CommentRange = comment_module.Range;
const Document = document_module.Document;
const DocumentNode = document_module.Node;
const DocumentRecord = storage_module.Record;
const Event = parser_module.Event;
const JSONOptions = json_writer.JSONOptions;
const Merge = merge.Merge;
const Position = parser_module.Position;
const ScalarStyle = parser_module.ScalarStyle;
const Schema = schema_module.Schema;
const Style = document_module.Style;
const Writer = writer_module.Writer;

const anchor_count_limit: u32 = 1 << 30;
const depth_max: u32 = scanner_module.depth_max;
const none: u32 = std.math.maxInt(u32);
const node_count_limit: u32 = 1 << 31;
const position_none = parser_module.position_none;
const source_bytes_max: u32 = scanner_module.source_bytes_max;
const stream_index: u32 = 0;
const text_empty: Text = .{ .length = 0, .offset = 0 };

comptime {
    assert(@sizeOf(Record) == 48);
    assert(@sizeOf(AnchorSlot) == 12);
    assert(node_count_limit < none);
    assert(depth_max == 256);
}

pub const Tree = struct {
    anchor_count: u32,
    anchors: []AnchorSlot,
    comment_count: u32,
    comment_slots: []CommentSlot,
    diagnostic: Position,
    node_count: u32,
    records: []Record,
    schema: Schema,
    text: []u8,
    text_count: u32,

    pub const CapacityError = error{
        AnchorsExhausted,
        CommentsExhausted,
        DepthExceeded,
        MergesExceeded,
        NodesExhausted,
        TextExhausted,
    };

    pub const Content = union(enum) {
        alias: Node,
        boolean: bool,
        copy: Copy,
        float: f64,
        integer: i64,
        mapping: Event.CollectionStart,
        null_value,
        scalar: Event.Scalar,
        sequence: Event.CollectionStart,
        string: []const u8,

        pub const Copy = struct {
            document: *const Document,
            merge: Merge = .ignored,
            node: DocumentNode,
        };
    };

    pub const EditError = CapacityError || ValueError;

    pub const Entries = struct {
        cursor: u32,
        remaining: u32,
        tree: *const Tree,

        pub const Entry = struct {
            key: Node,
            value: Node,
        };

        pub fn next(iterator: *Entries) ?Entry {
            assert(iterator.remaining < iterator.tree.node_count);
            if (iterator.remaining > 0) assert(iterator.cursor < iterator.tree.node_count);

            if (iterator.remaining == 0) return null;

            const records = iterator.tree.records;
            const key = iterator.cursor;
            const value = records[key].next;

            iterator.cursor = records[value].next;
            iterator.remaining -= 1;

            assert(records[key].flags.key);
            assert(!records[value].flags.key);

            return .{ .key = @fromBackingInt(key), .value = @fromBackingInt(value) };
        }
    };

    pub const Items = struct {
        cursor: u32,
        remaining: u32,
        tree: *const Tree,

        pub fn next(iterator: *Items) ?Node {
            assert(iterator.remaining < iterator.tree.node_count);
            if (iterator.remaining > 0) assert(iterator.cursor < iterator.tree.node_count);

            if (iterator.remaining == 0) return null;

            const result = iterator.cursor;

            iterator.cursor = iterator.tree.records[result].next;
            iterator.remaining -= 1;

            assert(!iterator.tree.records[result].flags.key);

            return @fromBackingInt(result);
        }
    };

    pub const Kind = document_module.Kind;

    pub const Node = enum(u32) { _ };

    pub const Options = struct {
        schema: Schema = .core,
    };

    pub const RemoveError = error{AnchorReferenced};

    pub const Storage = struct {
        anchors: []AnchorSlot,
        comments: []CommentSlot,
        records: []Record,
        text: []u8,

        pub fn init(gpa: std.mem.Allocator, capacity: Capacity) std.mem.Allocator.Error!Storage {
            assert(capacity.node_count_max > 0);
            assert(capacity.node_count_max <= node_count_limit);
            assert(capacity.anchor_count_max > 0);
            assert(capacity.anchor_count_max <= anchor_count_limit);

            const slot_count = anchor_slot_count_of(capacity.anchor_count_max);
            const anchors = try gpa.alloc(AnchorSlot, slot_count);
            errdefer gpa.free(anchors);

            const slots = try gpa.alloc(CommentSlot, capacity.comment_count_max orelse 0);
            errdefer gpa.free(slots);

            const records = try gpa.alloc(Record, capacity.node_count_max);
            errdefer gpa.free(records);

            const text = try gpa.alloc(u8, capacity.text_bytes_max);
            return .{ .anchors = anchors, .comments = slots, .records = records, .text = text };
        }

        pub fn deinit(storage: *Storage, gpa: std.mem.Allocator) void {
            assert(storage.records.len > 0);
            assert(std.math.isPowerOfTwo(storage.anchors.len));

            gpa.free(storage.anchors);
            gpa.free(storage.comments);
            gpa.free(storage.records);
            gpa.free(storage.text);

            storage.* = undefined;
        }
    };

    pub const ValueError = error{
        AliasInvalid,
        AnchorDuplicate,
        AnchorReferenced,
        MergeInvalid,
        TextInvalid,
    };

    pub fn StorageType(comptime capacity: Capacity) type {
        comptime assert(capacity.node_count_max > 0);
        comptime assert(capacity.node_count_max <= node_count_limit);
        comptime assert(capacity.anchor_count_max > 0);
        comptime assert(capacity.anchor_count_max <= anchor_count_limit);

        const slot_count = comptime anchor_slot_count_of(capacity.anchor_count_max);

        return struct {
            anchors: [slot_count]AnchorSlot,
            comments: [capacity.comment_count_max orelse 0]CommentSlot,
            records: [capacity.node_count_max]Record,
            text: [capacity.text_bytes_max]u8,

            const Fixed = @This();

            pub fn storage(fixed: *Fixed) Storage {
                assert(fixed.records.len == capacity.node_count_max);
                assert(std.math.isPowerOfTwo(fixed.anchors.len));

                return .{
                    .anchors = &fixed.anchors,
                    .comments = &fixed.comments,
                    .records = &fixed.records,
                    .text = &fixed.text,
                };
            }
        };
    }

    pub fn init(tree: *Tree, storage: Storage, options: Options) void {
        comptime assert(@sizeOf(@TypeOf(options)) <= 16);
        assert(storage.records.len > 0);
        assert(storage.records.len <= node_count_limit);
        assert(storage.anchors.len >= 2);
        assert(std.math.isPowerOfTwo(storage.anchors.len));

        tree.* = .{
            .anchor_count = 0,
            .anchors = storage.anchors,
            .comment_count = 0,
            .comment_slots = storage.comments,
            .diagnostic = position_none,
            .node_count = 1,
            .records = storage.records,
            .schema = options.schema,
            .text = storage.text,
            .text_count = 0,
        };

        @memset(tree.anchors, .{ .hash = 0, .home = none, .root = none });

        tree.records[stream_index] = .{
            .anchor = text_empty,
            .count = 0,
            .first = none,
            .flags = .{},
            .kind = .stream,
            .last = none,
            .next = none,
            .parent = none,
            .style = 0,
            .tag = text_empty,
            .text = text_empty,
        };

        assert(tree.root_count() == 0);
    }

    pub fn root_count(tree: *const Tree) u32 {
        assert(tree.node_count > 0);
        assert(tree.records[stream_index].kind == .stream);

        return tree.records[stream_index].count;
    }

    pub fn root(tree: *const Tree, index: u32) Node {
        assert(index < tree.root_count());
        assert(tree.records[stream_index].last != none);

        const result = tree.child_at(&tree.records[stream_index], index);

        assert(tree.records[result].parent == stream_index);

        return @fromBackingInt(result);
    }

    pub fn comments(tree: *const Tree, node: Node) Comments {
        assert(@backingInt(node) < tree.node_count);
        assert(tree.comment_count <= tree.comment_slots.len);

        const index = @backingInt(node);
        const slots = tree.comment_slots[0..tree.comment_count];
        const blank = tree.records[index].flags.blank_before;
        if (slots.len == 0) return comment_module.comments_of(slots, CommentRange.empty, blank);
        return comment_module.comments_of(slots, comment_module.range_of(slots, index), blank);
    }

    pub fn comment_set(
        tree: *Tree,
        node: Node,
        placement: Comment.Placement,
        text: []const u8,
    ) EditError!void {
        assert(@backingInt(node) < tree.node_count);
        assert(@backingInt(node) != stream_index);
        assert(@backingInt(placement) <= 2);
        assert(text.len <= source_bytes_max);

        tree.diagnostic = position_none;

        const index = @backingInt(node);

        assert(!tree.records[index].flags.detached);

        if (text.len > 0) {
            _ = comment_module.lines_check(placement, text) catch return error.TextInvalid;
        }

        const plan = comment_plan_of(placement, text);
        const range = comment_module.range_of(tree.comment_slots[0..tree.comment_count], index);
        const old = placement_range_of(tree.comment_slots[0..tree.comment_count], range, placement);
        const kept = tree.comment_count - (old.end - old.first);
        if (plan.slot_count > tree.comment_slots.len - kept) return error.CommentsExhausted;

        try tree.text_room_check(plan.text_bytes);

        tree.comments_splice(old, plan.slot_count);
        tree.comment_fill(index, .{ .placement = placement, .text = text }, old);

        const heads_set = placement == .head and text.len > 0;

        if (heads_set) tree.records[index].flags.blank_before = plan.tail;

        assert(tree.comment_count == kept + plan.slot_count);
    }

    fn comments_splice(tree: *Tree, old: CommentRange, count: u32) void {
        assert(old.first <= old.end);
        assert(old.end <= tree.comment_count);
        assert(count <= tree.comment_slots.len);

        const removed = old.end - old.first;
        const total = tree.comment_count - removed + count;
        const tail = tree.comment_count - old.end;

        assert(total <= tree.comment_slots.len);

        const tail_moves = count != removed and tail > 0;

        if (tail_moves) {
            const source = tree.comment_slots[old.end..][0..tail];
            const target = tree.comment_slots[old.first + count ..][0..tail];

            if (count < removed) {
                std.mem.copyForwards(CommentSlot, target, source);
            } else {
                std.mem.copyBackwards(CommentSlot, target, source);
            }
        }

        tree.comment_count = total;
    }

    fn comment_fill(tree: *Tree, index: u32, comment: Comment, old: CommentRange) void {
        assert(index < tree.node_count);
        assert(old.first <= tree.comment_count);
        assert(comment.text.len <= source_bytes_max);

        const placement = comment.placement;
        const text = comment.text;
        var slot_index = old.first;
        var blank = false;
        var start: u32 = 0;

        if (text.len == 0) return;

        for (0..text.len + 1) |_| {
            const end: u32 = @intCast(std.mem.findScalarPos(u8, text, start, '\n') orelse text.len);

            if (end == start) {
                blank = true;
            } else {
                const stored = tree.text_at(tree.text_append(text[start..end]));

                tree.comment_slots[slot_index] = comment_slot_of(index, placement, stored, blank);
                slot_index += 1;
                blank = false;
            }

            if (end == text.len) break;

            start = end + 1;
        }

        const foot_blank = blank and placement == .foot;

        if (foot_blank) {
            tree.comment_slots[slot_index] = comment_slot_of(index, placement, "", false);
            slot_index += 1;
        }

        assert(slot_index <= tree.comment_count);
    }

    fn comments_prune(tree: *Tree) void {
        assert(tree.comment_count <= tree.comment_slots.len);
        assert(tree.node_count <= tree.records.len);

        var kept: u32 = 0;

        for (tree.comment_slots[0..tree.comment_count]) |slot| {
            if (tree.records[slot.node].flags.detached) continue;

            tree.comment_slots[kept] = slot;
            kept += 1;
        }

        tree.comment_count = kept;
    }

    pub fn kind_of(tree: *const Tree, node: Node) Kind {
        assert(@backingInt(node) < tree.node_count);
        assert(@backingInt(node) != stream_index);

        return switch (tree.record_of(node).kind) {
            .alias, .stream => unreachable,
            .mapping => .mapping,
            .scalar => .scalar,
            .sequence => .sequence,
        };
    }

    pub fn text_of(tree: *const Tree, node: Node) ?[]const u8 {
        assert(@backingInt(node) < tree.node_count);
        assert(tree.node_count <= tree.records.len);

        const record = tree.record_of(node);
        if (record.kind != .scalar) return null;
        return tree.text_at(record.text);
    }

    pub fn style_of(tree: *const Tree, node: Node) Style {
        assert(@backingInt(node) < tree.node_count);
        assert(@backingInt(node) != stream_index);

        const record = tree.record_of(node);

        return switch (record.kind) {
            .alias, .stream => unreachable,
            .mapping => .{ .mapping = @fromBackingInt(@intCast(record.style)) },
            .scalar => .{ .scalar = @fromBackingInt(@intCast(record.style)) },
            .sequence => .{ .sequence = @fromBackingInt(@intCast(record.style)) },
        };
    }

    pub fn tag_of(tree: *const Tree, node: Node) []const u8 {
        assert(@backingInt(node) < tree.node_count);
        assert(@backingInt(node) != stream_index);

        return tree.text_at(tree.record_of(node).tag);
    }

    pub fn anchor_of(tree: *const Tree, node: Node) []const u8 {
        assert(@backingInt(node) < tree.node_count);
        assert(@backingInt(node) != stream_index);

        return tree.text_at(tree.record_of(node).anchor);
    }

    pub fn alias_of(tree: *const Tree, node: Node) ?Node {
        assert(@backingInt(node) < tree.node_count);
        assert(@backingInt(node) != stream_index);

        const record = &tree.records[@backingInt(node)];

        assert(!record.flags.detached);

        if (record.kind != .alias) return null;

        assert(anchored_is(&tree.records[record.last]));

        return @fromBackingInt(record.last);
    }

    pub fn count_of(tree: *const Tree, node: Node) u32 {
        assert(@backingInt(node) < tree.node_count);
        assert(@backingInt(node) != stream_index);

        const record = tree.record_of(node);

        const result = switch (record.kind) {
            .alias, .stream => unreachable,
            .mapping, .sequence => record.count,
            .scalar => 0,
        };

        assert(result < tree.node_count);

        return result;
    }

    pub fn entries(tree: *const Tree, mapping: Node) Entries {
        assert(@backingInt(mapping) < tree.node_count);
        assert(@backingInt(mapping) != stream_index);

        const record = tree.record_of(mapping);
        if (record.kind != .mapping) return .{ .cursor = none, .remaining = 0, .tree = tree };
        if (record.count == 0) return .{ .cursor = none, .remaining = 0, .tree = tree };

        return .{
            .cursor = record.first,
            .remaining = record.count,
            .tree = tree,
        };
    }

    pub fn items(tree: *const Tree, sequence: Node) Items {
        assert(@backingInt(sequence) < tree.node_count);
        assert(@backingInt(sequence) != stream_index);

        const record = tree.record_of(sequence);
        if (record.kind != .sequence) return .{ .cursor = none, .remaining = 0, .tree = tree };
        if (record.count == 0) return .{ .cursor = none, .remaining = 0, .tree = tree };

        return .{
            .cursor = record.first,
            .remaining = record.count,
            .tree = tree,
        };
    }

    pub fn member(tree: *const Tree, mapping: Node, key: []const u8) ?Node {
        assert(@backingInt(mapping) < tree.node_count);
        assert(key.len <= source_bytes_max);

        var iterator = tree.entries(mapping);

        for (0..iterator.remaining) |_| {
            const entry = iterator.next() orelse break;
            if (tree.key_text_is(entry.key, key)) return entry.value;
        }

        return null;
    }

    pub fn item(tree: *const Tree, sequence: Node, index: u32) ?Node {
        assert(@backingInt(sequence) < tree.node_count);
        assert(index < source_bytes_max);

        const record = tree.record_of(sequence);
        if (record.kind != .sequence) return null;
        if (record.count <= index) return null;

        const result = tree.child_at(record, index);

        assert(tree.records[result].parent == tree.resolved_index(@backingInt(sequence)));

        return @fromBackingInt(result);
    }

    pub fn path_find(tree: *const Tree, start: Node, segments: []const []const u8) ?Node {
        assert(@backingInt(start) < tree.node_count);
        assert(segments.len <= source_bytes_max);

        var node = start;

        for (segments) |segment| {
            node = tree.step_find(node, segment) orelse return null;
        }

        return node;
    }

    pub fn null_is(tree: *const Tree, node: Node) bool {
        assert(@backingInt(node) < tree.node_count);
        assert(@backingInt(node) != stream_index);

        const text = tree.core_text_of(node, schema_module.tag_null) orelse return false;
        return schema_module.null_text_is(text, tree.schema);
    }

    pub fn boolean_of(tree: *const Tree, node: Node) ?bool {
        assert(@backingInt(node) < tree.node_count);
        assert(@backingInt(node) != stream_index);

        const text = tree.core_text_of(node, schema_module.tag_boolean) orelse return null;
        return schema_module.boolean_text_of(text, tree.schema);
    }

    pub fn integer_of(tree: *const Tree, node: Node) ?i64 {
        assert(@backingInt(node) < tree.node_count);
        assert(@backingInt(node) != stream_index);

        const text = tree.core_text_of(node, schema_module.tag_integer) orelse return null;
        return schema_module.integer_text_of(i64, text, tree.schema);
    }

    pub fn float_of(tree: *const Tree, node: Node) ?f64 {
        assert(@backingInt(node) < tree.node_count);
        assert(@backingInt(node) != stream_index);

        const text = tree.core_text_of(node, schema_module.tag_float) orelse return null;

        if (schema_module.integer_text_of(i64, text, tree.schema)) |integer| {
            const result: f64 = @floatFromInt(integer);

            assert(@abs(result) <= 0x1p63);

            return result;
        }

        return schema_module.float_text_of(text, tree.schema);
    }

    pub fn root_append(tree: *Tree, content: Content) EditError!Node {
        assert(tree.node_count <= tree.records.len);
        assert(content_bytes(&content) <= source_bytes_max);

        tree.diagnostic = position_none;

        const placement: Placement = .{
            .document = tree.node_count,
            .key = null,
            .level = 0,
            .slot = .{ .parent = stream_index, .sibling = .end },
        };

        const value = try tree.value_create(&placement, &content);

        assert(value == placement.document);

        tree.segment_append(stream_index, .{ .first = value, .last = value });

        return @fromBackingInt(value);
    }

    pub fn set(tree: *Tree, mapping: Node, key: []const u8, content: Content) EditError!Node {
        assert(@backingInt(mapping) < tree.node_count);
        assert(key.len <= source_bytes_max);
        assert(content_bytes(&content) <= source_bytes_max);

        tree.diagnostic = position_none;

        const container = tree.resolved_index(@backingInt(mapping));

        assert(tree.records[container].kind == .mapping);

        if (!std.unicode.utf8ValidateSlice(key)) return error.TextInvalid;

        if (tree.member(@fromBackingInt(container), key)) |value| {
            try tree.replace(value, content);

            return value;
        }

        const placement: Placement = .{
            .document = tree.document_of(container),
            .key = key,
            .level = tree.level_of(container),
            .slot = .{ .parent = container, .sibling = .end },
        };

        const value = try tree.value_create(&placement, &content);

        tree.records[value - 1].next = value;
        tree.segment_append(container, .{ .first = value - 1, .last = value });

        assert(tree.records[value - 1].flags.key);
        assert(tree.records[container].last == value);

        return @fromBackingInt(value);
    }

    pub fn append(tree: *Tree, sequence: Node, content: Content) EditError!Node {
        assert(@backingInt(sequence) < tree.node_count);
        assert(content_bytes(&content) <= source_bytes_max);

        tree.diagnostic = position_none;

        const count = tree.count_of(sequence);
        const value = try tree.item_create(sequence, count, &content);

        return @fromBackingInt(value);
    }

    pub fn insert(tree: *Tree, sequence: Node, index: u32, content: Content) EditError!Node {
        assert(@backingInt(sequence) < tree.node_count);
        assert(index <= tree.count_of(sequence));
        assert(content_bytes(&content) <= source_bytes_max);

        tree.diagnostic = position_none;

        const value = try tree.item_create(sequence, index, &content);
        return @fromBackingInt(value);
    }

    pub fn replace(tree: *Tree, node: Node, content: Content) EditError!void {
        assert(@backingInt(node) < tree.node_count);
        assert(@backingInt(node) != stream_index);
        assert(content_bytes(&content) <= source_bytes_max);

        tree.diagnostic = position_none;

        const index = @backingInt(node);
        const record = &tree.records[index];

        assert(!record.flags.detached);
        assert(!record.flags.key);

        if (tree.referenced_is(.{ .first = index, .last = index })) return error.AnchorReferenced;

        const placement: Placement = .{
            .document = tree.document_of(index),
            .key = null,
            .level = tree.level_of(record.parent),
            .slot = .{ .parent = record.parent, .sibling = .{ .at = index } },
        };

        switch (content) {
            .copy => |*copy| try tree.copy_replace(index, &placement, copy),
            .alias,
            .boolean,
            .float,
            .integer,
            .mapping,
            .null_value,
            .scalar,
            .sequence,
            .string,
            => try tree.piece_replace(index, &placement, &content),
        }

        if (tree.comment_count > 0) tree.comments_prune();

        assert(!tree.records[index].flags.detached);
    }

    pub fn remove(tree: *Tree, node: Node) RemoveError!void {
        assert(@backingInt(node) < tree.node_count);
        assert(@backingInt(node) != stream_index);

        tree.diagnostic = position_none;

        const index = @backingInt(node);

        assert(!tree.records[index].flags.detached);

        const document = tree.document_of(index);
        const segment = tree.segment_find(index);
        if (tree.referenced_is(segment)) return error.AnchorReferenced;

        tree.segment_unlink(segment);
        tree.subtree_detach(.{ .document = document, .index = segment.first });

        if (segment.last != segment.first) {
            tree.subtree_detach(.{ .document = document, .index = segment.last });
        }

        if (tree.comment_count > 0) tree.comments_prune();

        assert(tree.records[index].flags.detached);
    }

    pub fn write(
        tree: *const Tree,
        sink: *std.Io.Writer,
        options: Writer.Options,
    ) std.Io.Writer.Error!void {
        comptime assert(@sizeOf(@TypeOf(options)) <= 16);
        assert(options.indent >= 1);
        assert(tree.node_count > 0);

        var trusted = options;
        var writer: Writer = undefined;

        trusted.utf8 = .trusted;

        writer.init(sink, trusted);

        const stream = &tree.records[stream_index];
        const kept = tree.comment_count > 0 or tree.blanks_any();
        var cursor = stream.first;

        if (stream.count == 0) assert(tree.comment_count == 0);

        for (0..stream.count) |_| {
            tree.document_write(&writer, cursor, kept) catch |err| switch (err) {
                error.DepthExceeded,
                error.EnumerationUnrecognized,
                error.TextInvalid,
                => unreachable,
                error.WriteFailed => |failed| return failed,
            };

            cursor = tree.records[cursor].next;
        }

        writer.finish();
    }

    pub fn write_json(
        tree: *const Tree,
        sink: *std.Io.Writer,
        options: JSONOptions,
    ) JSONOptions.Error!void {
        comptime assert(@sizeOf(@TypeOf(options)) <= 16);
        assert(options.node_count_max > 0);
        assert(tree.node_count > 0);

        const counted = try json_writer.json_write(Tree, .count, tree, sink, &options);

        const emitted = json_writer.json_write(
            Tree,
            .emit,
            tree,
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

    fn item_create(
        tree: *Tree,
        sequence: Node,
        index: u32,
        content: *const Content,
    ) EditError!u32 {
        assert(@backingInt(sequence) < tree.node_count);
        assert(content_bytes(content) <= source_bytes_max);

        const container = tree.resolved_index(@backingInt(sequence));
        const record = &tree.records[container];

        assert(record.kind == .sequence);
        assert(index <= record.count);

        const end = index == record.count;
        const sibling: Sibling = if (end) .end else .{ .before = tree.child_at(record, index) };

        const placement: Placement = .{
            .document = tree.document_of(container),
            .key = null,
            .level = tree.level_of(container),
            .slot = .{ .parent = container, .sibling = sibling },
        };

        const value = try tree.value_create(&placement, content);

        if (end) {
            tree.segment_append(container, .{ .first = value, .last = value });
        } else {
            const predecessor = if (index == 0) none else tree.child_at(record, index - 1);

            tree.segment_insert(container, .{
                .first = value,
                .last = value,
                .predecessor = predecessor,
            });
        }

        assert(tree.child_at(record, index) == value);

        return value;
    }

    fn resolved_index(tree: *const Tree, index: u32) u32 {
        assert(index < tree.node_count);
        assert(index != stream_index);

        const record = &tree.records[index];

        assert(!record.flags.detached);

        if (record.kind != .alias) return index;

        const home = record.last;

        assert(home < tree.node_count);
        assert(tree.records[home].kind != .alias);
        assert(!tree.records[home].flags.detached);

        return home;
    }

    fn record_of(tree: *const Tree, node: Node) *const Record {
        assert(@backingInt(node) < tree.node_count);
        assert(tree.node_count <= tree.records.len);

        const result = &tree.records[tree.resolved_index(@backingInt(node))];

        assert(result.kind != .alias);

        return result;
    }

    fn text_at(tree: *const Tree, text: Text) []const u8 {
        assert(text.offset <= tree.text_count);
        assert(text.length <= tree.text_count - text.offset);

        return tree.text[text.offset..][0..text.length];
    }

    fn key_text_is(tree: *const Tree, key: Node, text: []const u8) bool {
        assert(@backingInt(key) < tree.node_count);
        assert(text.len <= source_bytes_max);

        const record = tree.record_of(key);
        if (record.kind != .scalar) return false;
        if (record.text.length != text.len) return false;
        return std.mem.eql(u8, tree.text_at(record.text), text);
    }

    fn core_text_of(tree: *const Tree, node: Node, tag: []const u8) ?[]const u8 {
        assert(@backingInt(node) < tree.node_count);
        assert(tag.len > 0);

        const record = tree.record_of(node);
        if (record.kind != .scalar) return null;

        const record_tag = tree.text_at(record.tag);
        if (std.mem.eql(u8, record_tag, tag)) return tree.text_at(record.text);
        if (record_tag.len > 0) return null;

        const style: ScalarStyle = @fromBackingInt(@intCast(record.style));
        if (style != .plain) return null;
        return tree.text_at(record.text);
    }

    fn step_find(tree: *const Tree, node: Node, segment: []const u8) ?Node {
        assert(@backingInt(node) < tree.node_count);
        assert(segment.len <= source_bytes_max);

        switch (tree.kind_of(node)) {
            .mapping => return tree.member(node, segment),
            .scalar => return null,
            .sequence => {
                const index = document_module.segment_index_of(segment) orelse return null;
                return tree.item(node, index);
            },
        }
    }

    fn child_at(tree: *const Tree, record: *const Record, position: u32) u32 {
        assert(position < child_count_of(record));
        assert(record.last < tree.node_count);

        if (position + 1 == child_count_of(record)) return record.last;

        var cursor = record.first;

        for (0..position) |_| cursor = tree.records[cursor].next;

        assert(cursor < tree.node_count);

        return cursor;
    }

    fn position_of(tree: *const Tree, child: u32) u32 {
        assert(child < tree.node_count);
        assert(child != stream_index);

        const record = &tree.records[tree.records[child].parent];
        const count = child_count_of(record);
        var cursor = record.first;
        var result: u32 = 0;

        for (0..count) |_| {
            if (cursor == child) break;

            cursor = tree.records[cursor].next;
            result += 1;
        }

        assert(cursor == child);
        assert(result < count);

        return result;
    }

    fn document_of(tree: *const Tree, index: u32) u32 {
        assert(index < tree.node_count);
        assert(index != stream_index);

        var cursor = index;

        for (0..depth_max + 2) |_| {
            const parent = tree.records[cursor].parent;
            if (parent == stream_index) return cursor;

            cursor = parent;
        }

        unreachable;
    }

    fn level_of(tree: *const Tree, index: u32) u32 {
        assert(index < tree.node_count);
        assert(tree.node_count <= tree.records.len);

        var cursor = index;
        var result: u32 = 0;

        for (0..depth_max + 2) |_| {
            if (cursor == stream_index) break;

            result += @intFromBool(container_is(tree.records[cursor].kind));
            cursor = tree.records[cursor].parent;
        }

        assert(cursor == stream_index);
        assert(result <= depth_max);

        return result;
    }

    fn depth_of(tree: *const Tree, index: u32) u32 {
        assert(index < tree.node_count);
        assert(tree.node_count <= tree.records.len);

        var cursor = index;
        var result: u32 = 0;

        for (0..depth_max + 2) |_| {
            if (cursor == stream_index) break;

            result += 1;
            cursor = tree.records[cursor].parent;
        }

        assert(cursor == stream_index);
        assert(result <= depth_max + 1);

        return result;
    }

    fn precedes(tree: *const Tree, home: u32, slot: Slot) bool {
        assert(home < tree.node_count);
        assert(slot.parent < tree.node_count);

        const home_depth = tree.depth_of(home);
        const parent_depth = tree.depth_of(slot.parent);
        var upper: Ascent = .{ .child = none, .node = home };
        var lower: Ascent = .{ .child = none, .node = slot.parent };

        for (0..home_depth -| parent_depth) |_| tree.ascend(&upper);
        for (0..parent_depth -| home_depth) |_| tree.ascend(&lower);

        for (0..depth_max + 2) |_| {
            if (upper.node == lower.node) break;

            tree.ascend(&upper);
            tree.ascend(&lower);
        }

        assert(upper.node == lower.node);

        if (upper.child == none) return false;
        if (upper.node == stream_index) return false;

        const branch = tree.position_of(upper.child);
        if (lower.child != none) return branch < tree.position_of(lower.child);

        return switch (slot.sibling) {
            .at, .before => |child| branch < tree.position_of(child),
            .end => true,
        };
    }

    fn ascend(tree: *const Tree, ascent: *Ascent) void {
        assert(ascent.node < tree.node_count);
        assert(ascent.node != stream_index);

        ascent.child = ascent.node;
        ascent.node = tree.records[ascent.node].parent;
    }

    fn value_create(
        tree: *Tree,
        placement: *const Placement,
        content: *const Content,
    ) EditError!u32 {
        assert(placement.slot.parent < tree.node_count);
        assert(placement.level <= depth_max);

        const value = switch (content.*) {
            .copy => |*copy| try tree.copy_create(placement, copy),
            .alias,
            .boolean,
            .float,
            .integer,
            .mapping,
            .null_value,
            .scalar,
            .sequence,
            .string,
            => try tree.piece_create(placement, content),
        };

        assert(value < tree.node_count);
        assert(tree.records[value].parent == placement.slot.parent);

        return value;
    }

    fn piece_create(
        tree: *Tree,
        placement: *const Placement,
        content: *const Content,
    ) EditError!u32 {
        assert(content.* != .copy);
        assert(placement.slot.sibling != .at);

        var buffer: [codec.float_bytes_max]u8 = undefined;
        var piece = piece_of(content, &buffer);

        piece.home = try tree.piece_check(&piece, placement, content);

        const key = placement.key orelse "";
        const keyed: u32 = @intFromBool(placement.key != null);

        try tree.room_check(.{
            .node_count = keyed + 1,
            .text_bytes = key.len + piece_bytes(&piece),
        });

        if (placement.key != null) tree.key_write(placement.slot.parent, key);

        const value = tree.record_take();
        const record = &tree.records[value];
        const place: Place = .{ .document = placement.document, .index = value };

        record.flags = .{};
        record.next = none;
        record.parent = placement.slot.parent;

        tree.piece_fill(value, &piece);

        if (piece.anchor.len > 0) tree.anchor_insert(place);

        return value;
    }

    fn piece_replace(
        tree: *Tree,
        index: u32,
        placement: *const Placement,
        content: *const Content,
    ) EditError!void {
        assert(index < tree.node_count);
        assert(content.* != .copy);

        var buffer: [codec.float_bytes_max]u8 = undefined;
        var piece = piece_of(content, &buffer);

        piece.home = try tree.piece_check(&piece, placement, content);

        try tree.room_check(.{ .node_count = 0, .text_bytes = piece_bytes(&piece) });

        const place: Place = .{ .document = placement.document, .index = index };

        tree.home_unregister(place);
        tree.children_detach(place);
        tree.piece_fill(index, &piece);

        if (piece.anchor.len > 0) tree.anchor_insert(place);
    }

    fn piece_check(
        tree: *const Tree,
        piece: *const Piece,
        placement: *const Placement,
        content: *const Content,
    ) EditError!u32 {
        assert(piece.kind != .stream);
        assert(placement.level <= depth_max);

        if (!std.unicode.utf8ValidateSlice(piece.text)) return error.TextInvalid;
        if (!std.unicode.utf8ValidateSlice(piece.tag)) return error.TextInvalid;

        const anchored = piece.anchor.len > 0;

        if (anchored) {
            if (!anchor_valid_is(piece.anchor)) return error.TextInvalid;
        }

        const home = switch (content.*) {
            .alias => |target| try tree.alias_home_of(target, placement),
            .boolean,
            .copy,
            .float,
            .integer,
            .mapping,
            .null_value,
            .scalar,
            .sequence,
            .string,
            => none,
        };

        if (anchored) {
            if (tree.anchor_taken_is(placement, piece.anchor)) return error.AnchorDuplicate;
        }

        if (container_is(piece.kind)) {
            if (placement.level == depth_max) return error.DepthExceeded;
        }

        if (anchored) {
            if (!tree.anchor_room_is(placement)) return error.AnchorsExhausted;
        }

        return home;
    }

    fn alias_home_of(
        tree: *const Tree,
        target: Node,
        placement: *const Placement,
    ) ValueError!u32 {
        assert(@backingInt(target) < tree.node_count);
        assert(placement.slot.parent < tree.node_count);

        const home = tree.resolved_index(@backingInt(target));
        if (!anchored_is(&tree.records[home])) return error.AliasInvalid;
        if (!tree.precedes(home, placement.slot)) return error.AliasInvalid;

        assert(tree.document_of(home) == placement.document);

        return home;
    }

    fn anchor_taken_is(tree: *const Tree, placement: *const Placement, name: []const u8) bool {
        assert(name.len > 0);
        assert(placement.document <= tree.records.len);

        const home = tree.anchor_lookup(placement.document, name);
        if (home == none) return false;

        return switch (placement.slot.sibling) {
            .at => |replaced| !tree.inside(home, .{ .first = replaced, .last = replaced }),
            .before, .end => true,
        };
    }

    fn anchor_room_is(tree: *const Tree, placement: *const Placement) bool {
        assert(tree.anchor_count <= anchor_count_max_of(tree));
        assert(placement.level <= depth_max);

        if (tree.anchor_count < anchor_count_max_of(tree)) return true;

        return switch (placement.slot.sibling) {
            .at => |replaced| tree.subtree_anchored(replaced),
            .before, .end => false,
        };
    }

    fn room_check(tree: *const Tree, need: Need) CapacityError!void {
        assert(need.node_count <= 2);
        assert(need.text_bytes <= 4 * @as(u64, source_bytes_max));
        assert(tree.node_count <= tree.records.len);

        if (need.node_count > tree.records.len - tree.node_count) return error.NodesExhausted;
        if (need.text_bytes > tree.text.len - tree.text_count) return error.TextExhausted;
    }

    fn text_room_check(tree: *const Tree, bytes: u64) CapacityError!void {
        assert(tree.text_count <= tree.text.len);
        assert(bytes <= 3 * @as(u64, source_bytes_max));

        if (bytes > tree.text.len - tree.text_count) return error.TextExhausted;
    }

    fn record_reserve(tree: *Tree) CapacityError!u32 {
        assert(tree.node_count <= tree.records.len);
        assert(tree.node_count > 0);

        if (tree.node_count == tree.records.len) return error.NodesExhausted;
        return tree.record_take();
    }

    fn record_take(tree: *Tree) u32 {
        assert(tree.node_count < tree.records.len);
        assert(tree.node_count > 0);

        const result = tree.node_count;

        tree.node_count += 1;

        return result;
    }

    fn text_append(tree: *Tree, bytes: []const u8) Text {
        assert(bytes.len <= tree.text.len - tree.text_count);
        assert(tree.text_count <= tree.text.len);

        if (bytes.len == 0) return text_empty;

        const offset = tree.text_count;

        @memcpy(tree.text[offset..][0..bytes.len], bytes);
        tree.text_count += @intCast(bytes.len);

        return .{ .length = @intCast(bytes.len), .offset = offset };
    }

    fn key_write(tree: *Tree, parent: u32, key: []const u8) void {
        assert(parent < tree.node_count);
        assert(std.unicode.utf8ValidateSlice(key));

        const style = schema_module.string_style_of(key);
        const quoted: ScalarStyle = if (style == .single_quoted) .single_quoted else .double_quoted;
        const key_style: ScalarStyle = if (style == .plain) .plain else quoted;
        const index = tree.record_take();

        tree.records[index] = .{
            .anchor = text_empty,
            .count = 0,
            .first = none,
            .flags = .{ .key = true },
            .kind = .scalar,
            .last = none,
            .next = none,
            .parent = parent,
            .style = @backingInt(key_style),
            .tag = text_empty,
            .text = tree.text_append(key),
        };
    }

    fn piece_fill(tree: *Tree, index: u32, piece: *const Piece) void {
        assert(index < tree.node_count);
        if (piece.kind == .alias) assert(piece.home < tree.node_count);

        const record = &tree.records[index];

        record.anchor = tree.text_append(piece.anchor);
        record.count = 0;
        record.first = none;
        record.kind = piece.kind;
        record.last = piece.home;
        record.style = piece.style;
        record.tag = tree.text_append(piece.tag);
        record.text = tree.text_append(piece.text);
    }

    fn copy_create(
        tree: *Tree,
        placement: *const Placement,
        copy: *const Content.Copy,
    ) EditError!u32 {
        assert(@backingInt(copy.node) < copy.document.node_count);
        assert(placement.slot.parent < tree.node_count);

        const key = placement.key orelse "";
        const keyed: u32 = @intFromBool(placement.key != null);
        const comment_count = tree.comment_count;
        const node_count = tree.node_count;
        const text_count = tree.text_count;

        tree.room_check(.{ .node_count = keyed + 1, .text_bytes = key.len }) catch |err| {
            tree.diagnostic = copy.document.position_of(copy.node);

            return err;
        };

        if (placement.key != null) tree.key_write(placement.slot.parent, key);

        const value = tree.record_take();
        const root_is = placement.slot.parent == stream_index;
        const markers = copy.document.storage.nodes[@backingInt(copy.node)].markers;

        tree.records[value] = .{
            .anchor = text_empty,
            .count = 0,
            .first = none,
            .flags = .{
                .blank_before = markers.blank_before,
                .end_explicit = root_is and markers.end_explicit,
                .start_explicit = root_is and markers.start_explicit,
            },
            .kind = .scalar,
            .last = none,
            .next = none,
            .parent = placement.slot.parent,
            .style = 0,
            .tag = text_empty,
            .text = text_empty,
        };

        copy_run(tree, &.{
            .base = value + 1,
            .comments_root = true,
            .copy = copy,
            .document = placement.document,
            .level = placement.level,
            .target = value,
        }) catch |err| {
            tree.comment_count = comment_count;
            tree.node_count = node_count;
            tree.text_count = text_count;

            return err;
        };

        return value;
    }

    fn copy_replace(
        tree: *Tree,
        index: u32,
        placement: *const Placement,
        copy: *const Content.Copy,
    ) EditError!void {
        assert(index < tree.node_count);
        assert(@backingInt(copy.node) < copy.document.node_count);

        const saved = tree.records[index];
        const comment_count = tree.comment_count;
        const node_count = tree.node_count;
        const text_count = tree.text_count;
        const place: Place = .{ .document = placement.document, .index = index };

        tree.subtree_anchors_apply(place, .delete);

        copy_run(tree, &.{
            .base = node_count,
            .comments_root = false,
            .copy = copy,
            .document = placement.document,
            .level = placement.level,
            .target = index,
        }) catch |err| {
            tree.records[index] = saved;
            tree.comment_count = comment_count;
            tree.node_count = node_count;
            tree.text_count = text_count;

            tree.subtree_anchors_apply(place, .insert);

            return err;
        };

        const count = child_count_of(&saved);
        if (count == 0) return;

        tree.list_detach(.{ .document = placement.document, .index = saved.first }, count);
    }

    fn referenced_is(tree: *const Tree, segment: Segment) bool {
        assert(segment.first < tree.node_count);
        assert(segment.last < tree.node_count);

        if (!tree.segment_anchored(segment)) return false;

        for (tree.records[1..tree.node_count], 1..) |*record, position| {
            if (record.kind != .alias) continue;
            if (record.flags.detached) continue;
            if (!tree.inside(record.last, segment)) continue;
            if (tree.inside(@intCast(position), segment)) continue;
            return true;
        }

        return false;
    }

    fn inside(tree: *const Tree, index: u32, segment: Segment) bool {
        assert(index < tree.node_count);
        assert(segment.first < tree.node_count);

        var cursor = index;

        for (0..depth_max + 2) |_| {
            if (cursor == segment.first) return true;
            if (cursor == segment.last) return true;
            if (cursor == stream_index) return false;

            cursor = tree.records[cursor].parent;
        }

        unreachable;
    }

    fn segment_anchored(tree: *const Tree, segment: Segment) bool {
        assert(segment.first < tree.node_count);
        assert(segment.last < tree.node_count);

        if (tree.subtree_anchored(segment.first)) return true;
        if (segment.last == segment.first) return false;
        return tree.subtree_anchored(segment.last);
    }

    fn subtree_anchored(tree: *const Tree, index: u32) bool {
        assert(index < tree.node_count);
        assert(index != stream_index);

        var walk: Walk = undefined;
        var cursor = index;

        walk.start(tree, index);

        for (0..tree.node_count) |_| {
            if (anchored_is(&tree.records[cursor])) return true;

            cursor = walk.next(tree) orelse return false;
        }

        unreachable;
    }

    fn subtree_anchors_apply(tree: *Tree, place: Place, action: AnchorAction) void {
        assert(place.index < tree.node_count);
        assert(place.document < tree.node_count);

        var walk: Walk = undefined;
        var cursor = place.index;

        walk.start(tree, place.index);

        for (0..tree.node_count) |_| {
            if (anchored_is(&tree.records[cursor])) {
                const home: Place = .{ .document = place.document, .index = cursor };

                switch (action) {
                    .delete => tree.anchor_delete(home),
                    .insert => tree.anchor_insert(home),
                }
            }

            cursor = walk.next(tree) orelse return;
        }

        unreachable;
    }

    fn subtree_detach(tree: *Tree, place: Place) void {
        assert(place.index < tree.node_count);
        assert(!tree.records[place.index].flags.detached);

        tree.home_unregister(place);
        tree.records[place.index].flags.detached = true;

        tree.children_detach(place);
    }

    fn children_detach(tree: *Tree, place: Place) void {
        assert(place.index < tree.node_count);
        assert(place.document < tree.node_count);

        const record = &tree.records[place.index];
        const count = child_count_of(record);
        if (count == 0) return;

        tree.list_detach(.{ .document = place.document, .index = record.first }, count);
    }

    fn list_detach(tree: *Tree, first: Place, count: u32) void {
        assert(first.index < tree.node_count);
        assert(count > 0);

        var walk: Walk = undefined;

        walk.depth = 0;

        walk.push(.{ .cursor = first.index, .remaining = count });

        for (0..tree.node_count) |_| {
            const child = walk.next(tree) orelse return;

            tree.home_unregister(.{ .document = first.document, .index = child });
            tree.records[child].flags.detached = true;
        }

        unreachable;
    }

    fn home_unregister(tree: *Tree, place: Place) void {
        assert(place.index < tree.node_count);
        assert(place.document < tree.node_count);

        if (!anchored_is(&tree.records[place.index])) return;
        if (!tree.anchor_registered_is(place)) return;

        tree.anchor_delete(place);
    }

    fn segment_find(tree: *const Tree, index: u32) Segment {
        assert(index < tree.node_count);
        assert(index != stream_index);

        const parent = tree.records[index].parent;
        const container = &tree.records[parent];
        const mapping = container.kind == .mapping;

        assert(container.count > 0);

        var predecessor = none;
        var cursor = container.first;

        for (0..container.count) |_| {
            const last = if (mapping) tree.records[cursor].next else cursor;
            const found = cursor == index or last == index;
            if (found) return .{ .first = cursor, .last = last, .predecessor = predecessor };

            predecessor = last;
            cursor = tree.records[last].next;
        }

        unreachable;
    }

    fn segment_append(tree: *Tree, container: u32, segment: Segment) void {
        assert(container < tree.node_count);
        assert(tree.records[segment.first].parent == container);
        assert(tree.records[segment.last].parent == container);
        assert(tree.records[segment.last].next == none);

        const record = &tree.records[container];

        if (record.count == 0) {
            record.first = segment.first;
        } else {
            tree.records[record.last].next = segment.first;
        }

        record.last = segment.last;
        record.count += 1;
    }

    fn segment_insert(tree: *Tree, container: u32, segment: Segment) void {
        assert(container < tree.node_count);
        assert(tree.records[segment.first].parent == container);

        const record = &tree.records[container];

        assert(record.count > 0);
        assert(segment.predecessor != record.last);

        if (segment.predecessor == none) {
            tree.records[segment.last].next = record.first;
            record.first = segment.first;
        } else {
            assert(tree.records[segment.predecessor].parent == container);

            tree.records[segment.last].next = tree.records[segment.predecessor].next;
            tree.records[segment.predecessor].next = segment.first;
        }

        record.count += 1;
    }

    fn segment_unlink(tree: *Tree, segment: Segment) void {
        assert(segment.first < tree.node_count);
        assert(segment.last < tree.node_count);

        const record = &tree.records[tree.records[segment.first].parent];
        const successor = tree.records[segment.last].next;

        assert(record.count > 0);

        if (segment.predecessor == none) {
            assert(record.first == segment.first);

            record.first = successor;
        } else {
            assert(tree.records[segment.predecessor].next == segment.first);

            tree.records[segment.predecessor].next = successor;
        }

        if (record.last == segment.last) record.last = segment.predecessor;

        record.count -= 1;
    }

    fn anchor_lookup(tree: *const Tree, document: u32, name: []const u8) u32 {
        assert(document <= tree.records.len);
        assert(name.len > 0);

        const hash = anchor_hash(document, name);
        const mask: u32 = @intCast(tree.anchors.len - 1);
        var position = hash & mask;

        for (0..tree.anchors.len) |_| {
            const slot = &tree.anchors[position];
            if (slot.home == none) return none;

            if (slot.hash == hash) {
                if (slot.root == document) {
                    const home_name = tree.text_at(tree.records[slot.home].anchor);
                    if (std.mem.eql(u8, home_name, name)) return slot.home;
                }
            }

            position = (position + 1) & mask;
        }

        unreachable;
    }

    fn anchor_registered_is(tree: *const Tree, place: Place) bool {
        assert(place.index < tree.node_count);
        assert(anchored_is(&tree.records[place.index]));

        const name = tree.text_at(tree.records[place.index].anchor);
        return tree.anchor_lookup(place.document, name) == place.index;
    }

    fn anchor_insert(tree: *Tree, place: Place) void {
        assert(place.index < tree.node_count);
        assert(tree.anchor_count < anchor_count_max_of(tree));

        const name = tree.text_at(tree.records[place.index].anchor);
        const hash = anchor_hash(place.document, name);
        const mask: u32 = @intCast(tree.anchors.len - 1);
        var position = hash & mask;

        assert(tree.anchor_lookup(place.document, name) == none);

        for (0..tree.anchors.len) |_| {
            const slot = &tree.anchors[position];

            if (slot.home == none) {
                slot.* = .{ .hash = hash, .home = place.index, .root = place.document };
                tree.anchor_count += 1;

                return;
            }

            position = (position + 1) & mask;
        }

        unreachable;
    }

    fn anchor_delete(tree: *Tree, place: Place) void {
        assert(place.index < tree.node_count);
        assert(tree.anchor_count > 0);

        const slots = tree.anchors;
        const name = tree.text_at(tree.records[place.index].anchor);
        const mask: u32 = @intCast(slots.len - 1);
        var hole = anchor_hash(place.document, name) & mask;

        for (0..slots.len) |_| {
            if (slots[hole].home == place.index) break;

            assert(slots[hole].home != none);

            hole = (hole + 1) & mask;
        }

        assert(slots[hole].home == place.index);
        assert(slots[hole].root == place.document);

        var cursor = hole;

        for (0..slots.len) |_| {
            cursor = (cursor + 1) & mask;

            const slot = slots[cursor];
            if (slot.home == none) break;

            const distance_home = (cursor -% (slot.hash & mask)) & mask;
            const distance_hole = (cursor -% hole) & mask;

            if (distance_home >= distance_hole) {
                slots[hole] = slot;
                hole = cursor;
            }
        }

        slots[hole] = .{ .hash = 0, .home = none, .root = none };
        tree.anchor_count -= 1;
    }

    fn blanks_any(tree: *const Tree) bool {
        assert(tree.node_count > stream_index);
        assert(tree.node_count <= tree.records.len);

        for (tree.records[stream_index + 1 .. tree.node_count]) |*record| {
            if (record.flags.detached) continue;
            if (blank_written_is(record)) return true;
        }

        return false;
    }

    fn document_comments_write(tree: *const Tree, writer: *Writer, index: u32) Writer.Error!void {
        assert(index < tree.node_count);
        assert(tree.comment_count > 0 or tree.blanks_any());

        const flags = tree.records[index].flags;
        const slots = tree.comment_slots[0..tree.comment_count];
        const range = comment_module.range_of(slots, index);

        try comment_module.prefix_heads_write(writer, slots, range);
        try writer.document_begin(&.{ .explicit = flags.start_explicit });
        try tree.records_comments_write(writer, index);
        try writer.document_end(&.{ .explicit = flags.end_explicit });
        try comment_module.feet_write(writer, slots, range, true, .all);
    }

    fn records_comments_write(tree: *const Tree, writer: *Writer, start: u32) Writer.Error!void {
        assert(start < tree.node_count);
        assert(writer.depth == 0);

        const records = tree.records[0..tree.node_count];
        var frames: [depth_max]CommentWriteFrame = undefined;
        var depth: u32 = 0;

        try tree.node_comments_write(writer, frames[0..], &depth, start);

        for (0..2 * records.len) |_| {
            if (depth == 0) return;

            const frame = &frames[depth - 1];

            if (frame.remaining == 0) {
                depth -= 1;

                try tree.collection_comments_close(writer, frames[0..depth], frame);

                continue;
            }

            const child = frame.cursor;

            frame.cursor = records[child].next;
            frame.remaining -= 1;

            try tree.node_comments_write(writer, frames[0..], &depth, child);
        }

        unreachable;
    }

    fn node_comments_write(
        tree: *const Tree,
        writer: *Writer,
        frames: []CommentWriteFrame,
        depth: *u32,
        index: u32,
    ) Writer.Error!void {
        assert(index < tree.node_count);
        assert(depth.* <= frames.len);

        const records = tree.records[0..tree.node_count];
        const text = tree.text[0..tree.text_count];
        const slots = tree.comment_slots[0..tree.comment_count];
        const record = &records[index];
        const range = comment_module.range_of(slots, index);
        const parent = if (depth.* == 0) null else &frames[depth.* - 1].entry;
        const commented = range.end > range.first;

        try comment_module.heads_write(writer, slots, range, blank_written_is(record));

        const collection = record.kind == .mapping or record.kind == .sequence;

        if (collection) {
            const flow = record.style == @backingInt(CollectionStyle.flow);

            try collection_begin_write(writer, text, record);

            if (commented) try comment_module.line_write(writer, slots, range, .opening);

            if (record.count > 0) {
                assert(depth.* < frames.len);

                frames[depth.*] = .{
                    .cursor = record.first,
                    .entry = .of(record.kind == .mapping),
                    .flow = flow,
                    .range = range,
                    .remaining = child_count_of(record),
                };

                depth.* += 1;

                return;
            }

            if (commented) try comment_module.collection_feet_write(writer, slots, range, flow);

            try collection_end_write(writer, record.kind == .mapping);

            if (commented) try comment_module.line_write(writer, slots, range, .closing);

            try comment_module.entry_finish(writer, slots, parent, range, .of_collection(flow));

            return;
        }

        const block = record.kind == .scalar and block_style_is(record.style);
        const line_first = commented and block;
        const line_last = commented and !block;

        if (line_first) try comment_module.line_write(writer, slots, range, .node);

        const open = try record_write(records, text, writer, index);

        assert(!open);

        if (line_last) try comment_module.line_write(writer, slots, range, .node);

        try comment_module.entry_finish(writer, slots, parent, range, .leaf);
    }

    fn collection_comments_close(
        tree: *const Tree,
        writer: *Writer,
        frames: []CommentWriteFrame,
        frame: *const CommentWriteFrame,
    ) Writer.Error!void {
        assert(frame.remaining == 0);
        assert(frames.len < depth_max);

        const slots = tree.comment_slots[0..tree.comment_count];
        const parent = if (frames.len == 0) null else &frames[frames.len - 1].entry;
        const range = frame.range;
        const commented = range.end > range.first;
        const shape: comment_module.Shape = .of_collection(frame.flow);

        if (commented) try comment_module.collection_feet_write(writer, slots, range, frame.flow);

        try collection_end_write(writer, frame.entry.mapping);

        if (commented) try comment_module.line_write(writer, slots, range, .closing);

        try comment_module.entry_finish(writer, slots, parent, range, shape);
    }

    fn document_write(
        tree: *const Tree,
        writer: *Writer,
        index: u32,
        kept: bool,
    ) Writer.Error!void {
        assert(index < tree.node_count);
        assert(writer.depth == 0);

        if (kept) return tree.document_comments_write(writer, index);

        const flags = tree.records[index].flags;
        const records = tree.records[0..tree.node_count];
        const text = tree.text[0..tree.text_count];

        try writer.document_begin(&.{ .explicit = flags.start_explicit });
        try records_write(records, text, writer, index);
        try writer.document_end(&.{ .explicit = flags.end_explicit });
    }
};

const CommentPlan = struct {
    slot_count: u32,
    tail: bool,
    text_bytes: u32,
};

fn comment_plan_of(placement: Comment.Placement, text: []const u8) CommentPlan {
    assert(text.len <= source_bytes_max);
    assert(@backingInt(placement) <= 2);

    var result: CommentPlan = .{ .slot_count = 0, .tail = false, .text_bytes = 0 };
    var start: u32 = 0;

    if (text.len == 0) return result;

    for (0..text.len + 1) |_| {
        const end: u32 = @intCast(std.mem.findScalarPos(u8, text, start, '\n') orelse text.len);

        result.tail = end == start;

        if (end > start) {
            result.slot_count += 1;
            result.text_bytes += end - start;
        }

        if (end == text.len) break;

        start = end + 1;
    }

    const foot_tail = result.tail and placement == .foot;

    if (foot_tail) result.slot_count += 1;

    return result;
}

fn placement_range_of(
    slots: []const CommentSlot,
    range: CommentRange,
    placement: Comment.Placement,
) CommentRange {
    assert(range.first <= range.end);
    assert(range.end <= slots.len);
    assert(@backingInt(placement) <= 2);

    const rank = comment_module.rank_of(placement);
    var result: CommentRange = .{ .end = range.first, .first = range.first };

    for (slots[range.first..range.end]) |*slot| {
        const slot_rank = comment_module.rank_of(slot.placement);

        if (slot_rank < rank) {
            result.first += 1;
            result.end += 1;
        } else if (slot_rank == rank) {
            result.end += 1;
        } else {
            break;
        }
    }

    return result;
}

fn comment_slot_of(
    node: u32,
    placement: Comment.Placement,
    text: []const u8,
    blank: bool,
) CommentSlot {
    assert(node != none);
    assert(text.len <= source_bytes_max);
    assert(@backingInt(placement) <= 2);

    return .{
        .column = 0,
        .flags = .{
            .blank_before = blank,
            .inside = false,
            .prefix = false,
            .trailing = placement == .line,
            .padding = 0,
        },
        .flow_depth = 0,
        .line = 0,
        .node = node,
        .placement = placement,
        .previous = .scalar,
        .text = text,
    };
}

pub fn TreeType(comptime capacity: Capacity) type {
    comptime assert(capacity.node_count_max > 0);
    comptime assert(capacity.anchor_count_max > 0);

    return struct {
        storage: Tree.StorageType(capacity),
        tree: Tree,

        const Fixed = @This();

        pub fn init(fixed: *Fixed, options: Tree.Options) void {
            comptime assert(@sizeOf(@TypeOf(options)) <= 16);
            assert(fixed.storage.records.len == capacity.node_count_max);

            fixed.tree.init(fixed.storage.storage(), options);
        }

        pub fn diagnostic(fixed: *const Fixed) Position {
            assert(fixed.tree.node_count > 0);
            assert(fixed.tree.node_count <= capacity.node_count_max);

            return fixed.tree.diagnostic;
        }

        pub fn root_count(fixed: *const Fixed) u32 {
            assert(fixed.tree.node_count > 0);
            assert(fixed.tree.node_count <= capacity.node_count_max);

            return fixed.tree.root_count();
        }

        pub fn root(fixed: *const Fixed, index: u32) Tree.Node {
            assert(index < fixed.tree.root_count());
            assert(fixed.tree.node_count <= capacity.node_count_max);

            return fixed.tree.root(index);
        }

        pub fn comments(fixed: *const Fixed, node: Tree.Node) Comments {
            assert(@backingInt(node) < fixed.tree.node_count);
            assert(fixed.tree.comment_count <= fixed.storage.comments.len);

            return fixed.tree.comments(node);
        }

        pub fn comment_set(
            fixed: *Fixed,
            node: Tree.Node,
            placement: Comment.Placement,
            text: []const u8,
        ) Tree.EditError!void {
            assert(@backingInt(node) < fixed.tree.node_count);
            assert(@backingInt(placement) <= 2);
            assert(text.len <= source_bytes_max);

            return fixed.tree.comment_set(node, placement, text);
        }

        pub fn kind_of(fixed: *const Fixed, node: Tree.Node) Tree.Kind {
            assert(@backingInt(node) < fixed.tree.node_count);
            assert(fixed.tree.node_count <= capacity.node_count_max);

            return fixed.tree.kind_of(node);
        }

        pub fn text_of(fixed: *const Fixed, node: Tree.Node) ?[]const u8 {
            assert(@backingInt(node) < fixed.tree.node_count);
            assert(fixed.tree.node_count <= capacity.node_count_max);

            return fixed.tree.text_of(node);
        }

        pub fn style_of(fixed: *const Fixed, node: Tree.Node) Style {
            assert(@backingInt(node) < fixed.tree.node_count);
            assert(fixed.tree.node_count <= capacity.node_count_max);

            return fixed.tree.style_of(node);
        }

        pub fn tag_of(fixed: *const Fixed, node: Tree.Node) []const u8 {
            assert(@backingInt(node) < fixed.tree.node_count);
            assert(fixed.tree.node_count <= capacity.node_count_max);

            return fixed.tree.tag_of(node);
        }

        pub fn anchor_of(fixed: *const Fixed, node: Tree.Node) []const u8 {
            assert(@backingInt(node) < fixed.tree.node_count);
            assert(fixed.tree.node_count <= capacity.node_count_max);

            return fixed.tree.anchor_of(node);
        }

        pub fn alias_of(fixed: *const Fixed, node: Tree.Node) ?Tree.Node {
            assert(@backingInt(node) < fixed.tree.node_count);
            assert(fixed.tree.node_count <= capacity.node_count_max);

            return fixed.tree.alias_of(node);
        }

        pub fn count_of(fixed: *const Fixed, node: Tree.Node) u32 {
            assert(@backingInt(node) < fixed.tree.node_count);
            assert(fixed.tree.node_count <= capacity.node_count_max);

            return fixed.tree.count_of(node);
        }

        pub fn entries(fixed: *const Fixed, mapping: Tree.Node) Tree.Entries {
            assert(@backingInt(mapping) < fixed.tree.node_count);
            assert(fixed.tree.node_count <= capacity.node_count_max);

            return fixed.tree.entries(mapping);
        }

        pub fn items(fixed: *const Fixed, sequence: Tree.Node) Tree.Items {
            assert(@backingInt(sequence) < fixed.tree.node_count);
            assert(fixed.tree.node_count <= capacity.node_count_max);

            return fixed.tree.items(sequence);
        }

        pub fn member(fixed: *const Fixed, mapping: Tree.Node, key: []const u8) ?Tree.Node {
            assert(@backingInt(mapping) < fixed.tree.node_count);
            assert(key.len <= source_bytes_max);

            return fixed.tree.member(mapping, key);
        }

        pub fn item(fixed: *const Fixed, sequence: Tree.Node, index: u32) ?Tree.Node {
            assert(@backingInt(sequence) < fixed.tree.node_count);
            assert(index < source_bytes_max);

            return fixed.tree.item(sequence, index);
        }

        pub fn path_find(
            fixed: *const Fixed,
            start: Tree.Node,
            segments: []const []const u8,
        ) ?Tree.Node {
            assert(@backingInt(start) < fixed.tree.node_count);
            assert(segments.len <= source_bytes_max);

            return fixed.tree.path_find(start, segments);
        }

        pub fn null_is(fixed: *const Fixed, node: Tree.Node) bool {
            assert(@backingInt(node) < fixed.tree.node_count);
            assert(fixed.tree.node_count <= capacity.node_count_max);

            return fixed.tree.null_is(node);
        }

        pub fn boolean_of(fixed: *const Fixed, node: Tree.Node) ?bool {
            assert(@backingInt(node) < fixed.tree.node_count);
            assert(fixed.tree.node_count <= capacity.node_count_max);

            return fixed.tree.boolean_of(node);
        }

        pub fn integer_of(fixed: *const Fixed, node: Tree.Node) ?i64 {
            assert(@backingInt(node) < fixed.tree.node_count);
            assert(fixed.tree.node_count <= capacity.node_count_max);

            return fixed.tree.integer_of(node);
        }

        pub fn float_of(fixed: *const Fixed, node: Tree.Node) ?f64 {
            assert(@backingInt(node) < fixed.tree.node_count);
            assert(fixed.tree.node_count <= capacity.node_count_max);

            return fixed.tree.float_of(node);
        }

        pub fn root_append(fixed: *Fixed, content: Tree.Content) Tree.EditError!Tree.Node {
            assert(fixed.tree.node_count <= capacity.node_count_max);
            assert(content_bytes(&content) <= source_bytes_max);

            return try fixed.tree.root_append(content);
        }

        pub fn set(
            fixed: *Fixed,
            mapping: Tree.Node,
            key: []const u8,
            content: Tree.Content,
        ) Tree.EditError!Tree.Node {
            assert(@backingInt(mapping) < fixed.tree.node_count);
            assert(key.len <= source_bytes_max);
            assert(content_bytes(&content) <= source_bytes_max);

            return try fixed.tree.set(mapping, key, content);
        }

        pub fn append(fixed: *Fixed, sequence: Tree.Node, content: Tree.Content) error{
            AliasInvalid,
            AnchorDuplicate,
            AnchorReferenced,
            AnchorsExhausted,
            CommentsExhausted,
            DepthExceeded,
            MergeInvalid,
            MergesExceeded,
            NodesExhausted,
            TextExhausted,
            TextInvalid,
        }!Tree.Node {
            assert(@backingInt(sequence) < fixed.tree.node_count);
            assert(content_bytes(&content) <= source_bytes_max);

            return try fixed.tree.append(sequence, content);
        }

        pub fn insert(fixed: *Fixed, sequence: Tree.Node, index: u32, content: Tree.Content) error{
            AliasInvalid,
            AnchorDuplicate,
            AnchorReferenced,
            AnchorsExhausted,
            CommentsExhausted,
            DepthExceeded,
            MergeInvalid,
            MergesExceeded,
            NodesExhausted,
            TextExhausted,
            TextInvalid,
        }!Tree.Node {
            assert(@backingInt(sequence) < fixed.tree.node_count);
            assert(index <= fixed.tree.count_of(sequence));
            assert(content_bytes(&content) <= source_bytes_max);

            return try fixed.tree.insert(sequence, index, content);
        }

        pub fn replace(fixed: *Fixed, node: Tree.Node, content: Tree.Content) Tree.EditError!void {
            assert(@backingInt(node) < fixed.tree.node_count);
            assert(content_bytes(&content) <= source_bytes_max);

            return try fixed.tree.replace(node, content);
        }

        pub fn remove(fixed: *Fixed, node: Tree.Node) Tree.RemoveError!void {
            assert(@backingInt(node) < fixed.tree.node_count);
            assert(fixed.tree.node_count <= capacity.node_count_max);

            return try fixed.tree.remove(node);
        }

        pub fn write(
            fixed: *const Fixed,
            sink: *std.Io.Writer,
            options: Writer.Options,
        ) std.Io.Writer.Error!void {
            comptime assert(@sizeOf(@TypeOf(options)) <= 16);
            assert(options.indent >= 1);
            assert(fixed.tree.node_count <= capacity.node_count_max);

            return try fixed.tree.write(sink, options);
        }

        pub fn write_json(
            fixed: *const Fixed,
            sink: *std.Io.Writer,
            options: JSONOptions,
        ) JSONOptions.Error!void {
            comptime assert(@sizeOf(@TypeOf(options)) <= 16);
            assert(options.node_count_max > 0);
            assert(fixed.tree.node_count <= capacity.node_count_max);

            return try fixed.tree.write_json(sink, options);
        }
    };
}

const AnchorAction = enum {
    delete,
    insert,
};

const AnchorSlot = struct {
    hash: u32,
    home: u32,
    root: u32,
};

const Ascent = struct {
    child: u32,
    node: u32,
};

const Child = struct {
    mode: Mode,
    source: u32,
};

const CopyFrame = struct {
    container: u32,
    count: u32,
    cursor: u32,
    end: u32,
    entries: document_module.Entries,
    first: u32,
    last: u32,
    list: []const DocumentNode,
    mapping: bool,
    mode: Mode,
    pending: u32,
    phase: Phase,
    position: u32,
    source: u32,
};

const CopyPlan = struct {
    base: u32,
    comments_root: bool,
    copy: *const Tree.Content.Copy,
    document: u32,
    level: u32,
    target: u32,
};

const Copier = struct {
    depth: u32,
    failure: u32,
    frames: [depth_max]CopyFrame,
    plan: *const CopyPlan,
    range_end: u32,
    range_first: u32,
    sources: merge.StackType(Document),
    tree: *Tree,
};

const Mode = enum {
    expanded,
    raw,
};

const Need = struct {
    node_count: u32,
    text_bytes: u64,
};

const Phase = enum {
    merged,
    own,
    rest,
};

const Piece = struct {
    anchor: []const u8,
    home: u32,
    kind: Record.Kind,
    style: u8,
    tag: []const u8,
    text: []const u8,
};

const Place = struct {
    document: u32,
    index: u32,
};

const Placement = struct {
    document: u32,
    key: ?[]const u8,
    level: u32,
    slot: Slot,
};

const Record = struct {
    anchor: Text,
    count: u32,
    first: u32,
    flags: Flags,
    kind: Kind,
    last: u32,
    next: u32,
    parent: u32,
    style: u8,
    tag: Text,
    text: Text,

    const Flags = packed struct(u8) {
        detached: bool = false,
        end_explicit: bool = false,
        key: bool = false,
        start_explicit: bool = false,
        blank_before: bool = false,
        padding: u3 = 0,
    };

    const Kind = enum(u8) {
        alias,
        mapping,
        scalar,
        sequence,
        stream,
    };
};

const Segment = struct {
    first: u32,
    last: u32,
    predecessor: u32 = none,
};

const Sibling = union(enum) {
    at: u32,
    before: u32,
    end,
};

const Slot = struct {
    parent: u32,
    sibling: Sibling,
};

const Text = struct {
    length: u32,
    offset: u32,
};

const Walk = struct {
    depth: u32,
    frames: [depth_max + 1]WalkFrame,

    fn start(walk: *Walk, tree: *const Tree, index: u32) void {
        assert(index < tree.node_count);
        assert(walk.frames.len == depth_max + 1);

        walk.depth = 0;

        walk.children_push(tree, &tree.records[index]);
    }

    fn push(walk: *Walk, frame: WalkFrame) void {
        assert(frame.remaining > 0);
        assert(walk.depth < walk.frames.len);

        walk.frames[walk.depth] = frame;
        walk.depth += 1;
    }

    fn children_push(walk: *Walk, tree: *const Tree, record: *const Record) void {
        assert(walk.depth <= walk.frames.len);
        assert(tree.node_count <= tree.records.len);

        const count = child_count_of(record);
        if (count == 0) return;

        walk.push(.{ .cursor = record.first, .remaining = count });
    }

    fn next(walk: *Walk, tree: *const Tree) ?u32 {
        assert(walk.depth <= walk.frames.len);
        assert(tree.node_count <= tree.records.len);

        for (0..walk.frames.len + 1) |_| {
            if (walk.depth == 0) return null;

            const frame = &walk.frames[walk.depth - 1];

            if (frame.remaining == 0) {
                walk.depth -= 1;

                continue;
            }

            const child = frame.cursor;
            const record = &tree.records[child];

            frame.cursor = record.next;
            frame.remaining -= 1;

            walk.children_push(tree, record);

            return child;
        }

        unreachable;
    }
};

const WalkFrame = struct {
    cursor: u32,
    remaining: u32,
};

const WriteFrame = struct {
    cursor: u32,
    mapping: bool,
    remaining: u32,
};

const CommentWriteFrame = struct {
    cursor: u32,
    entry: comment_module.Entry,
    flow: bool,
    range: CommentRange,
    remaining: u32,
};

fn blank_written_is(record: *const Record) bool {
    assert(record.kind != .stream);

    if (!record.flags.blank_before) return false;
    if (record.kind != .scalar) return true;
    if (record.style != @backingInt(ScalarStyle.plain)) return true;
    if (record.text.length > 0) return true;
    if (record.anchor.length > 0) return true;
    return record.tag.length > 0;
}

fn block_style_is(style: u8) bool {
    assert(style <= @backingInt(ScalarStyle.single_quoted));

    const literal = style == @backingInt(ScalarStyle.literal);
    const folded = style == @backingInt(ScalarStyle.folded);

    return literal or folded;
}

pub fn audit(tree: *const Tree) void {
    assert(tree.node_count > 0);
    assert(tree.node_count <= tree.records.len);
    assert(tree.text_count <= tree.text.len);
    assert(tree.records[stream_index].kind == .stream);
    assert(tree.records[stream_index].parent == none);

    list_audit(tree, stream_index);

    var walk: Walk = undefined;
    var homes: u32 = 0;
    var reached: u32 = 1;

    walk.start(tree, stream_index);

    for (0..tree.node_count) |_| {
        const index = walk.next(tree) orelse break;

        record_audit(tree, index);

        homes += @intFromBool(anchored_is(&tree.records[index]));
        reached += 1;
    }

    var attached_count: u32 = 0;

    for (tree.records[0..tree.node_count]) |*record| {
        attached_count += @intFromBool(!record.flags.detached);
    }

    assert(walk.depth == 0);
    assert(attached_count == reached);
    assert(homes == tree.anchor_count);
}

fn record_audit(tree: *const Tree, index: u32) void {
    assert(index < tree.node_count);
    assert(!tree.records[index].flags.detached);

    const record = &tree.records[index];
    const parent = &tree.records[record.parent];

    assert(!parent.flags.detached);
    assert(container_is(parent.kind));

    if (record.flags.key) assert(parent.kind == .mapping);
    if (record.flags.start_explicit) assert(record.parent == stream_index);
    if (record.flags.end_explicit) assert(record.parent == stream_index);

    switch (record.kind) {
        .alias => alias_audit(tree, index),
        .mapping, .sequence => {
            assert(tree.level_of(index) <= depth_max);

            list_audit(tree, index);
        },
        .scalar => {
            assert(record.first == none);
            assert(record.last == none);
            assert(std.unicode.utf8ValidateSlice(tree.text_at(record.text)));
        },
        .stream => unreachable,
    }

    assert(std.unicode.utf8ValidateSlice(tree.text_at(record.tag)));

    if (anchored_is(record)) {
        const name = tree.text_at(record.anchor);

        assert(anchor_valid_is(name));
        assert(tree.anchor_lookup(tree.document_of(index), name) == index);
    }
}

fn alias_audit(tree: *const Tree, index: u32) void {
    assert(index < tree.node_count);
    assert(tree.records[index].kind == .alias);

    const record = &tree.records[index];
    const home = &tree.records[record.last];

    assert(record.last < tree.node_count);
    assert(record.first == none);
    assert(record.anchor.length == 0);
    assert(record.count == 0);
    assert(!home.flags.detached);
    assert(home.kind != .alias);
    assert(home.anchor.length > 0);
    assert(tree.document_of(record.last) == tree.document_of(index));
    assert(tree.precedes(record.last, .{ .parent = record.parent, .sibling = .{ .at = index } }));
}

fn list_audit(tree: *const Tree, container: u32) void {
    assert(container < tree.node_count);
    assert(container_is(tree.records[container].kind));

    const record = &tree.records[container];
    const count = child_count_of(record);
    const mapping = record.kind == .mapping;

    if (count == 0) {
        assert(record.first == none);
        assert(record.last == none);

        return;
    }

    var cursor = record.first;

    for (0..count) |position| {
        const child = &tree.records[cursor];
        const key_expected = mapping and position % 2 == 0;

        if (position > 0) assert(cursor != record.first);
        if (position + 1 == count) assert(cursor == record.last);

        assert(child.parent == container);
        assert(!child.flags.detached);
        assert(child.flags.key == key_expected);

        cursor = child.next;
    }

    assert(cursor == none);
}

fn copy_run(tree: *Tree, plan: *const CopyPlan) Tree.EditError!void {
    assert(plan.target < tree.node_count);
    assert(plan.target < plan.base);

    const source = @backingInt(plan.copy.node);
    const record = &plan.copy.document.storage.nodes[source];

    assert(record.kind != .alias);

    var copier: Copier = .{
        .depth = 0,
        .failure = source,
        .frames = undefined,
        .plan = plan,
        .range_end = source + record.span,
        .range_first = source,
        .sources = .{ .count = 0, .failure = undefined, .nodes = undefined },
        .tree = tree,
    };

    copier_run(&copier) catch |err| {
        copier_rollback(&copier);
        tree.diagnostic = failure_position(&copier, err);

        return err;
    };
}

fn failure_position(copier: *const Copier, err: Tree.EditError) Position {
    assert(copier.depth <= depth_max);
    assert(copier.failure < copier.plan.copy.document.node_count);
    assert(err != error.AnchorReferenced);

    const index = switch (err) {
        error.MergeInvalid => @backingInt(copier.sources.failure),
        error.MergesExceeded => copier.frames[copier.depth].source,
        else => copier.failure,
    };

    return storage_module.position_of(&copier.plan.copy.document.storage.nodes[index]);
}

fn copier_run(copier: *Copier) Tree.EditError!void {
    assert(copier.depth == 0);
    assert(copier.range_first < copier.range_end);

    const target = copier.plan.target;
    const child: Child = .{ .mode = .raw, .source = copier.range_first };

    try copier.tree.text_room_check(node_bytes_of(copier, child));

    node_fill(copier, target, child);

    if (copier.plan.comments_root) {
        try comments_carry(copier, .{ .source = child.source, .target = target });
    }

    try anchor_register(copier, target);
    try frame_open(copier, target, child);

    const step_count_max = 2 * @as(u64, copier.tree.records.len) + 2;

    for (0..step_count_max) |_| {
        if (copier.depth == 0) return;

        const frame = &copier.frames[copier.depth - 1];
        const next = try child_next(copier, frame);

        if (next.source == none) {
            frame_close(copier);
        } else {
            try child_emit(copier, next);
        }
    }

    unreachable;
}

fn copier_rollback(copier: *Copier) void {
    assert(copier.plan.base <= copier.tree.node_count);
    assert(copier.plan.target < copier.plan.base);

    const tree = copier.tree;
    const document = copier.plan.document;

    tree.home_unregister(.{ .document = document, .index = copier.plan.target });

    for (copier.plan.base..tree.node_count) |position| {
        tree.home_unregister(.{ .document = document, .index = @intCast(position) });
    }
}

fn child_emit(copier: *Copier, child: Child) Tree.EditError!void {
    assert(child.source < copier.plan.copy.document.node_count);
    assert(copier.depth > 0);

    copier.failure = child.source;

    const record = &copier.plan.copy.document.storage.nodes[child.source];
    const commented = if (child.mode == .raw) child.source else none;
    if (record.kind != .alias) return node_emit(copier, child, commented);

    if (child.mode == .raw) {
        const home = home_of(copier, record.link.target);
        if (home != none) return alias_emit(copier, home, child);
    }

    return node_emit(copier, .{ .mode = .expanded, .source = record.link.target }, commented);
}

fn node_emit(copier: *Copier, child: Child, commented: u32) Tree.EditError!void {
    assert(child.source < copier.plan.copy.document.node_count);
    assert(copier.depth > 0);
    assert(commented == none or commented < copier.plan.copy.document.node_count);

    try copier.tree.text_room_check(node_bytes_of(copier, child));

    const index = try copier.tree.record_reserve();

    node_fill(copier, index, child);
    child_link(copier, index);

    if (commented != none) try comments_carry(copier, .{ .source = commented, .target = index });

    try anchor_register(copier, index);
    try frame_open(copier, index, child);
}

fn node_bytes_of(copier: *const Copier, child: Child) u64 {
    assert(child.source < copier.plan.copy.document.node_count);
    assert(copier.plan.copy.document.storage.nodes[child.source].kind != .alias);

    const record = &copier.plan.copy.document.storage.nodes[child.source];
    const anchor: u64 = if (child.mode == .raw) record.anchor.len else 0;
    const result = anchor + record.tag.len + record.text.len;

    assert(result <= 3 * @as(u64, source_bytes_max));

    return result;
}

fn node_fill(copier: *Copier, index: u32, child: Child) void {
    assert(index < copier.tree.node_count);
    assert(copier.plan.copy.document.storage.nodes[child.source].kind != .alias);

    const tree = copier.tree;
    const record = &copier.plan.copy.document.storage.nodes[child.source];
    const target = &tree.records[index];
    const anchor = if (child.mode == .raw) record.anchor else "";

    target.anchor = tree.text_append(anchor);
    target.count = 0;
    target.first = none;
    target.kind = record_kind_of(record.kind);
    target.last = none;
    target.style = record.style;
    target.tag = tree.text_append(record.tag);
    target.text = tree.text_append(record.text);
}

fn anchor_register(copier: *Copier, index: u32) Tree.EditError!void {
    assert(index < copier.tree.node_count);
    assert(copier.plan.document <= copier.tree.node_count);

    const tree = copier.tree;
    const record = &tree.records[index];
    if (!anchored_is(record)) return;

    const name = tree.text_at(record.anchor);
    if (tree.anchor_lookup(copier.plan.document, name) != none) return error.AnchorDuplicate;
    if (tree.anchor_count == anchor_count_max_of(tree)) return error.AnchorsExhausted;

    tree.anchor_insert(.{ .document = copier.plan.document, .index = index });
}

fn home_of(copier: *const Copier, target: u32) u32 {
    assert(target < copier.plan.copy.document.node_count);
    assert(copier.range_first < copier.range_end);

    if (target < copier.range_first) return none;
    if (target >= copier.range_end) return none;

    const name = copier.plan.copy.document.storage.nodes[target].anchor;

    assert(name.len > 0);

    const home = copier.tree.anchor_lookup(copier.plan.document, name);
    if (home == none) return none;
    if (!part_of_copy(copier, home)) return none;
    return home;
}

fn part_of_copy(copier: *const Copier, index: u32) bool {
    assert(index < copier.tree.node_count);
    assert(copier.plan.target < copier.plan.base);

    if (index == copier.plan.target) return true;
    return index >= copier.plan.base;
}

fn alias_emit(copier: *Copier, home: u32, child: Child) Tree.EditError!void {
    assert(home < copier.tree.node_count);
    assert(copier.depth > 0);
    assert(child.source < copier.plan.copy.document.node_count);

    const commented = if (child.mode == .raw) child.source else none;
    const index = try copier.tree.record_reserve();

    copier.tree.records[index] = .{
        .anchor = text_empty,
        .count = 0,
        .first = none,
        .flags = .{},
        .kind = .alias,
        .last = home,
        .next = none,
        .parent = none,
        .style = 0,
        .tag = text_empty,
        .text = text_empty,
    };

    child_link(copier, index);

    if (commented != none) try comments_carry(copier, .{ .source = commented, .target = index });
}

const Carry = struct {
    source: u32,
    target: u32,
};

fn comments_carry(copier: *Copier, carry: Carry) Tree.EditError!void {
    assert(carry.target < copier.tree.node_count);
    assert(carry.source < copier.plan.copy.document.node_count);

    const index = carry.target;
    const source = carry.source;
    const tree = copier.tree;
    const document = copier.plan.copy.document;

    if (document.storage.nodes[source].markers.blank_before) {
        tree.records[index].flags.blank_before = true;
    }

    if (document.comment_count == 0) return;

    const slots = document.storage.comments[0..document.comment_count];
    const range = comment_module.range_of(slots, source);
    const count = range.end - range.first;
    if (count == 0) return;
    if (count > tree.comment_slots.len - tree.comment_count) return error.CommentsExhausted;

    var bytes: u64 = 0;

    for (slots[range.first..range.end]) |*slot| bytes += slot.text.len;

    try tree.text_room_check(bytes);

    for (slots[range.first..range.end]) |*slot| {
        var carried = slot.*;

        carried.node = index;
        carried.text = tree.text_at(tree.text_append(slot.text));
        tree.comment_slots[tree.comment_count] = carried;
        tree.comment_count += 1;
    }

    assert(tree.comment_count >= count);
}

fn child_link(copier: *Copier, index: u32) void {
    assert(copier.depth > 0);
    assert(index < copier.tree.node_count);

    const records = copier.tree.records;
    const frame = &copier.frames[copier.depth - 1];
    const key = frame.mapping and frame.count % 2 == 0;

    records[index].flags = .{ .key = key };
    records[index].next = none;
    records[index].parent = frame.container;

    if (frame.count == 0) {
        frame.first = index;
    } else {
        records[frame.last].next = index;
    }

    frame.last = index;
    frame.count += 1;
}

fn frame_open(copier: *Copier, index: u32, child: Child) Tree.EditError!void {
    assert(index < copier.tree.node_count);
    assert(child.source < copier.plan.copy.document.node_count);

    const record = &copier.plan.copy.document.storage.nodes[child.source];
    if (record.kind == .scalar) return;
    if (copier.plan.level + copier.depth + 1 > depth_max) return error.DepthExceeded;

    const frame = &copier.frames[copier.depth];

    frame.* = .{
        .container = index,
        .count = 0,
        .cursor = child.source + 1,
        .end = child.source + record.span,
        .entries = undefined,
        .first = none,
        .last = none,
        .list = &.{},
        .mapping = record.kind == .mapping,
        .mode = child.mode,
        .pending = none,
        .phase = .rest,
        .position = 0,
        .source = child.source,
    };

    if (frame.mapping) try frame_merge_prepare(copier, frame);

    copier.depth += 1;
}

fn frame_merge_prepare(copier: *Copier, frame: *CopyFrame) Tree.EditError!void {
    assert(frame.mapping);
    assert(frame.list.len == 0);

    if (copier.plan.copy.merge == .ignored) return;

    const document = copier.plan.copy.document;
    const mapping: DocumentNode = @fromBackingInt(frame.source);
    if (merge.value_of(Document, document, mapping) == null) return;

    frame.list = try copier.sources.flatten(document, mapping);
    frame.phase = .own;
}

fn frame_close(copier: *Copier) void {
    assert(copier.depth > 0);
    assert(copier.depth <= depth_max);

    copier.depth -= 1;

    const frame = &copier.frames[copier.depth];
    const records = copier.tree.records;
    const container = &records[frame.container];

    if (frame.count > 0) {
        container.first = frame.first;
        container.last = frame.last;
    }

    container.count = if (frame.mapping) @divExact(frame.count, 2) else frame.count;

    copier.sources.pop(frame.list);
}

fn child_next(copier: *Copier, frame: *CopyFrame) Tree.EditError!Child {
    assert(frame.cursor <= frame.end);
    assert(frame.position <= frame.list.len);

    if (frame.pending != none) {
        const pending = frame.pending;

        frame.pending = none;

        return .{ .mode = .expanded, .source = pending };
    }

    for (0..3) |_| {
        switch (frame.phase) {
            .merged => {
                const merged = merged_next(copier, frame);
                if (merged.source != none) return merged;
            },
            .own => {
                if (!try merge_entry_skip(copier, frame)) return own_next(copier, frame);
            },
            .rest => return own_next(copier, frame),
        }
    }

    unreachable;
}

fn own_next(copier: *const Copier, frame: *CopyFrame) Child {
    assert(frame.cursor <= frame.end);
    assert(frame.end <= copier.plan.copy.document.node_count);

    if (frame.cursor == frame.end) return .{ .mode = frame.mode, .source = none };

    const result = frame.cursor;

    frame.cursor += copier.plan.copy.document.storage.nodes[result].span;

    assert(frame.cursor <= frame.end);

    return .{ .mode = frame.mode, .source = result };
}

fn merge_entry_skip(copier: *Copier, frame: *CopyFrame) Tree.EditError!bool {
    assert(frame.phase == .own);
    assert(frame.mapping);

    if (frame.cursor == frame.end) return false;
    if (frame.count % 2 != 0) return false;

    const document = copier.plan.copy.document;
    const nodes = document.storage.nodes;
    const key = frame.cursor;
    const resolved: DocumentNode = @fromBackingInt(storage_module.resolved(nodes, key));
    if (!merge.entry_merge_is(Document, document, resolved)) return false;

    const value = key + nodes[key].span;
    const after = value + nodes[value].span;

    if (frame.mode == .raw) try dropped_check(copier, key);

    frame.cursor = after;

    if (frame.list.len == 0) {
        frame.phase = .rest;
    } else {
        frame.entries = document.entries(frame.list[0]);
        frame.phase = .merged;
        frame.position = 0;
    }

    return true;
}

fn dropped_check(copier: *Copier, key: u32) Tree.ValueError!void {
    assert(key < copier.plan.copy.document.node_count);
    assert(copier.plan.document <= copier.tree.node_count);

    const tree = copier.tree;
    const nodes = copier.plan.copy.document.storage.nodes;
    const value = key + nodes[key].span;
    const after = value + nodes[value].span;

    for (nodes[key..after], key..) |*record, index| {
        if (record.kind == .alias) continue;
        if (record.anchor.len == 0) continue;

        const home = tree.anchor_lookup(copier.plan.document, record.anchor);
        if (home == none) continue;

        if (part_of_copy(copier, home)) {
            copier.failure = @intCast(index);

            return error.AnchorDuplicate;
        }
    }
}

fn merged_next(copier: *const Copier, frame: *CopyFrame) Child {
    assert(frame.phase == .merged);
    assert(frame.position < frame.list.len);

    const document = copier.plan.copy.document;
    const step_count_max = document.node_count + merge.source_count_max + 1;

    for (0..step_count_max) |_| {
        const entry = frame.entries.next() orelse {
            frame.position += 1;

            if (frame.position == frame.list.len) {
                frame.phase = .rest;

                return .{ .mode = .expanded, .source = none };
            }

            frame.entries = document.entries(frame.list[frame.position]);

            continue;
        };

        if (merge.entry_merge_is(Document, document, entry.key)) continue;
        if (!merged_visible(copier, frame, entry.key)) continue;

        frame.pending = @backingInt(entry.value);

        return .{ .mode = .expanded, .source = @backingInt(entry.key) };
    }

    unreachable;
}

fn merged_visible(copier: *const Copier, frame: *const CopyFrame, key: DocumentNode) bool {
    assert(frame.phase == .merged);
    assert(@backingInt(key) < copier.plan.copy.document.node_count);

    const document = copier.plan.copy.document;
    const text = document.text_of(key) orelse return true;
    const mapping: DocumentNode = @fromBackingInt(frame.source);
    const earlier = frame.list[0..frame.position];

    return merge.visible(Document, document, mapping, earlier, text);
}

noinline fn records_write(
    records: []const Record,
    text: []const u8,
    writer: *Writer,
    start: u32,
) align(64) Writer.Error!void {
    assert(start < records.len);
    assert(text.len <= std.math.maxInt(u32));
    assert(writer.depth == 0);

    var frames: [depth_max]WriteFrame = undefined;
    var depth: u32 = 0;

    if (try record_write(records, text, writer, start)) {
        frames[0] = frame_of(records, start);
        depth = 1;
    }

    for (0..2 * records.len) |_| {
        if (depth == 0) return;

        const frame = &frames[depth - 1];

        if (frame.remaining == 0) {
            depth -= 1;

            try collection_end_write(writer, frame.mapping);

            continue;
        }

        const child = frame.cursor;

        frame.cursor = records[child].next;
        frame.remaining -= 1;

        if (try record_write(records, text, writer, child)) {
            assert(depth < depth_max);

            frames[depth] = frame_of(records, child);
            depth += 1;
        }
    }

    unreachable;
}

inline fn frame_of(records: []const Record, index: u32) WriteFrame {
    assert(index < records.len);
    assert(records[index].count > 0);

    const record = &records[index];

    return .{
        .cursor = record.first,
        .mapping = record.kind == .mapping,
        .remaining = child_count_of(record),
    };
}

inline fn record_write(
    records: []const Record,
    text: []const u8,
    writer: *Writer,
    index: u32,
) Writer.Error!bool {
    assert(index < records.len);
    assert(text.len <= std.math.maxInt(u32));
    assert(!records[index].flags.detached);

    const record = &records[index];

    switch (record.kind) {
        .alias => {
            const home = &records[record.last];

            try writer.alias(&.{ .anchor = text_slice(text, home.anchor) });

            return false;
        },
        .mapping, .sequence => {
            const properties: Event.CollectionStart = .{
                .anchor = text_slice(text, record.anchor),
                .style = @fromBackingInt(@intCast(record.style)),
                .tag = text_slice(text, record.tag),
            };

            const mapping = record.kind == .mapping;

            if (mapping) {
                try writer.mapping_begin(&properties);
            } else {
                try writer.sequence_begin(&properties);
            }

            if (record.count > 0) return true;

            try collection_end_write(writer, mapping);

            return false;
        },
        .scalar => {
            try writer.scalar(&.{
                .anchor = text_slice(text, record.anchor),
                .style = @fromBackingInt(@intCast(record.style)),
                .tag = text_slice(text, record.tag),
                .text = text_slice(text, record.text),
            });

            return false;
        },
        .stream => unreachable,
    }
}

fn collection_begin_write(
    writer: *Writer,
    text: []const u8,
    record: *const Record,
) Writer.Error!void {
    assert(record.kind == .mapping or record.kind == .sequence);
    assert(text.len <= std.math.maxInt(u32));

    const properties: Event.CollectionStart = .{
        .anchor = text_slice(text, record.anchor),
        .style = @fromBackingInt(@intCast(record.style)),
        .tag = text_slice(text, record.tag),
    };

    if (record.kind == .mapping) {
        try writer.mapping_begin(&properties);
    } else {
        try writer.sequence_begin(&properties);
    }
}

inline fn text_slice(text: []const u8, span: Text) []const u8 {
    assert(span.offset <= text.len);
    assert(span.length <= text.len - span.offset);

    return text[span.offset..][0..span.length];
}

fn collection_end_write(writer: *Writer, mapping: bool) Writer.Error!void {
    assert(writer.depth > 0);
    assert(writer.depth <= writer_module.depth_max);

    if (mapping) {
        try writer.mapping_end();
    } else {
        try writer.sequence_end();
    }
}

fn piece_of(content: *const Tree.Content, buffer: *[codec.float_bytes_max]u8) Piece {
    assert(content.* != .copy);
    assert(buffer.len == codec.float_bytes_max);

    return switch (content.*) {
        .alias => .{
            .anchor = "",
            .home = none,
            .kind = .alias,
            .style = 0,
            .tag = "",
            .text = "",
        },
        .boolean => |value| plain_piece_of(if (value) "true" else "false"),
        .copy => unreachable,
        .float => |value| float: {
            const finite = std.math.isFinite(value);
            if (!finite) break :float plain_piece_of(float_special_text_of(value));

            break :float plain_piece_of(codec.float_text_render(f64, buffer, value));
        },
        .integer => |value| integer: {
            const text = std.mem.print(buffer, "{d}", .{value}) catch |err| switch (err) {
                error.NoSpaceLeft => unreachable,
            };

            break :integer plain_piece_of(text);
        },
        .mapping => |*properties| collection_piece_of(properties, .mapping),
        .null_value => plain_piece_of("null"),
        .scalar => |*scalar| .{
            .anchor = scalar.anchor,
            .home = none,
            .kind = .scalar,
            .style = @backingInt(scalar.style),
            .tag = scalar.tag,
            .text = scalar.text,
        },
        .sequence => |*properties| collection_piece_of(properties, .sequence),
        .string => |text| .{
            .anchor = "",
            .home = none,
            .kind = .scalar,
            .style = @backingInt(schema_module.string_style_of(text)),
            .tag = "",
            .text = text,
        },
    };
}

fn plain_piece_of(text: []const u8) Piece {
    assert(text.len > 0);
    assert(text.len <= codec.float_bytes_max);

    return .{
        .anchor = "",
        .home = none,
        .kind = .scalar,
        .style = @backingInt(ScalarStyle.plain),
        .tag = "",
        .text = text,
    };
}

fn collection_piece_of(properties: *const Event.CollectionStart, kind: Record.Kind) Piece {
    assert(container_is(kind));
    assert(kind != .stream);

    return .{
        .anchor = properties.anchor,
        .home = none,
        .kind = kind,
        .style = @backingInt(properties.style),
        .tag = properties.tag,
        .text = "",
    };
}

fn float_special_text_of(value: f64) []const u8 {
    assert(!std.math.isFinite(value));

    if (std.math.isNan(value)) return ".nan";
    return if (value > 0) ".inf" else "-.inf";
}

fn piece_bytes(piece: *const Piece) u64 {
    assert(piece.kind != .stream);
    if (piece.kind == .alias) assert(piece.text.len == 0);

    return @as(u64, piece.anchor.len) + piece.tag.len + piece.text.len;
}

fn content_bytes(content: *const Tree.Content) u64 {
    assert(@sizeOf(Tree.Content) <= 128);
    assert(source_bytes_max < none);

    const result: u64 = switch (content.*) {
        .alias, .boolean, .copy, .float, .integer, .null_value => 0,
        .mapping, .sequence => |*properties| properties.anchor.len + properties.tag.len,
        .scalar => |*scalar| scalar.anchor.len + scalar.tag.len + scalar.text.len,
        .string => |text| text.len,
    };

    assert(result <= 3 * @as(u64, source_bytes_max));

    return result;
}

fn record_kind_of(kind: storage_module.NodeKind) Record.Kind {
    assert(kind != .alias);
    assert(@typeInfo(storage_module.NodeKind).@"enum".field_names.len == 4);

    return switch (kind) {
        .alias => unreachable,
        .mapping => .mapping,
        .scalar => .scalar,
        .sequence => .sequence,
    };
}

fn anchor_valid_is(name: []const u8) bool {
    assert(name.len <= source_bytes_max);
    assert(scanner_module.depth_max > 0);

    if (name.len == 0) return false;
    if (!std.unicode.utf8ValidateSlice(name)) return false;

    var view = std.unicode.Utf8View.initUnchecked(name);
    var iterator = view.iterator();

    for (0..name.len) |_| {
        const codepoint = iterator.nextCodepoint() orelse return true;
        if (!anchor_codepoint_is(codepoint)) return false;
    }

    return iterator.nextCodepoint() == null;
}

fn anchor_codepoint_is(codepoint: u21) bool {
    assert(codepoint <= 0x10ffff);
    assert(codepoint < 0xd800 or codepoint > 0xdfff);

    if (codepoint < 0x80) {
        if (codepoint <= 0x20) return false;
        if (codepoint == 0x7f) return false;
        return std.mem.findScalar(u8, ",[]{}", @intCast(codepoint)) == null;
    }

    if (codepoint == 0x85) return true;
    if (codepoint < 0xa0) return false;
    if (codepoint <= 0xd7ff) return true;
    if (codepoint == 0xfeff) return false;
    if (codepoint <= 0xfffd) return true;
    return codepoint >= 0x10000;
}

fn anchored_is(record: *const Record) bool {
    assert(@backingInt(record.kind) <= @backingInt(Record.Kind.stream));
    if (record.kind == .alias) assert(record.anchor.length == 0);

    return record.anchor.length > 0;
}

fn container_is(kind: Record.Kind) bool {
    assert(@backingInt(kind) <= @backingInt(Record.Kind.stream));
    assert(@typeInfo(Record.Kind).@"enum".field_names.len == 5);

    return switch (kind) {
        .alias, .scalar => false,
        .mapping, .sequence, .stream => true,
    };
}

fn child_count_of(record: *const Record) u32 {
    assert(@backingInt(record.kind) <= @backingInt(Record.Kind.stream));
    assert(record.count < node_count_limit);

    const result = switch (record.kind) {
        .alias, .scalar => 0,
        .mapping => 2 * record.count,
        .sequence, .stream => record.count,
    };

    if (result > 0) assert(record.first != none);
    if (result > 0) assert(record.last != none);

    return result;
}

fn anchor_hash(document: u32, name: []const u8) u32 {
    assert(name.len > 0);
    assert(document < none);

    const hash = std.hash.Wyhash.hash(document, name);
    const result: u32 = @truncate(hash);

    assert(result == hash & std.math.maxInt(u32));

    return result;
}

fn anchor_count_max_of(tree: *const Tree) u32 {
    assert(tree.anchors.len >= 2);
    assert(std.math.isPowerOfTwo(tree.anchors.len));

    return @intCast(@divExact(tree.anchors.len, 2));
}

fn anchor_slot_count_of(anchor_count_max: u32) u32 {
    assert(anchor_count_max > 0);
    assert(anchor_count_max <= anchor_count_limit);

    const result = 2 * std.math.ceilPowerOfTwoAssert(u32, anchor_count_max);

    assert(result >= 2 * anchor_count_max);

    return result;
}

const testing = std.testing;

const test_capacity: Capacity = .{
    .anchor_count_max = 16,
    .comment_count_max = null,
    .node_count_max = 256,
    .text_bytes_max = 4096,
};

const test_json_options: JSONOptions = .{
    .merge = .ignored,
    .node_count_max = 256,
    .non_finite = .refused,
};

const test_output_bytes: u32 = 8192;

const test_write_options: Writer.Options = .{
    .indent = 2,
    .layout = .preserve,
    .sequence_indentless = false,
    .utf8 = .checked,
    .version_directive = false,
    .width = 0,
};

const test_write_sets = [_]Writer.Options{
    test_write_options,
    .{
        .indent = 4,
        .layout = .block,
        .sequence_indentless = true,
        .utf8 = .checked,
        .version_directive = false,
        .width = 0,
    },
    .{
        .indent = 1,
        .layout = .flow,
        .sequence_indentless = false,
        .utf8 = .checked,
        .version_directive = true,
        .width = 0,
    },
    .{
        .indent = 3,
        .layout = .preserve,
        .sequence_indentless = true,
        .utf8 = .checked,
        .version_directive = false,
        .width = 0,
    },
};

const TestDocument = document_module.DocumentType(test_capacity);

const TestOperation = enum {
    append,
    insert,
    remove,
    replace,
    root_append,
    set,
};

const TestRefusal = struct {
    content: Tree.Content,
    expected: Tree.EditError,
    operation: TestOperation,
    target: Tree.Node,
};

const TestSnapshot = struct {
    anchor_count: u32,
    length: u32,
    node_count: u32,
    text_count: u32,
};

const TestTree = TreeType(test_capacity);

const TestFixture = struct {
    document: TestDocument,
    output: [test_output_bytes]u8,
    reference: [test_output_bytes]u8,
    reparsed: TestDocument,
    tree: TestTree,

    fn create() !*TestFixture {
        assert(test_output_bytes > 0);
        assert(test_capacity.node_count_max > 0);

        const fixture = try testing.allocator.create(TestFixture);

        fixture.tree.init(.{ .schema = .core });

        return fixture;
    }

    fn parsed(fixture: *TestFixture, source: []const u8) !*const Document {
        assert(source.len < test_capacity.text_bytes_max);
        assert(fixture.document.storage.nodes.len == test_capacity.node_count_max);

        try fixture.document.parse(source, .{ .schema = .core });

        return &fixture.document.document;
    }

    fn copied(fixture: *TestFixture, source: []const u8) !Tree.Node {
        assert(source.len < test_capacity.text_bytes_max);
        assert(fixture.tree.tree.node_count > 0);

        const document = try fixture.parsed(source);

        const content: Tree.Content = .{
            .copy = .{ .document = document, .merge = .ignored, .node = document.root(0) },
        };

        return fixture.tree.root_append(content);
    }

    fn written(fixture: *TestFixture, options: Writer.Options) ![]const u8 {
        assert(options.indent >= 1);
        assert(fixture.output.len == test_output_bytes);

        var sink: std.Io.Writer = .fixed(&fixture.output);

        try fixture.tree.write(&sink, options);

        audit(&fixture.tree.tree);

        return sink.buffered();
    }

    fn json(fixture: *TestFixture, options: JSONOptions) ![]const u8 {
        assert(options.node_count_max > 0);
        assert(fixture.output.len == test_output_bytes);

        var sink: std.Io.Writer = .fixed(&fixture.output);

        try fixture.tree.write_json(&sink, options);

        return sink.buffered();
    }

    fn snapshot(fixture: *TestFixture) !TestSnapshot {
        assert(fixture.reference.len == test_output_bytes);
        assert(fixture.tree.tree.node_count > 0);

        const text = try fixture.written(test_write_options);

        @memcpy(fixture.reference[0..text.len], text);

        return .{
            .anchor_count = fixture.tree.tree.anchor_count,
            .length = @intCast(text.len),
            .node_count = fixture.tree.tree.node_count,
            .text_count = fixture.tree.tree.text_count,
        };
    }

    fn unchanged(fixture: *TestFixture, before: *const TestSnapshot) !void {
        assert(before.length <= test_output_bytes);
        assert(before.node_count > 0);

        const tree = &fixture.tree.tree;

        try testing.expectEqual(before.anchor_count, tree.anchor_count);
        try testing.expectEqual(before.node_count, tree.node_count);
        try testing.expectEqual(before.text_count, tree.text_count);

        const text = try fixture.written(test_write_options);

        try testing.expectEqualStrings(fixture.reference[0..before.length], text);
    }

    fn refused(fixture: *TestFixture, refusals: []const TestRefusal) !void {
        assert(refusals.len > 0);
        assert(fixture.tree.tree.node_count > 0);

        const before = try fixture.snapshot();

        for (refusals) |*refusal| {
            const result = test_edit(&fixture.tree, refusal);

            try testing.expectError(refusal.expected, result);
            try fixture.unchanged(&before);
        }
    }
};

fn test_edit(tree: *TestTree, refusal: *const TestRefusal) Tree.EditError!void {
    assert(@backingInt(refusal.target) < tree.tree.node_count);
    assert(!tree.tree.records[@backingInt(refusal.target)].flags.detached);

    const content = refusal.content;
    const target = refusal.target;

    switch (refusal.operation) {
        .append => _ = try tree.append(target, content),
        .insert => _ = try tree.insert(target, 0, content),
        .remove => try tree.remove(target),
        .replace => try tree.replace(target, content),
        .root_append => _ = try tree.root_append(content),
        .set => _ = try tree.set(target, "z", content),
    }
}

test Tree {
    const TestStorage = Tree.StorageType(test_capacity);
    const storage = try testing.allocator.create(TestStorage);
    defer testing.allocator.destroy(storage);

    var tree: Tree = undefined;

    tree.init(storage.storage(), .{ .schema = .core });

    const root = try tree.root_append(.{ .mapping = .{ .style = .block } });
    const sequence: Event.CollectionStart = .{ .anchor = "ports", .style = .flow };
    const ports = try tree.set(root, "ports", .{ .sequence = sequence });
    const name = try tree.set(root, "name", .{ .string = "warbler" });
    const last = try tree.append(ports, .{ .integer = 8443 });
    const first = try tree.insert(ports, 0, .{ .integer = 8080 });
    const mirror = try tree.set(root, "mirror", .{ .alias = ports });
    const ratio = try tree.set(root, "ratio", .{ .float = 0.5 });
    const renamed = try tree.set(root, "name", .{ .string = "yes" });

    try testing.expectEqual(name, renamed);
    try testing.expectEqual(@as(?f64, 0.5), tree.float_of(ratio));
    try testing.expectEqual(@as(?Tree.Node, ports), tree.alias_of(mirror));
    try testing.expectEqual(@as(?Tree.Node, first), tree.item(mirror, 0));
    try testing.expectEqual(@as(?Tree.Node, last), tree.path_find(root, &.{ "mirror", "1" }));

    const refused = tree.remove(ports);

    try testing.expectError(error.AnchorReferenced, refused);
    try testing.expectEqual(@as(u32, 0), tree.diagnostic.line);
    try testing.expectEqual(@as(?[]const u8, null), tree.text_of(root));

    var buffer: [256]u8 = undefined;
    var sink: std.Io.Writer = .fixed(&buffer);

    try tree.write(&sink, .{
        .indent = 2,
        .layout = .preserve,
        .sequence_indentless = false,
        .utf8 = .checked,
        .version_directive = false,
        .width = 0,
    });

    const written = "ports: &ports [8080, 8443]\nname: 'yes'\nmirror: *ports\nratio: 0.5\n";

    try testing.expectEqualStrings(written, sink.buffered());

    sink = .fixed(&buffer);

    try tree.write_json(&sink, .{
        .merge = .ignored,
        .node_count_max = 64,
        .non_finite = .refused,
    });

    const json = "{\"ports\":[8080,8443],\"name\":\"yes\",\"mirror\":[8080,8443],\"ratio\":0.5}\n";

    try testing.expectEqualStrings(json, sink.buffered());
}

test TreeType {
    const document = try testing.allocator.create(TestDocument);
    defer testing.allocator.destroy(document);

    const tree = try testing.allocator.create(TreeType(test_capacity));
    defer testing.allocator.destroy(tree);

    try document.parse(
        \\defaults: &defaults {replicas: 2, image: base}
        \\web: {<<: *defaults, image: nginx}
        \\
    , .{ .schema = .core });

    tree.init(.{ .schema = .core });

    const root = try tree.root_append(.{ .copy = .{
        .document = &document.document,
        .merge = .applied,
        .node = document.root(0),
    } });

    const web = tree.member(root, "web") orelse return error.WebMissing;
    const defaults = tree.member(root, "defaults") orelse return error.DefaultsMissing;
    const replicas = tree.member(web, "replicas") orelse return error.ReplicasMissing;

    try testing.expectEqual(@as(?i64, 2), tree.integer_of(replicas));
    try testing.expectEqualStrings("defaults", tree.anchor_of(defaults));

    try tree.remove(defaults);
    try tree.replace(replicas, .{ .integer = 3 });

    _ = try tree.set(web, "image", .{ .string = "caddy" });

    var buffer: [256]u8 = undefined;
    var sink: std.Io.Writer = .fixed(&buffer);

    try tree.write(&sink, .{
        .indent = 2,
        .layout = .block,
        .sequence_indentless = false,
        .utf8 = .checked,
        .version_directive = false,
        .width = 0,
    });

    try testing.expectEqualStrings("web:\n  replicas: 3\n  image: caddy\n", sink.buffered());
    try testing.expectEqual(@as(?[]const u8, null), tree.text_of(web));

    try document.parse("bad: {<<: 3}\n", .{ .schema = .core });

    const refused = tree.root_append(.{ .copy = .{
        .document = &document.document,
        .merge = .applied,
        .node = document.root(0),
    } });

    try testing.expectError(error.MergeInvalid, refused);
    try testing.expectEqual(Position{ .column = 11, .line = 1, .offset = 10 }, tree.diagnostic());
}

test "a copy writes byte for byte what the document writes, under every writer option set" {
    const fixture = try TestFixture.create();
    defer testing.allocator.destroy(fixture);

    const sources = [_][]const u8{
        "a: 1\nb: [x, y]\nc: {d: e}\n",
        "%YAML 1.2\n--- !shape\n- &a [1, 2]\n- *a\n- {? [k] : v, *a : w}\n...\n--- &a z\n",
        "plain: text\nsingle: 'it''s'\ndouble: \"tab\\tx\"\nliteral: |\n  line\n  next\n" ++
            "folded: >-\n  folded\n  text\nempty:\n",
        "--- |\n  root literal\n---\n...\n",
        "[a, {b: c}, [d, [e]], !!str 12, &x y, *x, !local {}]\n",
        "? a\n? b\n: c\n? - complex\n: value\n",
        "",
    };

    for (sources) |source| {
        const document = try fixture.parsed(source);

        fixture.tree.init(.{ .schema = .core });

        for (0..document.root_count()) |index| {
            const node = document.root(@intCast(index));

            _ = try fixture.tree.root_append(.{
                .copy = .{ .document = document, .merge = .ignored, .node = node },
            });
        }

        for (test_write_sets) |options| {
            var sink: std.Io.Writer = .fixed(&fixture.reference);

            try document.write(&sink, options);
            try testing.expectEqualStrings(sink.buffered(), try fixture.written(options));
        }
    }
}

test "a copy keeps the aliases inside the copied range and expands the ones that leave it" {
    const fixture = try TestFixture.create();
    defer testing.allocator.destroy(fixture);

    const document = try fixture.parsed("base: &b {x: 1}\nholder: [*b, &i 2, *i]\n");
    const holder = document.member(document.root(0), "holder") orelse return error.HolderMissing;

    const copy = try fixture.tree.root_append(.{
        .copy = .{ .document = document, .merge = .ignored, .node = holder },
    });

    const tree = &fixture.tree;
    const expanded = tree.item(copy, 0) orelse return error.ItemMissing;
    const home = tree.item(copy, 1) orelse return error.ItemMissing;
    const alias = tree.item(copy, 2) orelse return error.ItemMissing;

    try testing.expectEqualStrings("", tree.anchor_of(expanded));
    try testing.expectEqual(@as(?Tree.Node, null), tree.alias_of(expanded));
    try testing.expectEqual(@as(?Tree.Node, home), tree.alias_of(alias));
    try testing.expectEqualStrings("[{x: 1}, &i 2, *i]\n", try fixture.written(test_write_options));
}

test "a copy that would register an anchor twice is AnchorDuplicate and changes nothing" {
    const fixture = try TestFixture.create();
    defer testing.allocator.destroy(fixture);

    const root = try fixture.copied("kept: &x 0\n");
    const before = try fixture.snapshot();
    const redefined = fixture.copied("a: &x 1\nb: &x 2\nc: *x\n");

    try testing.expectError(error.AnchorDuplicate, redefined);
    try fixture.unchanged(&before);

    const document = try fixture.parsed("&x [1]\n");

    const content: Tree.Content = .{
        .copy = .{ .document = document, .merge = .ignored, .node = document.root(0) },
    };

    const refusal: TestRefusal = .{
        .content = content,
        .expected = error.AnchorDuplicate,
        .operation = .set,
        .target = root,
    };

    try fixture.refused(&.{refusal});

    _ = try fixture.tree.root_append(content);

    const written = try fixture.written(test_write_options);

    try testing.expectEqualStrings("kept: &x 0\n--- &x [1]\n", written);
}

test "a copy with merges applied holds what write_json shows with merges applied" {
    const fixture = try TestFixture.create();
    defer testing.allocator.destroy(fixture);

    const document = try fixture.parsed(
        \\base: &base {a: 1, b: 2}
        \\more: &more {b: 3, c: 4}
        \\one: {<<: *base, a: 9}
        \\many: {x: 0, <<: [*more, *base], c: 5}
        \\nested: {inner: {<<: *base}}
        \\
    );

    const content: Tree.Content = .{
        .copy = .{ .document = document, .merge = .applied, .node = document.root(0) },
    };

    const root = try fixture.tree.root_append(content);
    var sink: std.Io.Writer = .fixed(&fixture.reference);

    try document.write_json(&sink, .{
        .merge = .applied,
        .node_count_max = 256,
        .non_finite = .refused,
    });

    try testing.expectEqualStrings(sink.buffered(), try fixture.json(test_json_options));

    const base = fixture.tree.member(root, "base") orelse return error.BaseMissing;

    try fixture.tree.remove(base);

    const written =
        \\more: &more {b: 3, c: 4}
        \\one: {b: 2, a: 9}
        \\many: {x: 0, b: 3, a: 1, c: 5}
        \\nested: {inner: {a: 1, b: 2}}
        \\
    ;

    try testing.expectEqualStrings(written, try fixture.written(test_write_options));

    const invalid = try fixture.parsed("a: {<<: 1}\n");

    const refusal: TestRefusal = .{
        .content = .{
            .copy = .{ .document = invalid, .merge = .applied, .node = invalid.root(0) },
        },
        .expected = error.MergeInvalid,
        .operation = .root_append,
        .target = root,
    };

    try fixture.refused(&.{refusal});
}

test "set replaces the value of an existing key and keeps its handle" {
    const fixture = try TestFixture.create();
    defer testing.allocator.destroy(fixture);

    const tree = &fixture.tree;
    const root = try tree.root_append(.{ .mapping = .{ .style = .block } });
    const first = try tree.set(root, "port", .{ .integer = 80 });
    const second = try tree.set(root, "port", .{ .integer = 8080 });
    const quoted = try tree.set(root, "null", .{ .boolean = true });

    _ = try tree.set(root, "two\nlines", .null_value);

    try testing.expectEqual(first, second);
    try testing.expectEqual(@as(u32, 3), tree.count_of(root));
    try testing.expectEqual(@as(?i64, 8080), tree.integer_of(second));
    try testing.expectEqual(@as(?Tree.Node, quoted), tree.member(root, "null"));
    try testing.expectEqual(@as(?bool, true), tree.boolean_of(quoted));

    const written = "port: 8080\n'null': true\n\"two\\nlines\": null\n";

    try testing.expectEqualStrings(written, try fixture.written(test_write_options));
}

test "handles stay with their nodes while the tree around them is edited" {
    const fixture = try TestFixture.create();
    defer testing.allocator.destroy(fixture);

    const tree = &fixture.tree;
    const root = try fixture.copied("a: [1, 2]\nb: {c: d}\ne: f\n");
    const list = tree.member(root, "a") orelse return error.ListMissing;
    const inner = tree.member(root, "b") orelse return error.InnerMissing;
    const tail = tree.member(root, "e") orelse return error.TailMissing;
    const item = tree.item(list, 1) orelse return error.ItemMissing;

    _ = try tree.insert(list, 0, .{ .integer = 0 });
    _ = try tree.set(root, "g", .{ .string = "h" });
    _ = try tree.set(inner, "c", .{ .sequence = .{ .style = .flow } });

    try tree.remove(tree.item(list, 1) orelse return error.ItemMissing);
    try tree.replace(tail, .{ .string = "replaced" });
    try testing.expectEqual(@as(?Tree.Node, item), tree.item(list, 1));
    try testing.expectEqualStrings("2", tree.text_of(item).?);
    try testing.expectEqualStrings("replaced", tree.text_of(tail).?);
    try testing.expectEqual(@as(?Tree.Node, tail), tree.member(root, "e"));

    const written = "a: [0, 2]\nb: {c: []}\ne: replaced\ng: h\n";

    try testing.expectEqualStrings(written, try fixture.written(test_write_options));
}

test "insert places an item at every position, and remove takes it back out" {
    const fixture = try TestFixture.create();
    defer testing.allocator.destroy(fixture);

    const tree = &fixture.tree;
    const root = try tree.root_append(.{ .sequence = .{ .style = .flow } });
    const middle = try tree.insert(root, 0, .{ .integer = 2 });
    const front = try tree.insert(root, 0, .{ .integer = 0 });
    const back = try tree.append(root, .{ .integer = 4 });
    const second = try tree.insert(root, 1, .{ .integer = 1 });
    const fourth = try tree.insert(root, 3, .{ .integer = 3 });

    try testing.expectEqualStrings("[0, 1, 2, 3, 4]\n", try fixture.written(test_write_options));

    const removals = [_]Tree.Node{ middle, front, back, second, fourth };
    const remaining = [_][]const u8{ "[0, 1, 3, 4]\n", "[1, 3, 4]\n", "[1, 3]\n", "[3]\n", "[]\n" };

    for (removals, remaining) |node, text| {
        try tree.remove(node);
        try testing.expectEqualStrings(text, try fixture.written(test_write_options));
        try testing.expect(tree.tree.records[@backingInt(node)].flags.detached);
    }
}

test "remove takes a whole entry from its key or its value, and a root takes its document" {
    const fixture = try TestFixture.create();
    defer testing.allocator.destroy(fixture);

    const tree = &fixture.tree;
    const root = try fixture.copied("a: 1\nb: [2]\nc: 3\n");
    var entries = tree.entries(root);
    const first = entries.next() orelse return error.EntryMissing;
    const second = entries.next() orelse return error.EntryMissing;
    const records = tree.tree.records;

    try tree.remove(first.key);
    try tree.remove(second.value);
    try testing.expect(records[@backingInt(first.value)].flags.detached);
    try testing.expect(records[@backingInt(second.key)].flags.detached);
    try testing.expect(records[@backingInt(second.value) + 1].flags.detached);
    try testing.expectEqualStrings("c: 3\n", try fixture.written(test_write_options));

    const kept = try fixture.copied("--- x\n...\n");

    try tree.remove(root);
    try testing.expectEqual(@as(u32, 1), tree.root_count());
    try testing.expectEqual(kept, tree.root(0));
    try testing.expectEqualStrings("--- x\n...\n", try fixture.written(test_write_options));
}

test "edits through an alias reach the shared node, and replace and remove act on the alias" {
    const fixture = try TestFixture.create();
    defer testing.allocator.destroy(fixture);

    const tree = &fixture.tree;
    const root = try fixture.copied("base: &b {x: 1}\nuse: *b\nlist: &l [1]\nmore: *l\n");
    const base = tree.member(root, "base") orelse return error.BaseMissing;
    const use = tree.member(root, "use") orelse return error.UseMissing;
    const more = tree.member(root, "more") orelse return error.MoreMissing;

    _ = try tree.set(use, "w", .{ .integer = 2 });
    _ = try tree.append(more, .{ .integer = 2 });

    const shared = "base: &b {x: 1, w: 2}\nuse: *b\nlist: &l [1, 2]\nmore: *l\n";

    try testing.expectEqualStrings(shared, try fixture.written(test_write_options));
    try testing.expectEqual(@as(u32, 2), tree.count_of(use));

    try tree.replace(use, .{ .string = "plain" });
    try tree.remove(more);
    try tree.remove(base);

    const remaining = try fixture.written(test_write_options);

    try testing.expectEqualStrings("use: plain\nlist: &l [1, 2]\n", remaining);
}

test "text that is not UTF-8, or an anchor that YAML cannot spell, is TextInvalid" {
    const fixture = try TestFixture.create();
    defer testing.allocator.destroy(fixture);

    const root = try fixture.copied("k: v\n");

    const invalid = [_]Tree.Content{
        .{ .string = "\xc3" },
        .{ .scalar = .{ .tag = "!\xff", .text = "x" } },
        .{ .scalar = .{ .anchor = "a b", .text = "x" } },
        .{ .scalar = .{ .anchor = "a,b", .text = "x" } },
        .{ .mapping = .{ .anchor = "[", .style = .flow } },
        .{ .sequence = .{ .anchor = "\u{feff}x", .style = .flow } },
        .{ .scalar = .{ .anchor = "\x7f", .text = "x" } },
    };

    for (invalid) |content| {
        const refusal: TestRefusal = .{
            .content = content,
            .expected = error.TextInvalid,
            .operation = .set,
            .target = root,
        };

        try fixture.refused(&.{refusal});
    }

    const keyed = fixture.tree.set(root, "\xff", .null_value);

    try testing.expectError(error.TextInvalid, keyed);
}

test "an alias whose home is unanchored, or does not come first in its document, is AliasInvalid" {
    const fixture = try TestFixture.create();
    defer testing.allocator.destroy(fixture);

    const tree = &fixture.tree;
    const root = try fixture.copied("base: &b {k: v}\nlist: [&i 1, 2]\n");
    const base = tree.member(root, "base") orelse return error.BaseMissing;
    const value = tree.member(base, "k") orelse return error.ValueMissing;
    const list = tree.member(root, "list") orelse return error.ListMissing;
    const first = tree.item(list, 0) orelse return error.ItemMissing;
    const second = tree.item(list, 1) orelse return error.ItemMissing;

    const refusals = [_]TestRefusal{
        .{
            .content = .{ .alias = second },
            .expected = error.AliasInvalid,
            .operation = .set,
            .target = root,
        },
        .{
            .content = .{ .alias = first },
            .expected = error.AliasInvalid,
            .operation = .insert,
            .target = list,
        },
        .{
            .content = .{ .alias = base },
            .expected = error.AliasInvalid,
            .operation = .set,
            .target = base,
        },
        .{
            .content = .{ .alias = base },
            .expected = error.AliasInvalid,
            .operation = .replace,
            .target = value,
        },
        .{
            .content = .{ .alias = first },
            .expected = error.AliasInvalid,
            .operation = .replace,
            .target = first,
        },
        .{
            .content = .{ .alias = base },
            .expected = error.AliasInvalid,
            .operation = .root_append,
            .target = root,
        },
    };

    try fixture.refused(&refusals);
}

test "an anchor is unique in its document, and an anchor an alias names cannot leave" {
    const fixture = try TestFixture.create();
    defer testing.allocator.destroy(fixture);

    const tree = &fixture.tree;
    const root = try fixture.copied("base: &b {k: v}\nuse: *b\nlist: [&i 1, 2]\n");
    const base = tree.member(root, "base") orelse return error.BaseMissing;
    const list = tree.member(root, "list") orelse return error.ListMissing;
    const second = tree.item(list, 1) orelse return error.ItemMissing;
    const anchored: Tree.Content = .{ .scalar = .{ .anchor = "i", .text = "x" } };
    var entries = tree.entries(root);
    const entry = entries.next() orelse return error.EntryMissing;

    const refusals = [_]TestRefusal{
        .{
            .content = anchored,
            .expected = error.AnchorDuplicate,
            .operation = .replace,
            .target = second,
        },
        .{
            .content = anchored,
            .expected = error.AnchorDuplicate,
            .operation = .append,
            .target = list,
        },
        .{
            .content = .null_value,
            .expected = error.AnchorReferenced,
            .operation = .remove,
            .target = base,
        },
        .{
            .content = .null_value,
            .expected = error.AnchorReferenced,
            .operation = .remove,
            .target = entry.key,
        },
        .{
            .content = .null_value,
            .expected = error.AnchorReferenced,
            .operation = .replace,
            .target = base,
        },
    };

    try fixture.refused(&refusals);

    const before = try fixture.snapshot();
    const shadowed = tree.set(root, "base", .null_value);

    try testing.expectError(error.AnchorReferenced, shadowed);
    try fixture.unchanged(&before);

    const first = tree.item(list, 0) orelse return error.ItemMissing;

    try tree.replace(first, anchored);
    try testing.expectEqual(@as(?Tree.Node, first), tree.item(list, 0));
    try testing.expectEqualStrings("x", tree.text_of(first).?);
}

test "capacity refusals leave the tree unchanged, a failed copy included" {
    const fixture = try TestFixture.create();
    defer testing.allocator.destroy(fixture);

    const Small = TreeType(.{
        .anchor_count_max = 1,
        .comment_count_max = null,
        .node_count_max = 6,
        .text_bytes_max = 16,
    });

    var small: Small = undefined;

    small.init(.{ .schema = .core });

    const root = try small.root_append(.{ .mapping = .{ .anchor = "a", .style = .block } });
    const anchored: Tree.Content = .{ .scalar = .{ .anchor = "b", .text = "v" } };
    const document = try fixture.parsed("x: [1, 2, 3]\n");
    const node_count = small.tree.node_count;
    const text_count = small.tree.text_count;

    const copy: Tree.Content = .{
        .copy = .{ .document = document, .merge = .ignored, .node = document.root(0) },
    };

    const anchors_refused = small.set(root, "k", anchored);
    const text_refused = small.set(root, "a-key-of-twenty-bytes", .null_value);
    const nodes_refused = small.set(root, "k", copy);

    try testing.expectError(error.AnchorsExhausted, anchors_refused);
    try testing.expectError(error.TextExhausted, text_refused);
    try testing.expectError(error.NodesExhausted, nodes_refused);
    try testing.expectEqual(node_count, small.tree.node_count);
    try testing.expectEqual(text_count, small.tree.text_count);
    try testing.expectEqual(@as(u32, 1), small.tree.anchor_count);

    _ = try small.set(root, "b", .{ .integer = 1 });
    _ = try small.set(root, "c", .{ .integer = 2 });

    const full = small.set(root, "d", .{ .integer = 3 });

    try testing.expectError(error.NodesExhausted, full);
    try testing.expectEqual(node_count + 4, small.tree.node_count);
    try testing.expectEqual(text_count + 4, small.tree.text_count);

    audit(&small.tree);
}

test "typed content writes canonical text that reads back as its type under every schema" {
    const fixture = try TestFixture.create();
    defer testing.allocator.destroy(fixture);

    const floats = [_]f64{ 0.5, 1000, 1e300, 5e-324, -0.0, -2.5e-3, 1.5e9, std.math.floatMax(f64) };

    const strings = [_][]const u8{
        "yes",
        "No",
        "null",
        "~",
        "",
        "1e3",
        "0x1F",
        "0o17",
        "12",
        "1_000",
        "<<",
        "=",
        "2001-12-14",
        "a\nb",
        ".inf",
        "true",
    };

    const tree = &fixture.tree;
    const root = try tree.root_append(.{ .sequence = .{ .style = .block } });

    for (floats) |value| _ = try tree.append(root, .{ .float = value });
    for (strings) |text| _ = try tree.append(root, .{ .string = text });

    _ = try tree.append(root, .{ .integer = std.math.minInt(i64) });
    _ = try tree.append(root, .{ .boolean = false });
    _ = try tree.append(root, .null_value);

    const written = try fixture.written(test_write_options);

    for ([_]Schema{ .core, .json, .v1_1 }) |schema| {
        try fixture.reparsed.parse(written, .{ .schema = schema });

        const document = &fixture.reparsed.document;
        var items = document.items(document.root(0));

        for (floats) |value| {
            const node = items.next() orelse return error.ItemMissing;
            const read = document.float_of(node) orelse return error.FloatMissing;

            try testing.expectEqual(@as(u64, @bitCast(value)), @as(u64, @bitCast(read)));
        }

        for (strings) |text| {
            const node = items.next() orelse return error.ItemMissing;
            const plain = document.style_of(node).scalar == .plain;

            try testing.expectEqualStrings(text, document.text_of(node).?);

            if (plain) try testing.expectEqual(.string, schema_module.resolution_of(text, schema));
        }

        const integer = items.next() orelse return error.ItemMissing;
        const boolean = items.next() orelse return error.ItemMissing;
        const empty = items.next() orelse return error.ItemMissing;

        try testing.expectEqual(@as(?i64, std.math.minInt(i64)), document.integer_of(integer));
        try testing.expectEqual(@as(?bool, false), document.boolean_of(boolean));
        try testing.expect(document.null_is(empty));
    }
}

test "non-finite floats write the special forms, which only the core and 1.1 schemas read" {
    const fixture = try TestFixture.create();
    defer testing.allocator.destroy(fixture);

    const specials = [_]f64{ std.math.inf(f64), -std.math.inf(f64), std.math.nan(f64) };

    for ([_]Schema{ .core, .json, .v1_1 }) |schema| {
        const tree = &fixture.tree;

        tree.init(.{ .schema = schema });

        const root = try tree.root_append(.{ .sequence = .{ .style = .flow } });

        for (specials) |value| _ = try tree.append(root, .{ .float = value });

        const written = try fixture.written(test_write_options);

        try testing.expectEqualStrings("[.inf, -.inf, .nan]\n", written);

        for (specials, 0..) |value, index| {
            const node = tree.item(root, @intCast(index)) orelse return error.ItemMissing;
            const read = tree.float_of(node);

            if (schema == .json) {
                try testing.expectEqual(@as(?f64, null), read);
            } else {
                const bits: u64 = @bitCast(read orelse return error.FloatMissing);

                try testing.expectEqual(@as(u64, @bitCast(value)), bits);
            }
        }
    }
}

test "nesting past the depth bound is DepthExceeded, and the deepest tree re-parses" {
    const deep_capacity: Capacity = .{
        .anchor_count_max = 1,
        .comment_count_max = null,
        .node_count_max = 600,
        .text_bytes_max = 64,
    };

    const Deep = TreeType(deep_capacity);
    const DeepDocument = document_module.DocumentType(deep_capacity);
    const tree = try testing.allocator.create(Deep);
    defer testing.allocator.destroy(tree);

    const document = try testing.allocator.create(DeepDocument);
    defer testing.allocator.destroy(document);

    tree.init(.{ .schema = .core });

    const mapping: Tree.Content = .{ .mapping = .{ .style = .flow } };
    const sequence: Tree.Content = .{ .sequence = .{ .style = .flow } };
    const root = try tree.root_append(sequence);
    var node = root;

    for (1..depth_max) |_| node = try tree.append(node, sequence);

    const deeper = tree.append(node, mapping);

    try testing.expectError(error.DepthExceeded, deeper);

    _ = try tree.append(node, .{ .integer = 1 });

    var buffer: [1024]u8 = undefined;
    var sink: std.Io.Writer = .fixed(&buffer);

    try tree.write(&sink, test_write_options);
    try document.parse(sink.buffered(), .{ .schema = .core });

    const copy: Tree.Content = .{
        .copy = .{ .document = &document.document, .merge = .ignored, .node = document.root(0) },
    };

    const holder = try tree.root_append(mapping);
    const nested = tree.set(holder, "deep", copy);

    try testing.expectError(error.DepthExceeded, nested);

    _ = try tree.root_append(copy);

    audit(&tree.tree);
}

test "path_find and item index sequences and see through aliases" {
    const fixture = try TestFixture.create();
    defer testing.allocator.destroy(fixture);

    const tree = &fixture.tree;
    const root = try fixture.copied("list: &l [a, [b, c]]\nmirror: *l\nmap: {k: v}\n");
    const found = tree.path_find(root, &.{ "mirror", "1", "0" }) orelse return error.PathMissing;
    const list = tree.member(root, "list") orelse return error.ListMissing;
    const map = tree.member(root, "map") orelse return error.MapMissing;

    try testing.expectEqualStrings("b", tree.text_of(found).?);
    try testing.expectEqual(tree.item(list, 1), tree.path_find(root, &.{ "mirror", "1" }));
    try testing.expectEqual(@as(?Tree.Node, null), tree.path_find(root, &.{ "list", "01" }));
    try testing.expectEqual(@as(?Tree.Node, null), tree.path_find(root, &.{ "list", "2" }));
    try testing.expectEqual(@as(?Tree.Node, null), tree.path_find(root, &.{ "map", "0" }));
    try testing.expectEqual(@as(?Tree.Node, null), tree.path_find(root, &.{ "map", "k", "x" }));
    try testing.expectEqual(@as(?Tree.Node, null), tree.member(list, "k"));
    try testing.expectEqual(@as(?Tree.Node, null), tree.item(map, 0));
    try testing.expectEqual(@as(u32, 0), tree.count_of(found));
    try testing.expectEqual(@as(u32, 0), tree.entries(list).remaining);
    try testing.expectEqual(@as(u32, 0), tree.items(map).remaining);
}

test "storage from an allocator holds a tree" {
    var storage = try Tree.Storage.init(testing.allocator, test_capacity);
    defer storage.deinit(testing.allocator);

    var tree: Tree = undefined;

    tree.init(storage, .{ .schema = .json });

    const root = try tree.root_append(.{ .string = "only" });

    try testing.expectEqualStrings("only", tree.text_of(root).?);
    try testing.expectEqual(Tree.Kind.scalar, tree.kind_of(root));
    try testing.expectEqual(@as(u32, 1), tree.root_count());
}

test "a blank line above an entry survives a write and a copy when no comment is kept" {
    const kept_capacity: Capacity = .{
        .anchor_count_max = 16,
        .comment_count_max = 16,
        .node_count_max = 256,
        .text_bytes_max = 4096,
    };

    const source = "a: 1\n\nb:\n  - x\n\n  - y\n";
    const document = try testing.allocator.create(document_module.DocumentType(kept_capacity));
    defer testing.allocator.destroy(document);

    const tree = try testing.allocator.create(TreeType(kept_capacity));
    defer testing.allocator.destroy(tree);

    try document.parse(source, .{ .schema = .core });
    try testing.expectEqual(@as(u32, 0), document.document.comment_count);

    var buffer: [64]u8 = undefined;
    var sink: std.Io.Writer = .fixed(&buffer);

    try document.write(&sink, test_write_options);
    try testing.expectEqualStrings(source, sink.buffered());

    tree.init(.{ .schema = .core });

    _ = try tree.root_append(.{ .copy = .{
        .document = &document.document,
        .node = document.root(0),
    } });

    sink = .fixed(&buffer);

    try tree.write(&sink, test_write_options);
    try testing.expectEqualStrings(source, sink.buffered());
}

test "a blank line asked above an empty node is not written, since the node has no line" {
    const fixture = try TestFixture.create();
    defer testing.allocator.destroy(fixture);

    const tree = &fixture.tree;
    const root = try fixture.copied("-\n- 1\n");
    const empty = tree.item(root, 0) orelse return error.ItemMissing;
    const one = tree.item(root, 1) orelse return error.ItemMissing;

    try tree.comment_set(empty, .head, "\n");
    try testing.expectEqualStrings("-\n- 1\n", try fixture.written(test_write_options));

    try tree.comment_set(one, .head, "\n");
    try testing.expectEqualStrings("-\n\n- 1\n", try fixture.written(test_write_options));
}
