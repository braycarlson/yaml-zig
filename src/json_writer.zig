const std = @import("std");

const codec = @import("codec.zig");
const document_module = @import("document.zig");
const merge = @import("merge.zig");
const scanner_module = @import("scanner.zig");
const schema_module = @import("schema.zig");

const assert = std.debug.assert;

const Merge = merge.Merge;

const JSONWriter = struct {
    comma: bool,
    depth: u32,
    sink: *std.Io.Writer,

    fn separator_write(json: *JSONWriter) std.Io.Writer.Error!void {
        assert(json.depth <= depth_max);
        assert(escapes[','] == 0);

        if (json.comma) try json.sink.writeByte(',');

        json.comma = true;
    }

    fn begin(json: *JSONWriter, bracket: u8) std.Io.Writer.Error!void {
        assert(bracket == '{' or bracket == '[');
        assert(json.depth < depth_max);

        try json.separator_write();
        try json.sink.writeByte(bracket);

        json.comma = false;
        json.depth += 1;
    }

    fn end(json: *JSONWriter, bracket: u8) std.Io.Writer.Error!void {
        assert(bracket == '}' or bracket == ']');
        assert(json.depth > 0);

        try json.sink.writeByte(bracket);

        json.comma = true;
        json.depth -= 1;
    }

    fn key(json: *JSONWriter, text: []const u8) std.Io.Writer.Error!void {
        assert(text.len <= scanner_module.source_bytes_max);
        assert(json.depth > 0);

        try json.separator_write();
        try json.string_write(text);
        try json.sink.writeByte(':');

        json.comma = false;
    }

    fn string(json: *JSONWriter, text: []const u8) std.Io.Writer.Error!void {
        assert(text.len <= scanner_module.source_bytes_max);
        assert(json.depth <= depth_max);

        try json.separator_write();
        try json.string_write(text);
    }

    fn raw(json: *JSONWriter, text: []const u8) std.Io.Writer.Error!void {
        assert(text.len > 0);
        assert(escapes[text[0]] == 0);

        try json.separator_write();
        try json.sink.writeAll(text);
    }

    fn decimal(json: *JSONWriter, text: []const u8) std.Io.Writer.Error!void {
        assert(text.len > 0);
        assert(escapes[text[0]] == 0);

        try json.separator_write();

        if (text[0] == '-') try json.sink.writeByte('-');

        var leading = true;
        var digit_count: u32 = 0;

        for (text) |byte| {
            if (!std.ascii.isDigit(byte)) continue;

            if (leading) {
                if (byte == '0') continue;

                leading = false;
            }

            try json.sink.writeByte(byte);

            digit_count += 1;
        }

        assert(digit_count > 0);
    }

    fn line_end(json: *JSONWriter) std.Io.Writer.Error!void {
        assert(json.depth == 0);
        assert(json.comma);

        try json.sink.writeByte('\n');

        json.comma = false;
    }

    fn string_write(json: *JSONWriter, text: []const u8) std.Io.Writer.Error!void {
        assert(text.len <= scanner_module.source_bytes_max);
        assert(escapes[0x1f] == 'u');

        var start: usize = 0;

        try json.sink.writeByte('"');

        for (text, 0..) |byte, index| {
            const escape = escapes[byte];
            if (escape == 0) continue;

            try json.sink.writeAll(text[start..index]);
            try escape_write(json.sink, byte);

            start = index + 1;
        }

        try json.sink.writeAll(text[start..]);
        try json.sink.writeByte('"');
    }
};

pub const JSONOptions = struct {
    merge: Merge = .ignored,
    node_count_max: u32,
    non_finite: NonFinite = .refused,

    pub const NonFinite = enum {
        null_value,
        refused,
    };

    pub const CapacityError = error{
        DepthExceeded,
        ExpansionExceeded,
        MergesExceeded,
    };

    pub const ValueError = error{
        FloatNonFinite,
        KeyInvalid,
        MergeInvalid,
    };

    pub const Error = CapacityError || ValueError || std.Io.Writer.Error;
};

pub const Pass = enum {
    count,
    emit,
};

const depth_max: u32 = scanner_module.depth_max;
const escapes: [256]u8 = escapes_build();
const hexadecimal_digits = "0123456789abcdef";
const integer_bytes_max: u32 = 48;

comptime {
    assert(depth_max == 256);
    assert(integer_bytes_max > std.math.log10_int(@as(u128, std.math.maxInt(u128))) + 2);
}

pub fn json_write(
    comptime Source: type,
    comptime pass: Pass,
    source: *const Source,
    sink: *std.Io.Writer,
    options: *const JSONOptions,
) JSONOptions.Error!u64 {
    assert(options.node_count_max > 0);
    assert(sink.end <= sink.buffer.len);

    const Walk = WalkType(Source);

    var walk: Walk = undefined;

    walk.init(source, sink, options);

    for (0..source.root_count()) |index| {
        try walk.document_write(pass, @intCast(index));
    }

    assert(walk.node_count >= source.root_count());
    assert(walk.node_count <= options.node_count_max);

    return walk.node_count;
}

fn WalkType(comptime Source: type) type {
    const Node = merge.NodeOf(Source);
    const Merged = merge.EntriesType(Source);
    const Sources = merge.StackType(Source);

    const Frame = union(enum) {
        mapping: merge.RawEntriesOf(Source),
        merged: Merged,
        sequence: merge.ItemsOf(Source),
    };

    return struct {
        depth: u32,
        frames: [depth_max]Frame,
        json: JSONWriter,
        node_count: u64,
        options: *const JSONOptions,
        source: *const Source,
        sources: Sources,

        const Walk = @This();

        fn init(
            walk: *Walk,
            source: *const Source,
            sink: *std.Io.Writer,
            options: *const JSONOptions,
        ) void {
            assert(options.node_count_max > 0);
            assert(walk.frames.len == depth_max);

            walk.depth = 0;
            walk.json = .{ .comma = false, .depth = 0, .sink = sink };
            walk.node_count = 0;
            walk.options = options;
            walk.source = source;
            walk.sources.count = 0;
        }

        fn document_write(walk: *Walk, comptime pass: Pass, index: u32) JSONOptions.Error!void {
            assert(index < walk.source.root_count());
            assert(walk.depth == 0);
            assert(walk.sources.count == 0);

            try walk.node_open(pass, walk.source.root(index));

            const step_count_max = 2 * @as(u64, walk.options.node_count_max) + 2;

            for (0..step_count_max) |_| {
                if (walk.depth == 0) break;

                try walk.step(pass);
            }

            assert(walk.depth == 0);
            assert(walk.sources.count == 0);

            if (pass == .emit) try walk.json.line_end();
        }

        fn step(walk: *Walk, comptime pass: Pass) JSONOptions.Error!void {
            assert(walk.depth > 0);
            assert(walk.depth <= depth_max);

            const frame = &walk.frames[walk.depth - 1];

            switch (frame.*) {
                .mapping => |*entries| {
                    const entry = entries.next() orelse return walk.frame_close(pass);

                    try walk.key_write(pass, entry.key);
                    try walk.node_open(pass, entry.value);
                },
                .merged => |*merged| {
                    const entry = merged.next() orelse return walk.frame_close(pass);

                    try walk.key_write(pass, entry.key);
                    try walk.node_open(pass, entry.value);
                },
                .sequence => |*items| {
                    const item = items.next() orelse return walk.frame_close(pass);

                    try walk.node_open(pass, item);
                },
            }
        }

        fn node_open(walk: *Walk, comptime pass: Pass, node: Node) JSONOptions.Error!void {
            assert(@backingInt(node) < walk.source.node_count);
            assert(walk.depth <= depth_max);
            assert(walk.node_count <= walk.options.node_count_max);

            try walk.node_count_add();

            switch (walk.source.kind_of(node)) {
                .mapping => try walk.mapping_open(pass, node),
                .scalar => try walk.scalar_write(pass, node),
                .sequence => try walk.sequence_open(pass, node),
            }
        }

        fn mapping_open(walk: *Walk, comptime pass: Pass, mapping: Node) JSONOptions.Error!void {
            assert(walk.depth <= depth_max);
            assert(walk.source.kind_of(mapping) == .mapping);

            if (walk.depth == depth_max) return error.DepthExceeded;

            const frame = &walk.frames[walk.depth];

            switch (walk.options.merge) {
                .applied => {
                    const list = try walk.sources.flatten(walk.source, mapping);

                    frame.* = .{ .merged = .init(walk.source, mapping, list) };
                },
                .ignored => frame.* = .{ .mapping = walk.source.entries(mapping) },
            }

            walk.depth += 1;

            if (pass == .emit) try walk.json.begin('{');
        }

        fn sequence_open(walk: *Walk, comptime pass: Pass, sequence: Node) JSONOptions.Error!void {
            assert(walk.depth <= depth_max);
            assert(walk.source.kind_of(sequence) == .sequence);

            if (walk.depth == depth_max) return error.DepthExceeded;

            walk.frames[walk.depth] = .{ .sequence = walk.source.items(sequence) };
            walk.depth += 1;

            if (pass == .emit) try walk.json.begin('[');
        }

        fn frame_close(walk: *Walk, comptime pass: Pass) JSONOptions.Error!void {
            assert(walk.depth > 0);
            assert(walk.depth <= depth_max);

            walk.depth -= 1;

            const frame = &walk.frames[walk.depth];

            const bracket: u8 = switch (frame.*) {
                .mapping => '}',
                .merged => |*merged| bracket: {
                    walk.sources.pop(merged.list);

                    break :bracket '}';
                },
                .sequence => ']',
            };

            if (pass == .emit) try walk.json.end(bracket);
        }

        fn key_write(walk: *Walk, comptime pass: Pass, key: Node) JSONOptions.Error!void {
            assert(@backingInt(key) < walk.source.node_count);
            assert(walk.depth > 0);
            assert(walk.frames[walk.depth - 1] != .sequence);

            try walk.node_count_add();

            const text = walk.source.text_of(key) orelse return error.KeyInvalid;

            if (pass == .emit) try walk.json.key(text);
        }

        fn scalar_write(walk: *Walk, comptime pass: Pass, node: Node) JSONOptions.Error!void {
            assert(walk.source.kind_of(node) == .scalar);
            assert(walk.node_count > 0);

            const source = walk.source;
            const text = source.text_of(node).?;

            switch (scalar_resolution_of(Source, source, node)) {
                .boolean => {
                    if (source.boolean_of(node)) |value| {
                        return walk.raw_write(pass, if (value) "true" else "false");
                    }
                },
                .float => {
                    if (source.float_of(node)) |value| {
                        if (std.math.isFinite(value)) return walk.float_write(pass, text, value);
                        if (walk.options.non_finite == .refused) return error.FloatNonFinite;
                        return walk.raw_write(pass, "null");
                    }
                },
                .integer => {
                    if (try walk.integer_write(pass, text)) return;
                },
                .null_value => {
                    if (source.null_is(node)) return walk.raw_write(pass, "null");
                },
                .string => {},
            }

            if (pass == .emit) try walk.json.string(text);
        }

        fn integer_write(
            walk: *Walk,
            comptime pass: Pass,
            text: []const u8,
        ) JSONOptions.Error!bool {
            assert(text.len <= scanner_module.source_bytes_max);
            assert(walk.depth <= depth_max);

            const schema = walk.source.schema;

            if (schema_module.integer_text_of(i128, text, schema)) |value| {
                if (pass == .emit) {
                    var buffer: [integer_bytes_max]u8 = undefined;

                    const digits = std.mem.print(&buffer, "{d}", .{value}) catch |err| {
                        switch (err) {
                            error.NoSpaceLeft => unreachable,
                        }
                    };

                    try walk.json.raw(digits);
                }

                return true;
            }

            if (!schema_module.decimal_form_is(text, schema)) return false;

            if (pass == .emit) try walk.json.decimal(text);

            return true;
        }

        fn float_write(
            walk: *Walk,
            comptime pass: Pass,
            text: []const u8,
            value: f64,
        ) JSONOptions.Error!void {
            assert(text.len > 0);
            assert(std.math.isFinite(value));

            if (pass == .count) return;
            if (json_float_text_is(text)) return walk.json.raw(text);

            var buffer: [codec.float_bytes_max]u8 = undefined;

            try walk.json.raw(codec.float_text_render(f64, &buffer, value));
        }

        fn raw_write(walk: *Walk, comptime pass: Pass, text: []const u8) JSONOptions.Error!void {
            assert(text.len > 0);
            assert(walk.node_count > 0);

            if (pass == .emit) try walk.json.raw(text);
        }

        fn node_count_add(walk: *Walk) JSONOptions.Error!void {
            assert(walk.node_count <= walk.options.node_count_max);
            assert(walk.options.node_count_max > 0);

            if (walk.node_count == walk.options.node_count_max) return error.ExpansionExceeded;

            walk.node_count += 1;
        }
    };
}

fn scalar_resolution_of(
    comptime Source: type,
    source: *const Source,
    node: merge.NodeOf(Source),
) schema_module.Resolution {
    assert(source.kind_of(node) == .scalar);
    assert(schema_module.tag_null.len > 0);

    const tag = source.tag_of(node);
    if (tag.len > 0) return schema_module.tag_resolution_of(tag);
    if (source.style_of(node).scalar != .plain) return .string;
    return schema_module.resolution_of(source.text_of(node).?, source.schema);
}

fn json_float_text_is(text: []const u8) bool {
    assert(text.len > 0);
    assert(text.len <= scanner_module.source_bytes_max);

    const digits = if (text[0] == '-') text[1..] else text;
    if (digits.len == 0) return false;
    if (!std.ascii.isDigit(digits[0])) return false;

    var index: usize = 1;

    if (digits[0] != '0') index = digits_end(digits, 1);

    var fraction = false;

    if (index < digits.len) {
        if (digits[index] == '.') {
            const fraction_end = digits_end(digits, index + 1);
            if (fraction_end == index + 1) return false;

            index = fraction_end;
            fraction = true;
        }
    }

    if (index == digits.len) return fraction;

    const marker = digits[index] == 'e' or digits[index] == 'E';
    if (!marker) return false;

    index += 1;

    if (index < digits.len) {
        const sign = digits[index] == '-' or digits[index] == '+';

        if (sign) index += 1;
    }

    const exponent_end = digits_end(digits, index);
    if (exponent_end == index) return false;
    return exponent_end == digits.len;
}

fn digits_end(text: []const u8, start: usize) usize {
    assert(start <= text.len);
    assert(text.len <= scanner_module.source_bytes_max);

    var index = start;

    for (text[start..]) |byte| {
        if (!std.ascii.isDigit(byte)) break;

        index += 1;
    }

    assert(index <= text.len);

    return index;
}

fn escape_write(sink: *std.Io.Writer, byte: u8) std.Io.Writer.Error!void {
    assert(escapes[byte] != 0);
    assert(sink.end <= sink.buffer.len);

    const escape = escapes[byte];
    if (escape != 'u') return sink.writeAll(&.{ '\\', escape });

    const high = hexadecimal_digits[byte >> 4];
    const low = hexadecimal_digits[byte & 0xf];

    try sink.writeAll(&.{ '\\', 'u', '0', '0', high, low });
}

fn escapes_build() [256]u8 {
    var result: [256]u8 = @splat(0);

    for (result[0..0x20]) |*escape| escape.* = 'u';

    result[0x08] = 'b';
    result[0x0c] = 'f';

    result['\n'] = 'n';
    result['\r'] = 'r';
    result['\t'] = 't';
    result['"'] = '"';
    result['\\'] = '\\';

    return result;
}

const testing = std.testing;

const test_output_bytes_max: u32 = 64 * 1024;

const TestDocument = document_module.DocumentType(.{
    .anchor_count_max = 64,
    .comment_count_max = null,
    .node_count_max = 4096,
    .text_bytes_max = 64 * 1024,
});

const test_options: JSONOptions = .{
    .merge = .ignored,
    .node_count_max = 1 << 20,
    .non_finite = .refused,
};

const TestFixture = struct {
    document: TestDocument,
    output: [test_output_bytes_max]u8,
    schema: document_module.Schema,
    sink: std.Io.Writer,

    fn create() !*TestFixture {
        assert(test_output_bytes_max > 0);
        assert(test_options.node_count_max > 0);

        const fixture = try testing.allocator.create(TestFixture);

        fixture.schema = .core;

        return fixture;
    }

    fn written(fixture: *TestFixture, source: []const u8, options: JSONOptions) ![]const u8 {
        assert(source.len < test_output_bytes_max);
        assert(options.node_count_max > 0);

        fixture.sink = .fixed(&fixture.output);

        try fixture.document.parse(source, .{ .schema = fixture.schema });
        try fixture.document.write_json(&fixture.sink, options);

        return fixture.sink.buffered();
    }

    fn refused(
        fixture: *TestFixture,
        source: []const u8,
        options: JSONOptions,
        expected: JSONOptions.Error,
    ) !void {
        assert(source.len < test_output_bytes_max);
        assert(options.node_count_max > 0);
        assert(@errorName(expected).len > 0);

        const outcome = fixture.written(source, options);

        try testing.expectError(expected, outcome);
        try testing.expectEqual(@as(usize, 0), fixture.sink.buffered().len);
    }
};

fn test_lines_parse(output: []const u8, buffer: []u8) !u32 {
    assert(buffer.len > 0);
    assert(output.len <= test_output_bytes_max);

    var allocator: std.heap.FixedBufferAllocator = .init(buffer);
    var lines = std.mem.splitScalar(u8, output, '\n');
    var count: u32 = 0;

    for (0..output.len + 1) |_| {
        const line = lines.next() orelse break;
        if (line.len == 0) continue;

        _ = try std.json.parseFromSliceLeaky(std.json.Value, allocator.allocator(), line, .{
            .duplicate_field_behavior = .@"error",
            .ignore_unknown_fields = false,
            .max_value_len = null,
            .allocate = .alloc_always,
            .parse_numbers = true,
        });

        count += 1;
    }

    return count;
}

test "aliases expand, properties and markers drop, and each document is one line" {
    const fixture = try TestFixture.create();
    defer testing.allocator.destroy(fixture);

    const source =
        \\--- !doc
        \\a: &x [1, {b: c}]
        \\copy: *x
        \\? *x
        \\: ignored
        \\--- &y plain
        \\...
        \\---
        \\...
        \\
    ;

    try testing.expectError(error.KeyInvalid, fixture.written(source, test_options));

    const accepted = "--- !doc\na: &x [1, {b: c}]\ncopy: *x\n--- &y plain\n...\n---\n...\n";
    const output = try fixture.written(accepted, test_options);
    const expected = "{\"a\":[1,{\"b\":\"c\"}],\"copy\":[1,{\"b\":\"c\"}]}\n\"plain\"\nnull\n";

    var buffer: [4096]u8 = undefined;

    try testing.expectEqualStrings(expected, output);
    try testing.expectEqual(@as(u32, 3), try test_lines_parse(output, &buffer));
    try testing.expectEqualStrings("", try fixture.written("", test_options));
}

test "scalars resolve by tag, then style, then the schema" {
    const fixture = try TestFixture.create();
    defer testing.allocator.destroy(fixture);

    const source =
        \\[~, null, '', true, 0x1F, 0o17, -0, +12, 007, 1.5, 1., .5, +1.5, 1e3, -0.0,
        \\ '1', "true", !!str 2, !!int "3", !!float 4, !!int x, !!null x, !!bool yes,
        \\ !custom 5, yes, 1_000, "x\ty\"z\\", "\x01\u00e9"]
        \\
    ;

    const core =
        \\[null,null,"",true,31,15,0,12,7,1.5,1.0,0.5,1.5,1e3,-0.0,"1","true","2",3,4.0,
    ++
        \\"x","x","yes","5","yes","1_000","x\ty\"z\\","\u0001é"]
    ++ "\n";

    const legacy =
        \\[null,null,"",true,31,"0o17",0,12,7,1.5,1.0,0.5,1.5,"1e3",-0.0,"1","true","2",3,
    ++
        \\4.0,"x","x",true,"5",true,1000,"x\ty\"z\\","\u0001é"]
    ++ "\n";

    const json =
        \\["~",null,"",true,"0x1F","0o17",0,"+12","007",1.5,1.0,".5","+1.5",1e3,-0.0,"1","true",
    ++
        \\"2",3,4.0,"x","x","yes","5","yes","1_000","x\ty\"z\\","\u0001é"]
    ++ "\n";

    var buffer: [16 * 1024]u8 = undefined;

    try testing.expectEqualStrings(core, try fixture.written(source, test_options));
    try testing.expectEqual(@as(u32, 1), try test_lines_parse(fixture.sink.buffered(), &buffer));

    fixture.schema = .v1_1;

    try testing.expectEqualStrings(legacy, try fixture.written(source, test_options));

    fixture.schema = .json;

    try testing.expectEqualStrings(json, try fixture.written(source, test_options));
}

test "examples 10.1 to 10.3 keep tagged mappings, sequences, and strings under every schema" {
    const fixture = try TestFixture.create();
    defer testing.allocator.destroy(fixture);

    const source =
        \\Block style: !!map
        \\  Clark : Evans
        \\  Ingy  : döt Net
        \\  Oren  : Ben-Kiki
        \\Flow style: !!seq [ Clark Evans, Ingy döt Net, Oren Ben-Kiki ]
        \\Block string: !!str |-
        \\  String: just a theorem.
        \\Flow string: !!str "String: just a theorem."
        \\
    ;

    const expected = "{\"Block style\":{\"Clark\":\"Evans\",\"Ingy\":\"döt Net\"," ++
        "\"Oren\":\"Ben-Kiki\"},\"Flow style\":[\"Clark Evans\",\"Ingy döt Net\"," ++
        "\"Oren Ben-Kiki\"],\"Block string\":\"String: just a theorem.\"," ++
        "\"Flow string\":\"String: just a theorem.\"}\n";

    for (std.enums.values(document_module.Schema)) |schema| {
        fixture.schema = schema;

        try testing.expectEqualStrings(expected, try fixture.written(source, test_options));
    }
}

test "an empty scalar under a core tag is null only for the null tag" {
    const fixture = try TestFixture.create();
    defer testing.allocator.destroy(fixture);

    const source = "[!!int '', !!float '', !!null '', !!bool '', !!int, !!str]\n";

    try testing.expectEqualStrings(
        "[\"\",\"\",null,\"\",\"\",\"\"]\n",
        try fixture.written(source, test_options),
    );

    fixture.schema = .json;

    try testing.expectEqualStrings(
        "[\"\",\"\",\"\",\"\",\"\",\"\"]\n",
        try fixture.written(source, test_options),
    );
}

test "integers convert to decimal, and past 128 bits only decimal digits stay numbers" {
    const fixture = try TestFixture.create();
    defer testing.allocator.destroy(fixture);

    const wide = "170141183460469231731687303715884105728";
    const hexadecimal: [33]u8 = @splat('f');
    const sevens: [50]u8 = @splat('7');
    const zeros: [40]u8 = @splat('0');
    const core_source = "[-" ++ wide ++ ", +000" ++ wide ++ "1, 0x" ++ hexadecimal ++ ", 0o17]\n";
    const core_expected = "[-" ++ wide ++ "," ++ wide ++ "1,\"0x" ++ hexadecimal ++ "\",15]\n";
    const core_output = try fixture.written(core_source, test_options);

    try testing.expectEqualStrings(core_expected, core_output);

    const legacy_source = "[1_7" ++ zeros ++ ", -0b1_0, 0" ++ sevens ++ ", 1:0:0, 0b_]\n";
    const legacy_expected = "[17" ++ zeros ++ ",-2,\"0" ++ sevens ++ "\",3600,\"0b_\"]\n";

    fixture.schema = .v1_1;

    const legacy_output = try fixture.written(legacy_source, test_options);

    try testing.expectEqualStrings(legacy_expected, legacy_output);
}

test "floats keep JSON text, else take the shortest form, and non-finite values obey the option" {
    const fixture = try TestFixture.create();
    defer testing.allocator.destroy(fixture);

    fixture.schema = .v1_1;

    const legacy = try fixture.written("[1_000.5, 1:30.5, 1.0e+3, 6.]\n", test_options);

    try testing.expectEqualStrings("[1000.5,90.5,1.0e+3,6.0]\n", legacy);

    var nulled = test_options;

    nulled.non_finite = .null_value;
    fixture.schema = .core;

    const finite = try fixture.written("[.inf, -.Inf, .NaN, 1e999, 2.5]\n", nulled);

    try testing.expectEqualStrings("[null,null,null,null,2.5]\n", finite);
    try fixture.refused("[2.5, .inf]\n", test_options, error.FloatNonFinite);
    try fixture.refused("a: [1e999]\n", test_options, error.FloatNonFinite);
}

test "keys are the key text, an alias key is its target's text, and a collection key is refused" {
    const fixture = try TestFixture.create();
    defer testing.allocator.destroy(fixture);

    const duplicated = "{1: a, ~: b, &k \"q\\\"\": c, *k : d, 'e': [f]}\n";
    const source = "{1: a, ~: b, &k \"q\\\"\": c, x: *k}\n";
    const output = try fixture.written(source, test_options);
    const expected = "{\"1\":\"a\",\"~\":\"b\",\"q\\\"\":\"c\",\"x\":\"q\\\"\"}\n";

    try testing.expectEqualStrings(expected, output);
    try testing.expectError(error.KeyDuplicate, fixture.written(duplicated, test_options));
    try fixture.refused("{[a]: b}\n", test_options, error.KeyInvalid);
    try fixture.refused("- ok\n- {? {a: b} : c}\n", test_options, error.KeyInvalid);
}

test "an alias bomb is ExpansionExceeded and the sink stays empty" {
    const fixture = try TestFixture.create();
    defer testing.allocator.destroy(fixture);

    const bomb =
        \\a: &a [x, x, x, x, x, x, x, x, x, x]
        \\b: &b [*a, *a, *a, *a, *a, *a, *a, *a, *a, *a]
        \\c: &c [*b, *b, *b, *b, *b, *b, *b, *b, *b, *b]
        \\d: &d [*c, *c, *c, *c, *c, *c, *c, *c, *c, *c]
        \\e: &e [*d, *d, *d, *d, *d, *d, *d, *d, *d, *d]
        \\f: &f [*e, *e, *e, *e, *e, *e, *e, *e, *e, *e]
        \\
    ;

    var bounded = test_options;

    bounded.node_count_max = 100_000;

    try fixture.refused(bomb, bounded, error.ExpansionExceeded);

    var exact = test_options;

    exact.node_count_max = 7;

    const fitting = try fixture.written("k: [1, 2]\n", exact);

    try testing.expectEqualStrings("{\"k\":[1,2]}\n", fitting);

    exact.node_count_max = 4;

    try fixture.refused("k: [1, 2]\n", exact, error.ExpansionExceeded);
}

test "expanded nesting deeper than the depth bound is DepthExceeded and the sink stays empty" {
    const fixture = try TestFixture.create();
    defer testing.allocator.destroy(fixture);

    var source: [1024]u8 = undefined;
    var sink: std.Io.Writer = .fixed(&source);

    try sink.writeAll("a: &a ");
    try sink.splatByteAll('[', depth_max - 1);
    try sink.splatByteAll(']', depth_max - 1);
    try sink.writeAll("\n");

    const shallow = sink.buffered();
    const output = try fixture.written(shallow, test_options);

    try testing.expect(std.mem.startsWith(u8, output, "{\"a\":[[["));

    try sink.writeAll("b: [*a]\n");
    try fixture.refused(sink.buffered(), test_options, error.DepthExceeded);
}

test "merge keys apply under the option and their failures leave the sink empty" {
    const fixture = try TestFixture.create();
    defer testing.allocator.destroy(fixture);

    const source =
        \\base: &base {image: base, restart: always}
        \\web: {<<: *base, image: nginx, ports: [80]}
        \\
    ;

    var applied = test_options;

    applied.merge = .applied;

    const merged = try fixture.written(source, applied);

    try testing.expectEqualStrings(
        "{\"base\":{\"image\":\"base\",\"restart\":\"always\"}," ++
            "\"web\":{\"restart\":\"always\",\"image\":\"nginx\",\"ports\":[80]}}\n",
        merged,
    );

    const ignored = try fixture.written(source, test_options);

    try testing.expect(std.mem.indexOf(u8, ignored, "\"<<\":{\"image\":\"base\"") != null);
    try fixture.refused("{<<: 5}\n", applied, error.MergeInvalid);

    var many: [2048]u8 = undefined;
    var sink: std.Io.Writer = .fixed(&many);

    try sink.writeAll("- ok\n- {<<: [");
    try sink.splatBytesAll("{}, ", merge.source_count_max);
    try sink.writeAll("{}]}\n");
    try fixture.refused(sink.buffered(), applied, error.MergesExceeded);
}

test "the count pass and the emit pass visit the same nodes" {
    const fixture = try TestFixture.create();
    defer testing.allocator.destroy(fixture);

    const source = "base: &b {a: 1}\nx: {<<: *b, c: [*b, *b]}\n---\n- *b\n";

    var applied = test_options;

    applied.merge = .applied;

    try testing.expectError(error.AliasUndefined, fixture.written(source, applied));

    const valid = "base: &b {a: 1}\nx: {<<: *b, c: [*b, *b]}\n--- [1, [2]]\n";

    _ = try fixture.written(valid, applied);

    const document = &fixture.document.document;

    var sink: std.Io.Writer = .fixed(&fixture.output);

    const counted = try json_write(document_module.Document, .count, document, &sink, &applied);

    try testing.expectEqual(@as(usize, 0), sink.buffered().len);

    const emitted = try json_write(document_module.Document, .emit, document, &sink, &applied);

    try testing.expectEqual(counted, emitted);
    try testing.expectEqual(@as(u64, 21), counted);
}

test "a sink too small for the output fails with WriteFailed" {
    const fixture = try TestFixture.create();
    defer testing.allocator.destroy(fixture);

    var buffer: [8]u8 = undefined;
    var sink: std.Io.Writer = .fixed(&buffer);

    try fixture.document.parse("name: warbler\n", .{ .schema = .core });

    const refused = fixture.document.write_json(&sink, test_options);

    try testing.expectError(error.WriteFailed, refused);
    try testing.expectEqualStrings("{\"name\":", sink.buffered());
}

test JSONOptions {
    const document = try testing.allocator.create(TestDocument);
    defer testing.allocator.destroy(document);

    try document.parse(
        \\defaults: &defaults {replicas: 2, image: base}
        \\web: {<<: *defaults, image: nginx, ratio: .5}
        \\
    , .{ .schema = .core });

    var buffer: [256]u8 = undefined;
    var sink: std.Io.Writer = .fixed(&buffer);

    try document.write_json(&sink, .{
        .merge = .applied,
        .node_count_max = 64,
        .non_finite = .refused,
    });

    const expected = "{\"defaults\":{\"replicas\":2,\"image\":\"base\"}," ++
        "\"web\":{\"replicas\":2,\"image\":\"nginx\",\"ratio\":0.5}}\n";

    try testing.expectEqualStrings(expected, sink.buffered());

    sink = .fixed(&buffer);

    const bounded = document.write_json(&sink, .{
        .merge = .applied,
        .node_count_max = 8,
        .non_finite = .refused,
    });

    try testing.expectError(error.ExpansionExceeded, bounded);
    try testing.expectEqual(@as(usize, 0), sink.buffered().len);
}
