const std = @import("std");

const comment_module = @import("comment.zig");
const document_module = @import("document.zig");
const parser_module = @import("parser.zig");
const round_trip = @import("round_trip.zig");
const storage_module = @import("storage.zig");
const writer_module = @import("writer.zig");

const assert = std.debug.assert;

const Comment = comment_module.Comment;
const CommentSlot = storage_module.CommentSlot;
const Event = parser_module.Event;
const Parser = parser_module.Parser;
const Prng = std.Random.DefaultPrng;
const ScalarStyle = parser_module.ScalarStyle;
const Writer = writer_module.Writer;

pub const Options = struct {
    events_max: u32,
    seed: u64,
};

const anchor_count_max: u32 = 64;
const child_count_max: u32 = 4;
const comment_lines_max: u32 = 4;
const comment_text_max: u32 = 160;
const comments_max: u32 = 1024;
const coverage_events_min: u32 = 20_000;
const depth_limit: u32 = 6;
const document_count_max: u32 = 3;
const event_budget: u32 = 384;
const event_count_max: u32 = 512;
const fragment_count_max: u32 = 5;
const key_long_bytes: u32 = 1100;
const output_bytes_max: u32 = 8 * 1024 * 1024;
const pool_bytes_max: u32 = 64 * 1024;
const text_bytes_max: u32 = 2048;

comptime {
    assert(event_budget + 2 * child_count_max * (depth_limit + 1) + 8 < event_count_max);
    assert(key_long_bytes + 64 < text_bytes_max);
    assert(text_bytes_max < pool_bytes_max);
}

const KeptDocument = document_module.DocumentType(.{
    .anchor_count_max = anchor_count_max,
    .comment_count_max = comments_max,
    .node_count_max = event_count_max,
    .text_bytes_max = 1024 * 1024,
});

const comment_lines = [_][]const u8{
    "#",
    "# c",
    "#x y",
    "# \u{fc}n\u{ef}",
    "# a: b",
    "# - [x], {y}",
    "#  indented # twice",
};

const comment_invalid = [_]struct { placement: Comment.Placement, text: []const u8 }{
    .{ .placement = .line, .text = "# a\n# b" },
    .{ .placement = .line, .text = "" },
    .{ .placement = .head, .text = "a" },
    .{ .placement = .foot, .text = "# a " },
    .{ .placement = .head, .text = "# \x07" },
    .{ .placement = .foot, .text = "#\r" },
    .{ .placement = .head, .text = "# \xff" },
    .{ .placement = .foot, .text = "# \xef\xbb\xbf" },
};

const anchor_names = [_][]const u8{
    "a",
    "b",
    "a:b",
    "\u{e9}",
    "x.y",
    "#h",
    "q'",
    "anchor_name_long",
};

const tag_names = [_][]const u8{
    "!",
    "!local",
    "!e!x",
    "!a%b",
    "!{}",
    "tag:yaml.org,2002:str",
    "tag:yaml.org,2002:a,b",
    "tag:yaml.org,2002:[\u{e9}]",
    "tag:yaml.org,2002:",
    "tag:example.com,2000:v",
    "x y>",
};

const fragments = [_][]const u8{
    "a",
    "word",
    "x y",
    "the quick brown fox",
    "-",
    "?",
    ":",
    ",",
    "[",
    "]",
    "{",
    "}",
    "#",
    "&",
    "*",
    "!",
    "|",
    ">",
    "'",
    "\"",
    "%",
    "@",
    "`",
    "~",
    " ",
    "  ",
    "\t",
    "\n",
    "\n\n",
    "- ",
    "? ",
    ": ",
    " #",
    "---",
    "...",
    "--- ",
    "null",
    "true",
    "1",
    "-.inf",
    "0x1F",
    "12345678901234567890",
    "yes",
    "\x01",
    "\x7f",
    "\r",
    "\\",
    "''",
    "\u{85}",
    "\u{2028}",
    "\u{feff}",
    "\u{fffe}",
    "\u{a0}",
    "\u{e9}",
    "\u{20ac}",
    "\u{1f600}",
};

const invalid_sequences = [_][]const u8{
    "\xff",
    "\xc3",
    "\xc0\x80",
    "\xed\xa0\x80",
    "\xf4\x90\x80\x80",
    "\xe2\x80",
};

const words = "the quick brown fox jumps over the lazy dog";

const Counter = enum {
    comment_foot,
    comment_head,
    comment_invalid,
    comment_line,
    fallback_block_in_flow,
    fallback_content_white,
    fallback_document_marker,
    fallback_flow_sign,
    fallback_indicator_last,
    fallback_null,
    fallback_plain_double,
    fallback_plain_single,
    fallback_single_double,
    fallback_special,
    fold_double,
    fold_folded,
    fold_plain,
    fold_single,
    header_folded_clip,
    header_folded_clip_digit,
    header_folded_keep,
    header_folded_keep_digit,
    header_folded_strip,
    header_folded_strip_digit,
    header_literal_clip,
    header_literal_clip_digit,
    header_literal_keep,
    header_literal_keep_digit,
    header_literal_strip,
    header_literal_strip_digit,
    key_explicit,
    key_simple,
    layout_block,
    layout_flow,
    layout_preserve,
    text_invalid,
};

const Coverage = std.EnumArray(Counter, u64);

const header_counters = [2][3][2]Counter{
    .{
        .{ .header_folded_clip, .header_folded_clip_digit },
        .{ .header_folded_keep, .header_folded_keep_digit },
        .{ .header_folded_strip, .header_folded_strip_digit },
    },
    .{
        .{ .header_literal_clip, .header_literal_clip_digit },
        .{ .header_literal_keep, .header_literal_keep_digit },
        .{ .header_literal_strip, .header_literal_strip_digit },
    },
};

const Frame = struct {
    anchor: []const u8,
    flow: bool,
    key_count: u32,
    keys: [child_count_max][]const u8,
    mapping: bool,
    remaining: u32,
};

const Fact = struct {
    context: round_trip.Context,
    folded: bool,
};

const ScalarPair = struct {
    original: *const Event.Scalar,
    written: *const Event.Scalar,
};

const Failure = struct {
    reason: []const u8,
    written: []const u8,
};

const Sinks = struct {
    main: std.Io.Writer,
    shadow: std.Io.Writer,
};

const State = struct {
    anchor_count: u32,
    anchors: [anchor_count_max][]const u8,
    comment_buffer: [comment_text_max]u8,
    comment_count: u32,
    comments: [comments_max][]const u8,
    coverage: Coverage,
    depth: u32,
    event_count: u32,
    events: [event_count_max]Event,
    facts: [event_count_max]Fact,
    frames: [depth_limit]Frame,
    kept: KeptDocument,
    kept_order: [comments_max]CommentSlot,
    kept_written: [2][output_bytes_max]u8,
    key_unique: u32,
    output: [output_bytes_max]u8,
    parser: Parser,
    parser_text: [output_bytes_max]u8,
    pool: [pool_bytes_max]u8,
    pool_used: u32,
    prng: Prng,
    reparsed: [event_count_max]Event,
    rewritten: [output_bytes_max]u8,
    scratch: [text_bytes_max + 8]u8,
    seed: u64,
    shadow: [output_bytes_max]u8,
    sinks: Sinks,
    writer: Writer,
    writer_shadow: Writer,

    fn chance(state: *State, denominator: u32) bool {
        assert(denominator > 0);
        assert(denominator <= 1024);

        return state.prng.random().uintLessThan(u32, denominator) == 0;
    }

    fn below(state: *State, bound: u32) u32 {
        assert(bound > 0);
        assert(bound <= std.math.maxInt(u32));

        const result = state.prng.random().uintLessThan(u32, bound);

        assert(result < bound);

        return result;
    }

    fn event_append(state: *State, event: Event) void {
        assert(state.event_count < event_count_max);
        assert(state.depth <= depth_limit);

        if (event == .stream_start) assert(state.event_count == 0);

        state.events[state.event_count] = event;
        state.event_count += 1;
    }

    fn pool_take(state: *State, length: u32) ?[]u8 {
        assert(length <= text_bytes_max);
        assert(state.pool_used <= pool_bytes_max);

        if (pool_bytes_max - state.pool_used < length) return null;

        const result = state.pool[state.pool_used..][0..length];

        state.pool_used += length;

        return result;
    }

    fn options_choose(state: *State) Writer.Options {
        assert(writer_module.depth_max > depth_limit);
        assert(state.event_count == 0);

        const layouts = [_]Writer.Layout{ .block, .flow, .preserve };
        const widths = [_]u32{ 0, 0, 1, 20, 80 };
        const width_roll = state.below(widths.len + 1);

        return .{
            .indent = @intCast(1 + state.below(9)),
            .layout = layouts[state.below(layouts.len)],
            .sequence_indentless = state.chance(2),
            .utf8 = if (state.chance(2)) .checked else .trusted,
            .version_directive = state.chance(4),
            .width = if (width_roll < widths.len) widths[width_roll] else 1 + state.below(100),
        };
    }

    fn stream_generate(state: *State) void {
        assert(state.depth == 0);
        assert(state.event_count == 0);

        state.pool_used = 0;

        state.event_append(.stream_start);

        const documents = 1 + state.below(document_count_max);

        for (0..documents) |_| state.document_generate();

        state.event_append(.stream_end);

        assert(state.event_count <= event_count_max);
    }

    fn document_generate(state: *State) void {
        assert(state.depth == 0);
        assert(state.event_count + 8 < event_count_max);

        state.anchor_count = 0;

        state.event_append(.{ .document_start = .{ .explicit = state.chance(2) } });

        switch (state.below(3)) {
            0 => state.scalar_generate(false),
            1 => state.collection_open(true),
            else => state.collection_open(false),
        }

        for (0..event_count_max) |_| {
            if (state.depth == 0) break;

            state.frame_step();
        }

        assert(state.depth == 0);

        state.event_append(.{ .document_end = .{ .explicit = state.chance(2) } });
    }

    fn frame_step(state: *State) void {
        assert(state.depth > 0);
        assert(state.depth <= depth_limit);

        const frame = &state.frames[state.depth - 1];
        if (frame.remaining == 0) return state.collection_close();

        frame.remaining -= 1;

        const key = frame.mapping and frame.remaining % 2 == 1;
        const room = state.event_count + 64 < event_budget and state.depth < depth_limit;
        const roll = state.below(16);

        if (room) {
            if (roll < 3) return state.collection_open(true);
            if (roll < 6) return state.collection_open(false);
        }

        if (roll < 8) {
            if (state.anchor_count > 0) return state.alias_generate();
        }

        state.scalar_generate(key);
    }

    fn collection_open(state: *State, mapping: bool) void {
        assert(state.depth < depth_limit);
        assert(state.event_count < event_budget + 64);

        const parent_flow = state.depth > 0 and state.frames[state.depth - 1].flow;
        const flow = parent_flow or state.chance(2);
        const count = state.below(child_count_max + 1);
        const anchor = if (state.chance(6)) anchor_names[state.below(anchor_names.len)] else "";
        const tag = if (state.chance(8)) tag_names[state.below(tag_names.len)] else "";

        const start: Event.CollectionStart = .{
            .anchor = anchor,
            .style = if (flow) .flow else .block,
            .tag = tag,
        };

        if (mapping) {
            state.event_append(.{ .mapping_start = start });
        } else {
            state.event_append(.{ .sequence_start = start });
        }

        state.frames[state.depth] = .{
            .anchor = anchor,
            .flow = flow,
            .key_count = 0,
            .keys = undefined,
            .mapping = mapping,
            .remaining = if (mapping) 2 * count else count,
        };

        state.depth += 1;
    }

    fn collection_close(state: *State) void {
        assert(state.depth > 0);
        assert(state.frames[state.depth - 1].remaining == 0);

        const frame = &state.frames[state.depth - 1];

        state.event_append(if (frame.mapping) .mapping_end else .sequence_end);

        if (frame.anchor.len > 0) state.anchor_complete(frame.anchor);

        state.depth -= 1;
    }

    fn anchor_complete(state: *State, name: []const u8) void {
        assert(name.len > 0);
        assert(state.anchor_count <= anchor_count_max);

        for (state.anchors[0..state.anchor_count]) |known| {
            if (std.mem.eql(u8, known, name)) return;
        }

        if (state.anchor_count == anchor_count_max) return;

        state.anchors[state.anchor_count] = name;
        state.anchor_count += 1;
    }

    fn alias_generate(state: *State) void {
        assert(state.anchor_count > 0);
        assert(state.depth > 0);

        const anchor = state.anchors[state.below(state.anchor_count)];

        state.event_append(.{ .alias = .{ .anchor = anchor } });
    }

    fn scalar_generate(state: *State, key: bool) void {
        assert(state.depth <= depth_limit);

        if (key) assert(state.depth > 0);

        const styles = std.enums.values(ScalarStyle);
        const anchor = if (state.chance(6)) anchor_names[state.below(anchor_names.len)] else "";
        const tag = if (state.chance(8)) tag_names[state.below(tag_names.len)] else "";
        const text = if (key) state.key_text_generate() else state.text_generate(false);

        state.event_append(.{ .scalar = .{
            .anchor = anchor,
            .style = styles[state.below(styles.len)],
            .tag = tag,
            .text = text,
        } });

        if (anchor.len > 0) state.anchor_complete(anchor);
    }

    fn key_text_generate(state: *State) []const u8 {
        assert(state.depth > 0);
        assert(state.frames[state.depth - 1].mapping);

        const frame = &state.frames[state.depth - 1];

        for (0..4) |_| {
            const text = state.text_generate(true);

            const known = for (frame.keys[0..frame.key_count]) |key| {
                if (std.mem.eql(u8, key, text)) break true;
            } else false;

            if (known) continue;

            frame.keys[frame.key_count] = text;
            frame.key_count += 1;

            return text;
        }

        const unique = state.pool_take(16) orelse return "k";
        const text = std.mem.print(unique, "k{d}", .{state.key_unique}) catch return "k";

        state.key_unique += 1;
        frame.keys[frame.key_count] = text;
        frame.key_count += 1;

        return text;
    }

    fn text_generate(state: *State, key: bool) []const u8 {
        assert(state.pool_used <= pool_bytes_max);
        assert(state.depth <= depth_limit);

        const roll = state.below(32);
        if (roll == 0) return "";
        if (roll == 1) return words;

        if (roll == 2) {
            if (key) return state.long_text_generate();
        }

        const count = 1 + state.below(fragment_count_max);
        var parts: [fragment_count_max][]const u8 = undefined;
        var length: u32 = 0;

        for (parts[0..count]) |*part| {
            part.* = fragments[state.below(fragments.len)];
            length += @intCast(part.len);
        }

        const text = state.pool_take(length) orelse return "x";
        var cursor: u32 = 0;

        for (parts[0..count]) |part| {
            @memcpy(text[cursor..][0..part.len], part);
            cursor += @intCast(part.len);
        }

        assert(cursor == length);

        return text;
    }

    fn long_text_generate(state: *State) []const u8 {
        assert(key_long_bytes > 1024);
        assert(state.pool_used <= pool_bytes_max);

        const text = state.pool_take(key_long_bytes) orelse return "x";
        const spaced = state.chance(2);

        for (text, 0..) |*byte, index| {
            const space = spaced and index % 7 == 6;

            byte.* = if (space) ' ' else 'k';
        }

        return text;
    }

    fn stream_run(state: *State) !void {
        assert(state.depth == 0);
        assert(state.anchor_count <= anchor_count_max);

        state.event_count = 0;
        state.comment_count = 0;

        const options = state.options_choose();

        state.stream_generate();

        try state.stream_write(&options);

        const written = state.sinks.main.buffered();
        const reparsed = try state.reparse(written);

        const sources: round_trip.Sources = .{
            .original = .{ .events = state.events[0..state.event_count] },
            .written = .{ .events = reparsed },
        };

        const comparison: round_trip.Options = .{
            .layout = options.layout,
            .style_exact = false,
            .version_directive = options.version_directive,
        };

        const verdict = try round_trip.streams_equivalent(sources, comparison);

        if (verdict == .differed) {
            state.failure_print(.{ .reason = verdict.differed, .written = written });

            return error.StreamsDiffer;
        }

        if (state.comment_count == 0) {
            try state.idempotence_check(reparsed, &options);
        } else {
            try state.comments_check(written, &options);
        }

        try state.coverage_record(reparsed, &options);
    }

    fn comments_check(state: *State, written: []const u8, options: *const Writer.Options) !void {
        assert(state.comment_count > 0);
        assert(written.len <= output_bytes_max);

        const first = state.kept_write(written, options, 0) catch |err| switch (err) {
            error.AliasRecursive, error.KeyDuplicate => return,
            else => return err,
        };

        const second = try state.kept_write(first, options, 1);

        if (!std.mem.eql(u8, first, second)) {
            state.failure_print(.{
                .reason = "a commented rewrite misses the fixed point",
                .written = first,
            });

            std.debug.print("--- second write ---\n{s}\n", .{second});

            return error.WriteUnstable;
        }
    }

    fn kept_write(
        state: *State,
        source: []const u8,
        options: *const Writer.Options,
        round: u32,
    ) ![]const u8 {
        assert(round < state.kept_written.len);
        assert(source.len <= output_bytes_max);

        state.kept.parse(source, .{ .schema = .core }) catch |err| {
            if (err == error.AliasRecursive) return err;
            if (err == error.KeyDuplicate) return err;

            std.debug.print("writer: a kept parse fails ({t})\n", .{err});
            state.failure_print(.{ .reason = "a kept parse error", .written = source });

            return err;
        };

        try state.comment_order_check(source);

        var sink: std.Io.Writer = .fixed(&state.kept_written[round]);

        try state.kept.write(&sink, options.*);

        return sink.buffered();
    }

    fn comment_order_check(state: *State, source: []const u8) !void {
        assert(source.len <= output_bytes_max);
        assert(state.kept.document.comment_count <= comments_max);
        assert(state.comment_count <= comments_max);

        const count = state.kept.document.comment_count;
        const order = state.kept_order[0..count];

        @memcpy(order, state.kept.storage.comments[0..count]);
        std.sort.block(CommentSlot, order, {}, slot_source_less);

        var same = count == state.comment_count;

        for (order[0..@min(count, state.comment_count)], 0..) |*slot, index| {
            if (std.mem.eql(u8, slot.text, state.comments[index])) continue;

            std.debug.print("writer: comment {d} is {s}, generated {s}\n", .{
                index,
                slot.text,
                state.comments[index],
            });

            same = false;

            break;
        }

        if (!same) {
            std.debug.print("writer: {d} comments kept, {d} generated\n", .{
                count,
                state.comment_count,
            });

            state.failure_print(.{
                .reason = "the comments differ from the generated ones",
                .written = source,
            });

            return error.CommentsDiffer;
        }
    }

    fn comment_maybe(state: *State, index: u32) !void {
        assert(state.writer.depth == state.writer_shadow.depth);
        assert(state.comment_count <= comments_max);
        assert(index < state.event_count);

        if (!state.chance(5)) return;
        if (state.comment_count + comment_lines_max > comments_max) return;

        if (state.writer.options.utf8 == .checked) {
            if (state.chance(8)) try state.comment_invalid_inject();
        }

        const placements = [_]Comment.Placement{ .foot, .head, .line };
        const placement = placements[state.below(placements.len)];
        const text = try state.comment_text_generate(placement);
        const ended = state.writer.end_written;
        const closed_bare = state.writer.document_state == .closed and state.writer.root_bare;

        try state.writer.comment(placement, text);
        try state.writer_shadow.comment(placement, text);

        const ended_now = !ended and state.writer.end_written;

        if (ended_now) state.document_end_mark(index);

        const bare_closed = closed_bare and !state.writer.root_bare;

        if (bare_closed) state.document_end_mark_previous(index);

        const counter: Counter = switch (placement) {
            .foot => .comment_foot,
            .head => .comment_head,
            .line => .comment_line,
        };

        state.coverage.getPtr(counter).* += 1;
    }

    fn document_end_mark(state: *State, index: u32) void {
        assert(index < state.event_count);
        assert(state.writer.depth == 0);

        for (state.events[index..state.event_count]) |*event| {
            if (event.* != .document_end) continue;

            event.document_end.explicit = true;

            return;
        }

        unreachable;
    }

    fn document_end_mark_previous(state: *State, index: u32) void {
        assert(index < state.event_count);
        assert(state.writer.depth == 0);

        var position = index;

        for (0..index) |_| {
            position -= 1;

            const event = &state.events[position];
            if (event.* != .document_end) continue;

            event.document_end.explicit = true;

            return;
        }

        unreachable;
    }

    fn comment_text_generate(
        state: *State,
        placement: Comment.Placement,
    ) std.Io.Writer.Error![]const u8 {
        assert(@backingInt(placement) <= 2);
        assert(state.comment_count + comment_lines_max <= comments_max);

        const count = if (placement == .line) 1 else 1 + state.below(comment_lines_max);
        var sink: std.Io.Writer = .fixed(&state.comment_buffer);

        for (0..count) |index| {
            const blank = placement != .line and state.chance(4);

            if (index > 0) try sink.writeByte('\n');
            if (blank) try sink.writeByte('\n');

            const line = comment_lines[state.below(comment_lines.len)];

            try sink.writeAll(line);

            state.comments[state.comment_count] = line;
            state.comment_count += 1;
        }

        assert(comment_module.lines_valid_is(placement, sink.buffered()));

        if (placement == .line) return state.comments[state.comment_count - 1];
        return sink.buffered();
    }

    fn comment_invalid_inject(state: *State) !void {
        assert(state.writer.options.utf8 == .checked);
        assert(comment_invalid.len > 0);

        const invalid = comment_invalid[state.below(comment_invalid.len)];
        const before = std.mem.toBytes(state.writer);
        const written = state.sinks.main.end;
        const result = state.writer.comment(invalid.placement, invalid.text);

        try std.testing.expectError(error.TextInvalid, result);
        try std.testing.expectEqual(written, state.sinks.main.end);
        try std.testing.expectEqualSlices(u8, &before, std.mem.asBytes(&state.writer));

        state.coverage.getPtr(.comment_invalid).* += 1;
    }

    fn stream_write(state: *State, options: *const Writer.Options) !void {
        assert(state.event_count >= 2);
        assert(options.indent >= 1);

        var shadow_options = options.*;

        shadow_options.width = 0;

        state.sinks.main = .fixed(&state.output);
        state.sinks.shadow = .fixed(&state.shadow);

        state.writer.init(&state.sinks.main, options.*);
        state.writer_shadow.init(&state.sinks.shadow, shadow_options);

        const commented = state.chance(2);

        for (state.events[0..state.event_count], 0..) |*event, index| {
            const comment_due = commented and index > 0;

            if (comment_due) try state.comment_maybe(@intCast(index));

            try state.event_write(event, @intCast(index));
        }

        assert(state.writer.depth == 0);
        assert(state.writer_shadow.depth == 0);
    }

    fn event_write(state: *State, event: *const Event, index: u32) !void {
        assert(index < state.event_count);
        assert(state.writer.depth == state.writer_shadow.depth);

        const key = key_position_is(&state.writer) and node_is(event);

        if (event.* == .scalar) {
            try state.scalar_write(event, index);
        } else {
            try state.writer.emit(event);
            try state.writer_shadow.emit(event);
        }

        if (key) state.key_record(event);
    }

    fn scalar_write(state: *State, event: *const Event, index: u32) !void {
        assert(event.* == .scalar);
        assert(index < state.event_count);

        const main_before = state.sinks.main.end;
        const shadow_before = state.sinks.shadow.end;

        state.facts[index].context = context_of(&state.writer);

        if (state.writer.options.utf8 == .checked) {
            if (state.chance(64)) try state.invalid_inject(&event.scalar);
        }

        try state.writer.emit(event);
        try state.writer_shadow.emit(event);

        const main_bytes = state.output[main_before..state.sinks.main.end];
        const shadow_bytes = state.shadow[shadow_before..state.sinks.shadow.end];
        const differ = !std.mem.eql(u8, main_bytes, shadow_bytes);

        state.facts[index].folded = state.comment_count == 0 and differ;
    }

    fn key_record(state: *State, event: *const Event) void {
        assert(state.writer.depth > 0);
        assert(@backingInt(std.meta.activeTag(event.*)) <= 9);

        const depth = state.writer.depth;

        switch (event.*) {
            .alias, .scalar => {
                const explicit = state.writer.frames[depth - 1].key_explicit;

                state.coverage.getPtr(if (explicit) .key_explicit else .key_simple).* += 1;
            },
            .mapping_start, .sequence_start => {
                assert(state.writer.frames[depth - 2].key_explicit);

                state.coverage.getPtr(.key_explicit).* += 1;
            },
            else => unreachable,
        }
    }

    fn invalid_inject(state: *State, scalar: *const Event.Scalar) !void {
        assert(scalar.text.len <= text_bytes_max);
        assert(state.writer.options.utf8 == .checked);

        const text = scalar.text;
        const sequence = invalid_sequences[state.below(invalid_sequences.len)];
        var position = state.below(@intCast(text.len + 1));

        for (0..text.len) |_| {
            if (position == text.len) break;
            if (text[position] & 0xc0 != 0x80) break;

            position += 1;
        }

        const length = text.len + sequence.len;

        @memcpy(state.scratch[0..position], text[0..position]);
        @memcpy(state.scratch[position..][0..sequence.len], sequence);
        @memcpy(state.scratch[position + sequence.len .. length], text[position..]);

        var variant = scalar.*;

        variant.text = state.scratch[0..length];

        const before = std.mem.toBytes(state.writer);
        const written = state.sinks.main.end;

        try std.testing.expectError(error.TextInvalid, state.writer.scalar(&variant));
        try std.testing.expectEqual(written, state.sinks.main.end);
        try std.testing.expectEqualSlices(u8, &before, std.mem.asBytes(&state.writer));

        state.coverage.getPtr(.text_invalid).* += 1;
    }

    fn reparse(state: *State, source: []const u8) ![]const Event {
        assert(source.len <= output_bytes_max);
        assert(state.reparsed.len == event_count_max);

        state.parser.init(&state.parser_text, source);

        for (&state.reparsed, 0..) |*slot, index| {
            const event = state.parser.next() catch |err| {
                std.debug.print("writer: the written bytes do not parse ({t})\n", .{err});
                state.failure_print(.{ .reason = "a parse error", .written = source });

                return err;
            };

            slot.* = event.*;

            if (event.* == .stream_end) return state.reparsed[0 .. index + 1];
        }

        return error.EventsUnbounded;
    }

    fn idempotence_check(
        state: *State,
        reparsed: []const Event,
        options: *const Writer.Options,
    ) !void {
        assert(reparsed.len == state.event_count);
        assert(options.indent >= 1);

        var sink: std.Io.Writer = .fixed(&state.rewritten);
        var writer: Writer = undefined;

        writer.init(&sink, options.*);

        for (reparsed) |*event| try writer.emit(event);

        const written = state.sinks.main.buffered();

        if (!std.mem.eql(u8, written, sink.buffered())) {
            state.failure_print(.{ .reason = "a second write differs", .written = written });
            std.debug.print("--- second write ---\n{s}\n", .{sink.buffered()});

            return error.WriteUnstable;
        }
    }

    fn coverage_record(
        state: *State,
        reparsed: []const Event,
        options: *const Writer.Options,
    ) !void {
        assert(reparsed.len == state.event_count);
        assert(@backingInt(options.layout) <= 2);

        const layout: Counter = switch (options.layout) {
            .block => .layout_block,
            .flow => .layout_flow,
            .preserve => .layout_preserve,
        };

        state.coverage.getPtr(layout).* += 1;

        for (state.events[0..state.event_count], reparsed, 0..) |*original, *written, index| {
            if (original.* != .scalar) continue;

            const pair: ScalarPair = .{ .original = &original.scalar, .written = &written.scalar };

            try state.scalar_record(pair, &state.facts[index]);
        }
    }

    fn scalar_record(state: *State, pair: ScalarPair, fact: *const Fact) !void {
        assert(pair.original.text.len <= text_bytes_max);
        assert(@backingInt(fact.context) <= 3);

        const written = pair.written;

        try state.fallback_record(pair, fact.context);

        if (fact.folded) {
            const counter: Counter = switch (written.style) {
                .double_quoted => .fold_double,
                .folded => .fold_folded,
                .literal => return error.LiteralFolded,
                .plain => .fold_plain,
                .single_quoted => .fold_single,
            };

            state.coverage.getPtr(counter).* += 1;
        }

        const block = written.style == .literal or written.style == .folded;

        if (block) try state.header_record(written);
    }

    fn fallback_record(state: *State, pair: ScalarPair, context: round_trip.Context) !void {
        assert(pair.original.text.len <= text_bytes_max);
        assert(@backingInt(context) <= 3);

        const original = pair.original;
        const written = pair.written;

        if (!style_reachable(pair)) return error.FallbackTowardPlain;

        const substituted = !std.mem.eql(u8, original.text, written.text);

        if (substituted) state.coverage.getPtr(.fallback_null).* += 1;
        if (original.style == written.style) return;

        if (round_trip.fallback_of(original.text, original.style, context)) |fallback| {
            const counter: Counter = switch (fallback) {
                .block_in_flow => .fallback_block_in_flow,
                .content_white => .fallback_content_white,
                .document_marker => .fallback_document_marker,
                .flow_sign => .fallback_flow_sign,
                .indicator_last => .fallback_indicator_last,
                .special => .fallback_special,
            };

            state.coverage.getPtr(counter).* += 1;

            return;
        }

        const single = written.style == .single_quoted;

        const counter: Counter = switch (original.style) {
            .plain => if (single) .fallback_plain_single else .fallback_plain_double,
            .single_quoted => .fallback_single_double,
            .double_quoted, .folded, .literal => return error.FallbackUnexplained,
        };

        state.coverage.getPtr(counter).* += 1;
    }

    fn header_record(state: *State, written: *const Event.Scalar) !void {
        assert(written.style == .literal or written.style == .folded);
        assert(written.mark.index < state.sinks.main.end);

        const output = state.sinks.main.buffered();
        var index: u32 = written.mark.index;

        for (0..2) |_| {
            const property = output[index] == '&' or output[index] == '!';
            if (!property) break;

            index = @intCast(std.mem.findScalarPos(u8, output, index, ' ') orelse output.len);
            index += 1;
        }

        const indicator: u8 = if (written.style == .literal) '|' else '>';
        if (output[index] != indicator) return error.HeaderMissing;

        const digit = std.ascii.isDigit(output[index + 1]);
        const chomping = output[index + 1 + @intFromBool(digit)];

        const chomp: u32 = switch (chomping) {
            '-' => 2,
            '+' => 1,
            else => 0,
        };

        const style: u32 = @intFromBool(written.style == .literal);
        const counter = header_counters[style][chomp][@intFromBool(digit)];

        state.coverage.getPtr(counter).* += 1;
    }

    fn failure_print(state: *const State, failure: Failure) void {
        assert(failure.reason.len > 0);
        assert(failure.written.len <= output_bytes_max);

        std.debug.print("writer: {s}, seed {d}\n--- written ---\n{f}\n--- end ---\n", .{
            failure.reason,
            state.seed,
            std.zig.fmtString(failure.written),
        });
    }
};

pub fn main(gpa: std.mem.Allocator, options: Options) !void {
    assert(options.events_max > 0);
    assert(options.events_max <= std.math.maxInt(u32));

    const state = try gpa.create(State);
    defer gpa.destroy(state);

    state.anchor_count = 0;
    state.coverage = .initFill(0);
    state.depth = 0;
    state.event_count = 0;
    state.key_unique = 0;
    state.pool_used = 0;
    state.prng = .init(options.seed);

    std.debug.print("fuzz writer: seed={d} events_max={d}\n", .{
        options.seed,
        options.events_max,
    });

    for (0..options.events_max) |_| {
        state.seed = state.prng.random().int(u64);
        state.prng = .init(state.seed);

        try state.stream_run();
    }

    coverage_print(&state.coverage);

    if (options.events_max >= coverage_events_min) try coverage_check(&state.coverage);

    std.debug.print("fuzz writer: passed\n", .{});
}

fn coverage_print(coverage: *const Coverage) void {
    assert(coverage.values.len == std.enums.values(Counter).len);
    assert(coverage_events_min > 0);

    for (std.enums.values(Counter)) |counter| {
        std.debug.print("  {t}: {d}\n", .{ counter, coverage.get(counter) });
    }
}

fn coverage_check(coverage: *const Coverage) !void {
    assert(coverage.values.len == std.enums.values(Counter).len);
    assert(coverage_events_min > 0);

    var missing: u32 = 0;

    for (std.enums.values(Counter)) |counter| {
        if (coverage.get(counter) > 0) continue;

        std.debug.print("fuzz writer: {t} was never reached\n", .{counter});

        missing += 1;
    }

    if (missing > 0) return error.CoverageMissing;
}

fn key_position_is(writer: *const Writer) bool {
    assert(writer.depth <= writer_module.depth_max);
    assert(writer.options.indent >= 1);

    if (writer.depth == 0) return false;

    const frame = writer.frames[writer.depth - 1];
    if (!frame.mapping) return false;
    return !frame.value_next;
}

fn node_is(event: *const Event) bool {
    assert(@backingInt(std.meta.activeTag(event.*)) <= 9);
    assert(event_count_max > 0);

    return switch (event.*) {
        .alias, .mapping_start, .scalar, .sequence_start => true,
        else => false,
    };
}

fn context_of(writer: *const Writer) round_trip.Context {
    assert(writer.depth <= writer_module.depth_max);
    assert(writer.options.indent >= 1);

    if (writer.depth == 0) return .root;

    const frame = writer.frames[writer.depth - 1];
    if (!frame.flow) return .block;
    if (frame.mapping) return .flow;
    return .flow_sequence_item;
}

fn slot_source_less(_: void, left: CommentSlot, right: CommentSlot) bool {
    assert(left.text.len > 0);
    assert(right.text.len > 0);

    return @intFromPtr(left.text.ptr) < @intFromPtr(right.text.ptr);
}

fn style_reachable(pair: ScalarPair) bool {
    assert(@backingInt(pair.original.style) <= 4);
    assert(@backingInt(pair.written.style) <= 4);

    const requested = pair.original.style;
    const written = pair.written.style;
    if (written == requested) return true;
    if (written == .double_quoted) return true;
    return requested == .plain and written == .single_quoted;
}
