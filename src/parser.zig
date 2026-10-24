const std = @import("std");

const scanner_module = @import("scanner.zig");

const assert = std.debug.assert;

const Scanner = scanner_module.Scanner;
const Token = scanner_module.Token;
const TokenKind = scanner_module.TokenKind;

pub const ScalarStyle = scanner_module.ScalarStyle;

pub const state_capacity: u32 = scanner_module.depth_max * 2 + 8;
pub const tag_cache_count: u32 = 64;
pub const tag_directive_count_max: u32 = 64;
const tag_handle_primary = "!";
const tag_handle_secondary = "!!";
const tag_prefix_secondary = "tag:yaml.org,2002:";

comptime {
    assert(state_capacity > scanner_module.depth_max);
    assert(std.math.isPowerOfTwo(tag_cache_count));
    assert(tag_directive_count_max >= 4);
    assert(@sizeOf(Event) == 72);
}

pub const CapacityError = scanner_module.CapacityError;

pub const SyntaxError = scanner_module.SyntaxError || error{
    DirectiveDuplicate,
    DocumentInvalid,
    PropertiesInvalid,
    StructureInvalid,
    TagHandleUndefined,
    VersionUnsupported,
};

pub const Position = struct {
    column: u32,
    line: u32,
    offset: u32,
};

pub const position_none: Position = .{ .column = 0, .line = 0, .offset = 0 };

pub const CollectionStyle = enum {
    block,
    flow,
};

pub const Event = union(enum) {
    alias: Alias,
    document_end: DocumentEnd,
    document_start: DocumentStart,
    mapping_end,
    mapping_start: CollectionStart,
    scalar: Scalar,
    sequence_end,
    sequence_start: CollectionStart,
    stream_end,
    stream_start,

    pub const Alias = struct {
        anchor: []const u8,
        mark: Mark = .zero,
    };

    pub const CollectionStart = struct {
        anchor: []const u8 = "",
        mark: Mark = .zero,
        style: CollectionStyle = .block,
        tag: []const u8 = "",
    };

    pub const DocumentEnd = struct {
        explicit: bool = false,
        mark: Mark = .zero,
    };

    pub const DocumentStart = struct {
        explicit: bool = false,
        mark: Mark = .zero,
    };

    pub const Mark = scanner_module.Mark;

    pub const Scalar = struct {
        anchor: []const u8 = "",
        mark: Mark = .zero,
        style: ScalarStyle = .plain,
        tag: []const u8 = "",
        text: []const u8,
    };
};

const State = enum(u8) {
    block_mapping_key,
    block_mapping_key_first,
    block_mapping_value,
    block_node,
    block_node_or_indentless_sequence,
    block_sequence_entry,
    block_sequence_entry_first,
    document_content,
    document_end,
    document_start,
    document_start_implicit,
    end,
    flow_mapping_key,
    flow_mapping_key_first,
    flow_mapping_value,
    flow_node,
    flow_sequence_entry,
    flow_sequence_entry_first,
    flow_sequence_entry_mapping_end,
    flow_sequence_entry_mapping_key,
    flow_sequence_entry_mapping_value,
    indentless_sequence_entry,
    stream_start,
};

const TagDirective = struct {
    handle: []const u8,
    prefix: []const u8,
};

const TagCacheEntry = struct {
    handle: []const u8,
    resolved: []const u8,
    suffix: []const u8,
};

const Properties = struct {
    anchor: []const u8,
    mark: Event.Mark,
    present: bool,
    tag: []const u8,
};

const NodeContext = struct {
    block: bool,
    indentless: bool,
};

const context_block: NodeContext = .{ .block = true, .indentless = false };
const context_block_indentless: NodeContext = .{ .block = true, .indentless = true };
const context_flow: NodeContext = .{ .block = false, .indentless = false };

const EntryPlan = struct {
    context: NodeContext,
    empty_kinds: []const TokenKind,
    empty_state: State,
    push_state: State,
};

const TagParts = struct {
    head: []const u8,
    suffix: []const u8,
};

pub const Parser = struct {
    diagnostic: Position,
    document_end_explicit: bool,
    event: Event,
    scanner: Scanner,
    state: State,
    state_count: u32,
    states: [state_capacity]State,
    tag_cache: [tag_cache_count]TagCacheEntry,
    tag_directive_count: u32,
    tag_directives: [tag_directive_count_max]TagDirective,
    version_seen: bool,

    pub const Error = CapacityError || SyntaxError;

    pub fn init(parser: *Parser, text: []u8, source: []const u8) void {
        assert(source.len <= scanner_module.source_bytes_max);
        assert(text.len <= std.math.maxInt(u32));

        parser.diagnostic = position_none;
        parser.document_end_explicit = false;
        parser.event = .stream_end;

        parser.scanner.init(source, text);
        parser.state = .stream_start;
        parser.state_count = 0;
        parser.tag_directive_count = 0;
        parser.version_seen = false;

        for (&parser.tag_cache) |*entry| {
            entry.* = .{ .handle = "", .resolved = "", .suffix = "" };
        }
    }

    pub inline fn next(parser: *Parser) Error!*const Event {
        assert(parser.state != .end);
        assert(parser.state_count <= state_capacity);

        parser.dispatch() catch |err| {
            parser.diagnostic_record(err);

            return err;
        };

        return &parser.event;
    }

    pub fn text_used(parser: *const Parser) u32 {
        assert(parser.scanner.text_used <= parser.scanner.text.len);
        assert(parser.state_count <= state_capacity);

        return parser.scanner.text_used;
    }

    fn diagnostic_record(parser: *Parser, err: Error) void {
        assert(@errorName(err).len > 0);
        assert(parser.scanner.failure.index <= parser.scanner.source.len);

        const failure = parser.scanner.failure;

        parser.diagnostic = .{
            .column = failure.column + 1,
            .line = failure.line + 1,
            .offset = failure.index,
        };
    }

    fn fail(parser: *Parser, mark: Event.Mark, err: Error) Error {
        assert(mark.index <= parser.scanner.source.len);
        assert(@errorName(err).len > 0);

        parser.scanner.failure = mark;

        return err;
    }

    fn dispatch(parser: *Parser) Error!void {
        assert(parser.state != .end);
        assert(parser.state_count <= state_capacity);

        return switch (parser.state) {
            .block_mapping_key => parser.block_mapping_key(false),
            .block_mapping_key_first => parser.block_mapping_key(true),
            .block_mapping_value => parser.block_mapping_value(),
            .block_node => parser.node(context_block),
            .block_node_or_indentless_sequence => parser.node(context_block_indentless),
            .block_sequence_entry => parser.block_sequence_entry(false),
            .block_sequence_entry_first => parser.block_sequence_entry(true),
            .document_content => parser.document_content(),
            .document_end => parser.document_end(),
            .document_start => parser.document_start(false),
            .document_start_implicit => parser.document_start(true),
            .end => unreachable,
            .flow_mapping_key => parser.flow_mapping_key(false),
            .flow_mapping_key_first => parser.flow_mapping_key(true),
            .flow_mapping_value => parser.flow_mapping_value(),
            .flow_node => parser.node(context_flow),
            .flow_sequence_entry => parser.flow_sequence_entry(false),
            .flow_sequence_entry_first => parser.flow_sequence_entry(true),
            .flow_sequence_entry_mapping_end => parser.flow_pair_end(),
            .flow_sequence_entry_mapping_key => parser.flow_pair_key(),
            .flow_sequence_entry_mapping_value => parser.flow_pair_value(),
            .indentless_sequence_entry => parser.indentless_sequence_entry(),
            .stream_start => parser.stream_start(),
        };
    }

    fn peek(parser: *Parser) align(64) Error!*const Token {
        assert(parser.state_count <= state_capacity);
        assert(parser.scanner.token_count <= scanner_module.token_capacity);

        return parser.scanner.token_peek();
    }

    fn skip(parser: *Parser) void {
        assert(parser.scanner.token_count > 0);
        assert(parser.state_count <= state_capacity);

        parser.scanner.token_skip();
    }

    fn push(parser: *Parser, state: State) Error!void {
        assert(state != .end);
        assert(parser.state_count <= state_capacity);

        if (parser.state_count == state_capacity) {
            return parser.fail(parser.scanner.mark, error.DepthExceeded);
        }

        parser.states[parser.state_count] = state;
        parser.state_count += 1;
    }

    fn pop(parser: *Parser) State {
        assert(parser.state_count > 0);
        assert(parser.state_count <= state_capacity);

        parser.state_count -= 1;

        return parser.states[parser.state_count];
    }

    inline fn emit(parser: *Parser, event: Event) void {
        assert(parser.state_count <= state_capacity);

        if (parser.state == .end) assert(event == .stream_end);

        parser.event = event;
    }

    fn stream_start(parser: *Parser) Error!void {
        assert(parser.state == .stream_start);
        assert(parser.state_count == 0);

        const token = try parser.peek();

        assert(token.kind == .stream_start);

        parser.skip();
        parser.state = .document_start_implicit;

        return parser.emit(.stream_start);
    }

    fn document_start(parser: *Parser, implicit: bool) Error!void {
        assert(parser.state_count == 0);
        assert(parser.state == .document_start or parser.state == .document_start_implicit);

        var token = try parser.peek();

        for (0..parser.scanner.source.len + 1) |_| {
            if (token.kind != .document_end) break;

            parser.document_end_explicit = true;

            parser.skip();
            token = try parser.peek();
        }

        const bare_allowed = implicit or parser.document_end_explicit;

        const directive = token.kind == .directive_version or token.kind == .directive_tag or
            token.kind == .directive_reserved;

        const bare = bare_allowed and !directive and token.kind != .document_start and
            token.kind != .stream_end;

        if (bare) {
            try parser.directives_reset();
            try parser.push(.document_end);

            parser.state = .block_node;

            return parser.emit(.{ .document_start = .{ .explicit = false, .mark = token.mark } });
        }

        if (token.kind == .stream_end) {
            parser.state = .end;

            parser.skip();

            return parser.emit(.stream_end);
        }

        if (directive) {
            if (!parser.document_end_explicit) {
                if (!implicit) return parser.fail(token.mark, error.DocumentInvalid);
            }
        }

        return parser.document_start_explicit();
    }

    fn document_start_explicit(parser: *Parser) Error!void {
        assert(parser.state_count == 0);
        assert(parser.tag_directive_count <= tag_directive_count_max);

        try parser.directives_process();

        const token = try parser.peek();
        if (token.kind != .document_start) return parser.fail(token.mark, error.DocumentInvalid);

        const mark = token.mark;

        try parser.push(.document_end);

        parser.state = .document_content;

        parser.skip();

        return parser.emit(.{ .document_start = .{ .explicit = true, .mark = mark } });
    }

    fn document_content(parser: *Parser) Error!void {
        assert(parser.state == .document_content);
        assert(parser.state_count > 0);

        const token = try parser.peek();

        const boundary = switch (token.kind) {
            .directive_reserved,
            .directive_tag,
            .directive_version,
            .document_end,
            .document_start,
            .stream_end,
            => true,
            else => false,
        };

        if (boundary) {
            parser.state = parser.pop();

            return parser.emit(empty_scalar(token.mark));
        }

        return parser.node(context_block);
    }

    fn document_end(parser: *Parser) Error!void {
        assert(parser.state == .document_end);
        assert(parser.state_count == 0);

        parser.tag_directive_count = 0;
        parser.version_seen = false;

        const token = try parser.peek();
        const explicit = token.kind == .document_end;
        const event: Event = .{ .document_end = .{ .explicit = explicit, .mark = token.mark } };

        if (explicit) parser.skip();

        parser.document_end_explicit = explicit;
        parser.state = .document_start;

        return parser.emit(event);
    }

    fn directives_reset(parser: *Parser) Error!void {
        assert(parser.state_count == 0);
        assert(parser.tag_directive_count <= tag_directive_count_max);

        parser.tag_directive_count = 0;
        parser.version_seen = false;

        try parser.directives_default();
    }

    fn directives_process(parser: *Parser) Error!void {
        assert(parser.state_count == 0);
        assert(parser.tag_directive_count <= tag_directive_count_max);

        parser.tag_directive_count = 0;
        parser.version_seen = false;

        for (0..parser.scanner.source.len + 1) |_| {
            const token = try parser.peek();

            switch (token.kind) {
                .directive_version => try parser.version_directive(token),
                .directive_tag => try parser.tag_directive(token),
                .directive_reserved => {},
                else => break,
            }

            parser.skip();
        }

        try parser.directives_default();
    }

    fn version_directive(parser: *Parser, token: *const Token) Error!void {
        assert(token.kind == .directive_version);
        assert(token.text.len >= 3);

        if (parser.version_seen) return parser.fail(token.mark, error.DirectiveDuplicate);

        parser.version_seen = true;

        const dot = std.mem.findScalar(u8, token.text, '.') orelse {
            return parser.fail(token.mark, error.DirectiveInvalid);
        };

        const major = std.fmt.parseUnsigned(u32, token.text[0..dot], 10) catch {
            return parser.fail(token.mark, error.VersionUnsupported);
        };

        if (major != 1) return parser.fail(token.mark, error.VersionUnsupported);
    }

    fn tag_directive(parser: *Parser, token: *const Token) Error!void {
        assert(token.kind == .directive_tag);
        assert(token.text.len > 0);

        for (parser.tag_directives[0..parser.tag_directive_count]) |*directive| {
            if (std.mem.eql(u8, directive.handle, token.text)) {
                return parser.fail(token.mark, error.DirectiveDuplicate);
            }
        }

        if (parser.tag_directive_count == tag_directive_count_max) {
            return parser.fail(token.mark, error.DirectiveInvalid);
        }

        parser.tag_directives[parser.tag_directive_count] = .{
            .handle = token.text,
            .prefix = token.extra,
        };

        parser.tag_directive_count += 1;
    }

    fn directives_default(parser: *Parser) Error!void {
        assert(parser.tag_directive_count <= tag_directive_count_max);
        assert(tag_handle_primary.len == 1);

        const defaults = [_]TagDirective{
            .{ .handle = tag_handle_primary, .prefix = tag_handle_primary },
            .{ .handle = tag_handle_secondary, .prefix = tag_prefix_secondary },
        };

        for (&defaults) |*default| {
            if (parser.tag_prefix_of(default.handle) != null) continue;

            if (parser.tag_directive_count == tag_directive_count_max) {
                return parser.fail(parser.scanner.mark, error.DirectiveInvalid);
            }

            parser.tag_directives[parser.tag_directive_count] = default.*;
            parser.tag_directive_count += 1;
        }

        for (&parser.tag_cache) |*entry| {
            entry.* = .{ .handle = "", .resolved = "", .suffix = "" };
        }
    }

    fn tag_prefix_of(parser: *const Parser, handle: []const u8) ?[]const u8 {
        assert(handle.len > 0);
        assert(parser.tag_directive_count <= tag_directive_count_max);

        for (parser.tag_directives[0..parser.tag_directive_count]) |*directive| {
            if (std.mem.eql(u8, directive.handle, handle)) return directive.prefix;
        }

        return null;
    }

    fn node(parser: *Parser, context: NodeContext) align(64) Error!void {
        assert(parser.state_count <= state_capacity);
        assert(context.block or !context.indentless);

        var token = try parser.peek();

        if (token.kind == .alias) {
            const event: Event = .{ .alias = .{ .anchor = token.text, .mark = token.mark } };

            parser.state = parser.pop();

            parser.skip();

            return parser.emit(event);
        }

        var properties = Properties{
            .anchor = "",
            .mark = token.mark,
            .present = false,
            .tag = "",
        };

        switch (token.kind) {
            .anchor, .tag => {
                try parser.properties_read(&properties);

                token = try parser.peek();
            },
            else => {},
        }

        if (context.indentless) {
            if (token.kind == .block_entry) {
                parser.state = .indentless_sequence_entry;

                return parser.emit(collection_start(.sequence_start, &properties, .block));
            }
        }

        return parser.node_content(context, &properties, token);
    }

    fn node_content(
        parser: *Parser,
        context: NodeContext,
        properties: *const Properties,
        token: *const Token,
    ) Error!void {
        assert(parser.state_count <= state_capacity);
        assert(token.mark.index <= parser.scanner.source.len);
        assert(context.block or !context.indentless);

        switch (token.kind) {
            .alias, .anchor, .tag => return parser.fail(token.mark, error.PropertiesInvalid),
            .scalar => {
                const event: Event = .{ .scalar = .{
                    .anchor = properties.anchor,
                    .mark = if (properties.present) properties.mark else token.mark,
                    .style = token.style,
                    .tag = properties.tag,
                    .text = token.text,
                } };

                parser.state = parser.pop();

                parser.skip();

                return parser.emit(event);
            },
            .flow_sequence_start => {
                parser.state = .flow_sequence_entry_first;

                return parser.emit(collection_start(.sequence_start, properties, .flow));
            },
            .flow_mapping_start => {
                parser.state = .flow_mapping_key_first;

                return parser.emit(collection_start(.mapping_start, properties, .flow));
            },
            .block_sequence_start, .block_mapping_start => {
                if (context.block) return parser.block_collection_start(properties, token);
            },
            else => {},
        }

        if (properties.present) {
            parser.state = parser.pop();

            return parser.emit(.{ .scalar = .{
                .anchor = properties.anchor,
                .mark = properties.mark,
                .style = .plain,
                .tag = properties.tag,
                .text = "",
            } });
        }

        return parser.fail(token.mark, error.StructureInvalid);
    }

    fn block_collection_start(
        parser: *Parser,
        properties: *const Properties,
        token: *const Token,
    ) Error!void {
        assert(token.kind == .block_sequence_start or token.kind == .block_mapping_start);
        assert(properties.mark.index <= token.mark.index or !properties.present);

        if (properties.present) {
            if (properties.mark.line == token.mark.line) {
                return parser.fail(token.mark, error.PropertiesInvalid);
            }
        }

        if (token.kind == .block_sequence_start) {
            parser.state = .block_sequence_entry_first;

            return parser.emit(collection_start(.sequence_start, properties, .block));
        }

        parser.state = .block_mapping_key_first;

        return parser.emit(collection_start(.mapping_start, properties, .block));
    }

    fn properties_read(parser: *Parser, properties: *Properties) Error!void {
        assert(!properties.present);
        assert(parser.state_count <= state_capacity);

        for (0..2) |_| {
            const token = try parser.peek();

            switch (token.kind) {
                .anchor => {
                    if (properties.anchor.len > 0) {
                        return parser.fail(token.mark, error.PropertiesInvalid);
                    }

                    properties.anchor = token.text;
                },
                .tag => {
                    if (properties.tag.len > 0) {
                        return parser.fail(token.mark, error.PropertiesInvalid);
                    }

                    properties.tag = try parser.tag_resolve(token);
                },
                else => return,
            }

            if (!properties.present) properties.mark = token.mark;

            properties.present = true;

            parser.skip();
        }
    }

    fn tag_resolve(parser: *Parser, token: *const Token) Error![]const u8 {
        assert(token.kind == .tag);
        assert(token.text.len <= token.mark.index + token.text.len);

        const handle = token.text;
        const suffix = token.extra;
        if (handle.len == 0) return parser.uri_decode(token, &.{ .head = "", .suffix = suffix });
        if (suffix.len == 0) return tag_handle_primary;

        const slot = cache_slot_of(&.{ .head = handle, .suffix = suffix });
        const entry = &parser.tag_cache[slot];

        if (std.mem.eql(u8, entry.handle, handle)) {
            if (std.mem.eql(u8, entry.suffix, suffix)) return entry.resolved;
        }

        const prefix = parser.tag_prefix_of(handle) orelse {
            return parser.fail(token.mark, error.TagHandleUndefined);
        };

        const resolved = try parser.uri_decode(token, &.{ .head = prefix, .suffix = suffix });

        entry.* = .{ .handle = handle, .resolved = resolved, .suffix = suffix };

        return resolved;
    }

    fn uri_decode(parser: *Parser, token: *const Token, parts: *const TagParts) Error![]const u8 {
        assert(token.kind == .tag);
        assert(parts.suffix.len + parts.head.len > 0);

        const prefix = parts.head;
        const suffix = parts.suffix;

        const escaped = std.mem.findScalar(u8, prefix, '%') != null or
            std.mem.findScalar(u8, suffix, '%') != null;

        if (!escaped) {
            if (prefix.len == 0) return suffix;

            const handle = token.text;
            const adjacent = handle.ptr + handle.len == suffix.ptr;
            const contiguous = adjacent and std.mem.eql(u8, prefix, handle);
            if (contiguous) return handle.ptr[0 .. handle.len + suffix.len];
        }

        const scanner = &parser.scanner;
        const start = scanner.text_used;

        try parser.percent_append(token, prefix);
        try parser.percent_append(token, suffix);

        const resolved = scanner.text[start..scanner.text_used];
        const valid = std.unicode.utf8ValidateSlice(resolved);
        if (!valid) return parser.fail(token.mark, error.TagInvalid);
        return resolved;
    }

    fn percent_append(parser: *Parser, token: *const Token, text: []const u8) Error!void {
        assert(token.kind == .tag);
        assert(text.len <= std.math.maxInt(u32));

        var index: u32 = 0;

        for (0..text.len) |_| {
            if (index == text.len) return;

            if (text[index] != '%') {
                const end = std.mem.findScalarPos(u8, text, index, '%') orelse text.len;

                try parser.scanner.text_append(text[index..end]);

                index = @intCast(end);

                continue;
            }

            if (index + 3 > text.len) return parser.fail(token.mark, error.TagInvalid);

            const byte = std.fmt.parseUnsigned(u8, text[index + 1 .. index + 3], 16) catch {
                return parser.fail(token.mark, error.TagInvalid);
            };

            try parser.scanner.text_append(&.{byte});

            index += 3;
        }
    }

    fn block_sequence_entry(parser: *Parser, first: bool) align(64) Error!void {
        assert(parser.state_count <= state_capacity);
        assert(first == (parser.state == .block_sequence_entry_first));

        if (first) parser.skip();

        const token = try parser.peek();

        if (token.kind == .block_end) {
            parser.state = parser.pop();

            parser.skip();

            return parser.emit(.sequence_end);
        }

        if (token.kind != .block_entry) return parser.fail(token.mark, error.StructureInvalid);

        return parser.entry_node(token.mark, &.{
            .context = context_block,
            .empty_kinds = &.{ .block_entry, .block_end },
            .empty_state = .block_sequence_entry,
            .push_state = .block_sequence_entry,
        });
    }

    fn indentless_sequence_entry(parser: *Parser) Error!void {
        assert(parser.state == .indentless_sequence_entry);
        assert(parser.state_count > 0);

        const token = try parser.peek();

        if (token.kind != .block_entry) {
            parser.state = parser.pop();

            return parser.emit(.sequence_end);
        }

        return parser.entry_node(token.mark, &.{
            .context = context_block,
            .empty_kinds = &.{ .block_entry, .key, .value, .block_end },
            .empty_state = .indentless_sequence_entry,
            .push_state = .indentless_sequence_entry,
        });
    }

    fn block_mapping_key(parser: *Parser, first: bool) align(64) Error!void {
        assert(parser.state_count <= state_capacity);
        assert(first == (parser.state == .block_mapping_key_first));

        if (first) parser.skip();

        const token = try parser.peek();

        switch (token.kind) {
            .block_end => {
                parser.state = parser.pop();

                parser.skip();

                return parser.emit(.mapping_end);
            },
            .value => {
                parser.state = .block_mapping_value;

                return parser.emit(empty_scalar(token.mark));
            },
            .key => {},
            else => return parser.fail(token.mark, error.StructureInvalid),
        }

        return parser.entry_node(token.mark, &.{
            .context = context_block_indentless,
            .empty_kinds = &.{ .key, .value, .block_end },
            .empty_state = .block_mapping_value,
            .push_state = .block_mapping_value,
        });
    }

    fn block_mapping_value(parser: *Parser) Error!void {
        assert(parser.state == .block_mapping_value);
        assert(parser.state_count > 0);

        const token = try parser.peek();

        if (token.kind != .value) {
            parser.state = .block_mapping_key;

            return parser.emit(empty_scalar(token.mark));
        }

        return parser.entry_node(token.mark, &.{
            .context = context_block_indentless,
            .empty_kinds = &.{ .key, .value, .block_end },
            .empty_state = .block_mapping_key,
            .push_state = .block_mapping_key,
        });
    }

    fn entry_node(
        parser: *Parser,
        indicator: Event.Mark,
        plan: *const EntryPlan,
    ) align(64) Error!void {
        assert(indicator.index <= parser.scanner.source.len);
        assert(plan.empty_kinds.len > 0);

        parser.skip();

        const after = try parser.peek();
        const empty = std.mem.findScalar(TokenKind, plan.empty_kinds, after.kind) != null;

        if (empty) {
            parser.state = plan.empty_state;

            return parser.emit(empty_scalar(indicator));
        }

        try parser.push(plan.push_state);

        return parser.node(plan.context);
    }

    fn flow_sequence_entry(parser: *Parser, first: bool) align(64) Error!void {
        assert(parser.state_count <= state_capacity);
        assert(parser.state == .flow_sequence_entry or parser.state == .flow_sequence_entry_first);

        if (first) parser.skip();

        var token = try parser.peek();
        if (token.kind == .flow_sequence_end) return parser.flow_collection_end(.sequence_end);

        if (!first) {
            if (token.kind != .flow_entry) return parser.fail(token.mark, error.FlowInvalid);

            parser.skip();
            token = try parser.peek();

            if (token.kind == .flow_sequence_end) return parser.flow_collection_end(.sequence_end);
        }

        if (token.kind == .flow_entry) return parser.fail(token.mark, error.FlowInvalid);

        const pair = token.kind == .key or token.kind == .value;

        if (pair) {
            const mark = token.mark;

            if (token.kind == .key) parser.skip();

            parser.state = .flow_sequence_entry_mapping_key;

            return parser.emit(.{ .mapping_start = .{
                .anchor = "",
                .mark = mark,
                .style = .flow,
                .tag = "",
            } });
        }

        try parser.push(.flow_sequence_entry);

        return parser.node(context_flow);
    }

    fn flow_collection_end(parser: *Parser, event: Event) Error!void {
        assert(event == .sequence_end or event == .mapping_end);
        assert(parser.state_count > 0);

        parser.state = parser.pop();

        parser.skip();

        return parser.emit(event);
    }

    fn flow_pair_key(parser: *Parser) Error!void {
        assert(parser.state == .flow_sequence_entry_mapping_key);
        assert(parser.state_count > 0);

        const token = try parser.peek();

        const empty = switch (token.kind) {
            .value, .flow_entry, .flow_sequence_end => true,
            else => false,
        };

        if (empty) {
            parser.state = .flow_sequence_entry_mapping_value;

            return parser.emit(empty_scalar(token.mark));
        }

        try parser.push(.flow_sequence_entry_mapping_value);

        return parser.node(context_flow);
    }

    fn flow_pair_value(parser: *Parser) Error!void {
        assert(parser.state == .flow_sequence_entry_mapping_value);
        assert(parser.state_count > 0);

        const token = try parser.peek();

        if (token.kind == .value) {
            parser.skip();

            const after = try parser.peek();
            const empty = after.kind == .flow_entry or after.kind == .flow_sequence_end;

            if (!empty) {
                try parser.push(.flow_sequence_entry_mapping_end);

                return parser.node(context_flow);
            }

            parser.state = .flow_sequence_entry_mapping_end;

            return parser.emit(empty_scalar(after.mark));
        }

        parser.state = .flow_sequence_entry_mapping_end;

        return parser.emit(empty_scalar(token.mark));
    }

    fn flow_pair_end(parser: *Parser) Error!void {
        assert(parser.state == .flow_sequence_entry_mapping_end);
        assert(parser.state_count > 0);

        parser.state = .flow_sequence_entry;

        return parser.emit(.mapping_end);
    }

    fn flow_mapping_key(parser: *Parser, first: bool) align(64) Error!void {
        assert(parser.state_count <= state_capacity);
        assert(parser.state == .flow_mapping_key or parser.state == .flow_mapping_key_first);

        if (first) parser.skip();

        var token = try parser.peek();
        if (token.kind == .flow_mapping_end) return parser.flow_collection_end(.mapping_end);

        if (!first) {
            if (token.kind != .flow_entry) return parser.fail(token.mark, error.FlowInvalid);

            parser.skip();
            token = try parser.peek();

            if (token.kind == .flow_mapping_end) return parser.flow_collection_end(.mapping_end);
        }

        switch (token.kind) {
            .flow_entry => return parser.fail(token.mark, error.FlowInvalid),
            .value => {
                parser.state = .flow_mapping_value;

                return parser.emit(empty_scalar(token.mark));
            },
            .key => return parser.flow_mapping_explicit_key(),
            else => {},
        }

        try parser.push(.flow_mapping_value);

        return parser.node(context_flow);
    }

    fn flow_mapping_explicit_key(parser: *Parser) Error!void {
        assert(parser.state_count <= state_capacity);
        assert(parser.scanner.token_count > 0);

        parser.skip();

        const token = try parser.peek();

        const empty = switch (token.kind) {
            .value, .flow_entry, .flow_mapping_end => true,
            else => false,
        };

        if (empty) {
            parser.state = .flow_mapping_value;

            return parser.emit(empty_scalar(token.mark));
        }

        try parser.push(.flow_mapping_value);

        return parser.node(context_flow);
    }

    fn flow_mapping_value(parser: *Parser) Error!void {
        assert(parser.state == .flow_mapping_value);
        assert(parser.state_count > 0);

        const token = try parser.peek();

        if (token.kind == .value) {
            parser.skip();

            const after = try parser.peek();
            const empty = after.kind == .flow_entry or after.kind == .flow_mapping_end;

            if (!empty) {
                try parser.push(.flow_mapping_key);

                return parser.node(context_flow);
            }

            parser.state = .flow_mapping_key;

            return parser.emit(empty_scalar(after.mark));
        }

        parser.state = .flow_mapping_key;

        return parser.emit(empty_scalar(token.mark));
    }
};

fn empty_scalar(mark: Event.Mark) Event {
    assert(mark.line <= std.math.maxInt(u32));
    assert(mark.column <= std.math.maxInt(u32));

    return .{ .scalar = .{ .anchor = "", .mark = mark, .style = .plain, .tag = "", .text = "" } };
}

const CollectionKind = enum {
    mapping_start,
    sequence_start,
};

fn collection_start(
    kind: CollectionKind,
    properties: *const Properties,
    style: CollectionStyle,
) Event {
    assert(properties.anchor.len <= scanner_module.source_bytes_max);
    assert(@backingInt(style) <= 1);

    const start = Event.CollectionStart{
        .anchor = properties.anchor,
        .mark = properties.mark,
        .style = style,
        .tag = properties.tag,
    };

    return switch (kind) {
        .mapping_start => .{ .mapping_start = start },
        .sequence_start => .{ .sequence_start = start },
    };
}

fn cache_slot_of(parts: *const TagParts) u32 {
    assert(parts.head.len > 0);
    assert(parts.suffix.len > 0);

    var hasher = std.hash.Wyhash.init(parts.head.len);

    hasher.update(parts.head);
    hasher.update(parts.suffix);

    const slot: u32 = @intCast(hasher.final() & (tag_cache_count - 1));

    assert(slot < tag_cache_count);

    return slot;
}

test Parser {
    const parser = try std.testing.allocator.create(Parser);
    defer std.testing.allocator.destroy(parser);

    var text: [256]u8 = undefined;

    parser.init(&text, "- &a warbler\n- *a\n");

    const kinds = [_]std.meta.Tag(Event){
        .stream_start,
        .document_start,
        .sequence_start,
        .scalar,
        .alias,
        .sequence_end,
        .document_end,
        .stream_end,
    };

    for (kinds) |kind| {
        const event = try parser.next();

        try std.testing.expectEqual(kind, @as(std.meta.Tag(Event), event.*));

        switch (event.*) {
            .alias => |*alias| try std.testing.expectEqualStrings("a", alias.anchor),
            .scalar => |*scalar| try std.testing.expectEqualStrings("warbler", scalar.text),
            else => {},
        }
    }

    parser.init(&text, "a: b\nc: d: e\n");

    var failure: ?Parser.Error = null;

    for (0..16) |_| {
        const event = parser.next() catch |err| {
            failure = err;

            break;
        };

        if (event.* == .stream_end) break;
    }

    try std.testing.expectEqual(@as(?Parser.Error, error.ValueInvalid), failure);
    try std.testing.expectEqual(@as(u32, 2), parser.diagnostic.line);
    try std.testing.expectEqual(@as(u32, 5), parser.diagnostic.column);
    try std.testing.expectEqual(@as(u32, 9), parser.diagnostic.offset);
}
