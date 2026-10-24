const std = @import("std");

const scanner_module = @import("scanner.zig");
const storage_module = @import("storage.zig");
const writer_module = @import("writer.zig");

const assert = std.debug.assert;

const CommentSlot = storage_module.CommentSlot;
const Writer = writer_module.Writer;

pub const Comment = struct {
    placement: Placement,
    text: []const u8,

    pub const Placement = enum {
        foot,
        head,
        line,
    };
};

pub const Comments = struct {
    blank: bool,
    cursor: u32,
    end: u32,
    remaining: u32,
    slots: []const CommentSlot,
    tail: bool,

    pub fn next(iterator: *Comments) ?Comment {
        assert(iterator.cursor <= iterator.end);
        assert(iterator.end <= iterator.slots.len);

        if (iterator.remaining == 0) return null;

        iterator.remaining -= 1;

        if (iterator.tail) {
            const heads_done = iterator.cursor == iterator.end or
                iterator.slots[iterator.cursor].placement != .head;

            if (heads_done) {
                iterator.tail = false;

                return .{ .placement = .head, .text = "" };
            }
        }

        const slot = &iterator.slots[iterator.cursor];
        const blank_due = slot.flags.blank_before and slot.text.len > 0 and !iterator.blank;

        if (blank_due) {
            iterator.blank = true;

            return .{ .placement = slot.placement, .text = "" };
        }

        iterator.blank = false;
        iterator.cursor += 1;

        return .{ .placement = slot.placement, .text = slot.text };
    }
};

pub const Entry = struct {
    key_range: Range,
    key_shape: Shape,
    mapping: bool,
    value_next: bool,

    pub fn of(mapping: bool) Entry {
        return .{
            .key_range = Range.empty,
            .key_shape = .block,
            .mapping = mapping,
            .value_next = false,
        };
    }
};

pub const FeetAt = enum {
    all,
    inside,
    outside,
};

pub const LineAt = enum {
    closing,
    node,
    opening,
};

pub const LineError = error{TextInvalid};

pub const Range = struct {
    end: u32,
    first: u32,

    pub const empty: Range = .{ .end = 0, .first = 0 };
};

pub const Shape = enum {
    block,
    flow,
    leaf,

    fn feet_at(shape: Shape) FeetAt {
        assert(shape != .block);

        return if (shape == .flow) .outside else .all;
    }

    pub fn of_collection(flow: bool) Shape {
        return if (flow) .flow else .block;
    }
};

pub fn comments_of(slots: []const CommentSlot, range: Range, blank: bool) Comments {
    assert(range.first <= range.end);
    assert(range.end <= slots.len);

    var remaining: u32 = 0;

    for (slots[range.first..range.end]) |*slot| {
        remaining += 1;

        const blank_counted = slot.flags.blank_before and slot.text.len > 0;

        if (blank_counted) remaining += 1;
    }

    return .{
        .blank = false,
        .cursor = range.first,
        .end = range.end,
        .remaining = remaining + @intFromBool(blank),
        .slots = slots,
        .tail = blank,
    };
}

pub fn range_of(slots: []const CommentSlot, node: u32) Range {
    assert(slots.len <= std.math.maxInt(u32));
    assert(node != storage_module.index_none);

    var low: u32 = 0;
    var high: u32 = @intCast(slots.len);

    for (0..33) |_| {
        if (low == high) break;

        const middle = low + @divFloor(high - low, 2);

        if (slots[middle].node < node) {
            low = middle + 1;
        } else {
            high = middle;
        }
    }

    var end = low;

    for (low..slots.len) |position| {
        if (slots[position].node != node) break;

        end += 1;
    }

    assert(end >= low);

    return .{ .end = end, .first = low };
}

pub fn heads_write(
    writer: *Writer,
    slots: []const CommentSlot,
    range: Range,
    blank: bool,
) Writer.Error!void {
    assert(range.first <= range.end);
    assert(range.end <= slots.len);

    try heads_matching_write(writer, slots, range, false);

    if (blank) try writer.comment(.head, "");
}

fn heads_matching_write(
    writer: *Writer,
    slots: []const CommentSlot,
    range: Range,
    prefix: bool,
) Writer.Error!void {
    assert(range.first <= range.end);
    assert(range.end <= slots.len);

    for (slots[range.first..range.end]) |*slot| {
        if (slot.placement != .head) break;
        if (slot.flags.prefix != prefix) continue;

        try slot_write(writer, slot);
    }
}

pub fn prefix_heads_write(
    writer: *Writer,
    slots: []const CommentSlot,
    range: Range,
) Writer.Error!void {
    assert(range.first <= range.end);
    assert(range.end <= slots.len);

    try heads_matching_write(writer, slots, range, true);
}

pub fn line_write(
    writer: *Writer,
    slots: []const CommentSlot,
    range: Range,
    at: LineAt,
) Writer.Error!void {
    assert(range.first <= range.end);
    assert(range.end <= slots.len);

    for (slots[range.first..range.end]) |*slot| {
        if (slot.placement != .line) continue;

        const wanted = switch (at) {
            .closing => closing_is(slot),
            .node => true,
            .opening => !closing_is(slot),
        };

        if (!wanted) continue;

        try writer.comment(.line, slot.text);
    }
}

pub fn closing_is(slot: *const CommentSlot) bool {
    assert(slot.placement == .line);
    assert(slot.text.len > 0);

    return switch (slot.previous) {
        .flow_entry, .flow_mapping_end, .flow_sequence_end => true,
        else => false,
    };
}

pub fn feet_write(
    writer: *Writer,
    slots: []const CommentSlot,
    range: Range,
    prefix: bool,
    at: FeetAt,
) Writer.Error!void {
    assert(range.first <= range.end);
    assert(range.end <= slots.len);

    for (slots[range.first..range.end]) |*slot| {
        if (slot.placement != .foot) continue;
        if (slot.flags.prefix != prefix) continue;

        const wanted = switch (at) {
            .all => true,
            .inside => slot.flags.inside,
            .outside => !slot.flags.inside,
        };

        if (!wanted) continue;

        try slot_write(writer, slot);
    }
}

pub fn feet_after_write(
    writer: *Writer,
    slots: []const CommentSlot,
    range: Range,
    shape: Shape,
) Writer.Error!void {
    assert(range.first <= range.end);
    assert(range.end <= slots.len);

    if (shape == .block) return;

    try feet_write(writer, slots, range, false, shape.feet_at());
}

pub fn collection_feet_write(
    writer: *Writer,
    slots: []const CommentSlot,
    range: Range,
    flow: bool,
) Writer.Error!void {
    assert(range.first <= range.end);
    assert(range.end <= slots.len);

    try feet_write(writer, slots, range, false, if (flow) .inside else .all);
}

inline fn entry_quiet_finish(
    writer: *Writer,
    slots: []const CommentSlot,
    parent: ?*Entry,
    shape: Shape,
) Writer.Error!void {
    assert(@backingInt(shape) <= 2);
    assert(parent == null or parent.?.key_range.end <= slots.len);

    const entry = parent orelse return;
    if (!entry.mapping) return;

    if (!entry.value_next) {
        entry.* = .{
            .key_range = Range.empty,
            .key_shape = shape,
            .mapping = true,
            .value_next = true,
        };

        return;
    }

    const key = entry.key_range;
    const key_feet = entry.key_shape != .block and key.end > key.first;

    entry.value_next = false;

    if (key_feet) try feet_write(writer, slots, key, false, entry.key_shape.feet_at());
}

pub inline fn entry_finish(
    writer: *Writer,
    slots: []const CommentSlot,
    parent: ?*Entry,
    range: Range,
    shape: Shape,
) Writer.Error!void {
    assert(range.first <= range.end);
    assert(range.end <= slots.len);
    assert(parent == null or parent.?.key_range.end <= slots.len);

    if (range.end == range.first) return entry_quiet_finish(writer, slots, parent, shape);
    return entry_commented_finish(writer, slots, parent, range, shape);
}

fn entry_commented_finish(
    writer: *Writer,
    slots: []const CommentSlot,
    parent: ?*Entry,
    range: Range,
    shape: Shape,
) Writer.Error!void {
    assert(range.first < range.end);
    assert(range.end <= slots.len);
    assert(parent == null or parent.?.key_range.end <= slots.len);

    const entry = parent orelse {
        if (shape != .block) try feet_write(writer, slots, range, false, shape.feet_at());

        return;
    };

    if (!entry.mapping) {
        if (shape != .block) try feet_write(writer, slots, range, false, shape.feet_at());

        return;
    }

    if (!entry.value_next) {
        entry.value_next = true;
        entry.key_range = range;
        entry.key_shape = shape;

        return;
    }

    if (shape != .block) try feet_write(writer, slots, range, false, shape.feet_at());

    if (entry.key_shape != .block) {
        try feet_write(writer, slots, entry.key_range, false, entry.key_shape.feet_at());
    }

    entry.value_next = false;
}

fn slot_write(writer: *Writer, slot: *const CommentSlot) Writer.Error!void {
    assert(slot.placement != .line);
    assert(slot.text.len <= scanner_module.source_bytes_max);

    const blank_written = slot.flags.blank_before and slot.text.len > 0;

    if (blank_written) try writer_module.comment_single_write(writer, slot.placement, "");

    try writer_module.comment_single_write(writer, slot.placement, slot.text);
}

pub const Lines = struct {
    count: u32,
    trailing_empty: bool,
};

pub fn rank_of(placement: Comment.Placement) u2 {
    assert(@backingInt(placement) <= 2);

    const result: u2 = switch (placement) {
        .head => 0,
        .line => 1,
        .foot => 2,
    };

    assert(result <= 2);

    return result;
}

pub fn lines_check(placement: Comment.Placement, text: []const u8) LineError!Lines {
    assert(text.len <= scanner_module.source_bytes_max);
    assert(@backingInt(placement) <= 2);

    var result: Lines = .{ .count = 0, .trailing_empty = false };
    var start: u32 = 0;

    for (0..text.len + 1) |_| {
        const end: u32 = @intCast(std.mem.findScalarPos(u8, text, start, '\n') orelse text.len);
        const line = text[start..end];

        if (line.len == 0) {
            if (placement == .line) return error.TextInvalid;
        } else {
            if (!line_valid_is(line)) return error.TextInvalid;
        }

        result.count += 1;
        result.trailing_empty = line.len == 0;

        if (end == text.len) break;

        start = end + 1;
    }

    if (placement == .line) {
        if (result.count != 1) return error.TextInvalid;
    }

    assert(result.count > 0);

    return result;
}

pub fn lines_valid_is(placement: Comment.Placement, text: []const u8) bool {
    assert(text.len <= scanner_module.source_bytes_max);
    assert(@backingInt(placement) <= 2);

    _ = lines_check(placement, text) catch return false;

    return true;
}

pub fn line_valid_is(line: []const u8) bool {
    assert(line.len > 0);
    assert(line.len <= scanner_module.source_bytes_max);

    if (line[0] != '#') return false;

    const last = line[line.len - 1];
    if (last == ' ') return false;
    if (last == '\t') return false;
    if (!std.unicode.utf8ValidateSlice(line)) return false;

    var index: u32 = 0;

    for (0..line.len) |_| {
        if (index == line.len) break;

        const byte = line[index];

        if (byte < 0x80) {
            if (byte == '\n') return false;
            if (byte == '\r') return false;
            if (!scanner_module.ascii_printable_is(byte)) return false;

            index += 1;

            continue;
        }

        const length = std.unicode.utf8ByteSequenceLength(byte) catch return false;
        const codepoint = std.unicode.utf8Decode(line[index..][0..length]) catch return false;
        if (codepoint == 0xfeff) return false;
        if (!scanner_module.codepoint_printable_is(codepoint)) return false;

        index += length;
    }

    return true;
}

test Comment {
    const yaml = @import("yaml.zig");

    const Fixed = yaml.DocumentType(.{
        .anchor_count_max = 4,
        .comment_count_max = 8,
        .node_count_max = 32,
        .text_bytes_max = 256,
    });

    const document = try std.testing.allocator.create(Fixed);
    defer std.testing.allocator.destroy(document);

    try document.parse("# server\nport: 80 # http\n", .{});

    const root = document.root(0);
    const port = document.member(root, "port") orelse return error.PortMissing;
    var head = document.comments(root);
    var line = document.comments(port);

    const header = head.next() orelse return error.HeadMissing;
    const trailing = line.next() orelse return error.LineMissing;

    try std.testing.expectEqual(Comment.Placement.head, header.placement);
    try std.testing.expectEqualStrings("# server", header.text);
    try std.testing.expectEqual(Comment.Placement.line, trailing.placement);
    try std.testing.expectEqualStrings("# http", trailing.text);

    const after = line.next();

    try std.testing.expectEqual(@as(?Comment, null), after);
}

test Comments {
    const yaml = @import("yaml.zig");

    const Fixed = yaml.TreeType(.{
        .anchor_count_max = 4,
        .comment_count_max = 8,
        .node_count_max = 32,
        .text_bytes_max = 256,
    });

    const tree = try std.testing.allocator.create(Fixed);
    defer std.testing.allocator.destroy(tree);

    tree.init(.{ .schema = .core });

    const root = try tree.root_append(.{ .mapping = .{ .style = .block } });
    const port = try tree.set(root, "port", .{ .integer = 80 });

    try tree.comment_set(port, .head, "# first\n\n# second");
    try tree.comment_set(port, .line, "# http");

    const expected = [_]Comment{
        .{ .placement = .head, .text = "# first" },
        .{ .placement = .head, .text = "" },
        .{ .placement = .head, .text = "# second" },
        .{ .placement = .line, .text = "# http" },
    };

    var comments = tree.comments(port);

    for (expected) |wanted| {
        const comment = comments.next() orelse return error.CommentMissing;

        try std.testing.expectEqual(wanted.placement, comment.placement);
        try std.testing.expectEqualStrings(wanted.text, comment.text);
    }

    const after = comments.next();

    try std.testing.expectEqual(@as(?Comment, null), after);
}

test "comment text is lines that start with a hash, with empty lines for blank lines" {
    try std.testing.expectEqual(@as(u32, 3), (try lines_check(.head, "# a\n\n# b")).count);
    try std.testing.expect((try lines_check(.head, "# a\n")).trailing_empty);
    try std.testing.expectEqual(@as(u32, 1), (try lines_check(.line, "#")).count);
    try std.testing.expectError(error.TextInvalid, lines_check(.line, "# a\n# b"));
    try std.testing.expectError(error.TextInvalid, lines_check(.line, ""));
    try std.testing.expectError(error.TextInvalid, lines_check(.head, "a"));
    try std.testing.expectError(error.TextInvalid, lines_check(.head, "# a "));
    try std.testing.expectError(error.TextInvalid, lines_check(.foot, "# a\r"));
    try std.testing.expectError(error.TextInvalid, lines_check(.foot, "# \xff"));
    try std.testing.expectError(error.TextInvalid, lines_check(.foot, "# \x07"));
    try std.testing.expectError(error.TextInvalid, lines_check(.foot, "# \xef\xbb\xbf"));
}
