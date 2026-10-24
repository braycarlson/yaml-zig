const std = @import("std");

const yaml = @import("yaml");

const assert = std.debug.assert;

const Document = yaml.DocumentType(.{
    .anchor_count_max = 16,
    .comment_count_max = null,
    .node_count_max = 256,
    .text_bytes_max = 4096,
});

const Endpoint = union(enum) {
    port: u16,
    socket: []const u8,
};

const Protocol = enum {
    http,
    https,
    unrecognized,
};

const Server = struct {
    endpoint: Endpoint,
    host: []const u8,
    protocol: Protocol = .http,
    tags: []const []const u8 = &.{},

    pub const yaml = .{ .host = "Host" };
};

const source =
    \\Host: localhost
    \\endpoint: 8080
    \\protocol: https
    \\tags: [edge, 'yes']
    \\
;

pub fn main() !void {
    assert(source.len <= yaml.limits.source_bytes_max);

    var document: Document = undefined;

    document.parse(source, .{ .schema = .core }) catch |err| {
        const diagnostic = document.diagnostic();

        std.debug.print("{t} at {d}:{d}\n", .{ err, diagnostic.line, diagnostic.column });

        return err;
    };

    var buffer: [4096]u8 = undefined;
    var region: yaml.Region = .init(&buffer);
    var server: Server = undefined;
    var position: yaml.Position = undefined;

    const root = document.root(0);

    yaml.decode(Server, &region, &document.document, root, &server, .{
        .diagnostic = &position,
        .unknown_members = .refused,
    }) catch |err| {
        std.debug.print("{s} at {d}:{d}\n", .{ yaml.message(err), position.line, position.column });

        return err;
    };

    std.debug.print("host: {s}\n", .{server.host});

    switch (server.endpoint) {
        .port => |port| std.debug.print("port: {d}\n", .{port}),
        .socket => |path| std.debug.print("socket: {s}\n", .{path}),
    }

    for (server.tags) |tag| std.debug.print("tag: {s}\n", .{tag});

    var output: [512]u8 = undefined;
    var sink: std.Io.Writer = .fixed(&output);
    var writer: yaml.Writer = undefined;

    writer.init(&sink, .{
        .indent = 2,
        .layout = .preserve,
        .sequence_indentless = false,
        .utf8 = .trusted,
        .version_directive = false,
        .width = 0,
    });

    try yaml.encode(Server, &writer, &server, .{ .null_members = .omitted });

    writer.finish();

    std.debug.print("{s}", .{sink.buffered()});

    assert(std.mem.startsWith(u8, sink.buffered(), "endpoint: 8080\nHost: localhost\n"));
}
