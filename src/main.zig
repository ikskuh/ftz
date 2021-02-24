const std = @import("std");
const network = @import("network");
const uri_parser = @import("uri");
const args_parser = @import("args");

pub fn main() !u8 {
    try network.init();
    defer network.deinit();

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const allocator = &gpa.allocator;

    var args = std.process.args();

    const executable_name = try (args.next(allocator) orelse {
        try std.io.getStdErr().writer().writeAll("Failed to get executable name from the argument list!\n");
        return error.NoExecutableName;
    });
    defer allocator.free(executable_name);

    const verb = try (args.next(allocator) orelse {
        var writer = std.io.getStdErr().writer();
        try writer.writeAll("Missing verb. Try 'ftz help' to see all possible verbs!\n");
        try printUsage(writer);
        return 1;
    });
    errdefer allocator.free(verb);

    if (std.mem.eql(u8, verb, "help")) {
        try printUsage(std.io.getStdOut().writer());
        return 0;
    } else if (std.mem.eql(u8, verb, "host")) {
        return try doHost(allocator, args_parser.parse(HostArgs, &args, allocator) catch |err| return 1);
    } else if (std.mem.eql(u8, verb, "get")) {
        return try doGet(allocator, args_parser.parse(GetArgs, &args, allocator) catch |err| return 1);
    } else if (std.mem.eql(u8, verb, "put")) {
        return try doPut(allocator, args_parser.parse(PutArgs, &args, allocator) catch |err| return 1);
    } else {
        var writer = std.io.getStdErr().writer();
        try writer.print("Unknown verb '{s}'\n", .{verb});
        try printUsage(writer);
        return 1;
    }
}

const HostArgs = struct {
    @"get-dir": ?[]const u8 = null,
    @"put-dir": ?[]const u8 = null,
    @"port": u16 = 17457,
};

const HostState = struct {
    put_dir: ?std.fs.Dir,
    get_dir: ?std.fs.Dir,
};

fn doHost(allocator: *std.mem.Allocator, args: args_parser.ParseArgsResult(HostArgs)) !u8 {
    defer args.deinit();

    var state = HostState{
        .put_dir = null,
        .get_dir = null,
    };

    if (args.positionals.len > 1) {
        var writer = std.io.getStdErr().writer();
        try writer.print("More than one directory is not allowed!\n", .{});
        return 1;
    }

    if ((args.positionals.len == 0) and (args.options.@"get-dir" == null) and (args.options.@"put-dir" == null)) {
        var writer = std.io.getStdErr().writer();
        try writer.print("Expected either one directory name or at least --get-dir or --put-dir set!\n", .{});
        return 1;
    }

    const common_dir: ?[]const u8 = if (args.positionals.len == 1) args.positionals[0] else null;

    if (args.options.@"get-dir" orelse common_dir) |path| {
        state.get_dir = try std.fs.cwd().openDir(path, .{ .access_sub_paths = true, .iterate = true, .no_follow = true });
    }
    defer if (state.get_dir) |*dir| dir.close();

    if (args.options.@"put-dir" orelse common_dir) |path| {
        state.put_dir = try std.fs.cwd().openDir(path, .{ .access_sub_paths = true, .iterate = true, .no_follow = true });
    }
    defer if (state.put_dir) |*dir| dir.close();

    var sock = try network.Socket.create(.ipv4, .tcp);
    defer sock.close();

    try sock.enablePortReuse(true);

    try sock.bind(network.EndPoint{
        .address = .{ .ipv4 = network.Address.IPv4.any },
        .port = args.options.port,
    });

    try sock.listen();

    while (true) {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();

        var client = try sock.accept();
        defer client.close();

        std.log.info("accepted connection from {}", .{try client.getRemoteEndPoint()});

        handleClientConnection(state, &arena.allocator, client) catch |err| {
            std.log.err("handling client connection failed: {s}", .{@errorName(err)});
        };
    }

    return 0;
}

fn handleClientConnection(host: HostState, allocator: *std.mem.Allocator, client: network.Socket) !void {
    var buffer: [1024]u8 = undefined;

    var reader = client.reader();
    var writer = client.writer();

    const query = blk: {
        const query_raw = (try reader.readUntilDelimiterOrEof(&buffer, '\n')) orelse return error.ProtocolViolation;
        if (query_raw.len < 4 or query_raw[query_raw.len - 1] != '\r')
            return error.ProtocolViolation;

        break :blk try allocator.dupe(u8, query_raw[0 .. query_raw.len - 1]);
    };
    defer allocator.free(query);

    if (std.mem.startsWith(u8, query, "GET ")) {
        if (host.get_dir) |dir| {
            const path = try resolvePath(&buffer, query[4..]);
            std.debug.assert(path[0] == '/');
            std.log.info("GET {s}", .{path});

            var file = try dir.openFile(path[1..], .{ .read = true, .write = false });
            defer file.close();

            while (true) {
                const len = try file.read(&buffer);
                if (len == 0)
                    break;

                try writer.writeAll(buffer[0..len]);
            }
        } else {
            return error.GetNotAllowed;
        }
    } else if (std.mem.startsWith(u8, query, "PUT ")) {
        if (host.put_dir) |dir| {
            const path = try resolvePath(&buffer, query[4..]);
            std.debug.assert(path[0] == '/');
            std.log.info("PUT {s}", .{path});

            var file = try dir.createFile(path[1..], .{});
            defer file.close();

            while (true) {
                const len = try reader.read(&buffer);
                if (len == 0)
                    break;

                try file.writer().writeAll(buffer[0..len]);
            }
        } else {
            return error.PutNotAllowed;
        }
    } else {
        return error.ProtocolViolation;
    }
}

const GetArgs = struct {};
fn doGet(allocator: *std.mem.Allocator, args: args_parser.ParseArgsResult(GetArgs)) !u8 {
    defer args.deinit();

    return 0;
}

const PutArgs = struct {};
fn doPut(allocator: *std.mem.Allocator, args: args_parser.ParseArgsResult(PutArgs)) !u8 {
    defer args.deinit();

    return 0;
}

fn printUsage(writer: anytype) !void {
    try writer.writeAll(
        \\ftz [verb]
        \\  Quickly transfer files between two systems connected via network.
        \\
        \\ftz help
        \\   Prints this help
        \\
        \\ftz host [path] [--get-dir path] [--put-dir path] [--port num] 
        \\   Hosts the given directories for either upload or download.
        \\   path            If given, sets both --get-dir and --put-dir to the same directory.
        \\   --get-dir path  Sets the directory for transfers to a client. No access outside this directory is allowed.
        \\   --put-dir path  Sets the directory for transfers from a client. No access outside this directory is allowed.
        \\   --port    num   Sets the port where ftz will serve the data. Default is 17457
        \\
        \\ftz get [uri]
        \\   Fetches a file from [uri]
        \\
        \\ftz put [file] [uri]
        \\   Uploads [file] (a local path) to [uri] (a ftz uri)
        \\
    );
}

fn resolvePath(buffer: []u8, src_path: []const u8) error{BufferTooSmall}![]u8 {
    if (buffer.len == 0)
        return error.BufferTooSmall;
    if (src_path.len == 0) {
        buffer[0] = '/';
        return buffer[0..1];
    }

    var end: usize = 0;
    buffer[0] = '/';

    var iter = std.mem.tokenize(src_path, "/");
    while (iter.next()) |segment| {
        if (std.mem.eql(u8, segment, ".")) {
            continue;
        } else if (std.mem.eql(u8, segment, "..")) {
            while (true) {
                if (end == 0)
                    break;
                if (buffer[end] == '/') {
                    break;
                }
                end -= 1;
            }
            // std.debug.print("remove: '{s}' {}\n", .{ buffer[0..end], end });
        } else {
            if (end + segment.len + 1 > buffer.len)
                return error.BufferTooSmall;

            const start = end;
            buffer[end] = '/';
            end += segment.len + 1;
            std.mem.copy(u8, buffer[start + 1 .. end], segment);
            // std.debug.print("append: '{s}' {}\n", .{ buffer[0..end], end });
        }
    }

    return if (end == 0)
        buffer[0 .. end + 1]
    else
        buffer[0..end];
}

fn testResolve(expected: []const u8, input: []const u8) !void {
    var buffer: [1024]u8 = undefined;

    const actual = try resolvePath(&buffer, input);
    std.testing.expectEqualStrings(expected, actual);
}

test "resolvePath" {
    try testResolve("/", "");
    try testResolve("/", "/");
    try testResolve("/", "////////////");

    try testResolve("/a", "a");
    try testResolve("/a", "/a");
    try testResolve("/a", "////////////a");
    try testResolve("/a", "////////////a///");

    try testResolve("/a/b/c/d", "/a/b/c/d");

    try testResolve("/a/b/d", "/a/b/c/../d");

    try testResolve("/", "..");
    try testResolve("/", "/..");
    try testResolve("/", "/../../../..");
    try testResolve("/a/b/c", "a/b/c/");
}
