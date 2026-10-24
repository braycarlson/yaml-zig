const std = @import("std");

const yaml = @import("yaml");

const assert = std.debug.assert;

const capacity: yaml.Capacity = .{
    .anchor_count_max = 16,
    .comment_count_max = 64,
    .node_count_max = 256,
    .text_bytes_max = 4096,
};

const Document = yaml.DocumentType(capacity);
const Tree = yaml.TreeType(capacity);

const source =
    \\# service settings
    \\name: warbler # public name
    \\ports:
    \\  - 8080 # http
    \\
    \\# retired
    \\legacy: true
    \\
;

const written =
    \\# service settings
    \\name: kestrel # public name
    \\ports:
    \\  - 8080 # http
    \\  - 8443 # https
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
        .node = document.root(0),
    } });

    try comments_print(tree, root);
    try edit(tree, root);

    var buffer: [1024]u8 = undefined;
    var sink: std.Io.Writer = .fixed(&buffer);

    try tree.write(&sink, .{ .indent = 2, .layout = .preserve });

    std.debug.print("{s}", .{sink.buffered()});

    assert(std.mem.eql(u8, sink.buffered(), written));
}

fn comments_print(tree: *const Tree, root: yaml.Tree.Node) !void {
    assert(tree.root_count() == 1);
    assert(tree.kind_of(root) == .mapping);

    const name = tree.member(root, "name") orelse return error.NameMissing;
    var comments = tree.comments(name);

    for (0..capacity.comment_count_max.?) |_| {
        const comment = comments.next() orelse break;

        std.debug.print("{t}: {s}\n", .{ comment.placement, comment.text });
    }
}

fn edit(tree: *Tree, root: yaml.Tree.Node) !void {
    assert(tree.root_count() == 1);
    assert(tree.root(0) == root);

    const name = tree.member(root, "name") orelse return error.NameMissing;
    const ports = tree.member(root, "ports") orelse return error.PortsMissing;
    const legacy = tree.member(root, "legacy") orelse return error.LegacyMissing;

    try tree.replace(name, .{ .string = "kestrel" });

    const port = try tree.append(ports, .{ .integer = 8443 });

    try tree.comment_set(port, .line, "# https");
    try tree.remove(legacy);

    assert(tree.member(root, "legacy") == null);
}
