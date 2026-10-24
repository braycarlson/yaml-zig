const std = @import("std");

const comment_module = @import("comment.zig");
const parser_module = @import("parser.zig");
const scanner_module = @import("scanner.zig");

const assert = std.debug.assert;

const CollectionStyle = parser_module.CollectionStyle;
const Comment = comment_module.Comment;
const Event = parser_module.Event;
const ScalarStyle = parser_module.ScalarStyle;

pub const depth_max: u32 = parser_module.state_capacity;

const comment_indent_none: u32 = std.math.maxInt(u32);
const indent_max: u8 = 9;
const indentation_max: u32 = depth_max * 2 * indent_max;
const key_columns_max: u32 = scanner_module.key_columns_max;
const lane_count: u32 = 32;
const quote_count_max: u32 = std.math.maxInt(u15);
const spaces: [64]u8 = @splat(' ');
const tag_prefix_core = "tag:yaml.org,2002:";
const text_bytes_max: u32 = scanner_module.source_bytes_max;

comptime {
    assert(depth_max == 2 * scanner_module.depth_max + 8);
    assert(indentation_max < std.math.maxInt(i32));
    assert(key_columns_max < quote_count_max);
    assert(std.math.isPowerOfTwo(lane_count));
}

const WriterCapacityError = error{DepthExceeded};
const WriterValueError = error{ EnumerationUnrecognized, TextInvalid };
const WriterError = std.Io.Writer.Error || WriterCapacityError || WriterValueError;

const WriterLayout = enum {
    block,
    flow,
    preserve,
};

const WriterUTF8 = enum {
    checked,
    trusted,
};

const WriterOptions = struct {
    indent: u8 = 2,
    layout: WriterLayout = .preserve,
    sequence_indentless: bool = false,
    utf8: WriterUTF8 = .checked,
    version_directive: bool = false,
    width: u32 = 0,
};

pub const Writer = WriterType(.commented);
pub const WriterQuiet = WriterType(.quiet);
pub const WriterRun = WriterType(.run);

comptime {
    for ([_]type{ WriterQuiet, WriterRun }) |Emitter| {
        assert(@sizeOf(Writer) == @sizeOf(Emitter));
        assert(@alignOf(Writer) == @alignOf(Emitter));

        for (@typeInfo(Writer).@"struct".field_names) |name| {
            assert(@offsetOf(Writer, name) == @offsetOf(Emitter, name));
        }
    }
}

const WriterMode = enum {
    commented,
    quiet,
    run,
};

fn WriterType(comptime mode: WriterMode) type {
    const commented = mode == .commented;
    const block_tracked = mode != .quiet;

    return struct {
        blank_last: bool,
        block_last: bool,
        block_tail: bool,
        column: u32,
        comment_header: []const u8,
        comment_held: bool,
        comment_indent: u32,
        comment_pending: []const u8,
        depth: u32,
        document_count: u32,
        document_state: DocumentState,
        end_previous_explicit: bool,
        end_written: bool,
        frames: [depth_max]Frame,
        indent: i32,
        indention: bool,
        options: Options,
        root_bare: bool,
        sink: *std.Io.Writer,
        start_explicit: bool,
        start_written: bool,
        whitespace: bool,

        const Emitter = @This();

        pub const CapacityError = WriterCapacityError;
        pub const Error = WriterError;
        pub const Layout = WriterLayout;
        pub const Options = WriterOptions;
        pub const UTF8 = WriterUTF8;
        pub const ValueError = WriterValueError;

        pub fn init(writer: *Emitter, sink: *std.Io.Writer, options: Options) void {
            comptime assert(@sizeOf(@TypeOf(options)) <= 16);
            assert(options.indent >= 1);
            assert(options.indent <= indent_max);

            writer.blank_last = false;
            writer.block_last = false;
            writer.block_tail = false;
            writer.column = 0;
            writer.comment_header = "";
            writer.comment_held = false;
            writer.comment_indent = comment_indent_none;
            writer.comment_pending = "";
            writer.depth = 0;
            writer.document_count = 0;
            writer.document_state = .closed;
            writer.end_previous_explicit = false;
            writer.end_written = false;
            writer.indent = -@as(i32, options.indent);
            writer.indention = true;
            writer.options = options;
            writer.root_bare = false;
            writer.sink = sink;
            writer.start_explicit = false;
            writer.start_written = false;
            writer.whitespace = true;
        }

        pub fn emit(writer: *Emitter, event: *const Event) align(64) Error!void {
            assert(writer.depth <= depth_max);

            if (event.* == .stream_start) assert(writer.document_count == 0);

            switch (event.*) {
                .alias => |*reference| try writer.alias(reference),
                .document_end => |*marker| try writer.document_end(marker),
                .document_start => |*marker| try writer.document_begin(marker),
                .mapping_end => try writer.mapping_end(),
                .mapping_start => |*properties| try writer.mapping_begin(properties),
                .scalar => |*value| try writer.scalar(value),
                .sequence_end => try writer.sequence_end(),
                .sequence_start => |*properties| try writer.sequence_begin(properties),
                .stream_end => writer.finish(),
                .stream_start => writer.fresh_assert(),
            }
        }

        pub fn comment(
            writer: *Emitter,
            placement: Comment.Placement,
            text: []const u8,
        ) Error!void {
            assert(@backingInt(placement) <= 2);
            assert(text.len <= text_bytes_max);
            assert(writer.depth <= depth_max);

            switch (writer.options.utf8) {
                .checked => _ = comment_module.lines_check(placement, text) catch {
                    return error.TextInvalid;
                },
                .trusted => if (std.debug.runtime_safety) {
                    assert(comment_module.lines_valid_is(placement, text));
                },
            }

            writer.comment_held = true;

            switch (placement) {
                .foot, .head => try writer.comment_lines_write(placement, text),
                .line => try writer.comment_line_write(text),
            }
        }

        fn comment_line_write(writer: *Emitter, text: []const u8) Error!void {
            assert(text.len > 0);
            assert(text[0] == '#');

            const flow = writer.depth > 0 and writer.frames[writer.depth - 1].flow;

            if (writer.indent_held_is()) {
                if (flow) return writer.comment_lines_write(.foot, text);

                try writer.comment_indent_settle();
            }

            if (writer.depth == 0) {
                const closed = writer.document_state == .closed;
                if (closed) return writer.comment_lines_write(.head, text);
                if (writer.root_bare) return writer.comment_lines_write(.foot, text);
            }

            if (writer.block_tail) return writer.comment_lines_write(.foot, text);

            if (writer.header_position_is()) {
                if (writer.header_held_is()) try writer.comment_header_flush();

                writer.comment_header = text;

                return;
            }

            if (writer.depth == 0) {
                const line_due = writer.pending_held_is() or writer.column == 0;

                if (line_due) {
                    return writer.comment_lines_write(.foot, text);
                }
            }

            if (writer.pending_held_is()) {
                if (!flow) return writer.comment_lines_write(.foot, text);

                try writer.comment_pending_break();
            }

            writer.comment_pending = text;
        }

        fn root_awaited(writer: *const Emitter) bool {
            assert(writer.depth == 0);
            assert(writer.depth <= depth_max);

            return writer.document_state == .pending or writer.document_state == .marked;
        }

        fn header_position_is(writer: *const Emitter) bool {
            assert(writer.depth <= depth_max);
            assert(writer.document_state != .closed or writer.depth == 0);

            if (writer.depth == 0) {
                return writer.document_state == .pending or writer.document_state == .marked;
            }

            const frame = writer.frames[writer.depth - 1];
            if (frame.flow) return false;
            return frame.first or writer.column == 0;
        }

        fn comment_header_flush(writer: *Emitter) Error!void {
            assert(writer.comment_header.len > 0);
            assert(writer.document_state != .closed);

            const marker_column = writer.column == indicator_document_start.text.len;

            const marker_line = writer.start_written and marker_column and writer.depth > 0 and
                writer.frames[0].first;

            const break_due = writer.pending_held_is() or marker_line;

            if (break_due) try writer.break_write();

            writer.comment_pending = writer.comment_header;
            writer.comment_header = "";

            try writer.break_write();
        }

        fn comment_header_settle(writer: *Emitter) Error!void {
            assert(writer.comment_header.len > 0);
            assert(writer.depth <= depth_max);

            if (writer.pending_held_is()) {
                if (writer.depth > 0) {
                    try writer.comment_pending_break();
                } else {
                    try writer.break_write();
                }
            }

            writer.comment_pending = writer.comment_header;
            writer.comment_header = "";
        }

        fn comment_lines_write(
            writer: *Emitter,
            placement: Comment.Placement,
            text: []const u8,
        ) Error!void {
            assert(placement != .line);
            assert(text.len <= text_bytes_max);

            const blank = text.len == 0;

            if (blank) {
                if (writer.blank_repeated_is()) return;
            }

            const target = try writer.comment_target(placement);
            var start: u32 = 0;

            for (0..text.len + 1) |_| {
                const found = std.mem.findScalarPos(u8, text, start, '\n') orelse text.len;
                const end: u32 = @intCast(found);

                try writer.comment_line_body_write(target, text[start..end]);

                if (end == text.len) break;

                start = end + 1;
            }

            writer.comment_lines_finish(target);
            writer.blank_last = blank;
        }

        fn comment_line_body_write(writer: *Emitter, target: u32, text: []const u8) Error!void {
            assert(writer.column == 0);
            assert(target <= indentation_max);
            assert(text.len <= text_bytes_max);

            if (text.len > 0) {
                if (target > 0) try writer.spaces_write(target);

                try writer.sink.writeAll(text);

                writer.blank_last = false;
                writer.block_last = false;
            }

            if (!writer.block_last) try writer.sink.writeByte('\n');

            writer.column = 0;
        }

        fn comment_lines_finish(writer: *Emitter, target: u32) void {
            assert(writer.column == 0);
            assert(target <= indentation_max);

            writer.indention = true;
            writer.whitespace = true;

            if (writer.depth == 0) return;

            const frame = writer.frames[writer.depth - 1];
            const indent_kept = frame.flow or frame.indicated;

            if (indent_kept) writer.comment_indent = target;
        }

        fn comment_indent_settle(writer: *Emitter) Error!void {
            assert(writer.comment_indent != comment_indent_none);
            assert(writer.column == 0);

            const target = writer.comment_indent;

            writer.comment_indent = comment_indent_none;

            try writer.indent_write(target);
        }

        fn comment_target(writer: *Emitter, placement: Comment.Placement) Error!u32 {
            assert(placement != .line);
            assert(writer.depth <= depth_max);

            writer.comment_indent = comment_indent_none;

            if (writer.header_held_is()) try writer.comment_header_flush();

            if (writer.depth == 0) {
                try writer.comment_target_root();

                return 0;
            }

            const frame = &writer.frames[writer.depth - 1];
            const value = frame.mapping and frame.value_next and !frame.key_explicit;

            if (frame.flow) writer.flow_break_mark();

            if (value) {
                if (!frame.indicated) {
                    if (frame.flow) {
                        try writer.flow_indicator_write(&indicator_value_flow);
                    } else {
                        try writer.indicator_write(&indicator_value_simple);
                    }
                }

                frame.indicated = true;
            } else if (frame.flow) {
                const separator_due = placement == .head and !frame.first and !frame.value_next;

                if (separator_due) {
                    try writer.flow_indicator_write(&indicator_separator);

                    frame.first = true;
                }
            }

            if (writer.column > 0) try writer.break_write();

            const continued = value or frame.flow;

            const result: u32 = if (continued)
                writer.continuation_of()
            else
                @intCast(writer.indent);

            assert(result < text_bytes_max);

            return result;
        }

        fn comment_target_root(writer: *Emitter) Error!void {
            assert(writer.depth == 0);
            assert(writer.comment_header.len == 0);

            switch (writer.document_state) {
                .closed => {
                    assert(writer.column == 0);

                    if (writer.root_bare) {
                        try writer.line_write("...");

                        writer.end_previous_explicit = true;
                        writer.root_bare = false;
                    }
                },
                .marked => assert(writer.column == 0),
                .complete, .open => {
                    if (writer.column > 0) try writer.break_write();

                    if (writer.root_bare) {
                        try writer.line_write("...");

                        writer.end_written = true;
                        writer.root_bare = false;
                    }
                },
                .pending => {
                    assert(writer.column == 0);

                    try writer.document_start_write(false);

                    if (writer.column > 0) try writer.break_write();

                    writer.document_state = .marked;
                },
            }
        }

        fn flow_indicator_write(writer: *Emitter, indicator: *const Indicator) Error!void {
            assert(writer.depth > 0);
            assert(writer.frames[writer.depth - 1].flow);

            if (writer.column == 0) try writer.indent_write(writer.continuation_of());

            try writer.indicator_write(indicator);
        }

        fn flow_break_mark(writer: *Emitter) void {
            assert(writer.depth > 0);
            assert(writer.frames[writer.depth - 1].flow);

            var depth = writer.depth;

            for (0..writer.depth) |_| {
                if (depth == 0) break;

                const frame = &writer.frames[depth - 1];
                if (!frame.flow) break;

                frame.broken = true;
                depth -= 1;
            }
        }

        fn comment_pending_write(writer: *Emitter) Error!void {
            assert(writer.comment_pending.len > 0);
            assert(writer.comment_pending[0] == '#');

            const text = writer.comment_pending;

            writer.comment_pending = "";

            const space_due = writer.column > 0 and (!writer.whitespace or !writer.indention);

            if (space_due) {
                try writer.sink.writeByte(' ');

                writer.column +|= 1;
            }

            try writer.sink.writeAll(text);

            writer.blank_last = false;

            writer.column +|= @intCast(text.len);
            writer.indention = false;
            writer.whitespace = false;
        }

        fn comment_pending_break(writer: *Emitter) Error!void {
            assert(writer.comment_pending.len > 0);
            assert(writer.depth > 0);

            const target = writer.continuation_of();

            if (writer.frames[writer.depth - 1].flow) writer.flow_break_mark();

            try writer.break_write();
            try writer.indent_write(target);
        }

        pub fn document_begin(writer: *Emitter, marker: *const Event.DocumentStart) Error!void {
            assert(writer.document_state == .closed);
            assert(writer.depth == 0);
            assert(marker.mark.column <= marker.mark.index);

            writer.document_state = .pending;
            writer.root_bare = false;
            writer.start_explicit = marker.explicit;
            writer.start_written = false;
        }

        pub fn document_end(writer: *Emitter, marker: *const Event.DocumentEnd) Error!void {
            assert(writer.document_state == .complete);
            assert(writer.depth == 0);
            assert(marker.mark.column <= marker.mark.index);

            if (writer.header_held_is()) try writer.comment_header_settle();
            if (writer.column > 0) try writer.break_write();

            const marker_due = marker.explicit and !writer.end_written;

            if (marker_due) try writer.line_write("...");

            writer.document_count += 1;
            writer.document_state = .closed;
            writer.end_previous_explicit = marker.explicit or writer.end_written;
            writer.end_written = false;

            if (writer.end_previous_explicit) writer.root_bare = false;
        }

        pub fn mapping_begin(
            writer: *Emitter,
            properties: *const Event.CollectionStart,
        ) align(64) Error!void {
            assert(writer.depth <= depth_max);
            assert(properties.mark.column <= properties.mark.index);

            try writer.collection_begin(properties, .mapping);
        }

        pub fn mapping_end(writer: *Emitter) align(64) Error!void {
            assert(writer.depth > 0);
            assert(writer.frames[writer.depth - 1].mapping);

            try writer.collection_end(.mapping);
        }

        pub fn sequence_begin(
            writer: *Emitter,
            properties: *const Event.CollectionStart,
        ) align(64) Error!void {
            assert(writer.depth <= depth_max);
            assert(properties.mark.column <= properties.mark.index);

            try writer.collection_begin(properties, .sequence);
        }

        pub fn sequence_end(writer: *Emitter) align(64) Error!void {
            assert(writer.depth > 0);
            assert(!writer.frames[writer.depth - 1].mapping);

            try writer.collection_end(.sequence);
        }

        pub fn scalar(writer: *Emitter, value: *const Event.Scalar) align(64) Error!void {
            assert(value.text.len <= text_bytes_max);
            assert(writer.depth <= depth_max);

            if (writer.depth == 0) assert(writer.root_awaited());

            properties_assert(Event.Scalar, value);

            const utf8 = writer.options.utf8;

            const analysis = if (commented)
                try analysis_of(value.text, utf8)
            else
                try @call(.always_inline, analysis_of, .{ value.text, utf8 });

            const quiet = writer.depth > 0 and writer.quiet_check();

            if (!quiet) try writer.scalar_comments_settle(value);

            if (writer.plain_block_is(value, analysis)) {
                try writer.plain_block_write(value.text);

                writer.block_mark(.none);

                return;
            }

            const context = writer.context_of();
            const style = style_select(value.style, analysis, context);

            const explicit = writer.key_position() and
                !key_simple_is(value, analysis, style, context);

            const slot = writer.slot_of(explicit);
            const empty = empty_plain_is(value, style);
            const block = style == .literal or style == .folded;

            if (quiet) {
                try writer.prefix_write(slot);
            } else {
                try writer.scalar_commented_open(slot, value, style);
            }

            try writer.properties_write(Event.Scalar, value);

            if (!quiet) {
                if (writer.header_held_is()) try writer.comment_header_settle();
            }

            const substituted = empty and context == .flow_sequence_item;
            const key_simple = slot == .block_key_simple or slot == .flow_key_simple;

            try writer.scalar_body_write(&.{
                .analysis = analysis,
                .folding = writer.options.width > 0 and !key_simple,
                .style = style,
                .text = if (substituted) "null" else value.text,
            });

            writer.block_mark(.{ .last = block, .tail = block and writer.column > 0 });

            if (slot == .root) {
                writer.document_state = .complete;
                writer.root_bare = block and breaks_only_is(value.text);
            } else {
                writer.slot_settle(slot);
            }
        }

        noinline fn scalar_comments_settle(
            writer: *Emitter,
            value: *const Event.Scalar,
        ) Error!void {
            assert(value.text.len <= text_bytes_max);
            assert(writer.depth <= depth_max);

            if (writer.indent_held_is()) {
                if (!writer.value_silent_is(value)) try writer.comment_indent_settle();
            }

            const header_held = writer.header_held_is() and writer.depth > 0;

            if (header_held) {
                const block = value.style == .literal or value.style == .folded;

                if (!block) try writer.comment_header_flush();
            }
        }

        noinline fn scalar_commented_open(
            writer: *Emitter,
            slot: Slot,
            value: *const Event.Scalar,
            style: ScalarStyle,
        ) Error!void {
            assert(writer.depth <= depth_max);
            assert(value.text.len <= text_bytes_max);
            assert(style == value.style or value.text.len > 0 or style == .double_quoted);

            const block = style == .literal or style == .folded;
            const empty = empty_plain_is(value, style);
            const header_flushed = writer.header_held_is() and !block;

            if (slot == .root) {
                if (writer.document_state == .pending) try writer.document_start_write(empty);

                const marker_due = empty and !writer.start_written;

                if (marker_due) {
                    assert(writer.column == 0);

                    try writer.indicator_write(&indicator_document_start);

                    writer.start_written = true;
                }

                if (header_flushed) try writer.comment_header_flush();
            } else {
                if (header_flushed) try writer.comment_header_flush();

                try writer.prefix_write(slot);
            }

            if (writer.pending_held_is()) {
                const bare = empty and value.anchor.len == 0 and value.tag.len == 0;
                const pending_breaks = !block and !bare;

                if (pending_breaks) try writer.comment_pending_break();
            }
        }

        fn value_silent_is(writer: *const Emitter, value: *const Event.Scalar) bool {
            assert(value.text.len <= text_bytes_max);
            assert(writer.depth <= depth_max);

            if (writer.depth == 0) return false;
            if (value.text.len > 0) return false;
            if (value.style != .plain) return false;
            if (value.anchor.len > 0) return false;
            if (value.tag.len > 0) return false;

            const frame = writer.frames[writer.depth - 1];
            return frame.flow and frame.mapping and frame.value_next and frame.indicated;
        }

        fn plain_block_is(
            writer: *const Emitter,
            value: *const Event.Scalar,
            analysis: Analysis,
        ) bool {
            assert(value.text.len <= text_bytes_max);
            assert(analysis.quote_single <= value.text.len);
            assert(writer.depth <= depth_max);

            if (writer.depth == 0) return false;
            if (writer.options.width > 0) return false;
            if (value.style != .plain) return false;
            if (value.anchor.len > 0) return false;
            if (value.tag.len > 0) return false;
            if (analysis.empty) return false;
            if (analysis.multiline) return false;
            if (analysis.special) return false;

            const frame = writer.frames[writer.depth - 1];
            if (frame.flow) return false;
            if (!plain_legal_is(analysis, .block)) return false;
            if (!frame.mapping) return true;
            if (frame.value_next) return true;
            return value.text.len + 5 <= key_columns_max;
        }

        fn plain_block_write(writer: *Emitter, text: []const u8) Error!void {
            assert(text.len > 0);
            assert(writer.depth > 0);

            const slot = writer.slot_of(false);

            try writer.prefix_write(slot);

            if (writer.pending_held_is()) try writer.comment_pending_break();
            if (!writer.whitespace) try writer.raw_write(" ");

            try writer.text_write(text);

            writer.slot_settle(slot);
        }

        pub fn alias(writer: *Emitter, reference: *const Event.Alias) align(64) Error!void {
            assert(writer.depth > 0);
            assert(writer.depth <= depth_max);

            anchor_assert(reference.anchor);

            const long = reference.anchor.len + 2 > key_columns_max;
            const slot = writer.slot_of(writer.key_position() and long);

            if (writer.quiet_check()) {
                try writer.prefix_write(slot);
            } else {
                try writer.alias_commented_open(slot);
            }

            try writer.sigil_write('*', reference.anchor);

            writer.block_mark(.none);

            const key_simple = slot == .block_key_simple or slot == .flow_key_simple;

            if (key_simple) try writer.space_write();

            writer.slot_settle(slot);
        }

        noinline fn alias_commented_open(writer: *Emitter, slot: Slot) Error!void {
            assert(writer.depth > 0);
            assert(slot != .root);

            if (writer.indent_held_is()) try writer.comment_indent_settle();
            if (writer.header_held_is()) try writer.comment_header_flush();

            try writer.prefix_write(slot);

            if (writer.pending_held_is()) try writer.comment_pending_break();
        }

        pub fn finish(writer: *const Emitter) void {
            assert(writer.depth == 0);
            assert(writer.document_state == .closed);
        }

        fn fresh_assert(writer: *const Emitter) void {
            assert(writer.document_count == 0);
            assert(writer.document_state == .closed);
            assert(writer.depth == 0);
            assert(writer.column == 0);
        }

        fn collection_begin(
            writer: *Emitter,
            properties: *const Event.CollectionStart,
            kind: CollectionKind,
        ) Error!void {
            assert(writer.depth <= depth_max);
            assert(properties.mark.column <= properties.mark.index);

            if (writer.depth == 0) assert(writer.root_awaited());

            properties_assert(Event.CollectionStart, properties);

            if (writer.depth == depth_max) return error.DepthExceeded;

            const style = writer.collection_style_of(properties.style);
            const slot = writer.slot_of(writer.key_position());
            const brackets = brackets_of(kind);
            const root_fresh = slot == .root and writer.document_state == .pending;

            if (!writer.quiet_check()) {
                try writer.collection_commented_open(slot, style);
            } else if (root_fresh) {
                try writer.document_start_write(false);
            } else if (slot == .root) {
                try writer.collection_commented_open(slot, style);
            } else {
                try writer.prefix_write(slot);
            }

            try writer.properties_write(Event.CollectionStart, properties);

            if (style == .flow) try writer.indicator_write(&brackets.open);

            writer.block_mark(.none);

            if (slot == .root) {
                writer.document_state = .open;
            } else {
                writer.slot_settle(slot);
            }

            const indentless = kind == .sequence and style == .block and
                slot == .block_value_simple and writer.options.sequence_indentless;

            writer.frame_push(.{
                .broken = false,
                .first = true,
                .flow = style == .flow,
                .indentless = indentless,
                .indicated = false,
                .key_explicit = false,
                .mapping = kind == .mapping,
                .value_next = false,
            });
        }

        noinline fn collection_commented_open(
            writer: *Emitter,
            slot: Slot,
            style: CollectionStyle,
        ) Error!void {
            assert(writer.depth < depth_max);
            assert(@backingInt(style) <= 1);

            if (writer.indent_held_is()) try writer.comment_indent_settle();

            if (slot == .root) {
                if (writer.document_state == .pending) try writer.document_start_write(false);
                if (writer.header_held_is()) try writer.comment_header_flush();
            } else {
                if (writer.header_held_is()) try writer.comment_header_flush();

                try writer.prefix_write(slot);
            }

            if (writer.pending_held_is()) {
                if (style == .flow) try writer.comment_pending_break();
            }
        }

        fn collection_end(writer: *Emitter, kind: CollectionKind) align(64) Error!void {
            assert(writer.depth > 0);
            assert(writer.document_state == .open);

            if (!writer.quiet_check()) return writer.collection_commented_end(kind);

            const frame = writer.frames[writer.depth - 1];
            const brackets = brackets_of(kind);

            assert(frame.mapping == (kind == .mapping));
            assert(!frame.value_next);

            if (frame.flow) try writer.indicator_write(&brackets.close);

            writer.frame_pop();

            const block_first = !frame.flow and frame.first;

            if (block_first) {
                const fresh = writer.column == 0 and writer.depth > 0;

                if (fresh) try writer.indent_write(writer.continuation_of());

                try writer.indicator_write(&brackets.empty);
            }

            if (writer.depth == 0) writer.document_state = .complete;
        }

        noinline fn collection_commented_end(writer: *Emitter, kind: CollectionKind) Error!void {
            assert(writer.depth > 0);
            assert(writer.document_state == .open);

            if (writer.indent_held_is()) try writer.comment_indent_settle();

            const frame = writer.frames[writer.depth - 1];
            const brackets = brackets_of(kind);

            assert(frame.mapping == (kind == .mapping));
            assert(!frame.value_next);

            if (writer.header_held_is()) {
                if (frame.flow) {
                    try writer.comment_header_flush();
                } else if (!frame.first) {
                    const header = writer.comment_header;

                    writer.comment_header = "";

                    try writer.comment_lines_write(.foot, header);
                }
            }

            if (frame.flow) {
                if (writer.pending_held_is()) {
                    try writer.break_write();
                    try writer.indent_write(@intCast(writer.indent));
                }

                try writer.indicator_write(&brackets.close);
            }

            writer.frame_pop();

            const block_first = !frame.flow and frame.first;

            if (block_first) {
                const fresh = writer.column == 0 and writer.depth > 0;

                if (fresh) try writer.indent_write(writer.continuation_of());

                try writer.indicator_write(&brackets.empty);
            }

            if (writer.header_held_is()) try writer.comment_header_settle();
            if (writer.depth == 0) writer.document_state = .complete;
        }

        fn frame_push(writer: *Emitter, frame: Frame) void {
            assert(writer.depth < depth_max);
            assert(!frame.broken);

            writer.frames[writer.depth] = frame;
            writer.depth += 1;
            writer.indent += writer.delta_of(frame);

            assert(writer.indent >= 0);
            assert(writer.indent <= indentation_max);
        }

        fn frame_pop(writer: *Emitter) void {
            assert(writer.depth > 0);
            assert(writer.indent >= 0);

            writer.depth -= 1;
            writer.indent -= writer.delta_of(writer.frames[writer.depth]);

            assert(writer.indent >= -@as(i32, writer.options.indent));
        }

        fn delta_of(writer: *const Emitter, frame: Frame) i32 {
            assert(!frame.indentless or !frame.flow);
            assert(writer.options.indent >= 1);

            const step: i32 = writer.options.indent;

            if (frame.indentless) return 0;
            if (!frame.flow) return step;

            const result = 2 * step;

            assert(result > step);

            return result;
        }

        fn key_position(writer: *const Emitter) bool {
            assert(writer.depth <= depth_max);
            assert(writer.document_state != .closed);

            if (writer.depth == 0) return false;

            const frame = writer.frames[writer.depth - 1];
            if (!frame.mapping) return false;
            if (frame.value_next) return false;
            return true;
        }

        fn flow_is(writer: *const Emitter) bool {
            assert(writer.depth <= depth_max);
            assert(writer.document_state != .closed);

            if (writer.depth == 0) return false;
            return writer.frames[writer.depth - 1].flow;
        }

        fn context_of(writer: *const Emitter) Context {
            assert(writer.depth <= depth_max);
            assert(writer.document_state != .closed);

            if (writer.depth == 0) return .root;

            const frame = writer.frames[writer.depth - 1];
            if (!frame.flow) return .block;
            if (frame.mapping) return .flow;
            return .flow_sequence_item;
        }

        fn continuation_of(writer: *const Emitter) u32 {
            assert(writer.depth <= depth_max);
            assert(writer.options.indent >= 1);

            const step: u32 = writer.options.indent;
            if (writer.depth == 0) return step;

            const indent: u32 = @intCast(writer.indent);
            if (writer.frames[writer.depth - 1].flow) return indent;

            const result = indent + step;

            assert(result >= step);

            return result;
        }

        fn collection_style_of(writer: *const Emitter, requested: CollectionStyle) CollectionStyle {
            assert(writer.depth <= depth_max);
            assert(@backingInt(requested) <= 1);

            if (writer.flow_is()) return .flow;

            return switch (writer.options.layout) {
                .block => .block,
                .flow => .flow,
                .preserve => requested,
            };
        }

        fn slot_of(writer: *const Emitter, explicit: bool) Slot {
            assert(writer.depth <= depth_max);

            if (explicit) assert(writer.key_position());

            if (writer.depth == 0) return .root;

            const frame = writer.frames[writer.depth - 1];

            if (!frame.mapping) {
                if (frame.flow) return .flow_sequence_item;
                return .block_sequence_item;
            }

            if (frame.value_next) return value_slot_of(frame);

            if (frame.flow) {
                if (explicit) return .flow_key_explicit;
                return .flow_key_simple;
            }

            if (explicit) return .block_key_explicit;
            return .block_key_simple;
        }

        inline fn prefix_write(writer: *Emitter, slot: Slot) Error!void {
            assert(slot != .root);
            assert(writer.depth > 0);

            const indent: u32 = @intCast(writer.indent);

            switch (slot) {
                .block_key_explicit => {
                    try writer.indent_write(indent);
                    try writer.indicator_write(&indicator_key_block);
                },
                .block_key_simple => try writer.indent_write(indent),
                .block_sequence_item => {
                    try writer.indent_write(indent);
                    try writer.indicator_write(&indicator_entry);
                },
                .block_value_explicit => {
                    try writer.indent_write(indent);
                    try writer.indicator_write(&indicator_value_block);
                },
                .block_value_simple, .flow_value_simple => {
                    try writer.indicator_write(&indicator_value_simple);
                },
                .flow_key_explicit => {
                    try writer.separator_write();
                    try writer.indicator_write(&indicator_key_flow);
                },
                .flow_key_simple, .flow_sequence_item => try writer.separator_write(),
                .flow_value_explicit => try writer.indicator_write(&indicator_value_flow),
                .value_indicated => {},
                .root => unreachable,
            }
        }

        fn blank_repeated_is(writer: *const Emitter) bool {
            assert(writer.depth <= depth_max);

            if (!writer.blank_last) return false;
            if (writer.column > 0) return false;
            if (writer.header_held_is()) return false;
            return !writer.pending_held_is();
        }

        inline fn block_mark(writer: *Emitter, mark: BlockMark) void {
            assert(!mark.tail or mark.last);

            if (!block_tracked) return;

            writer.block_last = mark.last;
            writer.block_tail = mark.tail;
        }

        fn header_held_is(writer: *const Emitter) bool {
            assert(writer.comment_header.len == 0 or writer.comment_header[0] == '#');

            return commented and writer.comment_header.len > 0;
        }

        fn indent_held_is(writer: *const Emitter) bool {
            const indent = writer.comment_indent;

            assert(indent == comment_indent_none or indent <= indentation_max);

            return commented and writer.comment_indent != comment_indent_none;
        }

        fn pending_held_is(writer: *const Emitter) bool {
            assert(writer.comment_pending.len == 0 or writer.comment_pending[0] == '#');

            return commented and writer.comment_pending.len > 0;
        }

        fn quiet_check(writer: *Emitter) bool {
            assert(writer.depth <= depth_max);
            assert(writer.comment_pending.len == 0 or writer.comment_pending[0] == '#');

            if (!commented) return true;
            if (!writer.comment_held) return true;

            const text_held = writer.header_held_is() or writer.pending_held_is();
            const held = text_held or writer.indent_held_is();

            writer.comment_held = held;

            return !held;
        }

        noinline fn separator_broken_write(writer: *Emitter) Error!void {
            assert(writer.depth > 0);
            assert(writer.frames[writer.depth - 1].flow);

            const frame = &writer.frames[writer.depth - 1];

            if (!frame.first) try writer.flow_indicator_write(&indicator_separator);

            const broken = writer.pending_held_is() or frame.broken;

            if (broken) {
                frame.broken = true;

                try writer.indent_write(writer.continuation_of());
            }
        }

        inline fn separator_write(writer: *Emitter) Error!void {
            assert(writer.depth > 0);
            assert(writer.frames[writer.depth - 1].flow);

            const frame = &writer.frames[writer.depth - 1];

            const plain = !commented or
                (!frame.broken and !writer.pending_held_is() and writer.column > 0);

            if (!plain) return writer.separator_broken_write();

            if (!frame.first) try writer.indicator_write(&indicator_separator);
        }

        fn slot_settle(writer: *Emitter, slot: Slot) void {
            assert(slot != .root);
            assert(writer.depth > 0);

            const frame = &writer.frames[writer.depth - 1];

            switch (slot) {
                .block_key_explicit, .flow_key_explicit => {
                    frame.first = false;
                    frame.key_explicit = true;
                    frame.value_next = true;
                },
                .block_key_simple, .flow_key_simple => {
                    frame.first = false;
                    frame.key_explicit = false;
                    frame.value_next = true;
                },
                .block_sequence_item, .flow_sequence_item => frame.first = false,
                .block_value_explicit,
                .block_value_simple,
                .flow_value_explicit,
                .flow_value_simple,
                .value_indicated,
                => {
                    frame.indicated = false;
                    frame.value_next = false;
                },
                .root => unreachable,
            }
        }

        fn document_start_write(writer: *Emitter, empty: bool) Error!void {
            assert(writer.document_state == .pending);
            assert(writer.depth == 0);

            const later = writer.document_count > 0;
            const after_implicit = later and !writer.end_previous_explicit;
            const version = writer.options.version_directive;

            if (version) {
                if (after_implicit) try writer.line_write("...");

                try writer.line_write("%YAML 1.2");
            }

            const marked = writer.start_explicit or version or after_implicit or empty;

            if (marked) try writer.indicator_write(&indicator_document_start);

            writer.start_written = marked;
        }

        fn properties_write(
            writer: *Emitter,
            comptime Payload: type,
            payload: *const Payload,
        ) Error!void {
            assert(payload.anchor.len <= text_bytes_max);
            assert(payload.tag.len <= text_bytes_max);

            if (payload.anchor.len > 0) try writer.sigil_write('&', payload.anchor);
            if (payload.tag.len > 0) try writer.tag_write(payload.tag);
        }

        fn sigil_write(writer: *Emitter, sigil: u8, name: []const u8) Error!void {
            assert(sigil == '&' or sigil == '*');
            assert(name.len > 0);

            if (!writer.whitespace) try writer.raw_write(" ");

            try writer.sink.writeByte(sigil);
            try writer.sink.writeAll(name);

            writer.column +|= @intCast(name.len + 1);
            writer.indention = false;
            writer.whitespace = false;
        }

        fn tag_write(writer: *Emitter, tag: []const u8) Error!void {
            assert(tag.len > 0);
            assert(std.unicode.utf8ValidateSlice(tag));

            const parts = tag_parts_of(tag);

            if (!writer.whitespace) try writer.raw_write(" ");

            try writer.raw_write(parts.head);

            for (parts.body) |byte| {
                if (tag_byte_is(byte, parts.form)) {
                    try writer.raw_write(&.{byte});
                } else {
                    const digits = "0123456789ABCDEF";

                    try writer.raw_write(&.{ '%', digits[byte >> 4], digits[byte & 0xf] });
                }
            }

            if (parts.tail.len > 0) try writer.raw_write(parts.tail);

            writer.indention = false;
            writer.whitespace = false;
        }

        fn scalar_body_write(writer: *Emitter, body: *const Body) Error!void {
            assert(body.text.len <= text_bytes_max);
            assert(@backingInt(body.style) <= 4);

            switch (body.style) {
                .double_quoted => try writer.double_quoted_write(body),
                .folded, .literal => try writer.block_scalar_write(body),
                .plain => try writer.plain_write(body),
                .single_quoted => try writer.single_quoted_write(body),
            }
        }

        fn plain_write(writer: *Emitter, body: *const Body) align(64) Error!void {
            assert(body.style == .plain);
            assert(body.text.len <= text_bytes_max);

            if (body.text.len == 0) {
                if (writer.flow_is()) {
                    if (!writer.whitespace) try writer.space_write();
                }

                writer.indention = false;

                return;
            }

            if (!writer.whitespace) try writer.raw_write(" ");

            const fast = !body.folding and !body.analysis.multiline;

            if (fast) {
                try writer.text_write(body.text);
            } else {
                try writer.lines_write(&.{
                    .continuation = writer.continuation_of(),
                    .folding = body.folding,
                    .quoted = false,
                    .text = body.text,
                });
            }

            writer.indention = false;
            writer.whitespace = false;
        }

        fn single_quoted_write(writer: *Emitter, body: *const Body) align(64) Error!void {
            assert(body.style == .single_quoted);
            assert(body.text.len <= text_bytes_max);

            try writer.indicator_write(&indicator_quote_single_open);

            const clean = !body.analysis.multiline and body.analysis.quote_single == 0;
            const fast = !body.folding and clean;

            if (fast) {
                try writer.text_write(body.text);
            } else {
                try writer.lines_write(&.{
                    .continuation = writer.continuation_of(),
                    .folding = body.folding,
                    .quoted = true,
                    .text = body.text,
                });
            }

            try writer.indicator_write(&indicator_quote_single_close);

            writer.indention = false;
            writer.whitespace = false;
        }

        fn double_quoted_write(writer: *Emitter, body: *const Body) align(64) Error!void {
            assert(body.style == .double_quoted);
            assert(body.text.len <= text_bytes_max);

            try writer.indicator_write(&indicator_quote_double_open);

            const analysis = &body.analysis;
            const clean = !analysis.escape and !analysis.special and !analysis.multiline;
            const fast = !body.folding and clean;

            if (fast) {
                try writer.text_write(body.text);
            } else {
                try writer.escaped_write(body);
            }

            try writer.indicator_write(&indicator_quote_double_close);

            writer.indention = false;
            writer.whitespace = false;
        }

        fn block_scalar_write(writer: *Emitter, body: *const Body) Error!void {
            assert(body.style == .literal or body.style == .folded);
            assert(!writer.flow_is());

            var header: [3]u8 = undefined;
            var length: u32 = 1;
            const text = body.text;

            header[0] = if (body.style == .literal) '|' else '>';

            const digit = writer.depth > 0 and text.len > 0 and blank_or_break_is(text[0]);

            if (digit) {
                header[length] = '0' + writer.options.indent;
                length += 1;
            }

            if (chomping_of(text)) |chomping| {
                header[length] = chomping;
                length += 1;
            }

            try writer.indicator_write(&.{
                .indention = false,
                .separated = true,
                .text = header[0..length],
                .whitespace = false,
            });

            try writer.break_write();

            const block: Block = .{
                .content = writer.continuation_of(),
                .folding = body.folding,
                .text = text,
            };

            if (body.style == .literal) {
                try writer.literal_write(&block);
            } else {
                try writer.folded_write(&block);
            }
        }

        noinline fn lines_write(writer: *Emitter, lines: *const Lines) align(64) Error!void {
            assert(lines.continuation >= 1);
            assert(lines.text.len <= text_bytes_max);

            const text = lines.text;

            const stops: Stops = .{
                .escapes = false,
                .quote_single = lines.quoted,
                .space = lines.folding,
            };

            var breaks = false;
            var index: u32 = 0;

            for (0..text.len) |_| {
                if (index == text.len) break;

                const byte = text[index];

                if (byte == '\n') {
                    if (!breaks) try writer.break_write();

                    try writer.break_write();

                    breaks = true;
                    index += 1;

                    continue;
                }

                if (breaks) try writer.indent_write(lines.continuation);

                breaks = false;

                const step = try writer.line_step_write(lines, index);
                const end = run_end(text, index + step, stops);

                try writer.text_write(text[index + step .. end]);

                index = end;
            }

            if (lines.quoted) {
                if (breaks) try writer.indent_write(lines.continuation);
            }
        }

        fn line_step_write(writer: *Emitter, lines: *const Lines, index: u32) Error!u32 {
            assert(index < lines.text.len);
            assert(lines.text[index] != '\n');

            const text = lines.text;
            const byte = text[index];

            if (byte == '\'') {
                if (!lines.quoted) return 0;

                try writer.raw_write("''");

                return 1;
            }

            if (byte != ' ') return 0;

            if (lines.folding) {
                const fold = writer.column > writer.options.width and
                    fold_point_is(text, index) and !blank_is(text[index + 1]);

                if (fold) {
                    try writer.indent_write(lines.continuation);

                    return 1;
                }
            }

            try writer.raw_write(" ");

            return 1;
        }

        noinline fn escaped_write(writer: *Emitter, body: *const Body) align(64) Error!void {
            assert(body.style == .double_quoted);
            assert(body.text.len <= text_bytes_max);

            const text = body.text;
            const stops: Stops = .{ .escapes = true, .quote_single = false, .space = body.folding };
            const continuation = writer.continuation_of();
            var index: u32 = 0;

            for (0..text.len) |_| {
                if (index == text.len) break;

                const end = run_end(text, index, stops);

                if (end > index) {
                    try writer.text_write(text[index..end]);

                    index = end;

                    continue;
                }

                if (text[index] != ' ') {
                    index += try writer.escape_stop_write(text, index);

                    continue;
                }

                const fold = writer.column > writer.options.width and fold_point_is(text, index);

                if (fold) {
                    try writer.indent_write(continuation);

                    if (blank_is(text[index + 1])) try writer.raw_write("\\");
                } else {
                    try writer.raw_write(" ");
                }

                index += 1;
            }
        }

        fn escape_stop_write(writer: *Emitter, text: []const u8, index: u32) Error!u32 {
            assert(index < text.len);
            assert(text[index] != ' ');

            const byte = text[index];

            if (byte == '\t') {
                try writer.raw_write("\t");

                return 1;
            }

            if (byte < 0x80) {
                try writer.escape_write(byte);

                return 1;
            }

            const special = special_length_of(text, index);

            if (special > 0) {
                try writer.escape_write(codepoint_of(text[index..][0..special]));

                return special;
            }

            const length = sequence_length_of(text, index);

            try writer.text_write(text[index..][0..length]);

            return length;
        }

        fn escape_write(writer: *Emitter, codepoint: u21) Error!void {
            assert(codepoint <= 0x10ffff);
            assert(codepoint != ' ');

            const name = escape_name_of(codepoint);
            if (name.len > 0) return writer.raw_write(name);

            const digits = "0123456789ABCDEF";
            const width: u32 = if (codepoint <= 0xff) 2 else if (codepoint <= 0xffff) 4 else 8;
            var buffer: [10]u8 = undefined;

            buffer[0] = '\\';

            buffer[1] = switch (width) {
                2 => 'x',
                4 => 'u',
                else => 'U',
            };

            for (0..width) |step| {
                const shift: u5 = @intCast(4 * (width - 1 - step));

                buffer[2 + step] = digits[(codepoint >> shift) & 0xf];
            }

            try writer.raw_write(buffer[0 .. 2 + width]);
        }

        noinline fn literal_write(writer: *Emitter, block: *const Block) align(64) Error!void {
            assert(block.content >= 1);
            assert(writer.column == 0);

            const text = block.text;
            var index: u32 = 0;

            for (0..text.len) |_| {
                if (index == text.len) break;

                if (text[index] == '\n') {
                    try writer.break_write();

                    index += 1;

                    continue;
                }

                const stops: Stops = .{ .escapes = false, .quote_single = false, .space = false };
                const end = run_end(text, index, stops);

                try writer.indent_write(block.content);
                try writer.text_write(text[index..end]);

                index = end;
            }
        }

        noinline fn folded_write(writer: *Emitter, block: *const Block) align(64) Error!void {
            assert(block.content >= 1);
            assert(writer.column == 0);

            const text = block.text;
            var line: Line = .{ .blank = false, .start = true };
            var index: u32 = 0;

            for (0..text.len) |_| {
                if (index == text.len) break;

                if (text[index] == '\n') {
                    if (!line.start) try writer.folded_break_write(block, index, &line);

                    try writer.break_write();

                    line.start = true;
                    index += 1;

                    continue;
                }

                if (line.start) {
                    try writer.indent_write(block.content);

                    line.blank = blank_is(text[index]);
                }

                const fold = !line.start and !line.blank and block.folding and
                    writer.column > writer.options.width and folded_point_is(text, index);

                line.start = false;

                if (fold) {
                    try writer.indent_write(block.content);

                    index += 1;

                    continue;
                }

                const stops: Stops = .{
                    .escapes = false,
                    .quote_single = false,
                    .space = block.folding,
                };

                const end = run_end(text, index + 1, stops);

                try writer.text_write(text[index..end]);

                index = end;
            }
        }

        fn folded_break_write(
            writer: *Emitter,
            block: *const Block,
            index: u32,
            line: *const Line,
        ) Error!void {
            assert(index < block.text.len);
            assert(!line.start);

            if (line.blank) return;

            const next = std.mem.findNonePos(u8, block.text, index, "\n") orelse return;
            if (blank_is(block.text[next])) return;

            try writer.break_write();
        }

        inline fn indent_write(writer: *Emitter, target: u32) Error!void {
            assert(target <= indentation_max);
            assert(writer.options.indent >= 1);

            var kept = writer.indention and
                (writer.column < target or (writer.column == target and writer.whitespace));

            if (writer.pending_held_is()) {
                try writer.comment_pending_write();

                kept = false;
            }

            const unused = writer.sink.unusedCapacitySlice();

            if (target < unused.len) {
                var count: u32 = 0;

                if (!kept) {
                    unused[0] = '\n';
                    count = 1;
                    writer.column = 0;
                }

                const pad = target -| writer.column;

                spaces_fill(unused[count..], pad);
                writer.sink.advance(count + pad);
                writer.column +|= pad;
            } else {
                if (!kept) try writer.break_write();
                if (writer.column < target) try writer.spaces_write(target - writer.column);
            }

            writer.indention = true;
            writer.whitespace = true;
        }

        fn spaces_write(writer: *Emitter, count: u32) Error!void {
            assert(count > 0);
            assert(count <= indentation_max);

            var remaining = count;

            for (0..@divFloor(count, spaces.len) + 1) |_| {
                if (remaining == 0) break;

                const chunk: u32 = @min(remaining, spaces.len);

                try writer.sink.writeAll(spaces[0..chunk]);

                remaining -= chunk;
            }

            writer.column +|= count;
        }

        inline fn indicator_write(writer: *Emitter, indicator: *const Indicator) Error!void {
            assert(indicator.text.len > 0);
            assert(indicator.text.len <= 3);

            const separated = indicator.separated and !writer.whitespace;
            const offset: u32 = @intFromBool(separated);
            const length: u32 = @intCast(indicator.text.len + offset);
            const unused = writer.sink.unusedCapacitySlice();
            const room = length <= unused.len;

            if (room) {
                const text = indicator.text;

                unused[0] = ' ';

                switch (text.len) {
                    1 => unused[offset] = text[0],
                    2 => unused[offset..][0..2].* = text[0..2].*,
                    3 => unused[offset..][0..3].* = text[0..3].*,
                    else => unreachable,
                }

                writer.sink.advance(length);
            } else {
                if (separated) try writer.sink.writeByte(' ');

                try writer.sink.writeAll(indicator.text);
            }

            writer.column +|= length;
            writer.indention = writer.indention and indicator.indention;
            writer.whitespace = indicator.whitespace;
        }

        fn space_write(writer: *Emitter) Error!void {
            assert(!writer.whitespace);
            assert(writer.column > 0);

            try writer.raw_write(" ");

            writer.whitespace = true;
        }

        fn break_write(writer: *Emitter) Error!void {
            assert(writer.depth <= depth_max);
            assert(writer.document_state != .closed);

            if (writer.pending_held_is()) try writer.comment_pending_write();

            try writer.sink.writeByte('\n');

            if (block_tracked) {
                writer.blank_last = false;
                writer.block_last = writer.block_tail;
                writer.block_tail = false;
            }

            writer.column = 0;
            writer.indention = true;
            writer.whitespace = true;
        }

        fn line_write(writer: *Emitter, text: []const u8) Error!void {
            assert(text.len > 0);
            assert(writer.column == 0);

            try writer.sink.writeAll(text);
            try writer.sink.writeByte('\n');

            writer.blank_last = false;

            writer.block_mark(.none);
            writer.indention = true;
            writer.whitespace = true;
        }

        fn raw_write(writer: *Emitter, bytes: []const u8) Error!void {
            assert(bytes.len > 0);
            assert(bytes.len <= 10);

            if (bytes.len == 1) {
                try writer.sink.writeByte(bytes[0]);
            } else {
                try writer.sink.writeAll(bytes);
            }

            writer.column +|= @intCast(bytes.len);
        }

        inline fn text_write(writer: *Emitter, text: []const u8) Error!void {
            assert(text.len <= text_bytes_max);
            assert(writer.depth <= depth_max);

            if (text.len == 0) return;

            const unused = writer.sink.unusedCapacitySlice();

            if (text.len > unused.len) {
                try writer.sink.writeAll(text);
            } else {
                @memcpy(unused[0..text.len], text);
                writer.sink.advance(text.len);
            }

            const columns = if (writer.options.width > 0) columns_of(text) else text.len;

            writer.column +|= @intCast(columns);
            writer.indention = false;
            writer.whitespace = false;
        }
    };
}

const DocumentState = enum(u8) {
    closed,
    complete,
    marked,
    open,
    pending,
};

const Frame = packed struct(u8) {
    broken: bool,
    first: bool,
    flow: bool,
    indentless: bool,
    indicated: bool,
    key_explicit: bool,
    mapping: bool,
    value_next: bool,
};

const BlockMark = struct {
    last: bool,
    tail: bool,

    const none: BlockMark = .{ .last = false, .tail = false };
};

const CollectionKind = enum {
    mapping,
    sequence,
};

const Context = enum {
    block,
    flow,
    flow_sequence_item,
    root,
};

const Slot = enum {
    block_key_explicit,
    block_key_simple,
    block_sequence_item,
    block_value_explicit,
    block_value_simple,
    flow_key_explicit,
    flow_key_simple,
    flow_sequence_item,
    flow_value_explicit,
    flow_value_simple,
    root,
    value_indicated,
};

const Indicator = struct {
    indention: bool,
    separated: bool,
    text: []const u8,
    whitespace: bool,
};

const Brackets = struct {
    close: Indicator,
    empty: Indicator,
    open: Indicator,
};

const Body = struct {
    analysis: Analysis,
    folding: bool,
    style: ScalarStyle,
    text: []const u8,
};

const Lines = struct {
    continuation: u32,
    folding: bool,
    quoted: bool,
    text: []const u8,
};

const Block = struct {
    content: u32,
    folding: bool,
    text: []const u8,
};

const Line = struct {
    blank: bool,
    start: bool,
};

const Stops = struct {
    escapes: bool,
    quote_single: bool,
    space: bool,
};

const TagForm = enum {
    shorthand,
    verbatim,
};

const TagParts = struct {
    body: []const u8,
    form: TagForm,
    head: []const u8,
    tail: []const u8,
};

const Analysis = packed struct(u32) {
    break_white: bool,
    colon_unsafe: bool,
    content_white_first: bool,
    empty: bool,
    escape: bool,
    flow_indicator: bool,
    flow_unsafe_first: bool,
    hash_after_white: bool,
    indicator_first: bool,
    leading_break: bool,
    leading_white: bool,
    marker: bool,
    multiline: bool,
    quote_single: u15,
    special: bool,
    trailing_break: bool,
    trailing_white: bool,
    white_break: bool,
};

const Class = packed struct(u16) {
    ends: u4,
    starts: u4,
    control: bool,
    escape: bool,
    flow: bool,
    high: bool,
    lead: bool,
    line_feed: bool,
    quote_single: bool,
    padding: u1,
};

const Scan = struct {
    pairs: u4,
    previous: Class,
    quotes: u32,
    seen: u16,
    special: bool,

    inline fn feed(scan: *Scan, text: []const u8, range: Range) void {
        assert(range.start < range.end);
        assert(range.end <= text.len);

        var seen: u16 = 0;

        for (text[range.start..range.end]) |byte| seen |= @as(u16, @bitCast(classes[byte]));

        const local: Class = @bitCast(seen);
        const paired = local.starts != 0 or scan.previous.starts != 0;
        const counted = paired or local.quote_single;

        if (counted) scan.pairs_feed(text, range);

        scan.previous = classes[text[range.end - 1]];
        scan.seen |= seen;

        if (local.lead) scan.special_find(text, range);
    }

    fn pairs_feed(scan: *Scan, text: []const u8, range: Range) void {
        assert(range.start < range.end);
        assert(range.end <= text.len);

        var pairs = scan.pairs;
        var previous = scan.previous;
        var quotes = scan.quotes;

        for (text[range.start..range.end]) |byte| {
            const class = classes[byte];

            pairs |= previous.starts & class.ends;
            quotes += @intFromBool(class.quote_single);
            previous = class;
        }

        scan.pairs = pairs;
        scan.quotes = quotes;
    }

    fn special_find(scan: *Scan, text: []const u8, range: Range) void {
        assert(range.start <= range.end);
        assert(range.end <= text.len);

        for (text[range.start..range.end], range.start..) |byte, index| {
            if (!classes[byte].lead) continue;

            if (special_length_of(text, @intCast(index)) > 0) {
                scan.special = true;

                return;
            }
        }
    }

    fn window_feed(scan: *Scan, text: []const u8, window: Window) void {
        assert(window.index + lane_count <= text.len);
        assert(window.fresh != 0);

        const chunk: Chunk = text[window.index..][0..lane_count].*;
        const fresh = window.fresh;
        const carry = scan.previous.starts;
        const line_feed = lanes_equal(&chunk, '\n');
        const tab = lanes_equal(&chunk, '\t');
        const white = lanes_equal(&chunk, ' ') | tab;
        const colon = lanes_equal(&chunk, ':');
        const line_feed_before = (line_feed << 1) | @intFromBool(carry & pair_break_white != 0);
        const white_before = (white << 1) | @intFromBool(carry & pair_white_break != 0);
        const colon_before = (colon << 1) | @intFromBool(carry & pair_colon != 0);
        const blank_before = line_feed_before | white_before;
        const hash = lanes_equal(&chunk, '#');
        const quote = lanes_equal(&chunk, '\'') & fresh;

        if (line_feed_before & white & fresh != 0) scan.pairs |= pair_break_white;
        if (white_before & line_feed & fresh != 0) scan.pairs |= pair_white_break;
        if (colon_before & (white | line_feed) & fresh != 0) scan.pairs |= pair_colon;
        if (blank_before & hash & fresh != 0) scan.pairs |= pair_hash;

        const below: Mask = @bitCast(@as(Lanes, @intFromBool(chunk < @as(Chunk, @splat(0x20)))));
        const control = (below & ~tab & ~line_feed) | lanes_equal(&chunk, 0x7f);
        const escape = lanes_equal(&chunk, '"') | lanes_equal(&chunk, '\\');
        const folded: Chunk = chunk | @as(Chunk, @splat(0x20));
        const brackets = lanes_equal(&folded, '{') | lanes_equal(&folded, '}');
        const flow = brackets | lanes_equal(&chunk, ',');
        const high: Mask = @bitCast(@as(Lanes, @intFromBool(chunk >= @as(Chunk, @splat(0x80)))));
        const lead_c2 = lanes_equal(&chunk, 0xc2);
        const lead = lead_c2 | lanes_equal(&chunk, 0xe2) | lanes_equal(&chunk, 0xef);

        const class: Class = .{
            .ends = 0,
            .starts = 0,
            .control = control & fresh != 0,
            .escape = escape & fresh != 0,
            .flow = flow & fresh != 0,
            .high = high & fresh != 0,
            .lead = lead & fresh != 0,
            .line_feed = line_feed & fresh != 0,
            .quote_single = quote != 0,
            .padding = 0,
        };

        scan.seen |= @as(u16, @bitCast(class));
        scan.quotes += @popCount(quote);
        scan.previous = classes[text[window.index + lane_count - 1]];

        if (class.lead) scan.leads_check(text, .{ .fresh = lead & fresh, .index = window.index });
    }

    fn leads_check(scan: *Scan, text: []const u8, window: Window) void {
        assert(window.index + lane_count <= text.len);
        assert(window.fresh != 0);

        var leads = window.fresh;

        for (0..lane_count) |_| {
            if (leads == 0) return;

            const lane: u32 = @ctz(leads);

            if (special_length_of(text, window.index + lane) > 0) {
                scan.special = true;

                return;
            }

            leads &= leads - 1;
        }
    }

    fn windows_feed(scan: *Scan, text: []const u8) void {
        assert(text.len >= lane_count);
        assert(text.len <= text_bytes_max);

        var index: u32 = 0;

        for (0..@divFloor(text.len, lane_count)) |_| {
            scan.window_feed(text, .{ .fresh = mask_full, .index = index });

            index += lane_count;
        }

        const tail: u32 = @intCast(text.len - index);

        if (tail > 0) {
            const shift: std.math.Log2Int(Mask) = @intCast(lane_count - tail);
            const start: u32 = @intCast(text.len - lane_count);

            scan.window_feed(text, .{ .fresh = mask_full << shift, .index = start });
        }

        assert(scan.previous == classes[text[text.len - 1]]);
    }
};

const Range = struct {
    end: u32,
    start: u32,
};

const Window = struct {
    fresh: Mask,
    index: u32,
};

const Chunk = @Vector(lane_count, u8);
const Lanes = @Vector(lane_count, u1);
const Mask = @Int(.unsigned, lane_count);
const class_none: Class = @bitCast(@as(u16, 0));
const classes: [256]Class = classes_build();
const escape_stops: [256]bool = escape_stops_build();
const pair_break_white: u4 = 1;
const pair_colon: u4 = 4;
const pair_hash: u4 = 8;
const pair_white_break: u4 = 2;
const indicators_always: [256]bool = byte_set_build(",[]{}#&*!|>'\"%@`");
const indicators_spaced: [256]bool = byte_set_build("-?:");
const mask_full: Mask = std.math.maxInt(Mask);
const analysis_none: Analysis = @bitCast(@as(u32, 0));
const firsts: [256]Analysis = firsts_build();
const lasts: [256]Analysis = lasts_build();
const pairings: [16]Analysis = pairings_build();

const analysis_empty: Analysis = analysis: {
    var result = analysis_none;

    result.empty = true;

    break :analysis result;
};

const indicator_document_start: Indicator = .{
    .indention = false,
    .separated = true,
    .text = "---",
    .whitespace = false,
};

const indicator_entry: Indicator = .{
    .indention = true,
    .separated = true,
    .text = "-",
    .whitespace = false,
};

const indicator_key_block: Indicator = .{
    .indention = true,
    .separated = true,
    .text = "?",
    .whitespace = false,
};

const indicator_key_flow: Indicator = .{
    .indention = false,
    .separated = true,
    .text = "?",
    .whitespace = false,
};

const indicator_quote_double_close: Indicator = .{
    .indention = false,
    .separated = false,
    .text = "\"",
    .whitespace = false,
};

const indicator_quote_double_open: Indicator = .{
    .indention = false,
    .separated = true,
    .text = "\"",
    .whitespace = false,
};

const indicator_quote_single_close: Indicator = .{
    .indention = false,
    .separated = false,
    .text = "'",
    .whitespace = false,
};

const indicator_quote_single_open: Indicator = .{
    .indention = false,
    .separated = true,
    .text = "'",
    .whitespace = false,
};

const indicator_separator: Indicator = .{
    .indention = false,
    .separated = false,
    .text = ",",
    .whitespace = false,
};

const indicator_value_block: Indicator = .{
    .indention = true,
    .separated = true,
    .text = ":",
    .whitespace = false,
};

const indicator_value_flow: Indicator = .{
    .indention = false,
    .separated = true,
    .text = ":",
    .whitespace = false,
};

const indicator_value_simple: Indicator = .{
    .indention = false,
    .separated = false,
    .text = ":",
    .whitespace = false,
};

const brackets_mapping: Brackets = .{
    .close = .{ .indention = false, .separated = false, .text = "}", .whitespace = false },
    .empty = .{ .indention = false, .separated = true, .text = "{}", .whitespace = false },
    .open = .{ .indention = false, .separated = true, .text = "{", .whitespace = true },
};

const brackets_sequence: Brackets = .{
    .close = .{ .indention = false, .separated = false, .text = "]", .whitespace = false },
    .empty = .{ .indention = false, .separated = true, .text = "[]", .whitespace = false },
    .open = .{ .indention = false, .separated = true, .text = "[", .whitespace = true },
};

pub fn blank_quiet_is(writer: *const Writer) bool {
    assert(writer.depth <= depth_max);
    assert(writer.document_state != .closed or writer.depth == 0);

    if (writer.depth == 0) return false;

    const frame = &writer.frames[writer.depth - 1];
    const value = frame.mapping and frame.value_next and !frame.key_explicit;

    if (frame.flow) return false;
    if (frame.indicated) return false;
    return !value;
}

pub fn blank_quiet_write(writer: *Writer) Writer.Error!void {
    assert(blank_quiet_is(writer));
    assert(writer.quiet_check());
    assert(writer.comment_indent == comment_indent_none);

    if (writer.blank_repeated_is()) return;

    if (writer.column > 0) try writer.break_write();
    if (!writer.block_last) try writer.sink.writeByte('\n');

    writer.blank_last = true;
    writer.column = 0;
    writer.indention = true;
    writer.whitespace = true;

    assert(writer.quiet_check());
}

pub fn line_append(writer: *Writer, text: []const u8) Writer.Error!void {
    assert(line_append_is(writer));
    assert(text.len > 0);
    assert(text[0] == '#');

    writer.comment_pending = text;

    try writer.comment_pending_write();

    assert(writer.quiet_check());
}

pub fn line_append_is(writer: *Writer) bool {
    assert(writer.depth <= depth_max);
    assert(writer.comment_pending.len == 0 or writer.comment_pending[0] == '#');

    if (writer.depth == 0) return false;
    if (writer.column == 0) return false;
    if (writer.block_tail) return false;
    if (quiet_enter(writer) == null) return false;

    const frame = &writer.frames[writer.depth - 1];
    if (frame.first) return false;
    return !frame.value_next;
}

pub fn pending_flush(writer: *Writer) Writer.Error!bool {
    assert(writer.depth <= depth_max);
    assert(writer.comment_pending.len == 0 or writer.comment_pending[0] == '#');

    if (writer.depth == 0) return false;
    if (writer.column == 0) return false;
    if (writer.block_tail) return false;
    if (writer.header_held_is()) return false;
    if (writer.indent_held_is()) return false;
    if (!writer.pending_held_is()) return false;

    const frame = &writer.frames[writer.depth - 1];
    if (frame.flow) return false;
    if (frame.first) return false;
    if (frame.value_next) return false;

    try writer.comment_pending_write();

    assert(writer.quiet_check());

    return true;
}

pub fn quiet_enter(writer: *Writer) ?*WriterRun {
    assert(writer.depth <= depth_max);
    assert(writer.document_state != .closed or writer.depth == 0);

    if (writer.options.width > 0) return null;

    if (writer.depth > 0) {
        if (writer.frames[writer.depth - 1].flow) return null;
    }

    if (!writer.quiet_check()) return null;
    return @ptrCast(writer);
}

pub fn comment_single_write(
    writer: *Writer,
    placement: Comment.Placement,
    text: []const u8,
) Writer.Error!void {
    assert(@backingInt(placement) <= 2);
    assert(writer.options.utf8 == .trusted);

    if (std.debug.runtime_safety) assert(std.mem.findScalar(u8, text, '\n') == null);

    if (placement == .line) return writer.comment(placement, text);

    if (std.debug.runtime_safety) assert(comment_module.lines_valid_is(placement, text));

    const blank = text.len == 0;

    if (blank) {
        if (writer.blank_repeated_is()) return;
    }

    writer.comment_held = true;

    const target = try writer.comment_target(placement);

    try writer.comment_line_body_write(target, text);
    writer.comment_lines_finish(target);
    writer.blank_last = blank;
}

fn brackets_of(kind: CollectionKind) *const Brackets {
    assert(brackets_mapping.open.whitespace);
    assert(brackets_sequence.open.whitespace);

    return switch (kind) {
        .mapping => &brackets_mapping,
        .sequence => &brackets_sequence,
    };
}

fn value_slot_of(frame: Frame) Slot {
    assert(frame.mapping);
    assert(frame.value_next);

    if (frame.indicated) return .value_indicated;

    if (frame.flow) {
        if (frame.key_explicit) return .flow_value_explicit;
        return .flow_value_simple;
    }

    if (frame.key_explicit) return .block_value_explicit;
    return .block_value_simple;
}

fn properties_assert(comptime Payload: type, payload: *const Payload) void {
    assert(payload.anchor.len <= text_bytes_max);
    assert(payload.tag.len <= text_bytes_max);

    if (payload.tag.len > 0) assert(std.unicode.utf8ValidateSlice(payload.tag));
    if (payload.anchor.len > 0) anchor_assert(payload.anchor);
}

fn anchor_assert(anchor: []const u8) void {
    assert(anchor.len > 0);
    assert(std.mem.findAny(u8, anchor, " \t\n\r\x00,[]{}") == null);
    assert(std.mem.find(u8, anchor, "\xef\xbb\xbf") == null);
}

fn empty_plain_is(value: *const Event.Scalar, style: ScalarStyle) bool {
    assert(value.text.len <= text_bytes_max);

    if (value.text.len == 0) assert(style == value.style or style == .double_quoted);

    if (style != .plain) return false;
    if (value.text.len > 0) return false;
    if (value.anchor.len > 0) return false;
    return value.tag.len == 0;
}

fn key_simple_is(
    value: *const Event.Scalar,
    analysis: Analysis,
    style: ScalarStyle,
    context: Context,
) bool {
    assert(context != .root);
    assert(context != .flow_sequence_item);

    if (analysis.multiline) assert(!analysis.empty);
    if (style != .double_quoted) assert(!analysis.special);

    const length: u64 = value.text.len;
    const quotes: u64 = analysis.quote_single;

    const text_bound: u64 = switch (style) {
        .double_quoted => 4 * length + 2,
        .folded, .literal => return false,
        .plain => if (analysis.multiline) return false else length,
        .single_quoted => if (analysis.multiline) return false else length + quotes + 2,
    };

    const bound = value.anchor.len + 2 + 3 * value.tag.len + 3 + text_bound;
    if (bound > key_columns_max) return false;
    if (value.text.len > 0) return true;
    if (context == .block) return false;
    if (value.anchor.len > 0) return false;
    return value.tag.len == 0;
}

fn style_select(requested: ScalarStyle, analysis: Analysis, context: Context) ScalarStyle {
    assert(analysis.quote_single <= quote_count_max);
    assert(@backingInt(requested) <= 4);

    if (analysis.special) return .double_quoted;

    return switch (requested) {
        .double_quoted => .double_quoted,
        .folded, .literal => block_style_select(requested, analysis, context),
        .plain => plain_style_select(analysis, context),
        .single_quoted => single_style_select(analysis),
    };
}

fn block_style_select(requested: ScalarStyle, analysis: Analysis, context: Context) ScalarStyle {
    assert(requested == .literal or requested == .folded);
    assert(!analysis.special);

    return switch (context) {
        .block => requested,
        .flow, .flow_sequence_item => .double_quoted,
        .root => if (analysis.content_white_first) .double_quoted else requested,
    };
}

fn plain_style_select(analysis: Analysis, context: Context) ScalarStyle {
    assert(!analysis.special);
    assert(analysis.quote_single <= quote_count_max);

    if (plain_legal_is(analysis, context)) return .plain;
    return single_style_select(analysis);
}

fn single_style_select(analysis: Analysis) ScalarStyle {
    assert(!analysis.special);
    assert(analysis.quote_single <= quote_count_max);

    if (analysis.break_white) return .double_quoted;
    if (analysis.white_break) return .double_quoted;
    return .single_quoted;
}

fn plain_legal_is(analysis: Analysis, context: Context) bool {
    assert(!analysis.special);
    assert(analysis.quote_single <= quote_count_max);

    if (analysis.empty) return true;
    if (analysis.leading_white) return false;
    if (analysis.trailing_white) return false;
    if (analysis.leading_break) return false;
    if (analysis.trailing_break) return false;
    if (analysis.break_white) return false;
    if (analysis.white_break) return false;
    if (analysis.marker) return false;
    if (analysis.indicator_first) return false;
    if (analysis.colon_unsafe) return false;
    if (analysis.hash_after_white) return false;
    if (context == .block) return true;
    if (context == .root) return true;
    if (analysis.flow_indicator) return false;
    return !analysis.flow_unsafe_first;
}

fn analysis_of(text: []const u8, utf8: Writer.UTF8) align(64) error{TextInvalid}!Analysis {
    assert(text.len <= text_bytes_max);
    assert(@backingInt(utf8) <= 1);

    if (text.len == 0) return analysis_empty;

    var scan: Scan = .{
        .pairs = 0,
        .previous = class_none,
        .quotes = 0,
        .seen = 0,
        .special = false,
    };

    if (text.len < lane_count) {
        scan.feed(text, .{ .end = @intCast(text.len), .start = 0 });
    } else {
        scan.windows_feed(text);
    }

    const seen: Class = @bitCast(scan.seen);

    if (seen.high) {
        if (utf8 == .checked) {
            if (!std.unicode.utf8ValidateSlice(text)) return error.TextInvalid;
        }
    }

    return analysis_assemble(text, &scan);
}

inline fn analysis_assemble(text: []const u8, scan: *const Scan) Analysis {
    assert(text.len <= text_bytes_max);
    assert(scan.quotes <= text.len);

    if (text.len == 0) return analysis_empty;

    const seen: Class = @bitCast(scan.seen);
    const first = text[0];
    const pairs = scan.pairs | (scan.previous.starts & pair_colon);
    const edges = @as(u32, @bitCast(firsts[first])) | @as(u32, @bitCast(lasts[text[text.len - 1]]));

    var result: Analysis = @bitCast(edges | @as(u32, @bitCast(pairings[pairs])));

    result.escape = seen.escape;
    result.flow_indicator = seen.flow;
    result.multiline = seen.line_feed;
    result.quote_single = @intCast(@min(scan.quotes, quote_count_max));
    result.special = seen.control or scan.special;

    if (indicators_spaced[first]) {
        result.indicator_first = text.len == 1 or blank_or_break_is(text[1]);
    }

    switch (first) {
        '-', '.' => result.marker = marker_is(text),
        '\n' => result.content_white_first = content_white_first_is(text),
        else => {},
    }

    assert(!result.empty);
    assert(result.leading_break == (first == '\n'));

    return result;
}

fn lanes_equal(chunk: *const Chunk, comptime byte: u8) Mask {
    comptime assert(byte != 0);
    comptime assert(lane_count == @bitSizeOf(Mask));

    const lanes: Lanes = @intFromBool(chunk.* == @as(Chunk, @splat(byte)));
    return @bitCast(lanes);
}

fn spaces_fill(target: []u8, count: u32) void {
    assert(count <= target.len);
    assert(count <= indentation_max);

    if (count > spaces.len) return @memset(target[0..count], ' ');
    if (target.len < spaces.len) return @memset(target[0..count], ' ');

    target[0..spaces.len].* = spaces;
}

fn special_length_of(text: []const u8, index: u32) u32 {
    assert(index < text.len);
    assert(text.len <= text_bytes_max);

    const remaining = text.len - index;

    switch (text[index]) {
        0xc2 => {
            if (remaining < 2) return 0;
            if (text[index + 1] < 0x80) return 0;
            if (text[index + 1] > 0x9f) return 0;
            return 2;
        },
        0xe2 => {
            if (remaining < 3) return 0;
            if (text[index + 1] != 0x80) return 0;
            if (text[index + 2] < 0xa8) return 0;
            if (text[index + 2] > 0xa9) return 0;
            return 3;
        },
        0xef => {
            if (remaining < 3) return 0;

            const second = text[index + 1];
            const third = text[index + 2];
            const order_mark = second == 0xbb and third == 0xbf;
            const nonchar = second == 0xbf and (third == 0xbe or third == 0xbf);

            if (order_mark) return 3;
            if (nonchar) return 3;
            return 0;
        },
        else => return 0,
    }
}

fn codepoint_of(bytes: []const u8) u21 {
    assert(bytes.len >= 2);
    assert(bytes.len <= 3);

    if (bytes.len == 2) {
        const result: u21 = (@as(u21, bytes[0] & 0x1f) << 6) | (bytes[1] & 0x3f);

        assert(result >= 0x80);

        return result;
    }

    const high: u21 = @as(u21, bytes[0] & 0x0f) << 12;
    const middle: u21 = @as(u21, bytes[1] & 0x3f) << 6;
    const result: u21 = high | middle | (bytes[2] & 0x3f);

    assert(result >= 0x800);

    return result;
}

fn sequence_length_of(text: []const u8, index: u32) u32 {
    assert(index < text.len);
    assert(text[index] >= 0x80);

    const wanted: u32 = std.unicode.utf8ByteSequenceLength(text[index]) catch 1;
    const remaining: u32 = @intCast(text.len - index);
    const result = @min(wanted, remaining);

    assert(result >= 1);

    return result;
}

fn escape_name_of(codepoint: u21) []const u8 {
    assert(codepoint <= 0x10ffff);
    assert(codepoint != ' ');

    return switch (codepoint) {
        0x00 => "\\0",
        0x07 => "\\a",
        0x08 => "\\b",
        0x09 => "\\t",
        0x0a => "\\n",
        0x0b => "\\v",
        0x0c => "\\f",
        0x0d => "\\r",
        0x1b => "\\e",
        0x22 => "\\\"",
        0x5c => "\\\\",
        0x85 => "\\N",
        0x2028 => "\\L",
        0x2029 => "\\P",
        else => "",
    };
}

fn content_white_first_is(text: []const u8) bool {
    assert(text.len <= text_bytes_max);
    assert(text_bytes_max > 0);

    const start = std.mem.findNone(u8, text, "\n") orelse return false;
    return blank_is(text[start]);
}

fn marker_is(text: []const u8) bool {
    assert(text.len <= text_bytes_max);
    assert(text_bytes_max > 3);

    if (text.len < 3) return false;

    const head = text[0..3];
    const marked = std.mem.eql(u8, head, "---") or std.mem.eql(u8, head, "...");
    if (!marked) return false;
    if (text.len == 3) return true;
    return blank_or_break_is(text[3]);
}

fn fold_point_is(text: []const u8, index: u32) bool {
    assert(index < text.len);
    assert(text[index] == ' ');

    if (index == 0) return false;
    if (index + 1 == text.len) return false;
    return !blank_is(text[index - 1]);
}

fn folded_point_is(text: []const u8, index: u32) bool {
    assert(index < text.len);
    assert(text.len <= text_bytes_max);

    if (text[index] != ' ') return false;
    if (!fold_point_is(text, index)) return false;
    return !blank_or_break_is(text[index + 1]);
}

fn blank_is(byte: u8) bool {
    assert(classes[byte].padding == 0);
    assert(classes[' '].ends != 0);

    return byte == ' ' or byte == '\t';
}

fn blank_or_break_is(byte: u8) bool {
    assert(classes[byte].padding == 0);
    assert(classes['\n'].line_feed);

    return blank_is(byte) or byte == '\n';
}

fn breaks_only_is(text: []const u8) bool {
    assert(text.len <= text_bytes_max);
    assert(classes['\n'].line_feed);

    for (text) |byte| {
        if (byte != '\n') return false;
    }

    return true;
}

fn chomping_of(text: []const u8) ?u8 {
    assert(text.len <= text_bytes_max);
    assert(text_bytes_max > 1);

    if (text.len == 0) return '-';
    if (text[text.len - 1] != '\n') return '-';
    if (text.len == 1) return '+';
    if (text[text.len - 2] == '\n') return '+';
    return null;
}

fn columns_of(text: []const u8) usize {
    assert(text.len <= text_bytes_max);
    assert(text.len > 0);

    var result: usize = 0;

    for (text) |byte| {
        if (byte & 0xc0 != 0x80) result += 1;
    }

    assert(result <= text.len);

    return result;
}

fn tag_parts_of(tag: []const u8) TagParts {
    assert(tag.len > 0);
    assert(tag_prefix_core.len == 18);

    if (std.mem.eql(u8, tag, "!")) {
        return .{ .body = "", .form = .shorthand, .head = "!", .tail = "" };
    }

    const core = tag.len > tag_prefix_core.len and std.mem.startsWith(u8, tag, tag_prefix_core);

    if (core) {
        const body = tag[tag_prefix_core.len..];
        return .{ .body = body, .form = .shorthand, .head = "!!", .tail = "" };
    }

    if (tag[0] == '!') return .{ .body = tag[1..], .form = .shorthand, .head = "!", .tail = "" };
    return .{ .body = tag, .form = .verbatim, .head = "!<", .tail = ">" };
}

fn tag_byte_is(byte: u8, form: TagForm) bool {
    assert(@backingInt(form) <= 1);
    assert(byte != '%' or !std.ascii.isAlphanumeric(byte));

    const uri = std.ascii.isAlphanumeric(byte) or
        std.mem.findScalar(u8, "-#;/?:@&=+$,_.!~*'()[]", byte) != null;

    if (!uri) return false;

    return switch (form) {
        .shorthand => std.mem.findScalar(u8, "!,[]", byte) == null,
        .verbatim => true,
    };
}

fn run_end(text: []const u8, start: u32, stops: Stops) u32 {
    assert(start <= text.len);
    assert(text.len <= text_bytes_max);

    if (stops.escapes) assert(!stops.quote_single);

    var index = start;

    for (0..@divFloor(text.len - start, lane_count)) |_| {
        const mask = stop_mask_of(text, index, stops);

        if (mask != 0) {
            const result = index + @ctz(mask);

            assert(result < text.len);

            return result;
        }

        index += lane_count;
    }

    for (text[index..]) |byte| {
        if (stop_is(byte, stops)) break;

        index += 1;
    }

    assert(index <= text.len);

    return index;
}

fn stop_mask_of(text: []const u8, index: u32, stops: Stops) Mask {
    assert(index + lane_count <= text.len);
    assert(text.len <= text_bytes_max);

    if (stops.escapes) assert(!stops.quote_single);

    const chunk: Chunk = text[index..][0..lane_count].*;
    var lanes: Lanes = @intFromBool(chunk == @as(Chunk, @splat('\n')));

    if (stops.escapes) {
        lanes |= @intFromBool(chunk < @as(Chunk, @splat(0x20)));
        lanes |= @intFromBool(chunk == @as(Chunk, @splat('"')));
        lanes |= @intFromBool(chunk == @as(Chunk, @splat('\\')));
        lanes |= @intFromBool(chunk == @as(Chunk, @splat(0x7f)));
        lanes |= @intFromBool(chunk == @as(Chunk, @splat(0xc2)));
        lanes |= @intFromBool(chunk == @as(Chunk, @splat(0xe2)));
        lanes |= @intFromBool(chunk == @as(Chunk, @splat(0xef)));
    }

    if (stops.quote_single) lanes |= @intFromBool(chunk == @as(Chunk, @splat('\'')));
    if (stops.space) lanes |= @intFromBool(chunk == @as(Chunk, @splat(' ')));

    return @bitCast(lanes);
}

fn stop_is(byte: u8, stops: Stops) bool {
    assert(classes[byte].padding == 0);

    if (stops.escapes) assert(!stops.quote_single);

    if (byte == '\n') return true;

    if (stops.escapes) {
        if (escape_stops[byte]) return true;
    }

    if (stops.quote_single) {
        if (byte == '\'') return true;
    }

    if (stops.space) {
        if (byte == ' ') return true;
    }

    return false;
}

fn classes_build() [256]Class {
    @setEvalBranchQuota(20_000);

    var result: [256]Class = undefined;

    for (&result, 0..) |*class, index| {
        const byte: u8 = @intCast(index);
        const white = byte == ' ' or byte == '\t';
        const line_feed = byte == '\n';
        var ends: u4 = 0;
        var starts: u4 = 0;

        if (line_feed) {
            starts |= pair_break_white | pair_hash;
            ends |= pair_white_break | pair_colon;
        }

        if (white) {
            starts |= pair_white_break | pair_hash;
            ends |= pair_break_white | pair_colon;
        }

        if (byte == ':') starts |= pair_colon;
        if (byte == '#') ends |= pair_hash;

        class.* = .{
            .ends = ends,
            .starts = starts,
            .control = (byte < 0x20 and !white and !line_feed) or byte == 0x7f,
            .escape = byte == '"' or byte == '\\',
            .flow = std.mem.findScalar(u8, ",[]{}", byte) != null,
            .high = byte >= 0x80,
            .lead = byte == 0xc2 or byte == 0xe2 or byte == 0xef,
            .line_feed = line_feed,
            .quote_single = byte == '\'',
            .padding = 0,
        };
    }

    assert(result['\r'].control);
    assert(!result['\t'].control);

    return result;
}

fn firsts_build() [256]Analysis {
    var result: [256]Analysis = @splat(analysis_none);

    for (&result, 0..) |*analysis, index| {
        const byte: u8 = @intCast(index);
        const white = byte == ' ' or byte == '\t';

        analysis.content_white_first = white;
        analysis.flow_unsafe_first = byte == '?' or byte == ':';
        analysis.indicator_first = indicators_always[byte];
        analysis.leading_break = byte == '\n';
        analysis.leading_white = white;
    }

    assert(result['#'].indicator_first);
    assert(!result['-'].indicator_first);

    return result;
}

fn lasts_build() [256]Analysis {
    var result: [256]Analysis = @splat(analysis_none);

    result['\n'].trailing_break = true;
    result[' '].trailing_white = true;
    result['\t'].trailing_white = true;

    assert(!result['a'].trailing_white);
    assert(result['\n'].trailing_break);

    return result;
}

fn pairings_build() [16]Analysis {
    var result: [16]Analysis = @splat(analysis_none);

    for (&result, 0..) |*analysis, index| {
        const pairs: u4 = @intCast(index);

        analysis.break_white = pairs & pair_break_white != 0;
        analysis.colon_unsafe = pairs & pair_colon != 0;
        analysis.hash_after_white = pairs & pair_hash != 0;
        analysis.white_break = pairs & pair_white_break != 0;
    }

    assert(result[pair_colon].colon_unsafe);
    assert(!result[0].colon_unsafe);

    return result;
}

fn byte_set_build(comptime members: []const u8) [256]bool {
    comptime assert(members.len > 0);

    var result: [256]bool = @splat(false);

    for (members) |member| result[member] = true;

    assert(result[members[0]]);
    assert(!result[0]);

    return result;
}

fn escape_stops_build() [256]bool {
    var result: [256]bool = undefined;

    for (&result, 0..) |*stop, index| {
        const byte: u8 = @intCast(index);
        const lead = byte == 0xc2 or byte == 0xe2 or byte == 0xef;

        stop.* = byte < 0x20 or byte == '"' or byte == '\\' or byte == 0x7f or lead;
    }

    assert(result['\t']);
    assert(!result[' ']);

    return result;
}

test Writer {
    var buffer: [256]u8 = undefined;
    var sink: std.Io.Writer = .fixed(&buffer);
    var writer: Writer = undefined;

    writer.init(&sink, .{ .indent = 2, .layout = .preserve, .width = 0 });

    try writer.document_begin(&.{ .explicit = false });
    try writer.mapping_begin(&.{ .style = .block });
    try writer.scalar(&.{ .text = "name" });
    try writer.scalar(&.{ .text = "warbler" });
    try writer.scalar(&.{ .text = "ports" });
    try writer.sequence_begin(&.{ .style = .flow });
    try writer.scalar(&.{ .text = "8080" });
    try writer.scalar(&.{ .text = "8443" });
    try writer.sequence_end();
    try writer.scalar(&.{ .text = "motto" });
    try writer.scalar(&.{ .style = .single_quoted, .text = "it's: \"fine\"" });
    try writer.mapping_end();
    try writer.document_end(&.{ .explicit = false });
    try writer.document_begin(&.{ .explicit = false });
    try std.testing.expectError(error.TextInvalid, writer.scalar(&.{ .text = "\xff" }));
    try writer.scalar(&.{ .text = "replaced" });
    try writer.document_end(&.{ .explicit = true });

    writer.finish();

    const expected =
        \\name: warbler
        \\ports: [8080, 8443]
        \\motto: 'it''s: "fine"'
        \\--- replaced
        \\...
        \\
    ;

    try std.testing.expectEqualStrings(expected, sink.buffered());
}

test "a rejected scalar after a written comment leaves the writer unchanged" {
    var buffer: [256]u8 = undefined;
    var sink: std.Io.Writer = .fixed(&buffer);
    var writer: Writer = undefined;

    writer.init(&sink, .{ .indent = 2, .width = 0 });

    try writer.document_begin(&.{ .explicit = false });
    try writer.mapping_begin(&.{ .style = .block });
    try writer.comment(.head, "# note");

    const before = std.mem.toBytes(writer);

    try std.testing.expectError(error.TextInvalid, writer.scalar(&.{ .text = "\xff" }));
    try std.testing.expectEqualSlices(u8, &before, std.mem.asBytes(&writer));
    try writer.scalar(&.{ .text = "key" });
    try writer.scalar(&.{ .text = "value" });
    try writer.mapping_end();
    try writer.document_end(&.{ .explicit = false });

    writer.finish();

    try std.testing.expectEqualStrings("# note\nkey: value\n", sink.buffered());
}

const test_pieces = [_][]const u8{
    "a",
    "Z",
    "0",
    "_",
    ".",
    "/",
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
    "\\",
    "%",
    "@",
    "`",
    " ",
    "\t",
    "\n",
    "---",
    "...",
    "\x01",
    "\x7f",
    "\u{85}",
    "\u{a0}",
    "\u{e9}",
    "\u{2028}",
    "\u{2029}",
    "\u{20ac}",
    "\u{feff}",
    "\u{fffe}",
    "\u{ffff}",
    "\u{fffd}",
    "\u{1f600}",
};

fn test_analysis_reference(text: []const u8) Analysis {
    assert(text.len <= 256);
    assert(std.unicode.utf8ValidateSlice(text));

    var result = analysis_none;

    result.empty = text.len == 0;

    if (text.len == 0) return result;

    const first = text[0];
    const last = text[text.len - 1];

    result.leading_break = first == '\n';
    result.leading_white = first == ' ' or first == '\t';
    result.trailing_break = last == '\n';
    result.trailing_white = last == ' ' or last == '\t';
    result.flow_unsafe_first = first == '?' or first == ':';
    result.marker = test_marker_is(text);

    const spaced = std.mem.findScalar(u8, "-?:", first) != null;
    const separated = text.len == 1 or std.mem.findScalar(u8, " \t\n", text[1]) != null;

    result.indicator_first = std.mem.findScalar(u8, ",[]{}#&*!|>'\"%@`", first) != null or
        (spaced and separated);

    const content = std.mem.findNone(u8, text, "\n");

    result.content_white_first = if (content) |start| blank_is(text[start]) else false;

    test_pairs_reference(text, &result);

    var quotes: u32 = 0;

    for (text) |byte| {
        if (byte == '\'') quotes += 1;
        if (byte == '\n') result.multiline = true;
        if (byte == '"') result.escape = true;
        if (byte == '\\') result.escape = true;
        if (std.mem.findScalar(u8, ",[]{}", byte) != null) result.flow_indicator = true;
    }

    result.quote_single = @intCast(quotes);
    result.special = test_special_has(text);

    return result;
}

fn test_marker_is(text: []const u8) bool {
    assert(text.len > 0);
    assert(text.len <= 256);

    const marked = std.mem.startsWith(u8, text, "---") or std.mem.startsWith(u8, text, "...");
    if (!marked) return false;
    if (text.len == 3) return true;
    return std.mem.findScalar(u8, " \t\n", text[3]) != null;
}

fn test_pairs_reference(text: []const u8, result: *Analysis) void {
    assert(text.len > 0);
    assert(text.len <= 256);

    for (text, 0..) |byte, index| {
        const next: ?u8 = if (index + 1 < text.len) text[index + 1] else null;
        const blank = byte == ' ' or byte == '\t';
        const blank_or_break = blank or byte == '\n';
        const blank_next = if (next) |value| value == ' ' or value == '\t' else false;
        const break_next = if (next) |value| value == '\n' else false;

        if (byte == '\n') {
            if (blank_next) result.break_white = true;
        }

        if (blank) {
            if (break_next) result.white_break = true;
        }

        if (byte == ':') {
            if (next == null) result.colon_unsafe = true;
            if (blank_next) result.colon_unsafe = true;
            if (break_next) result.colon_unsafe = true;
        }

        if (blank_or_break) {
            if (next == '#') result.hash_after_white = true;
        }
    }
}

fn test_special_has(text: []const u8) bool {
    assert(text.len > 0);
    assert(std.unicode.utf8ValidateSlice(text));

    var iterator = std.unicode.Utf8View.initUnchecked(text).iterator();

    for (0..text.len) |_| {
        const codepoint = iterator.nextCodepoint() orelse return false;

        const special = switch (codepoint) {
            '\t', '\n' => false,
            0x00...0x08, 0x0b...0x1f, 0x7f...0x9f => true,
            0x2028, 0x2029, 0xfeff, 0xfffe, 0xffff => true,
            else => false,
        };

        if (special) return true;
    }

    return false;
}

test "the scalar analysis matches a byte-by-byte reference at every length" {
    var prng: std.Random.DefaultPrng = .init(std.testing.random_seed);
    const random = prng.random();
    var buffer: [256]u8 = undefined;

    for (0..20_000) |_| {
        const target = random.uintAtMost(u32, 100);
        const plain = random.uintLessThan(u32, 4) == 0;
        var length: u32 = 0;

        for (0..buffer.len) |_| {
            const choice = random.uintLessThan(u32, test_pieces.len);
            const piece = if (plain) "ab" else test_pieces[choice];

            if (length >= target) break;
            if (length + piece.len > buffer.len) break;

            @memcpy(buffer[length..][0..piece.len], piece);
            length += @intCast(piece.len);
        }

        const text = buffer[0..length];
        const expected = test_analysis_reference(text);
        const analysis = try analysis_of(text, .checked);

        if (@as(u32, @bitCast(expected)) != @as(u32, @bitCast(analysis))) {
            std.debug.print("text {f}\n", .{std.zig.fmtString(text)});
        }

        try std.testing.expectEqual(@as(u32, @bitCast(expected)), @as(u32, @bitCast(analysis)));
    }
}
