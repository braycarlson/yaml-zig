const std = @import("std");

const document_module = @import("document.zig");

const assert = std.debug.assert;

const Document = document_module.Document;
const Node = document_module.Node;
const ScalarStyle = document_module.ScalarStyle;

pub const entry_count_max: u32 = 256;
pub const source_bytes_max: u32 = 512 * 1024;
const anchor_count: u32 = 8;
const characters_max: u32 = 16;
const depth_limit: u32 = 6;
const document_count_max: u32 = 3;
const frame_capacity: u32 = depth_limit + 1;
const index_none: u32 = std.math.maxInt(u32);
const line_count_max: u32 = 4;
const paragraph_count_max: u32 = 3;
const text_bytes_bound: u32 = 512;
const pool_bytes_max: u32 = entry_count_max * text_bytes_bound;
const word_count_max: u32 = 5;
const word_letters_max: u32 = 6;

comptime {
    assert(frame_capacity > depth_limit);
    assert(line_count_max * (characters_max * 4 + 4) + 16 < text_bytes_bound);
    assert(paragraph_count_max * word_count_max * (word_letters_max + 1) + 16 < text_bytes_bound);
    assert(std.math.isPowerOfTwo(anchor_count));
}

pub const Error = error{
    ModelMismatch,
    SourceExhausted,
};

const anchor_names = [anchor_count][]const u8{ "a0", "a1", "a2", "a3", "a4", "a5", "a6", "a7" };
const anchor_properties = [_][]const u8{ "&a0", "&a1", "&a2", "&a3", "&a4", "&a5", "&a6", "&a7" };
const letters = "abcdefghijklmnopqrstuvwxyz";
const word_tail = "abcdefghijklmnopqrstuvwxyz0123456789._/-";

const multibyte = [_][]const u8{
    "\u{e9}",
    "\u{20ac}",
    "\u{1f600}",
    "\u{85}",
    "\u{a0}",
    "\u{2028}",
    "\u{fffd}",
    "\u{10ffff}",
};

const controls = [_][]const u8{
    "\x00",
    "\x01",
    "\x07",
    "\x08",
    "\n",
    "\x0b",
    "\x0c",
    "\r",
    "\x1b",
    "\x1f",
    "\x7f",
    "\u{80}",
    "\u{9f}",
};

const TagForm = struct {
    collection: bool,
    emitted: []const u8,
    expected: []const u8,
    named: bool,
    scalar: bool,
};

const tag_forms = [_]TagForm{
    .{
        .collection = true,
        .emitted = "!local",
        .expected = "!local",
        .named = false,
        .scalar = true,
    },
    .{
        .collection = true,
        .emitted = "!lo%63al",
        .expected = "!local",
        .named = false,
        .scalar = true,
    },
    .{
        .collection = true,
        .emitted = "!<tag:example.com,2000:v>",
        .expected = "tag:example.com,2000:v",
        .named = false,
        .scalar = true,
    },
    .{
        .collection = true,
        .emitted = "!e!nm",
        .expected = "tag:example.com,2000:nm",
        .named = true,
        .scalar = true,
    },
    .{
        .collection = true,
        .emitted = "!e!n%2Fm",
        .expected = "tag:example.com,2000:n/m",
        .named = true,
        .scalar = true,
    },
    .{ .collection = false, .emitted = "!", .expected = "!", .named = false, .scalar = true },
    .{
        .collection = false,
        .emitted = "!!str",
        .expected = "tag:yaml.org,2002:str",
        .named = false,
        .scalar = true,
    },
};

const EntryKind = enum {
    alias,
    mapping,
    scalar,
    sequence,
};

const Form = enum {
    double_quoted,
    empty,
    folded,
    literal,
    plain,
    single_quoted,
};

const Slot = enum {
    explicit_key,
    flow_item,
    flow_key,
    flow_value,
    implicit_key,
    item,
    root,
    value,
};

const Entry = struct {
    anchor: u32,
    child_count: u32,
    flow: bool,
    form: Form,
    key: bool,
    kind: EntryKind,
    parent: u32,
    span: u32,
    tag: u32,
    target: u32,
    text_end: u32,
    text_start: u32,
};

const Header = struct {
    content: bool,
    increment: u32,
    trailing: u32,
};

const AnchorState = struct {
    complete: bool,
    entry: u32,
};

const Frame = struct {
    alias_key: bool,
    child_index: u32,
    column: u32,
    entry: u32,
    explicit: bool,
    indent: i32,
    inline_first: bool,
    single_pair: bool,
};

const Children = union(enum) {
    entries: document_module.Entries,
    items: document_module.Items,
};

const CompareFrame = struct {
    children: Children,
    cursor: u32,
    key_entry: u32,
    node: Node,
    pair: document_module.Entries.Entry,
    remaining: u32,
    value_phase: bool,
};

const CompareStack = struct {
    count: u32,
    frames: [frame_capacity]CompareFrame,
};

pub const Model = struct {
    anchors: [anchor_count]AnchorState,
    crlf: bool,
    document_count: u32,
    entries: [entry_count_max]Entry,
    entry_count: u32,
    frame_count: u32,
    frames: [frame_capacity]Frame,
    handles: [entry_count_max]Node,
    key_counter: u32,
    line_fresh: bool,
    named_declared: bool,
    pending: u32,
    pool: [pool_bytes_max]u8,
    pool_used: u32,
    prng: *std.Random.DefaultPrng,
    roots: [document_count_max]u32,
    source: [source_bytes_max]u8,
    source_used: u32,

    pub fn generate(model: *Model, prng: *std.Random.DefaultPrng) Error![]const u8 {
        assert(model.frames.len == frame_capacity);
        assert(model.entries.len == entry_count_max);

        model.prng = prng;
        model.document_count = 0;
        model.entry_count = 0;
        model.frame_count = 0;
        model.key_counter = 0;
        model.line_fresh = true;
        model.pending = 0;
        model.pool_used = 0;
        model.source_used = 0;
        model.crlf = model.chance(8);

        if (model.chance(8)) {
            @memcpy(model.source[0..3], "\xef\xbb\xbf");
            model.source_used = 3;
        }

        const document_count = 1 + model.below(document_count_max);
        var ended = true;

        for (0..document_count) |index| {
            if (model.entry_count + 16 > entry_count_max) break;

            ended = try model.document_generate(@intCast(index), ended);
        }

        if (model.chance(2)) try model.line_end();

        assert(model.frame_count == 0);

        return model.source[0..model.source_used];
    }

    pub fn compare(model: *Model, document: *const Document) Error!void {
        assert(model.document_count <= document_count_max);
        assert(model.frame_count == 0);

        if (document.document_count != model.document_count) {
            return model.mismatch(0, "document count");
        }

        for (0..model.document_count) |index| {
            const root = document.root(@intCast(index));

            try model.tree_compare(document, model.roots[index], root);
        }
    }

    fn chance(model: *Model, denominator: u32) bool {
        assert(denominator > 0);
        assert(denominator <= 1024);

        return model.prng.random().uintLessThan(u32, denominator) == 0;
    }

    fn below(model: *Model, bound: u32) u32 {
        assert(bound > 0);
        assert(bound <= 1 << 16);

        return model.prng.random().uintLessThan(u32, bound);
    }

    fn write(model: *Model, bytes: []const u8) Error!void {
        assert(model.source_used <= source_bytes_max);
        assert(bytes.len <= source_bytes_max);

        if (bytes.len > source_bytes_max - model.source_used) return error.SourceExhausted;

        @memcpy(model.source[model.source_used..][0..bytes.len], bytes);
        model.source_used += @intCast(bytes.len);

        if (bytes.len > 0) model.line_fresh = false;
    }

    fn newline(model: *Model) Error!void {
        assert(model.source_used <= source_bytes_max);
        assert(model.pool_used <= pool_bytes_max);

        try model.write(if (model.crlf) "\r\n" else "\n");

        model.line_fresh = true;
    }

    fn spaces(model: *Model, count: u32) Error!void {
        assert(count <= 1024);
        assert(model.source_used <= source_bytes_max);

        for (0..count) |_| try model.write(" ");
    }

    fn line_start(model: *Model, column: u32) Error!void {
        assert(column <= 1024);
        assert(model.source_used <= source_bytes_max);

        if (!model.line_fresh) try model.newline();

        try model.spaces(column);
    }

    fn line_end(model: *Model) Error!void {
        assert(model.source_used <= source_bytes_max);
        assert(model.frame_count <= frame_capacity);

        if (!model.line_fresh) try model.newline();
    }

    fn pool_write(model: *Model, bytes: []const u8) void {
        assert(bytes.len <= text_bytes_bound);
        assert(model.pool_used + bytes.len <= pool_bytes_max);

        @memcpy(model.pool[model.pool_used..][0..bytes.len], bytes);
        model.pool_used += @intCast(bytes.len);
    }

    fn text_of(model: *const Model, entry: *const Entry) []const u8 {
        assert(entry.text_start <= entry.text_end);
        assert(entry.text_end <= model.pool_used);

        return model.pool[entry.text_start..entry.text_end];
    }

    fn document_generate(model: *Model, index: u32, ended: bool) Error!bool {
        assert(index < document_count_max);
        assert(model.frame_count == 0);

        for (&model.anchors) |*anchor| anchor.* = .{ .complete = false, .entry = index_none };

        const version = ended and model.chance(8);

        model.named_declared = ended and model.chance(4);

        if (version) {
            try model.line_start(0);
            try model.write("%YAML 1.2");
            try model.newline();
        }

        if (model.named_declared) {
            try model.line_start(0);
            try model.write("%TAG !e! tag:example.com,2000:");
            try model.newline();
        }

        const explicit = index > 0 or version or model.named_declared or model.chance(2);

        if (explicit) {
            try model.line_start(0);
            try model.write("---");
        }

        model.roots[index] = model.entry_count;
        model.document_count += 1;

        try model.node_generate(.root, -1);
        try model.frames_drain();

        const end = model.chance(3);

        if (end) {
            try model.line_start(0);
            try model.write("...");
            try model.newline();
        }

        return end;
    }

    fn frames_drain(model: *Model) Error!void {
        assert(model.frame_count <= frame_capacity);
        assert(model.entry_count <= entry_count_max);

        for (0..entry_count_max * 2 + 2) |_| {
            if (model.frame_count == 0) return;

            try model.frame_step();
        }

        unreachable;
    }

    fn frame_step(model: *Model) Error!void {
        assert(model.frame_count > 0);
        assert(model.frame_count <= frame_capacity);

        const frame = &model.frames[model.frame_count - 1];
        const entry = &model.entries[frame.entry];
        if (frame.child_index == entry.child_count) return model.frame_close();

        model.pending -= 1;
        frame.child_index += 1;

        switch (entry.kind) {
            .mapping => {
                if (entry.flow) return model.flow_mapping_child(frame);
                return model.block_mapping_child(frame);
            },
            .sequence => {
                if (entry.flow) return model.flow_sequence_child(frame);
                return model.block_sequence_child(frame);
            },
            .alias, .scalar => unreachable,
        }
    }

    fn frame_push(model: *Model, frame: *const Frame) void {
        assert(model.frame_count < frame_capacity);
        assert(frame.entry < model.entry_count);

        model.frames[model.frame_count] = frame.*;
        model.frame_count += 1;
        model.pending += model.entries[frame.entry].child_count;
    }

    fn frame_close(model: *Model) Error!void {
        assert(model.frame_count > 0);
        assert(model.pending <= entry_count_max);

        model.frame_count -= 1;

        const frame = &model.frames[model.frame_count];
        const entry = &model.entries[frame.entry];

        entry.span = model.entry_count - frame.entry;

        if (entry.flow) {
            if (!frame.single_pair) try model.write(if (entry.kind == .mapping) "}" else "]");
        }

        model.anchor_complete(frame.entry);
    }

    fn anchor_complete(model: *Model, index: u32) void {
        assert(index < model.entry_count);
        assert(model.anchors.len == anchor_count);

        const entry = &model.entries[index];
        if (entry.anchor == 0) return;

        const anchor = &model.anchors[entry.anchor - 1];

        if (anchor.entry == index) anchor.complete = true;
    }

    fn block_mapping_child(model: *Model, frame: *Frame) Error!void {
        assert(frame.child_index > 0);
        assert(frame.column <= 1024);

        const index = frame.child_index - 1;
        const indent: i32 = @intCast(frame.column);

        if (index % 2 == 1) {
            if (!frame.explicit) return model.node_generate(.value, indent);

            try model.line_start(frame.column);
            try model.write(":");

            return model.node_generate(.item, indent);
        }

        const fresh_line = index > 0 or !frame.inline_first;

        if (fresh_line) {
            try model.comment_line_maybe(frame.column);
            try model.line_start(frame.column);
        }

        frame.explicit = model.chance(5);

        if (frame.explicit) {
            try model.write("?");

            return model.node_generate(.explicit_key, indent);
        }

        try model.node_generate(.implicit_key, indent);
        try model.write(":");
    }

    fn block_sequence_child(model: *Model, frame: *Frame) Error!void {
        assert(frame.child_index > 0);
        assert(frame.column <= 1024);

        const fresh_line = frame.child_index > 1 or !frame.inline_first;

        if (fresh_line) {
            try model.comment_line_maybe(frame.column);
            try model.line_start(frame.column);
        }

        try model.write("-");
        try model.node_generate(.item, @intCast(frame.column));
    }

    fn flow_sequence_child(model: *Model, frame: *Frame) Error!void {
        assert(frame.child_index > 0);
        assert(frame.indent >= -1);

        if (frame.child_index > 1) try model.flow_separator(frame);

        try model.node_generate(.flow_item, frame.indent);
    }

    fn flow_mapping_child(model: *Model, frame: *Frame) Error!void {
        assert(frame.child_index > 0);
        assert(frame.indent >= -1);

        const index = frame.child_index - 1;

        if (index % 2 == 1) {
            try model.write(":");

            return model.node_generate(.flow_value, frame.indent);
        }

        if (index > 0) try model.flow_separator(frame);

        try model.node_generate(.flow_key, frame.indent);
    }

    fn flow_separator(model: *Model, frame: *const Frame) Error!void {
        assert(frame.indent >= -1);
        assert(model.frame_count > 0);

        try model.write(",");

        if (!model.chance(4)) return model.write(" ");

        if (model.chance(3)) try model.write(" # c");

        try model.newline();
        try model.spaces(model.continuation_of(frame.indent));
    }

    fn continuation_of(model: *Model, indent: i32) u32 {
        assert(indent >= -1);
        assert(indent <= 1024);

        const minimum: u32 = @intCast(@max(indent + 1, 1));
        const result = minimum + model.below(3);

        assert(result >= minimum);

        return result;
    }

    fn comment_line_maybe(model: *Model, column: u32) Error!void {
        assert(column <= 1024);
        assert(model.frame_count > 0);

        if (!model.chance(10)) return;

        try model.line_start(model.below(column + 1));
        try model.write("# line comment");
        try model.newline();
    }

    fn comment_inline_maybe(model: *Model, slot: Slot) Error!void {
        assert(model.entry_count > 0);
        assert(model.source_used <= source_bytes_max);

        const allowed = switch (slot) {
            .explicit_key, .item, .root, .value => true,
            .flow_item, .flow_key, .flow_value, .implicit_key => false,
        };

        if (!allowed) return;

        if (model.chance(8)) try model.write(" # inline comment");
    }

    fn separator_write(model: *Model, slot: Slot) Error!void {
        assert(model.source_used <= source_bytes_max);
        assert(model.frame_count <= frame_capacity);

        switch (slot) {
            .explicit_key, .flow_value, .item, .value => try model.write(" "),
            .flow_item, .flow_key, .implicit_key => {},
            .root => if (!model.line_fresh) try model.write(" "),
        }
    }

    fn entry_add(model: *Model, kind: EntryKind, slot: Slot) *Entry {
        assert(model.entry_count < entry_count_max);
        assert(model.frame_count <= frame_capacity);

        const index = model.entry_count;
        const depth = model.frame_count;
        const parent = if (depth == 0) index_none else model.frames[depth - 1].entry;

        const key = switch (slot) {
            .explicit_key, .flow_key, .implicit_key => true,
            .flow_item, .flow_value, .item, .root, .value => false,
        };

        model.entries[index] = .{
            .anchor = 0,
            .child_count = 0,
            .flow = false,
            .form = .plain,
            .key = key,
            .kind = kind,
            .parent = parent,
            .span = 1,
            .tag = 0,
            .target = index_none,
            .text_end = model.pool_used,
            .text_start = model.pool_used,
        };

        model.entry_count += 1;

        return &model.entries[index];
    }

    fn node_generate(model: *Model, slot: Slot, indent: i32) Error!void {
        assert(indent >= -1);
        assert(model.entry_count < entry_count_max);

        const key_slot = switch (slot) {
            .flow_key, .implicit_key => true,
            .explicit_key, .flow_item, .flow_value, .item, .root, .value => false,
        };

        const room = model.frame_count < depth_limit and
            model.entry_count + model.pending + 4 <= entry_count_max;

        const roll = model.below(10);

        if (roll == 0) {
            if (slot != .root) return model.alias_generate(slot, indent);
        }

        const scalar_only = key_slot or !room;
        if (scalar_only) return model.scalar_generate(slot, indent);
        if (roll < 4) return model.collection_generate(slot, .mapping, indent);
        if (roll < 7) return model.collection_generate(slot, .sequence, indent);
        return model.scalar_generate(slot, indent);
    }

    fn alias_generate(model: *Model, slot: Slot, indent: i32) Error!void {
        assert(indent >= -1);
        assert(slot != .root);

        const anchor = model.alias_target_choose(slot) orelse {
            return model.scalar_generate(slot, indent);
        };

        const entry = model.entry_add(.alias, slot);

        entry.target = model.anchors[anchor].entry;

        try model.separator_write(slot);
        try model.write("*");
        try model.write(anchor_names[anchor]);

        if (entry.key) {
            try model.write(" ");

            model.frames[model.frame_count - 1].alias_key = true;
        }

        try model.comment_inline_maybe(slot);
    }

    fn alias_target_choose(model: *Model, slot: Slot) ?u32 {
        assert(slot != .root);
        assert(model.frame_count > 0);

        const key_slot = switch (slot) {
            .explicit_key, .flow_key, .implicit_key => true,
            .flow_item, .flow_value, .item, .root, .value => false,
        };

        const offset = model.below(anchor_count);

        if (key_slot) {
            const frame = &model.frames[model.frame_count - 1];
            if (frame.alias_key) return null;
        }

        for (0..anchor_count) |step| {
            const anchor: u32 = @intCast((offset + step) % anchor_count);

            if (model.alias_target_allowed(anchor, key_slot)) {
                assert(model.anchors[anchor].complete);

                return anchor;
            }
        }

        return null;
    }

    fn alias_target_allowed(model: *const Model, anchor: u32, key_slot: bool) bool {
        assert(anchor < anchor_count);
        assert(model.frame_count > 0);

        const state = &model.anchors[anchor];
        if (!state.complete) return false;
        if (!key_slot) return true;

        const target = &model.entries[state.entry];
        const keyable = target.key or target.kind == .mapping or target.kind == .sequence;
        const frame = &model.frames[model.frame_count - 1];

        if (!keyable) return false;
        return target.parent != frame.entry;
    }

    fn properties_choose(model: *Model, entry: *Entry) void {
        assert(entry.kind != .alias);
        assert(entry.tag == 0);

        if (model.chance(6)) entry.anchor = 1 + model.below(anchor_count);
        if (!model.chance(6)) return;

        const offset = model.below(tag_forms.len);

        for (0..tag_forms.len) |step| {
            const index: u32 = @intCast((offset + step) % tag_forms.len);
            const form = &tag_forms[index];
            const kind_allowed = if (entry.kind == .scalar) form.scalar else form.collection;
            const undeclared = form.named and !model.named_declared;

            if (!kind_allowed) continue;
            if (undeclared) continue;

            entry.tag = index + 1;

            return;
        }
    }

    fn properties_present(entry: *const Entry) bool {
        assert(entry.anchor <= anchor_count);
        assert(entry.tag <= tag_forms.len);

        return entry.anchor > 0 or entry.tag > 0;
    }

    fn properties_write(model: *Model, index: u32) Error!void {
        assert(index < model.entry_count);
        assert(properties_present(&model.entries[index]));

        const entry = &model.entries[index];
        const anchor = if (entry.anchor > 0) anchor_properties[entry.anchor - 1] else "";
        const tag = if (entry.tag > 0) tag_forms[entry.tag - 1].emitted else "";
        const swapped = model.chance(2);
        const first = if (swapped) tag else anchor;
        const second = if (swapped) anchor else tag;

        try model.write(first);

        if (first.len > 0) {
            if (second.len > 0) try model.write(" ");
        }

        try model.write(second);

        if (entry.anchor > 0) {
            model.anchors[entry.anchor - 1] = .{ .complete = false, .entry = index };
        }
    }

    fn collection_generate(model: *Model, slot: Slot, kind: EntryKind, indent: i32) Error!void {
        assert(kind == .mapping or kind == .sequence);
        assert(indent >= -1);

        const index = model.entry_count;
        const entry = model.entry_add(kind, slot);

        const flow_context = switch (slot) {
            .flow_item, .flow_key, .flow_value => true,
            .explicit_key, .implicit_key, .item, .root, .value => false,
        };

        entry.child_count = model.child_count_choose(kind);
        entry.flow = flow_context or entry.child_count == 0 or model.chance(4);

        const pair_possible = slot == .flow_item and kind == .mapping and entry.child_count == 2;
        const single_pair = pair_possible and model.chance(2);

        if (!single_pair) model.properties_choose(entry);

        if (entry.flow) return model.flow_open(index, slot, indent, single_pair);
        return model.block_open(index, slot, indent);
    }

    fn child_count_choose(model: *Model, kind: EntryKind) u32 {
        assert(kind == .mapping or kind == .sequence);
        assert(model.entry_count + model.pending <= entry_count_max);

        const available = entry_count_max - model.entry_count - model.pending;
        const wanted = if (kind == .mapping) 2 * model.below(4) else model.below(5);
        const count = @min(wanted, available);
        const result = if (kind == .mapping) count - count % 2 else count;

        assert(result <= available);

        return result;
    }

    fn flow_open(model: *Model, index: u32, slot: Slot, indent: i32, single_pair: bool) Error!void {
        assert(index < model.entry_count);
        assert(indent >= -1);

        const entry = &model.entries[index];

        try model.separator_write(slot);

        if (properties_present(entry)) {
            try model.properties_write(index);
            try model.write(" ");
        }

        if (!single_pair) try model.write(if (entry.kind == .mapping) "{" else "[");

        model.frame_push(&.{
            .alias_key = false,
            .child_index = 0,
            .column = 0,
            .entry = index,
            .explicit = false,
            .indent = indent,
            .inline_first = true,
            .single_pair = single_pair,
        });
    }

    fn block_open(model: *Model, index: u32, slot: Slot, indent: i32) Error!void {
        assert(index < model.entry_count);
        assert(indent >= -1);

        const entry = &model.entries[index];
        const properties = properties_present(entry);
        const compact_slot = slot == .item or slot == .explicit_key;
        const compact = compact_slot and !properties and model.chance(2);
        const base: u32 = @intCast(indent + 1);
        var column: u32 = base + model.below(3);

        if (slot == .root) column = 0;

        if (slot == .value) {
            const indentless = entry.kind == .sequence and model.chance(3);

            if (indentless) column = @intCast(indent);
        }

        if (compact) {
            try model.write(" ");

            column = @as(u32, @intCast(indent)) + 2;
        }

        if (properties) {
            try model.separator_write(slot);
            try model.properties_write(index);
        }

        model.frame_push(&.{
            .alias_key = false,
            .child_index = 0,
            .column = column,
            .entry = index,
            .explicit = false,
            .indent = @intCast(column),
            .inline_first = compact,
            .single_pair = false,
        });
    }

    fn scalar_generate(model: *Model, slot: Slot, indent: i32) Error!void {
        assert(indent >= -1);
        assert(model.pool_used + text_bytes_bound <= pool_bytes_max);

        const index = model.entry_count;
        const entry = model.entry_add(.scalar, slot);

        entry.form = model.form_choose(slot);

        model.text_generate(entry.form);

        if (entry.key) model.key_prefix_insert(entry.text_start);

        entry.text_end = model.pool_used;

        if (entry.form != .empty) {
            model.properties_choose(entry);

            try model.separator_write(slot);

            if (properties_present(entry)) {
                try model.properties_write(index);
                try model.write(" ");
            }

            try model.scalar_emit(index, slot, indent);
        }

        model.anchor_complete(index);

        const block = entry.form == .literal or entry.form == .folded;

        if (!block) try model.comment_inline_maybe(slot);
    }

    fn form_choose(model: *Model, slot: Slot) Form {
        assert(model.entry_count > 0);
        assert(model.pool_used <= pool_bytes_max);

        const roll = model.below(12);
        const flow_forms = [_]Form{ .plain, .plain, .single_quoted, .double_quoted };

        const block_forms = [_]Form{
            .plain,
            .single_quoted,
            .double_quoted,
            .literal,
            .folded,
            .empty,
        };

        const block_count: u32 = block_forms.len;
        const root_count = if (model.line_fresh) block_count - 1 else block_count;

        return switch (slot) {
            .flow_item, .flow_key, .implicit_key => flow_forms[roll % flow_forms.len],
            .flow_value => if (roll == 0) .empty else flow_forms[roll % flow_forms.len],
            .explicit_key => block_forms[roll % (block_count - 1)],
            .item, .value => block_forms[roll % block_count],
            .root => block_forms[roll % root_count],
        };
    }

    fn text_generate(model: *Model, form: Form) void {
        assert(model.pool_used + text_bytes_bound <= pool_bytes_max);
        assert(model.entry_count > 0);

        switch (form) {
            .double_quoted => model.characters_generate(true),
            .empty => {},
            .folded => model.folded_generate(),
            .literal => model.literal_generate(),
            .plain => model.words_generate(),
            .single_quoted => model.characters_generate(false),
        }
    }

    fn word_generate(model: *Model) void {
        assert(model.pool_used + word_letters_max <= pool_bytes_max);
        assert(letters.len == 26);

        const length = 1 + model.below(word_letters_max);

        model.pool_write(letters[model.below(letters.len)..][0..1]);

        for (1..length) |_| model.pool_write(word_tail[model.below(word_tail.len)..][0..1]);
    }

    fn words_generate(model: *Model) void {
        assert(model.pool_used + text_bytes_bound <= pool_bytes_max);
        assert(word_count_max > 0);

        const count = 1 + model.below(word_count_max);

        for (0..count) |index| {
            if (index > 0) model.pool_write(" ");

            model.word_generate();
        }
    }

    fn character_generate(model: *Model, controls_allowed: bool) void {
        assert(model.pool_used + 4 <= pool_bytes_max);
        assert(multibyte.len > 0);

        const roll = model.below(16);

        if (roll < 10) {
            const byte: u8 = @intCast(0x20 + model.below(0x7f - 0x20));
            return model.pool_write(&.{byte});
        }

        if (roll == 10) return model.pool_write("\t");
        if (roll < 14) return model.pool_write(multibyte[model.below(multibyte.len)]);
        if (controls_allowed) return model.pool_write(controls[model.below(controls.len)]);

        model.pool_write("x");
    }

    fn characters_generate(model: *Model, controls_allowed: bool) void {
        assert(model.pool_used + text_bytes_bound <= pool_bytes_max);
        assert(characters_max * 4 < text_bytes_bound);

        const count = model.below(characters_max + 1);

        for (0..count) |_| model.character_generate(controls_allowed);
    }

    fn literal_generate(model: *Model) void {
        assert(model.pool_used + text_bytes_bound <= pool_bytes_max);
        assert(line_count_max > 0);

        const line_count = model.below(line_count_max + 1);

        for (0..line_count) |index| {
            if (index > 0) model.pool_write("\n");

            const last = index + 1 == line_count;
            const empty = !last and model.chance(4);
            if (empty) continue;

            if (model.chance(4)) model.pool_write("  "[0 .. 1 + model.below(2)]);

            const count = 1 + model.below(characters_max);

            for (0..count) |_| model.character_generate(false);
        }

        for (0..model.below(4)) |_| model.pool_write("\n");
    }

    fn folded_generate(model: *Model) void {
        assert(model.pool_used + text_bytes_bound <= pool_bytes_max);
        assert(paragraph_count_max > 0);

        const paragraph_count = model.below(paragraph_count_max + 1);

        for (0..paragraph_count) |index| {
            if (index > 0) model.pool_write("\n\n"[0 .. 1 + model.below(2)]);

            model.words_generate();
        }

        for (0..model.below(4)) |_| model.pool_write("\n");
    }

    fn key_prefix_insert(model: *Model, start: u32) void {
        assert(start <= model.pool_used);
        assert(model.pool_used + 16 <= pool_bytes_max);

        var buffer: [11]u8 = undefined;
        const digits = decimal_write(buffer[1..], model.key_counter);
        const counter = buffer[buffer.len - digits.len - 1 ..];
        const length = model.pool_used - start;
        const separated = length > 0 and model.pool[start] != '\n';
        const prefix_length: u32 = @intCast(counter.len + @intFromBool(separated));
        const text = model.pool[start..model.pool_used];

        std.mem.copyBackwards(u8, model.pool[start + prefix_length ..][0..length], text);
        counter[0] = 'k';

        @memcpy(model.pool[start..][0..counter.len], counter);

        if (separated) model.pool[start + counter.len] = ' ';

        model.pool_used += prefix_length;
        model.key_counter += 1;
    }

    fn scalar_emit(model: *Model, index: u32, slot: Slot, indent: i32) Error!void {
        assert(index < model.entry_count);
        assert(indent >= -1);

        const entry = &model.entries[index];
        const text = model.text_of(entry);

        const multiline_slot = switch (slot) {
            .flow_key, .implicit_key => false,
            .explicit_key, .flow_item, .flow_value, .item, .root, .value => true,
        };

        const multiline = multiline_slot and model.chance(3);
        const continuation = model.continuation_of(indent);

        switch (entry.form) {
            .double_quoted => try model.double_quoted_emit(text, multiline, continuation),
            .empty => {},
            .folded => try model.block_emit(text, indent, '>'),
            .literal => try model.block_emit(text, indent, '|'),
            .plain => try model.plain_emit(text, multiline, continuation),
            .single_quoted => try model.single_quoted_emit(text, multiline, continuation),
        }
    }

    fn fold_point_is(text: []const u8, index: usize) bool {
        assert(index < text.len);
        assert(text.len <= text_bytes_bound);

        if (text[index] != ' ') return false;
        if (index == 0) return false;
        if (index + 1 == text.len) return false;

        const before = text[index - 1];
        const after = text[index + 1];
        const before_blank = before == ' ' or before == '\t';
        const after_blank = after == ' ' or after == '\t';

        return !before_blank and !after_blank;
    }

    fn fold_write(model: *Model, continuation: u32) Error!void {
        assert(continuation >= 1);
        assert(continuation <= 1024);

        try model.newline();
        try model.spaces(continuation);
    }

    fn plain_emit(model: *Model, text: []const u8, multiline: bool, continuation: u32) Error!void {
        assert(text.len > 0);
        assert(continuation >= 1);

        for (text) |byte| {
            const fold = multiline and byte == ' ' and model.chance(3);

            if (fold) {
                try model.fold_write(continuation);

                continue;
            }

            try model.write(&.{byte});
        }
    }

    fn single_quoted_emit(
        model: *Model,
        text: []const u8,
        multiline: bool,
        continuation: u32,
    ) Error!void {
        assert(text.len <= text_bytes_bound);
        assert(continuation >= 1);

        try model.write("'");

        for (text, 0..) |byte, index| {
            const fold = multiline and fold_point_is(text, index) and model.chance(3);

            if (fold) {
                try model.fold_write(continuation);

                continue;
            }

            try model.write(if (byte == '\'') "''" else &.{byte});
        }

        try model.write("'");
    }

    fn double_quoted_emit(
        model: *Model,
        text: []const u8,
        multiline: bool,
        continuation: u32,
    ) Error!void {
        assert(text.len <= text_bytes_bound);
        assert(continuation >= 1);

        try model.write("\"");

        var iterator = std.unicode.Utf8View.initUnchecked(text).iterator();

        for (0..text.len) |_| {
            const index: u32 = @intCast(iterator.i);
            const codepoint = iterator.nextCodepoint() orelse break;
            const break_allowed = multiline and index > 0;

            if (break_allowed) try model.escaped_break_maybe(codepoint, continuation);

            const fold = multiline and fold_point_is(text, index) and model.chance(3);

            if (fold) {
                try model.fold_write(continuation);
            } else {
                const bytes = text[index..iterator.i];

                try model.character_escape(codepoint, bytes);
            }
        }

        try model.write("\"");
    }

    fn escaped_break_maybe(model: *Model, codepoint: u21, continuation: u32) Error!void {
        assert(codepoint <= 0x10ffff);
        assert(continuation >= 1);

        if (codepoint == ' ') return;
        if (codepoint == '\t') return;
        if (!model.chance(10)) return;

        try model.write("\\");
        try model.fold_write(continuation);
    }

    fn character_escape(model: *Model, codepoint: u21, bytes: []const u8) Error!void {
        assert(bytes.len >= 1);
        assert(bytes.len <= 4);
        assert(codepoint <= 0x10ffff);

        const control = codepoint < 0x20 or codepoint == 0x7f or
            (codepoint >= 0x80 and codepoint <= 0x9f and codepoint != 0x85);

        const quote = codepoint == '"' or codepoint == '\\';
        const raw = !control and !quote;

        if (raw) {
            if (!model.chance(8)) return model.write(bytes);
        }

        if (escape_name_of(codepoint)) |name| {
            if (model.chance(2)) return model.write(name);
        }

        const roll = model.below(3);
        const byte_escape = codepoint <= 0xff and roll == 0;
        const short_escape = codepoint <= 0xffff and roll < 2;

        if (byte_escape) return model.hexadecimal_write("\\x", codepoint, 2);
        if (short_escape) return model.hexadecimal_write("\\u", codepoint, 4);

        try model.hexadecimal_write("\\U", codepoint, 8);
    }

    fn hexadecimal_write(model: *Model, prefix: []const u8, codepoint: u21, width: u32) Error!void {
        assert(prefix.len == 2);
        assert(width == 2 or width == 4 or width == 8);
        assert(codepoint <= 0x10ffff);

        const digits = if (model.chance(2)) "0123456789ABCDEF" else "0123456789abcdef";

        try model.write(prefix);

        for (0..width) |step| {
            const shift: u5 = @intCast(4 * (width - 1 - step));
            const digit = (@as(u32, codepoint) >> shift) & 0xf;

            try model.write(digits[digit..][0..1]);
        }
    }

    fn block_emit(model: *Model, text: []const u8, indent: i32, indicator: u8) Error!void {
        assert(indicator == '|' or indicator == '>');
        assert(indent >= -1);
        assert(text.len <= text_bytes_bound);

        var trailing: u32 = 0;

        for (0..text.len) |step| {
            if (text[text.len - 1 - step] != '\n') break;

            trailing += 1;
        }

        const body = text[0 .. text.len - trailing];
        const content = model.continuation_of(indent);
        const increment: u32 = @intCast(@as(i32, @intCast(content)) - indent);
        const explicit = leading_space_has(body) or model.chance(3);

        assert(increment >= 1);
        assert(increment <= 9);

        const header = Header{
            .content = body.len > 0,
            .increment = if (explicit) increment else 0,
            .trailing = trailing,
        };

        try model.write(&.{indicator});
        try model.header_write(&header);
        try model.newline();

        if (indicator == '|') {
            try model.literal_lines_emit(body, content);
        } else {
            try model.folded_lines_emit(body, content);
        }

        const extra = if (body.len > 0) trailing -| 1 else trailing;

        for (0..extra) |_| try model.empty_line_write(content);
    }

    fn header_write(model: *Model, header: *const Header) Error!void {
        assert(header.increment <= 9);
        assert(header.trailing <= 8);

        const chomping = model.chomping_of(header);
        const digits = "0123456789";
        const digit = if (header.increment > 0) digits[header.increment..][0..1] else "";

        if (model.chance(2)) {
            try model.write(digit);
            try model.write(chomping);
        } else {
            try model.write(chomping);
            try model.write(digit);
        }

        if (model.chance(6)) try model.write(" # header comment");
    }

    fn chomping_of(model: *Model, header: *const Header) []const u8 {
        assert(header.trailing <= 8);
        assert(header.increment <= 9);

        const coin = model.chance(2);

        if (header.trailing >= 2) return "+";

        if (header.trailing == 1) {
            if (!header.content) return "+";
            if (coin) return "+";
            return "";
        }

        if (header.content) return "-";
        if (coin) return "-";
        return "";
    }

    fn empty_line_write(model: *Model, content: u32) Error!void {
        assert(content >= 1);
        assert(content <= 1024);

        try model.spaces(model.below(content + 1));
        try model.newline();
    }

    fn literal_lines_emit(model: *Model, body: []const u8, content: u32) Error!void {
        assert(content >= 1);
        assert(body.len <= text_bytes_bound);

        if (body.len == 0) return;

        var lines = std.mem.splitScalar(u8, body, '\n');

        for (0..body.len + 1) |_| {
            const line = lines.next() orelse return;

            if (line.len == 0) {
                try model.empty_line_write(content);

                continue;
            }

            try model.spaces(content);
            try model.write(line);
            try model.newline();
        }
    }

    fn folded_lines_emit(model: *Model, body: []const u8, content: u32) Error!void {
        assert(content >= 1);
        assert(body.len <= text_bytes_bound);

        if (body.len == 0) return;

        var paragraphs = std.mem.splitScalar(u8, body, '\n');
        var first = true;

        for (0..body.len + 1) |_| {
            const paragraph = paragraphs.next() orelse return;

            if (!first) try model.empty_line_write(content);

            first = false;

            if (paragraph.len == 0) continue;

            try model.spaces(content);

            for (paragraph) |byte| {
                const fold = byte == ' ' and model.chance(3);

                if (fold) {
                    try model.fold_write(content);

                    continue;
                }

                try model.write(&.{byte});
            }

            try model.newline();
        }
    }

    fn tree_compare(model: *Model, document: *const Document, entry: u32, root: Node) Error!void {
        assert(entry < model.entry_count);
        assert(model.entries[entry].kind != .alias);
        assert(@backingInt(root) < document.node_count);

        var stack: CompareStack = .{ .count = 0, .frames = undefined };

        try model.node_compare(document, entry, root, &stack);

        for (0..entry_count_max * 2 + 1) |_| {
            if (stack.count == 0) return;

            const top = &stack.frames[stack.count - 1];

            if (top.remaining == 0) {
                stack.count -= 1;

                continue;
            }

            try model.child_compare(document, top, &stack);
        }

        unreachable;
    }

    fn node_compare(
        model: *Model,
        document: *const Document,
        index: u32,
        node: Node,
        stack: *CompareStack,
    ) Error!void {
        assert(index < model.entry_count);
        assert(stack.count <= frame_capacity);
        assert(@backingInt(node) < document.node_count);

        const entry = &model.entries[index];

        if (entry.kind == .alias) {
            if (node != model.handles[entry.target]) return model.mismatch(index, "alias target");
            return;
        }

        model.handles[index] = node;

        try model.properties_compare(document, index, node);

        if (entry.kind == .scalar) return model.scalar_compare(document, index, node);

        const kind: document_module.Kind = if (entry.kind == .mapping) .mapping else .sequence;
        const style: document_module.CollectionStyle = if (entry.flow) .flow else .block;

        if (document.kind_of(node) != kind) return model.mismatch(index, "collection kind");

        const actual = document.style_of(node);

        const expected: document_module.Style = switch (kind) {
            .mapping => .{ .mapping = style },
            .scalar => unreachable,
            .sequence => .{ .sequence = style },
        };

        if (!std.meta.eql(actual, expected)) return model.mismatch(index, "collection style");

        const pairs = if (kind == .mapping) @divExact(entry.child_count, 2) else entry.child_count;
        if (document.count_of(node) != pairs) return model.mismatch(index, "collection count");

        const children: Children = switch (kind) {
            .mapping => .{ .entries = document.entries(node) },
            .scalar => unreachable,
            .sequence => .{ .items = document.items(node) },
        };

        stack.frames[stack.count] = .{
            .children = children,
            .cursor = index + 1,
            .key_entry = index_none,
            .node = node,
            .pair = undefined,
            .remaining = entry.child_count,
            .value_phase = false,
        };

        stack.count += 1;
    }

    fn properties_compare(
        model: *Model,
        document: *const Document,
        index: u32,
        node: Node,
    ) Error!void {
        assert(index < model.entry_count);
        assert(model.entries[index].kind != .alias);
        assert(@backingInt(node) < document.node_count);

        const entry = &model.entries[index];
        const anchor = if (entry.anchor > 0) anchor_names[entry.anchor - 1] else "";
        const tag = if (entry.tag > 0) tag_forms[entry.tag - 1].expected else "";
        const anchor_equal = std.mem.eql(u8, document.anchor_of(node), anchor);
        const tag_equal = std.mem.eql(u8, document.tag_of(node), tag);

        if (!anchor_equal) return model.mismatch(index, "anchor");
        if (!tag_equal) return model.mismatch(index, "tag");
    }

    fn scalar_compare(model: *Model, document: *const Document, index: u32, node: Node) Error!void {
        assert(index < model.entry_count);
        assert(model.entries[index].kind == .scalar);
        assert(@backingInt(node) < document.node_count);

        const entry = &model.entries[index];

        const style: ScalarStyle = switch (entry.form) {
            .double_quoted => .double_quoted,
            .empty, .plain => .plain,
            .folded => .folded,
            .literal => .literal,
            .single_quoted => .single_quoted,
        };

        if (document.kind_of(node) != .scalar) return model.mismatch(index, "scalar kind");

        const style_equal = std.meta.eql(document.style_of(node), .{ .scalar = style });
        if (!style_equal) return model.mismatch(index, "scalar style");

        if (!std.mem.eql(u8, document.text_of(node).?, model.text_of(entry))) {
            std.debug.print("expected {f}\nactual   {f}\n", .{
                std.zig.fmtString(model.text_of(entry)),
                std.zig.fmtString(document.text_of(node).?),
            });

            return model.mismatch(index, "scalar text");
        }
    }

    fn child_compare(
        model: *Model,
        document: *const Document,
        top: *CompareFrame,
        stack: *CompareStack,
    ) Error!void {
        assert(top.remaining > 0);
        assert(top.cursor < model.entry_count);

        switch (top.children) {
            .entries => |*entries| {
                if (!top.value_phase) {
                    const pair = entries.next() orelse {
                        return model.mismatch(top.cursor, "entry missing");
                    };

                    top.pair = pair;
                    top.key_entry = top.cursor;
                    top.cursor += model.entries[top.cursor].span;
                    top.value_phase = true;

                    return model.node_compare(document, top.key_entry, top.pair.key, stack);
                }

                const value = top.cursor;

                top.cursor += model.entries[value].span;
                top.value_phase = false;
                top.remaining -= 2;

                try model.member_compare(document, top);
                try model.node_compare(document, value, top.pair.value, stack);
            },
            .items => |*items| {
                const item = items.next() orelse return model.mismatch(top.cursor, "item missing");
                const index = top.cursor;

                top.cursor += model.entries[index].span;
                top.remaining -= 1;

                try model.node_compare(document, index, item, stack);
            },
        }
    }

    fn member_compare(
        model: *Model,
        document: *const Document,
        top: *const CompareFrame,
    ) Error!void {
        assert(top.key_entry < model.entry_count);
        assert(top.children == .entries);

        var key = &model.entries[top.key_entry];

        if (key.kind == .alias) key = &model.entries[key.target];
        if (key.kind != .scalar) return;

        const found = document.member(top.node, model.text_of(key)) orelse {
            return model.mismatch(top.key_entry, "member absent");
        };

        if (found != top.pair.value) return model.mismatch(top.key_entry, "member value");
    }

    fn mismatch(model: *const Model, index: u32, what: []const u8) Error {
        assert(index <= model.entry_count);
        assert(what.len > 0);

        std.debug.print("model mismatch at entry {d}: {s}\n", .{ index, what });

        return error.ModelMismatch;
    }
};

fn decimal_write(buffer: []u8, value: u32) []u8 {
    assert(buffer.len >= 10);
    assert(buffer.len <= 64);
    assert(value <= entry_count_max);

    var index = buffer.len;
    var remaining = value;

    for (0..buffer.len) |_| {
        index -= 1;
        buffer[index] = '0' + @as(u8, @intCast(remaining % 10));
        remaining /= 10;

        if (remaining == 0) break;
    }

    return buffer[index..];
}

fn leading_space_has(body: []const u8) bool {
    assert(body.len <= text_bytes_bound);
    assert(text_bytes_bound > 0);

    var lines = std.mem.splitScalar(u8, body, '\n');

    for (0..body.len + 1) |_| {
        const line = lines.next() orelse return false;
        const leading = line.len > 0 and line[0] == ' ';
        if (leading) return true;
    }

    return false;
}

fn escape_name_of(codepoint: u21) ?[]const u8 {
    assert(codepoint <= 0x10ffff);
    assert(controls.len > 0);

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
        0x20 => "\\ ",
        0x22 => "\\\"",
        0x2f => "\\/",
        0x5c => "\\\\",
        0x85 => "\\N",
        0xa0 => "\\_",
        0x2028 => "\\L",
        0x2029 => "\\P",
        else => null,
    };
}
