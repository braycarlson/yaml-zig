const std = @import("std");

const codec = @import("codec.zig");
const comment_module = @import("comment.zig");
const document_module = @import("document.zig");
const fuzz_model = @import("fuzz_model.zig");
const json_writer = @import("json_writer.zig");
const merge = @import("merge.zig");
const parser_module = @import("parser.zig");
const round_trip = @import("round_trip.zig");
const scanner_module = @import("scanner.zig");
const schema_module = @import("schema.zig");
const storage_module = @import("storage.zig");
const tree_module = @import("tree.zig");
const writer_module = @import("writer.zig");

const assert = std.debug.assert;

const Capacity = storage_module.Capacity;
const Comment = comment_module.Comment;
const Document = document_module.Document;
const DocumentNode = document_module.Node;
const Event = parser_module.Event;
const JSONOptions = json_writer.JSONOptions;
const Parser = parser_module.Parser;
const Prng = std.Random.DefaultPrng;
const ScalarStyle = parser_module.ScalarStyle;
const Schema = schema_module.Schema;
const Tree = tree_module.Tree;
const Writer = writer_module.Writer;

pub const Options = struct {
    events_max: u32,
    seed: u64,
};

const anchor_slot_count_max: u32 = 64;
const applied_records_max: u32 = 16 * 1024;
const applied_text_bytes_max: u32 = 256 * 1024;
const campaign_events_min: u32 = 20_000;
const check_records_max: u32 = 4 * 1024;
const check_text_bytes_max: u32 = 128 * 1024;
const comment_line_count_max: u32 = 4;
const comment_lines_max: u32 = 2 * 1024;
const comment_text_bytes_max: u32 = 256;
const comments_max: u32 = 256;
const content_text_bytes_max: u32 = 512;
const depth_max: u32 = scanner_module.depth_max;
const event_count_max: u32 = 4 * tree_records_max + 8;
const fragment_count_max: u32 = 4;
const json_bytes_max: u32 = 4 * 1024 * 1024;
const json_node_count_max: u32 = 4 * 1024;
const none: u32 = std.math.maxInt(u32);
const operation_count_max: u32 = 24;
const output_bytes_max: u32 = 4 * 1024 * 1024;
const path_count_max: u32 = 4;
const path_segment_bytes_max: u32 = 16;
const path_segment_count_max: u32 = 8;
const scratch_index: u32 = tree_records_max;
const span_empty: Span = .{ .length = 0, .offset = 0 };
const stream_index: u32 = 0;
const tree_records_max: u32 = 1024;
const tree_text_bytes_max: u32 = 64 * 1024;

const applied_capacity: Capacity = .{
    .anchor_count_max = 256,
    .comment_count_max = null,
    .node_count_max = applied_records_max,
    .text_bytes_max = applied_text_bytes_max,
};

const check_capacity: Capacity = .{
    .anchor_count_max = 256,
    .comment_count_max = comments_max,
    .node_count_max = check_records_max,
    .text_bytes_max = check_text_bytes_max,
};

const document_capacity: Capacity = .{
    .anchor_count_max = 256,
    .comment_count_max = null,
    .node_count_max = 8 * 1024,
    .text_bytes_max = 1024 * 1024,
};

const reparsed_capacity: Capacity = .{
    .anchor_count_max = 256,
    .comment_count_max = comments_max,
    .node_count_max = 8 * 1024,
    .text_bytes_max = 1024 * 1024,
};

const tree_capacity: Capacity = .{
    .anchor_count_max = @divExact(anchor_slot_count_max, 2),
    .comment_count_max = comments_max,
    .node_count_max = tree_records_max,
    .text_bytes_max = tree_text_bytes_max,
};

comptime {
    assert(tree_records_max > depth_max + 2);
    assert(std.math.isPowerOfTwo(anchor_slot_count_max));
    assert(event_count_max > 4 * tree_records_max);
    assert(check_records_max >= tree_records_max);
    assert(content_text_bytes_max > 64 * (fragment_count_max + 1));

    for (fragments) |fragment| assert(fragment.len <= 64);
    for (sequences_invalid) |sequence| assert(sequence.len <= 64);
}

const AppliedStorage = Tree.StorageType(applied_capacity);
const CheckStorage = Tree.StorageType(check_capacity);
const FuzzDocument = document_module.DocumentType(document_capacity);
const ReparsedDocument = document_module.DocumentType(reparsed_capacity);
const TreeStorage = Tree.StorageType(tree_capacity);

const comment_suffixes = [_][]const u8{
    "",
    " a: b",
    " - [x], {y}",
    " \u{fc}n\u{ef}",
    "  # twice",
};

const comments_invalid = [_]struct { placement: Comment.Placement, text: []const u8 }{
    .{ .placement = .line, .text = "# a\n# b" },
    .{ .placement = .line, .text = "\n" },
    .{ .placement = .head, .text = "a" },
    .{ .placement = .foot, .text = "# a " },
    .{ .placement = .head, .text = "# \x07" },
    .{ .placement = .foot, .text = "#\r" },
    .{ .placement = .head, .text = "# \xff" },
    .{ .placement = .foot, .text = "# \xef\xbb\xbf" },
};

const anchors_invalid = [_][]const u8{
    "a b",
    "a\tb",
    "a,b",
    "x[",
    "x]",
    "{x",
    "x}",
    "a\nb",
    "\x01",
    "\x7f",
    "\u{9f}",
    "\u{feff}",
    "\u{fffe}",
    "\xff",
    "a\xc3",
};

const anchors_valid = [_][]const u8{
    "a",
    "b",
    "a0",
    "a1",
    "base",
    "m0",
    "x.y",
    "a:b",
    "#h",
    "q'",
    "\u{e9}",
    "\u{85}",
    "\u{2028}",
    "\u{1f600}",
};

const floats = [_]f64{
    0.0,
    -0.0,
    1.0,
    0.1,
    1000.0,
    1.5e9,
    1e300,
    5e-324,
    std.math.floatMax(f64),
    -std.math.floatMin(f64),
    std.math.inf(f64),
    -std.math.inf(f64),
    std.math.nan(f64),
};

const fragments = [_][]const u8{
    "a",
    "word",
    "x y",
    "the quick brown fox jumps over the lazy dog",
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
    " ",
    "\t",
    "\n",
    "\n\n",
    "- ",
    ": ",
    " #",
    "---",
    "...",
    "null",
    "true",
    "1",
    "-.inf",
    "0x1F",
    "yes",
    "~",
    "<<",
    "\x01",
    "\x7f",
    "\r",
    "\\",
    "\u{85}",
    "\u{2028}",
    "\u{feff}",
    "\u{fffe}",
    "\u{a0}",
    "\u{e9}",
    "\u{1f600}",
};

const integers = [_]i64{
    0,
    1,
    -1,
    42,
    std.math.maxInt(i64),
    std.math.minInt(i64),
};

const keys = [_][]const u8{
    "a",
    "b",
    "key",
    "",
    "<<",
    "a: b",
    "\u{e9}",
    "-",
    "x\ny",
    "true",
    "1",
    "null",
    "image",
    "k0",
    "x",
    "\x01",
    "\xff",
};

const sequences_invalid = [_][]const u8{
    "\xff",
    "\xc3",
    "\xc0\x80",
    "\xed\xa0\x80",
    "\xe2\x80",
};

const tags = [_][]const u8{
    "!",
    "!local",
    "!e!x",
    "!a%b",
    "!{}",
    "tag:yaml.org,2002:str",
    "tag:yaml.org,2002:int",
    "tag:yaml.org,2002:a,b",
    "tag:yaml.org,2002:[\u{e9}]",
    "tag:yaml.org,2002:",
    "tag:example.com,2000:v",
    "x y>",
    "!\xff",
};

const deep_text = deep: {
    var text: [2 * depth_max + 2]u8 = undefined;

    @memset(text[0..depth_max], '[');
    text[depth_max] = 'x';

    @memset(text[depth_max + 1 ..][0..depth_max], ']');
    text[2 * depth_max + 1] = '\n';

    const result = text;

    break :deep &result;
};

const merge_text = merges: {
    @setEvalBranchQuota(200_000);

    const count = merge.source_count_max + 1;
    const split = 40;

    var all: []const u8 = "";
    var fits: []const u8 = "";
    var inner: []const u8 = "";
    var outer: []const u8 = "";

    for (0..count) |index| {
        const source = std.fmt.comptimePrint("{{k{d}: {d}}}", .{ index, index });
        const separator = if (index == 0) "" else ", ";

        all = all ++ separator ++ source;

        if (index < count - 1) fits = fits ++ separator ++ source;

        if (index < split) {
            outer = outer ++ separator ++ source;
        } else {
            inner = inner ++ (if (index == split) "" else ", ") ++ source;
        }
    }

    const text = "all: {<<: [" ++ all ++ "]}\n" ++
        "fits: {<<: [" ++ fits ++ "]}\n" ++
        "outer: {<<: [" ++ outer ++ "], inner: {<<: [" ++ inner ++ "]}}\n";

    break :merges text;
};

const corpus = [_][]const u8{
    \\base: &base {image: base, restart: always, ports: [80, 443]}
    \\extra: &extra {image: nginx, replicas: 2}
    \\web:
    \\  <<: [*extra, *base]
    \\  restart: never
    \\worker: {<<: *base, nested: {<<: *extra, depth: 1}}
    \\quoted: {"<<": *base}
    \\tagged: {!!merge <<: {a: 1}, b: 2}
    \\
    ,
    \\shared: &shared {a: 1}
    \\broken: {<<: [*shared, 2], b: 3}
    \\scalar: {<<: text}
    \\
    ,
    \\- &a {x: 1, y: &n 2}
    \\- {<<: *a, z: *n}
    \\- {p: 0, <<: [{p: &q 1, s: 2}], r: *q}
    \\- {<<: [], e: 1}
    \\
    ,
    \\chain: &c1 {a: 1}
    \\next: &c2 {<<: *c1, b: 2}
    \\last: {<<: *c2, c: 3}
    \\
    ,
    \\first: &d {k: 1}
    \\redefined: {v: *d, <<: &d {k: 2}, w: *d}
    \\
    ,
    \\%YAML 1.2
    \\--- !!map
    \\? &k [a, b]
    \\: *k
    \\...
    \\--- |
    \\  literal text
    \\--- &top
    \\- plain
    \\- 'single'
    \\- "double\ttab"
    \\- >
    \\  folded
    \\- !local {x: [1, 2], ? complex : value}
    \\...
    \\
    ,
    \\---
    \\empty:
    \\nested:
    \\  - - inner
    \\    - &i {k: v}
    \\  - *i
    \\...
    \\--- plain root
    \\...
    \\
    ,
    merge_text,
    deep_text,
};

const Cell = struct {
    container: u32,
    position: u32,
};

const Child = struct {
    mode: Mode,
    source: u32,
};

const Claim = struct {
    document: u32,
    excluded: u32,
    name: []const u8,
};

const ContentKind = enum {
    alias,
    boolean,
    copy,
    float,
    integer,
    mapping,
    null_value,
    scalar,
    sequence,
    string,
};

const Counter = enum {
    alias_expanded,
    alias_kept,
    applied_compared,
    applied_skipped,
    comment_cleared,
    comment_compared,
    comment_foot,
    comment_head,
    comment_line,
    copy_accepted,
    copy_merged,
    copy_replaced,
    dropped_checked,
    fixpoint_compared,
    json_compared,
    json_refused,
    json_skipped,
    path_walked,
    remove_entry,
    remove_root,
    set_existing,
    sink_refused,
    write_compared,
};

const Fill = struct {
    excluded: u32,
    target: u32,
};

const Filter = enum {
    anchored,
    any,
    mapping,
    sequence,
    value,
};

const Generated = struct {
    anchor_valid: bool,
    content: Tree.Content,
};

const Home = struct {
    index: u32,
    source: u32,
};

const JSONPair = struct {
    left: JSONResult,
    right: JSONResult,
};

const JSONResult = union(enum) {
    failure: JSONOptions.Error,
    written: []const u8,
};

const Label = struct {
    text: []const u8,
    valid: bool,
};

const Link = struct {
    parent: u32,
    sibling: Sibling,
};

const Mode = enum {
    expanded,
    raw,
};

const Model = struct {
    anchor_count_max: u32,
    comment_capacity: u32,
    comment_line_count: u32,
    comment_lines: [comment_lines_max]ModelLine,
    ends: [tree_records_max + 1]u32,
    levels: [tree_records_max + 1]u32,
    node_capacity: u32,
    node_count: u32,
    node_next: u32,
    nodes: [tree_records_max + 1]ModelNode,
    order_count: u32,
    orders: [tree_records_max + 1]u32,
    pool: [tree_text_bytes_max]u8,
    pool_capacity: u32,
    pool_count: u32,
    pool_next: u32,
};

const ModelComments = struct {
    count: u32,
    first: u32,

    const empty: ModelComments = .{ .count = 0, .first = 0 };
};

const ModelLine = struct {
    blank: bool,
    text: Span,
};

const ModelKind = enum {
    alias,
    mapping,
    scalar,
    sequence,
    stream,
};

const ModelNode = struct {
    anchor: Span,
    blank: bool,
    comments: [3]ModelComments,
    count: u32,
    detached: bool,
    end_explicit: bool,
    first: u32,
    home: u32,
    key: bool,
    kind: ModelKind,
    last: u32,
    next: u32,
    parent: u32,
    previous: u32,
    start_explicit: bool,
    style: u8,
    tag: Span,
    text: Span,
};

const Operation = enum {
    append,
    comment_set,
    insert,
    remove,
    replace,
    root_append,
    set,
};

const Piece = struct {
    anchor: []const u8,
    anchor_valid: bool,
    home: u32,
    kind: ModelKind,
    style: u8,
    tag: []const u8,
    text: []const u8,
};

const Plan = struct {
    key: u32,
    refusal: Refusal,
    value: u32,
};

const Preorder = struct {
    cursor: u32,
    root: u32,
};

const Refusal = enum {
    accepted,
    alias_invalid,
    anchor_duplicate,
    anchor_referenced,
    anchors_exhausted,
    comments_exhausted,
    depth_exceeded,
    merge_invalid,
    merges_exceeded,
    nodes_exhausted,
    text_exhausted,
    text_invalid,
};

const Segment = struct {
    first: u32,
    last: u32,
};

const Sibling = union(enum) {
    at: u32,
    before: u32,
    end,
};

const Simulation = struct {
    anchor_count: u32,
    copy: *const Tree.Content.Copy,
    depth: u32,
    document: u32,
    excluded: u32,
    frames: [depth_max]SimulationFrame,
    home_count: u32,
    homes: [anchor_slot_count_max]Home,
    level: u32,
    range_end: u32,
    range_first: u32,
    sources: merge.StackType(Document),
    target: u32,
};

const SimulationFrame = struct {
    container: u32,
    cursor: u32,
    end: u32,
    entries: merge.EntriesType(Document),
    list: []const DocumentNode,
    merged: bool,
    mode: Mode,
    pending: Child,
};

const Slot = struct {
    document: u32,
    level: u32,
    parent: u32,
    sibling: Sibling,
};

const Span = struct {
    length: u32,
    offset: u32,
};

const State = struct {
    applied: Tree,
    applied_refusals: std.EnumArray(Refusal, u32),
    applied_storage: AppliedStorage,
    check: Tree,
    check_storage: CheckStorage,
    comment_serial: u32,
    comment_text: [comment_text_bytes_max]u8,
    comment_texts: [comments_max][]const u8,
    content_text: [content_text_bytes_max]u8,
    counters: std.EnumArray(Counter, u32),
    event_index: u32,
    events: [event_count_max]Event,
    generator: fuzz_model.Model,
    json_left: [json_bytes_max]u8,
    json_right: [json_bytes_max]u8,
    model: Model,
    operations: std.EnumArray(Operation, u32),
    output: [output_bytes_max]u8,
    output_again: [output_bytes_max]u8,
    output_kept: [output_bytes_max]u8,
    parser: Parser,
    parser_text: [output_bytes_max]u8,
    path_texts: [path_segment_count_max][path_segment_bytes_max]u8,
    prng: Prng,
    refusals: std.EnumArray(Refusal, u32),
    reparsed: ReparsedDocument,
    simulation: Simulation,
    sources: [2]FuzzDocument,
    tree: Tree,
    tree_storage: TreeStorage,
};

const Step = struct {
    next: u32,
    text: []const u8,
};

pub fn main(gpa: std.mem.Allocator, options: Options) !void {
    assert(options.events_max > 0);
    assert(corpus.len > 0);

    const state = try gpa.create(State);
    defer gpa.destroy(state);

    std.debug.print("fuzz tree: seed={d} events_max={d}\n", .{ options.seed, options.events_max });

    state.applied_refusals = .initFill(0);
    state.comment_serial = 0;
    state.counters = .initFill(0);
    state.event_index = 0;
    state.operations = .initFill(0);
    state.prng = .init(options.seed);
    state.refusals = .initFill(0);

    try corpus_check(state);

    for (0..options.events_max) |index| {
        state.event_index = @intCast(index);

        try event_run(state);
    }

    summary_print(state);

    try summary_check(state, options.events_max);

    std.debug.print("fuzz tree: passed\n", .{});
}

fn corpus_check(state: *State) !void {
    assert(corpus.len > 0);
    assert(state.sources.len == 2);

    for (corpus) |text| try source_parse(&state.sources[1], text);
}

fn source_parse(source: *FuzzDocument, text: []const u8) !void {
    assert(text.len <= fuzz_model.source_bytes_max);
    assert(source.storage.nodes.len == document_capacity.node_count_max);

    source.parse(text, .{ .schema = .core }) catch |err| {
        std.debug.print("fuzz tree: a source was rejected with {t}\n", .{err});
        std.debug.print("--- source ---\n{f}\n--- end ---\n", .{std.zig.fmtString(text)});

        return err;
    };
}

fn event_run(state: *State) !void {
    assert(state.sources.len == 2);
    assert(state.model.nodes.len == tree_records_max + 1);

    tree_prepare(state);

    try sources_prepare(state);

    const operation_count = 1 + below(state, operation_count_max);
    const write_middle = below(state, 2 * operation_count);

    for (0..operation_count) |index| {
        try operation_run(state);

        if (index == write_middle) try write_check(state);
    }

    try write_check(state);
    try applied_check(state);
}

fn below(state: *State, bound: u32) u32 {
    assert(bound > 0);
    assert(state.model.nodes.len == tree_records_max + 1);

    const result = state.prng.random().uintLessThan(u32, bound);

    assert(result < bound);

    return result;
}

fn chance(state: *State, denominator: u32) bool {
    assert(denominator > 0);
    assert(denominator <= 1024);

    return below(state, denominator) == 0;
}

fn tree_prepare(state: *State) void {
    assert(state.tree_storage.records.len == tree_records_max);
    assert(state.tree_storage.anchors.len == anchor_slot_count_max);

    const schemas = [_]Schema{ .core, .json, .v1_1 };
    const node_count_max = node_capacity_choose(state);
    const text_bytes_max = text_capacity_choose(state);
    const shift: u5 = @intCast(below(state, 6));
    const slot_count = @as(u32, 2) << shift;
    const schema = schemas[below(state, schemas.len)];
    const comment_count_max = comment_capacity_choose(state);

    state.tree.init(.{
        .anchors = state.tree_storage.anchors[0..slot_count],
        .comments = state.tree_storage.comments[0..comment_count_max],
        .records = state.tree_storage.records[0..node_count_max],
        .text = state.tree_storage.text[0..text_bytes_max],
    }, .{ .schema = schema });

    model_reset(&state.model, .{
        .anchor_count_max = @divExact(slot_count, 2),
        .comment_count_max = comment_count_max,
        .node_count_max = node_count_max,
        .text_bytes_max = text_bytes_max,
    });
}

fn comment_capacity_choose(state: *State) u32 {
    assert(comments_max > 8);
    assert(state.tree_storage.comments.len == comments_max);

    const result = switch (below(state, 4)) {
        0 => below(state, 8),
        else => comments_max,
    };

    assert(result <= comments_max);

    return result;
}

fn node_capacity_choose(state: *State) u32 {
    assert(tree_records_max > depth_max + 2);
    assert(state.tree_storage.records.len == tree_records_max);

    const result = switch (below(state, 4)) {
        0 => 2 + below(state, 16),
        1 => 16 + below(state, 256),
        else => tree_records_max,
    };

    assert(result >= 2);
    assert(result <= tree_records_max);

    return result;
}

fn text_capacity_choose(state: *State) u32 {
    assert(tree_text_bytes_max > 4096);
    assert(state.tree_storage.text.len == tree_text_bytes_max);

    const result = switch (below(state, 4)) {
        0 => below(state, 64),
        1 => below(state, 4096),
        else => tree_text_bytes_max,
    };

    assert(result <= tree_text_bytes_max);

    return result;
}

fn model_reset(model: *Model, capacity: Capacity) void {
    assert(capacity.node_count_max <= tree_records_max);
    assert(capacity.text_bytes_max <= tree_text_bytes_max);
    assert(capacity.anchor_count_max > 0);

    model.anchor_count_max = capacity.anchor_count_max;
    model.comment_capacity = capacity.comment_count_max orelse 0;
    model.comment_line_count = 0;
    model.node_capacity = capacity.node_count_max;
    model.node_count = 1;
    model.node_next = 1;
    model.pool_capacity = capacity.text_bytes_max;
    model.pool_count = 0;
    model.pool_next = 0;
    model.nodes[stream_index] = node_blank(.stream, none);
}

fn node_blank(kind: ModelKind, parent: u32) ModelNode {
    assert(parent != scratch_index);
    assert(kind != .stream or parent == none);

    return .{
        .anchor = span_empty,
        .blank = false,
        .comments = .{ ModelComments.empty, ModelComments.empty, ModelComments.empty },
        .count = 0,
        .detached = false,
        .end_explicit = false,
        .first = none,
        .home = none,
        .key = false,
        .kind = kind,
        .last = none,
        .next = none,
        .parent = parent,
        .previous = none,
        .start_explicit = false,
        .style = 0,
        .tag = span_empty,
        .text = span_empty,
    };
}

fn sources_prepare(state: *State) !void {
    assert(state.sources.len == 2);
    assert(corpus.len > 0);

    var prng: Prng = .init(state.prng.random().int(u64));

    const generated = try state.generator.generate(&prng);

    try source_parse(&state.sources[0], generated);
    try source_parse(&state.sources[1], corpus[below(state, corpus.len)]);
}

fn operation_run(state: *State) !void {
    assert(state.model.node_count == state.tree.node_count);
    assert(state.model.pool_count == state.tree.text_count);

    const operation: Operation = switch (below(state, 24)) {
        0...2 => .root_append,
        3...7 => .set,
        8...10 => .append,
        11, 12 => .insert,
        13...16 => .replace,
        17...19 => .remove,
        else => .comment_set,
    };

    orders_compute(&state.model);

    state.model.node_next = state.model.node_count;
    state.model.pool_next = state.model.pool_count;

    switch (operation) {
        .append => try sequence_run(state, .append),
        .comment_set => try comment_run(state),
        .insert => try sequence_run(state, .insert),
        .remove => try remove_run(state),
        .replace => try replace_run(state),
        .root_append => try root_append_run(state),
        .set => try set_run(state),
    }

    tree_module.audit(&state.tree);

    try model_compare(state);
}

fn orders_compute(model: *Model) void {
    assert(model.node_count <= tree_records_max);
    assert(model.nodes[stream_index].kind == .stream);

    var cursor = model.nodes[stream_index].first;

    model.levels[stream_index] = 0;
    model.order_count = 0;

    for (0..2 * model.node_count + 2) |_| {
        if (cursor == none) break;

        const node = &model.nodes[cursor];
        const container: u32 = @intFromBool(container_is(node.kind));

        model.orders[cursor] = model.order_count;
        model.levels[cursor] = model.levels[node.parent] + container;
        model.order_count += 1;

        if (node.first == none) {
            cursor = order_climb(model, cursor);
        } else {
            cursor = node.first;
        }
    }

    assert(cursor == none);
}

fn order_climb(model: *Model, start: u32) u32 {
    assert(start != stream_index);
    assert(model.order_count > 0);

    var cursor = start;

    for (0..depth_max + 4) |_| {
        const node = &model.nodes[cursor];

        model.ends[cursor] = model.order_count;

        if (node.next != none) return node.next;
        if (node.parent == stream_index) return none;

        cursor = node.parent;
    }

    unreachable;
}

fn container_is(kind: ModelKind) bool {
    assert(@typeInfo(ModelKind).@"enum".field_names.len == 5);
    assert(@backingInt(kind) <= @backingInt(ModelKind.stream));

    return switch (kind) {
        .alias, .scalar => false,
        .mapping, .sequence, .stream => true,
    };
}

fn root_append_run(state: *State) !void {
    assert(state.model.node_next == state.model.node_count);
    assert(state.model.nodes[stream_index].kind == .stream);

    var generated: Generated = undefined;

    content_generate(state, &generated);

    const slot: Slot = .{
        .document = state.model.node_count,
        .level = 0,
        .parent = stream_index,
        .sibling = .end,
    };

    const plan = create_prepare(state, &generated, &slot, null);

    const handle = state.tree.root_append(generated.content) catch |err| {
        return refusal_check(state, plan.refusal, err, copy_of(&generated.content));
    };

    try acceptance_check(state, &plan, @backingInt(handle));

    create_commit(&state.model, &plan, &slot);
    accepted_count(state, .root_append, &generated);

    try value_check(state, plan.value, &generated);
}

fn set_run(state: *State) !void {
    assert(state.model.node_next == state.model.node_count);
    assert(keys.len > 0);

    const container = node_pick(state, .mapping) orelse return root_append_run(state);
    const key = keys[below(state, keys.len)];

    var generated: Generated = undefined;

    content_generate(state, &generated);

    const model = &state.model;
    const mapping = resolved_of(model, container);
    const valid = std.unicode.utf8ValidateSlice(key);
    const existing = if (valid) member_of(model, mapping, key) else none;

    const slot: Slot = .{
        .document = document_of(model, mapping),
        .level = model.levels[mapping],
        .parent = mapping,
        .sibling = .end,
    };

    const plan = set_plan(state, &generated, &slot, key, existing);
    const target: Tree.Node = @fromBackingInt(container);

    const handle = state.tree.set(target, key, generated.content) catch |err| {
        return refusal_check(state, plan.refusal, err, copy_of(&generated.content));
    };

    try acceptance_check(state, &plan, @backingInt(handle));

    if (existing == none) {
        create_commit(model, &plan, &slot);
    } else {
        replace_commit(model, existing);
        state.counters.getPtr(.set_existing).* += 1;
    }

    accepted_count(state, .set, &generated);

    try value_check(state, plan.value, &generated);
}

fn set_plan(
    state: *State,
    generated: *const Generated,
    slot: *const Slot,
    key: []const u8,
    existing: u32,
) Plan {
    assert(key.len <= tree_text_bytes_max);
    assert(existing != stream_index);

    if (!std.unicode.utf8ValidateSlice(key)) {
        return .{ .key = none, .refusal = .text_invalid, .value = none };
    }

    if (existing != none) return replace_plan(state, generated, existing);
    return create_prepare(state, generated, slot, key);
}

fn sequence_run(state: *State, operation: Operation) !void {
    assert(state.model.node_next == state.model.node_count);
    assert(state.model.pool_next == state.model.pool_count);

    const container = sequence_pick(state) orelse return root_append_run(state);
    const model = &state.model;
    const sequence = resolved_of(model, container);
    const count = model.nodes[sequence].count;
    const position = if (operation == .insert) below(state, count + 1) else count;

    var generated: Generated = undefined;

    content_generate(state, &generated);

    const sibling: Sibling = if (position == count) .end else .{
        .before = child_at(model, .{ .container = sequence, .position = position }),
    };

    const slot: Slot = .{
        .document = document_of(model, sequence),
        .level = model.levels[sequence],
        .parent = sequence,
        .sibling = sibling,
    };

    const plan = create_prepare(state, &generated, &slot, null);
    const cell: Cell = .{ .container = container, .position = position };

    const handle = sequence_call(state, operation, cell, &generated) catch |err| {
        return refusal_check(state, plan.refusal, err, copy_of(&generated.content));
    };

    try acceptance_check(state, &plan, @backingInt(handle));

    create_commit(model, &plan, &slot);
    accepted_count(state, operation, &generated);

    try position_check(state, cell, handle);
    try value_check(state, plan.value, &generated);
}

fn sequence_call(
    state: *State,
    operation: Operation,
    cell: Cell,
    generated: *const Generated,
) error{
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
    assert(cell.container < state.model.node_count);
    assert(cell.position <= state.tree.count_of(@fromBackingInt(cell.container)));

    const sequence: Tree.Node = @fromBackingInt(cell.container);
    if (operation == .append) return try state.tree.append(sequence, generated.content);
    return try state.tree.insert(sequence, cell.position, generated.content);
}

fn position_check(state: *State, cell: Cell, handle: Tree.Node) !void {
    assert(cell.container < state.model.node_count);
    assert(@backingInt(handle) < state.tree.node_count);

    const sequence: Tree.Node = @fromBackingInt(cell.container);

    const found = state.tree.item(sequence, cell.position) orelse {
        return mismatch(state, "the new item is not at its position", cell.container);
    };

    if (found != handle) {
        return mismatch(state, "another item is at the new position", cell.container);
    }
}

fn replace_run(state: *State) !void {
    assert(state.model.node_next == state.model.node_count);
    assert(state.model.pool_next == state.model.pool_count);

    const index = node_pick(state, .value) orelse return root_append_run(state);

    var generated: Generated = undefined;

    content_generate(state, &generated);

    const plan = replace_plan(state, &generated, index);
    const target: Tree.Node = @fromBackingInt(index);

    state.tree.replace(target, generated.content) catch |err| {
        return refusal_check(state, plan.refusal, err, copy_of(&generated.content));
    };

    try acceptance_check(state, &plan, index);

    replace_commit(&state.model, index);
    accepted_count(state, .replace, &generated);

    if (generated.content == .copy) state.counters.getPtr(.copy_replaced).* += 1;

    try value_check(state, index, &generated);
}

fn replace_plan(state: *State, generated: *const Generated, index: u32) Plan {
    assert(index > stream_index);
    assert(index < state.model.node_count);

    const model = &state.model;
    const node = &model.nodes[index];

    assert(!node.key);
    assert(!node.detached);

    if (referenced(model, .{ .first = index, .last = index })) {
        return .{ .key = none, .refusal = .anchor_referenced, .value = index };
    }

    const slot: Slot = .{
        .document = document_of(model, index),
        .level = model.levels[node.parent],
        .parent = node.parent,
        .sibling = .{ .at = index },
    };

    const refusal = switch (generated.content) {
        .copy => |*copy| copy_replace_prepare(state, copy, &slot, index),
        .alias,
        .boolean,
        .float,
        .integer,
        .mapping,
        .null_value,
        .scalar,
        .sequence,
        .string,
        => piece_replace_prepare(state, generated, &slot, index),
    };

    return .{ .key = none, .refusal = refusal, .value = index };
}

fn remove_run(state: *State) !void {
    assert(state.model.node_next == state.model.node_count);
    assert(state.model.pool_next == state.model.pool_count);

    const index = node_pick(state, .any) orelse return root_append_run(state);
    const model = &state.model;
    const segment = segment_of(model, index);
    const expected: Refusal = if (referenced(model, segment)) .anchor_referenced else .accepted;

    state.tree.remove(@fromBackingInt(index)) catch |err| {
        return refusal_check(state, expected, err, null);
    };

    try acceptance_check(state, &.{ .key = none, .refusal = expected, .value = index }, index);

    child_unlink(model, segment.first);
    subtree_detach(model, segment.first);

    if (segment.last != segment.first) {
        child_unlink(model, segment.last);
        subtree_detach(model, segment.last);
    }

    const parent = model.nodes[index].parent;

    if (parent == stream_index) state.counters.getPtr(.remove_root).* += 1;
    if (model.nodes[parent].kind == .mapping) state.counters.getPtr(.remove_entry).* += 1;

    state.operations.getPtr(.remove).* += 1;
}

fn comment_run(state: *State) !void {
    assert(state.model.node_next == state.model.node_count);
    assert(state.model.pool_next == state.model.pool_count);

    const index = node_pick(state, .any) orelse return root_append_run(state);
    const placements = [_]Comment.Placement{ .foot, .head, .line };
    var placement = placements[below(state, placements.len)];
    var text: []const u8 = "";
    var expected: Refusal = .accepted;

    if (chance(state, 8)) {
        const invalid = comments_invalid[below(state, comments_invalid.len)];

        placement = invalid.placement;
        text = invalid.text;
        expected = .text_invalid;
    } else if (!chance(state, 8)) {
        text = try comment_text_generate(state, placement);
    }

    if (expected == .accepted) expected = comment_refusal(&state.model, index, placement, text);

    state.tree.comment_set(@fromBackingInt(index), placement, text) catch |err| {
        return refusal_check(state, expected, err, null);
    };

    try acceptance_check(state, &.{ .key = none, .refusal = expected, .value = index }, index);

    comment_commit(&state.model, index, placement, text);

    const counter: Counter = if (text.len == 0) .comment_cleared else switch (placement) {
        .foot => .comment_foot,
        .head => .comment_head,
        .line => .comment_line,
    };

    state.counters.getPtr(counter).* += 1;
    state.operations.getPtr(.comment_set).* += 1;
}

fn comment_text_generate(
    state: *State,
    placement: Comment.Placement,
) std.Io.Writer.Error![]const u8 {
    assert(@backingInt(placement) <= 2);
    assert(comment_text_bytes_max > comment_line_count_max * 48);

    const count = if (placement == .line) 1 else 1 + below(state, comment_line_count_max);
    var sink: std.Io.Writer = .fixed(&state.comment_text);

    for (0..count) |index| {
        const blank = placement != .line and chance(state, 4);

        if (index > 0) try sink.writeByte('\n');
        if (blank) try sink.writeByte('\n');

        const suffix = comment_suffixes[below(state, comment_suffixes.len)];

        try sink.print("# n{d}{s}", .{ state.comment_serial, suffix });
        state.comment_serial +%= 1;
    }

    const tail_blank = placement != .line and chance(state, 8);

    if (tail_blank) try sink.writeByte('\n');

    return sink.buffered();
}

fn comment_refusal(
    model: *const Model,
    index: u32,
    placement: Comment.Placement,
    text: []const u8,
) Refusal {
    assert(@backingInt(placement) <= 2);
    assert(text.len <= comment_text_bytes_max);
    assert(index > stream_index);
    assert(!model.nodes[index].detached);

    var slots: u32 = 0;
    var bytes: u32 = 0;

    if (text.len > 0) {
        var lines = std.mem.splitScalar(u8, text, '\n');
        var last: []const u8 = "";

        for (0..text.len + 1) |_| {
            const line = lines.next() orelse break;

            last = line;
            slots += @intFromBool(line.len > 0);
            bytes += @intCast(line.len);
        }

        const foot_tail = last.len == 0 and placement == .foot;

        if (foot_tail) slots += 1;
    }

    const old = model.nodes[index].comments[comment_module.rank_of(placement)].count;
    const kept = comment_live_count(model) - old;
    if (slots > model.comment_capacity - kept) return .comments_exhausted;
    if (bytes > model.pool_capacity - model.pool_count) return .text_exhausted;
    return .accepted;
}

fn comment_live_count(model: *const Model) u32 {
    assert(model.node_count <= tree_records_max);
    assert(model.comment_line_count <= comment_lines_max);

    var result: u32 = 0;

    for (model.nodes[1..model.node_count]) |*node| {
        if (node.detached) continue;

        for (node.comments) |comments| result += comments.count;
    }

    return result;
}

fn comment_commit(model: *Model, index: u32, placement: Comment.Placement, text: []const u8) void {
    assert(@backingInt(placement) <= 2);
    assert(text.len <= comment_text_bytes_max);
    assert(index > stream_index);
    assert(model.comment_line_count + comment_line_count_max + 1 <= comment_lines_max);

    const node = &model.nodes[index];
    const first = model.comment_line_count;

    if (text.len > 0) {
        var lines = std.mem.splitScalar(u8, text, '\n');
        var blank = false;
        var last: []const u8 = "";

        for (0..text.len + 1) |_| {
            const line = lines.next() orelse break;

            last = line;

            if (line.len == 0) {
                blank = true;

                continue;
            }

            model.comment_lines[model.comment_line_count] = .{
                .blank = blank,
                .text = pool_keep(model, line),
            };

            model.comment_line_count += 1;
            blank = false;
        }

        const foot_tail = last.len == 0 and placement == .foot;

        if (foot_tail) {
            model.comment_lines[model.comment_line_count] = .{ .blank = false, .text = span_empty };
            model.comment_line_count += 1;
        }

        if (placement == .head) node.blank = last.len == 0;
    }

    node.comments[comment_module.rank_of(placement)] = .{
        .count = model.comment_line_count - first,
        .first = first,
    };

    model.pool_count = model.pool_next;
}

fn comments_expected(model: *const Model, index: u32, buffer: []Comment) []Comment {
    assert(index > stream_index);
    assert(buffer.len >= 2 * 3 * (comment_line_count_max + 1));

    const node = &model.nodes[index];
    const placements = [3]Comment.Placement{ .head, .line, .foot };
    var count: u32 = 0;

    for (node.comments, placements) |comments, placement| {
        for (model.comment_lines[comments.first..][0..comments.count]) |line| {
            const text = span_text(model, line.text);
            const blank_due = line.blank and text.len > 0;

            if (blank_due) {
                buffer[count] = .{ .placement = placement, .text = "" };
                count += 1;
            }

            buffer[count] = .{ .placement = placement, .text = text };
            count += 1;
        }

        const head_blank = placement == .head and node.blank;

        if (head_blank) {
            buffer[count] = .{ .placement = .head, .text = "" };
            count += 1;
        }
    }

    return buffer[0..count];
}

fn comments_compare(state: *State, index: u32) !void {
    assert(index > stream_index);
    assert(!state.model.nodes[index].detached);

    var buffer: [2 * 3 * (comment_line_count_max + 1)]Comment = undefined;
    const expected = comments_expected(&state.model, index, &buffer);
    var comments = state.tree.comments(@fromBackingInt(index));

    for (expected) |wanted| {
        const comment = comments.next() orelse
            return mismatch(state, "a comment is missing", index);

        if (comment.placement != wanted.placement) {
            return mismatch(state, "the comment placements differ", index);
        }

        if (!std.mem.eql(u8, comment.text, wanted.text)) {
            return mismatch(state, "the comment texts differ", index);
        }
    }

    if (comments.next() != null) return mismatch(state, "the tree holds an extra comment", index);
}

fn segment_of(model: *const Model, index: u32) Segment {
    assert(index > stream_index);
    assert(index < model.node_count);

    const node = &model.nodes[index];
    if (model.nodes[node.parent].kind != .mapping) return .{ .first = index, .last = index };
    if (node.key) return .{ .first = index, .last = node.next };
    return .{ .first = node.previous, .last = index };
}

fn refusal_check(
    state: *State,
    expected: Refusal,
    err: Tree.EditError,
    copy: ?*const Tree.Content.Copy,
) !void {
    assert(@errorName(err).len > 0);
    assert(state.model.node_count == state.tree.node_count);
    if (copy) |source| assert(@backingInt(source.node) < source.document.node_count);

    const actual = refusal_of(err);

    state.refusals.getPtr(actual).* += 1;

    try diagnostic_check(state, copy);

    if (expected == actual) return;

    std.debug.print("fuzz tree: the model expected {t}, the tree refused with {t}\n", .{
        expected,
        actual,
    });

    return mismatch(state, "the refusals differ", stream_index);
}

fn copy_of(content: *const Tree.Content) ?*const Tree.Content.Copy {
    return switch (content.*) {
        .copy => |*copy| copy,
        .alias,
        .boolean,
        .float,
        .integer,
        .mapping,
        .null_value,
        .scalar,
        .sequence,
        .string,
        => null,
    };
}

fn diagnostic_check(state: *State, copy: ?*const Tree.Content.Copy) !void {
    assert(state.tree.node_count > 0);
    if (copy) |source| assert(@backingInt(source.node) < source.document.node_count);

    const diagnostic = state.tree.diagnostic;
    if (std.meta.eql(diagnostic, parser_module.position_none)) return;

    if (copy) |source| {
        if (diagnostic.line >= 1) {
            if (diagnostic.column <= diagnostic.offset + 1) {
                if (diagnostic.offset <= source.document.source.len) return;
            }
        }
    }

    std.debug.print("fuzz tree: diagnostic {d}:{d} at {d} for a refused edit\n", .{
        diagnostic.line,
        diagnostic.column,
        diagnostic.offset,
    });

    return mismatch(state, "the diagnostic is outside the copied source", stream_index);
}

fn acceptance_check(state: *State, plan: *const Plan, handle: u32) !void {
    assert(handle > stream_index);
    assert(handle < state.tree.node_count);

    state.refusals.getPtr(.accepted).* += 1;

    if (plan.refusal != .accepted) {
        std.debug.print("fuzz tree: the model expected {t}, the tree accepted\n", .{plan.refusal});

        return mismatch(state, "the tree accepted a refused edit", handle);
    }

    if (handle == plan.value) return;

    std.debug.print("fuzz tree: the model predicted handle {d}\n", .{plan.value});

    return mismatch(state, "the handles differ", handle);
}

fn accepted_count(state: *State, operation: Operation, generated: *const Generated) void {
    assert(state.model.node_count == state.tree.node_count);
    assert(state.model.pool_count == state.tree.text_count);

    state.operations.getPtr(operation).* += 1;

    if (generated.content == .copy) state.counters.getPtr(.copy_accepted).* += 1;
}

fn refusal_of(err: Tree.EditError) Refusal {
    assert(@errorName(err).len > 0);
    assert(@typeInfo(Refusal).@"enum".field_names.len == 12);

    return switch (err) {
        error.AliasInvalid => .alias_invalid,
        error.AnchorDuplicate => .anchor_duplicate,
        error.AnchorReferenced => .anchor_referenced,
        error.AnchorsExhausted => .anchors_exhausted,
        error.CommentsExhausted => .comments_exhausted,
        error.DepthExceeded => .depth_exceeded,
        error.MergeInvalid => .merge_invalid,
        error.MergesExceeded => .merges_exceeded,
        error.NodesExhausted => .nodes_exhausted,
        error.TextExhausted => .text_exhausted,
        error.TextInvalid => .text_invalid,
    };
}

fn node_pick(state: *State, filter: Filter) ?u32 {
    assert(state.model.node_count >= 1);
    assert(state.model.node_count <= tree_records_max);

    const model = &state.model;

    var match_count: u32 = 0;

    for (1..model.node_count) |position| {
        match_count += @intFromBool(filter_matches(model, @intCast(position), filter));
    }

    if (match_count == 0) return null;

    var remaining = below(state, match_count);

    for (1..model.node_count) |position| {
        const index: u32 = @intCast(position);

        assert(index > stream_index);

        if (!filter_matches(model, index, filter)) continue;
        if (remaining == 0) return index;

        remaining -= 1;
    }

    unreachable;
}

fn filter_matches(model: *const Model, index: u32, filter: Filter) bool {
    assert(index > stream_index);
    assert(index < model.node_count);

    const node = &model.nodes[index];
    if (node.detached) return false;

    const home = &model.nodes[resolved_of(model, index)];

    return switch (filter) {
        .anchored => node.anchor.length > 0,
        .any => true,
        .mapping => home.kind == .mapping,
        .sequence => home.kind == .sequence,
        .value => !node.key,
    };
}

fn sequence_pick(state: *State) ?u32 {
    assert(state.model.node_count >= 1);
    assert(state.model.node_count <= tree_records_max);

    if (!chance(state, 8)) return node_pick(state, .sequence);

    const model = &state.model;

    var result: ?u32 = null;
    var level: u32 = 0;

    for (1..model.node_count) |position| {
        const index: u32 = @intCast(position);
        const node = &model.nodes[index];
        if (node.detached) continue;
        if (node.kind != .sequence) continue;
        if (model.levels[index] < level) continue;

        level = model.levels[index];
        result = index;
    }

    return result;
}

fn content_generate(state: *State, generated: *Generated) void {
    assert(state.model.node_count >= 1);
    assert(state.content_text.len == content_text_bytes_max);

    const anchor = anchor_choose(state);

    generated.anchor_valid = anchor.valid;

    generated.content = switch (content_kind_choose(state)) {
        .alias => alias_content(state),
        .boolean => .{ .boolean = chance(state, 2) },
        .copy => copy_content(state),
        .float => .{ .float = float_choose(state) },
        .integer => .{ .integer = integer_choose(state) },
        .mapping => .{ .mapping = collection_start(state, anchor.text) },
        .null_value => .null_value,
        .scalar => .{ .scalar = scalar_start(state, anchor.text) },
        .sequence => .{ .sequence = collection_start(state, anchor.text) },
        .string => .{ .string = text_generate(state) },
    };
}

fn content_kind_choose(state: *State) ContentKind {
    assert(@typeInfo(ContentKind).@"enum".field_names.len == 10);
    assert(state.model.node_count >= 1);

    return switch (below(state, 20)) {
        0 => .null_value,
        1 => .boolean,
        2 => .integer,
        3, 4 => .float,
        5, 6 => .string,
        7...10 => .scalar,
        11, 12 => .mapping,
        13, 14 => .sequence,
        15, 16 => .alias,
        else => .copy,
    };
}

fn anchor_choose(state: *State) Label {
    assert(anchors_valid.len > 0);
    assert(anchors_invalid.len > 0);

    if (!chance(state, 3)) return .{ .text = "", .valid = true };

    if (chance(state, 4)) {
        return .{ .text = anchors_invalid[below(state, anchors_invalid.len)], .valid = false };
    }

    return .{ .text = anchors_valid[below(state, anchors_valid.len)], .valid = true };
}

fn tag_choose(state: *State) []const u8 {
    assert(tags.len > 0);
    assert(state.model.node_count >= 1);

    if (!chance(state, 4)) return "";
    return tags[below(state, tags.len)];
}

fn alias_content(state: *State) Tree.Content {
    assert(state.model.node_count >= 1);
    assert(state.model.node_count == state.tree.node_count);

    const filter: Filter = if (chance(state, 4)) .any else .anchored;
    const index = node_pick(state, filter) orelse node_pick(state, .any) orelse return .null_value;

    return .{ .alias = @fromBackingInt(index) };
}

fn copy_content(state: *State) Tree.Content {
    assert(state.sources.len == 2);
    assert(state.model.node_count >= 1);

    const source = &state.sources[below(state, 2)].document;
    if (source.node_count == 0) return .null_value;

    const node = source_node_pick(state, source);
    const applied = chance(state, 2);

    return .{ .copy = .{
        .document = source,
        .merge = if (applied) .applied else .ignored,
        .node = node,
    } };
}

fn source_node_pick(state: *State, document: *const Document) DocumentNode {
    assert(document.node_count > 0);
    assert(document.root_count() > 0);

    if (chance(state, 3)) return document.root(below(state, document.root_count()));

    const index = below(state, document.node_count);
    const resolved = storage_module.resolved(document.storage.nodes, index);

    assert(resolved < document.node_count);

    return @fromBackingInt(resolved);
}

fn float_choose(state: *State) f64 {
    assert(floats.len > 0);
    assert(state.model.node_count >= 1);

    if (chance(state, 3)) return float_random(state);
    return floats[below(state, floats.len)];
}

fn float_random(state: *State) f64 {
    assert(state.model.node_count >= 1);
    assert(@sizeOf(f64) == @sizeOf(u64));

    const bits = state.prng.random().int(u64);
    const result: f64 = @bitCast(bits);

    assert(@as(u64, @bitCast(result)) == bits);

    return result;
}

fn integer_choose(state: *State) i64 {
    assert(integers.len > 0);
    assert(state.model.node_count >= 1);

    if (chance(state, 2)) return state.prng.random().int(i64);
    return integers[below(state, integers.len)];
}

fn collection_start(state: *State, anchor: []const u8) Event.CollectionStart {
    assert(anchor.len <= 64);
    assert(state.model.node_count >= 1);

    return .{
        .anchor = anchor,
        .style = if (chance(state, 2)) .flow else .block,
        .tag = tag_choose(state),
    };
}

fn scalar_start(state: *State, anchor: []const u8) Event.Scalar {
    assert(anchor.len <= 64);
    assert(state.model.node_count >= 1);

    const styles = [_]ScalarStyle{
        .plain,
        .plain,
        .single_quoted,
        .double_quoted,
        .literal,
        .folded,
    };

    return .{
        .anchor = anchor,
        .style = styles[below(state, styles.len)],
        .tag = tag_choose(state),
        .text = text_generate(state),
    };
}

fn text_generate(state: *State) []const u8 {
    assert(state.content_text.len == content_text_bytes_max);
    assert(fragments.len > 0);

    const count = below(state, fragment_count_max + 1);

    var length: u32 = 0;

    for (0..count) |_| {
        const fragment = fragments[below(state, fragments.len)];

        @memcpy(state.content_text[length..][0..fragment.len], fragment);
        length += @intCast(fragment.len);
    }

    if (chance(state, 12)) {
        const sequence = sequences_invalid[below(state, sequences_invalid.len)];

        @memcpy(state.content_text[length..][0..sequence.len], sequence);
        length += @intCast(sequence.len);
    }

    assert(length <= content_text_bytes_max);

    return state.content_text[0..length];
}

fn create_prepare(
    state: *State,
    generated: *const Generated,
    slot: *const Slot,
    key: ?[]const u8,
) Plan {
    assert(slot.parent < state.model.node_count);
    if (key) |text| assert(text.len <= tree_text_bytes_max);

    const model = &state.model;
    const keyed: u32 = @intFromBool(key != null);

    const refusal = switch (generated.content) {
        .copy => |*copy| copy_create_prepare(state, copy, slot, key),
        .alias,
        .boolean,
        .float,
        .integer,
        .mapping,
        .null_value,
        .scalar,
        .sequence,
        .string,
        => piece_create_prepare(state, generated, slot, key),
    };

    return .{
        .key = if (key == null) none else model.node_count,
        .refusal = refusal,
        .value = model.node_count + keyed,
    };
}

fn piece_create_prepare(
    state: *State,
    generated: *const Generated,
    slot: *const Slot,
    key: ?[]const u8,
) Refusal {
    assert(generated.content != .copy);
    if (key) |text| assert(text.len <= tree_text_bytes_max);

    var buffer: [codec.float_bytes_max]u8 = undefined;

    const piece = piece_of(state, generated, &buffer);
    const refusal = piece_refusal(state, &piece, slot, none, key);
    if (refusal != .accepted) return refusal;

    if (key) |text| key_place(&state.model, slot.parent, text);

    const value = node_take(&state.model);

    piece_place(&state.model, value, &piece);

    return .accepted;
}

fn piece_replace_prepare(
    state: *State,
    generated: *const Generated,
    slot: *const Slot,
    replaced: u32,
) Refusal {
    assert(generated.content != .copy);
    assert(replaced < state.model.node_count);

    var buffer: [codec.float_bytes_max]u8 = undefined;

    const piece = piece_of(state, generated, &buffer);
    const refusal = piece_refusal(state, &piece, slot, replaced, null);
    if (refusal != .accepted) return refusal;

    piece_place(&state.model, scratch_index, &piece);

    return .accepted;
}

fn piece_of(
    state: *State,
    generated: *const Generated,
    buffer: *[codec.float_bytes_max]u8,
) Piece {
    assert(generated.content != .copy);
    assert(buffer.len == codec.float_bytes_max);

    return switch (generated.content) {
        .alias => |target| .{
            .anchor = "",
            .anchor_valid = true,
            .home = resolved_of(&state.model, @backingInt(target)),
            .kind = .alias,
            .style = 0,
            .tag = "",
            .text = "",
        },
        .boolean => |value| piece_plain(if (value) "true" else "false"),
        .copy => unreachable,
        .float => |value| piece_plain(float_text(value, buffer)),
        .integer => |value| piece_plain(integer_text(value, buffer)),
        .mapping => |*start| piece_collection(start, .mapping, generated.anchor_valid),
        .null_value => piece_plain("null"),
        .scalar => |*scalar| .{
            .anchor = scalar.anchor,
            .anchor_valid = generated.anchor_valid,
            .home = none,
            .kind = .scalar,
            .style = @backingInt(scalar.style),
            .tag = scalar.tag,
            .text = scalar.text,
        },
        .sequence => |*start| piece_collection(start, .sequence, generated.anchor_valid),
        .string => |text| .{
            .anchor = "",
            .anchor_valid = true,
            .home = none,
            .kind = .scalar,
            .style = @backingInt(schema_module.string_style_of(text)),
            .tag = "",
            .text = text,
        },
    };
}

fn piece_plain(text: []const u8) Piece {
    assert(text.len > 0);
    assert(text.len <= codec.float_bytes_max);

    return .{
        .anchor = "",
        .anchor_valid = true,
        .home = none,
        .kind = .scalar,
        .style = @backingInt(ScalarStyle.plain),
        .tag = "",
        .text = text,
    };
}

fn piece_collection(start: *const Event.CollectionStart, kind: ModelKind, valid: bool) Piece {
    assert(kind == .mapping or kind == .sequence);
    assert(start.anchor.len <= 64);

    return .{
        .anchor = start.anchor,
        .anchor_valid = valid,
        .home = none,
        .kind = kind,
        .style = @backingInt(start.style),
        .tag = start.tag,
        .text = "",
    };
}

fn float_text(value: f64, buffer: *[codec.float_bytes_max]u8) []const u8 {
    assert(buffer.len == codec.float_bytes_max);
    assert(@sizeOf(@TypeOf(value)) == 8);

    if (std.math.isNan(value)) return ".nan";
    if (std.math.isInf(value)) return if (value > 0) ".inf" else "-.inf";
    return codec.float_text_render(f64, buffer, value);
}

fn integer_text(value: i64, buffer: *[codec.float_bytes_max]u8) []const u8 {
    assert(buffer.len == codec.float_bytes_max);
    assert(@sizeOf(@TypeOf(value)) == 8);

    return std.mem.print(buffer, "{d}", .{value}) catch |err| switch (err) {
        error.NoSpaceLeft => unreachable,
    };
}

fn piece_refusal(
    state: *State,
    piece: *const Piece,
    slot: *const Slot,
    replaced: u32,
    key: ?[]const u8,
) Refusal {
    assert(replaced != stream_index);
    if (key) |text| assert(text.len <= tree_text_bytes_max);

    const model = &state.model;
    const anchored = piece.anchor.len > 0;

    if (!std.unicode.utf8ValidateSlice(piece.text)) return .text_invalid;
    if (!std.unicode.utf8ValidateSlice(piece.tag)) return .text_invalid;

    if (anchored) {
        if (!piece.anchor_valid) return .text_invalid;
    }

    if (piece.kind == .alias) {
        if (!alias_valid(model, piece.home, slot)) return .alias_invalid;
    }

    if (anchored) {
        const claim: Claim = .{
            .document = slot.document,
            .excluded = replaced,
            .name = piece.anchor,
        };

        if (anchor_taken(model, &claim)) return .anchor_duplicate;
    }

    if (container_is(piece.kind)) {
        if (slot.level == depth_max) return .depth_exceeded;
    }

    if (anchored) {
        if (!anchor_room(model, replaced)) return .anchors_exhausted;
    }

    return room_refusal(model, piece, replaced, key);
}

fn room_refusal(model: *const Model, piece: *const Piece, replaced: u32, key: ?[]const u8) Refusal {
    assert(replaced != stream_index);
    if (key) |text| assert(text.len <= tree_text_bytes_max);

    const text = key orelse "";
    const keyed: u32 = @intFromBool(key != null);
    const node_need: u32 = if (replaced == none) keyed + 1 else 0;
    const text_need = @as(u64, text.len) + piece.anchor.len + piece.tag.len + piece.text.len;

    if (node_need > model.node_capacity - model.node_count) return .nodes_exhausted;
    if (text_need > model.pool_capacity - model.pool_count) return .text_exhausted;
    return .accepted;
}

fn alias_valid(model: *const Model, home: u32, slot: *const Slot) bool {
    assert(home < model.node_count);
    assert(slot.parent < model.node_count);

    if (model.nodes[home].anchor.length == 0) return false;
    if (slot.parent == stream_index) return false;
    if (document_of(model, home) != slot.document) return false;
    if (inside(model, slot.parent, .{ .first = home, .last = home })) return false;

    const limit = switch (slot.sibling) {
        .at, .before => |child| model.orders[child],
        .end => model.ends[slot.parent],
    };

    return model.orders[home] < limit;
}

fn anchor_taken(model: *const Model, claim: *const Claim) bool {
    assert(claim.name.len > 0);
    assert(claim.excluded != stream_index);

    const excluded: Segment = .{ .first = claim.excluded, .last = claim.excluded };

    for (1..model.node_count) |position| {
        const index: u32 = @intCast(position);
        const node = &model.nodes[index];
        if (node.detached) continue;
        if (node.anchor.length == 0) continue;
        if (!std.mem.eql(u8, span_text(model, node.anchor), claim.name)) continue;
        if (document_of(model, index) != claim.document) continue;

        if (claim.excluded != none) {
            if (inside(model, index, excluded)) continue;
        }

        return true;
    }

    return false;
}

fn anchor_room(model: *const Model, replaced: u32) bool {
    assert(replaced != stream_index);
    assert(model.anchor_count_max > 0);

    if (anchor_count_of(model) < model.anchor_count_max) return true;
    if (replaced == none) return false;
    return subtree_anchor_count(model, replaced) > 0;
}

fn anchor_count_of(model: *const Model) u32 {
    assert(model.node_count <= tree_records_max);
    assert(model.nodes[stream_index].kind == .stream);

    var result: u32 = 0;

    for (model.nodes[1..model.node_count]) |*node| {
        if (node.detached) continue;

        result += @intFromBool(node.anchor.length > 0);
    }

    assert(result < model.node_count);

    return result;
}

fn subtree_anchor_count(model: *const Model, root: u32) u32 {
    assert(root > stream_index);
    assert(root < model.node_count);

    var result: u32 = @intFromBool(model.nodes[root].anchor.length > 0);
    var preorder: Preorder = .{ .cursor = model.nodes[root].first, .root = root };

    for (0..model.node_count) |_| {
        if (preorder.cursor == none) break;

        result += @intFromBool(model.nodes[preorder.cursor].anchor.length > 0);
        preorder.cursor = preorder_next(model, &preorder);
    }

    assert(preorder.cursor == none);
    assert(result <= model.node_count);

    return result;
}

fn preorder_next(model: *const Model, preorder: *const Preorder) u32 {
    assert(preorder.cursor != preorder.root);
    assert(preorder.cursor <= scratch_index);

    const first = model.nodes[preorder.cursor].first;
    if (first != none) return first;

    var climb = preorder.cursor;

    for (0..depth_max + 4) |_| {
        if (climb == preorder.root) return none;
        if (model.nodes[climb].next != none) return model.nodes[climb].next;

        climb = model.nodes[climb].parent;
    }

    unreachable;
}

fn resolved_of(model: *const Model, index: u32) u32 {
    assert(index > stream_index);
    assert(index <= scratch_index);

    const node = &model.nodes[index];
    if (node.kind != .alias) return index;

    assert(model.nodes[node.home].kind != .alias);
    assert(!model.nodes[node.home].detached);

    return node.home;
}

fn document_of(model: *const Model, index: u32) u32 {
    assert(index > stream_index);
    assert(index < model.node_count);

    var cursor = index;

    for (0..depth_max + 4) |_| {
        const parent = model.nodes[cursor].parent;
        if (parent == stream_index) return cursor;

        cursor = parent;
    }

    unreachable;
}

fn inside(model: *const Model, index: u32, segment: Segment) bool {
    assert(index < model.node_count);
    assert(segment.first > stream_index);

    var cursor = index;

    for (0..depth_max + 4) |_| {
        if (cursor == segment.first) return true;
        if (cursor == segment.last) return true;
        if (cursor == stream_index) return false;

        cursor = model.nodes[cursor].parent;
    }

    unreachable;
}

fn referenced(model: *const Model, segment: Segment) bool {
    assert(segment.first > stream_index);
    assert(segment.last > stream_index);

    for (1..model.node_count) |position| {
        const index: u32 = @intCast(position);
        const node = &model.nodes[index];
        if (node.detached) continue;
        if (node.kind != .alias) continue;
        if (!inside(model, node.home, segment)) continue;
        if (inside(model, index, segment)) continue;
        return true;
    }

    return false;
}

fn child_at(model: *const Model, cell: Cell) u32 {
    assert(cell.container <= scratch_index);
    assert(cell.position < model.nodes[cell.container].count);

    var cursor = model.nodes[cell.container].first;

    for (0..cell.position) |_| cursor = model.nodes[cursor].next;

    assert(cursor != none);

    return cursor;
}

fn member_of(model: *const Model, mapping: u32, key: []const u8) u32 {
    assert(model.nodes[mapping].kind == .mapping);
    assert(key.len <= tree_text_bytes_max);

    var cursor = model.nodes[mapping].first;

    for (0..@divExact(model.nodes[mapping].count, 2)) |_| {
        const home = &model.nodes[resolved_of(model, cursor)];
        const value = model.nodes[cursor].next;
        const scalar = home.kind == .scalar;

        if (scalar) {
            if (std.mem.eql(u8, span_text(model, home.text), key)) return value;
        }

        cursor = model.nodes[value].next;
    }

    return none;
}

fn span_text(model: *const Model, span: Span) []const u8 {
    assert(span.offset <= model.pool_next);
    assert(span.length <= model.pool_next - span.offset);

    return model.pool[span.offset..][0..span.length];
}

fn node_take(model: *Model) u32 {
    assert(model.node_next < model.node_capacity);
    assert(model.node_next >= model.node_count);

    const result = model.node_next;

    model.node_next += 1;

    return result;
}

fn pool_keep(model: *Model, text: []const u8) Span {
    assert(model.pool_next <= model.pool_capacity);
    assert(text.len <= model.pool_capacity - model.pool_next);

    if (text.len == 0) return span_empty;

    const offset = model.pool_next;

    @memcpy(model.pool[offset..][0..text.len], text);
    model.pool_next += @intCast(text.len);

    return .{ .length = @intCast(text.len), .offset = offset };
}

fn key_place(model: *Model, parent: u32, text: []const u8) void {
    assert(parent < model.node_count);
    assert(std.unicode.utf8ValidateSlice(text));

    const index = node_take(model);
    const style = schema_module.string_style_of(text);
    const quoted: ScalarStyle = if (style == .single_quoted) .single_quoted else .double_quoted;
    const key_style: ScalarStyle = if (style == .plain) .plain else quoted;

    model.nodes[index] = node_blank(.scalar, parent);
    model.nodes[index].style = @backingInt(key_style);
    model.nodes[index].text = pool_keep(model, text);
}

fn piece_place(model: *Model, index: u32, piece: *const Piece) void {
    assert(index <= scratch_index);
    assert(piece.kind != .stream);

    model.nodes[index] = node_blank(piece.kind, none);
    model.nodes[index].anchor = pool_keep(model, piece.anchor);
    model.nodes[index].home = piece.home;
    model.nodes[index].style = piece.style;
    model.nodes[index].tag = pool_keep(model, piece.tag);
    model.nodes[index].text = pool_keep(model, piece.text);
}

fn create_commit(model: *Model, plan: *const Plan, slot: *const Slot) void {
    assert(plan.refusal == .accepted);
    assert(plan.value >= model.node_count);

    const link: Link = .{ .parent = slot.parent, .sibling = slot.sibling };

    if (plan.key != none) child_link(model, link, plan.key);

    child_link(model, link, plan.value);

    model.node_count = model.node_next;
    model.pool_count = model.pool_next;
}

fn replace_commit(model: *Model, index: u32) void {
    assert(index > stream_index);
    assert(!model.nodes[index].detached);

    descendants_detach(model, index);

    const scratch = &model.nodes[scratch_index];
    const node = &model.nodes[index];

    node.anchor = scratch.anchor;
    node.count = scratch.count;
    node.first = scratch.first;
    node.home = scratch.home;
    node.kind = scratch.kind;
    node.last = scratch.last;
    node.style = scratch.style;
    node.tag = scratch.tag;
    node.text = scratch.text;

    var cursor = node.first;

    for (0..node.count) |_| {
        model.nodes[cursor].parent = index;
        cursor = model.nodes[cursor].next;
    }

    assert(cursor == none);

    model.node_count = model.node_next;
    model.pool_count = model.pool_next;
}

fn child_link(model: *Model, link: Link, child: u32) void {
    assert(link.parent <= scratch_index);
    assert(link.sibling != .at);
    assert(child <= scratch_index);

    const container = &model.nodes[link.parent];
    const node = &model.nodes[child];

    const next = switch (link.sibling) {
        .at => unreachable,
        .before => |before| before,
        .end => none,
    };

    const previous = if (next == none) container.last else model.nodes[next].previous;

    if (next != none) assert(model.nodes[next].parent == link.parent);

    node.key = container.kind == .mapping and container.count % 2 == 0;
    node.next = next;
    node.parent = link.parent;
    node.previous = previous;

    if (previous == none) {
        container.first = child;
    } else {
        model.nodes[previous].next = child;
    }

    if (next == none) {
        container.last = child;
    } else {
        model.nodes[next].previous = child;
    }

    container.count += 1;
}

fn child_unlink(model: *Model, child: u32) void {
    assert(child > stream_index);
    assert(child < model.node_count);

    const node = &model.nodes[child];
    const container = &model.nodes[node.parent];

    if (node.previous == none) {
        container.first = node.next;
    } else {
        model.nodes[node.previous].next = node.next;
    }

    if (node.next == none) {
        container.last = node.previous;
    } else {
        model.nodes[node.next].previous = node.previous;
    }

    container.count -= 1;
    node.next = none;
    node.previous = none;
}

fn subtree_detach(model: *Model, root: u32) void {
    assert(root > stream_index);
    assert(!model.nodes[root].detached);

    model.nodes[root].detached = true;

    descendants_detach(model, root);
}

fn descendants_detach(model: *Model, root: u32) void {
    assert(root > stream_index);
    assert(root < model.node_count);

    var preorder: Preorder = .{ .cursor = model.nodes[root].first, .root = root };

    for (0..model.node_count) |_| {
        if (preorder.cursor == none) return;

        model.nodes[preorder.cursor].detached = true;
        preorder.cursor = preorder_next(model, &preorder);
    }

    unreachable;
}

fn copy_create_prepare(
    state: *State,
    copy: *const Tree.Content.Copy,
    slot: *const Slot,
    key: ?[]const u8,
) Refusal {
    assert(@backingInt(copy.node) < copy.document.node_count);
    if (key) |text| assert(text.len <= tree_text_bytes_max);

    const model = &state.model;
    const text = key orelse "";
    const keyed: u32 = @intFromBool(key != null);
    if (keyed + 1 > model.node_capacity - model.node_count) return .nodes_exhausted;
    if (text.len > model.pool_capacity - model.pool_count) return .text_exhausted;

    if (key != null) key_place(model, slot.parent, text);

    const value = node_take(model);
    const markers = copy.document.storage.nodes[@backingInt(copy.node)].markers;
    const root = slot.parent == stream_index;

    model.nodes[value] = node_blank(.scalar, slot.parent);
    model.nodes[value].end_explicit = root and markers.end_explicit;
    model.nodes[value].start_explicit = root and markers.start_explicit;

    return simulation_run(state, copy, slot, .{ .excluded = none, .target = value });
}

fn copy_replace_prepare(
    state: *State,
    copy: *const Tree.Content.Copy,
    slot: *const Slot,
    replaced: u32,
) Refusal {
    assert(replaced > stream_index);
    assert(replaced < state.model.node_count);

    state.model.nodes[scratch_index] = node_blank(.scalar, slot.parent);

    return simulation_run(state, copy, slot, .{ .excluded = replaced, .target = scratch_index });
}

fn simulation_run(
    state: *State,
    copy: *const Tree.Content.Copy,
    slot: *const Slot,
    fill: Fill,
) Refusal {
    assert(fill.target <= scratch_index);
    assert(fill.excluded != stream_index);

    const model = &state.model;
    const simulation = &state.simulation;
    const source = @backingInt(copy.node);
    const replaced = fill.excluded != none;
    const removed = if (replaced) subtree_anchor_count(model, fill.excluded) else 0;

    assert(copy.document.storage.nodes[source].kind != .alias);

    simulation.anchor_count = anchor_count_of(model) - removed;
    simulation.copy = copy;
    simulation.depth = 0;
    simulation.document = slot.document;
    simulation.excluded = fill.excluded;
    simulation.home_count = 0;
    simulation.level = slot.level;
    simulation.range_end = source + copy.document.storage.nodes[source].span;
    simulation.range_first = source;
    simulation.sources = .{ .count = 0, .failure = undefined, .nodes = undefined };
    simulation.target = fill.target;

    return simulation_walk(state);
}

fn simulation_walk(state: *State) Refusal {
    assert(state.simulation.depth == 0);
    assert(state.simulation.range_first < state.simulation.range_end);

    const simulation = &state.simulation;
    const root: Child = .{ .mode = .raw, .source = simulation.range_first };
    const root_refusal = node_simulate(state, simulation.target, root);
    if (root_refusal != .accepted) return root_refusal;

    const step_count_max = 2 * @as(u64, state.model.node_capacity) + 2;

    for (0..step_count_max) |_| {
        if (simulation.depth == 0) return .accepted;

        const step = simulation_step(state);
        if (step != .accepted) return step;
    }

    unreachable;
}

fn simulation_step(state: *State) Refusal {
    assert(state.simulation.depth > 0);
    assert(state.simulation.depth <= depth_max);

    const simulation = &state.simulation;
    const frame = &simulation.frames[simulation.depth - 1];

    var child: Child = .{ .mode = frame.mode, .source = none };

    const next = child_next_simulate(state, frame, &child);
    if (next != .accepted) return next;

    if (child.source == none) {
        simulation.depth -= 1;

        simulation.sources.pop(frame.list);

        return .accepted;
    }

    return child_simulate(state, child);
}

fn child_next_simulate(state: *State, frame: *SimulationFrame, child: *Child) Refusal {
    assert(frame.cursor <= frame.end);
    assert(child.source == none);

    const nodes = state.simulation.copy.document.storage.nodes;

    if (frame.pending.source != none) {
        child.* = frame.pending;
        frame.pending.source = none;

        return .accepted;
    }

    if (frame.merged) return merged_next_simulate(state, frame, child);
    if (frame.cursor == frame.end) return .accepted;

    child.* = .{ .mode = frame.mode, .source = frame.cursor };
    frame.cursor += nodes[frame.cursor].span;

    return .accepted;
}

fn merged_next_simulate(state: *State, frame: *SimulationFrame, child: *Child) Refusal {
    assert(frame.merged);
    assert(child.source == none);

    const nodes = state.simulation.copy.document.storage.nodes;
    const own_before = frame.entries.phase == .own;
    const entry = frame.entries.next();
    const own_after = frame.entries.phase == .own;

    if (own_before != own_after) {
        const dropped = merge_entry_drop(state, frame);
        if (dropped != .accepted) return dropped;
    }

    const pair = entry orelse {
        assert(frame.cursor == frame.end);

        return .accepted;
    };

    if (frame.entries.phase == .merged) {
        child.* = .{ .mode = .expanded, .source = @backingInt(pair.key) };
        frame.pending = .{ .mode = .expanded, .source = @backingInt(pair.value) };

        return .accepted;
    }

    const key = frame.cursor;
    const value = key + nodes[key].span;

    assert(storage_module.resolved(nodes, key) == @backingInt(pair.key));
    assert(storage_module.resolved(nodes, value) == @backingInt(pair.value));

    frame.cursor = value + nodes[value].span;
    child.* = .{ .mode = frame.mode, .source = key };
    frame.pending = .{ .mode = frame.mode, .source = value };

    return .accepted;
}

fn merge_entry_drop(state: *State, frame: *SimulationFrame) Refusal {
    assert(frame.merged);
    assert(frame.cursor < frame.end);

    const document = state.simulation.copy.document;
    const nodes = document.storage.nodes;
    const key = frame.cursor;
    const value = key + nodes[key].span;
    const after = value + nodes[value].span;
    const resolved: DocumentNode = @fromBackingInt(storage_module.resolved(nodes, key));

    assert(merge.entry_merge_is(Document, document, resolved));

    frame.cursor = after;

    if (frame.mode != .raw) return .accepted;

    state.counters.getPtr(.dropped_checked).* += 1;

    for (nodes[key..after]) |*record| {
        if (record.kind == .alias) continue;
        if (record.anchor.len == 0) continue;
        if (copy_registered(state, record.anchor)) return .anchor_duplicate;
    }

    return .accepted;
}

fn child_simulate(state: *State, child: Child) Refusal {
    assert(child.source < state.simulation.copy.document.node_count);
    assert(state.simulation.depth > 0);

    const record = &state.simulation.copy.document.storage.nodes[child.source];
    if (record.kind != .alias) return node_simulate(state, none, child);

    if (child.mode == .raw) {
        const home = home_find(state, record.link.target);
        if (home != none) return alias_simulate(state, home);
    }

    state.counters.getPtr(.alias_expanded).* += 1;

    return node_simulate(state, none, .{ .mode = .expanded, .source = record.link.target });
}

fn home_find(state: *const State, target: u32) u32 {
    assert(target < state.simulation.copy.document.node_count);
    assert(state.simulation.home_count <= anchor_slot_count_max);

    const simulation = &state.simulation;
    if (target < simulation.range_first) return none;
    if (target >= simulation.range_end) return none;

    for (simulation.homes[0..simulation.home_count]) |home| {
        if (home.source == target) return home.index;
    }

    return none;
}

fn alias_simulate(state: *State, home: u32) Refusal {
    assert(home != scratch_index);
    assert(state.simulation.depth > 0);

    const model = &state.model;
    const frame = &state.simulation.frames[state.simulation.depth - 1];

    if (model.node_next == model.node_capacity) return .nodes_exhausted;

    const index = node_take(model);

    model.nodes[index] = node_blank(.alias, none);
    model.nodes[index].home = home;

    child_link(model, .{ .parent = frame.container, .sibling = .end }, index);
    state.counters.getPtr(.alias_kept).* += 1;

    return .accepted;
}

fn node_simulate(state: *State, reserved: u32, child: Child) Refusal {
    assert(reserved != stream_index);
    assert(child.source < state.simulation.copy.document.node_count);

    const model = &state.model;
    const simulation = &state.simulation;
    const record = &simulation.copy.document.storage.nodes[child.source];
    const anchor = if (child.mode == .raw) record.anchor else "";
    const bytes = @as(u64, anchor.len) + record.tag.len + record.text.len;

    assert(record.kind != .alias);

    if (bytes > model.pool_capacity - model.pool_next) return .text_exhausted;

    var index = reserved;

    if (reserved == none) {
        if (model.node_next == model.node_capacity) return .nodes_exhausted;

        const frame = &simulation.frames[simulation.depth - 1];

        index = node_take(model);
        model.nodes[index] = node_blank(.scalar, none);

        child_link(model, .{ .parent = frame.container, .sibling = .end }, index);
    }

    node_fill(state, index, child);

    const registered = anchor_simulate(state, index, child);
    if (registered != .accepted) return registered;
    return frame_simulate_open(state, index, child);
}

fn node_fill(state: *State, index: u32, child: Child) void {
    assert(index <= scratch_index);
    assert(child.source < state.simulation.copy.document.node_count);

    const model = &state.model;
    const record = &state.simulation.copy.document.storage.nodes[child.source];
    const anchor = if (child.mode == .raw) record.anchor else "";
    const node = &model.nodes[index];

    node.anchor = pool_keep(model, anchor);
    node.count = 0;
    node.first = none;
    node.home = none;
    node.kind = model_kind_of(record.kind);
    node.last = none;
    node.style = record.style;
    node.tag = pool_keep(model, record.tag);
    node.text = pool_keep(model, record.text);
}

fn model_kind_of(kind: storage_module.NodeKind) ModelKind {
    assert(kind != .alias);
    assert(@typeInfo(storage_module.NodeKind).@"enum".field_names.len == 4);

    return switch (kind) {
        .alias => unreachable,
        .mapping => .mapping,
        .scalar => .scalar,
        .sequence => .sequence,
    };
}

fn anchor_simulate(state: *State, index: u32, child: Child) Refusal {
    assert(index <= scratch_index);
    assert(child.source < state.simulation.copy.document.node_count);

    const model = &state.model;
    const simulation = &state.simulation;
    const name = simulation.copy.document.storage.nodes[child.source].anchor;

    if (child.mode != .raw) return .accepted;
    if (name.len == 0) return .accepted;

    const claim: Claim = .{
        .document = simulation.document,
        .excluded = simulation.excluded,
        .name = name,
    };

    if (anchor_taken(model, &claim)) return .anchor_duplicate;
    if (copy_registered(state, name)) return .anchor_duplicate;
    if (simulation.anchor_count == model.anchor_count_max) return .anchors_exhausted;

    simulation.homes[simulation.home_count] = .{ .index = index, .source = child.source };
    simulation.home_count += 1;
    simulation.anchor_count += 1;

    return .accepted;
}

fn copy_registered(state: *const State, name: []const u8) bool {
    assert(name.len > 0);
    assert(state.simulation.home_count <= anchor_slot_count_max);

    const simulation = &state.simulation;
    const nodes = simulation.copy.document.storage.nodes;

    for (simulation.homes[0..simulation.home_count]) |home| {
        if (std.mem.eql(u8, nodes[home.source].anchor, name)) return true;
    }

    return false;
}

fn frame_simulate_open(state: *State, index: u32, child: Child) Refusal {
    assert(index <= scratch_index);
    assert(child.source < state.simulation.copy.document.node_count);

    const simulation = &state.simulation;
    const record = &simulation.copy.document.storage.nodes[child.source];
    if (record.kind == .scalar) return .accepted;
    if (simulation.level + simulation.depth + 1 > depth_max) return .depth_exceeded;

    const frame = &simulation.frames[simulation.depth];

    frame.* = .{
        .container = index,
        .cursor = child.source + 1,
        .end = child.source + record.span,
        .entries = undefined,
        .list = &.{},
        .merged = false,
        .mode = child.mode,
        .pending = .{ .mode = child.mode, .source = none },
    };

    const merging = record.kind == .mapping and simulation.copy.merge == .applied;

    if (merging) {
        const refusal = frame_merge_simulate(state, frame, child.source);
        if (refusal != .accepted) return refusal;
    }

    simulation.depth += 1;

    return .accepted;
}

fn frame_merge_simulate(state: *State, frame: *SimulationFrame, source: u32) Refusal {
    assert(frame.list.len == 0);
    assert(source < state.simulation.copy.document.node_count);

    const simulation = &state.simulation;
    const document = simulation.copy.document;
    const mapping: DocumentNode = @fromBackingInt(source);
    if (merge.value_of(Document, document, mapping) == null) return .accepted;

    frame.list = simulation.sources.flatten(document, mapping) catch |err| switch (err) {
        error.MergeInvalid => return .merge_invalid,
        error.MergesExceeded => return .merges_exceeded,
    };

    frame.entries = merge.EntriesType(Document).init(document, mapping, frame.list);
    frame.merged = true;

    state.counters.getPtr(.copy_merged).* += 1;

    return .accepted;
}

fn value_check(state: *State, index: u32, generated: *const Generated) !void {
    assert(index > stream_index);
    assert(index < state.model.node_count);

    const tree = &state.tree;
    const handle: Tree.Node = @fromBackingInt(index);

    switch (generated.content) {
        .alias, .copy, .mapping, .scalar, .sequence => {},
        .boolean => |value| {
            const read = tree.boolean_of(handle) orelse {
                return mismatch(state, "a boolean does not read as one", index);
            };

            if (read != value) return mismatch(state, "a boolean reads back changed", index);
        },
        .float => |value| try float_check(state, index, value),
        .integer => |value| {
            const read = tree.integer_of(handle) orelse {
                return mismatch(state, "an integer does not read as one", index);
            };

            if (read != value) return mismatch(state, "an integer reads back changed", index);
        },
        .null_value => {
            if (!tree.null_is(handle)) return mismatch(state, "a null does not read as one", index);
        },
        .string => try string_check(state, index),
    }
}

fn float_check(state: *State, index: u32, value: f64) !void {
    assert(index > stream_index);
    assert(@sizeOf(@TypeOf(value)) == 8);

    const handle: Tree.Node = @fromBackingInt(index);
    const text = state.tree.text_of(handle).?;
    const schemas = [_]Schema{ .core, .json, .v1_1 };

    if (state.tree.integer_of(handle) != null) {
        return mismatch(state, "a float reads as an integer", index);
    }

    for (schemas) |schema| {
        const foreign = schema_module.float_text_of(text, schema);
        const read = if (schema == state.tree.schema) state.tree.float_of(handle) else foreign;

        if (schema == .json) {
            const finite = std.math.isFinite(value);

            if (!finite) {
                if (read != null) return mismatch(state, "a non-finite float reads as JSON", index);

                continue;
            }
        }

        const found = read orelse return mismatch(state, "a float does not read as one", index);

        if (std.math.isNan(value)) {
            if (!std.math.isNan(found)) return mismatch(state, "a NaN reads as a number", index);

            continue;
        }

        if (@as(u64, @bitCast(found)) != @as(u64, @bitCast(value))) {
            return mismatch(state, "a float reads back changed", index);
        }
    }
}

fn string_check(state: *State, index: u32) !void {
    assert(index > stream_index);
    assert(index < state.model.node_count);

    const tree = &state.tree;
    const handle: Tree.Node = @fromBackingInt(index);
    if (tree.null_is(handle)) return mismatch(state, "a string reads as null", index);
    if (tree.boolean_of(handle)) |_| return mismatch(state, "a string reads as a boolean", index);
    if (tree.integer_of(handle)) |_| return mismatch(state, "a string reads as an integer", index);
    if (tree.float_of(handle)) |_| return mismatch(state, "a string reads as a float", index);
}

fn model_compare(state: *State) !void {
    assert(state.model.node_count <= state.model.node_capacity);
    assert(state.model.pool_count <= state.model.pool_capacity);

    const tree = &state.tree;
    const model = &state.model;
    if (tree.node_count != model.node_count) return mismatch(state, "the node counts differ", 0);
    if (tree.text_count != model.pool_count) return mismatch(state, "the text counts differ", 0);

    if (tree.anchor_count != anchor_count_of(model)) {
        return mismatch(state, "the anchor counts differ", 0);
    }

    if (tree.root_count() != model.nodes[stream_index].count) {
        return mismatch(state, "the root counts differ", 0);
    }

    var root = model.nodes[stream_index].first;

    for (0..model.nodes[stream_index].count) |position| {
        const found = tree.root(@intCast(position));
        if (@backingInt(found) != root) return mismatch(state, "the roots differ", root);

        root = model.nodes[root].next;
    }

    for (1..model.node_count) |position| try node_compare(state, @intCast(position));
}

fn node_compare(state: *State, index: u32) !void {
    assert(index > stream_index);
    assert(index < state.model.node_count);

    const node = &state.model.nodes[index];
    const flags = state.tree.records[index].flags;
    if (flags.detached != node.detached) return mismatch(state, "the detached marks differ", index);
    if (node.detached) return;
    if (flags.key != node.key) return mismatch(state, "the key marks differ", index);

    if (flags.start_explicit != node.start_explicit) {
        return mismatch(state, "the document start markers differ", index);
    }

    if (flags.end_explicit != node.end_explicit) {
        return mismatch(state, "the document end markers differ", index);
    }

    try alias_compare(state, index);
    try properties_compare(state, index);
    try comments_compare(state, index);

    switch (node.kind) {
        .alias, .scalar => {},
        .mapping => try entries_compare(state, index),
        .sequence => try items_compare(state, index),
        .stream => unreachable,
    }
}

fn alias_compare(state: *State, index: u32) !void {
    assert(index > stream_index);
    assert(!state.model.nodes[index].detached);

    const node = &state.model.nodes[index];
    const alias = state.tree.alias_of(@fromBackingInt(index));

    if (node.kind != .alias) {
        if (alias != null) return mismatch(state, "a value reads as an alias", index);
        return;
    }

    const found = alias orelse return mismatch(state, "an alias reads as a value", index);
    if (@backingInt(found) != node.home) return mismatch(state, "an alias points elsewhere", index);
}

fn properties_compare(state: *State, index: u32) !void {
    assert(index > stream_index);
    assert(!state.model.nodes[index].detached);

    const model = &state.model;
    const tree = &state.tree;
    const handle: Tree.Node = @fromBackingInt(index);
    const target = &model.nodes[resolved_of(model, index)];
    const kind = tree.kind_of(handle);

    if (!std.mem.eql(u8, @tagName(target.kind), @tagName(kind))) {
        return mismatch(state, "the kinds differ", index);
    }

    if (!std.mem.eql(u8, tree.anchor_of(handle), span_text(model, target.anchor))) {
        return mismatch(state, "the anchors differ", index);
    }

    if (!std.mem.eql(u8, tree.tag_of(handle), span_text(model, target.tag))) {
        return mismatch(state, "the tags differ", index);
    }

    if (style_backing(tree.style_of(handle)) != target.style) {
        return mismatch(state, "the styles differ", index);
    }

    if (tree.count_of(handle) != count_expected(target)) {
        return mismatch(state, "the counts differ", index);
    }

    if (kind != .scalar) return;

    if (!std.mem.eql(u8, tree.text_of(handle).?, span_text(model, target.text))) {
        return mismatch(state, "the texts differ", index);
    }
}

fn style_backing(style: document_module.Style) u8 {
    assert(@backingInt(std.meta.activeTag(style)) <= 2);
    assert(@typeInfo(document_module.Style).@"union".field_names.len == 3);

    return switch (style) {
        .mapping, .sequence => |collection| @backingInt(collection),
        .scalar => |scalar| @backingInt(scalar),
    };
}

fn count_expected(node: *const ModelNode) u32 {
    assert(node.kind != .alias);
    assert(node.kind != .stream);

    return switch (node.kind) {
        .alias, .stream => unreachable,
        .mapping => @divExact(node.count, 2),
        .scalar => 0,
        .sequence => node.count,
    };
}

fn entries_compare(state: *State, index: u32) !void {
    assert(state.model.nodes[index].kind == .mapping);
    assert(state.model.nodes[index].count % 2 == 0);

    const model = &state.model;

    var iterator = state.tree.entries(@fromBackingInt(index));
    var cursor = model.nodes[index].first;

    for (0..@divExact(model.nodes[index].count, 2)) |_| {
        const entry = iterator.next() orelse return mismatch(state, "an entry is missing", index);
        const value = model.nodes[cursor].next;

        if (@backingInt(entry.key) != cursor) return mismatch(state, "the keys differ", cursor);
        if (@backingInt(entry.value) != value) return mismatch(state, "the values differ", value);

        cursor = model.nodes[value].next;
    }

    if (iterator.next() != null) return mismatch(state, "an extra entry was found", index);
}

fn items_compare(state: *State, index: u32) !void {
    assert(state.model.nodes[index].kind == .sequence);
    assert(!state.model.nodes[index].detached);

    const model = &state.model;

    var iterator = state.tree.items(@fromBackingInt(index));
    var cursor = model.nodes[index].first;

    for (0..model.nodes[index].count) |_| {
        const item = iterator.next() orelse return mismatch(state, "an item is missing", index);
        if (@backingInt(item) != cursor) return mismatch(state, "the items differ", cursor);

        cursor = model.nodes[cursor].next;
    }

    if (iterator.next() != null) return mismatch(state, "an extra item was found", index);
}

fn mismatch(state: *State, message: []const u8, index: u32) error{TreeMismatch} {
    assert(message.len > 0);
    assert(index != scratch_index);

    std.debug.print("fuzz tree: event {d}: {s} (node {d})\n", .{
        state.event_index,
        message,
        index,
    });

    var sink: std.Io.Writer = .fixed(&state.output_again);

    state.tree.write(&sink, .{
        .indent = 2,
        .layout = .preserve,
        .sequence_indentless = false,
        .utf8 = .trusted,
        .version_directive = false,
        .width = 0,
    }) catch |err| {
        std.debug.print("fuzz tree: the tree did not write ({t})\n", .{err});

        return error.TreeMismatch;
    };

    std.debug.print("--- tree ---\n{f}\n--- end ---\n", .{std.zig.fmtString(sink.buffered())});

    return error.TreeMismatch;
}

fn write_check(state: *State) !void {
    assert(state.model.node_count == state.tree.node_count);
    assert(state.output.len == output_bytes_max);

    const options = writer_options_choose(state);
    const output = try tree_written(&state.tree, &options, &state.output);
    const events = model_events(state);

    try stream_check(state, &options, output, events);
    try reparse_check(state, &options, output);
    try json_check(state);
    try paths_check(state);
    try sink_check(state, &options, output);

    state.counters.getPtr(.write_compared).* += 1;
}

fn writer_options_choose(state: *State) Writer.Options {
    assert(writer_module.depth_max > depth_max);
    assert(state.model.node_count >= 1);

    const layouts = [_]Writer.Layout{ .block, .flow, .preserve };
    const widths = [_]u32{ 0, 0, 0, 1, 20, 80 };

    return .{
        .indent = @intCast(1 + below(state, 9)),
        .layout = layouts[below(state, layouts.len)],
        .sequence_indentless = chance(state, 2),
        .utf8 = if (chance(state, 2)) .checked else .trusted,
        .version_directive = chance(state, 4),
        .width = widths[below(state, widths.len)],
    };
}

fn tree_written(tree: *const Tree, options: *const Writer.Options, buffer: []u8) ![]u8 {
    assert(options.indent >= 1);
    assert(buffer.len == output_bytes_max);

    var sink: std.Io.Writer = .fixed(buffer);

    try tree.write(&sink, options.*);

    return sink.buffered();
}

fn document_written(
    document: *const Document,
    options: *const Writer.Options,
    buffer: []u8,
) ![]u8 {
    assert(options.indent >= 1);
    assert(buffer.len == output_bytes_max);

    var sink: std.Io.Writer = .fixed(buffer);

    try document.write(&sink, options.*);

    return sink.buffered();
}

fn model_events(state: *State) []const Event {
    assert(state.model.node_count <= tree_records_max);
    assert(state.events.len == event_count_max);

    const model = &state.model;

    var count: u32 = 0;
    var root = model.nodes[stream_index].first;

    event_push(state, &count, .stream_start);

    for (0..model.nodes[stream_index].count) |_| {
        const node = &model.nodes[root];
        const end_explicit = node.end_explicit or root_bare_commented(model, root);

        event_push(state, &count, .{ .document_start = .{ .explicit = node.start_explicit } });
        node_events(state, &count, root);
        event_push(state, &count, .{ .document_end = .{ .explicit = end_explicit } });

        root = node.next;
    }

    event_push(state, &count, .stream_end);

    return state.events[0..count];
}

fn root_bare_commented(model: *const Model, root: u32) bool {
    assert(root > stream_index);
    assert(model.nodes[root].parent == stream_index);

    const node = &model.nodes[root];

    const block = node.style == @backingInt(ScalarStyle.literal) or
        node.style == @backingInt(ScalarStyle.folded);

    if (node.kind != .scalar) return false;
    if (!block) return false;
    if (node.comments[2].count == 0) return false;

    for (span_text(model, node.text)) |byte| {
        if (byte != '\n') return false;
    }

    return true;
}

fn event_push(state: *State, count: *u32, event: Event) void {
    assert(count.* < event_count_max);
    assert(@backingInt(std.meta.activeTag(event)) < 10);

    state.events[count.*] = event;
    count.* += 1;
}

fn node_events(state: *State, count: *u32, root: u32) void {
    assert(root > stream_index);
    assert(state.model.nodes[root].parent == stream_index);

    const model = &state.model;

    var containers: [depth_max + 2]u32 = undefined;
    var cursors: [depth_max + 2]u32 = undefined;
    var depth: u32 = 0;

    if (node_event_open(state, count, root)) {
        containers[0] = root;
        cursors[0] = model.nodes[root].first;
        depth = 1;
    }

    for (0..2 * model.node_count + 2) |_| {
        if (depth == 0) return;

        const cursor = cursors[depth - 1];

        if (cursor == none) {
            depth -= 1;

            node_event_close(state, count, containers[depth]);

            continue;
        }

        cursors[depth - 1] = model.nodes[cursor].next;

        if (node_event_open(state, count, cursor)) {
            containers[depth] = cursor;
            cursors[depth] = model.nodes[cursor].first;
            depth += 1;
        }
    }

    unreachable;
}

fn node_event_open(state: *State, count: *u32, index: u32) bool {
    assert(index > stream_index);
    assert(!state.model.nodes[index].detached);

    const model = &state.model;
    const node = &model.nodes[index];
    const anchor = span_text(model, node.anchor);
    const tag = span_text(model, node.tag);

    switch (node.kind) {
        .alias => {
            const home = span_text(model, model.nodes[node.home].anchor);

            event_push(state, count, .{ .alias = .{ .anchor = home } });

            return false;
        },
        .mapping, .sequence => {
            const start: Event.CollectionStart = .{
                .anchor = anchor,
                .style = @fromBackingInt(@as(u1, @intCast(node.style))),
                .tag = tag,
            };

            const event: Event = if (node.kind == .mapping) .{
                .mapping_start = start,
            } else .{
                .sequence_start = start,
            };

            event_push(state, count, event);

            return true;
        },
        .scalar => {
            event_push(state, count, .{ .scalar = .{
                .anchor = anchor,
                .style = @fromBackingInt(@as(u3, @intCast(node.style))),
                .tag = tag,
                .text = span_text(model, node.text),
            } });

            return false;
        },
        .stream => unreachable,
    }
}

fn node_event_close(state: *State, count: *u32, index: u32) void {
    assert(index > stream_index);
    assert(container_is(state.model.nodes[index].kind));

    const mapping = state.model.nodes[index].kind == .mapping;

    event_push(state, count, if (mapping) .mapping_end else .sequence_end);
}

fn stream_check(
    state: *State,
    options: *const Writer.Options,
    output: []const u8,
    events: []const Event,
) !void {
    assert(events.len >= 2);
    assert(output.len <= output_bytes_max);

    const comparison: round_trip.Options = .{
        .layout = options.layout,
        .style_exact = false,
        .version_directive = options.version_directive,
    };

    state.parser.init(&state.parser_text, output);

    const sources: round_trip.Sources = .{
        .original = .{ .events = events },
        .written = .{ .parser = &state.parser },
    };

    const verdict = round_trip.streams_equivalent(sources, comparison) catch |err| {
        std.debug.print("fuzz tree: the written tree does not parse ({t})\n", .{err});

        return mismatch(state, "the output is not YAML", 0);
    };

    switch (verdict) {
        .differed => |reason| {
            std.debug.print("fuzz tree: {s}\n", .{reason});
            std.debug.print("--- written ---\n{f}\n--- end ---\n", .{std.zig.fmtString(output)});

            return mismatch(state, "the output differs from the model", 0);
        },
        .matched => {},
    }
}

fn reparse_check(state: *State, options: *const Writer.Options, output: []const u8) !void {
    assert(output.len <= output_bytes_max);
    assert(options.indent >= 1);

    state.reparsed.parse(output, .{ .schema = state.tree.schema }) catch |err| {
        std.debug.print("fuzz tree: the written tree does not compose ({t})\n", .{err});

        return mismatch(state, "the output does not compose", 0);
    };

    try comment_texts_check(state, output);

    const again = try document_written(&state.reparsed.document, options, &state.output_again);
    const plain_unstable = state.tree.comment_count == 0 and !std.mem.eql(u8, output, again);

    if (plain_unstable) {
        std.debug.print("--- written ---\n{f}\n--- end ---\n", .{std.zig.fmtString(output)});
        std.debug.print("--- again ---\n{f}\n--- end ---\n", .{std.zig.fmtString(again)});

        return mismatch(state, "the output is no fixpoint", 0);
    }

    state.counters.getPtr(.fixpoint_compared).* += 1;

    try copy_check(state, options, again);

    if (state.tree.comment_count > 0) try comment_round_check(state, options, again);
}

fn comment_texts_check(state: *State, output: []const u8) !void {
    assert(state.reparsed.document.comment_count <= comments_max);
    assert(output.len <= output_bytes_max);

    const document = &state.reparsed.document;
    const model = &state.model;
    var expected: u32 = 0;

    for (model.nodes[1..model.node_count]) |*node| {
        if (node.detached) continue;

        for (node.comments) |comments| {
            for (model.comment_lines[comments.first..][0..comments.count]) |line| {
                if (line.text.length == 0) continue;

                state.comment_texts[expected] = span_text(model, line.text);
                expected += 1;
            }
        }
    }

    var found: u32 = 0;

    for (document.storage.comments[0..document.comment_count]) |*slot| {
        const known = for (state.comment_texts[0..expected]) |text| {
            if (std.mem.eql(u8, text, slot.text)) break true;
        } else false;

        if (!known) {
            std.debug.print("fuzz tree: the output holds {s}\n", .{slot.text});
            std.debug.print("--- written ---\n{f}\n--- end ---\n", .{std.zig.fmtString(output)});

            return mismatch(state, "the output holds a comment the model lacks", 0);
        }

        found += 1;
    }

    if (found != expected) {
        std.debug.print("--- written ---\n{f}\n--- end ---\n", .{std.zig.fmtString(output)});

        return mismatch(state, "the output lost a comment", 0);
    }

    if (expected > 0) state.counters.getPtr(.comment_compared).* += 1;
}

fn comment_round_check(state: *State, options: *const Writer.Options, again: []const u8) !void {
    assert(state.tree.comment_count > 0);
    assert(again.len <= output_bytes_max);

    state.reparsed.parse(again, .{ .schema = state.tree.schema }) catch |err| {
        std.debug.print("fuzz tree: a commented rewrite does not compose ({t})\n", .{err});

        return mismatch(state, "a commented rewrite does not compose", 0);
    };

    const twice = try document_written(&state.reparsed.document, options, &state.output_kept);
    if (std.mem.eql(u8, again, twice)) return;

    std.debug.print("--- again ---\n{f}\n--- end ---\n", .{std.zig.fmtString(again)});
    std.debug.print("--- twice ---\n{f}\n--- end ---\n", .{std.zig.fmtString(twice)});

    return mismatch(state, "a commented rewrite misses the fixed point", 0);
}

fn copy_check(state: *State, options: *const Writer.Options, output: []const u8) !void {
    assert(output.len <= output_bytes_max);
    assert(options.indent >= 1);

    const document = &state.reparsed.document;

    state.check.init(state.check_storage.storage(), .{ .schema = state.tree.schema });

    for (0..document.root_count()) |index| {
        const root = document.root(@intCast(index));

        const content: Tree.Content = .{
            .copy = .{ .document = document, .merge = .ignored, .node = root },
        };

        _ = try state.check.root_append(content);
    }

    tree_module.audit(&state.check);

    const written = try tree_written(&state.check, options, &state.output_again);
    if (std.mem.eql(u8, output, written)) return;

    std.debug.print("--- copy ---\n{f}\n--- end ---\n", .{std.zig.fmtString(written)});

    return mismatch(state, "a copy of the output writes differently", 0);
}

fn json_check(state: *State) !void {
    assert(state.model.node_count == state.tree.node_count);
    assert(state.json_left.len == json_bytes_max);

    if (json_substitution_is(state)) {
        state.counters.getPtr(.json_skipped).* += 1;

        return;
    }

    const options = json_options_choose(state);

    const pair: JSONPair = .{
        .left = tree_json(&state.tree, &options, &state.json_left),
        .right = document_json(&state.reparsed.document, &options, &state.json_right),
    };

    try json_compare(state, &pair);
}

fn json_substitution_is(state: *const State) bool {
    assert(state.model.node_count <= tree_records_max);
    assert(state.model.nodes[stream_index].kind == .stream);

    const model = &state.model;

    if (state.tree.schema != .json) return false;

    for (model.nodes[1..model.node_count]) |*node| {
        if (node.detached) continue;
        if (node.kind != .scalar) continue;
        if (node.text.length > 0) continue;
        if (node.anchor.length > 0) continue;
        if (node.tag.length > 0) continue;
        if (node.style != @backingInt(ScalarStyle.plain)) continue;
        if (model.nodes[node.parent].kind == .sequence) return true;
    }

    return false;
}

fn json_options_choose(state: *State) JSONOptions {
    assert(json_node_count_max > 64);
    assert(state.model.node_count >= 1);

    return .{
        .merge = if (chance(state, 2)) .applied else .ignored,
        .node_count_max = if (chance(state, 4)) 1 + below(state, 64) else json_node_count_max,
        .non_finite = if (chance(state, 2)) .null_value else .refused,
    };
}

fn tree_json(tree: *const Tree, options: *const JSONOptions, buffer: []u8) JSONResult {
    assert(options.node_count_max > 0);
    assert(buffer.len == json_bytes_max);

    var sink: std.Io.Writer = .fixed(buffer);

    tree.write_json(&sink, options.*) catch |err| return .{ .failure = err };

    return .{ .written = sink.buffered() };
}

fn document_json(document: *const Document, options: *const JSONOptions, buffer: []u8) JSONResult {
    assert(options.node_count_max > 0);
    assert(buffer.len == json_bytes_max);

    var sink: std.Io.Writer = .fixed(buffer);

    document.write_json(&sink, options.*) catch |err| return .{ .failure = err };

    return .{ .written = sink.buffered() };
}

fn json_compare(state: *State, pair: *const JSONPair) !void {
    assert(@backingInt(std.meta.activeTag(pair.left)) <= 1);
    assert(@backingInt(std.meta.activeTag(pair.right)) <= 1);

    switch (pair.left) {
        .failure => |failure| {
            const same = switch (pair.right) {
                .failure => |other| other == failure,
                .written => false,
            };

            if (!same) return json_mismatch(state, pair);

            state.counters.getPtr(.json_refused).* += 1;
        },
        .written => |written| {
            const same = switch (pair.right) {
                .failure => false,
                .written => |other| std.mem.eql(u8, written, other),
            };

            if (!same) return json_mismatch(state, pair);

            state.counters.getPtr(.json_compared).* += 1;
        },
    }
}

fn json_mismatch(state: *State, pair: *const JSONPair) error{TreeMismatch} {
    assert(@backingInt(std.meta.activeTag(pair.left)) <= 1);
    assert(@backingInt(std.meta.activeTag(pair.right)) <= 1);

    for ([_]*const JSONResult{ &pair.left, &pair.right }) |result| {
        switch (result.*) {
            .failure => |failure| std.debug.print("--- json ---\n{t}\n", .{failure}),
            .written => |written| {
                std.debug.print("--- json ---\n{f}\n", .{std.zig.fmtString(written)});
            },
        }
    }

    return mismatch(state, "the JSON differs", 0);
}

fn paths_check(state: *State) !void {
    assert(state.model.node_count == state.tree.node_count);
    assert(path_count_max > 0);

    if (state.model.nodes[stream_index].count == 0) return;

    for (0..path_count_max) |_| try path_check(state);
}

fn path_check(state: *State) !void {
    assert(state.model.nodes[stream_index].count > 0);
    assert(state.path_texts.len == path_segment_count_max);

    const model = &state.model;
    const root_position = below(state, model.nodes[stream_index].count);
    const start = child_at(model, .{ .container = stream_index, .position = root_position });

    var segments: [path_segment_count_max][]const u8 = undefined;
    var count: u32 = 0;
    var cursor = start;

    for (0..path_segment_count_max) |position| {
        const step = step_choose(state, cursor, &state.path_texts[position]) orelse break;

        segments[count] = step.text;
        count += 1;

        if (step.next == none) break;

        cursor = step.next;
    }

    const expected = model_path_find(model, start, segments[0..count]);
    const actual = state.tree.path_find(@fromBackingInt(start), segments[0..count]);
    const found = if (actual) |node| @backingInt(node) else none;

    state.counters.getPtr(.path_walked).* += 1;

    if (found == expected) return;

    std.debug.print("fuzz tree: the path from {d} found {d}, the model {d}\n", .{
        start,
        found,
        expected,
    });

    return mismatch(state, "the paths differ", start);
}

fn step_choose(state: *State, node: u32, buffer: *[path_segment_bytes_max]u8) ?Step {
    assert(node > stream_index);
    assert(buffer.len == path_segment_bytes_max);

    const model = &state.model;
    const home = resolved_of(model, node);

    switch (model.nodes[home].kind) {
        .alias, .stream => unreachable,
        .mapping => return mapping_step_choose(state, home),
        .scalar => {
            if (chance(state, 2)) return null;
            return .{ .next = none, .text = "x" };
        },
        .sequence => {
            const count = model.nodes[home].count;
            const position = below(state, count + 2);
            const cell: Cell = .{ .container = home, .position = position };
            const next = if (position < count) child_at(model, cell) else none;

            const text = std.mem.print(buffer, "{d}", .{position}) catch |err| switch (err) {
                error.NoSpaceLeft => unreachable,
            };

            return .{ .next = next, .text = text };
        },
    }
}

fn mapping_step_choose(state: *State, mapping: u32) Step {
    assert(state.model.nodes[mapping].kind == .mapping);
    assert(keys.len > 0);

    const model = &state.model;
    const pair_count = @divExact(model.nodes[mapping].count, 2);
    if (pair_count == 0) return .{ .next = none, .text = keys[below(state, keys.len)] };
    if (chance(state, 4)) return .{ .next = none, .text = keys[below(state, keys.len)] };

    const position = 2 * below(state, pair_count);
    const key = child_at(model, .{ .container = mapping, .position = position });
    const home = &model.nodes[resolved_of(model, key)];
    if (home.kind != .scalar) return .{ .next = none, .text = "x" };
    return .{ .next = model.nodes[key].next, .text = span_text(model, home.text) };
}

fn model_path_find(model: *const Model, start: u32, segments: []const []const u8) u32 {
    assert(start > stream_index);
    assert(segments.len <= path_segment_count_max);

    var node = start;

    for (segments) |segment| {
        node = model_step(model, node, segment);

        if (node == none) return none;
    }

    return node;
}

fn model_step(model: *const Model, node: u32, segment: []const u8) u32 {
    assert(node > stream_index);
    assert(segment.len <= tree_text_bytes_max);

    const home = resolved_of(model, node);

    switch (model.nodes[home].kind) {
        .alias, .stream => unreachable,
        .mapping => return member_of(model, home, segment),
        .scalar => return none,
        .sequence => {
            const position = std.fmt.parseInt(u32, segment, 10) catch |err| switch (err) {
                error.InvalidCharacter, error.Overflow => return none,
            };

            if (position >= model.nodes[home].count) return none;
            return child_at(model, .{ .container = home, .position = position });
        },
    }
}

fn sink_check(state: *State, options: *const Writer.Options, output: []const u8) !void {
    assert(output.len <= output_bytes_max);
    assert(options.indent >= 1);

    if (output.len == 0) return;

    const size = below(state, @intCast(output.len));

    var sink: std.Io.Writer = .fixed(state.output_again[0..size]);

    state.tree.write(&sink, options.*) catch |err| switch (err) {
        error.WriteFailed => {
            state.counters.getPtr(.sink_refused).* += 1;

            return;
        },
    };

    return mismatch(state, "a write past the end of the sink succeeded", 0);
}

fn applied_check(state: *State) !void {
    assert(state.sources.len == 2);
    assert(state.applied_storage.records.len == applied_records_max);

    const document = &state.sources[below(state, 2)].document;

    state.applied.init(state.applied_storage.storage(), .{ .schema = document.schema });

    for (0..document.root_count()) |index| {
        const root = document.root(@intCast(index));

        const content: Tree.Content = .{
            .copy = .{ .document = document, .merge = .applied, .node = root },
        };

        _ = state.applied.root_append(content) catch |err| return applied_refused(state, err);
    }

    tree_module.audit(&state.applied);

    const non_finite: JSONOptions.NonFinite = if (chance(state, 2)) .null_value else .refused;

    const ignored: JSONOptions = .{
        .merge = .ignored,
        .node_count_max = json_node_count_max,
        .non_finite = non_finite,
    };

    const applied: JSONOptions = .{
        .merge = .applied,
        .node_count_max = json_node_count_max,
        .non_finite = non_finite,
    };

    const pair: JSONPair = .{
        .left = tree_json(&state.applied, &ignored, &state.json_left),
        .right = document_json(document, &applied, &state.json_right),
    };

    try json_compare(state, &pair);

    state.counters.getPtr(.applied_compared).* += 1;
}

fn applied_refused(state: *State, err: Tree.EditError) void {
    assert(@errorName(err).len > 0);
    assert(state.applied.node_count <= applied_records_max);

    state.applied_refusals.getPtr(refusal_of(err)).* += 1;
    state.counters.getPtr(.applied_skipped).* += 1;
}

fn summary_print(state: *const State) void {
    assert(state.operations.values.len == 7);
    assert(state.refusals.values.len == 12);

    for (std.enums.values(Operation)) |operation| {
        std.debug.print("  operation {t}: {d}\n", .{ operation, state.operations.get(operation) });
    }

    for (std.enums.values(Refusal)) |refusal| {
        std.debug.print("  outcome {t}: {d}\n", .{ refusal, state.refusals.get(refusal) });
    }

    for (std.enums.values(Refusal)) |refusal| {
        const count = state.applied_refusals.get(refusal);

        if (count > 0) std.debug.print("  applied copy refused {t}: {d}\n", .{ refusal, count });
    }

    for (std.enums.values(Counter)) |counter| {
        std.debug.print("  {t}: {d}\n", .{ counter, state.counters.get(counter) });
    }
}

fn summary_check(state: *const State, events_max: u32) !void {
    assert(events_max > 0);
    assert(state.counters.values.len == @typeInfo(Counter).@"enum".field_names.len);

    if (events_max < campaign_events_min) return;

    for (std.enums.values(Operation)) |operation| {
        if (state.operations.get(operation) == 0) {
            std.debug.print("fuzz tree: no {t} was accepted\n", .{operation});

            return error.CoverageMissing;
        }
    }

    for (std.enums.values(Refusal)) |refusal| {
        if (state.refusals.get(refusal) == 0) {
            std.debug.print("fuzz tree: no edit ended {t}\n", .{refusal});

            return error.CoverageMissing;
        }
    }

    for (std.enums.values(Counter)) |counter| {
        if (state.counters.get(counter) == 0) {
            std.debug.print("fuzz tree: {t} was never reached\n", .{counter});

            return error.CoverageMissing;
        }
    }
}
