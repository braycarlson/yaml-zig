const std = @import("std");

const document_module = @import("document.zig");
const fuzz_model = @import("fuzz_model.zig");
const json_writer = @import("json_writer.zig");
const parser_module = @import("parser.zig");
const round_trip = @import("round_trip.zig");
const scanner_module = @import("scanner.zig");
const schema_module = @import("schema.zig");
const storage_module = @import("storage.zig");
const tree_fuzz = @import("tree_fuzz.zig");
const writer_fuzz = @import("writer_fuzz.zig");
const writer_module = @import("writer.zig");

const assert = std.debug.assert;

const Position = parser_module.Position;
const Document = document_module.Document;
const Event = parser_module.Event;
const JSONOptions = json_writer.JSONOptions;
const Mark = Event.Mark;
const Node = document_module.Node;
const Parser = parser_module.Parser;
const Prng = std.Random.DefaultPrng;
const Writer = writer_module.Writer;

const Fuzzer = enum {
    model,
    mutation,
    smoke,
    tree,
    writer,
};

const Options = struct {
    events_max: u32,
    seed: u64,
};

const Arguments = struct {
    corpus_path: []const u8,
    events_text: []const u8,
    fuzzer: Fuzzer,
    seed_text: []const u8,
};

const arguments_bytes_max: u32 = 4096;
const corpus_bytes_max: u32 = 2 * 1024 * 1024;
const corpus_count_max: u32 = 1024;
const depth_tracked_max: u32 = 1024;
const events_max_default: u32 = 20_000;
const events_max_smoke: u32 = 512;
const flat_count_max: u32 = 512;
const flat_frame_count_max: u32 = 64;
const json_node_count_limit: u32 = 1 << 20;
const json_pair_count_max: u32 = 1 << 16;
const json_values_bytes_max: u32 = 32 * 1024 * 1024;
const mutation_count_max: u32 = 8;
const output_bytes_max: u32 = 4 * source_bytes_max;
const path_bytes_max: u32 = 1024;
const path_depth_max: u32 = 64;
const seed_smoke: u64 = 0x5eed;
const source_bytes_max: u32 = fuzz_model.source_bytes_max;

const usage_text = "usage: fuzz <model|mutation|smoke|tree|writer> [seed|random] [events] " ++
    "[yaml-test-suite data directory]\n";

const capacity: document_module.Capacity = .{
    .anchor_count_max = 256,
    .comment_count_max = null,
    .node_count_max = 64 * 1024,
    .text_bytes_max = 2 * source_bytes_max,
};

const capacity_written: document_module.Capacity = .{
    .anchor_count_max = capacity.anchor_count_max,
    .comment_count_max = null,
    .node_count_max = capacity.node_count_max,
    .text_bytes_max = 2 * output_bytes_max,
};

comptime {
    assert(events_max_smoke < events_max_default);
    assert(fuzz_model.entry_count_max < capacity.node_count_max);
    assert(source_bytes_max < corpus_bytes_max);
}

const FuzzStorage = storage_module.StorageType(capacity);
const WrittenStorage = storage_module.StorageType(capacity_written);

const Corpus = struct {
    bytes: [corpus_bytes_max]u8,
    count: u32,
    ends: [corpus_count_max]u32,
    used: u32,

    fn add(corpus: *Corpus, text: []const u8) bool {
        assert(corpus.count <= corpus_count_max);
        assert(corpus.used <= corpus_bytes_max);
        assert(text.len <= std.math.maxInt(u32));

        if (corpus.count == corpus_count_max) return false;
        if (text.len > source_bytes_max) return true;
        if (text.len > corpus_bytes_max - corpus.used) return false;

        @memcpy(corpus.bytes[corpus.used..][0..text.len], text);
        corpus.used += @intCast(text.len);
        corpus.ends[corpus.count] = corpus.used;
        corpus.count += 1;

        return true;
    }

    fn get(corpus: *const Corpus, index: u32) []const u8 {
        assert(index < corpus.count);
        assert(corpus.ends[index] <= corpus.used);

        const start = if (index == 0) 0 else corpus.ends[index - 1];
        return corpus.bytes[start..corpus.ends[index]];
    }
};

const JSONCounts = struct {
    compared: u32,
    merged: u32,
    past_sink: u32,
    refusals: std.EnumArray(Refusal, u32),
};

const Refusal = enum {
    depth,
    expansion,
    float,
    key,
    merge_invalid,
    merges_exceeded,
};

const JSONPair = struct {
    node: Node,
    value: *const std.json.Value,
};

const FlatEntry = struct {
    key: []const u8,
    value: Node,
};

const FlatFrame = struct {
    expanded: bool,
    mapping: Node,
};

const PathStep = struct {
    index: u32,
    node: Node,
    segment: []const u8,
};

const State = struct {
    corpus: Corpus,
    document: Document,
    json_counts: JSONCounts,
    json_flat: [flat_count_max]FlatEntry,
    json_pairs: [json_pair_count_max]JSONPair,
    json_values: [json_values_bytes_max]u8,
    model: fuzz_model.Model,
    output: [output_bytes_max]u8,
    parser: Parser,
    parser_text: [capacity.text_bytes_max]u8,
    path_count: u32,
    prng: Prng,
    ratio_max: u64,
    rewritten: [output_bytes_max]u8,
    source: [source_bytes_max]u8,
    source_count: u32,
    storage: FuzzStorage,
    write_count: u32,
    write_skip_count: u32,
    written: Document,
    written_storage: WrittenStorage,
};

const WriteCheck = enum {
    equivalence,
    idempotence,
};

const WriteFailure = struct {
    source: []const u8,
    written: []const u8,
};

const Level = struct {
    child_count: u32,
    mapping: bool,
};

const Summary = struct {
    depth: u32,
    document_count: u32,
    document_open: bool,
    event_count: u32,
    node_count: u32,
    root_count: u32,
    stack: [depth_tracked_max]Level,
};

const DiagnosticPair = struct {
    composer: Position,
    parser: Position,
};

const Rejection = struct {
    diagnostic: Position,
    err: parser_module.Parser.Error,
};

const Outcome = union(enum) {
    accepted: u32,
    rejected: Rejection,
};

const corpus_embedded = [_][]const u8{
    \\american:
    \\  - Boston Red Sox
    \\  - Detroit Tigers
    \\national:
    \\  - New York Mets
    \\  - Chicago Cubs
    \\
    ,
    \\---
    \\hr: # 1998 hr ranking
    \\  - Mark McGwire
    \\  - &SS Sammy Sosa
    \\rbi:
    \\  - *SS # Subsequent occurrence
    \\  - Ken Griffey
    \\
    ,
    \\? - Detroit Tigers
    \\  - Chicago cubs
    \\: - 2001-07-23
    \\
    \\? [ New York Yankees,
    \\    Atlanta Braves ]
    \\: [ 2001-07-02, 2001-08-12,
    \\    2001-08-14 ]
    \\
    ,
    \\%TAG ! tag:clarkevans.com,2002:
    \\--- !shape
    \\- !circle
    \\  center: &ORIGIN {x: 73, y: 129}
    \\  radius: 7
    \\- !line
    \\  start: *ORIGIN
    \\  finish: { x: 89, y: 102 }
    \\- !label
    \\  start: *ORIGIN
    \\  color: 0xFFEEBB
    \\  text: Pretty vector drawing.
    \\
    ,
    \\literal: |
    \\  some
    \\  text
    \\folded: >-
    \\  some
    \\
    \\  text
    \\keep: |+2
    \\   indented
    \\
    \\strip: >-
    \\
    \\...
    \\
    ,
    \\unicode: "Sosa did fine.☺ \x0d\x0a is \r\n \U0001F600"
    \\control: "\b1998\t1999\t2000\n"
    \\single: '"Howdy!" he cried. ''quoted'''
    \\folded: "a
    \\  b \
    \\  c"
    \\tie-fighter: '|\-*-/|'
    \\
    ,
    \\{ "json": [1, 2.5, "three", null, true],
    \\  plain: text, ? explicit : value, "adjacent":value,
    \\  [flow, key]: {nested: [a, b: c, {}]} }
    \\
    ,
    \\--- !!map
    \\? !!str "key"
    \\: !<tag:yaml.org,2002:seq> [ ! a, !local b ]
    \\--- &anchor
    \\- value
    \\...
    \\%YAML 1.2
    \\---
    \\plain multi
    \\  line scalar
    \\
    ,
    \\- - nested
    \\  - sequence
    \\- key: value
    \\  other: value
    \\-
    \\-   ? complex
    \\    : pair
    \\
    ,
    "key:\tvalue\r\nlist:\r\n- a\r\n-\tb\r\n",
    "\xef\xbb\xbfbom: true\n# comment only line\n...\n",
    \\a: &x [1, 2, 3]
    \\b: *x
    \\c: {*x : d}
    \\? |
    \\  block key
    \\: >
    \\  folded value
    \\e:
    \\f: ""
    \\
    ,
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
    \\
    ,
    \\numbers: [0x1F, 0o17, 0b101, 1_000, 190:20:30, 1:30.5, .inf, -.Inf, .nan, 1e999]
    \\words: [yes, No, on, y, ~, null, 2001-12-14, "=", <<]
    \\big: [123456789012345678901234567890123456789012, -0x1234567890abcdef1234567890abcdef1]
    \\
    ,
};

pub fn main(init: std.process.Init) !void {
    assert(init.minimal.args.vector.len < std.math.maxInt(u32));

    const vector = try init.minimal.args.toSlice(init.arena.allocator());
    const arguments = try arguments_parse(vector);
    const state = try init.gpa.create(State);
    defer init.gpa.destroy(state);

    state_reset(state);

    if (arguments.fuzzer == .smoke) return smoke_run(init.gpa, state, &arguments);

    if (arguments.corpus_path.len > 0) {
        try corpus_load(init.io, &state.corpus, arguments.corpus_path);
    }

    const options = try options_of(init.io, &arguments);

    try run(init.gpa, state, arguments.fuzzer, &options);
}

fn arguments_parse(vector: []const [:0]const u8) error{ArgumentsInvalid}!Arguments {
    assert(vector.len > 0);
    assert(vector.len < std.math.maxInt(u32));

    if (vector.len < 2) return usage();
    if (vector.len > 5) return usage();

    const fuzzer = std.meta.stringToEnum(Fuzzer, vector[1]) orelse return usage();

    return .{
        .corpus_path = if (vector.len == 5) vector[4] else "",
        .events_text = if (vector.len >= 4) vector[3] else "",
        .fuzzer = fuzzer,
        .seed_text = if (vector.len >= 3) vector[2] else "",
    };
}

fn state_reset(state: *State) void {
    assert(corpus_embedded.len < corpus_count_max);
    assert(state.source.len == source_bytes_max);

    state.corpus.count = 0;
    state.corpus.used = 0;
    state.ratio_max = 0;

    for (corpus_embedded) |text| {
        const added = state.corpus.add(text);

        assert(added);
    }
}

fn smoke_run(gpa: std.mem.Allocator, state: *State, arguments: *const Arguments) !void {
    assert(arguments.fuzzer == .smoke);
    assert(state.corpus.count == corpus_embedded.len);

    if (arguments.seed_text.len > 0) return usage();

    for (std.enums.values(Fuzzer)) |each| {
        if (each == .smoke) continue;

        try run(gpa, state, each, &.{ .events_max = events_max_smoke, .seed = seed_smoke });
    }
}

fn options_of(io: std.Io, arguments: *const Arguments) error{ArgumentsInvalid}!Options {
    assert(arguments.fuzzer != .smoke);
    assert(arguments.seed_text.len <= arguments_bytes_max);

    const seed_text = arguments.seed_text;
    const seed_absent = seed_text.len == 0 or std.mem.eql(u8, seed_text, "random");
    const events_text = arguments.events_text;
    const events_absent = events_text.len == 0;

    return .{
        .events_max = if (events_absent) events_max_default else try events_parse(events_text),
        .seed = if (seed_absent) seed_random(io) else try seed_parse(seed_text),
    };
}

fn usage() error{ArgumentsInvalid} {
    assert(usage_text.len > 0);
    assert(usage_text[usage_text.len - 1] == '\n');

    std.debug.print("{s}", .{usage_text});

    return error.ArgumentsInvalid;
}

fn seed_parse(text: []const u8) error{ArgumentsInvalid}!u64 {
    assert(text.len > 0);
    assert(text.len <= arguments_bytes_max);

    const result = std.fmt.parseInt(u64, text, 10) catch return usage();
    return result;
}

fn events_parse(text: []const u8) error{ArgumentsInvalid}!u32 {
    assert(text.len > 0);
    assert(text.len <= arguments_bytes_max);

    const result = std.fmt.parseInt(u32, text, 10) catch return usage();
    if (result == 0) return usage();
    return result;
}

fn seed_random(io: std.Io) u64 {
    var result: u64 = 0;

    io.random(std.mem.asBytes(&result));

    return result;
}

fn run(gpa: std.mem.Allocator, state: *State, fuzzer: Fuzzer, options: *const Options) !void {
    assert(fuzzer != .smoke);
    assert(options.events_max > 0);

    if (fuzzer == .tree) {
        return tree_fuzz.main(gpa, .{ .events_max = options.events_max, .seed = options.seed });
    }

    if (fuzzer == .writer) {
        return writer_fuzz.main(gpa, .{ .events_max = options.events_max, .seed = options.seed });
    }

    std.debug.print("fuzz {t}: seed={d} events_max={d} corpus={d}\n", .{
        fuzzer,
        options.seed,
        options.events_max,
        state.corpus.count,
    });

    state.json_counts = .{
        .compared = 0,
        .merged = 0,
        .past_sink = 0,
        .refusals = .initFill(0),
    };

    state.path_count = 0;
    state.prng = .init(options.seed);
    state.write_count = 0;
    state.write_skip_count = 0;

    for (0..options.events_max) |_| {
        switch (fuzzer) {
            .model => try model_event(state),
            .mutation => try mutation_event(state),
            .smoke, .tree, .writer => unreachable,
        }
    }

    run_report(state, fuzzer);

    if (options.events_max < events_max_default) return;
    if (state.json_counts.compared == 0) return error.JSONNeverCompared;
    if (state.json_counts.refusals.get(.expansion) == 0) return error.ExpansionNeverRefused;
    if (state.path_count == 0) return error.PathsNeverWalked;
    if (fuzzer == .model) return;
    if (state.corpus.count > corpus_embedded.len) return;
    if (state.json_counts.merged == 0) return error.MergesNeverCompared;
    if (state.json_counts.refusals.get(.merge_invalid) == 0) return error.MergeNeverRefused;
}

fn run_report(state: *const State, fuzzer: Fuzzer) void {
    assert(fuzzer == .model or fuzzer == .mutation);
    assert(state.ratio_max <= 16 * 16);

    std.debug.print("fuzz {t}: passed, at most {d}/16 events per source byte\n", .{
        fuzzer,
        state.ratio_max,
    });

    std.debug.print("fuzz {t}: {d} documents written and read back, {d} past the sink\n", .{
        fuzzer,
        state.write_count,
        state.write_skip_count,
    });

    std.debug.print("fuzz {t}: {d} documents written as JSON and compared ({d} merged " ++
        "mappings), {d} past the sink; {d} path walks\n", .{
        fuzzer,
        state.json_counts.compared,
        state.json_counts.merged,
        state.json_counts.past_sink,
        state.path_count,
    });

    for (std.enums.values(Refusal)) |refusal| {
        const count = state.json_counts.refusals.get(refusal);

        std.debug.print("  refused {t}: {d}\n", .{ refusal, count });
    }
}

fn corpus_load(io: std.Io, corpus: *Corpus, root: []const u8) !void {
    assert(root.len > 0);
    assert(corpus.count <= corpus_count_max);

    var directory = try std.Io.Dir.cwd().openDir(io, root, .{ .iterate = true });
    defer directory.close(io);

    var iterator = directory.iterate();

    for (0..corpus_count_max * 4) |_| {
        const entry = try iterator.next(io) orelse return;
        if (entry.kind != .directory) continue;

        const room = try corpus_case_load(io, &directory, entry.name, corpus);
        if (!room) return;
    }
}

fn corpus_case_load(
    io: std.Io,
    directory: *const std.Io.Dir,
    name: []const u8,
    corpus: *Corpus,
) !bool {
    assert(name.len > 0);
    assert(corpus.count <= corpus_count_max);

    var case_directory = try directory.openDir(io, name, .{ .iterate = true });
    defer case_directory.close(io);

    if (!try corpus_file_load(io, &case_directory, "in.yaml", corpus)) return false;

    var iterator = case_directory.iterate();

    for (0..corpus_count_max) |_| {
        const entry = try iterator.next(io) orelse return true;
        if (entry.kind != .directory) continue;

        var path: [path_bytes_max]u8 = undefined;
        const nested = try std.mem.print(&path, "{s}/in.yaml", .{entry.name});
        if (!try corpus_file_load(io, &case_directory, nested, corpus)) return false;
    }

    return true;
}

fn corpus_file_load(
    io: std.Io,
    directory: *const std.Io.Dir,
    path: []const u8,
    corpus: *Corpus,
) !bool {
    assert(path.len > 0);
    assert(corpus.used <= corpus_bytes_max);

    var buffer: [source_bytes_max]u8 = undefined;

    const content = directory.readFile(io, path, &buffer) catch |err| switch (err) {
        error.FileNotFound => return true,
        else => |other| return other,
    };

    return corpus.add(content);
}

fn model_event(state: *State) !void {
    assert(state.corpus.count > 0);
    assert(state.source.len == source_bytes_max);

    const seed = state.prng.random().int(u64);

    var prng = Prng.init(seed);

    const source = try state.model.generate(&prng);

    state.document.parse(state.storage.storage(), source, .{ .schema = .core }) catch |err| {
        std.debug.print("model: generated input rejected with {t} at {d}:{d}, seed {d}\n", .{
            err,
            state.document.diagnostic.line,
            state.document.diagnostic.column,
            seed,
        });

        source_print(source);

        return err;
    };

    state.model.compare(&state.document) catch |err| {
        std.debug.print("model: composed document differs from the model, seed {d}\n", .{seed});
        source_print(source);

        return err;
    };

    const accepted = try input_check(state, source);

    assert(accepted);

    try write_check(state, &prng, .equivalence);
    try paths_check(state, &prng);
    try json_check(state, &prng);
}

fn mutation_event(state: *State) !void {
    assert(state.corpus.count > 0);
    assert(state.source.len == source_bytes_max);

    const random = state.prng.random();
    const choice = random.uintLessThan(u32, state.corpus.count + 1);

    if (choice == state.corpus.count) {
        source_set(state, try state.model.generate(&state.prng));
    } else {
        source_set(state, state.corpus.get(choice));
    }

    const mutations = random.uintAtMost(u32, mutation_count_max);

    for (0..mutations) |_| source_mutate(state);

    const accepted = try input_check(state, state.source[0..state.source_count]);
    if (!accepted) return;

    try write_check(state, &state.prng, .idempotence);
    try paths_check(state, &state.prng);
    try json_check(state, &state.prng);
}

fn write_check(state: *State, prng: *Prng, check: WriteCheck) !void {
    assert(state.document.composer.frame_count == 0);
    assert(state.output.len == output_bytes_max);

    const options = write_options_choose(prng);

    var sink: std.Io.Writer = .fixed(&state.output);

    state.document.write(&sink, options) catch |err| switch (err) {
        error.WriteFailed => {
            state.write_skip_count += 1;

            return;
        },
    };

    const written = sink.buffered();
    const written_storage = state.written_storage.storage();

    state.written.parse(written_storage, written, .{ .schema = .core }) catch |err| {
        std.debug.print("write: the written bytes do not parse ({t} at {d}:{d})\n", .{
            err,
            state.written.diagnostic.line,
            state.written.diagnostic.column,
        });

        write_failure_print(.{ .source = state.document.source, .written = written });

        return err;
    };

    const documents: round_trip.Documents = .{
        .original = &state.document,
        .written = &state.written,
    };

    const difference = round_trip.documents_equivalent(documents, .{
        .layout = options.layout,
        .style_exact = options.layout == .preserve,
        .version_directive = options.version_directive,
    });

    if (difference) |reason| {
        std.debug.print("write: {s}\n", .{reason});
        write_failure_print(.{ .source = state.document.source, .written = written });

        return error.WriteDiffers;
    }

    state.write_count += 1;

    if (check == .idempotence) try idempotence_check(state, written, &options);
}

fn idempotence_check(state: *State, written: []const u8, options: *const Writer.Options) !void {
    assert(written.len <= output_bytes_max);
    assert(options.indent >= 1);

    var sink: std.Io.Writer = .fixed(&state.rewritten);

    try state.written.write(&sink, options.*);

    if (!std.mem.eql(u8, written, sink.buffered())) {
        std.debug.print("write: a second write differs\n", .{});
        write_failure_print(.{ .source = written, .written = sink.buffered() });

        return error.WriteUnstable;
    }
}

fn paths_check(state: *State, prng: *Prng) !void {
    assert(state.document.composer.frame_count == 0);
    assert(path_depth_max > 0);

    const document = &state.document;

    var segments: [path_depth_max][]const u8 = undefined;
    var digits: [path_depth_max][16]u8 = undefined;

    for (0..document.root_count()) |index| {
        const root = document.root(@intCast(index));

        var node = root;
        var depth: u32 = 0;

        for (0..path_depth_max - 1) |_| {
            const found = document.path_find(root, segments[0..depth]);

            try std.testing.expectEqual(@as(?Node, node), found);

            const step = path_step(document, prng, node, &digits[depth]) orelse break;

            if (document.kind_of(node) == .sequence) {
                segments[depth] = path_index_past(document, node, &digits[depth + 1]);

                const past = document.path_find(root, segments[0 .. depth + 1]);
                const item = document.item(node, step.index);

                try std.testing.expectEqual(@as(?Node, null), past);
                try std.testing.expectEqual(@as(?Node, step.node), item);
            }

            segments[depth] = step.segment;
            node = step.node;
            depth += 1;
        }

        state.path_count += 1;
    }
}

fn path_step(document: *const Document, prng: *Prng, node: Node, digits: *[16]u8) ?PathStep {
    assert(@backingInt(node) < document.node_count);
    assert(digits.len == 16);

    const count = document.count_of(node);
    if (count == 0) return null;

    const choice = prng.random().uintLessThan(u32, count);

    switch (document.kind_of(node)) {
        .mapping => {
            var entries = document.entries(node);

            for (0..choice) |_| _ = entries.next();

            const entry = entries.next() orelse unreachable;
            if (document.kind_of(entry.key) != .scalar) return null;

            const segment = document.text_of(entry.key).?;
            return .{ .index = choice, .node = entry.value, .segment = segment };
        },
        .scalar => unreachable,
        .sequence => {
            var items = document.items(node);

            for (0..choice) |_| _ = items.next();

            const item = items.next() orelse unreachable;

            const segment = std.mem.print(digits, "{d}", .{choice}) catch |err| switch (err) {
                error.NoSpaceLeft => unreachable,
            };

            return .{ .index = choice, .node = item, .segment = segment };
        },
    }
}

fn path_index_past(document: *const Document, sequence: Node, digits: *[16]u8) []const u8 {
    assert(document.kind_of(sequence) == .sequence);
    assert(digits.len == 16);

    const count = document.count_of(sequence);

    const result = std.mem.print(digits, "{d}", .{count}) catch |err| switch (err) {
        error.NoSpaceLeft => unreachable,
    };

    assert(result.len > 0);

    return result;
}

fn json_check(state: *State, prng: *Prng) !void {
    assert(state.document.composer.frame_count == 0);
    assert(state.output.len == output_bytes_max);

    const random = prng.random();
    const document = &state.document;
    const schemas = std.enums.values(schema_module.Schema);

    const options: JSONOptions = .{
        .merge = if (random.boolean()) .applied else .ignored,
        .node_count_max = json_bound_choose(prng, document.node_count),
        .non_finite = if (random.boolean()) .null_value else .refused,
    };

    document.schema = schemas[random.uintLessThan(u32, schemas.len)];
    defer document.schema = .core;

    var sink: std.Io.Writer = .fixed(&state.output);

    document.write_json(&sink, options) catch |err| {
        return json_refusal_check(state, &options, &sink, err);
    };

    try json_lines_compare(state, &options, sink.buffered());

    state.json_counts.compared += 1;
}

fn json_bound_choose(prng: *Prng, records: u32) u32 {
    assert(records <= capacity.node_count_max);
    assert(capacity.node_count_max < json_node_count_limit);

    const random = prng.random();
    if (random.uintLessThan(u32, 8) > 0) return json_node_count_limit;

    const result = 1 + random.uintAtMost(u32, records);

    assert(result <= records + 1);

    return result;
}

fn json_refusal_check(
    state: *State,
    options: *const JSONOptions,
    sink: *const std.Io.Writer,
    err: JSONOptions.Error,
) !void {
    assert(options.node_count_max > 0);
    assert(sink.buffer.len == output_bytes_max);
    assert(@errorName(err).len > 0);

    const refusal: Refusal = switch (err) {
        error.WriteFailed => {
            state.json_counts.past_sink += 1;

            return;
        },
        error.DepthExceeded => .depth,
        error.ExpansionExceeded => .expansion,
        error.FloatNonFinite => .float,
        error.KeyInvalid => .key,
        error.MergeInvalid => .merge_invalid,
        error.MergesExceeded => .merges_exceeded,
    };

    switch (refusal) {
        .depth => {},
        .expansion => try json_expansion_check(state, options),
        .float => try std.testing.expect(options.non_finite == .refused),
        .key => try std.testing.expect(collection_key_has(&state.document)),
        .merge_invalid, .merges_exceeded => try std.testing.expect(options.merge == .applied),
    }

    try std.testing.expectEqual(@as(usize, 0), sink.buffered().len);

    state.json_counts.refusals.getPtr(refusal).* += 1;
}

fn json_expansion_check(state: *State, options: *const JSONOptions) !void {
    assert(options.node_count_max > 0);
    assert(options.node_count_max <= json_node_count_limit);

    var relaxed = options.*;
    var sink: std.Io.Writer = .fixed(&state.output);

    relaxed.node_count_max = json_node_count_limit;

    const document = &state.document;
    const pass = json_writer.Pass.count;

    const counted = json_writer.json_write(Document, pass, document, &sink, &relaxed) catch |err| {
        switch (err) {
            error.DepthExceeded,
            error.ExpansionExceeded,
            error.FloatNonFinite,
            error.KeyInvalid,
            error.MergeInvalid,
            error.MergesExceeded,
            => return,
            error.WriteFailed => unreachable,
        }
    };

    try std.testing.expect(counted > options.node_count_max);
    try std.testing.expectEqual(@as(usize, 0), sink.buffered().len);
}

fn collection_key_has(document: *const Document) bool {
    assert(document.composer.frame_count == 0);
    assert(document.node_count <= capacity.node_count_max);

    for (document.storage.nodes[0..document.node_count], 0..) |*record, index| {
        if (record.kind != .mapping) continue;

        const mapping: Node = @fromBackingInt(@as(u32, @intCast(index)));
        var entries = document.entries(mapping);

        for (0..record.link.count) |_| {
            const entry = entries.next() orelse break;
            if (document.kind_of(entry.key) != .scalar) return true;
        }
    }

    return false;
}

fn json_lines_compare(state: *State, options: *const JSONOptions, output: []const u8) !void {
    assert(options.node_count_max > 0);
    assert(output.len <= output_bytes_max);

    const document = &state.document;

    var values: std.heap.FixedBufferAllocator = .init(&state.json_values);
    var lines = std.mem.splitScalar(u8, output, '\n');

    for (0..document.root_count()) |index| {
        const line = lines.next() orelse return error.JSONLineMissing;

        const value = std.json.parseFromSliceLeaky(std.json.Value, values.allocator(), line, .{
            .duplicate_field_behavior = .@"error",
            .ignore_unknown_fields = false,
            .max_value_len = null,
            .allocate = .alloc_always,
            .parse_numbers = true,
        }) catch |err| switch (err) {
            error.OutOfMemory => return,
            else => |other| {
                std.debug.print("json: a written line does not parse ({t})\n", .{other});
                write_failure_print(.{ .source = document.source, .written = output });

                return other;
            },
        };

        try json_tree_compare(state, options, document.root(@intCast(index)), &value);
    }

    const rest = lines.next() orelse return error.JSONLineMissing;
    const beyond = lines.next();

    try std.testing.expectEqual(@as(usize, 0), rest.len);
    try std.testing.expectEqual(@as(?[]const u8, null), beyond);
}

fn json_tree_compare(
    state: *State,
    options: *const JSONOptions,
    root: Node,
    value: *const std.json.Value,
) !void {
    assert(@backingInt(root) < state.document.node_count);
    assert(options.node_count_max > 0);

    state.json_pairs[0] = .{ .node = root, .value = value };

    var count: u32 = 1;

    for (0..json_node_count_limit + 1) |_| {
        if (count == 0) return;

        count -= 1;

        const pair = state.json_pairs[count];

        count = json_pair_compare(state, options, &pair, count) catch |err| {
            std.debug.print("json: the output differs from the document at line {d}\n", .{
                state.document.position_of(pair.node).line,
            });

            source_print(state.document.source);

            return err;
        };
    }

    return error.JSONUnbounded;
}

fn json_pair_compare(
    state: *State,
    options: *const JSONOptions,
    pair: *const JSONPair,
    count: u32,
) !u32 {
    assert(@backingInt(pair.node) < state.document.node_count);
    assert(count < json_pair_count_max);

    const document = &state.document;

    switch (document.kind_of(pair.node)) {
        .mapping => {
            try std.testing.expect(pair.value.* == .object);

            if (options.merge == .applied) {
                const merged = merge_value_of(document, pair.node) != null;
                if (merged) return json_merged_push(state, pair, count);
            }

            return json_entries_push(state, pair, count);
        },
        .scalar => {
            try json_scalar_compare(document, pair);

            return count;
        },
        .sequence => {
            try std.testing.expect(pair.value.* == .array);

            const array = pair.value.array.items;

            try std.testing.expectEqual(@as(usize, document.count_of(pair.node)), array.len);

            var items = document.items(pair.node);
            var result = count;

            for (array) |*element| {
                const item = items.next() orelse break;

                if (result == json_pair_count_max) return error.JSONPairsExhausted;

                state.json_pairs[result] = .{ .node = item, .value = element };
                result += 1;
            }

            return result;
        },
    }
}

fn json_entries_push(state: *State, pair: *const JSONPair, count: u32) !u32 {
    assert(pair.value.* == .object);
    assert(count < json_pair_count_max);

    const document = &state.document;
    const object = &pair.value.object;

    try std.testing.expectEqual(@as(usize, document.count_of(pair.node)), object.count());

    var entries = document.entries(pair.node);
    var result = count;

    for (0..document.count_of(pair.node)) |_| {
        const entry = entries.next() orelse break;
        const key = document.text_of(entry.key) orelse return error.JSONKeyNotScalar;
        const value = object.getPtr(key) orelse return error.JSONKeyMissing;

        if (result == json_pair_count_max) return error.JSONPairsExhausted;

        state.json_pairs[result] = .{ .node = entry.value, .value = value };
        result += 1;
    }

    return result;
}

fn json_merged_push(state: *State, pair: *const JSONPair, count: u32) !u32 {
    assert(pair.value.* == .object);
    assert(count < json_pair_count_max);

    const flat_count = json_flatten(state, pair.node) orelse return count;
    const flat = state.json_flat[0..flat_count];
    const object = &pair.value.object;

    var distinct: u32 = 0;

    for (flat, 0..) |entry, index| {
        if (flat_key_find(flat[0..index], entry.key) == null) distinct += 1;
    }

    try std.testing.expectEqual(@as(usize, distinct), object.count());

    var iterator = object.iterator();
    var result = count;

    for (0..object.count()) |_| {
        const entry = iterator.next() orelse break;
        const node = flat_key_find(flat, entry.key_ptr.*) orelse return error.JSONKeyUnexpected;

        if (result == json_pair_count_max) return error.JSONPairsExhausted;

        state.json_pairs[result] = .{ .node = node, .value = entry.value_ptr };
        result += 1;
    }

    state.json_counts.merged += 1;

    return result;
}

fn json_flatten(state: *State, mapping: Node) ?u32 {
    assert(state.document.kind_of(mapping) == .mapping);
    assert(flat_frame_count_max > 1);

    const document = &state.document;

    var frames: [flat_frame_count_max]FlatFrame = undefined;
    var frame_count: u32 = 1;
    var flat_count: u32 = 0;

    frames[0] = .{ .expanded = false, .mapping = mapping };

    for (0..flat_count_max * flat_frame_count_max) |_| {
        if (frame_count == 0) return flat_count;

        frame_count -= 1;

        const frame = frames[frame_count];

        if (frame.expanded) {
            flat_count = flat_explicit_append(state, frame.mapping, flat_count) orelse return null;

            continue;
        }

        frames[frame_count] = .{ .expanded = true, .mapping = frame.mapping };
        frame_count += 1;

        const value = merge_value_of(document, frame.mapping) orelse continue;

        frame_count = flat_sources_push(document, value, &frames, frame_count) orelse return null;
    }

    return null;
}

fn flat_sources_push(
    document: *const Document,
    value: Node,
    frames: *[flat_frame_count_max]FlatFrame,
    frame_count: u32,
) ?u32 {
    assert(@backingInt(value) < document.node_count);
    assert(frame_count <= flat_frame_count_max);

    if (document.kind_of(value) == .mapping) {
        if (frame_count == frames.len) return null;

        frames[frame_count] = .{ .expanded = false, .mapping = value };

        const pushed = frame_count + 1;

        assert(pushed <= flat_frame_count_max);

        return pushed;
    }

    assert(document.kind_of(value) == .sequence);

    var items = document.items(value);
    var result = frame_count;

    for (0..document.count_of(value)) |_| {
        const item = items.next() orelse break;

        assert(document.kind_of(item) == .mapping);

        if (result == frames.len) return null;

        frames[result] = .{ .expanded = false, .mapping = item };
        result += 1;
    }

    assert(result - frame_count == document.count_of(value));

    return result;
}

fn flat_explicit_append(state: *State, mapping: Node, flat_count: u32) ?u32 {
    assert(state.document.kind_of(mapping) == .mapping);
    assert(flat_count <= flat_count_max);

    const document = &state.document;

    var entries = document.entries(mapping);
    var result = flat_count;

    for (0..document.count_of(mapping)) |_| {
        const entry = entries.next() orelse break;
        if (merge_key_is(document, entry.key)) continue;
        if (result == flat_count_max) return null;

        state.json_flat[result] = .{ .key = document.text_of(entry.key).?, .value = entry.value };
        result += 1;
    }

    return result;
}

fn flat_key_find(flat: []const FlatEntry, key: []const u8) ?Node {
    assert(flat.len <= flat_count_max);
    assert(key.len <= source_bytes_max);

    for (0..flat.len) |step| {
        const entry = flat[flat.len - 1 - step];
        if (std.mem.eql(u8, entry.key, key)) return entry.value;
    }

    return null;
}

fn merge_value_of(document: *const Document, mapping: Node) ?Node {
    assert(document.kind_of(mapping) == .mapping);
    assert(document.node_count > 0);

    var entries = document.entries(mapping);

    for (0..document.count_of(mapping)) |_| {
        const entry = entries.next() orelse break;
        if (merge_key_is(document, entry.key)) return entry.value;
    }

    return null;
}

fn merge_key_is(document: *const Document, key: Node) bool {
    assert(@backingInt(key) < document.node_count);
    assert(schema_module.tag_merge.len > 0);

    if (document.kind_of(key) != .scalar) return false;
    if (!std.mem.eql(u8, document.text_of(key).?, "<<")) return false;

    const tag = document.tag_of(key);
    if (tag.len > 0) return std.mem.eql(u8, tag, schema_module.tag_merge);
    return document.style_of(key).scalar == .plain;
}

fn json_scalar_compare(document: *const Document, pair: *const JSONPair) !void {
    assert(document.kind_of(pair.node) == .scalar);
    assert(@backingInt(pair.node) < document.node_count);

    const node = pair.node;
    const value = pair.value;
    const text = document.text_of(node).?;
    const tag = document.tag_of(node);
    const plain = document.style_of(node).scalar == .plain;

    const resolution: schema_module.Resolution = resolution: {
        if (tag.len > 0) break :resolution schema_module.tag_resolution_of(tag);
        if (!plain) break :resolution .string;

        break :resolution schema_module.resolution_of(text, document.schema);
    };

    switch (resolution) {
        .boolean => if (document.boolean_of(node)) |boolean| {
            return std.testing.expectEqual(std.json.Value{ .bool = boolean }, value.*);
        },
        .float => if (document.float_of(node)) |float| return json_float_compare(float, value),
        .integer => {
            if (document.integer_of(node)) |integer| {
                return std.testing.expectEqual(std.json.Value{ .integer = integer }, value.*);
            }

            if (value.* == .number_string) return json_digits_check(value.number_string);
        },
        .null_value => if (document.null_is(node)) return std.testing.expect(value.* == .null),
        .string => {},
    }

    try std.testing.expect(value.* == .string);
    try std.testing.expectEqualStrings(text, value.string);
}

fn json_float_compare(float: f64, value: *const std.json.Value) !void {
    assert(!std.math.isNan(float) or !std.math.isFinite(float));
    assert(json_node_count_limit > 0);

    if (!std.math.isFinite(float)) return std.testing.expect(value.* == .null);

    try std.testing.expect(value.* == .float);
    try std.testing.expectEqual(@as(u64, @bitCast(float)), @as(u64, @bitCast(value.float)));
}

fn json_digits_check(text: []const u8) !void {
    assert(text.len > 0);
    assert(text.len <= source_bytes_max);

    const digits = if (text[0] == '-') text[1..] else text;

    try std.testing.expect(digits.len > 18);
    try std.testing.expect(digits[0] != '0');

    for (digits) |byte| try std.testing.expect(std.ascii.isDigit(byte));
}

fn write_options_choose(prng: *Prng) Writer.Options {
    assert(writer_module.depth_max > 0);
    assert(output_bytes_max > source_bytes_max);

    const random = prng.random();
    const layouts = [_]Writer.Layout{ .block, .flow, .preserve };
    const widths = [_]u32{ 0, 0, 1, 20, 80 };
    const width_roll = random.uintLessThan(u32, widths.len + 1);
    const width = if (width_roll < widths.len) widths[width_roll] else random.uintAtMost(u32, 100);

    return .{
        .indent = random.intRangeAtMost(u8, 1, 9),
        .layout = layouts[random.uintLessThan(u32, layouts.len)],
        .sequence_indentless = random.boolean(),
        .utf8 = .checked,
        .version_directive = random.uintLessThan(u32, 4) == 0,
        .width = width,
    };
}

fn write_failure_print(failure: WriteFailure) void {
    assert(failure.source.len <= output_bytes_max);
    assert(failure.written.len <= output_bytes_max);

    source_print(failure.source);

    std.debug.print("--- written ({d} bytes) ---\n{f}\n--- end ---\n", .{
        failure.written.len,
        std.zig.fmtString(failure.written),
    });
}

fn source_set(state: *State, text: []const u8) void {
    assert(text.len <= source_bytes_max);
    assert(state.source.len == source_bytes_max);

    @memcpy(state.source[0..text.len], text);
    state.source_count = @intCast(text.len);
}

fn source_mutate(state: *State) void {
    assert(state.source_count <= source_bytes_max);
    assert(state.source.len == source_bytes_max);

    const random = state.prng.random();
    const alphabet = " \t\r\n-?:,[]{}#&*!|>'\"%@`\\.0aZ\x00\x7f\xc3\xa9\xef\xbb\xbf\xff";
    const count = state.source_count;
    const position = random.uintAtMost(u32, count);
    const replacement = alphabet[random.uintLessThan(u32, alphabet.len)];

    switch (random.uintLessThan(u32, 4)) {
        0 => {
            if (count == source_bytes_max) return;

            std.mem.copyBackwards(
                u8,
                state.source[position + 1 .. count + 1],
                state.source[position..count],
            );

            state.source[position] = replacement;
            state.source_count += 1;
        },
        1 => {
            if (position == count) return;

            std.mem.copyForwards(
                u8,
                state.source[position .. count - 1],
                state.source[position + 1 .. count],
            );

            state.source_count -= 1;
        },
        2 => {
            if (position == count) return;

            state.source[position] = replacement;
        },
        3 => source_splice(state, position),
        else => unreachable,
    }
}

fn source_splice(state: *State, position: u32) void {
    assert(position <= state.source_count);
    assert(state.source_count <= source_bytes_max);

    const random = state.prng.random();
    const count = state.source_count;
    const start = random.uintAtMost(u32, count);
    const length = @min(random.uintAtMost(u32, 16), count - start, source_bytes_max - count);
    var chunk: [16]u8 = undefined;

    @memcpy(chunk[0..length], state.source[start..][0..length]);

    std.mem.copyBackwards(
        u8,
        state.source[position + length .. count + length],
        state.source[position..count],
    );

    @memcpy(state.source[position..][0..length], chunk[0..length]);
    state.source_count += length;
}

fn source_print(source: []const u8) void {
    assert(source.len <= source_bytes_max);
    assert(source_bytes_max > 0);

    std.debug.print("--- input ({d} bytes) ---\n{f}\n--- end ---\n", .{
        source.len,
        std.zig.fmtString(source),
    });
}

fn input_check(state: *State, source: []const u8) !bool {
    assert(source.len <= source_bytes_max);
    assert(state.parser_text.len == capacity.text_bytes_max);

    const outcome = try events_check(state, source);

    state.document.parse(state.storage.storage(), source, .{ .schema = .core }) catch |err| {
        try diagnostic_check(source, state.document.diagnostic);

        const composer_error = composer_error_is(err);

        switch (outcome) {
            .accepted => {
                if (!composer_error) {
                    std.debug.print("events accepted but the document failed with {t}\n", .{err});
                    source_print(source);

                    return error.LayersDisagree;
                }
            },
            .rejected => |rejection| {
                if (composer_error) {
                    try diagnostic_order_check(&.{
                        .composer = state.document.diagnostic,
                        .parser = rejection.diagnostic,
                    });

                    return false;
                }

                try std.testing.expectEqual(rejection.err, err);
                try std.testing.expectEqual(rejection.diagnostic, state.document.diagnostic);
            },
        }

        return false;
    };

    switch (outcome) {
        .accepted => |count| try std.testing.expectEqual(count, state.document.node_count),
        .rejected => |rejection| {
            std.debug.print("events rejected with {t} but the document composed\n", .{
                rejection.err,
            });

            source_print(source);

            return error.LayersDisagree;
        },
    }

    try document_check(&state.document);

    return true;
}

fn composer_error_is(err: document_module.Document.Error) bool {
    assert(@errorName(err).len > 0);
    assert(capacity.node_count_max > 0);

    return switch (err) {
        error.AliasRecursive,
        error.AliasUndefined,
        error.AnchorsExhausted,
        error.DepthExceeded,
        error.KeyCollision,
        error.KeyDuplicate,
        error.NodesExhausted,
        => true,
        else => false,
    };
}

fn diagnostic_order_check(pair: *const DiagnosticPair) !void {
    assert(pair.composer.line >= 1);
    assert(pair.parser.line >= 1);

    try std.testing.expect(pair.composer.line <= pair.parser.line);

    if (pair.composer.line == pair.parser.line) {
        try std.testing.expect(pair.composer.column <= pair.parser.column);
    }
}

fn events_check(state: *State, source: []const u8) !Outcome {
    assert(source.len <= source_bytes_max);
    assert(state.parser_text.len > 0);

    var summary: Summary = .{
        .depth = 0,
        .document_count = 0,
        .document_open = false,
        .event_count = 0,
        .node_count = 0,
        .root_count = 0,
        .stack = undefined,
    };

    state.parser.init(&state.parser_text, source);

    const event_bound = 16 * source.len + 16;

    for (0..event_bound) |_| {
        const event = state.parser.next() catch |err| {
            try diagnostic_check(source, state.parser.diagnostic);

            return .{ .rejected = .{ .diagnostic = state.parser.diagnostic, .err = err } };
        };

        try event_check(&summary, event, source);

        if (event.* == .stream_end) {
            const ratio = @divFloor(16 * @as(u64, summary.event_count), source.len + 1);

            state.ratio_max = @max(state.ratio_max, ratio);

            try std.testing.expect(summary.event_count <= 4 * source.len + 16);

            return .{ .accepted = summary.node_count };
        }
    }

    return error.EventsUnbounded;
}

fn event_check(summary: *Summary, event: *const Event, source: []const u8) !void {
    assert(summary.depth <= depth_tracked_max);
    assert(source.len <= source_bytes_max);

    const first = summary.event_count == 0;

    summary.event_count += 1;

    try std.testing.expectEqual(first, event.* == .stream_start);

    switch (event.*) {
        .stream_start => {},
        .stream_end => {
            try std.testing.expect(!summary.document_open);
            try std.testing.expectEqual(@as(u32, 0), summary.depth);
        },
        .document_start => {
            try std.testing.expect(!summary.document_open);

            summary.document_open = true;
            summary.document_count += 1;
            summary.root_count = 0;
        },
        .document_end => {
            try std.testing.expect(summary.document_open);
            try std.testing.expectEqual(@as(u32, 0), summary.depth);
            try std.testing.expectEqual(@as(u32, 1), summary.root_count);

            summary.document_open = false;
        },
        .scalar => |*scalar| {
            try std.testing.expect(std.unicode.utf8ValidateSlice(scalar.text));
            try std.testing.expect(std.unicode.utf8ValidateSlice(scalar.tag));
            try mark_check(scalar.mark, source);
            try node_count(summary);
        },
        .alias => |*alias| {
            try std.testing.expect(alias.anchor.len > 0);
            try mark_check(alias.mark, source);
            try node_count(summary);
        },
        .mapping_start, .sequence_start => |*start| {
            try std.testing.expect(std.unicode.utf8ValidateSlice(start.tag));
            try mark_check(start.mark, source);
            try node_count(summary);
            try level_push(summary, event.* == .mapping_start);
        },
        .mapping_end, .sequence_end => try level_pop(summary, event.* == .mapping_end),
    }
}

fn mark_check(mark: Mark, source: []const u8) !void {
    assert(source.len <= source_bytes_max);
    assert(mark.column <= std.math.maxInt(u32));

    try std.testing.expect(mark.index <= source.len);
    try std.testing.expect(mark.line <= source.len);
    try std.testing.expect(mark.column <= mark.index);
}

fn node_count(summary: *Summary) !void {
    assert(summary.depth <= depth_tracked_max);
    assert(summary.node_count < std.math.maxInt(u32));

    try std.testing.expect(summary.document_open);

    summary.node_count += 1;

    if (summary.depth == 0) {
        summary.root_count += 1;

        return;
    }

    summary.stack[summary.depth - 1].child_count += 1;
}

fn level_push(summary: *Summary, mapping: bool) !void {
    assert(summary.depth <= depth_tracked_max);
    assert(summary.document_open);

    if (summary.depth == depth_tracked_max) return error.DepthUntracked;

    summary.stack[summary.depth] = .{ .child_count = 0, .mapping = mapping };
    summary.depth += 1;
}

fn level_pop(summary: *Summary, mapping: bool) !void {
    assert(summary.depth <= depth_tracked_max);
    assert(summary.document_open);

    try std.testing.expect(summary.depth > 0);

    const level = summary.stack[summary.depth - 1];

    try std.testing.expectEqual(level.mapping, mapping);

    if (mapping) try std.testing.expect(level.child_count % 2 == 0);

    summary.depth -= 1;
}

fn diagnostic_check(source: []const u8, diagnostic: Position) !void {
    assert(source.len <= source_bytes_max);
    assert(diagnostic.line <= std.math.maxInt(u32));

    try std.testing.expect(diagnostic.line >= 1);
    try std.testing.expect(diagnostic.column >= 1);

    var line: u32 = 1;
    var index: u32 = 0;

    for (0..source.len + 1) |_| {
        if (line == diagnostic.line) break;

        if (index >= source.len) {
            std.debug.print("diagnostic line {d} is past the input's {d} lines\n", .{
                diagnostic.line,
                line,
            });

            source_print(source);

            return error.DiagnosticBeyondInput;
        }

        const byte = source[index];
        const pair = byte == '\r' and index + 1 < source.len and source[index + 1] == '\n';
        const line_break = byte == '\n' or byte == '\r';

        if (line_break) line += 1;

        index += if (pair) 2 else 1;
    }

    var column: u32 = 1;

    for (source[index..]) |byte| {
        const line_break = byte == '\n' or byte == '\r';
        if (line_break) break;

        if (byte & 0xc0 != 0x80) column += 1;
    }

    if (diagnostic.column > column) {
        std.debug.print("diagnostic {d}:{d} is past the line's {d} columns\n", .{
            diagnostic.line,
            diagnostic.column,
            column,
        });

        source_print(source);

        return error.DiagnosticBeyondLine;
    }

    try diagnostic_offset_check(source, diagnostic, index);
}

fn diagnostic_offset_check(source: []const u8, diagnostic: Position, line_start: u32) !void {
    assert(line_start <= source.len);
    assert(diagnostic.line >= 1);

    if (diagnostic.offset < line_start) return diagnostic_offset_fail(source, diagnostic);
    if (diagnostic.offset > source.len) return diagnostic_offset_fail(source, diagnostic);

    const before = source[line_start..diagnostic.offset];

    if (std.mem.findAny(u8, before, "\r\n") != null) {
        return diagnostic_offset_fail(source, diagnostic);
    }

    const bom = "\xef\xbb\xbf";
    var marks: u32 = 0;
    var rest = before;

    for (0..before.len) |_| {
        if (!std.mem.startsWith(u8, rest, bom)) break;

        marks += 1;
        rest = rest[bom.len..];
    }

    var points: u32 = 0;

    for (before) |byte| {
        if (byte & 0xc0 != 0x80) points += 1;
    }

    if (diagnostic.column > points + 1) return diagnostic_offset_fail(source, diagnostic);
    if (diagnostic.column + marks < points + 1) return diagnostic_offset_fail(source, diagnostic);
}

fn diagnostic_offset_fail(source: []const u8, diagnostic: Position) error{DiagnosticOffsetInvalid} {
    assert(source.len <= source_bytes_max);
    assert(diagnostic.line >= 1);

    std.debug.print("diagnostic {d}:{d} disagrees with its offset {d}\n", .{
        diagnostic.line,
        diagnostic.column,
        diagnostic.offset,
    });

    source_print(source);

    return error.DiagnosticOffsetInvalid;
}

fn document_check(document: *const Document) !void {
    assert(document.node_count <= capacity.node_count_max);
    assert(document.document_count <= document.node_count);

    const nodes = document.storage.nodes[0..document.node_count];

    for (nodes, 0..) |*data, index| {
        const node: Node = @fromBackingInt(@as(u32, @intCast(index)));

        switch (data.kind) {
            .alias, .scalar => {},
            .mapping => try mapping_check(document, node),
            .sequence => try sequence_check(document, node),
        }
    }
}

fn sequence_check(document: *const Document, sequence: Node) !void {
    assert(document.kind_of(sequence) == .sequence);
    assert(document.node_count > 0);

    var items = document.items(sequence);
    var count: u32 = 0;

    for (0..document.node_count) |_| {
        _ = items.next() orelse break;

        count += 1;
    }

    try std.testing.expectEqual(document.count_of(sequence), count);
}

fn mapping_check(document: *const Document, mapping: Node) !void {
    assert(document.kind_of(mapping) == .mapping);
    assert(document.node_count > 0);

    var entries = document.entries(mapping);
    var count: u32 = 0;

    for (0..document.node_count) |_| {
        const entry = entries.next() orelse break;

        count += 1;

        if (document.kind_of(entry.key) != .scalar) continue;

        const found = document.member(mapping, document.text_of(entry.key).?);

        try std.testing.expectEqual(@as(?Node, entry.value), found);
    }

    try std.testing.expectEqual(document.count_of(mapping), count);
}
