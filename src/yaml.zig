const std = @import("std");
const assert = std.debug.assert;

const codec = @import("codec.zig");
const comment_module = @import("comment.zig");
const document_module = @import("document.zig");
const json_writer = @import("json_writer.zig");
const merge_module = @import("merge.zig");
const parser_module = @import("parser.zig");
const region_module = @import("region.zig");
const scanner_module = @import("scanner.zig");
const storage_module = @import("storage.zig");
const tree_module = @import("tree.zig");
const writer_module = @import("writer.zig");

pub const Capacity = document_module.Capacity;
pub const CapacityError = document_module.CapacityError;
pub const CollectionStyle = document_module.CollectionStyle;
pub const Comment = comment_module.Comment;
pub const Comments = comment_module.Comments;
pub const DecodeError = codec.DecodeError;
pub const DecodeOptions = codec.DecodeOptions;
pub const Document = document_module.Document;
pub const DocumentType = document_module.DocumentType;
pub const EncodeOptions = codec.EncodeOptions;
pub const Entries = document_module.Entries;
pub const EntryType = codec.EntryType;

pub const Error = CapacityError ||
    DecodeError ||
    Document.Error ||
    JSONOptions.Error ||
    Parser.Error ||
    std.mem.Allocator.Error ||
    SyntaxError ||
    Tree.EditError ||
    Tree.RemoveError ||
    Writer.Error;

pub const Event = parser_module.Event;
pub const Items = document_module.Items;
pub const JSONOptions = json_writer.JSONOptions;
pub const Kind = document_module.Kind;
pub const Merge = merge_module.Merge;
pub const MismatchError = codec.MismatchError;
pub const Node = document_module.Node;
pub const Parser = parser_module.Parser;
pub const Position = document_module.Position;
pub const Region = region_module.Region;
pub const ScalarStyle = document_module.ScalarStyle;
pub const Schema = document_module.Schema;
pub const Storage = document_module.Storage;
pub const StorageType = storage_module.StorageType;
pub const Style = document_module.Style;
pub const SyntaxError = document_module.SyntaxError;
pub const Tree = tree_module.Tree;
pub const TreeType = tree_module.TreeType;
pub const Writer = writer_module.Writer;

pub const decode = codec.decode;
pub const encode = codec.encode;

pub fn message(err: Error) []const u8 {
    assert(@errorName(err).len > 0);

    const result: []const u8 = switch (err) {
        error.AliasInvalid => "the alias does not name an earlier anchored node",
        error.AliasRecursive => "an alias refers to the node that contains it",
        error.AliasUndefined => "undefined alias",
        error.AnchorDuplicate => "duplicate anchor",
        error.AnchorInvalid => "invalid anchor",
        error.AnchorReferenced => "an alias still refers to the anchored node",
        error.AnchorsExhausted => "the document holds more anchors than its capacity",
        error.BlockScalarInvalid => "invalid block scalar",
        error.CharacterInvalid => "invalid character",
        error.CommentInvalid => "invalid comment",
        error.CommentsExhausted => "the document holds more comments than its capacity",
        error.DepthExceeded => "nesting is deeper than the limit",
        error.DirectiveDuplicate => "duplicate directive",
        error.DirectiveInvalid => "invalid directive",
        error.DocumentInvalid => "invalid document start",
        error.DocumentMarkerInvalid => "invalid document marker",
        error.EnumerationUnrecognized => "an unrecognized enumeration value cannot be written",
        error.EscapeInvalid => "invalid escape sequence",
        error.ExpansionExceeded => "alias expansion holds more nodes than the limit",
        error.FloatNonFinite => "a non-finite float cannot be written",
        error.FlowInvalid => "invalid flow collection",
        error.IndentationInvalid => "invalid indentation",
        error.KeyCollision => "too many keys collide in the key table",
        error.KeyDuplicate => "duplicate key",
        error.KeyInvalid => "invalid key",
        error.MemberMissing => "missing key",
        error.MemberUnknown => "unknown key",
        error.MergeInvalid => "a merge value is not a mapping or a sequence of mappings",
        error.MergesExceeded => "more merged mappings than the limit",
        error.Mismatch => "the value does not match the field's type",
        error.NodesExhausted => "the document holds more nodes than its capacity",
        error.OutOfMemory => "out of memory",
        error.PropertiesInvalid => "invalid anchor or tag placement",
        error.QuoteUnterminated => "unclosed quoted scalar",
        error.RegionFull => "the region is full",
        error.SequenceEntryInvalid => "invalid sequence entry",
        error.StructureInvalid => "invalid structure",
        error.TabInvalid => "a tab where only spaces are allowed",
        error.TagHandleUndefined => "undefined tag handle",
        error.TagInvalid => "invalid tag",
        error.TextExhausted => "the document holds more text than its capacity",
        error.TextInvalid => "invalid UTF-8 or an anchor that cannot be written",
        error.TokensExhausted => "more pending tokens than the limit",
        error.ValueInvalid => "a mapping value is not allowed here",
        error.VersionUnsupported => "unsupported YAML version",
        error.WriteFailed => "the output could not be written",
    };

    assert(result.len > 0);

    return result;
}

pub const limits = struct {
    pub const depth_max: u32 = scanner_module.depth_max;
    pub const merge_source_count_max: u32 = merge_module.source_count_max;
    pub const source_bytes_max: u32 = scanner_module.source_bytes_max;
    pub const writer_depth_max: u32 = writer_module.depth_max;
};

test message {
    const Server = struct {
        port: u16,
    };

    const Fixed = DocumentType(.{
        .anchor_count_max = 4,
        .comment_count_max = null,
        .node_count_max = 16,
        .text_bytes_max = 256,
    });

    var document: Fixed = undefined;
    var buffer: [256]u8 = undefined;
    var region: Region = .init(&buffer);
    var diagnostic: Position = undefined;
    var server: Server = undefined;

    try document.parse("port: '80'\n", .{ .schema = .core });

    const result = decode(Server, &region, &document.document, document.root(0), &server, .{
        .diagnostic = &diagnostic,
    });

    const sentence = "the value does not match the field's type";

    try std.testing.expectError(error.Mismatch, result);
    try std.testing.expectEqualStrings(sentence, message(error.Mismatch));
    try std.testing.expectEqual(Position{ .column = 7, .line = 1, .offset = 6 }, diagnostic);

    const names = @typeInfo(Error).error_set.error_names.?;

    @setEvalBranchQuota(64 * names.len * names.len);

    inline for (names, 0..) |left, index| {
        const text = message(@field(Error, left));

        try std.testing.expect(text.len > 0);

        inline for (names[index + 1 ..]) |right| {
            try std.testing.expect(!std.mem.eql(u8, text, message(@field(Error, right))));
        }
    }
}
