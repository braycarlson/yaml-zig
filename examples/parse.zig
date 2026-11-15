const std = @import("std");

const yaml = @import("yaml");

const assert = std.debug.assert;

const Document = yaml.DocumentType(.{
    .anchor_count_max = 16,
    .comment_count_max = null,
    .node_count_max = 256,
    .text_bytes_max = 4096,
});

const source =
    \\name: warbler
    \\ports:
    \\  - 8080
    \\  - 8443
    \\
;

pub fn main(init: std.process.Init) !void {
    assert(init.minimal.args.vector.len < std.math.maxInt(u32));
    assert(source.len <= yaml.limits.source_bytes_max);

    const document = try init.gpa.create(Document);
    defer init.gpa.destroy(document);

    document.parse(source, .{ .schema = .core }) catch |err| {
        const diagnostic = document.diagnostic();

        std.debug.print("{s} at {d}:{d}\n", .{
            yaml.message(err),
            diagnostic.line,
            diagnostic.column,
        });

        return err;
    };

    const root = document.root(0);
    const name = document.member(root, "name") orelse return error.NameMissing;
    const ports = document.member(root, "ports") orelse return error.PortsMissing;
    const text = document.text_of(name) orelse return error.NameInvalid;

    std.debug.print("name: {s}\n", .{text});

    var items = document.items(ports);

    for (0..document.count_of(ports)) |_| {
        const port = items.next() orelse break;
        const number = document.integer_of(port) orelse return error.PortInvalid;

        std.debug.print("port: {d}\n", .{number});
    }

    const after = items.next();

    assert(after == null);
}
