const std = @import("std");

const yaml = @import("yaml");

const assert = std.debug.assert;

const Document = yaml.DocumentType(.{
    .anchor_count_max = 16,
    .comment_count_max = null,
    .node_count_max = 256,
    .text_bytes_max = 4096,
});

const Reading = struct {
    name: []const u8,
    value: []const u8,
};

const readings = [_]Reading{
    .{ .name = "cpu", .value = "0.375" },
    .{ .name = "disk", .value = "full: 98%" },
    .{ .name = "memory", .value = "1.5e9" },
};

const source =
    \\name: warbler
    \\ports: [8080, 8443]
    \\motto: |
    \\  sings at dawn
    \\
;

pub fn main() !void {
    assert(readings.len > 0);
    assert(source.len <= yaml.limits.source_bytes_max);

    var buffer: [2048]u8 = undefined;
    var sink: std.Io.Writer = .fixed(&buffer);

    try report_write(&sink);

    std.debug.print("{s}", .{sink.buffered()});

    assert(std.mem.endsWith(u8, sink.buffered(), "memory: 1.5e9\n...\n"));

    sink = .fixed(&buffer);

    var document: Document = undefined;

    try document.parse(source, .{ .schema = .core });

    try document.write(&sink, .{
        .indent = 4,
        .layout = .block,
        .sequence_indentless = false,
        .utf8 = .trusted,
        .version_directive = false,
        .width = 0,
    });

    std.debug.print("{s}", .{sink.buffered()});

    assert(std.mem.startsWith(u8, sink.buffered(), "name: warbler\nports:\n    - 8080\n"));
}

fn report_write(sink: *std.Io.Writer) !void {
    assert(sink.end == 0);

    var writer: yaml.Writer = undefined;

    writer.init(sink, .{
        .indent = 2,
        .layout = .preserve,
        .sequence_indentless = false,
        .utf8 = .checked,
        .version_directive = false,
        .width = 0,
    });

    try writer.document_begin(&.{ .explicit = true });
    try writer.mapping_begin(&.{ .style = .block });
    try writer.scalar(&.{ .text = "title" });
    try writer.scalar(&.{ .style = .single_quoted, .text = "nightly report" });
    try writer.scalar(&.{ .text = "readings" });
    try writer.mapping_begin(&.{ .anchor = "latest", .style = .block });

    for (readings) |reading| {
        try writer.scalar(&.{ .text = reading.name });
        try writer.scalar(&.{ .text = reading.value });
    }

    try writer.mapping_end();
    try writer.mapping_end();
    try writer.document_end(&.{ .explicit = true });

    writer.finish();

    assert(std.mem.startsWith(u8, sink.buffered(), "---\ntitle: 'nightly report'\n"));
}
