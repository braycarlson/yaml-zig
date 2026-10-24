const std = @import("std");

const document_module = @import("document.zig");
const parser_module = @import("parser.zig");

const assert = std.debug.assert;

const ScalarStyle = parser_module.ScalarStyle;

pub const Schema = enum {
    core,
    json,
    v1_1,
};

pub const Resolution = enum {
    boolean,
    float,
    integer,
    null_value,
    string,
};

const Class = enum {
    binary,
    decimal,
    hexadecimal,
    octal,
};

const Truths = std.StaticStringMap(bool);
const Words = std.StaticStringMap(void);
pub const tag_boolean = "tag:yaml.org,2002:bool";
pub const tag_float = "tag:yaml.org,2002:float";
pub const tag_integer = "tag:yaml.org,2002:int";
pub const tag_merge = "tag:yaml.org,2002:merge";
pub const tag_null = "tag:yaml.org,2002:null";

const boolean_words: Words = .initComptime(.{
    .{"y"},
    .{"Y"},
    .{"yes"},
    .{"Yes"},
    .{"YES"},
    .{"n"},
    .{"N"},
    .{"no"},
    .{"No"},
    .{"NO"},
    .{"on"},
    .{"On"},
    .{"ON"},
    .{"off"},
    .{"Off"},
    .{"OFF"},
});

const core_booleans: Truths = .initComptime(.{
    .{ "true", true },
    .{ "True", true },
    .{ "TRUE", true },
    .{ "false", false },
    .{ "False", false },
    .{ "FALSE", false },
});

const infinity_words: Words = .initComptime(.{ .{".inf"}, .{".Inf"}, .{".INF"} });
const nan_words: Words = .initComptime(.{ .{".nan"}, .{".NaN"}, .{".NAN"} });
const null_words: Words = .initComptime(.{ .{"~"}, .{"null"}, .{"Null"}, .{"NULL"} });

const v1_1_booleans: Truths = .initComptime(.{
    .{ "yes", true },
    .{ "Yes", true },
    .{ "YES", true },
    .{ "true", true },
    .{ "True", true },
    .{ "TRUE", true },
    .{ "on", true },
    .{ "On", true },
    .{ "ON", true },
    .{ "no", false },
    .{ "No", false },
    .{ "NO", false },
    .{ "false", false },
    .{ "False", false },
    .{ "FALSE", false },
    .{ "off", false },
    .{ "Off", false },
    .{ "OFF", false },
});

const class_count = @typeInfo(Class).@"enum".field_names.len;
const class_members: [class_count][256]bool = class_members_build();
const sexagesimal_base: u128 = 60;
const text_bytes_max: u32 = 1 << 31;
const underscore_text_bytes_max: u32 = 1024;

comptime {
    assert(underscore_text_bytes_max >= std.fmt.float.bufferSize(.decimal, f64));
    assert(sexagesimal_base == 60);
    assert(!class_members[@backingInt(Class.hexadecimal)]['_']);
    assert(class_members[@backingInt(Class.octal)]['7']);
}

pub fn resolution_of(text: []const u8, schema: Schema) Resolution {
    assert(text.len <= text_bytes_max);

    const result = switch (schema) {
        .core => core_resolution_of(text),
        .json => json_resolution_of(text),
        .v1_1 => v1_1_resolution_of(text),
    };

    if (result == .null_value) assert(null_text_is(text, schema));

    return result;
}

fn core_resolution_of(text: []const u8) Resolution {
    assert(text.len <= text_bytes_max);
    assert(tag_null.len > 0);

    if (core_null_is(text)) return .null_value;
    if (core_boolean_of(text) != null) return .boolean;
    if (integer_form_is(text)) return .integer;
    if (float_lookalike_is(text)) return .float;
    return .string;
}

fn json_resolution_of(text: []const u8) Resolution {
    assert(text.len <= text_bytes_max);
    assert(tag_null.len > 0);

    if (std.mem.eql(u8, text, "null")) return .null_value;
    if (json_boolean_of(text) != null) return .boolean;
    if (json_integer_form_is(text)) return .integer;
    if (json_float_form_is(text)) return .float;
    return .string;
}

fn v1_1_resolution_of(text: []const u8) Resolution {
    assert(text.len <= text_bytes_max);
    assert(tag_null.len > 0);

    if (core_null_is(text)) return .null_value;
    if (v1_1_boolean_of(text) != null) return .boolean;
    if (v1_1_integer_form_is(text)) return .integer;
    if (v1_1_float_form_is(text)) return .float;
    return .string;
}

pub fn tag_resolution_of(tag: []const u8) Resolution {
    assert(tag.len > 0);
    assert(tag.len <= text_bytes_max);

    if (std.mem.eql(u8, tag, tag_null)) return .null_value;
    if (std.mem.eql(u8, tag, tag_boolean)) return .boolean;
    if (std.mem.eql(u8, tag, tag_integer)) return .integer;
    if (std.mem.eql(u8, tag, tag_float)) return .float;
    return .string;
}

pub fn decimal_form_is(text: []const u8, schema: Schema) bool {
    assert(text.len <= text_bytes_max);
    assert(tag_integer.len > 0);

    const body = sign_strip(text);
    if (body.len == 0) return false;

    return switch (schema) {
        .core => run_end(body, 0, .decimal) == body.len,
        .json => json_integer_form_is(text),
        .v1_1 => v1_1_decimal_form_is(body),
    };
}

fn v1_1_decimal_form_is(body: []const u8) bool {
    assert(body.len > 0);
    assert(body.len <= text_bytes_max);

    if (body[0] == '0') return false;
    if (!std.ascii.isDigit(body[0])) return false;
    return underscored_run_end(body, 1, .decimal) == body.len;
}

pub fn string_style_of(text: []const u8) ScalarStyle {
    assert(text.len <= text_bytes_max);
    assert(tag_merge.len > 0);

    if (resolution_of(text, .core) != .string) return .single_quoted;
    if (resolution_of(text, .v1_1) != .string) return .single_quoted;
    if (boolean_word_is(text)) return .single_quoted;
    if (timestamp_is(text)) return .single_quoted;
    if (std.mem.eql(u8, text, "=")) return .single_quoted;
    if (std.mem.eql(u8, text, "<<")) return .single_quoted;
    if (std.mem.findScalar(u8, text, '\n') != null) return .literal;
    return .plain;
}

pub fn boolean_word_is(text: []const u8) bool {
    assert(text.len <= text_bytes_max);
    assert(boolean_words.kvs.len == 16);

    return boolean_words.has(text);
}

pub fn timestamp_is(text: []const u8) bool {
    assert(text.len <= text_bytes_max);
    assert(tag_null.len > 0);

    if (text.len < 10) return false;
    if (run_end(text, 0, .decimal) != 4) return false;
    if (text[4] != '-') return false;

    const month_end = run_end(text, 5, .decimal);
    if (month_end == text.len) return false;
    if (text[month_end] != '-') return false;

    const day_end = run_end(text, month_end + 1, .decimal);
    const date_exact = month_end == 7 and day_end == 10;
    if (day_end == text.len) return date_exact;
    if (month_end - 5 > 2) return false;
    if (day_end - month_end - 1 > 2) return false;
    if (day_end == month_end + 1) return false;
    if (month_end == 5) return false;
    return clock_rest_is(text[day_end..]);
}

fn clock_rest_is(rest: []const u8) bool {
    assert(rest.len > 0);
    assert(rest.len <= text_bytes_max);

    var index: u32 = 0;

    if (rest[0] == 'T') {
        index = 1;
    } else if (rest[0] == 't') {
        index = 1;
    } else {
        index = blanks_end(rest, 0);

        if (index == 0) return false;
    }

    const hour_end = run_end(rest, index, .decimal);
    if (hour_end == index) return false;
    if (hour_end - index > 2) return false;
    if (!pair_after_colon_is(rest, hour_end)) return false;
    if (!pair_after_colon_is(rest, hour_end + 3)) return false;

    index = hour_end + 6;

    if (index < rest.len) {
        if (rest[index] == '.') index = run_end(rest, index + 1, .decimal);
    }

    return zone_rest_is(rest[index..]);
}

fn pair_after_colon_is(text: []const u8, index: u32) bool {
    assert(index <= text.len);
    assert(text.len <= text_bytes_max);

    if (text.len < index + 3) return false;
    if (text[index] != ':') return false;
    return run_end(text, index + 1, .decimal) - index - 1 >= 2;
}

fn zone_rest_is(rest: []const u8) bool {
    assert(rest.len <= text_bytes_max);
    assert(tag_null.len > 0);

    if (rest.len == 0) return true;

    const index = blanks_end(rest, 0);
    if (index == rest.len) return false;
    if (rest[index] == 'Z') return index + 1 == rest.len;
    if (sign_strip(rest[index..]).len == rest.len - index) return false;

    const hour_end = run_end(rest, index + 1, .decimal);
    if (hour_end == index + 1) return false;
    if (hour_end - index - 1 > 2) return false;
    if (hour_end == rest.len) return true;
    if (rest[hour_end] != ':') return false;
    return run_end(rest, hour_end + 1, .decimal) == rest.len and rest.len - hour_end - 1 == 2;
}

fn blanks_end(text: []const u8, start: u32) u32 {
    assert(start <= text.len);
    assert(text.len <= text_bytes_max);

    var index = start;

    for (text[start..]) |byte| {
        const blank = byte == ' ' or byte == '\t';
        if (!blank) break;

        index += 1;
    }

    assert(index <= text.len);

    return index;
}

fn integer_form_is(text: []const u8) bool {
    assert(text.len <= text_bytes_max);
    assert(tag_integer.len > 0);

    if (std.mem.startsWith(u8, text, "0o")) return radix_digits_are(text[2..], 8);
    if (std.mem.startsWith(u8, text, "0x")) return radix_digits_are(text[2..], 16);

    const digits = sign_strip(text);
    if (digits.len == 0) return false;

    for (digits) |byte| {
        if (!std.ascii.isDigit(byte)) return false;
    }

    return true;
}

fn radix_digits_are(digits: []const u8, radix: u8) bool {
    assert(radix == 8 or radix == 16);
    assert(digits.len <= text_bytes_max);

    if (digits.len == 0) return false;

    for (digits) |byte| {
        const value = std.fmt.charToDigit(byte, radix) catch return false;

        assert(value < radix);
    }

    return true;
}

fn float_lookalike_is(text: []const u8) bool {
    assert(text.len <= text_bytes_max);
    assert(tag_float.len > 0);

    const digits = sign_strip(text);
    if (infinity_words.has(digits)) return true;
    if (nan_words.has(text)) return true;
    return float_form_is(digits);
}

fn json_integer_form_is(text: []const u8) bool {
    assert(text.len <= text_bytes_max);
    assert(tag_integer.len > 0);

    const digits = minus_strip(text);
    if (digits.len == 0) return false;
    if (digits[0] == '0') return digits.len == 1;
    return run_end(digits, 0, .decimal) == digits.len;
}

fn json_float_form_is(text: []const u8) bool {
    assert(text.len <= text_bytes_max);
    assert(tag_float.len > 0);

    const digits = minus_strip(text);
    if (digits.len == 0) return false;
    if (!std.ascii.isDigit(digits[0])) return false;

    var index: u32 = 1;

    if (digits[0] != '0') index = run_end(digits, 1, .decimal);

    if (index < digits.len) {
        if (digits[index] == '.') index = run_end(digits, index + 1, .decimal);
    }

    return exponent_rest_is(digits[index..], .optional);
}

const ExponentSign = enum {
    optional,
    required,
};

fn exponent_rest_is(rest: []const u8, sign: ExponentSign) bool {
    assert(rest.len <= text_bytes_max);
    assert(tag_float.len > 0);

    if (rest.len == 0) return true;

    const marker = rest[0] == 'e' or rest[0] == 'E';
    if (!marker) return false;

    const digits = sign_strip(rest[1..]);

    if (sign == .required) {
        const signed = digits.len < rest.len - 1;
        if (!signed) return false;
    }

    if (digits.len == 0) return false;
    return run_end(digits, 0, .decimal) == digits.len;
}

fn v1_1_integer_form_is(text: []const u8) bool {
    assert(text.len <= text_bytes_max);
    assert(tag_integer.len > 0);

    const body = sign_strip(text);
    if (body.len == 0) return false;

    if (body[0] == '0') {
        if (body.len == 1) return true;
        if (body[1] == 'b') return v1_1_radix_tail_is(body[2..], .binary);
        if (body[1] == 'x') return v1_1_radix_tail_is(body[2..], .hexadecimal);
        return v1_1_radix_tail_is(body[1..], .octal);
    }

    if (!std.ascii.isDigit(body[0])) return false;

    const head_end = underscored_run_end(body, 1, .decimal);
    if (head_end == body.len) return true;
    return sexagesimal_groups_end(body, head_end) == body.len;
}

fn v1_1_radix_tail_is(tail: []const u8, class: Class) bool {
    assert(tail.len <= text_bytes_max);
    assert(class != .decimal);

    if (tail.len == 0) return false;
    return underscored_run_end(tail, 0, class) == tail.len;
}

fn sexagesimal_groups_end(text: []const u8, start: u32) u32 {
    assert(start <= text.len);
    assert(text.len <= text_bytes_max);

    var index = start;

    for (0..text.len - start) |_| {
        if (index == text.len) break;
        if (text[index] != ':') break;

        const group_end = run_end(text, index + 1, .decimal);
        const width = group_end - index - 1;
        if (width == 0) return start;
        if (width > 2) return start;

        if (width == 2) {
            if (text[index + 1] > '5') return start;
        }

        index = group_end;
    }

    assert(index <= text.len);

    return index;
}

fn v1_1_float_form_is(text: []const u8) bool {
    assert(text.len <= text_bytes_max);
    assert(tag_float.len > 0);

    if (nan_word_is(text)) return true;

    const body = sign_strip(text);
    if (infinity_word_is(body)) return true;
    if (body.len == 0) return false;

    if (body[0] == '.') {
        if (body.len < text.len) return false;
        if (body.len < 2) return false;
        if (!std.ascii.isDigit(body[1])) return false;

        const fraction_end = underscored_run_end(body, 2, .decimal);
        return exponent_rest_is(body[fraction_end..], .required);
    }

    if (!std.ascii.isDigit(body[0])) return false;

    const head_end = underscored_run_end(body, 1, .decimal);
    const point = sexagesimal_groups_end(body, head_end);
    if (point == body.len) return false;
    if (body[point] != '.') return false;

    const fraction_end = underscored_run_end(body, point + 1, .decimal);
    if (point > head_end) return fraction_end == body.len;
    return exponent_rest_is(body[fraction_end..], .required);
}

fn nan_word_is(text: []const u8) bool {
    assert(text.len <= text_bytes_max);
    assert(nan_words.kvs.len == 3);

    return nan_words.has(text);
}

fn infinity_word_is(text: []const u8) bool {
    assert(text.len <= text_bytes_max);
    assert(infinity_words.kvs.len == 3);

    return infinity_words.has(text);
}

pub fn null_text_is(text: []const u8, schema: Schema) bool {
    assert(text.len <= text_bytes_max);
    assert(tag_null.len > 0);

    return switch (schema) {
        .core, .v1_1 => core_null_is(text),
        .json => std.mem.eql(u8, text, "null"),
    };
}

fn core_null_is(text: []const u8) bool {
    assert(text.len <= text_bytes_max);
    assert(null_words.kvs.len == 4);

    if (text.len == 0) return true;
    return null_words.has(text);
}

pub fn boolean_text_of(text: []const u8, schema: Schema) ?bool {
    assert(text.len <= text_bytes_max);
    assert(tag_boolean.len > 0);

    return switch (schema) {
        .core => core_boolean_of(text),
        .json => json_boolean_of(text),
        .v1_1 => v1_1_boolean_of(text),
    };
}

fn core_boolean_of(text: []const u8) ?bool {
    assert(text.len <= text_bytes_max);
    assert(core_booleans.kvs.len == 6);

    return core_booleans.get(text);
}

fn json_boolean_of(text: []const u8) ?bool {
    assert(text.len <= text_bytes_max);
    assert(tag_boolean.len > 0);

    if (std.mem.eql(u8, text, "true")) return true;
    if (std.mem.eql(u8, text, "false")) return false;
    return null;
}

fn v1_1_boolean_of(text: []const u8) ?bool {
    assert(text.len <= text_bytes_max);
    assert(v1_1_booleans.kvs.len == 18);

    return v1_1_booleans.get(text);
}

pub fn integer_text_of(comptime T: type, text: []const u8, schema: Schema) ?T {
    comptime assert(@typeInfo(T) == .int);
    comptime assert(@typeInfo(T).int.bits <= 128);
    assert(text.len <= text_bytes_max);

    return switch (schema) {
        .core => core_integer_of(T, text),
        .json => json_integer_of(T, text),
        .v1_1 => v1_1_integer_of(T, text),
    };
}

fn core_integer_of(comptime T: type, text: []const u8) ?T {
    comptime assert(@typeInfo(T) == .int);
    assert(text.len <= text_bytes_max);

    if (text.len < 2) return decimal_of(T, text);
    if (std.mem.startsWith(u8, text, "0o")) return radix_of(T, text[2..], 8);
    if (std.mem.startsWith(u8, text, "0x")) return radix_of(T, text[2..], 16);
    return decimal_of(T, text);
}

fn decimal_of(comptime T: type, text: []const u8) ?T {
    comptime assert(@typeInfo(T) == .int);
    assert(text.len <= text_bytes_max);

    const digits = sign_strip(text);
    if (digits.len == 0) return null;

    for (digits) |byte| {
        if (!std.ascii.isDigit(byte)) return null;
    }

    const result = std.fmt.parseInt(T, text, 10) catch return null;
    return result;
}

fn radix_of(comptime T: type, digits: []const u8, radix: u8) ?T {
    comptime assert(@typeInfo(T) == .int);
    assert(radix == 8 or radix == 16);
    assert(digits.len <= text_bytes_max);

    if (digits.len == 0) return null;

    for (digits) |byte| {
        const value = std.fmt.charToDigit(byte, radix) catch return null;

        assert(value < radix);
    }

    const result = std.fmt.parseUnsigned(T, digits, radix) catch return null;
    return result;
}

fn json_integer_of(comptime T: type, text: []const u8) ?T {
    comptime assert(@typeInfo(T) == .int);
    assert(text.len <= text_bytes_max);

    if (!json_integer_form_is(text)) return null;

    const result = std.fmt.parseInt(T, text, 10) catch return null;
    return result;
}

fn v1_1_integer_of(comptime T: type, text: []const u8) ?T {
    comptime assert(@typeInfo(T) == .int);
    assert(text.len <= text_bytes_max);

    if (!v1_1_integer_form_is(text)) return null;

    const body = sign_strip(text);
    const magnitude = v1_1_magnitude_of(body) orelse return null;
    const signed: i129 = if (text[0] == '-') -@as(i129, magnitude) else magnitude;

    assert(@abs(signed) == magnitude);

    return std.math.cast(T, signed);
}

fn v1_1_magnitude_of(body: []const u8) ?u128 {
    assert(body.len > 0);
    assert(body.len <= text_bytes_max);

    if (body[0] == '0') {
        if (body.len == 1) return 0;
        if (body[1] == 'b') return accumulated_of(body[2..], .binary);
        if (body[1] == 'x') return accumulated_of(body[2..], .hexadecimal);
        return accumulated_of(body, .octal);
    }

    if (std.mem.findScalar(u8, body, ':') == null) return accumulated_of(body, .decimal);

    var parts = std.mem.splitScalar(u8, body, ':');
    var result: u128 = 0;

    for (0..body.len) |_| {
        const part = parts.next() orelse break;
        const value = accumulated_of(part, .decimal) orelse return null;
        const shifted = std.math.mul(u128, result, sexagesimal_base) catch return null;

        result = std.math.add(u128, shifted, value) catch return null;
    }

    return result;
}

fn accumulated_of(digits: []const u8, class: Class) ?u128 {
    assert(digits.len <= text_bytes_max);
    assert(underscored_run_end(digits, 0, class) == digits.len);

    const radix: u8 = switch (class) {
        .binary => 2,
        .decimal => 10,
        .hexadecimal => 16,
        .octal => 8,
    };

    var result: u128 = 0;
    var digit_count: u32 = 0;

    for (digits) |byte| {
        if (byte == '_') continue;

        const digit = std.fmt.charToDigit(byte, radix) catch |err| switch (err) {
            error.InvalidCharacter => unreachable,
        };

        const shifted = std.math.mul(u128, result, radix) catch return null;

        result = std.math.add(u128, shifted, digit) catch return null;
        digit_count += 1;
    }

    if (digit_count == 0) return null;
    return result;
}

pub fn float_text_of(text: []const u8, schema: Schema) ?f64 {
    assert(text.len <= text_bytes_max);
    assert(tag_float.len > 0);

    return switch (schema) {
        .core => core_float_of(text),
        .json => json_float_of(text),
        .v1_1 => v1_1_float_of(text),
    };
}

fn core_float_of(text: []const u8) ?f64 {
    assert(text.len <= text_bytes_max);
    assert(tag_float.len > 0);

    const digits = sign_strip(text);

    if (infinity_words.has(digits)) {
        const negative = text[0] == '-';
        const infinity = std.math.inf(f64);
        const result = if (negative) -infinity else infinity;

        assert(std.math.isInf(result));

        return result;
    }

    if (nan_words.has(text)) return std.math.nan(f64);
    if (!float_form_is(digits)) return null;

    const result = std.fmt.parseFloat(f64, text) catch return null;
    return result;
}

fn json_float_of(text: []const u8) ?f64 {
    assert(text.len <= text_bytes_max);
    assert(tag_float.len > 0);

    if (!json_float_form_is(text)) return null;

    const result = std.fmt.parseFloat(f64, text) catch return null;
    return result;
}

fn v1_1_float_of(text: []const u8) ?f64 {
    assert(text.len <= text_bytes_max);
    assert(tag_float.len > 0);

    if (!v1_1_float_form_is(text)) return null;
    if (nan_word_is(text)) return std.math.nan(f64);

    const body = sign_strip(text);
    const negative = text[0] == '-';
    const magnitude = v1_1_float_magnitude_of(body) orelse return null;
    const result = if (negative) -magnitude else magnitude;

    assert(std.math.signbit(result) == negative);

    return result;
}

fn v1_1_float_magnitude_of(body: []const u8) ?f64 {
    assert(body.len > 0);
    assert(body.len <= text_bytes_max);

    if (infinity_word_is(body)) return std.math.inf(f64);
    if (std.mem.findScalar(u8, body, ':') == null) return underscored_float_of(body);

    var result: f64 = 0;
    var base: u128 = 1;
    var end: usize = body.len;

    for (0..body.len) |_| {
        const colon = std.mem.findScalarLast(u8, body[0..end], ':');
        const start = if (colon) |position| position + 1 else 0;
        const part = underscored_float_of(body[start..end]) orelse return null;
        const scale: f64 = @floatFromInt(base);

        result += part * scale;

        if (colon == null) break;

        base = std.math.mul(u128, base, sexagesimal_base) catch return null;
        end = colon.?;
    }

    return result;
}

fn underscored_float_of(text: []const u8) ?f64 {
    assert(text.len > 0);
    assert(text.len <= text_bytes_max);

    if (std.mem.findScalar(u8, text, '_') == null) {
        const result = std.fmt.parseFloat(f64, text) catch return null;
        return result;
    }

    var buffer: [underscore_text_bytes_max]u8 = undefined;
    var length: u32 = 0;

    for (text) |byte| {
        if (byte == '_') continue;
        if (length == buffer.len) return null;

        buffer[length] = byte;
        length += 1;
    }

    if (length == 0) return null;

    const result = std.fmt.parseFloat(f64, buffer[0..length]) catch return null;
    return result;
}

fn float_form_is(digits: []const u8) bool {
    assert(digits.len <= text_bytes_max);
    assert(tag_float.len > 0);

    var index: u32 = 0;
    var mantissa_digits: u32 = 0;

    index = digits_skip(digits, index, &mantissa_digits);

    if (index < digits.len) {
        if (digits[index] == '.') index = digits_skip(digits, index + 1, &mantissa_digits);
    }

    if (mantissa_digits == 0) return false;
    if (index == digits.len) return true;

    const exponent_marker = digits[index] == 'e' or digits[index] == 'E';
    if (!exponent_marker) return false;

    index += 1;

    if (index < digits.len) {
        const sign = digits[index] == '-' or digits[index] == '+';

        if (sign) index += 1;
    }

    var exponent_digits: u32 = 0;

    index = digits_skip(digits, index, &exponent_digits);

    if (exponent_digits == 0) return false;
    return index == digits.len;
}

fn digits_skip(digits: []const u8, start: u32, count: *u32) u32 {
    assert(start <= digits.len);
    assert(digits.len <= text_bytes_max);

    var index = start;

    for (digits[start..]) |byte| {
        if (!std.ascii.isDigit(byte)) break;

        index += 1;
        count.* += 1;
    }

    assert(index <= digits.len);

    return index;
}

fn run_end(text: []const u8, start: u32, class: Class) u32 {
    assert(start <= text.len);
    assert(text.len <= text_bytes_max);

    var index = start;

    for (text[start..]) |byte| {
        if (!class_members[@backingInt(class)][byte]) break;

        index += 1;
    }

    assert(index <= text.len);

    return index;
}

fn underscored_run_end(text: []const u8, start: u32, class: Class) u32 {
    assert(start <= text.len);
    assert(text.len <= text_bytes_max);

    var index = start;

    for (text[start..]) |byte| {
        if (byte != '_') {
            if (!class_members[@backingInt(class)][byte]) break;
        }

        index += 1;
    }

    assert(index <= text.len);

    return index;
}

fn class_members_build() [class_count][256]bool {
    var result: [class_count][256]bool = undefined;

    for (0..256) |index| {
        const byte: u8 = @intCast(index);

        result[@backingInt(Class.binary)][index] = byte == '0' or byte == '1';
        result[@backingInt(Class.decimal)][index] = std.ascii.isDigit(byte);
        result[@backingInt(Class.hexadecimal)][index] = std.ascii.isHex(byte);
        result[@backingInt(Class.octal)][index] = byte >= '0' and byte <= '7';
    }

    return result;
}

fn sign_strip(text: []const u8) []const u8 {
    assert(text.len <= text_bytes_max);
    assert(tag_integer.len > 0);

    if (text.len == 0) return text;

    const signed = text[0] == '-' or text[0] == '+';
    return if (signed) text[1..] else text;
}

fn minus_strip(text: []const u8) []const u8 {
    assert(text.len <= text_bytes_max);
    assert(tag_integer.len > 0);

    if (text.len == 0) return text;
    if (text[0] == '-') return text[1..];
    return text;
}

const testing = std.testing;

test "the core schema resolves null, booleans, integers, and floats by the 1.2.2 patterns" {
    try testing.expect(null_text_is("", .core));
    try testing.expect(null_text_is("~", .core));
    try testing.expect(null_text_is("NULL", .core));
    try testing.expect(!null_text_is("nil", .core));
    try testing.expectEqual(@as(?bool, true), boolean_text_of("True", .core));
    try testing.expectEqual(@as(?bool, false), boolean_text_of("FALSE", .core));
    try testing.expectEqual(@as(?bool, null), boolean_text_of("yes", .core));
    try testing.expectEqual(@as(?i64, 42), integer_text_of(i64, "42", .core));
    try testing.expectEqual(@as(?i64, -17), integer_text_of(i64, "-17", .core));
    try testing.expectEqual(@as(?i64, 7), integer_text_of(i64, "+007", .core));
    try testing.expectEqual(@as(?i64, 0o14), integer_text_of(i64, "0o14", .core));
    try testing.expectEqual(@as(?i64, 0xc), integer_text_of(i64, "0xC", .core));
    try testing.expectEqual(@as(?i64, null), integer_text_of(i64, "0b101", .core));
    try testing.expectEqual(@as(?i64, null), integer_text_of(i64, "1_000", .core));
    try testing.expectEqual(@as(?i64, null), integer_text_of(i64, "9223372036854775808", .core));
    try testing.expectEqual(@as(?f64, 1.5), float_text_of("1.5", .core));
    try testing.expectEqual(@as(?f64, -0.5), float_text_of("-.5", .core));
    try testing.expectEqual(@as(?f64, 1200), float_text_of("12e2", .core));
    try testing.expectEqual(@as(?f64, 3), float_text_of("3", .core));
    try testing.expect(std.math.isNegativeInf(float_text_of("-.inf", .core).?));
    try testing.expect(std.math.isNan(float_text_of(".NaN", .core).?));
    try testing.expectEqual(@as(?f64, null), float_text_of("1e", .core));
    try testing.expectEqual(@as(?f64, null), float_text_of(".", .core));
    try testing.expectEqual(@as(?f64, null), float_text_of("inf", .core));
    try testing.expectEqual(@as(?f64, null), float_text_of("0x1p3", .core));
}

test "resolution matches the core patterns, so an integer too large for i64 is still an integer" {
    try testing.expectEqual(Resolution.null_value, resolution_of("", .core));
    try testing.expectEqual(Resolution.null_value, resolution_of("~", .core));
    try testing.expectEqual(Resolution.boolean, resolution_of("TRUE", .core));
    try testing.expectEqual(Resolution.string, resolution_of("yes", .core));
    try testing.expectEqual(Resolution.integer, resolution_of("12345678901234567890", .core));
    try testing.expectEqual(Resolution.integer, resolution_of("-0", .core));
    try testing.expectEqual(Resolution.integer, resolution_of("0o17", .core));
    try testing.expectEqual(Resolution.integer, resolution_of("0xFF", .core));
    try testing.expectEqual(Resolution.string, resolution_of("0o", .core));
    try testing.expectEqual(Resolution.string, resolution_of("0o8", .core));
    try testing.expectEqual(Resolution.string, resolution_of("-0x1", .core));
    try testing.expectEqual(Resolution.float, resolution_of("1.", .core));
    try testing.expectEqual(Resolution.float, resolution_of("-.5e+3", .core));
    try testing.expectEqual(Resolution.float, resolution_of("1e999", .core));
    try testing.expectEqual(Resolution.float, resolution_of("-.inf", .core));
    try testing.expectEqual(Resolution.float, resolution_of(".NaN", .core));
    try testing.expectEqual(Resolution.string, resolution_of("+.nan", .core));
    try testing.expectEqual(Resolution.string, resolution_of("1_000", .core));
    try testing.expectEqual(Resolution.string, resolution_of("a", .core));
    try testing.expectEqual(@as(?i64, null), integer_text_of(i64, "12345678901234567890", .core));
}

test "the YAML 1.1 boolean words are recognized and nothing else" {
    const words = [_][]const u8{ "y", "Y", "yes", "Yes", "YES", "n", "NO", "on", "On", "OFF" };
    const others = [_][]const u8{ "", "true", "yEs", "of", "ye", "nO", "o", "offf" };

    for (words) |word| {
        try testing.expect(boolean_word_is(word));
    }

    for (others) |word| {
        try testing.expect(!boolean_word_is(word));
    }
}

const TestResolution = struct {
    core: Resolution,
    json: Resolution,
    text: []const u8,
    v1_1: Resolution,
};

test "each schema resolves the YAML 1.2.2 examples and PyYAML's edges by its own patterns" {
    const cases = [_]TestResolution{
        .{ .text = "0777", .core = .integer, .json = .string, .v1_1 = .integer },
        .{ .text = "0o777", .core = .integer, .json = .string, .v1_1 = .string },
        .{ .text = "0b101", .core = .string, .json = .string, .v1_1 = .integer },
        .{ .text = "1_000", .core = .string, .json = .string, .v1_1 = .integer },
        .{ .text = "190:20:30", .core = .string, .json = .string, .v1_1 = .integer },
        .{ .text = "1:30.5", .core = .string, .json = .string, .v1_1 = .float },
        .{ .text = ".5", .core = .float, .json = .string, .v1_1 = .float },
        .{ .text = "+.5", .core = .float, .json = .string, .v1_1 = .string },
        .{ .text = "1e3", .core = .float, .json = .float, .v1_1 = .string },
        .{ .text = "1.0e+3", .core = .float, .json = .float, .v1_1 = .float },
        .{ .text = "yes", .core = .string, .json = .string, .v1_1 = .boolean },
        .{ .text = "Y", .core = .string, .json = .string, .v1_1 = .string },
        .{ .text = "~", .core = .null_value, .json = .string, .v1_1 = .null_value },
        .{ .text = "", .core = .null_value, .json = .string, .v1_1 = .null_value },
        .{ .text = "null", .core = .null_value, .json = .null_value, .v1_1 = .null_value },
        .{ .text = "Null", .core = .null_value, .json = .string, .v1_1 = .null_value },
        .{ .text = "True", .core = .boolean, .json = .string, .v1_1 = .boolean },
        .{ .text = "false", .core = .boolean, .json = .boolean, .v1_1 = .boolean },
        .{ .text = "-0", .core = .integer, .json = .integer, .v1_1 = .integer },
        .{ .text = "0x3A", .core = .integer, .json = .string, .v1_1 = .integer },
        .{ .text = "-0x1F", .core = .string, .json = .string, .v1_1 = .integer },
        .{ .text = "09", .core = .integer, .json = .string, .v1_1 = .string },
        .{ .text = "0.", .core = .float, .json = .float, .v1_1 = .float },
        .{ .text = "-0.0", .core = .float, .json = .float, .v1_1 = .float },
        .{ .text = "12e03", .core = .float, .json = .float, .v1_1 = .string },
        .{ .text = "-2E+05", .core = .float, .json = .float, .v1_1 = .string },
        .{ .text = "+12.3", .core = .float, .json = .string, .v1_1 = .float },
        .{ .text = "-.Inf", .core = .float, .json = .string, .v1_1 = .float },
        .{ .text = "-.nan", .core = .string, .json = .string, .v1_1 = .string },
        .{ .text = "1:59", .core = .string, .json = .string, .v1_1 = .integer },
        .{ .text = "1:60", .core = .string, .json = .string, .v1_1 = .string },
        .{ .text = "0:30", .core = .string, .json = .string, .v1_1 = .string },
        .{ .text = "0b_", .core = .string, .json = .string, .v1_1 = .integer },
        .{ .text = "._5", .core = .string, .json = .string, .v1_1 = .string },
        .{ .text = "2001-12-14", .core = .string, .json = .string, .v1_1 = .string },
    };

    for (cases) |case| {
        try testing.expectEqual(case.core, resolution_of(case.text, .core));
        try testing.expectEqual(case.json, resolution_of(case.text, .json));
        try testing.expectEqual(case.v1_1, resolution_of(case.text, .v1_1));
    }
}

test "integers under 1.1 follow construct_yaml_int, so underscores, octal, and base 60 count" {
    const texts = [_][]const u8{
        "0777",
        "0b101",
        "1_000",
        "190:20:30",
        "-1_0:20",
        "0_7",
        "0_",
        "-0b1",
        "1__",
        "0x_1F",
        "+0",
    };

    const values = [_]i64{ 511, 5, 1000, 685230, -620, 7, 0, -1, 1, 31, 0 };

    for (texts, values) |text, value| {
        try testing.expectEqual(@as(?i64, value), integer_text_of(i64, text, .v1_1));
    }

    try testing.expectEqual(@as(?i64, null), integer_text_of(i64, "0b_", .v1_1));
    try testing.expectEqual(@as(?i64, null), integer_text_of(i64, "0x_", .v1_1));
    try testing.expectEqual(@as(?i64, null), integer_text_of(i64, "09", .v1_1));
    try testing.expectEqual(@as(?i64, null), integer_text_of(i64, "0o7", .v1_1));
    try testing.expectEqual(@as(?u8, null), integer_text_of(u8, "-1", .v1_1));
    try testing.expectEqual(@as(?u8, 0), integer_text_of(u8, "-0", .v1_1));
    try testing.expectEqual(@as(?i8, -128), integer_text_of(i8, "-0b1000_0000", .v1_1));
    try testing.expectEqual(@as(?i8, null), integer_text_of(i8, "0b1000_0000", .v1_1));

    const largest = "170141183460469231731687303715884105727";
    const maximum: i128 = std.math.maxInt(i128);

    try testing.expectEqual(@as(?i128, maximum), integer_text_of(i128, largest, .v1_1));
    try testing.expectEqual(@as(?i128, null), integer_text_of(i128, largest ++ "0", .v1_1));
}

test "integers under the JSON schema allow one sign and no leading zero" {
    try testing.expectEqual(@as(?i64, -19), integer_text_of(i64, "-19", .json));
    try testing.expectEqual(@as(?i64, 0), integer_text_of(i64, "-0", .json));
    try testing.expectEqual(@as(?i64, null), integer_text_of(i64, "+12", .json));
    try testing.expectEqual(@as(?i64, null), integer_text_of(i64, "012", .json));
    try testing.expectEqual(@as(?i64, null), integer_text_of(i64, "0x3A", .json));
    try testing.expectEqual(@as(?i64, null), integer_text_of(i64, "1_000", .json));
}

test "floats under 1.1 follow construct_yaml_float, and the JSON schema has no infinity" {
    const texts = [_][]const u8{
        "1:30.5",
        "190:20:30.15",
        "1:2:3.5",
        ".5",
        "1.",
        "1._",
        "1_.5",
        "1_000.5",
        "1.0e+3",
        "1.5e-3",
        "-0.0",
        "+12.3",
    };

    const values = [_]f64{
        90.5,
        685230.15,
        3723.5,
        0.5,
        1.0,
        1.0,
        1.5,
        1000.5,
        1000.0,
        0.0015,
        -0.0,
        12.3,
    };

    for (texts, values) |text, value| {
        const result = float_text_of(text, .v1_1) orelse return error.FloatMissing;

        try testing.expectEqual(@as(u64, @bitCast(value)), @as(u64, @bitCast(result)));
    }

    try testing.expect(std.math.isPositiveInf(float_text_of("+.inf", .v1_1).?));
    try testing.expect(std.math.isNegativeInf(float_text_of("-.INF", .v1_1).?));
    try testing.expect(std.math.isNan(float_text_of(".NaN", .v1_1).?));
    try testing.expectEqual(@as(?f64, null), float_text_of("1e3", .v1_1));
    try testing.expectEqual(@as(?f64, null), float_text_of("+.5", .v1_1));
    try testing.expectEqual(@as(?f64, null), float_text_of("-.nan", .v1_1));
    try testing.expectEqual(@as(?f64, 1000), float_text_of("1e3", .json));
    try testing.expectEqual(@as(?f64, -200000), float_text_of("-2E+05", .json));
    try testing.expectEqual(@as(?f64, null), float_text_of(".inf", .json));
    try testing.expectEqual(@as(?f64, null), float_text_of("+12.3", .json));
}

test "the 1.1 timestamp pattern accepts the PyYAML forms and nothing near them" {
    const accepted = [_][]const u8{
        "2001-12-14",
        "2001-12-14t21:59:43.10-05:00",
        "2001-12-14 21:59:43.10 -5",
        "2001-12-15T02:59:43.1Z",
        "2001-1-1 1:00:00",
        "2001-12-14  21:59:43.10   Z",
        "2001-12-14T21:59:43.",
        "2001-12-14\t21:59:43+05:30",
    };

    const refused = [_][]const u8{
        "2001-1-1",
        "2001-12-14 ",
        "2001-12-14T",
        "2001-12-14T21:59",
        "2001-12-14T21:59:4",
        "2001-12-14T21:599:43",
        "2001-12-14T21:59:433",
        "2001-123-14T21:59:43",
        "2001-12-14T21:59:43 ",
        "2001-12-14T21:59:43 X",
        "2001-12-14T21:59:43+05:3",
        "201-12-14",
        "2001/12/14",
    };

    for (accepted) |text| try testing.expect(timestamp_is(text));
    for (refused) |text| try testing.expect(!timestamp_is(text));
}

test "a string is quoted when core, 1.1, or PyYAML would read it as something else" {
    const quoted = [_][]const u8{
        "true",
        "1",
        "",
        "y",
        "N",
        "on",
        "0b101",
        "1_000",
        "190:20:30",
        "1:30.5",
        "2001-12-14",
        "=",
        "<<",
        "0o17",
    };

    for (quoted) |text| {
        try testing.expectEqual(ScalarStyle.single_quoted, string_style_of(text));
    }

    try testing.expectEqual(ScalarStyle.plain, string_style_of("warbler"));
    try testing.expectEqual(ScalarStyle.plain, string_style_of("1e"));
    try testing.expectEqual(ScalarStyle.literal, string_style_of("a\nb"));
}

test "a tag picks the resolution and a decimal form is told from the other integer forms" {
    try testing.expectEqual(Resolution.null_value, tag_resolution_of(tag_null));
    try testing.expectEqual(Resolution.integer, tag_resolution_of(tag_integer));
    try testing.expectEqual(Resolution.string, tag_resolution_of(tag_merge));
    try testing.expectEqual(Resolution.string, tag_resolution_of("!local"));
    try testing.expect(decimal_form_is("+0012", .core));
    try testing.expect(!decimal_form_is("0o12", .core));
    try testing.expect(decimal_form_is("-12", .json));
    try testing.expect(!decimal_form_is("012", .json));
    try testing.expect(decimal_form_is("+1_2", .v1_1));
    try testing.expect(!decimal_form_is("012", .v1_1));
    try testing.expect(!decimal_form_is("_12", .v1_1));
    try testing.expect(!decimal_form_is("1:20", .v1_1));
}

test Schema {
    const Fixed = document_module.DocumentType(.{
        .anchor_count_max = 4,
        .comment_count_max = null,
        .node_count_max = 64,
        .text_bytes_max = 1024,
    });

    const document = try testing.allocator.create(Fixed);
    defer testing.allocator.destroy(document);

    const source = "[yes, 0777, 1_000, 1e3, ~]\n";

    try document.parse(source, .{ .schema = .v1_1 });

    const legacy = document.root(0);

    try testing.expectEqual(@as(?bool, true), document.boolean_of(document.item(legacy, 0).?));
    try testing.expectEqual(@as(?i64, 511), document.integer_of(document.item(legacy, 1).?));
    try testing.expectEqual(@as(?i64, 1000), document.integer_of(document.item(legacy, 2).?));
    try testing.expectEqual(@as(?f64, null), document.float_of(document.item(legacy, 3).?));
    try testing.expect(document.null_is(document.item(legacy, 4).?));

    try document.parse(source, .{ .schema = .core });

    const core = document.root(0);

    try testing.expectEqual(@as(?bool, null), document.boolean_of(document.item(core, 0).?));
    try testing.expectEqual(@as(?i64, 777), document.integer_of(document.item(core, 1).?));
    try testing.expectEqual(@as(?i64, null), document.integer_of(document.item(core, 2).?));
    try testing.expectEqual(@as(?f64, 1000), document.float_of(document.item(core, 3).?));

    try document.parse(source, .{ .schema = .json });

    const json = document.root(0);

    try testing.expectEqual(@as(?i64, null), document.integer_of(document.item(json, 1).?));
    try testing.expectEqual(@as(?f64, 1000), document.float_of(document.item(json, 3).?));
    try testing.expect(!document.null_is(document.item(json, 4).?));
}
