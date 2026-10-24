const std = @import("std");

const assert = std.debug.assert;

pub const Error = error{Overflow};

pub fn BoundedArrayType(comptime T: type, comptime capacity: u32) type {
    comptime assert(capacity > 0);

    return struct {
        buffer: [capacity]T,
        count: u32,

        const BoundedArray = @This();

        pub const capacity_max: u32 = capacity;

        pub const empty: BoundedArray = .{ .buffer = undefined, .count = 0 };

        pub fn clear(array: *BoundedArray) void {
            assert(array.count <= capacity);

            array.count = 0;

            assert(array.slice().len == 0);
        }

        pub fn full(array: *const BoundedArray) bool {
            assert(array.count <= capacity);

            return array.count == capacity;
        }

        pub fn get(array: *const BoundedArray, index: u32) *const T {
            assert(array.count <= capacity);
            assert(index < array.count);

            return &array.buffer[index];
        }

        pub fn get_mutable(array: *BoundedArray, index: u32) *T {
            assert(array.count <= capacity);
            assert(index < array.count);

            return &array.buffer[index];
        }

        pub fn push_slot(array: *BoundedArray) Error!*T {
            assert(array.count <= capacity);

            if (array.count == capacity) return error.Overflow;

            array.count += 1;

            assert(array.count <= capacity);

            return &array.buffer[array.count - 1];
        }

        pub fn push_slot_assume_capacity(array: *BoundedArray) *T {
            assert(array.count < capacity);

            array.count += 1;

            assert(array.count <= capacity);

            return &array.buffer[array.count - 1];
        }

        pub fn push_slice_assume_capacity(array: *BoundedArray, items: []const T) void {
            assert(items.len <= capacity - array.count);
            assert(array.count <= capacity);

            const count: u32 = @intCast(items.len);

            @memcpy(array.buffer[array.count..][0..count], items);
            array.count += count;
        }

        pub fn push_slice(array: *BoundedArray, items: []const T) Error!void {
            assert(array.count <= capacity);
            assert(items.len <= std.math.maxInt(u32));

            if (items.len > capacity - array.count) return error.Overflow;

            const count: u32 = @intCast(items.len);

            @memcpy(array.buffer[array.count..][0..count], items);
            array.count += count;

            assert(array.count <= capacity);
        }

        pub fn print(
            array: *BoundedArray,
            comptime format: []const u8,
            arguments: anytype,
        ) Error!void {
            comptime assert(T == u8);
            comptime assert(format.len > 0);
            comptime assert(@typeInfo(@TypeOf(arguments)) == .@"struct");
            assert(array.count <= capacity);

            const written = std.mem.print(array.buffer[array.count..], format, arguments) catch {
                return error.Overflow;
            };

            array.count += @intCast(written.len);

            assert(array.count <= capacity);
        }

        pub fn resize_assume_capacity(array: *BoundedArray, count: u32) void {
            assert(array.count <= capacity);
            assert(count <= capacity);

            array.count = count;
        }

        pub fn set(array: *BoundedArray, items: []const T) Error!void {
            assert(array.count <= capacity);
            assert(items.len <= std.math.maxInt(u32));

            if (items.len > capacity) return error.Overflow;

            array.clear();
            array.push_slice_assume_capacity(items);

            assert(array.count == items.len);
        }

        pub fn slice(array: *const BoundedArray) []const T {
            assert(array.count <= capacity);

            return array.buffer[0..array.count];
        }

        pub fn slice_mutable(array: *BoundedArray) []T {
            assert(array.count <= capacity);

            return array.buffer[0..array.count];
        }

        pub fn slice_unused(array: *BoundedArray) []T {
            assert(array.count <= capacity);

            return array.buffer[array.count..];
        }

        pub fn truncate(array: *BoundedArray, count: u32) void {
            assert(array.count <= capacity);
            assert(count <= array.count);

            array.count = count;
        }
    };
}

const testing = std.testing;

test "a push past the capacity is refused and leaves the array intact" {
    var array: BoundedArrayType(u8, 4) = .empty;

    try array.push_slice("abc");

    const overflowed_slice = array.push_slice("de");

    try testing.expectError(error.Overflow, overflowed_slice);
    try testing.expectEqualStrings("abc", array.slice());

    try array.push_slice("d");

    const overflowed_item = array.push_slice("e");

    try testing.expect(array.full());
    try testing.expectError(error.Overflow, overflowed_item);
    try testing.expectEqualStrings("abcd", array.slice());
}

test "print formats into the free capacity or leaves the array as it was" {
    var array: BoundedArrayType(u8, 8) = .empty;

    try array.print("{d}-{s}", .{ 42, "ab" });
    try testing.expectEqualStrings("42-ab", array.slice());

    const overflowed = array.print("{s}", .{"toolong"});

    try testing.expectError(error.Overflow, overflowed);
    try testing.expectEqualStrings("42-ab", array.slice());
}

test "set replaces the contents and truncate shortens them" {
    var array: BoundedArrayType(u32, 3) = .empty;

    try array.set(&.{ 1, 2, 3 });
    array.truncate(1);

    try testing.expectEqualSlices(u32, &.{1}, array.slice());

    const overflowed = array.set(&.{ 1, 2, 3, 4 });

    try testing.expectError(error.Overflow, overflowed);
    try testing.expectEqualSlices(u32, &.{1}, array.slice());
}

const model_capacity: u32 = 16;
const model_step_count: u32 = 10_000;

const ModelAction = enum {
    clear,
    get_mutable,
    print,
    push_slice,
    push_slot,
    resize_assume_capacity,
    set,
    truncate,
};

const ModelArray = BoundedArrayType(u8, model_capacity);

const Model = struct {
    array: ModelArray,
    list: std.ArrayList(u8),
    prng: std.Random.DefaultPrng,
};

test "every operation agrees with an ArrayList model of the same capacity" {
    var model = Model{
        .array = .empty,
        .list = try .initCapacity(testing.allocator, model_capacity),
        .prng = .init(testing.random_seed),
    };

    defer model.list.deinit(testing.allocator);

    var step: u32 = 0;

    while (step < model_step_count) : (step += 1) {
        try model_step(&model);
        try testing.expectEqualSlices(u8, model.list.items, model.array.slice());
        try testing.expectEqual(model.list.items.len == model_capacity, model.array.full());
    }
}

fn model_step(model: *Model) !void {
    assert(model.array.count == model.list.items.len);
    assert(model.list.capacity >= model_capacity);

    const random = model.prng.random();
    const actions = comptime std.enums.values(ModelAction);
    const action = actions[random.uintLessThan(u32, actions.len)];
    var bytes: [model_capacity + 4]u8 = undefined;

    random.bytes(&bytes);

    const items = bytes[0..random.uintAtMost(u32, bytes.len)];

    switch (action) {
        .clear => {
            model.array.clear();
            model.list.clearRetainingCapacity();
        },
        .get_mutable => try model_get_mutable(model),
        .print => try model_print(model),
        .push_slice => try model_push_slice(model, items),
        .push_slot => try model_push_slot(model),
        .resize_assume_capacity => model_resize(model, items),
        .set => try model_set(model, items),
        .truncate => {
            const count = random.uintAtMost(u32, model.array.count);

            model.array.truncate(count);
            model.list.shrinkRetainingCapacity(count);
        },
    }
}

fn model_get_mutable(model: *Model) !void {
    assert(model.array.count == model.list.items.len);
    assert(model.list.capacity >= model_capacity);

    if (model.array.count == 0) return;

    const random = model.prng.random();
    const index = random.uintLessThan(u32, model.array.count);
    const byte = random.int(u8);

    model.array.get_mutable(index).* = byte;
    model.list.items[index] = byte;

    try testing.expectEqual(byte, model.array.get(index).*);
}

fn model_print(model: *Model) !void {
    assert(model.array.count == model.list.items.len);
    assert(model.list.capacity >= model_capacity);

    var text: [8]u8 = undefined;
    const number = model.prng.random().int(u16);
    const expected = try std.mem.print(&text, "{d}", .{number});
    const printed = model.array.print("{d}", .{number});

    if (model.list.items.len + expected.len > model_capacity) {
        return testing.expectError(error.Overflow, printed);
    }

    try printed;
    model.list.appendSliceAssumeCapacity(expected);
}

fn model_push_slice(model: *Model, items: []const u8) !void {
    assert(model.array.count == model.list.items.len);
    assert(items.len <= model_capacity + 4);

    const pushed = model.array.push_slice(items);

    if (model.list.items.len + items.len > model_capacity) {
        return testing.expectError(error.Overflow, pushed);
    }

    try pushed;
    model.list.appendSliceAssumeCapacity(items);
}

fn model_push_slot(model: *Model) !void {
    assert(model.array.count == model.list.items.len);
    assert(model.list.capacity >= model_capacity);

    const byte = model.prng.random().int(u8);
    const slot = model.array.push_slot();
    if (model.list.items.len == model_capacity) return testing.expectError(error.Overflow, slot);

    (try slot).* = byte;
    model.list.appendAssumeCapacity(byte);
}

fn model_resize(model: *Model, items: []const u8) void {
    assert(model.array.count == model.list.items.len);
    assert(items.len <= model_capacity + 4);

    const unused = model.array.slice_unused();
    if (items.len > unused.len) return;

    @memcpy(unused[0..items.len], items);
    model.array.resize_assume_capacity(model.array.count + @as(u32, @intCast(items.len)));
    model.list.appendSliceAssumeCapacity(items);
}

fn model_set(model: *Model, items: []const u8) !void {
    assert(model.array.count == model.list.items.len);
    assert(items.len <= model_capacity + 4);

    const replaced = model.array.set(items);
    if (items.len > model_capacity) return testing.expectError(error.Overflow, replaced);

    try replaced;
    model.list.clearRetainingCapacity();
    model.list.appendSliceAssumeCapacity(items);
}
