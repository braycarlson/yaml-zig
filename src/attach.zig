const std = @import("std");

const comment_module = @import("comment.zig");
const composer_module = @import("composer.zig");
const document_module = @import("document.zig");
const parser_module = @import("parser.zig");
const scanner_module = @import("scanner.zig");
const storage_module = @import("storage.zig");

const assert = std.debug.assert;

const Comment = comment_module.Comment;
const CommentSlot = storage_module.CommentSlot;
const Document = document_module.Document;
const Record = storage_module.Record;
const ScalarStyle = parser_module.ScalarStyle;

const flow_style: u8 = @backingInt(parser_module.CollectionStyle.flow);
const none = storage_module.index_none;
const partition_gallop_min: u32 = 256;
const stack_capacity: u32 = parser_module.state_capacity;

comptime {
    assert(stack_capacity >= 2 * scanner_module.depth_max);
}

const Open = struct {
    child: u32,
    count: u32,
    end: u32,
    flow_depth: u32,
    key: u32,
    mapping: bool,
    next: u32,
    node: u32,

    fn settle(open: *Open, nodes: []const Record, cursor: u32) void {
        assert(open.next <= open.end);
        assert(open.end <= nodes.len);
        assert(cursor != none);

        var child = open.child;
        var count = open.count;
        var key = open.key;
        var next = open.next;

        for (open.next..open.end) |_| {
            if (next >= cursor) break;

            count += 1;
            child = next;

            if (count % 2 == 1) key = next;

            next += nodes[next].span;
        }

        open.child = child;
        open.count = count;
        open.next = next;

        if (open.mapping) open.key = key;

        assert(open.next <= open.end);
    }
};

const Role = enum {
    item,
    key,
    root,
    value,
};

const Target = struct {
    inside: bool,
    node: u32,
    placement: Comment.Placement,

    const empty: Target = .{ .inside = false, .node = none, .placement = .foot };
};

const Context = struct {
    depth: u32,
    entered: Role,
    following: u32,
    preceding: u32,
    value_ahead: bool,
    value_empty: bool,
};

const Walk = struct {
    cursor: u32,
    depth: u32,
    frames_cursor: u32,
    last: u32,
    nodes: []const Record,
    root_next: u32,
    roots: []const u32,
    source: []const u8,
    stack: [stack_capacity]Open,
    target_last: u32,

    fn init(walk: *Walk, document: *const Document) void {
        assert(document.node_count <= document.storage.nodes.len);
        assert(document.document_count <= document.storage.roots.len);

        walk.cursor = 0;
        walk.depth = 0;
        walk.frames_cursor = 0;
        walk.last = none;
        walk.nodes = document.storage.nodes[0..document.node_count];
        walk.root_next = 0;
        walk.roots = document.storage.roots[0..document.document_count];
        walk.source = document.source;
        walk.target_last = none;
    }

    fn advance(walk: *Walk, offset: u32) void {
        assert(walk.cursor <= walk.nodes.len);
        assert(walk.root_next <= walk.roots.len);
        assert(offset <= walk.source.len);

        const nodes = walk.nodes;
        const start = walk.cursor;
        const passed = partition_near(Record, nodes[start..], offset, offset_before);
        const cursor = start + passed;

        for (start..cursor) |_| {
            const root = walk.root_at();
            if (root == none) break;
            if (root >= cursor) break;

            walk.root_next += 1;
        }

        var position = cursor;

        for (start..cursor) |_| {
            position -= 1;

            if (!synthetic_is(&nodes[position])) {
                walk.last = position;

                break;
            }
        }

        walk.cursor = cursor;
    }

    fn root_at(walk: *const Walk) u32 {
        assert(walk.root_next <= walk.roots.len);

        if (walk.root_next == walk.roots.len) return none;
        return walk.roots[walk.root_next];
    }

    fn frames_settle(walk: *Walk) void {
        assert(walk.frames_cursor <= walk.cursor);
        assert(walk.depth <= stack_capacity);

        const target = walk.cursor;
        if (walk.frames_cursor == target) return;

        var depth = walk.depth;

        for (0..walk.depth) |_| {
            if (walk.stack[depth - 1].end >= target) break;

            depth -= 1;
        }

        if (depth == 0) {
            const root = walk.root_of();

            const root_holds = root != none and collection_is(&walk.nodes[root]) and
                root + walk.nodes[root].span >= target;

            if (root_holds) {
                walk.stack[0] = open_of(walk.nodes, root, null);
                depth = 1;
            }
        }

        for (0..stack_capacity) |_| {
            if (depth == 0) break;

            const frame = &walk.stack[depth - 1];

            frame.settle(walk.nodes, target);

            if (frame.child == none) break;
            if (!collection_is(&walk.nodes[frame.child])) break;

            assert(depth < stack_capacity);
            assert(frame.next >= target);

            walk.stack[depth] = open_of(walk.nodes, frame.child, frame);
            depth += 1;
        }

        walk.depth = depth;
        walk.frames_cursor = target;
    }

    fn column_of(walk: *const Walk, frame: *const Open) u32 {
        assert(frame.node < walk.nodes.len);
        assert(collection_is(&walk.nodes[frame.node]));

        const record = &walk.nodes[frame.node];
        const flow = record.style == flow_style;
        const bare = flow or (record.anchor.len == 0 and record.tag.len == 0);
        if (bare) return record.column;
        return content_column_of(walk.nodes, walk.source, frame.node);
    }

    fn next_of(walk: *const Walk) u32 {
        assert(walk.cursor <= walk.nodes.len);
        assert(walk.root_next <= walk.roots.len);

        for (walk.cursor..walk.nodes.len) |index| {
            const position: u32 = @intCast(index);

            const root_starts = walk.root_next < walk.roots.len and
                walk.roots[walk.root_next] == position;

            const found = root_starts or !synthetic_is(&walk.nodes[position]);

            if (found) {
                assert(position >= walk.cursor);

                return position;
            }
        }

        return none;
    }

    fn context_of(walk: *const Walk, slot: *const CommentSlot) Context {
        assert(walk.cursor <= walk.nodes.len);
        assert(slot.text.len > 0);

        const following = walk.next_of();

        var result: Context = .{
            .depth = walk.depth,
            .entered = entered_of(slot.previous),
            .following = following,
            .preceding = walk.last,
            .value_ahead = false,
            .value_empty = false,
        };

        const root_open = walk.last != none and walk.root_next > 0;

        if (root_open) {
            if (walk.last < walk.roots[walk.root_next - 1]) result.preceding = none;
        }

        if (following == none) return result;
        if (walk.root_next == walk.roots.len) return result;
        if (following < walk.roots[walk.root_next]) return result;

        const opening = switch (slot.previous) {
            .directive_reserved,
            .directive_tag,
            .directive_version,
            .document_start,
            .stream_start,
            => true,
            else => slot.flags.prefix or result.preceding == none,
        };

        if (opening) {
            return .{
                .depth = 0,
                .entered = .root,
                .following = following,
                .preceding = none,
                .value_ahead = false,
                .value_empty = false,
            };
        }

        result.following = none;

        return result;
    }

    fn role_of(walk: *const Walk, context: *const Context, following: u32) Role {
        assert(following < walk.nodes.len);
        assert(context.depth <= walk.depth);

        var depth = context.depth;

        const parent: *const Open = for (0..context.depth) |_| {
            const frame = &walk.stack[depth - 1];
            const following_inside = frame.node < following and following < frame.end;
            if (following_inside) break frame;

            depth -= 1;
        } else return .root;

        var child = if (parent.child == none) parent.node + 1 else parent.child;
        var position = if (parent.child == none) 0 else parent.count - 1;

        for (0..walk.nodes.len) |_| {
            if (child >= following) break;

            child += span_of(&walk.nodes[child]);
            position += 1;
        }

        assert(child == following);

        if (!parent.mapping) return .item;
        if (position % 2 == 0) return .key;
        return .value;
    }

    fn head_target(walk: *const Walk, context: *const Context, following: u32) ?u32 {
        assert(following < walk.nodes.len);
        assert(context.depth <= walk.depth);

        var role = walk.role_of(context, following);
        var target = following;
        const role_entered = role != .root and role == context.entered;

        if (role_entered) role = .value;

        const value_awaited = role == .value and context.value_ahead;
        if (value_awaited) return target;

        for (0..walk.nodes.len) |_| {
            if (role != .value) return target;

            const record = &walk.nodes[target];
            if (synthetic_is(record)) return null;
            if (!collection_is(record)) return target;
            if (record.style == flow_style) return target;
            if (record.anchor.len > 0) return target;
            if (record.tag.len > 0) return target;
            if (record.link.count == 0) return target;
            if (synthetic_is(&walk.nodes[target + 1])) return target;

            role = if (record.kind == .mapping) .key else .item;
            target += 1;
        }

        unreachable;
    }

    fn owner_of(walk: *const Walk, frame: *const Open) u32 {
        assert(frame.node < walk.nodes.len);
        assert(frame.count <= walk.nodes.len);

        if (frame.child == none) return none;

        const key_last = frame.mapping and frame.count % 2 == 0;
        const owner = if (key_last) frame.key else frame.child;
        if (!synthetic_is(&walk.nodes[owner])) return owner;

        const value_owns = owner == frame.key and !synthetic_is(&walk.nodes[frame.child]);
        if (value_owns) return frame.child;
        return none;
    }

    fn foot_owner_of(walk: *const Walk, frame: *const Open, owner: u32) u32 {
        assert(owner < walk.nodes.len);
        assert(frame.child != none);

        if (!collection_is(&walk.nodes[owner])) return owner;
        if (!frame.mapping) return none;
        if (frame.count % 2 == 1) return none;

        const value = &walk.nodes[frame.child];
        if (collection_is(value)) return none;
        if (synthetic_is(value)) return none;
        return frame.child;
    }

    fn foot_holder(walk: *const Walk, context: *const Context, column: u32) u32 {
        assert(context.depth <= walk.depth);
        assert(context.preceding != none);
        assert(column <= walk.source.len);

        var depth = context.depth;

        for (0..context.depth) |_| {
            const frame = &walk.stack[depth - 1];

            depth -= 1;

            if (walk.column_of(frame) > column) continue;
            if (frame.child == none) return none;

            const owner = walk.owner_of(frame);

            if (owner == none) {
                const following = context.following;
                const following_inside = following != none and following < frame.end;
                if (following_inside) return none;
                return frame.node;
            }

            const following = context.following;
            const following_in_entry = following != none and following < walk.entry_end_of(frame);
            if (following_in_entry) return none;

            const value_pending = frame.mapping and frame.count % 2 == 1;
            if (value_pending) return none;
            return walk.foot_owner_of(frame, owner);
        }

        return none;
    }

    fn entry_end_of(walk: *const Walk, frame: *const Open) u32 {
        assert(frame.child != none);
        assert(frame.child < walk.nodes.len);

        const child = frame.child;
        const end = child + span_of(&walk.nodes[child]);

        assert(end <= frame.end);

        if (!frame.mapping) return end;
        if (frame.count % 2 == 0) return end;
        if (end >= frame.end) return end;

        const result = end + span_of(&walk.nodes[end]);

        assert(result <= frame.end);

        return result;
    }

    fn open_depth_of(walk: *const Walk, context: *const Context, flow_depth: u32) u32 {
        assert(context.depth <= walk.depth);
        assert(flow_depth <= scanner_module.depth_max + 1);

        var depth = context.depth;

        for (0..context.depth) |_| {
            if (walk.stack[depth - 1].flow_depth <= flow_depth) break;

            depth -= 1;
        }

        assert(depth <= context.depth);

        return depth;
    }

    fn flow_frame(walk: *const Walk, context: *const Context, flow_depth: u32) ?*const Open {
        assert(context.depth <= walk.depth);
        assert(flow_depth <= scanner_module.depth_max + 1);

        var depth = context.depth;

        for (0..context.depth) |_| {
            const frame = &walk.stack[depth - 1];

            depth -= 1;

            if (frame.flow_depth < flow_depth) return null;

            if (frame.flow_depth == flow_depth) {
                if (walk.nodes[frame.node].style == flow_style) return frame;
            }
        }

        return null;
    }

    fn value_of(walk: *const Walk, key: u32) u32 {
        assert(key == none or key < walk.nodes.len);
        assert(walk.nodes.len < none);

        if (key == none) return none;

        const result = key + span_of(&walk.nodes[key]);

        assert(result <= walk.nodes.len);

        return result;
    }

    fn key_pending(walk: *const Walk, context: *const Context) u32 {
        assert(context.depth <= walk.depth);
        assert(walk.cursor <= walk.nodes.len);

        var depth = context.depth;

        for (0..context.depth) |_| {
            const frame = &walk.stack[depth - 1];

            depth -= 1;

            if (!frame.mapping) continue;
            if (frame.key == none) continue;
            if (frame.count % 2 == 1) return frame.key;
            if (synthetic_is(&walk.nodes[frame.child])) return frame.key;
        }

        return none;
    }

    fn usable_is(walk: *const Walk, node: u32) bool {
        assert(walk.cursor <= walk.nodes.len);
        assert(node == none or node < walk.nodes.len);

        if (node == none) return false;
        return !synthetic_is(&walk.nodes[node]);
    }

    fn document_target(walk: *const Walk) Target {
        assert(walk.root_next <= walk.roots.len);
        assert(walk.cursor <= walk.nodes.len);

        if (walk.root_next < walk.roots.len) {
            return head_of(walk.roots[walk.root_next]);
        }

        if (walk.roots.len == 0) return .empty;
        return foot_of(walk.roots[walk.roots.len - 1]);
    }

    fn root_of(walk: *const Walk) u32 {
        assert(walk.root_next <= walk.roots.len);

        if (walk.root_next == 0) return none;

        const result = walk.roots[walk.root_next - 1];

        assert(result < walk.nodes.len);

        return result;
    }

    fn trailing_target(walk: *const Walk, slot: *const CommentSlot) Target {
        assert(slot.flags.trailing);
        assert(slot.text.len > 0);

        if (walk.last != none) {
            const record = &walk.nodes[walk.last];
            const header_line = block_scalar_is(record) and record.line == slot.line;
            if (header_line) return line_of(walk.last);
        }

        if (slot.flags.prefix) return walk.document_target();

        const context = walk.context_of(slot);
        const preceding = context.preceding;
        const following = context.following;

        switch (slot.previous) {
            .alias, .anchor, .flow_mapping_start, .flow_sequence_start, .scalar, .tag => {
                if (preceding != none) return line_of(preceding);
            },
            .flow_mapping_end, .flow_sequence_end => {
                if (walk.flow_frame(&context, slot.flow_depth + 1)) |frame| {
                    return line_of(frame.node);
                }
            },
            .flow_entry => {
                if (walk.flow_entry_target(&context, slot)) |target| return target;
            },
            .value => {
                if (walk.value_trailing_target(&context, slot)) |target| return target;
            },
            .key => {
                const offset = offset_of(walk.source, slot);

                if (walk.empty_entry_last(&context, offset)) {
                    return line_of(walk.stack[context.depth - 1].child);
                }
            },
            .block_entry => {
                if (walk.empty_entry_last(&context, offset_of(walk.source, slot))) {
                    const frame = &walk.stack[context.depth - 1];
                    const following_inside = following != none and following < frame.end;
                    if (following_inside) return head_of(following);
                    return foot_of(frame.node);
                }
            },
            .directive_reserved,
            .directive_tag,
            .directive_version,
            .document_end,
            => return walk.document_target(),
            .document_start => {
                if (following != none) return head_of(following);
            },
            else => {},
        }

        if (following != none) return line_of(following);
        if (preceding != none) return line_of(preceding);
        return walk.document_target();
    }

    fn flow_entry_target(
        walk: *const Walk,
        context: *const Context,
        slot: *const CommentSlot,
    ) ?Target {
        assert(slot.flags.trailing);
        assert(slot.previous == .flow_entry);

        if (walk.flow_frame(context, slot.flow_depth)) |frame| {
            const owner = frame.child;
            if (walk.usable_is(owner)) return line_of(owner);

            const last = walk.target_last;
            const owner_held = owner != none and (last == none or last <= owner);
            if (owner_held) return line_of(owner);

            if (owner != none) {
                const following = context.following;
                const following_inside = following != none and following < frame.end;

                if (following_inside) {
                    if (walk.head_target(context, following)) |target| return head_of(target);
                }

                return foot_inside_of(frame.node);
            }

            if (walk.usable_is(frame.key)) return line_of(frame.key);
        }

        return null;
    }

    fn value_trailing_target(
        walk: *const Walk,
        context: *const Context,
        slot: *const CommentSlot,
    ) ?Target {
        assert(slot.flags.trailing);
        assert(slot.previous == .value);

        const following = context.following;
        const key = walk.key_pending(context);

        const key_line = walk.usable_is(key) and !collection_is(&walk.nodes[key]) and
            walk.nodes[key].line == slot.line;

        if (key_line) return line_of(key);

        if (walk.flow_frame(context, slot.flow_depth)) |frame| {
            const value_next = following != none and walk.value_of(frame.key) == following;
            if (value_next) return head_of(following);

            if (frame.key != none) {
                const value = frame.key + span_of(&walk.nodes[frame.key]);
                const empty = value < frame.end and synthetic_is(&walk.nodes[value]);
                if (empty) return line_of(value);
            }

            const following_inside = following != none and following < frame.end;

            if (following_inside) {
                if (walk.head_target(context, following)) |target| return head_of(target);
            }

            return foot_inside_of(frame.node);
        }

        const value_next = following != none and walk.value_of(key) == following;
        const value_skipped = key != none and !value_next;

        if (value_skipped) {
            const value = key + span_of(&walk.nodes[key]);
            const offset = offset_of(walk.source, slot);

            const empty = value < walk.nodes.len and synthetic_is(&walk.nodes[value]) and
                significant_from(walk.source, walk.nodes[value].offset + 1) >= offset;

            const scalar_key = walk.usable_is(key) and !collection_is(&walk.nodes[key]);
            const key_holds = empty and scalar_key;
            if (key_holds) return foot_of(key);
            if (empty) return line_of(value);
        }

        return null;
    }

    fn empty_entry_last(walk: *const Walk, context: *const Context, offset: u32) bool {
        assert(context.depth <= walk.depth);
        assert(walk.cursor <= walk.nodes.len);
        assert(offset <= walk.source.len);

        if (context.depth == 0) return false;

        const frame = &walk.stack[context.depth - 1];
        if (frame.child == none) return false;
        if (!synthetic_is(&walk.nodes[frame.child])) return false;

        const child = &walk.nodes[frame.child];
        if (significant_from(walk.source, child.offset + 1) < offset) return false;

        const key = frame.count % 2 == 1;
        const role: Role = if (!frame.mapping) .item else if (key) .key else .value;

        return role == context.entered;
    }

    fn open_innermost_of(walk: *const Walk, context: *const Context) u32 {
        assert(context.depth <= walk.depth);
        assert(walk.cursor <= walk.nodes.len);

        var depth = context.depth;

        for (0..context.depth) |_| {
            if (walk.stack[depth - 1].end > walk.cursor) break;

            depth -= 1;
        }

        return depth;
    }

    fn following_open_is(walk: *const Walk, context: *const Context) bool {
        assert(context.following != none);
        assert(context.depth <= walk.depth);

        const depth = walk.open_innermost_of(context);
        if (depth == 0) return true;
        return context.following < walk.stack[depth - 1].end;
    }

    fn indicator_target(walk: *const Walk, context: *const Context, column: u32) ?Target {
        assert(context.depth <= walk.depth);
        assert(context.value_ahead);
        assert(column <= walk.source.len);

        const depth = walk.open_innermost_of(context);
        if (depth == 0) return null;

        const frame = &walk.stack[depth - 1];
        if (!frame.mapping) return null;
        if (frame.count % 2 == 0) return null;
        if (frame.flow_depth > 0) return null;
        if (frame.key == none) return null;

        const key = &walk.nodes[frame.key];
        const value = frame.key + span_of(key);

        assert(value < frame.end);

        if (synthetic_is(key)) return head_of(value);

        if (collection_is(key)) {
            var closed = context.depth;

            for (depth..context.depth) |_| {
                const inner = &walk.stack[closed - 1];
                const inner_holds = inner.flow_depth == 0 and walk.column_of(inner) <= column;
                if (inner_holds) return foot_of(inner.node);

                closed -= 1;
            }

            return head_of(value);
        }

        if (synthetic_is(&walk.nodes[value])) return foot_of(frame.key);
        return head_of(value);
    }

    fn key_empty_awaited(
        walk: *const Walk,
        context: *const Context,
        first: *const CommentSlot,
        ahead: u32,
    ) bool {
        assert(context.depth <= walk.depth);
        assert(ahead <= walk.source.len);
        assert(!first.flags.trailing);

        if (ahead == walk.source.len) return false;
        if (walk.source[ahead] != '?') return false;
        if (walk.cursor == walk.nodes.len) return false;
        if (!synthetic_is(&walk.nodes[walk.cursor])) return false;

        const depth = walk.open_innermost_of(context);
        if (depth == 0) return false;

        const frame = &walk.stack[depth - 1];
        if (!frame.mapping) return false;
        if (frame.flow_depth > 0) return false;
        if (walk.column_of(frame) < first.column) return false;
        return frame.count % 2 == 0 and walk.cursor < frame.end;
    }

    fn content_empty_awaited(
        walk: *const Walk,
        context: *const Context,
        first: *const CommentSlot,
    ) bool {
        assert(context.depth <= walk.depth);
        assert(walk.cursor <= walk.nodes.len);

        if (context.preceding == none) return false;
        if (context.depth == 0) return false;

        const frame = &walk.stack[context.depth - 1];
        const record = &walk.nodes[context.preceding];

        if (frame.node != context.preceding) return false;
        if (frame.child != none) return false;
        if (frame.flow_depth > 0) return false;

        const bare = record.anchor.len == 0 and record.tag.len == 0;
        if (bare) return false;
        if (record.line >= first.line) return false;
        if (walk.cursor >= frame.end) return false;
        return synthetic_is(&walk.nodes[walk.cursor]);
    }

    fn bracket_awaited(
        walk: *const Walk,
        context: *const Context,
        first: *const CommentSlot,
        offset: u32,
    ) bool {
        assert(offset <= walk.source.len);
        assert(context.depth <= walk.depth);

        if (context.preceding == none) return false;

        const record = &walk.nodes[context.preceding];
        if (!collection_is(record)) return false;
        if (record.line >= first.line) return false;

        const source = walk.source;
        if (offset == source.len) return false;

        const bracket_absent = source[offset] != '[' and source[offset] != '{';
        if (bracket_absent) return false;

        const following = context.following;
        const bracket_composed = following != none and walk.nodes[following].offset == offset;
        if (bracket_composed) return false;
        return true;
    }

    fn flow_block_target(
        walk: *const Walk,
        context: *const Context,
        frame: *const Open,
        block: []const CommentSlot,
    ) Target {
        assert(frame.flow_depth > 0);
        assert(context.depth > 0);
        assert(block.len > 0);

        const first = &block[0];
        const last = &block[block.len - 1];
        const following = context.following;
        const inside = following != none and following < frame.end;
        const adjacent = inside and last.line + 1 == walk.nodes[following].line;

        if (adjacent) {
            if (walk.head_target(context, following)) |target| return head_of(target);
        }

        const value_pending = frame.mapping and frame.count % 2 == 1;
        const cursor = walk.cursor;

        const pending_empty = value_pending and first.previous != .value and
            cursor < walk.nodes.len and walk.value_of(frame.key) == cursor and
            synthetic_is(&walk.nodes[cursor]);

        if (pending_empty) return head_of(cursor);

        const key_empty = frame.mapping and !value_pending and context.value_ahead and
            cursor < frame.end and synthetic_is(&walk.nodes[cursor]);

        if (key_empty) return head_of(cursor);

        const value_empty = frame.child != none and synthetic_is(&walk.nodes[frame.child]);
        const owner_foot = !first.flags.blank_before and !value_pending and !value_empty;

        if (owner_foot) {
            const owner = walk.owner_of(frame);

            if (owner != none) {
                const holder = walk.foot_owner_of(frame, owner);
                if (holder != none) return foot_of(holder);
            }
        }

        if (inside) {
            if (walk.head_target(context, following)) |target| return head_of(target);
        }

        return foot_inside_of(frame.node);
    }

    fn entered_settle(walk: *const Walk, context: *Context, offset: u32) void {
        assert(context.depth <= walk.depth);
        assert(offset <= walk.source.len);

        if (context.entered != .root) {
            const role_held = context.following != none and walk.following_open_is(context) and
                walk.role_of(context, context.following) == context.entered;

            const entered = role_held and !(context.entered == .value and context.value_ahead);
            const entered_reset = !entered or walk.empty_entry_last(context, offset);

            if (entered_reset) context.entered = .root;
        }

        if (context.entered != .root) {
            for (0..context.depth) |_| {
                const frame = &walk.stack[context.depth - 1];
                if (frame.flow_depth > 0) break;
                if (frame.end > context.following) break;

                context.depth -= 1;
            }
        }
    }

    fn foot_fallback_target(walk: *const Walk, context: *const Context, column: u32) Target {
        assert(context.depth <= walk.depth);
        assert(walk.cursor <= walk.nodes.len);
        assert(column <= walk.source.len);

        const following = context.following;
        var depth = context.depth;

        for (0..context.depth) |_| {
            const frame = &walk.stack[depth - 1];

            depth -= 1;

            const frame_holds_q = following != none and frame.end > following;
            if (frame_holds_q) continue;
            if (walk.column_of(frame) <= column) return foot_of(frame.node);
            if (walk.cursor < frame.end) return foot_of(frame.node);
        }

        if (following != none) {
            if (walk.head_target(context, following)) |target| return head_of(target);

            if (context.preceding != none) {
                const holder = walk.foot_holder(context, column);
                if (holder != none) return foot_of(holder);
            }
        }

        depth = context.depth;

        for (0..context.depth) |_| {
            const frame = &walk.stack[depth - 1];

            depth -= 1;

            if (walk.column_of(frame) <= column) return foot_of(frame.node);
        }

        if (context.depth > 0) return foot_of(walk.stack[0].node);
        if (following != none) return head_of(following);

        const root = walk.root_of();
        if (root != none) return foot_of(root);
        return walk.document_target();
    }

    fn near_target(walk: *const Walk, context: *const Context, block: []const CommentSlot) ?Target {
        assert(block.len > 0);
        assert(context.depth <= walk.depth);

        const first = &block[0];
        const following = context.following;
        const column = first.column;

        if (following != none) {
            const last = &block[block.len - 1];
            const record = &walk.nodes[following];
            const adjacent = last.line + 1 == record.line;
            const indent = line_indent_of(walk.source, record);
            const heading = adjacent and column <= indent;

            if (heading) {
                if (walk.head_target(context, following)) |target| return head_of(target);
            }
        }

        const value_empty_below = context.value_empty and
            walk.column_of(&walk.stack[context.depth - 1]) <= first.column;

        if (value_empty_below) {
            const frame = &walk.stack[context.depth - 1];
            const key = frame.key;
            const key_scalar = walk.usable_is(key) and !collection_is(&walk.nodes[key]);
            if (key_scalar) return foot_of(key);
            return foot_of(frame.child);
        }

        return null;
    }

    fn block_target(walk: *const Walk, block: []const CommentSlot) Target {
        assert(block.len > 0);
        assert(block.len <= walk.source.len);

        const first = &block[0];
        const last = &block[block.len - 1];

        assert(!first.flags.trailing);
        assert(first.line <= last.line);

        if (first.flags.prefix) return walk.document_target();

        var context = walk.context_of(first);
        const ahead = significant_after(walk.source, last);

        context.depth = walk.open_depth_of(&context, first.flow_depth);
        context.value_ahead = ahead < walk.source.len and walk.source[ahead] == ':';

        const offset = offset_of(walk.source, first);

        context.value_empty = context.entered == .value and walk.empty_entry_last(&context, offset);

        walk.entered_settle(&context, offset);

        if (context.depth > 0) {
            const frame = &walk.stack[context.depth - 1];

            if (frame.flow_depth > 0) {
                const properties_held = context.preceding != none and
                    walk.nodes[context.preceding].link.count > 0 and
                    walk.bracket_awaited(&context, first, ahead);

                if (properties_held) return head_of(context.preceding);
                return walk.flow_block_target(&context, frame, block);
            }
        }

        if (walk.bracket_awaited(&context, first, ahead)) return head_of(context.preceding);
        if (walk.content_empty_awaited(&context, first)) return head_of(context.preceding);
        if (walk.key_empty_awaited(&context, first, ahead)) return head_of(walk.cursor);

        if (context.value_ahead) {
            if (walk.indicator_target(&context, first.column)) |target| return target;
        }

        if (walk.near_target(&context, block)) |target| return target;

        const column = first.column;

        const foot_held = !first.flags.blank_before and context.entered == .root and
            context.preceding != none;

        if (foot_held) {
            const holder = walk.foot_holder(&context, column);
            if (holder != none) return foot_of(holder);
        }

        return walk.foot_fallback_target(&context, column);
    }
};

pub noinline fn attach(document: *Document) void {
    assert(document.comment_count > 0);
    assert(document.comment_count <= document.storage.comments.len);

    const slots = document.storage.comments[0..document.comment_count];
    const nodes = document.storage.nodes;
    const source = document.source;
    var walk: Walk = undefined;
    var index: u32 = 0;

    walk.init(document);

    for (0..slots.len) |_| {
        if (index == slots.len) break;

        const first = &slots[index];

        walk.advance(offset_of(source, first));
        walk.frames_settle();

        const blank_after_node = first.flags.blank_before and walk.last != none;

        if (blank_after_node) {
            const record = &nodes[walk.last];
            const after = first.previous == .scalar;
            const quiet = after and (index == 0 or slots[index - 1].line <= record.line);
            const block_trailing = block_scalar_is(record) and quiet;

            if (block_trailing) first.flags.blank_before = false;
        }

        const end = if (first.flags.trailing) index + 1 else block_end_of(slots, index);

        const target = if (first.flags.trailing)
            walk.trailing_target(first)
        else
            walk.block_target(slots[index..end]);

        walk.target_last = target.node;

        for (slots[index..end]) |*slot| {
            slot.flags.inside = target.inside;
            slot.node = target.node;
            slot.placement = target.placement;
        }

        index = end;
    }

    lines_fold(slots);

    if (!std.sort.isSorted(CommentSlot, slots, {}, slot_less)) {
        std.sort.block(CommentSlot, slots, {}, slot_less);
    }

    assert(index == slots.len);
}

fn open_of(nodes: []const Record, index: u32, parent: ?*const Open) Open {
    assert(index < nodes.len);
    assert(collection_is(&nodes[index]));
    assert(parent == null or parent.?.child == index);

    const record = &nodes[index];
    const flow = record.style == flow_style;
    const flow_depth = if (parent) |frame| frame.flow_depth else 0;

    assert(flow_depth <= stack_capacity);

    return .{
        .child = none,
        .count = 0,
        .end = index + record.span,
        .flow_depth = flow_depth + @intFromBool(flow),
        .key = none,
        .mapping = record.kind == .mapping,
        .next = index + 1,
        .node = index,
    };
}

fn partition_near(
    comptime T: type,
    items: []const T,
    context: u32,
    comptime predicate: fn (u32, T) bool,
) u32 {
    assert(items.len < none);
    assert(context != none);

    const count: u32 = @intCast(items.len);

    if (count <= partition_gallop_min) {
        const point: u32 = @intCast(std.sort.partitionPoint(T, items, context, predicate));

        assert(point <= count);

        return point;
    }

    var high = count;
    var low: u32 = 0;
    var step: u32 = 1;

    for (0..@bitSizeOf(u32)) |_| {
        if (step > count - low) break;

        const probe = low + step - 1;

        if (!predicate(context, items[probe])) {
            high = probe;

            break;
        }

        low = probe + 1;

        step *|= 2;
    }

    assert(low <= high);
    assert(high <= count);

    const passed: u32 = @intCast(std.sort.partitionPoint(T, items[low..high], context, predicate));
    const result = low + passed;

    assert(result <= high);

    return result;
}

fn offset_before(offset: u32, record: Record) bool {
    assert(offset != none);
    assert(record.offset != none);

    return record.offset < offset;
}

fn lines_fold(slots: []CommentSlot) void {
    assert(slots.len > 0);
    assert(slots.len <= std.math.maxInt(u32));

    for (slots[0 .. slots.len - 1], slots[1..]) |*slot, *next| {
        if (slot.placement != .line) continue;
        if (next.node != slot.node) continue;
        if (next.placement != .head) continue;

        slot.placement = .head;
    }
}

pub fn slot_less(_: void, left: CommentSlot, right: CommentSlot) bool {
    assert(left.text.len <= scanner_module.source_bytes_max);
    assert(right.text.len <= scanner_module.source_bytes_max);

    if (left.node != right.node) return left.node < right.node;
    return comment_module.rank_of(left.placement) < comment_module.rank_of(right.placement);
}

fn block_end_of(slots: []const CommentSlot, start: u32) u32 {
    assert(start < slots.len);
    assert(!slots[start].flags.trailing);

    var end = start + 1;

    for (start + 1..slots.len) |position| {
        const slot = &slots[position];
        if (slot.flags.trailing) break;
        if (slot.flags.blank_before) break;
        if (slot.flags.prefix != slots[start].flags.prefix) break;
        if (slot.line != slots[position - 1].line + 1) break;
        if (slot.column < slots[position - 1].column) break;

        end += 1;
    }

    assert(end > start);

    return end;
}

fn whole_lines_skip(
    slots: []const CommentSlot,
    source: []const u8,
    cursor: *u32,
    offset: u32,
) bool {
    assert(cursor.* <= slots.len);
    assert(offset <= source.len);

    var result = true;

    for (cursor.*..slots.len) |slot_index| {
        const slot = &slots[slot_index];
        if (offset_of(source, slot) >= offset) break;

        if (!slot.flags.trailing) result = false;

        cursor.* += 1;
    }

    return result;
}

pub const Blanks = struct {
    clean_cursor: u32,
    clean_from: u32,
    clean_line_limit: u32,
    cursor: u32,
    line_last: u32,
    pending: u32,
    pending_role: Role,

    pub const empty: Blanks = .{
        .clean_cursor = 0,
        .clean_from = 0,
        .clean_line_limit = 0,
        .cursor = 0,
        .line_last = none,
        .pending = none,
        .pending_role = .root,
    };
};

pub inline fn blank_observe(document: *Document, index: u32) void {
    assert(index + 1 == document.node_count);

    assert(index == 0 or
        document.storage.nodes[index - 1].offset <= document.storage.nodes[index].offset);

    const blanks = &document.composer.blanks;
    const line = document.storage.nodes[index].line;

    if (line < blanks.clean_line_limit) {
        blanks.clean_line_limit = line + 2;

        return;
    }

    blank_track(document, index);
}

noinline fn blank_track(document: *Document, index: u32) void {
    assert(index + 1 == document.node_count);
    assert(document.storage.comments.len > 0);

    const blanks = &document.composer.blanks;
    const nodes = document.storage.nodes;
    const record = &nodes[index];

    if (blanks.clean_line_limit > 0) {
        if (gap_quiet_is(document, index)) {
            const comment_count = document.storage.parser.scanner.comment_count;
            const slots = document.storage.comments[0..comment_count];

            _ = whole_lines_skip(slots, document.source, &blanks.cursor, record.offset);
            blanks.clean_line_limit = record.line + 2;

            return;
        }

        blanks.clean_line_limit = 0;
        blanks.line_last = line_last_of(document, index);
    }

    const line_last = blanks.line_last;
    const near = line_last != none and record.line - line_last <= 1;
    const settled = near and blanks.pending == none;

    if (settled) {
        const advanced = record.line != line_last and !synthetic_is(record);

        if (advanced) blanks.line_last = record.line;
    } else {
        blank_settle(document, index);
    }

    if (blanks.pending == none) {
        blanks.clean_from = index + 1;
        blanks.clean_line_limit = record.line + 2;
    }
}

fn line_last_of(document: *const Document, index: u32) u32 {
    assert(index < document.node_count);
    assert(document.composer.blanks.clean_from <= index);

    const blanks = &document.composer.blanks;
    const nodes = document.storage.nodes;
    var position = index;

    for (blanks.clean_from..index) |_| {
        position -= 1;

        const record = &nodes[position];
        if (!synthetic_is(record)) return record.line;
    }

    return blanks.line_last;
}

fn gap_quiet_is(document: *Document, index: u32) bool {
    assert(index + 1 == document.node_count);
    assert(document.composer.blanks.clean_line_limit > 0);

    const blanks = &document.composer.blanks;
    const nodes = document.storage.nodes;
    const record = &nodes[index];
    const slots = document.storage.comments[0..document.storage.parser.scanner.comment_count];
    var line = if (index == 0) 0 else nodes[index - 1].line + 1;
    var cursor = blanks.clean_cursor;

    for (blanks.clean_cursor..slots.len) |_| {
        if (cursor == slots.len) break;

        const slot = &slots[cursor];
        if (slot.line >= record.line) break;
        if (slot.line > line) break;

        cursor += 1;

        if (slot.line == line) line += 1;
    }

    blanks.clean_cursor = cursor;

    if (line >= record.line) return true;

    const start = if (index == 0) 0 else nodes[index - 1].offset;
    if (record.offset < start) return false;
    return scanner_module.blank_line_find(document.source[start..record.offset]) == none;
}

fn blank_settle(document: *Document, index: u32) void {
    assert(index + 1 == document.node_count);
    assert(document.storage.comments.len > 0);

    const composer = &document.composer;
    const blanks = &composer.blanks;
    const nodes = document.storage.nodes[0..document.node_count];
    const count = composer.frame_count;
    const parent = if (count == 0) null else &composer.frames[count - 1];

    if (blanks.pending != none) {
        const pending = blanks.pending;
        const child_first = parent != null and parent.?.node == pending;

        blank_set(document, blank_target_of(nodes, pending, blanks.pending_role, child_first));
        blanks.pending = none;
    }

    const slots = document.storage.comments[0..document.storage.parser.scanner.comment_count];
    const record = &nodes[index];
    const quiet = whole_lines_skip(slots, document.source, &blanks.cursor, record.offset);
    const line_last = blanks.line_last;
    if (record.line == line_last) return;
    if (synthetic_is(record)) return;

    blanks.line_last = record.line;

    const adjacent = line_last != none and record.line == line_last + 1;
    const document_crossed = parent == null and !marker_line_is(document.source, record.offset);

    const after_block = quiet and index > 0 and block_scalar_is(&nodes[index - 1]) and
        !document_crossed;

    if (adjacent) return;
    if (after_block) return;

    const flow = parent != null and nodes[parent.?.node].style == flow_style;

    if (flow) {
        if (!flow_line_first_is(document.source, record.offset)) return;
    }

    blank_mark(document, index, parent);
}

fn blank_mark(document: *Document, index: u32, parent: ?*const composer_module.Frame) void {
    assert(index < document.node_count);
    assert(!synthetic_is(&document.storage.nodes[index]));
    assert(parent == null or parent.?.node < index);

    const nodes = document.storage.nodes[0..document.node_count];
    const source = document.source;
    const record = &nodes[index];

    const role: Role = if (parent) |frame| role: {
        if (!frame.mapping) break :role .item;
        if (frame.key == none) break :role .key;

        break :role .value;
    } else .root;

    const first = if (parent) |frame| frame.count == 0 and frame.key == none else true;

    const indicator: ?Indicator = switch (role) {
        .item => .{ .byte = '-', .first = first, .parent = parent.?.node },
        .key => .{ .byte = '?', .first = first, .parent = parent.?.node },
        .root, .value => null,
    };

    const above: Above = .{
        .nodes = nodes,
        .slots = document.storage.comments[0..document.composer.blanks.cursor],
        .source = source,
    };

    switch (blank_above_of(&above, record.offset, indicator)) {
        .direct => {
            const below_indicator = role != .root and line_white_is(source, record.offset);
            const role_target: Role = if (below_indicator) .value else role;
            const deferred = collection_is(record) and record.style != flow_style;

            if (deferred) {
                document.composer.blanks.pending = index;
                document.composer.blanks.pending_role = role_target;
            } else {
                blank_set(document, blank_target_of(nodes, index, role_target, false));
            }
        },
        .indicator => blank_set(document, index),
        .none => {},
    }
}

fn blank_set(document: *Document, target: u32) void {
    assert(target < document.node_count);
    assert(document.composer.frame_count <= composer_module.frame_capacity);

    const nodes = document.storage.nodes;
    const composer = &document.composer;

    nodes[target].markers.blank_before = true;

    for (composer.frames[0..composer.frame_count]) |*frame| {
        if (frame.node == target) continue;

        nodes[frame.node].markers.blank_inside = true;
    }
}

fn blank_target_of(nodes: []const Record, index: u32, role: Role, child_first: bool) u32 {
    assert(index < nodes.len);
    assert(@backingInt(role) <= 3);
    assert(!child_first or index + 1 < nodes.len);

    if (role != .value) return index;

    const record = &nodes[index];
    if (!collection_is(record)) return index;
    if (record.style == flow_style) return index;
    if (!child_first) return index;
    if (synthetic_is(&nodes[index + 1])) return index;

    const result = index + 1;

    assert(result < nodes.len);

    return result;
}

fn content_column_of(nodes: []const Record, source: []const u8, index: u32) u32 {
    assert(index < nodes.len);
    assert(collection_is(&nodes[index]));
    assert(source.len <= scanner_module.source_bytes_max);

    const record = &nodes[index];
    if (record.style == flow_style) return record.column;

    const bare = record.anchor.len == 0 and record.tag.len == 0;
    if (bare) return record.column;

    var offset = record.offset;

    for (0..2) |_| {
        if (offset == source.len) break;

        const property_ended = source[offset] != '&' and source[offset] != '!';
        if (property_ended) break;

        offset = @intCast(std.mem.findAnyPos(u8, source, offset, " \t\r\n") orelse source.len);
        offset = @intCast(std.mem.findNonePos(u8, source, offset, " \t") orelse source.len);
    }

    const content = significant_from(source, offset);
    if (content == source.len) return record.column;

    const line_start: u32 = if (std.mem.findLastAny(u8, source[0..content], "\n\r")) |found|
        @intCast(found + 1)
    else
        0;

    if (line_start <= record.offset) return record.column;

    const result = content - line_start;

    assert(result <= content);

    return result;
}

fn line_indent_of(source: []const u8, record: *const Record) u32 {
    assert(record.offset <= source.len);
    assert(source.len <= scanner_module.source_bytes_max);

    const offset = record.offset;
    const column = record.column;

    const ascii = column <= offset and
        (column == offset or line_break_at(source, offset - column - 1));

    const start: u32 = if (ascii) offset - column else line_start_of(source, offset);

    var result: u32 = 0;

    for (source[start..offset]) |byte| {
        if (byte != ' ') break;

        result += 1;
    }

    return result;
}

fn significant_after(source: []const u8, last: *const CommentSlot) u32 {
    assert(last.text.len > 0);
    assert(source.len <= scanner_module.source_bytes_max);

    const end = offset_of(source, last) + @as(u32, @intCast(last.text.len));
    return significant_from(source, end);
}

fn significant_from(source: []const u8, start: u32) u32 {
    assert(start <= source.len);
    assert(source.len <= scanner_module.source_bytes_max);

    var offset = start;

    for (0..source.len + 1) |_| {
        if (offset == source.len) break;

        switch (source[offset]) {
            ' ', '\t', '\r', '\n' => offset += 1,
            '#' => {
                const line_feed = std.mem.findScalarPos(u8, source, offset, '\n') orelse source.len;
                const carriage = std.mem.findScalarPos(u8, source[0..line_feed], offset, '\r');

                offset = @intCast(carriage orelse line_feed);
            },
            else => break,
        }
    }

    assert(offset <= source.len);

    return offset;
}

fn entered_of(previous: scanner_module.TokenKind) Role {
    assert(@backingInt(previous) <= @backingInt(scanner_module.TokenKind.value));

    return switch (previous) {
        .block_entry => .item,
        .key => .key,
        .value => .value,
        else => .root,
    };
}

const BlankAbove = enum {
    direct,
    indicator,
    none,
};

const Indicator = struct {
    byte: u8,
    first: bool,
    parent: u32,
};

const IndicatorLine = struct {
    byte: u8,
    column: u32,
    owner_offset: ?u32,
};

const Above = struct {
    nodes: []const Record,
    slots: []const CommentSlot,
    source: []const u8,
};

fn blank_above_of(above: *const Above, offset: u32, indicator: ?Indicator) BlankAbove {
    assert(offset <= above.source.len);
    assert(above.source.len <= scanner_module.source_bytes_max);
    assert(indicator == null or indicator.?.parent < above.nodes.len);

    const nodes = above.nodes;
    const source = above.source;
    const start = line_start_of(source, offset);

    for (source[start..offset]) |byte| {
        if (std.mem.findScalar(u8, " \t-?:,", byte) == null) return .none;
    }

    if (scanner_module.line_above_blank_is(source, start)) return .direct;
    if (!line_white_is(source, offset)) return .none;

    const expected = indicator orelse return .none;
    const column = content_column_of(nodes, source, expected.parent);

    const expected_line: IndicatorLine = .{
        .byte = expected.byte,
        .column = column,
        .owner_offset = if (expected.first) nodes[expected.parent].offset else null,
    };

    if (!indicator_line_above_blank_is(above, start, expected_line)) return .none;
    return .indicator;
}

fn line_break_at(source: []const u8, position: u32) bool {
    assert(position < source.len);
    assert(source.len <= scanner_module.source_bytes_max);

    return source[position] == '\n' or source[position] == '\r';
}

fn line_start_of(source: []const u8, offset: u32) u32 {
    assert(offset <= source.len);
    assert(source.len <= scanner_module.source_bytes_max);

    const found = std.mem.findLastAny(u8, source[0..offset], "\n\r") orelse return 0;
    const result: u32 = @intCast(found + 1);

    assert(result <= offset);

    return result;
}

fn flow_line_first_is(source: []const u8, offset: u32) bool {
    assert(offset <= source.len);
    assert(source.len <= scanner_module.source_bytes_max);

    const start = line_start_of(source, offset);

    for (source[start..offset], start..) |byte, position| {
        switch (byte) {
            ' ', '\t', ',', '[', '{' => {},
            '?', ':' => {
                const next = position + 1;
                if (next == offset) return false;

                const spaced = source[next] == ' ' or source[next] == '\t';
                if (!spaced) return false;
            },
            else => return false,
        }
    }

    return true;
}

fn marker_line_is(source: []const u8, offset: u32) bool {
    assert(offset <= source.len);
    assert(source.len <= scanner_module.source_bytes_max);

    const start = line_start_of(source, offset);
    if (start == offset) return false;
    return std.mem.startsWith(u8, source[start..], "---");
}

fn line_white_is(source: []const u8, offset: u32) bool {
    assert(offset <= source.len);
    assert(source.len <= scanner_module.source_bytes_max);

    const start = line_start_of(source, offset);
    return std.mem.findNone(u8, source[start..offset], " \t") == null;
}

fn indicator_line_above_blank_is(
    above: *const Above,
    line_start: u32,
    expected: IndicatorLine,
) bool {
    assert(line_start <= above.source.len);
    assert(expected.byte == '-' or expected.byte == '?');
    assert(expected.column <= above.source.len);

    const source = above.source;
    var slot_count: u32 = @intCast(above.slots.len);
    var start = line_start;
    var indicator = false;
    var commented = false;

    for (0..source.len) |_| {
        if (start == 0) return false;

        const crlf = start >= 2 and source[start - 1] == '\n' and source[start - 2] == '\r';
        const line_end = if (crlf) start - 2 else start - 1;
        const last = std.mem.findLastNone(u8, source[0..line_end], " \t");
        const blank = if (last) |position| line_break_at(source, @intCast(position)) else true;

        if (blank) {
            if (indicator) return true;
            if (!commented) return false;

            start = if (last) |position| @intCast(position + 1) else 0;

            continue;
        }

        if (indicator) return false;

        const end: u32 = @intCast(last.? + 1);

        if (slot_count > 0) {
            const slot = &above.slots[slot_count - 1];
            const slot_start = offset_of(source, slot);
            const comment_line = !slot.flags.trailing and slot_start + slot.text.len == end;

            if (comment_line) {
                commented = true;
                slot_count -= 1;
                start = line_start_of(source, slot_start);

                continue;
            }
        }

        if (source[end - 1] != expected.byte) return false;

        const above_start = line_start_of(source, end - 1);
        const lone = std.mem.findNone(u8, source[above_start .. end - 1], " \t") == null;
        if (!lone) return false;
        if (end - 1 - above_start != expected.column) return false;

        if (expected.owner_offset) |owner_offset| {
            if (owner_offset >= above_start) return false;
        }

        indicator = true;
        start = above_start;
    }

    return false;
}

fn offset_of(source: []const u8, slot: *const CommentSlot) u32 {
    assert(slot.text.len > 0);
    assert(@intFromPtr(slot.text.ptr) >= @intFromPtr(source.ptr));

    const result: u32 = @intCast(@intFromPtr(slot.text.ptr) - @intFromPtr(source.ptr));

    assert(result + slot.text.len <= source.len);

    return result;
}

fn line_of(node: u32) Target {
    assert(node != none);

    return .{ .inside = false, .node = node, .placement = .line };
}

fn head_of(node: u32) Target {
    assert(node != none);

    return .{ .inside = false, .node = node, .placement = .head };
}

fn foot_inside_of(node: u32) Target {
    assert(node != none);

    return .{ .inside = true, .node = node, .placement = .foot };
}

fn foot_of(node: u32) Target {
    assert(node != none);

    return .{ .inside = false, .node = node, .placement = .foot };
}

fn span_of(record: *const Record) u32 {
    assert(record.span > 0);
    assert(@backingInt(record.kind) <= 3);

    return record.span;
}

pub fn collection_is(record: *const Record) bool {
    assert(@backingInt(record.kind) <= 3);

    return record.kind == .mapping or record.kind == .sequence;
}

pub fn block_scalar_is(record: *const Record) bool {
    assert(@backingInt(record.kind) <= 3);

    if (record.kind != .scalar) return false;

    const literal = record.style == @backingInt(ScalarStyle.literal);
    const folded = record.style == @backingInt(ScalarStyle.folded);

    return literal or folded;
}

pub fn synthetic_is(record: *const Record) bool {
    assert(@backingInt(record.kind) <= 3);

    if (record.text.len > 0) return false;
    if (record.kind != .scalar) return false;
    if (record.style != @backingInt(ScalarStyle.plain)) return false;
    if (record.anchor.len > 0) return false;
    return record.tag.len == 0;
}

fn value_below(limit: u32, value: u32) bool {
    assert(limit != none);
    assert(value != none);

    return value < limit;
}

test partition_near {
    var prng: std.Random.DefaultPrng = .init(std.testing.random_seed);
    const random = prng.random();
    var values: [1200]u32 = undefined;

    for (0..2000) |_| {
        const count = random.uintAtMost(u32, values.len);
        var value: u32 = 0;

        for (values[0..count]) |*item| {
            value += random.uintAtMost(u32, 3);
            item.* = value;
        }

        const items = values[0..count];
        const limit = random.uintAtMost(u32, value + 2);
        const expected = std.sort.partitionPoint(u32, items, limit, value_below);

        try std.testing.expectEqual(expected, partition_near(u32, items, limit, value_below));
    }
}
