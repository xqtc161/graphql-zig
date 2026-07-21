const std = @import("std");

pub const Client = struct {
    allocator: std.mem.Allocator,
    http_client: std.http.Client,
    endpoint: []const u8,
    headers: []const std.http.Header,

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        endpoint: []const u8,
        headers: []const std.http.Header,
    ) !Client {
        return .{
            .allocator = allocator,
            .http_client = .{
                .allocator = allocator,
                .io = io,
            },
            .endpoint = endpoint,
            .headers = headers,
        };
    }

    pub fn deinit(self: *Client) void {
        self.http_client.deinit();
    }

    pub fn execute(self: *Client, query: []const u8, variables: anytype) !Response {
        const body = try self.rawFetch(query, variables);
        defer self.allocator.free(body);
        return parseResponse(self.allocator, body);
    }

    fn rawFetch(self: *Client, query: []const u8, variables: anytype) ![]u8 {
        var body_writer: std.Io.Writer.Allocating = .init(self.allocator);
        defer body_writer.deinit();

        try std.json.Stringify.value(.{ .query = query, .variables = variables }, .{}, &body_writer.writer);

        var response_writer: std.Io.Writer.Allocating = .init(self.allocator);
        errdefer response_writer.deinit();

        const result = try self.http_client.fetch(.{
            .method = .POST,
            .location = .{ .uri = try std.Uri.parse(self.endpoint) },
            .headers = .{
                .content_type = .{ .override = "application/json" },
            },
            .extra_headers = self.headers,
            .payload = body_writer.written(),
            .response_writer = &response_writer.writer,
        });

        if (result.status != .ok) {
            return error.UnexpectedStatus;
        }

        return response_writer.toOwnedSlice();
    }

    pub fn executeTyped(self: *Client, comptime T: type, query: []const u8, variables: anytype) !TypedResponse(T) {
        const body = try self.rawFetch(query, variables);
        defer self.allocator.free(body);
        return parseTypedResponse(T, self.allocator, body);
    }
};

pub const Response = struct {
    arena: std.heap.ArenaAllocator,
    data: ?std.json.Value,
    errors: []const GraphQLError,

    pub fn deinit(self: *Response) void {
        self.arena.deinit();
    }
};

pub fn TypedResponse(comptime T: type) type {
    return struct {
        arena: std.heap.ArenaAllocator,
        data: ?T,
        errors: []const GraphQLError,

        pub fn deinit(self: *@This()) void {
            self.arena.deinit();
        }
    };
}

pub const GraphQLError = struct {
    msg: []const u8,
    path: ?[]const std.json.Value = null,
};

fn parseResponse(allocator: std.mem.Allocator, body: []const u8) !Response {
    var arena: std.heap.ArenaAllocator = .init(allocator);
    errdefer arena.deinit();

    const parsed = try std.json.parseFromSliceLeaky(
        std.json.Value,
        arena.allocator(),
        body,
        .{ .allocate = .alloc_always },
    );
    const obj = switch (parsed) {
        .object => |o| o,
        else => return error.UnexpectedResponseShape,
    };
    const data: ?std.json.Value = obj.get("data");

    const errors: []const GraphQLError = if (obj.get("errors")) |errs_val| blk: {
        const errs_arr = switch (errs_val) {
            .array => |a| a,
            else => return error.UnexpectedResponseShape,
        };

        var list: std.ArrayList(GraphQLError) = .empty;
        for (errs_arr.items) |err_val| {
            const err_obj = switch (err_val) {
                .object => |o| o,
                else => continue,
            };
            const msg = switch (err_obj.get("message") orelse continue) {
                .string => |s| s,
                else => continue,
            };
            try list.append(arena.allocator(), .{ .msg = msg });
        }

        break :blk try list.toOwnedSlice(arena.allocator());
    } else &.{};

    return .{
        .arena = arena,
        .data = data,
        .errors = errors,
    };
}

fn parseTypedResponse(comptime T: type, allocator: std.mem.Allocator, body: []const u8) !TypedResponse(T) {
    var arena: std.heap.ArenaAllocator = .init(allocator);
    errdefer arena.deinit();

    const Envelope = struct {
        data: ?T = null,
        errors: []const GraphQLError = &.{},
    };

    const parsed = try std.json.parseFromSliceLeaky(
        Envelope,
        arena.allocator(),
        body,
        .{ .ignore_unknown_fields = true, .allocate = .alloc_always },
    );

    return .{
        .arena = arena,
        .data = parsed.data,
        .errors = parsed.errors,
    };
}

test "parseResponse extracts data" {
    const body =
        \\{"data":{"foo":"bar"}}
    ;
    var response = try parseResponse(std.testing.allocator, body);
    defer response.deinit();

    try std.testing.expect(response.errors.len == 0);
    const data = response.data.?;
    try std.testing.expectEqualStrings("bar", data.object.get("foo").?.string);
}

test "parseResponse extracts errors" {
    const body =
        \\{"data":null,"errors":[{"message":"field not found"}]}
    ;
    var response = try parseResponse(std.testing.allocator, body);
    defer response.deinit();

    try std.testing.expectEqual(1, response.errors.len);
    try std.testing.expectEqualStrings("field not found", response.errors[0].msg);
}

test "parseResponse skips malformed error entries" {
    const body =
        \\{"errors":[{"message":"good"},"not an object",{"nope":"missing message"}]}
    ;
    var response = try parseResponse(std.testing.allocator, body);
    defer response.deinit();

    try std.testing.expectEqual(1, response.errors.len);
    try std.testing.expectEqualStrings("good", response.errors[0].msg);
}

test "parseResponse rejects non-object root" {
    const body =
        \\[1, 2, 3]
    ;
    try std.testing.expectError(
        error.UnexpectedResponseShape,
        parseResponse(std.testing.allocator, body),
    );
}

test "parseTypedResponse decodes into a struct" {
    const Data = struct {
        user: struct {
            name: []const u8,
        },
    };

    const body =
        \\{"data":{"user":{"name":"test"}}}
    ;
    var response = try parseTypedResponse(Data, std.testing.allocator, body);
    defer response.deinit();

    try std.testing.expectEqual(0, response.errors.len);
    try std.testing.expectEqualStrings("test", response.data.?.user.name);
}

test "parseTypedResponse ignores unknown fields like extensions" {
    const Data = struct { ok: bool };
    const body =
        \\{"data":{"ok":true},"extensions":{"tracing":{}}}
    ;
    var response = try parseTypedResponse(Data, std.testing.allocator, body);
    defer response.deinit();

    try std.testing.expect(response.data.?.ok);
}

test "request body serialization matches expected shape" {
    var body_writer: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer body_writer.deinit();

    try std.json.Stringify.value(
        .{ .query = "{ viewer { login } }", .variables = .{ .login = "test" } },
        .{},
        &body_writer.writer,
    );

    const expected =
        \\{"query":"{ viewer { login } }","variables":{"login":"test"}}
    ;
    try std.testing.expectEqualStrings(expected, body_writer.written());
}
