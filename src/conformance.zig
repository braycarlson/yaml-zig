const std = @import("std");

const bounded = @import("bounded");
const parser_module = @import("parser.zig");
const round_trip = @import("round_trip.zig");
const storage_module = @import("storage.zig");
const yaml = @import("yaml.zig");

const assert = std.debug.assert;

const Event = parser_module.Event;
const Parser = parser_module.Parser;
const Writer = yaml.Writer;

const case_count_max: u32 = 1024;
const event_count_max: u32 = 1 << 16;
const json_bytes_max: u32 = 1 << 20;
const json_node_count_max: u32 = 1 << 20;
const json_pair_count_max: u32 = 1 << 16;
const json_values_bytes_max: u32 = 1 << 24;
const name_bytes_max: u32 = 64;
const path_bytes_max: u32 = 1024;
const rendered_bytes_max: u32 = 1 << 20;
const source_bytes_max: u32 = 1 << 20;
const text_bytes_max: u32 = 1 << 21;

const usage_text = "usage: conformance <yaml-test-suite data directory> [case]\n" ++
    "       conformance corpus <file>...\n";

const value_depth_max: u32 = 1024;
const value_visit_count_max: u32 = 1 << 20;
const write_bytes_max: u32 = 1 << 20;
const written_shown_max: u32 = 4096;

comptime {
    assert(rendered_bytes_max <= text_bytes_max);
    assert(name_bytes_max < path_bytes_max);
    assert(source_bytes_max <= yaml.limits.source_bytes_max);
    assert(value_depth_max > 2 * yaml.limits.depth_max);
}

const Document = yaml.DocumentType(.{
    .anchor_count_max = 1024,
    .comment_count_max = null,
    .node_count_max = 1 << 16,
    .text_bytes_max = text_bytes_max,
});

const Tree = yaml.TreeType(.{
    .anchor_count_max = 1024,
    .comment_count_max = null,
    .node_count_max = 1 << 16,
    .text_bytes_max = text_bytes_max,
});

const Name = bounded.ArrayType(u8, name_bytes_max);
const Names = bounded.ArrayType(Name, case_count_max);
const Path = bounded.BufferType(path_bytes_max);

const Outcome = union(enum) {
    failed,
    passed,
    rejected: Rejection,
};

const Tally = struct {
    failed: u32,
    passed: u32,
    rejection_early: u32,
    rejection_exact: u32,
    rejection_late: u32,
};

const Rejection = enum {
    early,
    exact,
    late,
};

const ValuesTally = struct {
    compared: u32,
    differed: u32,
};

const JSONPair = struct {
    actual: *const std.json.Value,
    expected: *const std.json.Value,
};

const ValuePair = struct {
    expected: *const std.json.Value,
    node: yaml.Node,
};

const SequenceCursor = struct {
    index: u32,
    items: yaml.Items,
};

const Cursor = union(enum) {
    mapping: yaml.Entries,
    sequence: SequenceCursor,
};

const ValueFrame = struct {
    cursor: Cursor,
    expected: *const std.json.Value,
};

const ValueStep = union(enum) {
    child: ValuePair,
    difference: []const u8,
    done,
};

const Verdict = union(enum) {
    differed: []const u8,
    matched,
};

const WriteSet = struct {
    comparison: round_trip.Options,
    options: Writer.Options,
};

const WriteInput = struct {
    composed: bool,
    source: []const u8,
};

const WriteOutcome = struct {
    composed: bool,
    differed: u32,
    idempotent: bool,
    passed_through: bool,
};

const WritesTally = struct {
    cases: u32,
    composed: u32,
    differed: u32,
    idempotent: u32,
    passed_through: u32,
};

const CommentsTally = struct {
    cases: u32,
    composed: u32,
    differed: u32,
    identical: u32,
    lost: u32,
    tree_differed: u32,
    unstable: u32,
};

const Kept = struct {
    again: yaml.Document,
    again_storage: yaml.Storage,
    document: yaml.Document,
    document_storage: yaml.Storage,
    order: []storage_module.CommentSlot,
    order_again: []storage_module.CommentSlot,
    parser: *Parser,
    parser_written: *Parser,
    rewritten: []u8,
    text: []u8,
    text_written: []u8,
    tree: yaml.Tree,
    tree_storage: yaml.Tree.Storage,
    tree_written: []u8,
    written: []u8,

    fn init(gpa: std.mem.Allocator, capacity: yaml.Capacity, bytes_max: u32) !*Kept {
        assert(capacity.comment_count_max != null);
        assert(bytes_max > 0);

        const kept = try gpa.create(Kept);
        const count = capacity.comment_count_max.?;

        kept.again_storage = try yaml.Storage.init(gpa, capacity);
        kept.document_storage = try yaml.Storage.init(gpa, capacity);
        kept.order = try gpa.alloc(storage_module.CommentSlot, count);
        kept.order_again = try gpa.alloc(storage_module.CommentSlot, count);
        kept.parser = try gpa.create(Parser);
        kept.parser_written = try gpa.create(Parser);

        const written_max = 2 * bytes_max;

        kept.rewritten = try gpa.alloc(u8, written_max);
        kept.text = try gpa.alloc(u8, capacity.text_bytes_max);
        kept.text_written = try gpa.alloc(u8, capacity.text_bytes_max);
        kept.tree_storage = try yaml.Tree.Storage.init(gpa, capacity);
        kept.tree_written = try gpa.alloc(u8, written_max);
        kept.written = try gpa.alloc(u8, written_max);

        return kept;
    }

    fn destroy(kept: *Kept, gpa: std.mem.Allocator) void {
        assert(kept.order.len > 0);
        assert(kept.written.len > 0);

        kept.again_storage.deinit(gpa);
        kept.document_storage.deinit(gpa);
        gpa.free(kept.order);
        gpa.free(kept.order_again);
        gpa.destroy(kept.parser);
        gpa.destroy(kept.parser_written);
        gpa.free(kept.rewritten);
        gpa.free(kept.text);
        gpa.free(kept.text_written);
        kept.tree_storage.deinit(gpa);
        gpa.free(kept.tree_written);
        gpa.free(kept.written);
        gpa.destroy(kept);
    }
};

const CommentOutcome = enum {
    differed,
    identical,
    lost,
    passed,
    tree_differed,
    uncomposed,
    unstable,
};

const TreeOutcome = struct {
    differed: u32,
    redefined: bool,
};

const TreeTally = struct {
    cases: u32,
    copied: u32,
    differed: u32,
    redefined: u32,
};

const EmittedTally = struct {
    emit_count: u32,
    emit_identical: u32,
    out_count: u32,
    out_identical: u32,
};

const Workspace = struct {
    document: Document,
    expected: [rendered_bytes_max]u8,
    frames: [value_depth_max]ValueFrame,
    json: [json_bytes_max]u8,
    json_pairs: [json_pair_count_max]JSONPair,
    json_values: [json_values_bytes_max]u8,
    json_written: [write_bytes_max]u8,
    names: Names,
    parser: Parser,
    parser_written: Parser,
    passed: [write_bytes_max]u8,
    rendered: [rendered_bytes_max]u8,
    reparsed: Document,
    rewritten: [write_bytes_max]u8,
    source: [source_bytes_max]u8,
    text: [text_bytes_max]u8,
    text_written: [text_bytes_max]u8,
    tree: Tree,
    tree_written: [write_bytes_max]u8,
    written: [write_bytes_max]u8,
};

const comments_identical_min: u32 = 57;
const corpus_identical_min: u32 = 16;
const emit_identical_min: u32 = 23;
const out_identical_min: u32 = 179;

const capacity_kept: yaml.Capacity = .{
    .anchor_count_max = 1024,
    .comment_count_max = 4096,
    .node_count_max = 1 << 16,
    .text_bytes_max = text_bytes_max,
};

const capacity_corpus: yaml.Capacity = .{
    .anchor_count_max = 1 << 16,
    .comment_count_max = 1 << 18,
    .node_count_max = 1 << 22,
    .text_bytes_max = 1 << 26,
};

const corpus_bytes_max: u32 = 1 << 26;

const options_emit: Writer.Options = .{
    .indent = 2,
    .layout = .preserve,
    .sequence_indentless = true,
    .utf8 = .checked,
    .version_directive = false,
    .width = 0,
};

const options_out: Writer.Options = .{
    .indent = 2,
    .layout = .block,
    .sequence_indentless = true,
    .utf8 = .checked,
    .version_directive = false,
    .width = 0,
};

const write_sets = [_]WriteSet{
    .{
        .comparison = .{ .layout = .preserve, .style_exact = true, .version_directive = false },
        .options = .{
            .indent = 2,
            .layout = .preserve,
            .sequence_indentless = false,
            .utf8 = .checked,
            .version_directive = false,
            .width = 0,
        },
    },
    .{
        .comparison = .{ .layout = .block, .style_exact = false, .version_directive = false },
        .options = .{
            .indent = 4,
            .layout = .block,
            .sequence_indentless = true,
            .utf8 = .checked,
            .version_directive = false,
            .width = 0,
        },
    },
    .{
        .comparison = .{ .layout = .flow, .style_exact = false, .version_directive = true },
        .options = .{
            .indent = 1,
            .layout = .flow,
            .sequence_indentless = false,
            .utf8 = .checked,
            .version_directive = true,
            .width = 0,
        },
    },
    .{
        .comparison = .{ .layout = .preserve, .style_exact = true, .version_directive = false },
        .options = .{
            .indent = 3,
            .layout = .preserve,
            .sequence_indentless = true,
            .utf8 = .checked,
            .version_directive = false,
            .width = 20,
        },
    },
};

comptime {
    assert(write_sets.len == 4);
    assert(write_bytes_max <= text_bytes_max);
}

pub fn main(init: std.process.Init) !u8 {
    assert(init.minimal.args.vector.len < std.math.maxInt(u32));

    const arguments = try init.minimal.args.toSlice(init.arena.allocator());
    if (arguments.len < 2) return usage();
    if (std.mem.eql(u8, arguments[1], "corpus")) return corpus_run(init, arguments[2..]);
    if (arguments.len > 3) return usage();

    const workspace = try init.gpa.create(Workspace);
    defer init.gpa.destroy(workspace);

    const root = arguments[1];
    const filter = if (arguments.len == 3) arguments[2] else "";

    workspace.names = .empty;

    try cases_collect(init.io, root, &workspace.names);

    const options: RunOptions = .{ .filter = filter, .root = root };
    const tally = try cases_run(init.io, workspace, options);
    const values = try values_run(init.io, workspace, options);

    std.debug.print("conformance: {d} passed, {d} failed, {d} total\n", .{
        tally.passed,
        tally.failed,
        tally.passed + tally.failed,
    });

    std.debug.print("rejections: {d} exact, {d} earlier, {d} later than the suite's events\n", .{
        tally.rejection_exact,
        tally.rejection_early,
        tally.rejection_late,
    });

    std.debug.print("values: {d} cases compared against in.json, {d} differ\n", .{
        values.compared,
        values.differed,
    });

    const writes = try writes_run(init.io, workspace, options);
    const emitted = try emitted_run(init.io, workspace, options);
    const verdict = writes_report(&writes, &emitted, filter.len > 0);
    const json = try json_run(init.io, workspace, options);

    std.debug.print("json: {d} cases written as JSON and compared against in.json, {d} differ\n", .{
        json.compared,
        json.differed,
    });

    const trees_verdict = try trees_check(init.io, workspace, options);
    const comment_verdict = try comments_check(init, workspace, options);

    if (tally.failed > 0) return 1;
    if (values.differed > 0) return 1;
    if (json.differed > 0) return 1;
    return @max(verdict, trees_verdict, comment_verdict);
}

fn comments_check(init: std.process.Init, workspace: *Workspace, options: RunOptions) !u8 {
    assert(init.minimal.args.vector.len > 0);
    assert(options.root.len > 0);
    assert(workspace.names.count <= case_count_max);

    const kept = try Kept.init(init.gpa, capacity_kept, source_bytes_max);
    defer kept.destroy(init.gpa);

    var tally = comments_tally_empty;

    for (workspace.names.slice()) |*name| {
        if (options.filter.len > 0) {
            if (!std.mem.startsWith(u8, name.slice(), options.filter)) continue;
        }

        const case = Case{ .name = name.slice(), .root = options.root };
        if (case_file_present(init.io, &case, "error")) continue;

        const source = try case_file_read(init.io, &case, "in.yaml", &workspace.source);

        const outcome = comments_round_trip(kept, source) catch |err| {
            std.debug.print("COMMENTS {s}: failed with {t}\n", .{ case.name, err });

            return err;
        };

        comments_tally_add(&tally, case.name, outcome);
    }

    comments_report("comments", &tally);

    return comments_verdict(&tally, options.filter.len == 0, comments_identical_min);
}

fn corpus_run(init: std.process.Init, paths: []const []const u8) !u8 {
    assert(init.minimal.args.vector.len > 0);
    assert(paths.len < std.math.maxInt(u32));

    if (paths.len == 0) return usage();

    const kept = try Kept.init(init.gpa, capacity_corpus, corpus_bytes_max);
    defer kept.destroy(init.gpa);

    const source_buffer = try init.gpa.alloc(u8, corpus_bytes_max);
    defer init.gpa.free(source_buffer);

    var tally = comments_tally_empty;

    for (paths) |path| {
        const source = try std.Io.Dir.cwd().readFile(init.io, path, source_buffer);
        if (source.len == source_buffer.len) return error.FileTooLarge;

        const outcome = try comments_round_trip(kept, source);

        comments_tally_add(&tally, std.fs.path.basename(path), outcome);
    }

    comments_report("corpus", &tally);

    return comments_verdict(&tally, true, corpus_identical_min);
}

const comments_tally_empty: CommentsTally = .{
    .cases = 0,
    .composed = 0,
    .differed = 0,
    .identical = 0,
    .lost = 0,
    .tree_differed = 0,
    .unstable = 0,
};

fn comments_tally_add(tally: *CommentsTally, name: []const u8, outcome: CommentOutcome) void {
    assert(name.len > 0);
    assert(tally.composed <= tally.cases);

    tally.cases += 1;

    if (outcome == .uncomposed) return;

    tally.composed += 1;

    switch (outcome) {
        .differed => tally.differed += 1,
        .identical => tally.identical += 1,
        .lost => tally.lost += 1,
        .passed => {},
        .tree_differed => tally.tree_differed += 1,
        .uncomposed => unreachable,
        .unstable => tally.unstable += 1,
    }

    switch (outcome) {
        .differed, .lost, .tree_differed, .unstable => {
            std.debug.print("COMMENTS {s}: {t}\n", .{ name, outcome });
        },
        .identical, .passed, .uncomposed => {},
    }
}

fn comments_report(label: []const u8, tally: *const CommentsTally) void {
    assert(label.len > 0);
    assert(tally.composed <= tally.cases);

    std.debug.print("{s}: {d} of {d} cases composed with comments kept and written, " ++
        "{d} differ, {d} lose a comment, {d} miss the fixed point, {d} tree copies differ; " ++
        "{d} byte-identical\n", .{
        label,
        tally.composed,
        tally.cases,
        tally.differed,
        tally.lost,
        tally.unstable,
        tally.tree_differed,
        tally.identical,
    });
}

fn comments_verdict(tally: *const CommentsTally, floored: bool, identical_min: u32) u8 {
    assert(identical_min <= case_count_max);
    assert(tally.composed <= tally.cases);
    assert(tally.identical <= tally.composed);

    if (tally.differed > 0) return 1;
    if (tally.lost > 0) return 1;
    if (tally.unstable > 0) return 1;
    if (tally.tree_differed > 0) return 1;

    const below_floor = floored and tally.identical < identical_min;
    if (below_floor) return 1;
    return 0;
}

fn comments_round_trip(kept: *Kept, source: []const u8) !CommentOutcome {
    assert(source.len <= corpus_bytes_max);
    assert(kept.written.len >= 2 * source.len);

    kept.document.parse(kept.document_storage, source, .{ .schema = .core }) catch {
        return .uncomposed;
    };

    const options = &write_sets[0].options;
    const written = try kept_written(&kept.document, options, kept.written);

    kept.parser.init(kept.text, source);
    kept.parser_written.init(kept.text_written, written);

    const sources: round_trip.Sources = .{
        .original = .{ .parser = kept.parser },
        .written = .{ .parser = kept.parser_written },
    };

    const verdict = try round_trip.streams_equivalent(sources, write_sets[0].comparison);

    if (verdict == .differed) {
        std.debug.print("COMMENTS: {s}\n", .{verdict.differed});
        written_print(written);

        return .differed;
    }

    kept.again.parse(kept.again_storage, written, .{ .schema = .core }) catch return .differed;

    const first = comments_in_order(&kept.document, kept.order);
    const second = comments_in_order(&kept.again, kept.order_again);

    if (!comment_texts_equal(.{ first, second })) {
        written_print(written);

        return .lost;
    }

    const rewritten = try kept_written(&kept.again, options, kept.rewritten);

    if (!std.mem.eql(u8, written, rewritten)) {
        written_print(written);
        written_print(rewritten);

        return .unstable;
    }

    if (!attachments_equal(.{ &kept.document, &kept.again })) {
        written_print(written);

        return .unstable;
    }

    if (!try kept_tree_matches(kept, written)) return .tree_differed;
    if (std.mem.eql(u8, source, written)) return .identical;
    return .passed;
}

fn kept_written(
    document: *const yaml.Document,
    options: *const Writer.Options,
    buffer: []u8,
) ![]u8 {
    assert(options.indent >= 1);
    assert(buffer.len > 0);

    var sink: std.Io.Writer = .fixed(buffer);

    try document.write(&sink, options.*);

    return sink.buffered();
}

fn kept_tree_matches(kept: *Kept, written: []const u8) !bool {
    assert(kept.document.composer.frame_count == 0);
    assert(written.len <= kept.written.len);

    const document = &kept.document;
    if (document.root_count() == 0) return true;

    kept.tree.init(kept.tree_storage, .{ .schema = .core });

    for (0..document.root_count()) |index| {
        const root = document.root(@intCast(index));

        const content: yaml.Tree.Content = .{
            .copy = .{ .document = document, .merge = .ignored, .node = root },
        };

        _ = kept.tree.root_append(content) catch |err| switch (err) {
            error.AnchorDuplicate => return true,
            else => |other| return other,
        };
    }

    var sink: std.Io.Writer = .fixed(kept.tree_written);

    try kept.tree.write(&sink, write_sets[0].options);

    if (std.mem.eql(u8, sink.buffered(), written)) return true;

    written_print(sink.buffered());

    return false;
}

fn comments_in_order(
    document: *const yaml.Document,
    buffer: []storage_module.CommentSlot,
) []storage_module.CommentSlot {
    assert(document.comment_count <= buffer.len);
    assert(document.comment_count <= document.storage.comments.len);

    const result = buffer[0..document.comment_count];

    @memcpy(result, document.storage.comments[0..document.comment_count]);
    std.sort.block(storage_module.CommentSlot, result, {}, slot_source_less);

    return result;
}

fn slot_source_less(
    _: void,
    left: storage_module.CommentSlot,
    right: storage_module.CommentSlot,
) bool {
    assert(left.text.len > 0);
    assert(right.text.len > 0);

    return @intFromPtr(left.text.ptr) < @intFromPtr(right.text.ptr);
}

fn comment_texts_equal(sides: [2][]const storage_module.CommentSlot) bool {
    assert(sides[0].len <= std.math.maxInt(u32));
    assert(sides[1].len <= std.math.maxInt(u32));

    const first = sides[0];
    const second = sides[1];

    if (first.len != second.len) {
        std.debug.print("COMMENTS: {d} comments became {d}\n", .{ first.len, second.len });

        return false;
    }

    for (first, second) |*left, *right| {
        if (std.mem.eql(u8, left.text, right.text)) continue;

        std.debug.print("COMMENTS: '{s}' became '{s}'\n", .{ left.text, right.text });

        return false;
    }

    return true;
}

fn attachments_equal(sides: [2]*const yaml.Document) bool {
    assert(sides[0].comment_count <= sides[0].storage.comments.len);
    assert(sides[1].comment_count <= sides[1].storage.comments.len);

    const first = sides[0];
    const second = sides[1];
    if (first.comment_count != second.comment_count) return false;
    if (first.node_count != second.node_count) return false;

    const left = first.storage.comments[0..first.comment_count];
    const right = second.storage.comments[0..second.comment_count];

    for (left, right) |*one, *two| {
        const same = one.node == two.node and one.placement == two.placement and
            std.mem.eql(u8, one.text, two.text);

        if (same) continue;

        std.debug.print("COMMENTS: '{s}' on node {d} {t} moved to node {d} {t}\n", .{
            one.text,
            one.node,
            one.placement,
            two.node,
            two.placement,
        });

        return false;
    }

    return true;
}

fn writes_report(writes: *const WritesTally, emitted: *const EmittedTally, filtered: bool) u8 {
    assert(writes.differed <= writes.cases * write_sets.len);
    assert(emitted.out_identical <= emitted.out_count);

    std.debug.print("writes: {d} cases, {d} option sets, {d} differ; idempotent {d}; " ++
        "pass-through {d}\n", .{
        writes.cases,
        write_sets.len,
        writes.differed,
        writes.idempotent,
        writes.passed_through,
    });

    std.debug.print("out.yaml: {d} of {d} identical; emit.yaml: {d} of {d} identical\n", .{
        emitted.out_identical,
        emitted.out_count,
        emitted.emit_identical,
        emitted.emit_count,
    });

    if (writes.differed > 0) return 1;
    if (writes.idempotent < writes.cases) return 1;
    if (writes.passed_through < writes.composed) return 1;
    if (filtered) return 0;
    if (emitted.out_identical < out_identical_min) return 1;
    if (emitted.emit_identical < emit_identical_min) return 1;
    return 0;
}

fn usage() u8 {
    assert(usage_text.len > 0);
    assert(usage_text[usage_text.len - 1] == '\n');

    std.debug.print("{s}", .{usage_text});

    return 2;
}

fn cases_collect(io: std.Io, root: []const u8, names: *Names) !void {
    assert(root.len > 0);
    assert(names.count == 0);

    var directory = try std.Io.Dir.cwd().openDir(io, root, .{ .iterate = true });
    defer directory.close(io);

    var iterator = directory.iterate();

    for (0..case_count_max * 4) |_| {
        const entry = try iterator.next(io) orelse break;
        if (entry.kind != .directory) continue;
        if (!case_name_is(entry.name)) continue;

        try case_collect(io, &directory, entry.name, names);
    }

    std.mem.sort(Name, names.slice_mutable(), {}, name_less);
}

fn case_name_is(name: []const u8) bool {
    assert(name.len > 0);
    assert(name.len <= path_bytes_max);

    if (name.len != 4) return false;

    for (name) |byte| {
        const valid = std.ascii.isUpper(byte) or std.ascii.isDigit(byte);
        if (!valid) return false;
    }

    return true;
}

fn case_collect(io: std.Io, directory: *const std.Io.Dir, name: []const u8, names: *Names) !void {
    assert(name.len == 4);
    assert(names.count <= case_count_max);

    var path: Path = .empty;

    try path.print("{s}/in.yaml", .{name});

    if (file_present(io, directory, path.slice())) return name_push(names, name);

    var case_directory = try directory.openDir(io, name, .{ .iterate = true });
    defer case_directory.close(io);

    var iterator = case_directory.iterate();

    for (0..case_count_max) |_| {
        const entry = try iterator.next(io) orelse break;
        if (entry.kind != .directory) continue;

        var nested: Path = .empty;

        try nested.print("{s}/{s}", .{ name, entry.name });
        try name_push(names, nested.slice());
    }
}

fn file_present(io: std.Io, directory: *const std.Io.Dir, path: []const u8) bool {
    assert(path.len > 0);
    assert(path.len <= path_bytes_max);

    directory.access(io, path, .{ .follow_symlinks = true, .read = true }) catch return false;

    return true;
}

fn name_push(names: *Names, name: []const u8) !void {
    assert(name.len > 0);
    assert(names.count <= case_count_max);

    const slot = try names.push_slot();

    slot.* = .empty;

    try slot.set(name);
}

fn name_less(context: void, left: Name, right: Name) bool {
    _ = context;

    assert(left.count > 0);
    assert(right.count > 0);

    return std.mem.lessThan(u8, left.slice(), right.slice());
}

const RunOptions = struct {
    filter: []const u8,
    root: []const u8,
};

const Case = struct {
    name: []const u8,
    root: []const u8,
};

const Comparison = struct {
    expected: []const u8,
    rendered: []const u8,
};

const PropertiesText = struct {
    anchor: []const u8,
    tag: []const u8,
};

fn cases_run(io: std.Io, workspace: *Workspace, options: RunOptions) !Tally {
    assert(options.root.len > 0);
    assert(workspace.names.count <= case_count_max);

    var tally = Tally{
        .failed = 0,
        .passed = 0,
        .rejection_early = 0,
        .rejection_exact = 0,
        .rejection_late = 0,
    };

    for (workspace.names.slice()) |*name| {
        if (options.filter.len > 0) {
            if (!std.mem.startsWith(u8, name.slice(), options.filter)) continue;
        }

        const case = Case{ .name = name.slice(), .root = options.root };
        const outcome = try case_run(io, workspace, &case);

        switch (outcome) {
            .failed => tally.failed += 1,
            .passed => tally.passed += 1,
            .rejected => |rejection| {
                tally.passed += 1;

                switch (rejection) {
                    .early => tally.rejection_early += 1,
                    .exact => tally.rejection_exact += 1,
                    .late => tally.rejection_late += 1,
                }
            },
        }
    }

    return tally;
}

fn case_run(io: std.Io, workspace: *Workspace, case: *const Case) !Outcome {
    assert(case.root.len > 0);
    assert(case.name.len > 0);

    const source = try case_file_read(io, case, "in.yaml", &workspace.source);
    const expected = try case_file_read(io, case, "test.event", &workspace.expected);
    const must_fail = case_file_present(io, case, "error");

    var writer: std.Io.Writer = .fixed(&workspace.rendered);
    const parsed = events_render(&workspace.parser, source, &workspace.text, &writer);
    const comparison = Comparison{ .expected = expected, .rendered = writer.buffered() };

    if (must_fail) {
        if (parsed) |_| {
            std.debug.print("FAIL {s}: accepted a document the suite rejects\n", .{case.name});

            return .failed;
        } else |err| {
            return rejection_report(case, &comparison, err, workspace.parser.diagnostic);
        }
    }

    parsed catch |err| {
        const diagnostic = workspace.parser.diagnostic;

        std.debug.print("FAIL {s}: {t} at {d}:{d}\n", .{
            case.name,
            err,
            diagnostic.line,
            diagnostic.column,
        });

        return .failed;
    };

    if (std.mem.eql(u8, comparison.rendered, comparison.expected)) return .passed;

    difference_report(case, &comparison);

    return .failed;
}

fn values_run(io: std.Io, workspace: *Workspace, options: RunOptions) !ValuesTally {
    assert(options.root.len > 0);
    assert(workspace.names.count <= case_count_max);

    var tally = ValuesTally{ .compared = 0, .differed = 0 };

    for (workspace.names.slice()) |*name| {
        if (options.filter.len > 0) {
            if (!std.mem.startsWith(u8, name.slice(), options.filter)) continue;
        }

        const case = Case{ .name = name.slice(), .root = options.root };
        if (case_file_present(io, &case, "error")) continue;
        if (!case_file_present(io, &case, "in.json")) continue;

        tally.compared += 1;

        switch (try case_values_compare(io, workspace, &case)) {
            .differed => |reason| {
                tally.differed += 1;

                std.debug.print("VALUES {s}: {s}\n", .{ case.name, reason });
            },
            .matched => {},
        }
    }

    assert(tally.differed <= tally.compared);

    return tally;
}

fn case_values_compare(io: std.Io, workspace: *Workspace, case: *const Case) !Verdict {
    assert(case.root.len > 0);
    assert(case.name.len > 0);

    const source = try case_file_read(io, case, "in.yaml", &workspace.source);
    const json_text = try case_file_read(io, case, "in.json", &workspace.json);
    const document = &workspace.document;

    document.parse(source, .{ .schema = .core }) catch |err| {
        return .{ .differed = @errorName(err) };
    };

    var values: std.heap.FixedBufferAllocator = .init(&workspace.json_values);
    const allocator = values.allocator();
    var start: u32 = 0;
    var index: u32 = 0;

    for (0..json_text.len + 1) |_| {
        start = json_blank_skip(json_text, start);

        if (start == json_text.len) break;
        if (index == document.root_count()) return .{ .differed = "in.json has more documents" };

        const end = json_value_end(json_text, start);
        const value_text = json_text[start..end];

        const expected = std.json.parseFromSliceLeaky(std.json.Value, allocator, value_text, .{
            .duplicate_field_behavior = .@"error",
            .ignore_unknown_fields = false,
            .max_value_len = null,
            .allocate = .alloc_always,
            .parse_numbers = true,
        }) catch return .{ .differed = "in.json is not valid JSON" };

        const root: ValuePair = .{ .expected = &expected, .node = document.root(index) };

        if (tree_difference(document, root, &workspace.frames)) |reason| {
            return .{ .differed = reason };
        }

        index += 1;
        start = end;
    }

    if (index != document.root_count()) return .{ .differed = "the stream has more documents" };
    return .matched;
}

fn json_run(io: std.Io, workspace: *Workspace, options: RunOptions) !ValuesTally {
    assert(options.root.len > 0);
    assert(workspace.names.count <= case_count_max);

    var tally = ValuesTally{ .compared = 0, .differed = 0 };

    for (workspace.names.slice()) |*name| {
        if (options.filter.len > 0) {
            if (!std.mem.startsWith(u8, name.slice(), options.filter)) continue;
        }

        const case = Case{ .name = name.slice(), .root = options.root };
        if (case_file_present(io, &case, "error")) continue;
        if (!case_file_present(io, &case, "in.json")) continue;

        tally.compared += 1;

        switch (try case_json_compare(io, workspace, &case)) {
            .differed => |reason| {
                tally.differed += 1;

                std.debug.print("JSON {s}: {s}\n", .{ case.name, reason });
            },
            .matched => {},
        }
    }

    assert(tally.differed <= tally.compared);

    return tally;
}

fn case_json_compare(io: std.Io, workspace: *Workspace, case: *const Case) !Verdict {
    assert(case.root.len > 0);
    assert(case.name.len > 0);

    const source = try case_file_read(io, case, "in.yaml", &workspace.source);
    const json_text = try case_file_read(io, case, "in.json", &workspace.json);
    const document = &workspace.document;

    document.parse(source, .{ .schema = .core }) catch |err| {
        return .{ .differed = @errorName(err) };
    };

    var sink: std.Io.Writer = .fixed(&workspace.json_written);

    document.write_json(&sink, .{
        .merge = .ignored,
        .node_count_max = json_node_count_max,
        .non_finite = .refused,
    }) catch |err| return .{ .differed = @errorName(err) };

    const written = sink.buffered();

    var values: std.heap.FixedBufferAllocator = .init(&workspace.json_values);
    var lines = std.mem.splitScalar(u8, written, '\n');
    var start: u32 = 0;

    for (0..json_text.len + 1) |_| {
        start = json_blank_skip(json_text, start);

        const line = lines.next() orelse return .{ .differed = "the output ended early" };

        if (start == json_text.len) {
            if (line.len > 0) return .{ .differed = "the output has more documents" };
            return .matched;
        }

        const end = json_value_end(json_text, start);

        const expected = json_parse(values.allocator(), json_text[start..end]) catch {
            return .{ .differed = "in.json is not valid JSON" };
        };

        const actual = json_parse(values.allocator(), line) catch {
            return .{ .differed = "a written line is not valid JSON" };
        };

        const pair: JSONPair = .{ .actual = &actual, .expected = &expected };
        if (json_difference(&pair, &workspace.json_pairs)) |reason| return .{ .differed = reason };

        start = end;
    }

    return .{ .differed = "in.json has more values than it has bytes" };
}

fn json_parse(allocator: std.mem.Allocator, text: []const u8) !std.json.Value {
    assert(text.len > 0);
    assert(text.len <= write_bytes_max);

    return std.json.parseFromSliceLeaky(std.json.Value, allocator, text, .{
        .duplicate_field_behavior = .@"error",
        .ignore_unknown_fields = false,
        .max_value_len = null,
        .allocate = .alloc_always,
        .parse_numbers = true,
    });
}

fn json_difference(root: *const JSONPair, pairs: []JSONPair) ?[]const u8 {
    assert(pairs.len == json_pair_count_max);
    assert(@intFromPtr(root.actual) != @intFromPtr(root.expected));

    pairs[0] = root.*;

    var count: u32 = 1;

    for (0..value_visit_count_max) |_| {
        if (count == 0) return null;

        count -= 1;

        const pair = pairs[count];
        if (json_scalar_difference(&pair)) |reason| return reason;

        count = json_children_push(&pair, pairs, count) orelse {
            return "a value larger than the comparison holds";
        };
    }

    return "more values than the comparison visits";
}

fn json_children_push(pair: *const JSONPair, pairs: []JSONPair, count: u32) ?u32 {
    assert(count < pairs.len);
    assert(@intFromPtr(pair.actual) != @intFromPtr(pair.expected));

    var result = count;

    switch (pair.expected.*) {
        .array => |expected| {
            assert(pair.actual.* == .array);

            for (expected.items, pair.actual.array.items) |*left, *right| {
                if (result == pairs.len) return null;

                pairs[result] = .{ .actual = right, .expected = left };
                result += 1;
            }
        },
        .object => |expected| {
            assert(pair.actual.* == .object);

            var iterator = expected.iterator();

            for (0..expected.count()) |_| {
                const entry = iterator.next() orelse break;
                const actual = pair.actual.object.getPtr(entry.key_ptr.*) orelse unreachable;

                if (result == pairs.len) return null;

                pairs[result] = .{ .actual = actual, .expected = entry.value_ptr };
                result += 1;
            }
        },
        .bool, .float, .integer, .null, .number_string, .string => {},
    }

    return result;
}

fn json_scalar_difference(pair: *const JSONPair) ?[]const u8 {
    assert(@intFromPtr(pair.actual) != @intFromPtr(pair.expected));
    assert(json_pair_count_max > 0);

    const expected = pair.expected.*;
    const actual = pair.actual.*;

    if (json_number_of(&expected)) |number| {
        const written = json_number_of(&actual) orelse return "a number where the output differs";

        if (expected == .integer) {
            if (actual == .integer) {
                if (expected.integer != actual.integer) return "a different integer";
                return null;
            }
        }

        if (number != written) return "a different number";
        return null;
    }

    const kind_equal = std.meta.activeTag(expected) == std.meta.activeTag(actual);
    if (!kind_equal) return "a different kind of value";

    return switch (expected) {
        .array => {
            const length = expected.array.items.len;
            if (length != actual.array.items.len) return "an array of another length";
            return null;
        },
        .bool => if (expected.bool == actual.bool) null else "a different boolean",
        .float, .integer, .number_string => unreachable,
        .null => null,
        .object => json_keys_difference(pair),
        .string => {
            if (!std.mem.eql(u8, expected.string, actual.string)) return "a different string";
            return null;
        },
    };
}

fn json_keys_difference(pair: *const JSONPair) ?[]const u8 {
    assert(pair.expected.* == .object);
    assert(pair.actual.* == .object);

    const expected = &pair.expected.object;
    const actual = &pair.actual.object;
    if (expected.count() != actual.count()) return "an object of another size";

    for (expected.keys()) |key| {
        if (!actual.contains(key)) return "a key absent from the output";
    }

    return null;
}

fn json_number_of(value: *const std.json.Value) ?f64 {
    assert(json_pair_count_max > 0);
    assert(json_node_count_max > 0);

    return switch (value.*) {
        .float => |float| float,
        .integer => |integer| @floatFromInt(integer),
        .number_string => |text| std.fmt.parseFloat(f64, text) catch null,
        .array, .bool, .null, .object, .string => null,
    };
}

fn json_blank_skip(text: []const u8, start: u32) u32 {
    assert(start <= text.len);
    assert(text.len <= json_bytes_max);

    var index = start;

    for (text[start..]) |byte| {
        const blank = switch (byte) {
            ' ', '\t', '\n', '\r' => true,
            else => false,
        };

        if (!blank) break;

        index += 1;
    }

    assert(index <= text.len);

    return index;
}

fn json_value_end(text: []const u8, start: u32) u32 {
    assert(start < text.len);
    assert(json_blank_skip(text, start) == start);

    var depth: u32 = 0;
    var end: u32 = @intCast(text.len);
    var escaped = false;
    var quoted = false;

    for (text[start..], start..) |byte, position| {
        const index: u32 = @intCast(position);

        if (quoted) {
            if (escaped) {
                escaped = false;
            } else if (byte == '\\') {
                escaped = true;
            } else if (byte == '"') {
                quoted = false;

                if (depth == 0) {
                    end = index + 1;

                    break;
                }
            } else {}

            continue;
        }

        switch (byte) {
            '"' => quoted = true,
            '[', '{' => depth += 1,
            ']', '}' => {
                if (depth <= 1) {
                    end = index + 1;

                    break;
                }

                depth -= 1;
            },
            ' ', '\t', '\n', '\r' => if (depth == 0) {
                end = index;

                break;
            },
            else => {},
        }
    }

    assert(end > start);
    assert(end <= text.len);

    return end;
}

fn tree_difference(
    document: *const Document,
    root: ValuePair,
    frames: []ValueFrame,
) ?[]const u8 {
    assert(@backingInt(root.node) < document.document.node_count);
    assert(frames.len == value_depth_max);

    if (pair_difference(document, root)) |reason| return reason;
    if (document.kind_of(root.node) == .scalar) return null;

    frames[0] = frame_of(document, root);

    var frame_count: u32 = 1;

    for (0..value_visit_count_max) |_| {
        if (frame_count == 0) return null;

        const step = frame_step(document, &frames[frame_count - 1]);

        switch (step) {
            .child => |child| {
                if (pair_difference(document, child)) |reason| return reason;
                if (document.kind_of(child.node) == .scalar) continue;
                if (frame_count == frames.len) return "nesting deeper than the comparison holds";

                frames[frame_count] = frame_of(document, child);
                frame_count += 1;
            },
            .difference => |reason| return reason,
            .done => frame_count -= 1,
        }
    }

    return "more nodes than the comparison visits";
}

fn frame_of(document: *const Document, pair: ValuePair) ValueFrame {
    assert(@backingInt(pair.node) < document.document.node_count);
    assert(document.kind_of(pair.node) != .scalar);

    const cursor: Cursor = switch (document.kind_of(pair.node)) {
        .mapping => .{ .mapping = document.entries(pair.node) },
        .scalar => unreachable,
        .sequence => .{ .sequence = .{ .index = 0, .items = document.items(pair.node) } },
    };

    return .{ .cursor = cursor, .expected = pair.expected };
}

fn frame_step(document: *const Document, frame: *ValueFrame) ValueStep {
    assert(document.root_count() > 0);
    assert(frame.expected.* != .null);

    switch (frame.cursor) {
        .mapping => |*entries| {
            const entry = entries.next() orelse return .done;

            const key = document.text_of(entry.key) orelse {
                return .{ .difference = "a key that is not a scalar" };
            };

            const expected = frame.expected.object.getPtr(key) orelse {
                return .{ .difference = "a key absent from in.json" };
            };

            return .{ .child = .{ .expected = expected, .node = entry.value } };
        },
        .sequence => |*cursor| {
            const item = cursor.items.next() orelse return .done;
            const expected = &frame.expected.array.items[cursor.index];

            cursor.index += 1;

            return .{ .child = .{ .expected = expected, .node = item } };
        },
    }
}

fn pair_difference(document: *const Document, pair: ValuePair) ?[]const u8 {
    assert(@backingInt(pair.node) < document.document.node_count);
    assert(document.root_count() > 0);

    const expected = pair.expected;

    switch (document.kind_of(pair.node)) {
        .mapping => {
            if (expected.* != .object) return "a mapping where in.json differs";

            const count = document.count_of(pair.node);
            if (count != expected.object.count()) return "a mapping of another size";
            return null;
        },
        .scalar => return scalar_difference(document, pair),
        .sequence => {
            if (expected.* != .array) return "a sequence where in.json differs";

            const count = document.count_of(pair.node);
            if (count != expected.array.items.len) return "a sequence of another length";
            return null;
        },
    }
}

fn scalar_difference(document: *const Document, pair: ValuePair) ?[]const u8 {
    assert(@backingInt(pair.node) < document.document.node_count);
    assert(document.kind_of(pair.node) == .scalar);

    const expected = pair.expected;
    const node = pair.node;

    if (document.null_is(node)) {
        if (expected.* != .null) return "a null where in.json differs";
        return null;
    }

    if (document.boolean_of(node)) |boolean| {
        if (expected.* != .bool) return "a boolean where in.json differs";
        return if (expected.bool == boolean) null else "a different boolean";
    }

    if (document.integer_of(node)) |integer| {
        const number: f64 = @floatFromInt(integer);

        return switch (expected.*) {
            .float => |value| if (value == number) null else "a different integer",
            .integer => |value| if (value == integer) null else "a different integer",
            else => "an integer where in.json differs",
        };
    }

    if (document.float_of(node)) |float| {
        const number: f64 = switch (expected.*) {
            .float => |value| value,
            .integer => |value| @floatFromInt(value),
            else => return "a float where in.json differs",
        };

        if (number != float) return "a different float";
        return null;
    }

    if (expected.* != .string) return "a string where in.json differs";
    if (!std.mem.eql(u8, expected.string, document.text_of(node).?)) return "a different string";
    return null;
}

fn writes_run(io: std.Io, workspace: *Workspace, options: RunOptions) !WritesTally {
    assert(options.root.len > 0);
    assert(workspace.names.count <= case_count_max);

    var tally: WritesTally = .{
        .cases = 0,
        .composed = 0,
        .differed = 0,
        .idempotent = 0,
        .passed_through = 0,
    };

    for (workspace.names.slice()) |*name| {
        if (options.filter.len > 0) {
            if (!std.mem.startsWith(u8, name.slice(), options.filter)) continue;
        }

        const case = Case{ .name = name.slice(), .root = options.root };
        if (case_file_present(io, &case, "error")) continue;

        const outcome = try case_writes_check(io, workspace, &case);

        tally.cases += 1;
        tally.composed += @intFromBool(outcome.composed);
        tally.differed += outcome.differed;
        tally.idempotent += @intFromBool(outcome.idempotent);
        tally.passed_through += @intFromBool(outcome.passed_through);
    }

    assert(tally.idempotent <= tally.cases);
    assert(tally.passed_through <= tally.composed);

    return tally;
}

fn case_writes_check(io: std.Io, workspace: *Workspace, case: *const Case) !WriteOutcome {
    assert(case.root.len > 0);
    assert(case.name.len > 0);

    const source = try case_file_read(io, case, "in.yaml", &workspace.source);
    const composed = case_compose(workspace, case, source);
    const input: WriteInput = .{ .composed = composed, .source = source };

    var outcome: WriteOutcome = .{
        .composed = input.composed,
        .differed = 0,
        .idempotent = true,
        .passed_through = false,
    };

    for (&write_sets, 0..) |*set, index| {
        const written = try case_written(workspace, &input, &set.options, &workspace.written);

        if (written_difference(workspace, &input, written, set)) |reason| {
            std.debug.print("WRITE {s}: set {d}: {s}\n", .{ case.name, index, reason });
            written_print(written);

            outcome.differed += 1;
            outcome.idempotent = false;

            continue;
        }

        const again: WriteInput = .{ .composed = input.composed, .source = written };

        if (!try idempotent_is(workspace, &again, set)) {
            std.debug.print("WRITE {s}: set {d}: a second write differs\n", .{ case.name, index });
            written_print(written);

            outcome.idempotent = false;
        }

        if (index == 0) {
            if (input.composed) outcome.passed_through = try passed_through_is(workspace, &again);
        }
    }

    if (input.composed) {
        if (!outcome.passed_through) {
            std.debug.print("WRITE {s}: the event and document writers differ\n", .{case.name});
        }
    }

    return outcome;
}

fn case_compose(workspace: *Workspace, case: *const Case, source: []const u8) bool {
    assert(case.name.len > 0);
    assert(source.len <= source_bytes_max);

    workspace.document.parse(source, .{ .schema = .core }) catch |err| {
        std.debug.print("WRITE {s}: written from its events, as it does not compose ({t})\n", .{
            case.name,
            err,
        });

        return false;
    };

    return true;
}

fn case_written(
    workspace: *Workspace,
    input: *const WriteInput,
    options: *const Writer.Options,
    buffer: []u8,
) ![]u8 {
    assert(input.source.len <= source_bytes_max);
    assert(options.indent >= 1);
    assert(buffer.len == write_bytes_max);

    if (input.composed) return document_written(&workspace.document, options, buffer);
    return events_written(workspace, input.source, options, buffer);
}

fn document_written(document: *const Document, options: *const Writer.Options, buffer: []u8) ![]u8 {
    assert(options.indent >= 1);
    assert(buffer.len == write_bytes_max);

    var sink: std.Io.Writer = .fixed(buffer);

    try document.write(&sink, options.*);

    return sink.buffered();
}

fn events_written(
    workspace: *Workspace,
    source: []const u8,
    options: *const Writer.Options,
    buffer: []u8,
) ![]u8 {
    assert(source.len <= write_bytes_max);
    assert(buffer.len == write_bytes_max);

    var sink: std.Io.Writer = .fixed(buffer);
    var writer: Writer = undefined;

    workspace.parser.init(&workspace.text, source);
    writer.init(&sink, options.*);

    for (0..event_count_max) |_| {
        const event = try workspace.parser.next();

        try writer.emit(event);

        if (event.* == .stream_end) return sink.buffered();
    }

    return error.EventsExhausted;
}

fn written_difference(
    workspace: *Workspace,
    input: *const WriteInput,
    written: []const u8,
    set: *const WriteSet,
) ?[]const u8 {
    assert(input.source.len <= source_bytes_max);
    assert(written.len <= write_bytes_max);

    workspace.parser.init(&workspace.text, input.source);
    workspace.parser_written.init(&workspace.text_written, written);

    const sources: round_trip.Sources = .{
        .original = .{ .parser = &workspace.parser },
        .written = .{ .parser = &workspace.parser_written },
    };

    const verdict = round_trip.streams_equivalent(sources, set.comparison) catch |err| {
        return @errorName(err);
    };

    return switch (verdict) {
        .differed => |reason| reason,
        .matched => null,
    };
}

fn idempotent_is(workspace: *Workspace, input: *const WriteInput, set: *const WriteSet) !bool {
    assert(input.source.len <= write_bytes_max);
    assert(set.options.indent >= 1);

    const options = &set.options;
    const buffer = &workspace.rewritten;

    if (input.composed) {
        workspace.reparsed.parse(input.source, .{ .schema = .core }) catch return false;

        const rewritten = try document_written(&workspace.reparsed, options, buffer);
        return std.mem.eql(u8, input.source, rewritten);
    }

    const rewritten = try events_written(workspace, input.source, options, buffer);
    return std.mem.eql(u8, input.source, rewritten);
}

fn passed_through_is(workspace: *Workspace, written: *const WriteInput) !bool {
    assert(written.composed);
    assert(written.source.len <= write_bytes_max);

    const source = workspace.document.document.source;
    const options = &write_sets[0].options;
    const passed = try events_written(workspace, source, options, &workspace.passed);

    return std.mem.eql(u8, passed, written.source);
}

fn trees_check(io: std.Io, workspace: *Workspace, options: RunOptions) !u8 {
    assert(options.root.len > 0);
    assert(workspace.names.count <= case_count_max);

    const trees = try trees_run(io, workspace, options);

    std.debug.print("tree: {d} of {d} composed cases copied and written under {d} option sets, " ++
        "{d} differ; {d} redefine an anchor and give AnchorDuplicate\n", .{
        trees.copied,
        trees.cases,
        write_sets.len,
        trees.differed,
        trees.redefined,
    });

    return @intFromBool(trees.differed > 0);
}

fn trees_run(io: std.Io, workspace: *Workspace, options: RunOptions) !TreeTally {
    assert(options.root.len > 0);
    assert(workspace.names.count <= case_count_max);

    var tally: TreeTally = .{ .cases = 0, .copied = 0, .differed = 0, .redefined = 0 };

    for (workspace.names.slice()) |*name| {
        if (options.filter.len > 0) {
            if (!std.mem.startsWith(u8, name.slice(), options.filter)) continue;
        }

        const case = Case{ .name = name.slice(), .root = options.root };
        if (case_file_present(io, &case, "error")) continue;

        const source = try case_file_read(io, &case, "in.yaml", &workspace.source);

        workspace.document.parse(source, .{ .schema = .core }) catch continue;

        const outcome = try case_tree_check(workspace, &case);

        tally.cases += 1;
        tally.copied += @intFromBool(!outcome.redefined);
        tally.differed += outcome.differed;
        tally.redefined += @intFromBool(outcome.redefined);
    }

    assert(tally.copied + tally.redefined == tally.cases);
    assert(tally.differed <= tally.cases * write_sets.len);

    return tally;
}

fn case_tree_check(workspace: *Workspace, case: *const Case) !TreeOutcome {
    assert(case.name.len > 0);
    assert(workspace.document.document.composer.frame_count == 0);

    const redefined = anchor_redefined_is(&workspace.document.document);

    tree_copy(workspace) catch |err| switch (err) {
        error.AnchorDuplicate => {
            if (redefined) return .{ .differed = 0, .redefined = true };

            std.debug.print("TREE {s}: AnchorDuplicate without a redefinition\n", .{case.name});

            return .{ .differed = write_sets.len, .redefined = false };
        },
        else => {
            std.debug.print("TREE {s}: the copy failed with {t}\n", .{ case.name, err });

            return .{ .differed = write_sets.len, .redefined = redefined };
        },
    };

    if (redefined) {
        std.debug.print("TREE {s}: an anchor redefinition was copied\n", .{case.name});

        return .{ .differed = write_sets.len, .redefined = true };
    }

    var outcome: TreeOutcome = .{ .differed = 0, .redefined = false };

    for (&write_sets, 0..) |*set, index| {
        const options = &set.options;
        const expected = try document_written(&workspace.document, options, &workspace.written);
        const written = try tree_written(&workspace.tree, options, &workspace.tree_written);
        if (std.mem.eql(u8, expected, written)) continue;

        std.debug.print("TREE {s}: set {d}: the copy writes differently\n", .{ case.name, index });
        written_print(written);

        outcome.differed += 1;
    }

    return outcome;
}

fn tree_copy(workspace: *Workspace) yaml.Tree.EditError!void {
    assert(workspace.document.document.composer.frame_count == 0);
    assert(workspace.document.document.document_count <= case_count_max * 1024);

    const document = &workspace.document.document;

    workspace.tree.init(.{ .schema = .core });

    for (0..document.root_count()) |index| {
        const root = document.root(@intCast(index));

        const content: yaml.Tree.Content = .{
            .copy = .{ .document = document, .merge = .ignored, .node = root },
        };

        _ = try workspace.tree.root_append(content);
    }
}

fn tree_written(tree: *const Tree, options: *const Writer.Options, buffer: []u8) ![]u8 {
    assert(options.indent >= 1);
    assert(buffer.len == write_bytes_max);

    var sink: std.Io.Writer = .fixed(buffer);

    try tree.write(&sink, options.*);

    return sink.buffered();
}

fn anchor_redefined_is(document: *const yaml.Document) bool {
    assert(document.composer.frame_count == 0);
    assert(document.node_count <= document.storage.nodes.len);

    const nodes = document.storage.nodes;

    for (document.storage.roots[0..document.document_count]) |root| {
        const end = root + nodes[root].span;

        for (root..end) |position| {
            if (anchor_defined_earlier_is(nodes[root..end], @intCast(position - root))) return true;
        }
    }

    return false;
}

fn anchor_defined_earlier_is(nodes: []const storage_module.Record, position: u32) bool {
    assert(position < nodes.len);
    assert(nodes.len <= std.math.maxInt(u32));

    const record = &nodes[position];
    if (record.kind == .alias) return false;
    if (record.anchor.len == 0) return false;

    for (nodes[0..position]) |*earlier| {
        if (earlier.kind == .alias) continue;
        if (std.mem.eql(u8, earlier.anchor, record.anchor)) return true;
    }

    return false;
}

fn written_print(written: []const u8) void {
    assert(written.len <= 2 * corpus_bytes_max);
    assert(write_bytes_max > 0);

    const shown = written[0..@min(written.len, written_shown_max)];

    std.debug.print("--- written ---\n{f}\n--- end ---\n", .{std.zig.fmtString(shown)});
}

fn emitted_run(io: std.Io, workspace: *Workspace, options: RunOptions) !EmittedTally {
    assert(options.root.len > 0);
    assert(workspace.names.count <= case_count_max);

    var tally: EmittedTally = .{
        .emit_count = 0,
        .emit_identical = 0,
        .out_count = 0,
        .out_identical = 0,
    };

    for (workspace.names.slice()) |*name| {
        if (options.filter.len > 0) {
            if (!std.mem.startsWith(u8, name.slice(), options.filter)) continue;
        }

        const case = Case{ .name = name.slice(), .root = options.root };
        if (case_file_present(io, &case, "error")) continue;

        if (case_file_present(io, &case, "out.yaml")) {
            tally.out_count += 1;
            tally.out_identical += @intFromBool(try emitted_is(io, workspace, &case, .out));
        }

        if (case_file_present(io, &case, "emit.yaml")) {
            tally.emit_count += 1;
            tally.emit_identical += @intFromBool(try emitted_is(io, workspace, &case, .emit));
        }
    }

    assert(tally.out_identical <= tally.out_count);
    assert(tally.emit_identical <= tally.emit_count);

    return tally;
}

const Emission = enum {
    emit,
    out,
};

fn emitted_is(io: std.Io, workspace: *Workspace, case: *const Case, emission: Emission) !bool {
    assert(case.name.len > 0);
    assert(case.root.len > 0);

    const file = switch (emission) {
        .emit => "emit.yaml",
        .out => "out.yaml",
    };

    const options = switch (emission) {
        .emit => &options_emit,
        .out => &options_out,
    };

    const source = try case_file_read(io, case, "in.yaml", &workspace.source);
    const parsed = workspace.document.parse(source, .{ .schema = .core });
    const composed = if (parsed) true else |_| false;
    const input: WriteInput = .{ .composed = composed, .source = source };
    const expected = try case_file_read(io, case, file, &workspace.expected);
    const written = try case_written(workspace, &input, options, &workspace.written);

    return std.mem.eql(u8, expected, written);
}

fn rejection_report(
    case: *const Case,
    comparison: *const Comparison,
    err: anyerror,
    diagnostic: parser_module.Position,
) Outcome {
    assert(case.name.len > 0);
    assert(@errorName(err).len > 0);
    assert(diagnostic.line >= 1);

    const rejection = rejection_of(comparison);

    if (rejection == .late) {
        std.debug.print("LATE {s}: {t} at {d}:{d}\n", .{
            case.name,
            err,
            diagnostic.line,
            diagnostic.column,
        });

        difference_report(case, comparison);
    }

    return .{ .rejected = rejection };
}

fn rejection_of(comparison: *const Comparison) Rejection {
    assert(comparison.expected.len <= rendered_bytes_max);
    assert(comparison.rendered.len <= rendered_bytes_max);

    if (std.mem.eql(u8, comparison.expected, comparison.rendered)) return .exact;
    if (std.mem.startsWith(u8, comparison.expected, comparison.rendered)) return .early;
    return .late;
}

fn case_file_read(io: std.Io, case: *const Case, file: []const u8, buffer: []u8) ![]const u8 {
    assert(case.root.len > 0);
    assert(case.name.len > 0);
    assert(file.len > 0);
    assert(buffer.len > 0);

    var path: Path = .empty;

    try path.print("{s}/{s}/{s}", .{ case.root, case.name, file });

    const content = std.Io.Dir.cwd().readFile(io, path.slice(), buffer) catch |err| switch (err) {
        error.FileNotFound => return "",
        else => |other| return other,
    };

    if (content.len == buffer.len) return error.FileTooLarge;
    return content;
}

fn case_file_present(io: std.Io, case: *const Case, file: []const u8) bool {
    assert(case.root.len > 0);
    assert(case.name.len > 0);
    assert(file.len > 0);

    var path: Path = .empty;

    path.print("{s}/{s}/{s}", .{ case.root, case.name, file }) catch return false;

    std.Io.Dir.cwd().access(io, path.slice(), .{ .follow_symlinks = true, .read = true }) catch {
        return false;
    };

    return true;
}

fn difference_report(case: *const Case, comparison: *const Comparison) void {
    assert(case.name.len > 0);
    assert(comparison.expected.len <= rendered_bytes_max);
    assert(comparison.rendered.len <= rendered_bytes_max);

    var expected_lines = std.mem.splitScalar(u8, comparison.expected, '\n');
    var rendered_lines = std.mem.splitScalar(u8, comparison.rendered, '\n');

    for (1..event_count_max) |number| {
        const left = expected_lines.next();
        const right = rendered_lines.next();

        if (left == null) {
            if (right == null) return;
        }

        const left_text = left orelse "<end>";
        const right_text = right orelse "<end>";

        if (!std.mem.eql(u8, left_text, right_text)) {
            std.debug.print("DIFF {s}: line {d}: expected `{s}`, got `{s}`\n", .{
                case.name,
                number,
                left_text,
                right_text,
            });

            return;
        }
    }
}

fn events_render(parser: *Parser, source: []const u8, text: []u8, writer: *std.Io.Writer) !void {
    assert(source.len <= source_bytes_max);
    assert(text.len == text_bytes_max);

    parser.init(text, source);

    for (0..event_count_max) |_| {
        const event = try parser.next();

        try event_write(writer, event);
        try writer.writeByte('\n');

        if (event.* == .stream_end) return;
    }

    return error.EventsExhausted;
}

fn event_write(writer: *std.Io.Writer, event: *const Event) !void {
    assert(writer.buffer.len > 0);
    assert(@backingInt(event.*) <= 9);

    switch (event.*) {
        .alias => |alias| try writer.print("=ALI *{s}", .{alias.anchor}),
        .document_end => |end| try writer.writeAll(if (end.explicit) "-DOC ..." else "-DOC"),
        .document_start => |start| try writer.writeAll(if (start.explicit) "+DOC ---" else "+DOC"),
        .mapping_end => try writer.writeAll("-MAP"),
        .mapping_start => |start| try collection_write(writer, "+MAP", &start),
        .scalar => |scalar| try scalar_write(writer, &scalar),
        .sequence_end => try writer.writeAll("-SEQ"),
        .sequence_start => |start| try collection_write(writer, "+SEQ", &start),
        .stream_end => try writer.writeAll("-STR"),
        .stream_start => try writer.writeAll("+STR"),
    }
}

fn collection_write(
    writer: *std.Io.Writer,
    marker: []const u8,
    start: *const Event.CollectionStart,
) !void {
    assert(marker.len == 4);
    assert(writer.buffer.len > 0);

    try writer.writeAll(marker);

    if (start.style == .flow) {
        try writer.writeAll(if (marker[1] == 'M') " {}" else " []");
    }

    try properties_write(writer, &.{ .anchor = start.anchor, .tag = start.tag });
}

fn properties_write(writer: *std.Io.Writer, properties: *const PropertiesText) !void {
    assert(writer.buffer.len > 0);
    assert(properties.anchor.len <= source_bytes_max);
    assert(properties.tag.len <= text_bytes_max);

    if (properties.anchor.len > 0) try writer.print(" &{s}", .{properties.anchor});
    if (properties.tag.len > 0) try writer.print(" <{s}>", .{properties.tag});
}

fn scalar_write(writer: *std.Io.Writer, scalar: *const Event.Scalar) !void {
    assert(writer.buffer.len > 0);
    assert(scalar.text.len <= text_bytes_max);

    try writer.writeAll("=VAL");
    try properties_write(writer, &.{ .anchor = scalar.anchor, .tag = scalar.tag });

    const indicator: u8 = switch (scalar.style) {
        .double_quoted => '"',
        .folded => '>',
        .literal => '|',
        .plain => ':',
        .single_quoted => '\'',
    };

    try writer.writeByte(' ');
    try writer.writeByte(indicator);

    for (scalar.text) |byte| {
        switch (byte) {
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\t' => try writer.writeAll("\\t"),
            '\r' => try writer.writeAll("\\r"),
            0x08 => try writer.writeAll("\\b"),
            0x00 => try writer.writeAll("\\0"),
            0x07 => try writer.writeAll("\\a"),
            0x0b => try writer.writeAll("\\v"),
            0x0c => try writer.writeAll("\\f"),
            0x1b => try writer.writeAll("\\e"),
            else => try writer.writeByte(byte),
        }
    }
}

const testing = std.testing;

test "a stream of JSON values is split where each top-level value ends" {
    const stream = "{\"a\": [1, \"]\"]}\n null 3.5 \"x\\\"y\" [[], {}]";

    try testing.expectEqual(@as(u32, 15), json_value_end(stream, 0));
    try testing.expectEqual(@as(u32, 17), json_blank_skip(stream, 15));
    try testing.expectEqual(@as(u32, 21), json_value_end(stream, 17));
    try testing.expectEqual(@as(u32, 25), json_value_end(stream, 22));
    try testing.expectEqual(@as(u32, 32), json_value_end(stream, 26));
    try testing.expectEqual(@as(u32, 41), json_value_end(stream, 33));
    try testing.expectEqual(@as(u32, stream.len), json_blank_skip(stream, 41));
}

test "a composed document matches the JSON of its core-schema values and nothing else" {
    const workspace = try testing.allocator.create(Workspace);
    defer testing.allocator.destroy(workspace);

    const source = "a: [1, true, ~, 0x1F, 1.5, 'x', !!str 2]\nb: &x {c: d}\ne: *x\n";

    try workspace.document.parse(source, .{ .schema = .core });

    const matching =
        \\{"e": {"c": "d"}, "a": [1, true, null, 31, 1.5, "x", "2"], "b": {"c": "d"}}
    ;

    const differing = [_][]const u8{
        \\{"a": [1, false, null, 31, 1.5, "x", "2"], "b": {"c": "d"}, "e": {"c": "d"}}
        ,
        \\{"a": [1, true, null, 31, 1.5, "x", 2], "b": {"c": "d"}, "e": {"c": "d"}}
        ,
        \\{"a": [1, true, null, 31, 1.5, "x"], "b": {"c": "d"}, "e": {"c": "d"}}
        ,
        \\{"a": [1, true, null, 31, 1.5, "x", "2"], "b": {"c": "d"}, "e": {"c": "z"}}
        ,
        \\{"a": [1, true, null, 31, 1.5, "x", "2"], "b": {"c": "d"}, "f": {"c": "d"}}
        ,
    };

    try testing.expectEqual(@as(?[]const u8, null), json_compare(workspace, matching));

    for (differing) |text| try testing.expect(json_compare(workspace, text) != null);
}

fn json_compare(workspace: *Workspace, text: []const u8) ?[]const u8 {
    assert(text.len > 0);
    assert(workspace.document.root_count() == 1);

    var values: std.heap.FixedBufferAllocator = .init(&workspace.json_values);

    const expected = std.json.parseFromSliceLeaky(std.json.Value, values.allocator(), text, .{
        .duplicate_field_behavior = .@"error",
        .ignore_unknown_fields = false,
        .max_value_len = null,
        .allocate = .alloc_always,
        .parse_numbers = true,
    }) catch return "invalid";

    const root: ValuePair = .{ .expected = &expected, .node = workspace.document.root(0) };
    return tree_difference(&workspace.document, root, &workspace.frames);
}

test "the JSON comparison finds a changed value, key, length, and kind, and accepts number forms" {
    const workspace = try testing.allocator.create(Workspace);
    defer testing.allocator.destroy(workspace);

    var values: std.heap.FixedBufferAllocator = .init(&workspace.json_values);

    const expected_text = "{\"a\": [1, 2.5, \"x\"], \"b\": {\"c\": null, \"d\": true}}";
    const expected = try json_parse(values.allocator(), expected_text);

    const matching = [_][]const u8{
        "{\"b\":{\"d\":true,\"c\":null},\"a\":[1.0,2.5e0,\"x\"]}",
        "{\"a\":[1,25e-1,\"x\"],\"b\":{\"c\":null,\"d\":true}}",
    };

    const differing = [_][]const u8{
        "{\"a\":[1,2.5,\"y\"],\"b\":{\"c\":null,\"d\":true}}",
        "{\"a\":[1,2.5,\"x\"],\"b\":{\"c\":null,\"e\":true}}",
        "{\"a\":[1,2.5],\"b\":{\"c\":null,\"d\":true}}",
        "{\"a\":[1,2.5,\"x\"],\"b\":{\"c\":0,\"d\":true}}",
        "{\"a\":[2,2.5,\"x\"],\"b\":{\"c\":null,\"d\":true}}",
        "{\"a\":[1,2.5,\"x\"],\"b\":{\"c\":null,\"d\":false}}",
        "{\"a\":[1,2.5,\"x\"],\"b\":{\"c\":null,\"d\":true},\"f\":1}",
    };

    for (matching) |text| {
        const actual = try json_parse(values.allocator(), text);
        const pair: JSONPair = .{ .actual = &actual, .expected = &expected };
        const difference = json_difference(&pair, &workspace.json_pairs);

        try testing.expectEqual(@as(?[]const u8, null), difference);
    }

    for (differing) |text| {
        const actual = try json_parse(values.allocator(), text);
        const pair: JSONPair = .{ .actual = &actual, .expected = &expected };

        try testing.expect(json_difference(&pair, &workspace.json_pairs) != null);
    }
}
