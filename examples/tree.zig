const std = @import("std");

const yaml = @import("yaml");

const assert = std.debug.assert;

const capacity: yaml.Capacity = .{
    .anchor_count_max = 16,
    .comment_count_max = null,
    .node_count_max = 256,
    .text_bytes_max = 4096,
};

const Document = yaml.DocumentType(capacity);
const Tree = yaml.TreeType(capacity);
const json_tail = "\"worker\":{\"image\":\"base\",\"replicas\":2}}\n";

const source =
    \\defaults: &defaults
    \\  image: base
    \\  replicas: 2
    \\web:
    \\  <<: *defaults
    \\  image: nginx
    \\  ports: [8080]
    \\worker: *defaults
    \\
;

const written =
    \\defaults: &defaults
    \\  image: base
    \\  replicas: 2
    \\web:
    \\  replicas: 3
    \\  image: nginx
    \\  ports: [80, 8080, 8443]
    \\worker: *defaults
    \\
;

pub fn main(init: std.process.Init) !void {
    assert(init.minimal.args.vector.len < std.math.maxInt(u32));
    assert(source.len <= yaml.limits.source_bytes_max);

    const document = try init.gpa.create(Document);
    defer init.gpa.destroy(document);

    const tree = try init.gpa.create(Tree);
    defer init.gpa.destroy(tree);

    try document.parse(source, .{ .schema = .core });

    tree.init(.{ .schema = .core });

    const root = try tree.root_append(.{ .copy = .{
        .document = &document.document,
        .merge = .applied,
        .node = document.root(0),
    } });

    try edit(tree, root);

    var buffer: [1024]u8 = undefined;
    var sink: std.Io.Writer = .fixed(&buffer);

    try tree.write(&sink, .{
        .indent = 2,
        .layout = .preserve,
        .sequence_indentless = false,
        .utf8 = .checked,
        .version_directive = false,
        .width = 0,
    });

    std.debug.print("{s}", .{sink.buffered()});

    assert(std.mem.eql(u8, sink.buffered(), written));

    sink = .fixed(&buffer);

    try tree.write_json(&sink, .{
        .merge = .ignored,
        .node_count_max = 64,
        .non_finite = .refused,
    });

    std.debug.print("{s}", .{sink.buffered()});

    assert(std.mem.endsWith(u8, sink.buffered(), json_tail));
}

fn edit(tree: *Tree, root: yaml.Tree.Node) !void {
    assert(tree.root_count() == 1);
    assert(tree.root(0) == root);

    const defaults = tree.member(root, "defaults") orelse return error.DefaultsMissing;
    const web = tree.member(root, "web") orelse return error.WebMissing;
    const ports = tree.member(web, "ports") orelse return error.PortsMissing;

    _ = try tree.set(web, "replicas", .{ .integer = 3 });
    _ = try tree.append(ports, .{ .integer = 8443 });
    _ = try tree.insert(ports, 0, .{ .integer = 80 });

    tree.remove(defaults) catch |err| switch (err) {
        error.AnchorReferenced => std.debug.print("defaults stays, worker names it\n", .{}),
    };

    assert(tree.member(root, "defaults") == defaults);
}
