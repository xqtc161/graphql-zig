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

        var arena: std.heap.ArenaAllocator = .init(self.allocator);
        errdefer arena.deinit();

        const parsed = try std.json.parseFromSliceLeaky(
            std.json.Value,
            arena.allocator(),
            body,
            .{},
        );
        const obj = switch (parsed) {
            .object => |o| o,
            else => return error.UnexpectedResponseShape,
        };
        const data: ?std.json.Value = obj.get("data");

        const errors: []const GraphQLError = if (obj.get("errors")) |errs_val| blk: {
            // check if error val is an array
            const errs_arr = switch (errs_val) {
                .array => |a| a,
                else => return error.UnexpectedResponseShape,
            };

            var list: std.ArrayList(GraphQLError) = .empty;
            // check if each element in err array is a json object with a 'message' field
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

    fn rawFetch(self: *Client, query: []const u8, variables: anytype) ![]u8 {
        var body_writer: std.Io.Writer.Allocating = .init(self.allocator);
        defer body_writer.deinit();

        try std.json.Stringify.value(.{
            .query = query,
            .variables = variables,
        }, .{}, &body_writer.writer);

        var response_writer: std.Io.Writer.Allocating = .init(self.allocator);
        errdefer response_writer.deinit();

        const result = try self.http_client.fetch(.{
            .method = .POST,
            .location = .{ .uri = self.endpoint },
            .headers = .{ .content_type = .{ .override = "application/json" } },
            .extra_headers = self.headers,
            .payload = body_writer.written(),
            .response_writer = &response_writer.writer,
        });

        if (result.status != .ok) return error.UnexpectedStatus;

        return response_writer.toOwnedSlice(self.allocator);
    }

    pub fn executeTyped(comptime T: type, query: []const u8, variables: anytype) !TypedResponse(T) {
        _ = query; // autofix
        _ = variables; // autofix
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

pub const GraphQLError = struct {
    msg: []const u8,
    path: ?[]const std.json.Value = null,
};
