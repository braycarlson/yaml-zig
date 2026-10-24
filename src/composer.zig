const std = @import("std");

const attach_module = @import("attach.zig");
const document_module = @import("document.zig");
const parser_module = @import("parser.zig");
const scanner_module = @import("scanner.zig");
const storage_module = @import("storage.zig");

const assert = std.debug.assert;

const Document = document_module.Document;
const Error = document_module.Document.Error;
const Event = parser_module.Event;
const KeyProbe = storage_module.KeyProbe;
const KeySlot = storage_module.KeySlot;
const Kind = document_module.Kind;
const Mark = scanner_module.Mark;
const Storage = storage_module.Storage;

pub const frame_capacity: u32 = parser_module.state_capacity;

const index_none = storage_module.index_none;
const key_bucket_count_min = storage_module.key_bucket_count_min;
const probe_count_max = storage_module.probe_count_max;
const scan_entry_count_max = storage_module.scan_entry_count_max;
const seed_anchor: u64 = 0x9e3779b97f4a7c15;

comptime {
    assert(frame_capacity >= 2 * scanner_module.depth_max);
    assert(index_none == std.math.maxInt(u32));
}

pub const Frame = struct {
    count: u32,
    key: u32,
    mapping: bool,
    node: u32,
};

pub const State = struct {
    anchor_count: u32,
    anchor_epoch: u32,
    blanks: attach_module.Blanks,
    document_start_explicit: bool,
    frame_count: u32,
    frames: [frame_capacity]Frame,
    key_count: u32,
};

pub fn compose(document: *Document, storage: Storage, source: []const u8) Error!void {
    assert(source.len <= scanner_module.source_bytes_max);
    assert(storage.roots.len == storage.nodes.len);
    assert(std.math.isPowerOfTwo(storage.key_buckets.len));
    assert(std.math.isPowerOfTwo(storage.anchors.len));
    assert(storage.key_buckets.len >= storage.nodes.len);
    assert(storage.keys.len * 2 > storage.nodes.len);

    storage_attach(document, storage, source);
    storage.parser.init(storage.text, source);

    if (storage.comments.len > 0) {
        storage.parser.scanner.comments_keep(storage.comments);
        document.composer.blanks.clean_line_limit = 1;
    }

    if (storage.comments.len > 0) {
        try events_compose(document, true);
    } else {
        try events_compose(document, false);
    }

    assert(document.composer.frame_count == 0);

    if (storage.comments.len > 0) {
        assert(document.composer.blanks.pending == index_none);

        document.comment_count = storage.parser.scanner.comment_count;

        if (document.comment_count > 0) attach_module.attach(document);
    }
}

fn storage_attach(document: *Document, storage: Storage, source: []const u8) void {
    assert(storage.nodes.len > 0);
    assert(storage.anchors.len > 1);
    assert(source.len <= scanner_module.source_bytes_max);

    document.comment_count = 0;
    document.composer.anchor_count = 0;
    document.composer.anchor_epoch = 0;
    document.composer.blanks = .empty;
    document.composer.document_start_explicit = false;
    document.composer.frame_count = 0;
    document.composer.key_count = 0;
    document.diagnostic = parser_module.position_none;
    document.document_count = 0;
    document.key_bucket_count = 0;
    document.node_count = 0;
    document.source = source;
    document.storage = storage;

    for (storage.anchors) |*slot| slot.epoch = 0;
}

fn events_compose(document: *Document, comptime kept: bool) align(64) Error!void {
    assert(document.node_count == 0);
    assert(document.composer.frame_count == 0);
    assert(kept == (document.storage.comments.len > 0));

    const parser = document.storage.parser;
    const event_count_max = 16 * document.source.len + 16;

    for (0..event_count_max) |_| {
        const event = parser.next() catch |err| {
            document.diagnostic = parser.diagnostic;

            return err;
        };

        switch (event.*) {
            .stream_start => {},
            .stream_end => return,
            .document_start => |*start| try document_begin(document, start),
            .document_end => |*end| document_finish(document, end),
            .scalar => |*scalar| try scalar_add(document, scalar, kept),
            .alias => |*alias| try alias_add(document, alias, kept),
            .mapping_start => |*start| try collection_open(document, start, .mapping, kept),
            .sequence_start => |*start| try collection_open(document, start, .sequence, kept),
            .mapping_end, .sequence_end => collection_close(document),
        }
    }

    unreachable;
}

fn document_begin(document: *Document, start: *const Event.DocumentStart) Error!void {
    assert(document.composer.frame_count == 0);
    assert(document.document_count <= document.storage.roots.len);
    assert(start.mark.index <= document.source.len);

    if (document.document_count == document.storage.roots.len) {
        return fail(document, start.mark, error.NodesExhausted);
    }

    document.composer.anchor_count = 0;
    document.composer.anchor_epoch += 1;
    document.composer.document_start_explicit = start.explicit;
    document.storage.roots[document.document_count] = document.node_count;
}

fn document_finish(document: *Document, end: *const Event.DocumentEnd) void {
    assert(document.composer.frame_count == 0);
    assert(document.storage.roots[document.document_count] < document.node_count);
    assert(end.mark.index <= document.source.len);

    const root = document.storage.roots[document.document_count];
    const markers = &document.storage.nodes[root].markers;

    markers.end_explicit = end.explicit;
    markers.start_explicit = document.composer.document_start_explicit;

    document.document_count += 1;
}

fn node_reserve(document: *Document, mark: Mark) Error!u32 {
    assert(document.node_count <= document.storage.nodes.len);
    assert(mark.index <= document.source.len);

    if (document.node_count == document.storage.nodes.len) {
        return fail(document, mark, error.NodesExhausted);
    }

    const index = document.node_count;

    document.storage.nodes[index] = .{
        .anchor = "",
        .column = mark.column,
        .kind = .scalar,
        .line = mark.line,
        .link = .{ .count = 0 },
        .markers = .{},
        .offset = mark.index,
        .span = 1,
        .style = 0,
        .tag = "",
        .text = "",
    };

    document.node_count += 1;

    return index;
}

fn fail(document: *Document, mark: Mark, err: Error) Error {
    assert(mark.index <= document.source.len);
    assert(@errorName(err).len > 0);

    document.diagnostic = .{
        .column = mark.column + 1,
        .line = mark.line + 1,
        .offset = mark.index,
    };

    return err;
}

fn key_duplicate_fail(document: *Document, key: u32) Error {
    assert(key < document.node_count);
    assert(document.composer.frame_count > 0);

    document.diagnostic = storage_module.position_of(&document.storage.nodes[key]);

    return error.KeyDuplicate;
}

fn scalar_add(document: *Document, scalar: *const Event.Scalar, comptime kept: bool) Error!void {
    assert(scalar.text.len <= scanner_module.source_bytes_max);
    assert(document.node_count <= document.storage.nodes.len);

    const index = try node_reserve(document, scalar.mark);
    const node = &document.storage.nodes[index];

    node.anchor = scalar.anchor;
    node.style = @backingInt(scalar.style);
    node.tag = scalar.tag;
    node.text = scalar.text;

    if (scalar.anchor.len > 0) try anchor_register(document, scalar.anchor, index, scalar.mark);

    try child_attach(document, index, scalar.mark, kept);
}

fn alias_add(document: *Document, alias: *const Event.Alias, comptime kept: bool) Error!void {
    assert(alias.anchor.len > 0);
    assert(document.node_count <= document.storage.nodes.len);

    const target = try anchor_lookup(document, alias.anchor, alias.mark);

    if (document.storage.nodes[target].span == 0) {
        return fail(document, alias.mark, error.AliasRecursive);
    }

    const index = try node_reserve(document, alias.mark);
    const node = &document.storage.nodes[index];

    node.kind = .alias;
    node.link = .{ .target = target };

    try child_attach(document, index, alias.mark, kept);
}

fn collection_open(
    document: *Document,
    start: *const Event.CollectionStart,
    kind: Kind,
    comptime kept: bool,
) Error!void {
    assert(kind != .scalar);
    assert(document.composer.frame_count <= frame_capacity);

    const index = try node_reserve(document, start.mark);
    const node = &document.storage.nodes[index];

    node.anchor = start.anchor;
    node.kind = if (kind == .mapping) .mapping else .sequence;
    node.span = 0;
    node.style = @backingInt(start.style);
    node.tag = start.tag;

    if (start.anchor.len > 0) try anchor_register(document, start.anchor, index, start.mark);

    try child_attach(document, index, start.mark, kept);

    const composer = &document.composer;

    if (composer.frame_count == frame_capacity) {
        return fail(document, start.mark, error.DepthExceeded);
    }

    composer.frames[composer.frame_count] = .{
        .count = 0,
        .key = index_none,
        .mapping = kind == .mapping,
        .node = index,
    };

    composer.frame_count += 1;
}

fn collection_close(document: *Document) void {
    assert(document.composer.frame_count > 0);
    assert(document.node_count <= document.storage.nodes.len);

    const composer = &document.composer;

    composer.frame_count -= 1;

    const frame = &composer.frames[composer.frame_count];
    const node = &document.storage.nodes[frame.node];

    assert(frame.key == index_none);

    node.span = document.node_count - frame.node;
    node.link = .{ .count = frame.count };

    assert(node.span > 0);
}

fn child_attach(
    document: *Document,
    index: u32,
    mark: Mark,
    comptime kept: bool,
) align(64) Error!void {
    assert(index < document.node_count);
    assert(document.composer.frame_count <= frame_capacity);
    assert(mark.index <= document.source.len);

    if (kept) attach_module.blank_observe(document, index);

    const composer = &document.composer;
    if (composer.frame_count == 0) return;

    const frame = &composer.frames[composer.frame_count - 1];

    if (!frame.mapping) {
        frame.count += 1;

        return;
    }

    if (frame.key == index_none) {
        frame.key = index;

        return;
    }

    try key_index(document, frame, index, mark);

    frame.key = index_none;
    frame.count += 1;
}

fn key_index(
    document: *Document,
    frame: *const Frame,
    value: u32,
    mark: Mark,
) align(64) Error!void {
    assert(frame.mapping);
    assert(value < document.node_count);
    assert(mark.index <= document.source.len);

    const nodes = document.storage.nodes;

    if (frame.count == scan_entry_count_max) mapping_index(document, frame.node);

    const key = storage_module.resolved(nodes, frame.key);
    if (nodes[key].kind != .scalar) return;

    const text = nodes[key].text;

    if (frame.count < scan_entry_count_max) {
        const scan: storage_module.EntryScan = .{ .count = frame.count, .mapping = frame.node };
        const found = storage_module.entry_find(nodes, scan, text);
        if (found != null) return key_duplicate_fail(document, frame.key);
        return;
    }

    const slot: KeySlot = .{
        .hash = storage_module.hash_of(frame.node, text),
        .key = frame.key,
        .mapping = frame.node,
        .value = value,
    };

    try key_insert(document, &slot, text, mark);
}

fn mapping_index(document: *Document, mapping: u32) void {
    assert(mapping < document.node_count);
    assert(document.storage.nodes[mapping].kind == .mapping);

    const nodes = document.storage.nodes;
    var cursor = mapping + 1;

    key_index_reserve(document, scan_entry_count_max + 1);

    for (0..scan_entry_count_max) |_| {
        const key = storage_module.resolved(nodes, cursor);
        const value = cursor + nodes[cursor].span;

        if (nodes[key].kind == .scalar) {
            const slot: KeySlot = .{
                .hash = storage_module.hash_of(mapping, nodes[key].text),
                .key = cursor,
                .mapping = mapping,
                .value = value,
            };

            slot_append(document, &slot);
        }

        cursor = value + nodes[value].span;
    }
}

fn key_insert(document: *Document, slot: *const KeySlot, text: []const u8, mark: Mark) Error!void {
    assert(slot.mapping < document.node_count);
    assert(text.len <= scanner_module.source_bytes_max);
    assert(mark.index <= document.source.len);

    key_index_reserve(document, 1);

    const nodes = document.storage.nodes;
    const probe: KeyProbe = .{ .hash = slot.hash, .mapping = slot.mapping, .text = text };
    const buckets = document.storage.key_buckets;
    const mask = document.key_bucket_count - 1;
    var bucket = slot.hash & mask;

    for (0..probe_count_max) |_| {
        const entry = buckets[bucket];
        if (entry == index_none) return slot_store(document, slot, bucket);

        if (storage_module.slot_matches(nodes, &document.storage.keys[entry], &probe)) {
            return key_duplicate_fail(document, slot.key);
        }

        bucket = (bucket + 1) & mask;
    }

    return fail(document, mark, error.KeyCollision);
}

fn slot_store(document: *Document, slot: *const KeySlot, bucket: u32) void {
    assert(bucket < document.key_bucket_count);
    assert(document.storage.key_buckets[bucket] == index_none);

    const position = document.composer.key_count;

    document.storage.keys[position] = slot.*;
    document.storage.key_buckets[bucket] = position;
    document.composer.key_count += 1;

    assert(document.composer.key_count * 2 <= document.key_bucket_count);
}

fn key_index_reserve(document: *Document, extra: u32) void {
    assert(extra > 0);
    assert(document.composer.key_count + extra <= document.storage.keys.len);

    const needed = document.composer.key_count + extra;
    if (needed * 2 <= document.key_bucket_count) return;

    key_buckets_rebuild(document, needed);
}

fn key_buckets_rebuild(document: *Document, needed: u32) void {
    assert(needed > 0);
    assert(needed * 2 <= document.storage.key_buckets.len);

    const buckets = document.storage.key_buckets;
    const wanted = std.math.ceilPowerOfTwoAssert(u32, @max(key_bucket_count_min, needed * 2));
    const capacity: u32 = @intCast(buckets.len);
    const bucket_count = @min(wanted, capacity);

    @memset(buckets[0..bucket_count], index_none);

    document.key_bucket_count = bucket_count;

    for (0..document.composer.key_count) |position| slot_place(document, @intCast(position));

    assert(document.key_bucket_count >= needed * 2);
}

fn slot_append(document: *Document, slot: *const KeySlot) void {
    assert(slot.mapping < document.node_count);
    assert(document.composer.key_count < document.storage.keys.len);

    const position = document.composer.key_count;

    document.storage.keys[position] = slot.*;
    document.composer.key_count += 1;

    slot_place(document, position);

    assert(document.composer.key_count * 2 <= document.key_bucket_count);
}

fn slot_place(document: *Document, position: u32) void {
    assert(position < document.composer.key_count);
    assert(std.math.isPowerOfTwo(document.key_bucket_count));

    const buckets = document.storage.key_buckets;
    const mask = document.key_bucket_count - 1;
    var bucket = document.storage.keys[position].hash & mask;

    for (0..document.key_bucket_count) |_| {
        if (buckets[bucket] == index_none) {
            buckets[bucket] = position;

            return;
        }

        bucket = (bucket + 1) & mask;
    }

    unreachable;
}

fn anchor_register(document: *Document, name: []const u8, index: u32, mark: Mark) Error!void {
    assert(name.len > 0);
    assert(index < document.node_count);
    assert(mark.index <= document.source.len);

    const composer = &document.composer;
    const anchors = document.storage.anchors;
    const hash: u32 = @truncate(std.hash.Wyhash.hash(seed_anchor, name));
    const mask: u32 = @intCast(anchors.len - 1);
    var slot_index = hash & mask;

    for (0..anchors.len) |_| {
        const slot = &anchors[slot_index];

        if (slot.epoch != composer.anchor_epoch) {
            const anchor_count_max = @divExact(anchors.len, 2);

            if (composer.anchor_count == anchor_count_max) {
                return fail(document, mark, error.AnchorsExhausted);
            }

            slot.* = .{ .epoch = composer.anchor_epoch, .hash = hash, .name = name, .node = index };
            composer.anchor_count += 1;

            return;
        }

        if (slot.hash == hash) {
            if (std.mem.eql(u8, slot.name, name)) {
                slot.node = index;

                return;
            }
        }

        slot_index = (slot_index + 1) & mask;
    }

    unreachable;
}

fn anchor_lookup(document: *Document, name: []const u8, mark: Mark) Error!u32 {
    assert(name.len > 0);
    assert(document.node_count <= document.storage.nodes.len);
    assert(mark.index <= document.source.len);

    const composer = &document.composer;
    const anchors = document.storage.anchors;
    const hash: u32 = @truncate(std.hash.Wyhash.hash(seed_anchor, name));
    const mask: u32 = @intCast(anchors.len - 1);
    var slot_index = hash & mask;

    for (0..anchors.len) |_| {
        const slot = &anchors[slot_index];
        if (slot.epoch != composer.anchor_epoch) break;

        if (slot.hash == hash) {
            if (std.mem.eql(u8, slot.name, name)) return slot.node;
        }

        slot_index = (slot_index + 1) & mask;
    }

    return fail(document, mark, error.AliasUndefined);
}
