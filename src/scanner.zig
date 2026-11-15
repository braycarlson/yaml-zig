const std = @import("std");

const storage_module = @import("storage.zig");

const assert = std.debug.assert;

const CommentSlot = storage_module.CommentSlot;

pub const depth_max: u32 = 256;
pub const key_columns_max: u32 = 1024;
pub const source_bytes_max: u32 = 1 << 31;
pub const token_capacity: u32 = 4096;
const byte_order_mark = "\xef\xbb\xbf";
const index_none: u32 = std.math.maxInt(u32);
const lane_count: u32 = 32;
const wide_count: u32 = 64;
const lookahead_max: u32 = 4;

comptime {
    assert(std.math.isPowerOfTwo(lane_count));
    assert(std.math.isPowerOfTwo(token_capacity));
    assert(token_capacity > 2 * key_columns_max + depth_max);
    assert(source_bytes_max < index_none);
    assert(depth_max >= 64);
}

pub const CapacityError = error{
    CommentsExhausted,
    DepthExceeded,
    TextExhausted,
    TokensExhausted,
};

pub const SyntaxError = error{
    AnchorInvalid,
    BlockScalarInvalid,
    CharacterInvalid,
    CommentInvalid,
    DirectiveInvalid,
    DocumentMarkerInvalid,
    EscapeInvalid,
    FlowInvalid,
    IndentationInvalid,
    KeyInvalid,
    QuoteUnterminated,
    SequenceEntryInvalid,
    TabInvalid,
    TagInvalid,
    ValueInvalid,
};

pub const Error = CapacityError || SyntaxError;

pub const Mark = struct {
    column: u32,
    index: u32,
    line: u32,

    pub const zero: Mark = .{ .column = 0, .index = 0, .line = 0 };
};

pub const ScalarStyle = enum {
    double_quoted,
    folded,
    literal,
    plain,
    single_quoted,
};

pub const TokenKind = enum {
    alias,
    anchor,
    block_end,
    block_entry,
    block_mapping_start,
    block_sequence_start,
    directive_reserved,
    directive_tag,
    directive_version,
    document_end,
    document_start,
    flow_entry,
    flow_mapping_end,
    flow_mapping_start,
    flow_sequence_end,
    flow_sequence_start,
    key,
    scalar,
    stream_end,
    stream_start,
    tag,
    value,
};

pub const Token = struct {
    extra: []const u8,
    kind: TokenKind,
    mark: Mark,
    style: ScalarStyle,
    text: []const u8,
};

const Chunk = @Vector(lane_count, u8);
const WideChunk = @Vector(wide_count, u8);
const Lanes = @Vector(lane_count, u1);
const Mask = @Int(.unsigned, lane_count);

const Stops = struct {
    blank: bool,
    bytes: []const u8,
};

const CharacterClass = packed struct(u16) {
    blank: bool,
    digit: bool,
    flow: bool,
    hexadecimal: bool,
    line_break: bool,
    tag: bool,
    terminal: bool,
    uri: bool,
    word: bool,
    padding: u7,
};

const classes: [256]CharacterClass = classes_build();
const lanes_carriage_return: Chunk = @splat('\r');
const lanes_high: Chunk = @splat(0x80);
const lanes_line_feed: Chunk = @splat('\n');
const lanes_space: Chunk = @splat(' ');
const lanes_tab: Chunk = @splat('\t');
const lanes_visible_count: Chunk = @splat(0x7f - ' ');
const stops_comment: Stops = .{ .blank = false, .bytes = "\n\r" };
const stops_double_quoted: Stops = .{ .blank = true, .bytes = "\"\\" };
const stops_plain_block: Stops = .{ .blank = true, .bytes = ":" };
const stops_plain_flow: Stops = .{ .blank = true, .bytes = ":,[]{}" };
const stops_single_quoted: Stops = .{ .blank = true, .bytes = "'" };

fn classes_build() [256]CharacterClass {
    @setEvalBranchQuota(20_000);

    var result: [256]CharacterClass = undefined;

    for (&result, 0..) |*class, index| {
        const byte: u8 = @intCast(index);
        const word = std.ascii.isAlphanumeric(byte) or byte == '-';
        const uri_other = std.mem.findScalar(u8, "#;/?:@&=+$,_.!~*'()[]%", byte) != null;
        const flow = std.mem.findScalar(u8, ",[]{}", byte) != null;
        const blank = byte == ' ' or byte == '\t';
        const line_break = byte == '\n' or byte == '\r';
        const uri = word or uri_other;

        class.* = .{
            .blank = blank,
            .digit = std.ascii.isDigit(byte),
            .flow = flow,
            .hexadecimal = std.ascii.isHex(byte),
            .line_break = line_break,
            .tag = uri and byte != '!' and !flow,
            .terminal = blank or line_break or byte == 0,
            .uri = uri,
            .word = word,
            .padding = 0,
        };
    }

    assert(result[' '].terminal);
    assert(!result['a'].terminal);

    return result;
}

const FlowKind = enum(u8) {
    mapping,
    sequence,
};

const SimpleKey = struct {
    mark: Mark,
    number: u64,
    possible: bool,
    required: bool,
    tab: ?Mark,

    const none: SimpleKey = .{
        .mark = .zero,
        .number = 0,
        .possible = false,
        .required = false,
        .tab = null,
    };
};

const Prefix = struct {
    first: bool,
    spaces: u32,
    tab: ?Mark,
};

const BlankRun = struct {
    start: u32,
    tab: u32,
};

const Range = struct {
    end: u32,
    start: u32,
};

const Roll = struct {
    column: u32,
    kind: TokenKind,
    mark: Mark,
    number: ?u64,
};

const Chomping = enum {
    clip,
    keep,
    strip,
};

const BlockHeader = struct {
    chomping: Chomping,
    increment: u32,
};

const Detection = struct {
    indent: u32,
    spaces_empty_max: u32,
};

const Builder = struct {
    building: bool,
    end: u32,
    start: u32,
};

const Escape = struct {
    bytes: [4]u8,
    consumed: u32,
    count: u32,
};

const PlainScan = struct {
    broken: bool,
    token: Token,
};

const LineState = enum {
    content,
    empty,
    empty_last,
    end,
};

const URIKind = enum {
    shorthand,
    verbatim,
};

const Gap = struct {
    breaks: u32,
    spaces: u32,
    stop: bool,
    tab_violation: ?Mark,
};

pub const Scanner = struct {
    adjacent_active: bool,
    adjacent_allowed: bool,
    comment_count: u32,
    comments: []CommentSlot,
    document_prefix: bool,
    failure: Mark,
    flow_count: u32,
    flow_kinds: [depth_max]FlowKind,
    indent: i32,
    indent_count: u32,
    indents: [depth_max]i32,
    mark: Mark,
    prefix: Prefix,
    prefix_index: u32,
    simple_key_allowed: bool,
    simple_keys: [depth_max + 1]SimpleKey,
    simple_keys_fresh_column_max: u32,
    simple_keys_fresh_line: u32,
    simple_keys_number_min: u64,
    source: []const u8,
    stream_end_produced: bool,
    stream_start_produced: bool,
    text: []u8,
    text_used: u32,
    token_count: u32,
    token_head: u32,
    tokens: [token_capacity]Token,
    tokens_parsed: u64,

    pub fn init(scanner: *Scanner, source: []const u8, text: []u8) void {
        assert(source.len <= source_bytes_max);
        assert(text.len < index_none);

        scanner.adjacent_active = false;
        scanner.adjacent_allowed = false;
        scanner.comment_count = 0;
        scanner.comments = &.{};
        scanner.document_prefix = true;
        scanner.failure = .zero;
        scanner.flow_count = 0;
        scanner.indent = -1;
        scanner.indent_count = 0;
        scanner.mark = .zero;
        scanner.prefix = .{ .first = true, .spaces = 0, .tab = null };
        scanner.prefix_index = index_none;
        scanner.simple_key_allowed = false;
        scanner.simple_keys[0] = .none;
        scanner.simple_keys_fresh_column_max = 0;
        scanner.simple_keys_fresh_line = 0;
        scanner.simple_keys_number_min = std.math.maxInt(u64);
        scanner.source = source;
        scanner.stream_end_produced = false;
        scanner.stream_start_produced = false;
        scanner.text = text;
        scanner.text_used = 0;
        scanner.token_count = 0;
        scanner.token_head = 0;
        scanner.tokens_parsed = 0;
    }

    pub fn comments_keep(scanner: *Scanner, slots: []CommentSlot) void {
        assert(slots.len <= std.math.maxInt(u32));
        assert(scanner.comment_count == 0);
        assert(!scanner.stream_start_produced);

        scanner.comments = slots;
    }

    pub fn token_peek(scanner: *Scanner) Error!*const Token {
        assert(scanner.token_count <= token_capacity);
        assert(scanner.token_head < token_capacity);

        try scanner.tokens_fetch();

        assert(scanner.token_count > 0);

        return &scanner.tokens[scanner.token_head];
    }

    pub fn token_skip(scanner: *Scanner) void {
        assert(scanner.token_count > 0);
        assert(scanner.token_head < token_capacity);

        scanner.token_head = (scanner.token_head + 1) & (token_capacity - 1);
        scanner.token_count -= 1;
        scanner.tokens_parsed += 1;
    }

    pub fn text_append(scanner: *Scanner, bytes: []const u8) Error!void {
        assert(scanner.text_used <= scanner.text.len);
        assert(bytes.len <= source_bytes_max);

        if (bytes.len > scanner.text.len - scanner.text_used) {
            return scanner.fail(error.TextExhausted);
        }

        @memcpy(scanner.text[scanner.text_used..][0..bytes.len], bytes);
        scanner.text_used += @intCast(bytes.len);
    }

    pub fn fail(scanner: *Scanner, err: Error) Error {
        assert(scanner.mark.index <= scanner.source.len);
        assert(@errorName(err).len > 0);

        scanner.failure = scanner.mark;

        return err;
    }

    pub fn fail_at(scanner: *Scanner, mark: Mark, err: Error) Error {
        assert(mark.index <= scanner.source.len);
        assert(@errorName(err).len > 0);

        scanner.failure = mark;

        return err;
    }

    fn tokens_fetch(scanner: *Scanner) Error!void {
        assert(scanner.token_count <= token_capacity);
        assert(scanner.flow_count <= depth_max);

        for (0..token_capacity + 1) |_| {
            const needed = try scanner.tokens_needed();
            if (!needed) return;

            try scanner.token_fetch();
        }

        return scanner.fail(error.TokensExhausted);
    }

    fn tokens_needed(scanner: *Scanner) Error!bool {
        assert(scanner.flow_count <= depth_max);
        assert(scanner.token_count <= token_capacity);

        if (scanner.token_count == 0) return !scanner.stream_end_produced;
        if (scanner.stream_end_produced) return false;

        try scanner.simple_keys_stale();

        if (scanner.simple_keys_number_min > scanner.tokens_parsed) return false;

        var number_min: u64 = std.math.maxInt(u64);

        for (scanner.simple_keys[0 .. scanner.flow_count + 1]) |*key| {
            if (!key.possible) continue;
            if (key.number == scanner.tokens_parsed) return true;

            number_min = @min(number_min, key.number);
        }

        scanner.simple_keys_number_min = number_min;

        return false;
    }

    noinline fn token_fetch(scanner: *Scanner) align(64) Error!void {
        assert(!scanner.stream_end_produced);
        assert(scanner.mark.index <= scanner.source.len);

        if (!scanner.stream_start_produced) return scanner.stream_start_fetch();

        try scanner.separation_skip();
        try scanner.simple_keys_stale();
        try scanner.indent_unroll(@intCast(scanner.mark.column));

        scanner.adjacent_active = scanner.adjacent_allowed;
        scanner.adjacent_allowed = false;

        const byte = scanner.byte_at(0);
        if (byte == 0) return scanner.stream_end_fetch();

        try scanner.line_start_check();

        if (scanner.mark.column == 0) {
            if (byte == '%') return scanner.directive_fetch();
            if (scanner.document_marker_of()) |kind| return scanner.document_indicator_fetch(kind);
        }

        return scanner.indicator_fetch(byte);
    }

    fn indicator_fetch(scanner: *Scanner, byte: u8) align(64) Error!void {
        assert(byte != 0);
        assert(scanner.mark.index < scanner.source.len);

        switch (byte) {
            '[' => return scanner.flow_start_fetch(.sequence),
            '{' => return scanner.flow_start_fetch(.mapping),
            ']' => return scanner.flow_end_fetch(.flow_sequence_end),
            '}' => return scanner.flow_end_fetch(.flow_mapping_end),
            ',' => return scanner.flow_entry_fetch(),
            '*' => return scanner.anchor_fetch(.alias),
            '&' => return scanner.anchor_fetch(.anchor),
            '!' => return scanner.tag_fetch(),
            '\'' => return scanner.quoted_fetch(.single_quoted),
            '"' => return scanner.quoted_fetch(.double_quoted),
            '|' => return scanner.block_scalar_fetch(.literal),
            '>' => return scanner.block_scalar_fetch(.folded),
            '-', '?', ':' => return scanner.sign_fetch(byte),
            '#' => return scanner.fail(error.CommentInvalid),
            '%', '@', '`' => return scanner.fail(error.CharacterInvalid),
            else => return scanner.plain_fetch(),
        }
    }

    fn sign_fetch(scanner: *Scanner, byte: u8) Error!void {
        assert(byte == '-' or byte == '?' or byte == ':');
        assert(scanner.byte_at(0) == byte);

        const terminal = classes[scanner.byte_at(1)].terminal;

        switch (byte) {
            '-' => {
                if (terminal) return scanner.block_entry_fetch();
                return scanner.plain_fetch();
            },
            '?' => {
                if (terminal) return scanner.key_fetch();
                return scanner.plain_fetch();
            },
            else => {
                if (scanner.value_indicator_is()) return scanner.value_fetch();
                return scanner.plain_fetch();
            },
        }
    }

    fn value_indicator_is(scanner: *const Scanner) bool {
        assert(scanner.byte_at(0) == ':');
        assert(scanner.flow_count <= depth_max);

        const next = scanner.byte_at(1);
        if (classes[next].terminal) return true;
        if (scanner.flow_count == 0) return false;
        if (classes[next].flow) return true;
        return scanner.adjacent_active;
    }

    fn byte_at(scanner: *const Scanner, offset: u32) u8 {
        assert(offset <= lookahead_max);
        assert(scanner.mark.index <= scanner.source.len);

        const index = scanner.mark.index + offset;
        if (index >= scanner.source.len) return 0;
        return scanner.source[index];
    }

    fn advance(scanner: *Scanner) align(64) void {
        assert(scanner.mark.index < scanner.source.len);
        assert(!classes[scanner.source[scanner.mark.index]].line_break);

        const byte = scanner.source[scanner.mark.index];
        const length = sequence_length_of(byte);

        scanner.mark.index += length;
        scanner.mark.column += 1;

        assert(scanner.mark.index <= scanner.source.len);
    }

    fn spaces_count_skip(scanner: *Scanner) u32 {
        assert(scanner.mark.index < scanner.source.len);
        assert(scanner.byte_at(0) == ' ');

        const start = scanner.mark.index;

        if (scanner.byte_at(1) == ' ') {
            scanner.spaces_skip();
        } else {
            scanner.advance();
        }

        const count = scanner.mark.index - start;

        assert(count > 0);

        return count;
    }

    fn spaces_skip(scanner: *Scanner) void {
        assert(scanner.mark.index < scanner.source.len);
        assert(scanner.byte_at(0) == ' ');

        const end = space_run_end(scanner.source, scanner.mark.index);

        scanner.mark.column += end - scanner.mark.index;
        scanner.mark.index = end;
    }

    inline fn run_skip(scanner: *Scanner, comptime stops: Stops) void {
        assert(scanner.mark.index <= scanner.source.len);
        assert(stops.bytes.len > 0);

        const end = run_end(scanner.source, scanner.mark.index, stops);

        scanner.mark.column += end - scanner.mark.index;
        scanner.mark.index = end;
    }

    fn break_skip(scanner: *Scanner) void {
        assert(scanner.mark.index < scanner.source.len);
        assert(classes[scanner.source[scanner.mark.index]].line_break);

        const pair = scanner.byte_at(0) == '\r' and scanner.byte_at(1) == '\n';

        scanner.mark.index += if (pair) 2 else 1;
        scanner.mark.line += 1;
        scanner.mark.column = 0;
    }

    fn token_push(scanner: *Scanner, token: Token) Error!void {
        assert(scanner.token_count <= token_capacity);
        assert(token.mark.index <= scanner.source.len);

        if (scanner.token_count == token_capacity) return scanner.fail(error.TokensExhausted);

        const slot = (scanner.token_head + scanner.token_count) & (token_capacity - 1);

        scanner.tokens[slot] = token;
        scanner.token_count += 1;
        scanner.document_prefix = token.kind == .stream_start or token.kind == .document_end;
    }

    fn token_insert(scanner: *Scanner, position: u32, token: Token) Error!void {
        assert(position <= scanner.token_count);
        assert(token.mark.index <= scanner.source.len);

        if (scanner.token_count == token_capacity) return scanner.fail(error.TokensExhausted);

        const mask = token_capacity - 1;
        var index = scanner.token_count;

        for (0..token_capacity) |_| {
            if (index == position) break;

            const target = (scanner.token_head + index) & mask;
            const source = (scanner.token_head + index - 1) & mask;

            scanner.tokens[target] = scanner.tokens[source];
            index -= 1;
        }

        scanner.tokens[(scanner.token_head + position) & mask] = token;
        scanner.token_count += 1;
    }

    fn token_simple(scanner: *Scanner, kind: TokenKind) Error!void {
        assert(kind != .scalar);
        assert(scanner.mark.index <= scanner.source.len);

        try scanner.token_push(.{
            .extra = "",
            .kind = kind,
            .mark = scanner.mark,
            .style = .plain,
            .text = "",
        });
    }

    fn stream_start_fetch(scanner: *Scanner) Error!void {
        assert(!scanner.stream_start_produced);
        assert(scanner.mark.index == 0);

        try scanner.source_validate();

        scanner.stream_start_produced = true;
        scanner.simple_key_allowed = true;

        try scanner.token_simple(.stream_start);

        if (std.mem.startsWith(u8, scanner.source, byte_order_mark)) {
            scanner.mark.index = byte_order_mark.len;
        }
    }

    fn stream_end_fetch(scanner: *Scanner) Error!void {
        assert(scanner.mark.index == scanner.source.len);
        assert(!scanner.stream_end_produced);

        try scanner.indent_unroll(-1);
        try scanner.simple_keys_clear();

        scanner.simple_key_allowed = false;
        scanner.stream_end_produced = true;

        try scanner.token_simple(.stream_end);
    }

    fn source_validate(scanner: *Scanner) Error!void {
        assert(scanner.source.len <= source_bytes_max);
        assert(scanner.mark.index == 0);

        const source = scanner.source;
        var index: u32 = 0;

        for (0..source.len) |_| {
            index = printable_skip(source, index);

            if (index == source.len) return;

            const byte = source[index];

            if (byte < 0x80) {
                if (!ascii_printable_is(byte)) return scanner.fail_offset(index);

                index += 1;

                continue;
            }

            const length = std.unicode.utf8ByteSequenceLength(byte) catch {
                return scanner.fail_offset(index);
            };

            if (length > source.len - index) return scanner.fail_offset(index);

            const codepoint = std.unicode.utf8Decode(source[index..][0..length]) catch {
                return scanner.fail_offset(index);
            };

            if (!codepoint_printable_is(codepoint)) return scanner.fail_offset(index);

            index += length;
        }
    }

    fn fail_offset(scanner: *Scanner, offset: u32) Error {
        assert(offset < scanner.source.len);
        assert(scanner.mark.index == 0);

        const source = scanner.source;
        const bom = std.mem.startsWith(u8, source, byte_order_mark);
        var index: u32 = if (bom) byte_order_mark.len else 0;
        var mark: Mark = .zero;

        for (0..offset) |_| {
            if (index >= offset) break;

            const byte = source[index];

            if (classes[byte].line_break) {
                index += line_break_length(source, index);
                mark.line += 1;
                mark.column = 0;

                continue;
            }

            index += 1;
            mark.column += @intFromBool(byte & 0xc0 != 0x80);
        }

        mark.index = offset;

        return scanner.fail_at(mark, error.CharacterInvalid);
    }

    fn separation_skip(scanner: *Scanner) Error!void {
        assert(scanner.stream_start_produced);
        assert(scanner.mark.index <= scanner.source.len);

        for (0..scanner.source.len + 1) |_| {
            switch (scanner.byte_at(0)) {
                ' ' => {
                    if (scanner.byte_at(1) == ' ') {
                        scanner.spaces_skip();
                    } else {
                        scanner.advance();
                    }
                },
                '\t' => scanner.advance(),
                '\n', '\r' => {
                    scanner.break_skip();

                    if (scanner.flow_count == 0) scanner.simple_key_allowed = true;
                },
                '#' => {
                    if (!scanner.comment_allowed()) return;

                    try scanner.comment_skip();
                },
                0xef => {
                    if (!scanner.byte_order_mark_skippable()) return;

                    scanner.mark.index += byte_order_mark.len;
                },
                else => return,
            }
        }
    }

    fn byte_order_mark_skippable(scanner: *const Scanner) bool {
        assert(scanner.mark.index < scanner.source.len);
        assert(scanner.source[scanner.mark.index] == 0xef);

        const index = scanner.mark.index;

        if (scanner.mark.column != 0) return false;
        if (!std.mem.startsWith(u8, scanner.source[index..], byte_order_mark)) return false;
        if (scanner.document_prefix) return true;
        return explicit_start_follows(scanner.source, index + @as(u32, byte_order_mark.len));
    }

    fn byte_order_mark_reject(scanner: *Scanner, byte: u8) Error!void {
        assert(scanner.mark.index < scanner.source.len);
        assert(scanner.source[scanner.mark.index] == byte);

        if (byte != 0xef) return;
        if (!std.mem.startsWith(u8, scanner.source[scanner.mark.index..], byte_order_mark)) return;
        return scanner.fail(error.CharacterInvalid);
    }

    fn comment_allowed(scanner: *const Scanner) bool {
        assert(scanner.byte_at(0) == '#');
        assert(scanner.mark.index < scanner.source.len);

        const index = scanner.mark.index;
        if (line_start_is(scanner.source, index)) return true;
        return classes[scanner.source[index - 1]].blank;
    }

    fn comment_skip(scanner: *Scanner) Error!void {
        assert(scanner.byte_at(0) == '#');
        assert(scanner.mark.index < scanner.source.len);

        const start = scanner.mark;

        for (0..scanner.source.len) |_| {
            scanner.run_skip(stops_comment);

            const byte = scanner.byte_at(0);
            if (byte == 0) break;
            if (classes[byte].line_break) break;

            try scanner.byte_order_mark_reject(byte);

            scanner.advance();
        }

        if (scanner.comments.len > 0) try scanner.comment_record(start);
    }

    noinline fn comment_record(scanner: *Scanner, start: Mark) Error!void {
        assert(start.index < scanner.mark.index);
        assert(scanner.source[start.index] == '#');
        assert(scanner.comment_count <= scanner.comments.len);

        if (scanner.comment_count == scanner.comments.len) {
            return scanner.fail_at(start, error.CommentsExhausted);
        }

        const source = scanner.source;
        const text = std.mem.trimEnd(u8, source[start.index..scanner.mark.index], " \t");
        const line_start = blank_run_of(source, start.index).start;
        const trailing = !line_start_is(source, line_start);
        const mask = token_capacity - 1;
        const previous = scanner.tokens[(scanner.token_head +% scanner.token_count -% 1) & mask];

        scanner.comments[scanner.comment_count] = .{
            .column = start.column,
            .flags = .{
                .blank_before = !trailing and line_above_blank_is(source, line_start),
                .inside = false,
                .prefix = scanner.document_prefix,
                .trailing = trailing,
                .padding = 0,
            },
            .flow_depth = @intCast(scanner.flow_count),
            .line = start.line,
            .node = index_none,
            .placement = .head,
            .previous = previous.kind,
            .text = text,
        };

        scanner.comment_count += 1;

        assert(text.len > 0);
    }

    fn prefix_of(scanner: *Scanner) align(64) Prefix {
        assert(scanner.mark.index <= scanner.source.len);
        assert(scanner.source.len <= source_bytes_max);

        if (scanner.prefix_index == scanner.mark.index) return scanner.prefix;

        const source = scanner.source;
        const run = blank_run_of(source, scanner.mark.index);
        const start = run.start;
        const tab: ?Mark = if (run.tab == index_none) null else scanner.mark_behind(run.tab);
        const first = line_start_is(source, start);
        const spaces_end = if (tab) |mark| mark.index else scanner.mark.index;
        const spaces = if (first) spaces_end - start else 0;
        const result: Prefix = .{ .first = first, .spaces = spaces, .tab = tab };

        if (first) {
            scanner.prefix = result;
            scanner.prefix_index = scanner.mark.index;
        }

        assert(result.spaces <= scanner.mark.index - start);

        return result;
    }

    fn mark_behind(scanner: *const Scanner, index: u32) Mark {
        assert(index <= scanner.mark.index);
        assert(scanner.mark.index - index <= scanner.mark.column);

        const distance = scanner.mark.index - index;

        return .{
            .column = scanner.mark.column - distance,
            .index = index,
            .line = scanner.mark.line,
        };
    }

    fn mark_ahead(scanner: *const Scanner, index: u32) Mark {
        assert(index >= scanner.mark.index);
        assert(index <= scanner.source.len);

        var mark = scanner.mark;

        for (0..index - scanner.mark.index) |_| {
            if (mark.index >= index) break;

            const byte = scanner.source[mark.index];

            if (classes[byte].line_break) {
                const next = source_byte_of(scanner.source, mark.index + 1);
                const pair = byte == '\r' and next == '\n';

                mark.index += if (pair) 2 else 1;
                mark.line += 1;
                mark.column = 0;
            } else {
                mark.index += sequence_length_of(byte);
                mark.column += 1;
            }
        }

        assert(mark.index == index);

        return mark;
    }

    fn line_start_check(scanner: *Scanner) Error!void {
        assert(scanner.mark.index < scanner.source.len);
        assert(scanner.indent >= -1);

        if (scanner.mark.index > 0) {
            switch (scanner.source[scanner.mark.index - 1]) {
                ' ', '\t', '\n', '\r', 0xbf => {},
                else => return,
            }
        }

        const prefix = scanner.prefix_of();
        if (!prefix.first) return;

        const required: u32 = @intCast(scanner.indent + 1);

        if (scanner.flow_count > 0) {
            if (prefix.spaces < required) return scanner.fail(error.IndentationInvalid);
            return;
        }

        const tab = prefix.tab orelse return;
        if (prefix.spaces < required) return scanner.fail_at(tab, error.TabInvalid);
    }

    inline fn simple_keys_stale(scanner: *Scanner) Error!void {
        assert(scanner.flow_count <= depth_max);
        assert(scanner.mark.index <= scanner.source.len);

        if (scanner.mark.line == scanner.simple_keys_fresh_line) {
            if (scanner.mark.column <= scanner.simple_keys_fresh_column_max) return;
        }

        try scanner.simple_keys_stale_walk();
    }

    fn simple_keys_stale_walk(scanner: *Scanner) Error!void {
        assert(scanner.flow_count <= depth_max);
        assert(scanner.mark.index <= scanner.source.len);

        var fresh_column_max: u32 = std.math.maxInt(u32);

        for (scanner.simple_keys[0 .. scanner.flow_count + 1]) |*key| {
            if (!key.possible) continue;

            const line_changed = key.mark.line < scanner.mark.line;
            const too_long = key.mark.column + key_columns_max < scanner.mark.column;
            const stale = line_changed or too_long;

            if (stale) {
                if (key.required) return scanner.fail_at(key.mark, error.KeyInvalid);

                key.possible = false;
            } else {
                fresh_column_max = @min(fresh_column_max, key.mark.column + key_columns_max);
            }
        }

        scanner.simple_keys_fresh_line = scanner.mark.line;
        scanner.simple_keys_fresh_column_max = fresh_column_max;
    }

    fn simple_key_tracked(scanner: *const Scanner) bool {
        assert(scanner.flow_count <= depth_max);
        assert(scanner.indent >= -1);

        if (scanner.flow_count == 0) return true;
        return scanner.flow_kinds[scanner.flow_count - 1] == .sequence;
    }

    fn simple_key_save(scanner: *Scanner) align(64) Error!void {
        assert(scanner.flow_count <= depth_max);
        assert(scanner.mark.index < scanner.source.len);

        if (!scanner.simple_key_allowed) return;
        if (!scanner.simple_key_tracked()) return;

        const block = scanner.flow_count == 0;
        const at_indent = scanner.indent == @as(i64, scanner.mark.column);
        const tab = if (block) scanner.prefix_of().tab else null;

        try scanner.simple_key_remove();

        const number = scanner.tokens_parsed + scanner.token_count;

        scanner.simple_keys[scanner.flow_count] = .{
            .mark = scanner.mark,
            .number = number,
            .possible = true,
            .required = block and at_indent,
            .tab = tab,
        };

        scanner.simple_keys_number_min = @min(scanner.simple_keys_number_min, number);

        if (scanner.mark.line == scanner.simple_keys_fresh_line) {
            const column_max = scanner.mark.column + key_columns_max;
            const fresh = scanner.simple_keys_fresh_column_max;

            scanner.simple_keys_fresh_column_max = @min(fresh, column_max);
        }
    }

    fn simple_keys_clear(scanner: *Scanner) Error!void {
        assert(scanner.flow_count <= depth_max);
        assert(scanner.mark.index == scanner.source.len);

        for (scanner.simple_keys[0 .. scanner.flow_count + 1]) |*key| {
            if (!key.possible) continue;
            if (key.required) return scanner.fail_at(key.mark, error.KeyInvalid);

            key.possible = false;
        }
    }

    fn simple_key_remove(scanner: *Scanner) Error!void {
        assert(scanner.flow_count <= depth_max);
        assert(scanner.mark.index <= scanner.source.len);

        const key = &scanner.simple_keys[scanner.flow_count];
        if (!key.possible) return;
        if (key.required) return scanner.fail_at(key.mark, error.KeyInvalid);

        key.possible = false;
    }

    fn flow_level_increase(scanner: *Scanner, kind: FlowKind) Error!void {
        assert(scanner.flow_count <= depth_max);
        assert(@backingInt(kind) <= 1);

        if (scanner.flow_count == depth_max) return scanner.fail(error.DepthExceeded);

        scanner.flow_kinds[scanner.flow_count] = kind;
        scanner.flow_count += 1;
        scanner.simple_keys[scanner.flow_count] = .none;
    }

    fn flow_level_decrease(scanner: *Scanner) void {
        assert(scanner.flow_count <= depth_max);
        assert(scanner.mark.index < scanner.source.len);

        if (scanner.flow_count == 0) return;

        scanner.flow_count -= 1;
    }

    fn indent_roll(scanner: *Scanner, roll: *const Roll) Error!void {
        assert(roll.kind == .block_mapping_start or roll.kind == .block_sequence_start);
        assert(roll.mark.index <= scanner.source.len);

        if (scanner.flow_count > 0) return;

        const column: i32 = @intCast(roll.column);
        if (scanner.indent >= column) return;
        if (scanner.indent_count == depth_max) return scanner.fail(error.DepthExceeded);

        scanner.indents[scanner.indent_count] = scanner.indent;
        scanner.indent_count += 1;
        scanner.indent = column;

        const token = Token{
            .extra = "",
            .kind = roll.kind,
            .mark = roll.mark,
            .style = .plain,
            .text = "",
        };

        if (roll.number) |number| {
            const position: u32 = @intCast(number - scanner.tokens_parsed);
            return scanner.token_insert(position, token);
        }

        try scanner.token_push(token);
    }

    fn indent_unroll(scanner: *Scanner, column: i32) align(64) Error!void {
        assert(column >= -1);
        assert(scanner.indent_count <= depth_max);

        if (scanner.flow_count > 0) return;

        for (0..depth_max + 1) |_| {
            if (scanner.indent <= column) return;

            try scanner.token_simple(.block_end);

            scanner.indent_count -= 1;
            scanner.indent = scanner.indents[scanner.indent_count];
        }

        unreachable;
    }

    fn document_marker_of(scanner: *const Scanner) ?TokenKind {
        assert(scanner.mark.column == 0);
        assert(scanner.mark.index <= scanner.source.len);

        return document_marker_at(scanner.source, scanner.mark.index);
    }

    fn line_boundary_is(scanner: *const Scanner) bool {
        assert(scanner.mark.column == 0);
        assert(scanner.mark.index <= scanner.source.len);

        return line_boundary_at(scanner.source, scanner.mark.index);
    }

    fn document_indicator_fetch(scanner: *Scanner, kind: TokenKind) Error!void {
        assert(kind == .document_start or kind == .document_end);
        assert(scanner.mark.column == 0);

        if (scanner.flow_count > 0) return scanner.fail(error.FlowInvalid);

        try scanner.indent_unroll(-1);
        try scanner.simple_key_remove();

        scanner.simple_key_allowed = false;

        try scanner.token_simple(kind);

        scanner.mark.index += 3;
        scanner.mark.column += 3;

        if (kind == .document_end) try scanner.line_end_expect(error.DocumentMarkerInvalid);
    }

    fn line_end_expect(scanner: *Scanner, err: Error) Error!void {
        assert(scanner.mark.index <= scanner.source.len);
        assert(@errorName(err).len > 0);

        for (0..scanner.source.len) |_| {
            if (!classes[scanner.byte_at(0)].blank) break;

            scanner.advance();
        }

        const byte = scanner.byte_at(0);

        if (byte == '#') {
            if (!scanner.comment_allowed()) return scanner.fail(err);

            try scanner.comment_skip();
        }

        const after = scanner.byte_at(0);
        if (after == 0) return;
        if (!classes[after].line_break) return scanner.fail(err);
    }

    fn flow_start_fetch(scanner: *Scanner, kind: FlowKind) align(64) Error!void {
        assert(@backingInt(kind) <= 1);
        assert(scanner.mark.index < scanner.source.len);

        try scanner.simple_key_save();
        try scanner.flow_level_increase(kind);

        scanner.simple_key_allowed = true;

        const token_kind: TokenKind = switch (kind) {
            .mapping => .flow_mapping_start,
            .sequence => .flow_sequence_start,
        };

        try scanner.token_simple(token_kind);

        scanner.advance();
    }

    fn flow_end_fetch(scanner: *Scanner, kind: TokenKind) Error!void {
        assert(kind == .flow_mapping_end or kind == .flow_sequence_end);
        assert(scanner.mark.index < scanner.source.len);

        try scanner.simple_key_remove();

        scanner.flow_level_decrease();
        scanner.simple_key_allowed = false;

        try scanner.token_simple(kind);

        scanner.advance();

        if (scanner.flow_count > 0) scanner.adjacent_allowed = true;
    }

    fn flow_entry_fetch(scanner: *Scanner) Error!void {
        assert(scanner.byte_at(0) == ',');
        assert(scanner.mark.index < scanner.source.len);

        try scanner.simple_key_remove();

        scanner.simple_key_allowed = true;

        try scanner.token_simple(.flow_entry);

        scanner.advance();
    }

    fn block_entry_fetch(scanner: *Scanner) Error!void {
        assert(scanner.byte_at(0) == '-');
        assert(scanner.mark.index < scanner.source.len);

        if (scanner.flow_count > 0) return scanner.fail(error.SequenceEntryInvalid);
        if (!scanner.simple_key_allowed) return scanner.fail(error.SequenceEntryInvalid);
        if (scanner.prefix_of().tab) |tab| return scanner.fail_at(tab, error.TabInvalid);

        try scanner.indent_roll(&.{
            .column = scanner.mark.column,
            .kind = .block_sequence_start,
            .mark = scanner.mark,
            .number = null,
        });

        try scanner.simple_key_remove();

        scanner.simple_key_allowed = true;

        try scanner.token_simple(.block_entry);

        scanner.advance();
    }

    fn key_fetch(scanner: *Scanner) Error!void {
        assert(scanner.byte_at(0) == '?');
        assert(scanner.mark.index < scanner.source.len);

        if (scanner.flow_count == 0) {
            if (!scanner.simple_key_allowed) return scanner.fail(error.KeyInvalid);
            if (scanner.prefix_of().tab) |tab| return scanner.fail_at(tab, error.TabInvalid);

            try scanner.indent_roll(&.{
                .column = scanner.mark.column,
                .kind = .block_mapping_start,
                .mark = scanner.mark,
                .number = null,
            });
        }

        try scanner.simple_key_remove();

        scanner.simple_key_allowed = scanner.flow_count == 0;

        try scanner.token_simple(.key);

        scanner.advance();
    }

    fn value_fetch(scanner: *Scanner) Error!void {
        assert(scanner.byte_at(0) == ':');
        assert(scanner.mark.index < scanner.source.len);

        const key = &scanner.simple_keys[scanner.flow_count];

        if (key.possible) {
            try scanner.simple_key_insert(key);
        } else {
            try scanner.value_complex_check();
        }

        try scanner.token_simple(.value);

        scanner.advance();
    }

    fn simple_key_insert(scanner: *Scanner, key: *SimpleKey) Error!void {
        assert(key.possible);
        assert(key.number >= scanner.tokens_parsed);

        if (scanner.flow_count == 0) {
            if (key.tab) |tab| return scanner.fail_at(tab, error.TabInvalid);
        }

        const position: u32 = @intCast(key.number - scanner.tokens_parsed);

        try scanner.token_insert(position, .{
            .extra = "",
            .kind = .key,
            .mark = key.mark,
            .style = .plain,
            .text = "",
        });

        try scanner.indent_roll(&.{
            .column = key.mark.column,
            .kind = .block_mapping_start,
            .mark = key.mark,
            .number = key.number,
        });

        key.possible = false;
        scanner.simple_key_allowed = false;
    }

    fn value_complex_check(scanner: *Scanner) Error!void {
        assert(scanner.byte_at(0) == ':');
        assert(scanner.flow_count <= depth_max);

        if (scanner.flow_count == 0) {
            if (!scanner.simple_key_allowed) return scanner.fail(error.ValueInvalid);
            if (scanner.prefix_of().tab) |tab| return scanner.fail_at(tab, error.TabInvalid);

            try scanner.indent_roll(&.{
                .column = scanner.mark.column,
                .kind = .block_mapping_start,
                .mark = scanner.mark,
                .number = null,
            });
        }

        scanner.simple_key_allowed = scanner.flow_count == 0;
    }

    fn anchor_fetch(scanner: *Scanner, kind: TokenKind) Error!void {
        assert(kind == .alias or kind == .anchor);
        assert(scanner.mark.index < scanner.source.len);

        try scanner.simple_key_save();

        scanner.simple_key_allowed = false;

        const mark = scanner.mark;

        scanner.advance();

        const start = scanner.mark.index;

        for (0..scanner.source.len) |_| {
            const byte = scanner.byte_at(0);
            if (classes[byte].terminal) break;
            if (classes[byte].flow) break;

            try scanner.byte_order_mark_reject(byte);

            scanner.advance();
        }

        if (scanner.mark.index == start) return scanner.fail_at(mark, error.AnchorInvalid);

        if (kind == .anchor) try scanner.property_end_check(error.AnchorInvalid);

        try scanner.token_push(.{
            .extra = "",
            .kind = kind,
            .mark = mark,
            .style = .plain,
            .text = scanner.source[start..scanner.mark.index],
        });
    }

    fn tag_fetch(scanner: *Scanner) Error!void {
        assert(scanner.byte_at(0) == '!');
        assert(scanner.mark.index < scanner.source.len);

        try scanner.simple_key_save();

        scanner.simple_key_allowed = false;

        const token = try scanner.tag_scan();

        try scanner.property_end_check(error.TagInvalid);
        try scanner.token_push(token);
    }

    fn property_end_check(scanner: *Scanner, err: Error) Error!void {
        assert(scanner.mark.index <= scanner.source.len);
        assert(@errorName(err).len > 0);

        const after = scanner.byte_at(0);
        if (classes[after].terminal) return;

        if (scanner.flow_count > 0) {
            const empty_end = after == ',' or after == ']' or after == '}';
            if (empty_end) return;
        }

        return scanner.fail(err);
    }

    fn tag_scan(scanner: *Scanner) Error!Token {
        assert(scanner.byte_at(0) == '!');
        assert(scanner.mark.index < scanner.source.len);

        const mark = scanner.mark;
        var token = Token{ .extra = "", .kind = .tag, .mark = mark, .style = .plain, .text = "" };

        if (scanner.byte_at(1) == '<') {
            scanner.mark.index += 2;
            scanner.mark.column += 2;

            token.extra = try scanner.uri_scan(.verbatim);

            if (token.extra.len == 0) return scanner.fail_at(mark, error.TagInvalid);
            if (scanner.byte_at(0) != '>') return scanner.fail(error.TagInvalid);

            scanner.advance();

            return token;
        }

        scanner.advance();

        const handle_start = mark.index;

        for (0..scanner.source.len) |_| {
            if (!classes[scanner.byte_at(0)].word) break;

            scanner.advance();
        }

        if (scanner.byte_at(0) == '!') {
            scanner.advance();
            token.text = scanner.source[handle_start..scanner.mark.index];
            token.extra = try scanner.uri_scan(.shorthand);

            if (token.extra.len == 0) return scanner.fail_at(mark, error.TagInvalid);
            return token;
        }

        const words = scanner.source[handle_start + 1 .. scanner.mark.index];
        const rest = try scanner.uri_scan(.shorthand);

        token.text = scanner.source[handle_start .. handle_start + 1];
        token.extra = scanner.source[handle_start + 1 .. handle_start + 1 + words.len + rest.len];

        return token;
    }

    fn uri_scan(scanner: *Scanner, kind: URIKind) Error![]const u8 {
        assert(scanner.mark.index <= scanner.source.len);
        assert(@backingInt(kind) <= 1);

        const start = scanner.mark.index;

        for (0..scanner.source.len) |_| {
            const byte = scanner.byte_at(0);

            const allowed = switch (kind) {
                .shorthand => classes[byte].tag,
                .verbatim => classes[byte].uri,
            };

            if (!allowed) break;

            if (byte == '%') {
                const valid = classes[scanner.byte_at(1)].hexadecimal and
                    classes[scanner.byte_at(2)].hexadecimal;

                if (!valid) return scanner.fail(error.TagInvalid);
            }

            scanner.advance();
        }

        return scanner.source[start..scanner.mark.index];
    }

    fn directive_fetch(scanner: *Scanner) Error!void {
        assert(scanner.byte_at(0) == '%');
        assert(scanner.mark.column == 0);

        try scanner.indent_unroll(-1);
        try scanner.simple_key_remove();

        scanner.simple_key_allowed = false;

        const token = try scanner.directive_scan();

        try scanner.token_push(token);
    }

    fn directive_scan(scanner: *Scanner) Error!Token {
        assert(scanner.byte_at(0) == '%');
        assert(scanner.mark.index < scanner.source.len);

        const mark = scanner.mark;

        scanner.advance();

        const name = scanner.word_scan();
        if (name.len == 0) return scanner.fail_at(mark, error.DirectiveInvalid);

        var token = Token{
            .extra = "",
            .kind = .directive_reserved,
            .mark = mark,
            .style = .plain,
            .text = name,
        };

        if (std.mem.eql(u8, name, "YAML")) {
            try scanner.blanks_expect();

            token.kind = .directive_version;
            token.text = try scanner.version_scan();
        } else if (std.mem.eql(u8, name, "TAG")) {
            try scanner.blanks_expect();

            token.kind = .directive_tag;
            token.text = try scanner.tag_handle_scan();

            try scanner.blanks_expect();

            token.extra = try scanner.tag_prefix_scan();
        } else {
            try scanner.directive_parameters_skip();
        }

        try scanner.line_end_expect(error.DirectiveInvalid);

        return token;
    }

    fn word_scan(scanner: *Scanner) []const u8 {
        assert(scanner.mark.index <= scanner.source.len);
        assert(scanner.source.len <= source_bytes_max);

        const start = scanner.mark.index;

        for (0..scanner.source.len) |_| {
            if (classes[scanner.byte_at(0)].terminal) break;

            scanner.advance();
        }

        return scanner.source[start..scanner.mark.index];
    }

    fn blanks_expect(scanner: *Scanner) Error!void {
        assert(scanner.mark.index <= scanner.source.len);
        assert(scanner.source.len <= source_bytes_max);

        if (!classes[scanner.byte_at(0)].blank) return scanner.fail(error.DirectiveInvalid);

        for (0..scanner.source.len) |_| {
            if (!classes[scanner.byte_at(0)].blank) return;

            scanner.advance();
        }
    }

    fn version_scan(scanner: *Scanner) Error![]const u8 {
        assert(scanner.mark.index <= scanner.source.len);
        assert(scanner.source.len <= source_bytes_max);

        const start = scanner.mark.index;

        try scanner.version_numbers_scan();

        return scanner.source[start..scanner.mark.index];
    }

    fn version_numbers_scan(scanner: *Scanner) Error!void {
        assert(scanner.mark.index <= scanner.source.len);
        assert(scanner.source.len <= source_bytes_max);

        const major = scanner.digits_scan();
        if (major == 0) return scanner.fail(error.DirectiveInvalid);
        if (scanner.byte_at(0) != '.') return scanner.fail(error.DirectiveInvalid);

        scanner.advance();

        const minor = scanner.digits_scan();
        if (minor == 0) return scanner.fail(error.DirectiveInvalid);
        if (!classes[scanner.byte_at(0)].terminal) return scanner.fail(error.DirectiveInvalid);
    }

    fn digits_scan(scanner: *Scanner) u32 {
        assert(scanner.mark.index <= scanner.source.len);
        assert(scanner.source.len <= source_bytes_max);

        var count: u32 = 0;

        for (0..scanner.source.len) |_| {
            if (!classes[scanner.byte_at(0)].digit) break;

            scanner.advance();
            count += 1;
        }

        return count;
    }

    fn tag_handle_scan(scanner: *Scanner) Error![]const u8 {
        assert(scanner.mark.index <= scanner.source.len);
        assert(scanner.source.len <= source_bytes_max);

        const start = scanner.mark.index;

        if (scanner.byte_at(0) != '!') return scanner.fail(error.DirectiveInvalid);

        scanner.advance();

        for (0..scanner.source.len) |_| {
            if (!classes[scanner.byte_at(0)].word) break;

            scanner.advance();
        }

        if (scanner.byte_at(0) == '!') scanner.advance();

        const handle = scanner.source[start..scanner.mark.index];
        const named = handle.len > 1;

        if (named) {
            if (handle[handle.len - 1] != '!') return scanner.fail(error.DirectiveInvalid);
        }

        if (!classes[scanner.byte_at(0)].blank) return scanner.fail(error.DirectiveInvalid);
        return handle;
    }

    fn tag_prefix_scan(scanner: *Scanner) Error![]const u8 {
        assert(scanner.mark.index <= scanner.source.len);
        assert(scanner.source.len <= source_bytes_max);

        const first = scanner.byte_at(0);
        const local = first == '!';

        if (!local) {
            if (!classes[first].tag) return scanner.fail(error.DirectiveInvalid);
        }

        const prefix = try scanner.uri_scan(.verbatim);
        if (prefix.len == 0) return scanner.fail(error.DirectiveInvalid);
        if (!classes[scanner.byte_at(0)].terminal) return scanner.fail(error.DirectiveInvalid);
        return prefix;
    }

    fn directive_parameters_skip(scanner: *Scanner) Error!void {
        assert(scanner.mark.index <= scanner.source.len);
        assert(scanner.source.len <= source_bytes_max);

        for (0..scanner.source.len) |_| {
            const byte = scanner.byte_at(0);
            if (byte == 0) return;
            if (classes[byte].line_break) return;

            if (byte == '#') {
                if (scanner.comment_allowed()) return;
            }

            try scanner.byte_order_mark_reject(byte);

            scanner.advance();
        }
    }

    fn quoted_fetch(scanner: *Scanner, style: ScalarStyle) align(64) Error!void {
        assert(style == .single_quoted or style == .double_quoted);
        assert(scanner.mark.index < scanner.source.len);

        try scanner.simple_key_save();

        scanner.simple_key_allowed = false;

        const token = try scanner.quoted_scan(style);

        try scanner.token_push(token);

        if (scanner.flow_count > 0) scanner.adjacent_allowed = true;
    }

    fn plain_fetch(scanner: *Scanner) align(64) Error!void {
        assert(scanner.mark.index < scanner.source.len);
        assert(scanner.flow_count <= depth_max);

        try scanner.simple_key_save();

        scanner.simple_key_allowed = false;

        const scan = try scanner.plain_scan();

        try scanner.token_push(scan.token);

        if (scan.broken) {
            if (scanner.flow_count == 0) scanner.simple_key_allowed = true;
        }
    }

    fn block_scalar_fetch(scanner: *Scanner, style: ScalarStyle) align(64) Error!void {
        assert(style == .literal or style == .folded);
        assert(scanner.mark.index < scanner.source.len);

        if (scanner.flow_count > 0) return scanner.fail(error.CharacterInvalid);

        try scanner.simple_key_remove();

        scanner.simple_key_allowed = true;

        const token = try scanner.block_scalar_scan(style);

        try scanner.token_push(token);
    }

    fn builder_text(scanner: *const Scanner, builder: *const Builder) []const u8 {
        assert(builder.start <= scanner.source.len or builder.building);
        assert(scanner.text_used <= scanner.text.len);

        if (builder.building) return scanner.text[builder.start..scanner.text_used];
        return scanner.source[builder.start..builder.end];
    }

    fn builder_promote(scanner: *Scanner, builder: *Builder) Error!void {
        assert(builder.end >= builder.start or builder.building);
        assert(scanner.text_used <= scanner.text.len);

        if (builder.building) return;

        const pending = scanner.source[builder.start..builder.end];
        const start = scanner.text_used;

        try scanner.text_append(pending);

        builder.* = .{ .building = true, .end = 0, .start = start };
    }

    fn builder_range(scanner: *Scanner, builder: *Builder, range: Range) Error!void {
        assert(range.start <= range.end);
        assert(range.end <= scanner.source.len);

        if (builder.building) return scanner.text_append(scanner.source[range.start..range.end]);

        if (builder.end == builder.start) builder.start = range.start;

        builder.end = range.end;
    }

    fn builder_bytes(scanner: *Scanner, builder: *Builder, bytes: []const u8) Error!void {
        assert(bytes.len <= source_bytes_max);
        assert(scanner.text_used <= scanner.text.len);

        try scanner.builder_promote(builder);
        try scanner.text_append(bytes);
    }

    fn builder_fold(scanner: *Scanner, builder: *Builder, breaks: u32) Error!void {
        assert(breaks > 0);
        assert(breaks <= scanner.source.len);

        try scanner.builder_promote(builder);

        if (breaks == 1) return scanner.text_append(" ");

        for (0..breaks - 1) |_| try scanner.text_append("\n");
    }

    fn plain_scan(scanner: *Scanner) Error!PlainScan {
        assert(scanner.mark.index < scanner.source.len);
        assert(scanner.indent >= -1);

        const mark = scanner.mark;
        const indent: u32 = @intCast(scanner.indent + 1);

        try scanner.plain_first_check();

        var builder = Builder{ .building = false, .end = mark.index, .start = mark.index };
        var breaks_final: u32 = 0;
        var pending: Range = .{ .end = mark.index, .start = mark.index };
        var pending_present = false;
        var breaks: u32 = 0;

        for (0..scanner.source.len + 1) |_| {
            const chunk = try scanner.plain_chunk_scan();
            if (chunk.end == chunk.start) break;

            breaks_final = 0;

            if (breaks > 0) {
                try scanner.builder_fold(&builder, breaks);
            } else if (pending_present) {
                if (builder.building) try scanner.builder_range(&builder, pending);
            } else {}

            try scanner.builder_range(&builder, chunk);

            const gap = try scanner.plain_gap_scan(indent);

            breaks_final = gap.breaks;

            if (gap.stop) break;

            breaks = gap.breaks;
            pending = .{ .end = scanner.mark.index, .start = chunk.end };
            pending_present = gap.breaks == 0;
        }

        const token = Token{
            .extra = "",
            .kind = .scalar,
            .mark = mark,
            .style = .plain,
            .text = scanner.builder_text(&builder),
        };

        return .{ .broken = breaks_final > 0, .token = token };
    }

    fn plain_first_check(scanner: *Scanner) Error!void {
        assert(scanner.mark.index < scanner.source.len);
        assert(scanner.flow_count <= depth_max);

        const byte = scanner.byte_at(0);
        const sign = byte == '-' or byte == '?' or byte == ':';
        if (!sign) return;

        const next = scanner.byte_at(1);
        if (classes[next].terminal) return scanner.fail(error.CharacterInvalid);

        if (scanner.flow_count > 0) {
            if (classes[next].flow) return scanner.fail(error.CharacterInvalid);
        }
    }

    fn plain_chunk_scan(scanner: *Scanner) Error!Range {
        assert(scanner.mark.index <= scanner.source.len);
        assert(scanner.flow_count <= depth_max);

        const start = scanner.mark.index;
        const flow = scanner.flow_count > 0;

        if (scanner.mark.column == 0) {
            if (scanner.document_marker_of() != null) return .{ .end = start, .start = start };
        }

        if (scanner.byte_at(0) == '#') return .{ .end = start, .start = start };

        for (0..scanner.source.len) |_| {
            if (flow) {
                scanner.run_skip(stops_plain_flow);
            } else {
                scanner.run_skip(stops_plain_block);
            }

            const byte = scanner.byte_at(0);
            if (classes[byte].terminal) break;

            if (byte == ':') {
                const next = scanner.byte_at(1);
                if (classes[next].terminal) break;

                if (flow) {
                    if (classes[next].flow) break;
                }
            }

            if (flow) {
                if (classes[byte].flow) break;
            }

            try scanner.byte_order_mark_reject(byte);

            scanner.advance();
        }

        return .{ .end = scanner.mark.index, .start = start };
    }

    fn plain_gap_scan(scanner: *Scanner, indent: u32) Error!Gap {
        assert(indent <= depth_max * 1024);
        assert(scanner.mark.index <= scanner.source.len);

        var gap = Gap{ .breaks = 0, .spaces = 0, .stop = false, .tab_violation = null };
        var tab_line: ?Mark = null;
        var counting = false;

        for (0..scanner.source.len + 1) |_| {
            const byte = scanner.byte_at(0);

            if (byte == '\t') {
                tab_line = tab_line orelse scanner.mark;

                scanner.advance();

                continue;
            }

            if (byte == ' ') {
                const count = scanner.spaces_count_skip();

                assert(count > 0);

                if (counting) {
                    if (tab_line == null) gap.spaces += count;
                }

                continue;
            }

            if (!classes[byte].line_break) break;

            if (counting) {
                if (tab_line) |mark| {
                    if (gap.spaces < indent) gap.tab_violation = gap.tab_violation orelse mark;
                }
            }

            scanner.break_skip();
            gap.breaks += 1;
            gap.spaces = 0;
            tab_line = null;
            counting = true;
        }

        try scanner.plain_gap_decide(&gap, indent);

        return gap;
    }

    fn plain_gap_decide(scanner: *Scanner, gap: *Gap, indent: u32) Error!void {
        assert(indent <= depth_max * 1024);
        assert(scanner.mark.index <= scanner.source.len);

        const byte = scanner.byte_at(0);

        if (byte == 0) {
            gap.stop = true;

            return;
        }

        if (gap.breaks == 0) {
            const terminator = byte == '#' or classes[byte].flow and scanner.flow_count > 0;

            gap.stop = terminator;

            return;
        }

        if (byte == '#') {
            gap.stop = true;

            return;
        }

        if (scanner.mark.column == 0) {
            if (scanner.line_boundary_is()) {
                gap.stop = true;

                return;
            }
        }

        if (gap.spaces < indent) {
            if (scanner.flow_count > 0) return scanner.fail(error.IndentationInvalid);

            gap.stop = true;

            return;
        }

        if (gap.tab_violation) |mark| return scanner.fail_at(mark, error.TabInvalid);
    }

    fn quoted_scan(scanner: *Scanner, style: ScalarStyle) Error!Token {
        assert(style == .single_quoted or style == .double_quoted);
        assert(scanner.mark.index < scanner.source.len);

        const mark = scanner.mark;
        const indent: u32 = @intCast(scanner.indent + 1);

        scanner.advance();

        var builder = Builder{
            .building = false,
            .end = scanner.mark.index,
            .start = scanner.mark.index,
        };

        for (0..scanner.source.len + 1) |_| {
            const run = scanner.quoted_run_scan(style);

            try scanner.builder_range(&builder, run);

            const done = try scanner.quoted_special(&builder, style, indent);
            if (done) break;
        } else unreachable;

        return .{
            .extra = "",
            .kind = .scalar,
            .mark = mark,
            .style = style,
            .text = scanner.builder_text(&builder),
        };
    }

    fn quoted_run_scan(scanner: *Scanner, style: ScalarStyle) Range {
        assert(style == .single_quoted or style == .double_quoted);
        assert(scanner.mark.index <= scanner.source.len);

        const start = scanner.mark.index;
        const quote: u8 = if (style == .single_quoted) '\'' else '"';

        for (0..scanner.source.len) |_| {
            if (style == .double_quoted) {
                scanner.run_skip(stops_double_quoted);
            } else {
                scanner.run_skip(stops_single_quoted);
            }

            const byte = scanner.byte_at(0);
            if (classes[byte].terminal) break;
            if (byte == quote) break;

            if (byte == '\\') {
                if (style == .double_quoted) break;
            }

            scanner.advance();
        }

        return .{ .end = scanner.mark.index, .start = start };
    }

    fn quoted_special(
        scanner: *Scanner,
        builder: *Builder,
        style: ScalarStyle,
        indent: u32,
    ) Error!bool {
        assert(style == .single_quoted or style == .double_quoted);
        assert(indent <= depth_max * 1024);

        const byte = scanner.byte_at(0);
        if (byte == 0) return scanner.fail(error.QuoteUnterminated);

        if (byte == '\'') {
            if (style == .single_quoted) {
                if (scanner.byte_at(1) != '\'') {
                    scanner.advance();

                    return true;
                }

                try scanner.builder_bytes(builder, "'");

                scanner.advance();
                scanner.advance();

                return false;
            }
        }

        if (byte == '"') {
            if (style == .double_quoted) {
                scanner.advance();

                return true;
            }
        }

        if (byte == '\\') {
            try scanner.escape_handle(builder, indent);

            return false;
        }

        try scanner.quoted_whitespace(builder, indent);

        return false;
    }

    fn quoted_whitespace(scanner: *Scanner, builder: *Builder, indent: u32) Error!void {
        assert(indent <= depth_max * 1024);
        assert(classes[scanner.byte_at(0)].terminal);

        const start = scanner.mark.index;

        for (0..scanner.source.len) |_| {
            if (!classes[scanner.byte_at(0)].blank) break;

            scanner.advance();
        }

        assert(scanner.mark.index >= start);

        const after = scanner.byte_at(0);

        if (!classes[after].line_break) {
            const whitespace = Range{ .end = scanner.mark.index, .start = start };

            if (after == 0) return;
            return scanner.builder_range(builder, whitespace);
        }

        const breaks = try scanner.quoted_breaks_scan(indent);

        try scanner.builder_fold(builder, breaks);
    }

    fn quoted_breaks_scan(scanner: *Scanner, indent: u32) Error!u32 {
        assert(indent <= depth_max * 1024);
        assert(classes[scanner.byte_at(0)].line_break);

        var breaks: u32 = 0;

        for (0..scanner.source.len + 1) |_| {
            if (!classes[scanner.byte_at(0)].line_break) break;

            scanner.break_skip();
            breaks += 1;

            try scanner.quoted_line_prefix(indent);
        }

        return breaks;
    }

    fn quoted_line_prefix(scanner: *Scanner, indent: u32) Error!void {
        assert(indent <= depth_max * 1024);
        assert(scanner.mark.column == 0);

        var spaces: u32 = 0;
        var tab: ?Mark = null;

        for (0..scanner.source.len) |_| {
            const byte = scanner.byte_at(0);
            if (!classes[byte].blank) break;

            if (byte == '\t') tab = tab orelse scanner.mark;
            if (tab == null) spaces += 1;

            scanner.advance();
        }

        const byte = scanner.byte_at(0);
        if (byte == 0) return scanner.fail(error.QuoteUnterminated);

        if (classes[byte].line_break) {
            if (tab) |mark| {
                if (spaces < indent) return scanner.fail_at(mark, error.TabInvalid);
            }

            return;
        }

        if (spaces < indent) return scanner.fail(error.IndentationInvalid);

        if (scanner.mark.column == 0) {
            const marker = scanner.document_marker_of() != null;
            if (marker) return scanner.fail(error.DocumentMarkerInvalid);
        }
    }

    fn escape_handle(scanner: *Scanner, builder: *Builder, indent: u32) Error!void {
        assert(scanner.byte_at(0) == '\\');
        assert(indent <= depth_max * 1024);

        const next = scanner.byte_at(1);

        if (classes[next].line_break) {
            try scanner.builder_promote(builder);

            scanner.advance();

            const breaks = try scanner.quoted_breaks_scan(indent);

            for (1..breaks) |_| try scanner.text_append("\n");

            return;
        }

        const escape = try scanner.escape_decode();

        try scanner.builder_bytes(builder, escape.bytes[0..escape.count]);

        for (0..escape.consumed) |_| scanner.advance();
    }

    fn escape_decode(scanner: *Scanner) Error!Escape {
        assert(scanner.byte_at(0) == '\\');
        assert(scanner.mark.index < scanner.source.len);

        var escape = Escape{ .bytes = undefined, .consumed = 2, .count = 1 };
        const code = scanner.byte_at(1);

        escape.bytes[0] = switch (code) {
            '0' => 0,
            'a' => 0x07,
            'b' => 0x08,
            't', '\t' => '\t',
            'n' => '\n',
            'v' => 0x0b,
            'f' => 0x0c,
            'r' => '\r',
            'e' => 0x1b,
            ' ' => ' ',
            '"' => '"',
            '/' => '/',
            '\\' => '\\',
            'N', '_', 'L', 'P', 'x', 'u', 'U' => return scanner.escape_unicode(code),
            else => return scanner.fail(error.EscapeInvalid),
        };

        return escape;
    }

    fn escape_unicode(scanner: *Scanner, code: u8) Error!Escape {
        assert(scanner.byte_at(0) == '\\');
        assert(std.mem.findScalar(u8, "N_LPxuU", code) != null);

        var escape = Escape{ .bytes = undefined, .consumed = 2, .count = 0 };

        const digits: u32 = switch (code) {
            'x' => 2,
            'u' => 4,
            'U' => 8,
            else => 0,
        };

        var codepoint: u32 = switch (code) {
            'N' => 0x85,
            '_' => 0xa0,
            'L' => 0x2028,
            'P' => 0x2029,
            else => 0,
        };

        if (digits > 0) {
            const start = scanner.mark.index + 2;
            if (start + digits > scanner.source.len) return scanner.fail(error.EscapeInvalid);

            const hex = scanner.source[start..][0..digits];

            for (hex) |byte| {
                if (!classes[byte].hexadecimal) return scanner.fail(error.EscapeInvalid);

                codepoint = codepoint * 16 + hexadecimal_value_of(byte);
            }

            escape.consumed += digits;
        }

        const scalar = std.math.cast(u21, codepoint) orelse {
            return scanner.fail(error.EscapeInvalid);
        };

        escape.count = std.unicode.utf8Encode(scalar, &escape.bytes) catch {
            return scanner.fail(error.EscapeInvalid);
        };

        return escape;
    }

    fn block_scalar_scan(scanner: *Scanner, style: ScalarStyle) Error!Token {
        assert(style == .literal or style == .folded);
        assert(scanner.mark.index < scanner.source.len);

        const mark = scanner.mark;

        scanner.advance();

        const header = try scanner.block_header_scan();

        try scanner.line_end_expect(error.BlockScalarInvalid);

        if (scanner.byte_at(0) == 0) {
            return .{ .extra = "", .kind = .scalar, .mark = mark, .style = style, .text = "" };
        }

        scanner.break_skip();

        const minimum: u32 = @intCast(scanner.indent + 1);
        const detection = try scanner.block_indent_detect(&header, minimum);
        const start = scanner.text_used;

        try scanner.block_content_scan(style, &header, detection.indent);

        return .{
            .extra = "",
            .kind = .scalar,
            .mark = mark,
            .style = style,
            .text = scanner.text[start..scanner.text_used],
        };
    }

    fn block_header_scan(scanner: *Scanner) Error!BlockHeader {
        assert(scanner.mark.index <= scanner.source.len);
        assert(scanner.indent >= -1);

        var header = BlockHeader{ .chomping = .clip, .increment = 0 };

        for (0..2) |_| {
            const byte = scanner.byte_at(0);

            switch (byte) {
                '+', '-' => {
                    if (header.chomping != .clip) return scanner.fail(error.BlockScalarInvalid);

                    header.chomping = if (byte == '+') .keep else .strip;
                },
                '1'...'9' => {
                    if (header.increment != 0) return scanner.fail(error.BlockScalarInvalid);

                    header.increment = byte - '0';
                },
                '0' => return scanner.fail(error.BlockScalarInvalid),
                else => break,
            }

            scanner.advance();
        }

        return header;
    }

    fn block_indent_detect(
        scanner: *Scanner,
        header: *const BlockHeader,
        minimum: u32,
    ) Error!Detection {
        assert(header.increment <= 9);
        assert(minimum <= depth_max * 1024);

        if (header.increment > 0) {
            const indent: u32 = @intCast(scanner.indent + @as(i32, @intCast(header.increment)));
            return .{ .indent = indent, .spaces_empty_max = 0 };
        }

        var detection = Detection{ .indent = 0, .spaces_empty_max = 0 };
        var index = scanner.mark.index;
        const source = scanner.source;

        for (0..source.len + 1) |_| {
            var spaces: u32 = 0;

            for (source[index..]) |byte| {
                if (byte != ' ') break;

                spaces += 1;
            }

            const position = index + spaces;
            const byte: u8 = if (position < source.len) source[position] else 0;
            const marker = spaces == 0 and line_boundary_at(source, index);

            if (marker) {
                detection.indent = @max(detection.spaces_empty_max, minimum);

                return detection;
            }

            if (byte == '\t') {
                if (spaces < minimum) return scanner.block_tab_fail(position);
            }

            if (byte == 0) {
                detection.spaces_empty_max = @max(detection.spaces_empty_max, spaces);
                detection.indent = @max(detection.spaces_empty_max, minimum);

                return detection;
            }

            if (!classes[byte].line_break) {
                if (spaces < minimum) {
                    detection.indent = @max(detection.spaces_empty_max, minimum);

                    return detection;
                }

                if (detection.spaces_empty_max > spaces) {
                    return scanner.fail(error.BlockScalarInvalid);
                }

                detection.indent = spaces;

                return detection;
            }

            detection.spaces_empty_max = @max(detection.spaces_empty_max, spaces);
            index = position + line_break_length(source, position);
        }

        unreachable;
    }

    fn block_tab_fail(scanner: *Scanner, position: u32) Error {
        assert(position < scanner.source.len);
        assert(scanner.source[position] == '\t');

        return scanner.fail_at(scanner.mark_ahead(position), error.TabInvalid);
    }

    fn block_content_scan(
        scanner: *Scanner,
        style: ScalarStyle,
        header: *const BlockHeader,
        indent: u32,
    ) Error!void {
        assert(style == .literal or style == .folded);
        assert(indent <= depth_max * 1024);

        var line_break_pending = false;
        var trailing_breaks: u32 = 0;
        var leading_blank = false;
        var content_seen = false;

        for (0..scanner.source.len + 1) |_| {
            const state = try scanner.block_line_start(indent);

            switch (state) {
                .end => break,
                .empty => {
                    trailing_breaks += 1;

                    continue;
                },
                .empty_last => {
                    trailing_breaks += 1;

                    break;
                },
                .content => {},
            }

            const trailing_blank = classes[scanner.byte_at(0)].blank;

            const fold = style == .folded and line_break_pending and !leading_blank and
                !trailing_blank;

            if (fold) {
                if (trailing_breaks == 0) try scanner.text_append(" ");
            } else if (line_break_pending) {
                try scanner.text_append("\n");
            } else {}

            try scanner.newlines_append(trailing_breaks);

            trailing_breaks = 0;
            leading_blank = trailing_blank;
            content_seen = true;

            try scanner.block_line_copy();

            line_break_pending = true;

            if (scanner.byte_at(0) != 0) scanner.break_skip();
        }

        try scanner.block_chomp(header.chomping, line_break_pending, trailing_breaks);

        assert(content_seen or !line_break_pending);
    }

    fn block_line_start(scanner: *Scanner, indent: u32) Error!LineState {
        assert(indent <= depth_max * 1024);
        assert(scanner.mark.index <= scanner.source.len);

        const line_fresh = scanner.mark.column == 0;

        if (line_fresh) {
            if (scanner.line_boundary_is()) return .end;
        }

        const spaces = space_run_end(scanner.source, scanner.mark.index) - scanner.mark.index;
        const count = @min(spaces, indent);

        scanner.mark.column += count;
        scanner.mark.index += count;

        const byte = scanner.byte_at(0);

        if (byte == 0) {
            if (!line_fresh) return .end;
            if (scanner.mark.column == 0) return .end;
            return .empty_last;
        }

        if (classes[byte].line_break) {
            scanner.break_skip();

            return .empty;
        }

        if (scanner.mark.column < indent) {
            if (byte == '\t') return scanner.fail(error.TabInvalid);
            return .end;
        }

        return .content;
    }

    fn block_line_copy(scanner: *Scanner) Error!void {
        assert(scanner.mark.index < scanner.source.len);
        assert(!classes[scanner.byte_at(0)].line_break);

        const start = scanner.mark.index;

        for (0..scanner.source.len) |_| {
            scanner.run_skip(stops_comment);

            const byte = scanner.byte_at(0);
            if (byte == 0) break;
            if (classes[byte].line_break) break;

            try scanner.byte_order_mark_reject(byte);

            scanner.advance();
        }

        try scanner.text_append(scanner.source[start..scanner.mark.index]);
    }

    fn newlines_append(scanner: *Scanner, count: u32) Error!void {
        assert(count <= scanner.source.len);
        assert(scanner.text_used <= scanner.text.len);

        for (0..count) |_| try scanner.text_append("\n");
    }

    fn block_chomp(
        scanner: *Scanner,
        chomping: Chomping,
        line_break_pending: bool,
        trailing_breaks: u32,
    ) Error!void {
        assert(trailing_breaks <= scanner.source.len);
        assert(@backingInt(chomping) <= 2);

        switch (chomping) {
            .strip => {},
            .clip => {
                if (line_break_pending) try scanner.text_append("\n");
            },
            .keep => {
                if (line_break_pending) try scanner.text_append("\n");

                try scanner.newlines_append(trailing_breaks);
            },
        }
    }
};

fn document_marker_at(source: []const u8, index: u32) ?TokenKind {
    assert(index <= source.len);
    assert(line_start_is(source, index));

    const rest = source[index..];
    if (rest.len < 3) return null;
    if (!classes[source_byte_of(source, index + 3)].terminal) return null;
    if (std.mem.startsWith(u8, rest, "---")) return .document_start;
    if (std.mem.startsWith(u8, rest, "...")) return .document_end;
    return null;
}

fn line_boundary_at(source: []const u8, index: u32) bool {
    assert(index <= source.len);
    assert(line_start_is(source, index));

    if (std.mem.startsWith(u8, source[index..], byte_order_mark)) return true;
    return document_marker_at(source, index) != null;
}

fn source_byte_of(source: []const u8, index: u32) u8 {
    assert(index <= source.len + lookahead_max);
    assert(source.len <= source_bytes_max);

    return if (index < source.len) source[index] else 0;
}

fn hexadecimal_value_of(byte: u8) u32 {
    assert(classes[byte].hexadecimal);
    assert(byte >= '0');

    const result: u32 = switch (byte) {
        '0'...'9' => byte - '0',
        'A'...'F' => byte - 'A' + 10,
        'a'...'f' => byte - 'a' + 10,
        else => unreachable,
    };

    assert(result < 16);

    return result;
}

fn sequence_length_of(byte: u8) u32 {
    assert(byte & 0xc0 != 0x80);
    assert(byte < 0xf8);

    if (byte < 0x80) return 1;
    if (byte < 0xe0) return 2;
    if (byte < 0xf0) return 3;
    return 4;
}

pub fn ascii_printable_is(byte: u8) bool {
    assert(byte < 0x80);
    assert(classes[byte].padding == 0);

    if (byte == '\t') return true;
    if (classes[byte].line_break) return true;
    return byte >= 0x20 and byte < 0x7f;
}

inline fn space_run_end(source: []const u8, start: u32) u32 {
    assert(start <= source.len);
    assert(source.len <= source_bytes_max);

    var index = start;

    for (0..@divFloor(source.len - start, lane_count)) |_| {
        const bytes: Chunk = source[index..][0..lane_count].*;
        const other: Lanes = @intFromBool(bytes != lanes_space);
        const mask: Mask = @bitCast(other);

        if (mask != 0) {
            index += @ctz(mask);

            break;
        }

        index += lane_count;
    }

    for (source[index..]) |byte| {
        if (byte != ' ') break;

        index += 1;
    }

    assert(index >= start);
    assert(index <= source.len);

    return index;
}

inline fn run_end(source: []const u8, start: u32, comptime stops: Stops) u32 {
    assert(start <= source.len);
    assert(source.len <= source_bytes_max);
    assert(stops.bytes.len > 0);

    var index = start;

    for (0..@divFloor(source.len - start, lane_count)) |_| {
        const bytes: Chunk = source[index..][0..lane_count].*;
        var lanes: Lanes = @intFromBool(bytes >= lanes_high);

        if (stops.blank) lanes |= @intFromBool(bytes <= lanes_space);

        inline for (stops.bytes) |byte| lanes |= @intFromBool(bytes == @as(Chunk, @splat(byte)));

        const mask: Mask = @bitCast(lanes);

        if (mask != 0) {
            index += @ctz(mask);

            break;
        }

        index += lane_count;
    }

    assert(index >= start);
    assert(index <= source.len);

    return index;
}

fn printable_skip(source: []const u8, start: u32) u32 {
    assert(start <= source.len);
    assert(source.len <= source_bytes_max);

    var index = start;

    for (0..@divFloor(source.len - start, lane_count)) |_| {
        const bytes: Chunk = source[index..][0..lane_count].*;
        const visible: Lanes = @intFromBool(bytes -% lanes_space < lanes_visible_count);
        const tab: Lanes = @intFromBool(bytes == lanes_tab);
        const line_feed: Lanes = @intFromBool(bytes == lanes_line_feed);
        const carriage_return: Lanes = @intFromBool(bytes == lanes_carriage_return);
        const mask: Mask = @bitCast(~(visible | tab | line_feed | carriage_return));

        if (mask != 0) {
            index += @ctz(mask);

            break;
        }

        index += lane_count;
    }

    assert(index >= start);
    assert(index <= source.len);

    return index;
}

pub fn codepoint_printable_is(codepoint: u21) bool {
    assert(codepoint >= 0x80);
    assert(codepoint <= 0x10ffff);

    if (codepoint == 0x85) return true;
    if (codepoint < 0xa0) return false;
    if (codepoint <= 0xd7ff) return true;
    if (codepoint < 0xe000) return false;
    if (codepoint <= 0xfffd) return true;
    return codepoint >= 0x10000;
}

fn blank_run_of(source: []const u8, index: u32) BlankRun {
    assert(index <= source.len);
    assert(source.len <= source_bytes_max);

    if (index < lane_count) return blank_run_scan(source, index);

    const bytes: Chunk = source[index - lane_count ..][0..lane_count].*;
    const tabs: Mask = @bitCast(@as(Lanes, @intFromBool(bytes == lanes_tab)));
    const spaces: Mask = @bitCast(@as(Lanes, @intFromBool(bytes == lanes_space)));
    const other = ~(tabs | spaces);
    if (other == 0) return blank_run_scan(source, index);

    const last: u32 = lane_count - 1 - @clz(other);
    const start = index - lane_count + last + 1;
    const run_tabs: Mask = if (last == lane_count - 1) 0 else tabs >> @intCast(last + 1);
    const tab = if (run_tabs == 0) index_none else start + @ctz(run_tabs);
    const result: BlankRun = .{ .start = start, .tab = tab };

    assert(result.start <= index);

    if (result.tab != index_none) assert(result.tab < index);

    return result;
}

fn blank_run_scan(source: []const u8, index: u32) BlankRun {
    assert(index <= source.len);
    assert(source.len <= source_bytes_max);

    var start = index;
    var tab = index_none;

    for (0..index) |_| {
        if (start == 0) break;

        const byte = source[start - 1];
        if (!classes[byte].blank) break;

        start -= 1;

        if (byte == '\t') tab = start;
    }

    const result: BlankRun = .{ .start = start, .tab = tab };

    assert(result.start <= index);

    return result;
}

fn line_start_is(source: []const u8, index: u32) align(64) bool {
    assert(index <= source.len);
    assert(source.len <= source_bytes_max);

    var position = index;

    for (0..@divFloor(index, byte_order_mark.len) + 1) |_| {
        if (line_break_before(source, position)) return true;
        if (position < byte_order_mark.len) return false;

        const start: u32 = position - @as(u32, byte_order_mark.len);
        if (!std.mem.eql(u8, source[start..position], byte_order_mark)) return false;

        position = start;
    }

    unreachable;
}

pub fn line_above_blank_is(source: []const u8, line_start: u32) bool {
    assert(line_start <= source.len);
    assert(source.len <= source_bytes_max);

    if (line_start == 0) return false;
    if (!classes[source[line_start - 1]].line_break) return false;

    var index = line_start - 1;
    const crlf = source[index] == '\n' and index > 0 and source[index - 1] == '\r';

    if (crlf) index -= 1;

    const start = blank_run_of(source, index).start;
    if (start == 0) return true;
    return classes[source[start - 1]].line_break;
}

pub fn blank_line_find(source: []const u8) u32 {
    assert(source.len <= source_bytes_max);
    assert(wide_count == 64);

    var carry: u1 = 0;
    var index: u32 = 0;
    var start_in: u64 = 1;

    for (0..@divFloor(source.len, wide_count) + 1) |_| {
        if (index >= source.len) break;

        const remaining = source.len - index;
        var tail: [wide_count]u8 = @splat('x');

        if (remaining < wide_count) @memcpy(tail[0..remaining], source[index..]);

        const whole = remaining >= wide_count;
        const bytes: WideChunk = if (whole) source[index..][0..wide_count].* else tail;
        const line_feed_next = remaining > wide_count and source[index + wide_count] == '\n';
        const line_feeds: u64 = @bitCast(bytes == @as(WideChunk, @splat('\n')));
        const returns: u64 = @bitCast(bytes == @as(WideChunk, @splat('\r')));
        const spaces: u64 = @bitCast(bytes == @as(WideChunk, @splat(' ')));
        const tabs: u64 = @bitCast(bytes == @as(WideChunk, @splat('\t')));
        const blanks = spaces | tabs;
        const line_feed_last: u64 = @intFromBool(line_feed_next);
        const line_feeds_after = (line_feeds >> 1) | (line_feed_last << (wide_count - 1));
        const openers = line_feeds | (returns & ~line_feeds_after);
        const starts = (openers << 1) | start_in;
        const partial = @addWithOverflow(blanks, starts);
        const total = @addWithOverflow(partial[0], @as(u64, carry));
        const landings = total[0] & ~blanks;
        const hits = landings & (line_feeds | returns);

        if (hits != 0) {
            const result = index + @ctz(hits);

            assert(result < source.len);

            return result;
        }

        assert(partial[1] & total[1] == 0);

        carry = partial[1] | total[1];
        start_in = openers >> (wide_count - 1);
        index += wide_count;
    }

    return index_none;
}

fn blank_line_find_slow(source: []const u8) u32 {
    assert(source.len <= source_bytes_max);

    for (source, 0..) |byte, position| {
        if (!classes[byte].line_break) continue;

        const following = position + 1 < source.len and source[position + 1] == '\n';
        const crlf_first = byte == '\r' and following;
        if (crlf_first) continue;

        const crlf_second = byte == '\n' and position > 0 and source[position - 1] == '\r';
        const end: u32 = @intCast(if (crlf_second) position - 1 else position);

        assert(end < source.len);

        if (line_above_blank_is(source, @intCast(position + 1))) return end;
    }

    return index_none;
}

fn explicit_start_follows(source: []const u8, start: u32) bool {
    assert(start <= source.len);
    assert(line_start_is(source, start));

    var index = start;
    var line_first = true;

    for (0..source.len + 1) |_| {
        if (index >= source.len) return true;

        if (line_first) {
            if (document_marker_at(source, index)) |kind| return kind == .document_start;
        }

        line_first = false;

        const byte = source[index];

        if (classes[byte].line_break) {
            index += line_break_length(source, index);
            line_first = true;

            continue;
        }

        if (byte == '#') {
            const end = std.mem.findAnyPos(u8, source, index, "\r\n") orelse return true;

            index = @intCast(end);

            continue;
        }

        if (!classes[byte].blank) return false;

        index += 1;
    }

    unreachable;
}

fn line_break_before(source: []const u8, index: u32) bool {
    assert(index <= source.len);
    assert(source.len <= source_bytes_max);

    if (index == 0) return true;
    return classes[source[index - 1]].line_break;
}

fn line_break_length(source: []const u8, index: u32) u32 {
    assert(index < source.len);
    assert(classes[source[index]].line_break);

    const pair = source[index] == '\r' and index + 1 < source.len and source[index + 1] == '\n';
    return if (pair) 2 else 1;
}

const testing = std.testing;

const printable_candidates = [_]u8{
    0x00,
    0x08,
    '\t',
    '\n',
    0x0b,
    0x0c,
    '\r',
    0x1f,
    ' ',
    '~',
    0x7f,
    0x80,
    0xc3,
    0xef,
    0xff,
};

const printable_fillers = "a #:~\t\n\r-";

fn printable_reference(source: []const u8, start: u32) u32 {
    assert(start <= source.len);
    assert(source.len <= source_bytes_max);

    const whole: u32 = @intCast(@divFloor(source.len - start, lane_count) * lane_count);
    var result = start + whole;

    for (source[start..][0..whole], start..) |byte, position| {
        const simple = byte < 0x80;

        if (!simple) {
            result = @intCast(position);

            break;
        }

        if (!ascii_printable_is(byte)) {
            result = @intCast(position);

            break;
        }
    }

    assert(result >= start);
    assert(result <= source.len);

    return result;
}

fn printable_skip_check(buffer: []const u8, position: u32) !void {
    assert(position < buffer.len);
    assert(buffer.len <= 128);

    for ([_]u32{ 0, 1, 31, 32, 33 }) |start| {
        for ([_]usize{ position, position + 1, 63, 64, 65, buffer.len }) |length| {
            if (start > length) continue;
            if (length > buffer.len) continue;

            const source = buffer[0..length];
            const expected = printable_reference(source, start);

            try testing.expectEqual(expected, printable_skip(source, start));
        }
    }
}

test "a printable skip stops at the first byte the scalar check must decide" {
    var buffer: [80]u8 = undefined;

    for (printable_candidates) |candidate| {
        for (0..buffer.len) |position| {
            for (&buffer, 0..) |*byte, index| {
                byte.* = printable_fillers[@mod(index, printable_fillers.len)];
            }

            buffer[position] = candidate;

            try printable_skip_check(&buffer, @intCast(position));
        }
    }
}

const PrefixExpected = struct {
    first: bool,
    spaces: u32,
    tab: ?u32,
};

fn prefix_reference(source: []const u8, index: u32) PrefixExpected {
    assert(index <= source.len);
    assert(source.len <= source_bytes_max);

    var start = index;

    for (0..index) |_| {
        if (start == 0) break;

        const blank = source[start - 1] == ' ' or source[start - 1] == '\t';
        if (!blank) break;

        start -= 1;
    }

    const first = line_start_is(source, start);
    const tab = std.mem.findScalar(u8, source[start..index], '\t');
    var spaces: u32 = 0;

    if (first) {
        for (source[start..index]) |byte| {
            if (byte != ' ') break;

            spaces += 1;
        }
    }

    const result: PrefixExpected = .{
        .first = first,
        .spaces = spaces,
        .tab = if (tab) |offset| start + @as(u32, @intCast(offset)) else null,
    };

    assert(result.spaces <= index - start);

    return result;
}

test "a token's prefix counts the spaces before the first tab of a leading blank run" {
    const blanks = [_][]const u8{ "", " ", "  ", "\t", " \t", "\t ", "  \t  ", " \t \t", "    " };
    const leads = [_][]const u8{ "", "\n", "x", "\xef\xbb\xbf", "\n\xef\xbb\xbf", "y\n" };
    var buffer: [32]u8 = undefined;
    var text: [8]u8 = undefined;

    for (leads) |lead| {
        for (blanks) |blank| {
            const source = try std.mem.print(&buffer, "{s}{s}a", .{ lead, blank });
            const index: u32 = @intCast(source.len - 1);
            const before = source[0..index];
            const line_start = if (std.mem.findScalarLast(u8, before, '\n')) |at| at + 1 else 0;
            const expected = prefix_reference(source, index);
            var scanner: Scanner = undefined;

            scanner.init(source, &text);

            scanner.mark = .{
                .column = @intCast(index - line_start),
                .index = index,
                .line = @intCast(std.mem.countScalar(u8, before, '\n')),
            };

            for (0..2) |_| {
                const prefix = scanner.prefix_of();
                const tab: ?u32 = if (prefix.tab) |mark| mark.index else null;

                try testing.expectEqual(expected.first, prefix.first);
                try testing.expectEqual(expected.spaces, prefix.spaces);
                try testing.expectEqual(expected.tab, tab);
            }
        }
    }
}

const run_candidates = [_]u8{
    '\t',
    '\n',
    '\r',
    ' ',
    '!',
    '"',
    '\'',
    ',',
    ':',
    '[',
    '\\',
    ']',
    'a',
    '{',
    '}',
    '~',
    0x7f,
    0x80,
    0xc3,
    0xef,
    0xff,
};

const run_fillers = "ab-~!#.0";

fn run_reference(source: []const u8, start: u32, comptime stops: Stops) u32 {
    assert(start <= source.len);
    assert(source.len <= source_bytes_max);
    assert(stops.bytes.len > 0);

    const whole: u32 = @intCast(@divFloor(source.len - start, lane_count) * lane_count);
    var result = start + whole;

    for (source[start..][0..whole], start..) |byte, position| {
        const high = byte >= 0x80;
        const listed = std.mem.findScalar(u8, stops.bytes, byte) != null;
        const blank = stops.blank and byte <= ' ';
        const stop = high or listed or blank;

        if (stop) {
            result = @intCast(position);

            break;
        }
    }

    assert(result >= start);
    assert(result <= source.len);

    return result;
}

fn run_end_check(comptime stops: Stops, buffer: []const u8, position: u32) !void {
    assert(position < buffer.len);
    assert(buffer.len <= 128);
    assert(stops.bytes.len > 0);

    for ([_]u32{ 0, 1, 31, 32, 33 }) |start| {
        for ([_]usize{ position, position + 1, 63, 64, 65, buffer.len }) |length| {
            if (start > length) continue;
            if (length > buffer.len) continue;

            const source = buffer[0..length];
            const expected = run_reference(source, start, stops);

            try testing.expectEqual(expected, run_end(source, start, stops));
        }
    }
}

test "a scalar run ends at the first byte its scanner must decide in a whole chunk" {
    var buffer: [80]u8 = undefined;

    const stop_sets = .{
        stops_comment,
        stops_double_quoted,
        stops_plain_block,
        stops_plain_flow,
        stops_single_quoted,
    };

    inline for (stop_sets) |stops| {
        for (run_candidates) |candidate| {
            for (0..buffer.len) |position| {
                for (&buffer, 0..) |*byte, index| {
                    byte.* = run_fillers[@mod(index, run_fillers.len)];
                }

                buffer[position] = candidate;

                try run_end_check(stops, &buffer, @intCast(position));
            }
        }
    }
}

fn space_run_end_check(buffer: []const u8, position: u32) !void {
    assert(position < buffer.len);
    assert(buffer.len <= 128);

    for ([_]u32{ 0, 1, 31, 32, 33 }) |start| {
        for ([_]usize{ position, position + 1, 63, 64, 65, buffer.len }) |length| {
            if (start > length) continue;
            if (length > buffer.len) continue;

            const source = buffer[0..length];
            const run = std.mem.findNone(u8, source[start..], " ") orelse source.len - start;
            const expected: u32 = @intCast(start + run);

            try testing.expectEqual(expected, space_run_end(source, start));
        }
    }
}

test "a space run ends at the first other byte wherever it falls" {
    var buffer: [80]u8 = undefined;

    for ([_]u8{ '\t', 'a', '\n', '#', 0x00, 0x80, 0xff }) |stop| {
        for (0..buffer.len) |position| {
            @memset(&buffer, ' ');
            buffer[position] = stop;

            try space_run_end_check(&buffer, @intCast(position));
        }
    }
}

test "a token after any byte but a blank, a line break, or a byte order mark cannot start a line" {
    const leads = [_][]const u8{ "", "\n", "\xef\xbb", "\n\xef\xbb", "ab" };
    var buffer: [8]u8 = undefined;

    for (0..256) |value| {
        const byte: u8 = @intCast(value);

        switch (byte) {
            ' ', '\t', '\n', '\r', 0xbf => continue,
            else => {},
        }

        for (leads) |lead| {
            const text = try std.mem.print(&buffer, "{s}{c}a", .{ lead, byte });
            const index: u32 = @intCast(text.len - 1);

            try testing.expect(!line_start_is(text, index));
        }
    }

    try testing.expect(line_start_is("\n\xef\xbb\xbfa", 4));
}

const BlankShape = struct {
    run: u32,
    tab_at: u32,
};

fn blank_run_check(buffer: []u8, shape: BlankShape) !void {
    assert(shape.run + 41 <= buffer.len);
    assert(shape.tab_at <= shape.run);

    const run = shape.run;
    const tab_at = shape.tab_at;

    for ([_]u8{ 'x', '\n', ':' }) |lead| {
        @memset(buffer[0..40], lead);
        @memset(buffer[40..][0..run], ' ');

        if (tab_at < run) buffer[40 + tab_at] = '\t';

        buffer[40 + run] = 'a';

        const source = buffer[0 .. 41 + run];
        const index: u32 = 40 + run;
        const expected = blank_run_scan(source, index);
        const found = blank_run_of(source, index);

        try testing.expectEqual(expected.start, found.start);
        try testing.expectEqual(expected.tab, found.tab);
    }
}

test "a blank run found in one chunk matches the byte walk at every length and tab position" {
    var buffer: [96]u8 = undefined;

    for (0..48) |run| {
        for (0..run + 1) |tab_at| {
            const shape: BlankShape = .{ .run = @intCast(run), .tab_at = @intCast(tab_at) };

            try blank_run_check(&buffer, shape);
        }
    }
}

test "the first blank line found by chunks matches the line above check at every break" {
    const alphabet = [_]u8{ ' ', '\t', '\n', '\r', 'a', '#' };
    var prng: std.Random.DefaultPrng = .init(0x5eed_b1a4);
    const random = prng.random();
    var buffer: [200]u8 = undefined;

    for (0..20_000) |_| {
        const length = random.uintLessThan(u32, buffer.len + 1);
        const weights = random.uintLessThan(u32, 4);

        for (buffer[0..length]) |*byte| {
            const roll = random.uintLessThan(u32, 16);
            const pick = alphabet[random.uintLessThan(u32, alphabet.len)];

            byte.* = if (roll < 6 + 2 * weights) ' ' else pick;
        }

        const source = buffer[0..length];

        try testing.expectEqual(blank_line_find_slow(source), blank_line_find(source));
    }

    try testing.expectEqual(index_none, blank_line_find(""));
    try testing.expectEqual(index_none, blank_line_find("a: 1\r\nb: 2\r\n"));
    try testing.expectEqual(@as(u32, 6), blank_line_find("a: 1\r\n\r\nb: 2"));
    try testing.expectEqual(@as(u32, 0), blank_line_find("\na"));
    try testing.expectEqual(@as(u32, 2), blank_line_find(" \t\na"));
    try testing.expectEqual(index_none, blank_line_find("\xef\xbb\xbf\na"));
}
