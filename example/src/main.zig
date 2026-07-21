const std = @import("std");
const graphql = @import("graphql");

const Title = struct {
    english: ?[]const u8 = null,
    native: ?[]const u8 = null,
};

const Media = struct {
    siteUrl: []const u8,
    title: Title,
    description: ?[]const u8 = null,
};

const Page = struct {
    media: []const Media,
};

const PageData = struct {
    Page: Page,
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    var client = try graphql.Client.init(
        allocator,
        io,
        "https://graphql.anilist.co",
        &.{},
    );
    defer client.deinit();

    var response = try client.executeTyped(
        PageData,
        \\query($search: String) {
        \\  Page {
        \\    media(search: $search, type: ANIME) {
        \\      siteUrl
        \\      title {
        \\        english
        \\        native
        \\      }
        \\      description
        \\    }
        \\  }
        \\}
    ,
        .{ .search = "Frieren" },
    );
    defer response.deinit();

    if (response.errors.len > 0) {
        for (response.errors) |err| {
            std.log.err("gql err: {s}", .{err.msg});
        }
        return error.GraphQLRequestFailed;
    }

    const page = response.data orelse return error.NoData;

    var stdout_buf: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buf);
    const stdout = &stdout_writer.interface;

    for (page.Page.media) |media| {
        try stdout.print("{s}\n", .{media.siteUrl});
        if (media.title.english) |en| try stdout.print("  en: {s}\n", .{en});
        if (media.title.native) |na| try stdout.print("  native: {s}\n", .{na});
    }
    try stdout.flush();
}
