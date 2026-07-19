# graphql-zig

[![builds.sr.ht status](https://builds.sr.ht/~xqtc/graphql-zig/commits/trunk.svg)](https://builds.sr.ht/~xqtc/graphql-zig/commits/trunk?)

A simple GraphQL client library. Can fetch endpoints and parse the response.

I'll eventually try to expand this project to handle more GraphQL features, but for now this is all I need.

## Example

``` zig
const std = @import("std");
const graphql = @import("graphql");

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    var client = try graphql.Client.init(
        allocator,
        io,
        "https://api.example.com/graphql",
        &.{
            .{ .name = "Authorization", .value = "Bearer sometoken" },
        },
    );
    defer client.deinit();

    var response = try client.execute(
        \\query($login: String!) {
        \\  user(login: $login) { name }
        \\}
    ,
        .{ .login = "transrights" },
    );
    defer response.deinit();

    if (response.errors.len > 0) {
        for (response.errors) |err| {
            std.log.err("gql err: {s}", .{err.message});
        }
        return error.GraphQLRequestFailed;
    }

    const data = response.data orelse return error.NoData;

    var stdout_buf: [1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buf);
    const stdout = &stdout_writer.interface;

    try stdout.print("{f}\n", .{std.json.fmt(data, .{})});
    try stdout.flush();
}
```

## License

[MIT](LICENSE)
