const std = @import("std");

const assert = std.debug.assert;

comptime {
    _ = @import("attach.zig");
    _ = @import("bounded.zig");
    _ = @import("codec.zig");
    _ = @import("comment.zig");
    _ = @import("composer.zig");
    _ = @import("conformance.zig");
    _ = @import("document.zig");
    _ = @import("document_tests.zig");
    _ = @import("fuzz_model.zig");
    _ = @import("json_writer.zig");
    _ = @import("merge.zig");
    _ = @import("parser.zig");
    _ = @import("region.zig");
    _ = @import("round_trip.zig");
    _ = @import("scanner.zig");
    _ = @import("schema.zig");
    _ = @import("storage.zig");
    _ = @import("tidy.zig");
    _ = @import("tree.zig");
    _ = @import("writer.zig");
    _ = @import("writer_tests.zig");
    _ = @import("yaml.zig");
}

test "every public declaration compiles" {
    const yaml = @import("yaml.zig");

    const Document = yaml.DocumentType(.{
        .anchor_count_max = 16,
        .comment_count_max = null,
        .node_count_max = 256,
        .text_bytes_max = 4096,
    });

    const Tree = yaml.TreeType(.{
        .anchor_count_max = 16,
        .comment_count_max = null,
        .node_count_max = 256,
        .text_bytes_max = 4096,
    });

    comptime assert(@hasDecl(yaml, "DocumentType"));
    comptime assert(@hasDecl(yaml, "Parser"));
    comptime assert(@hasDecl(yaml, "Tree"));
    comptime assert(@hasDecl(yaml, "Writer"));

    std.testing.refAllDecls(yaml);
    std.testing.refAllDecls(yaml.Document);
    std.testing.refAllDecls(yaml.Event);
    std.testing.refAllDecls(yaml.Parser);
    std.testing.refAllDecls(yaml.Tree);
    std.testing.refAllDecls(yaml.Writer);
    std.testing.refAllDecls(yaml.limits);
    std.testing.refAllDecls(Document);
    std.testing.refAllDecls(Tree);
}
