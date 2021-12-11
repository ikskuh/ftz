const std = @import("std");
const builtin = @import("builtin");
const network = @import("network");
const uri_parser = @import("uri");
const args_parser = @import("args");

const default_port = 17457;
const buffer_size = 2 * 1024 * 1024;
const ftz_version = "1.1.0";

const HashAlgorithm = std.crypto.hash.Md5;

const CliOptions = struct {
    help: bool = false,
};

const CliVerb = union(enum) {
    host: HostArgs,
    get: GetArgs,
    put: PutArgs,
    version: struct {},
    help: struct {},

    const HostArgs = struct {
        @"get-dir": ?[]const u8 = null,
        @"put-dir": ?[]const u8 = null,
        @"port": u16 = default_port,
    };

    const GetArgs = struct {
        @"output": ?[]const u8 = null,

        pub const shorthands = .{
            .o = "output",
        };
    };
    const PutArgs = struct {
        progress: bool = false,
    };
};

pub fn main() !u8 {
    try network.init();
    defer network.deinit();

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const allocator = gpa.allocator();

    var cli = args_parser.parseWithVerbForCurrentProcess(CliOptions, CliVerb, allocator, .print) catch return 1;
    defer cli.deinit();

    if (cli.options.help) {
        try printUsage(std.io.getStdOut().writer());
        return 0;
    }
    if (cli.verb == null) {
        var writer = std.io.getStdErr().writer();
        try writer.print("Unknown verb\n", .{});
        try printUsage(writer);
        return 1;
    }

    return switch (cli.verb.?) {
        .help => {
            try printUsage(std.io.getStdOut().writer());
            return 0;
        },
        .host => |options| try doHost(allocator, cli.positionals, options),
        .get => |options| try doGet(allocator, cli.positionals, options),
        .put => |options| try doPut(allocator, cli.positionals, options),
        .version => {
            var writer = std.io.getStdOut().writer();
            try writer.writeAll(ftz_version ++ "\n");
            return 0;
        },
    };
}

const HostState = struct {
    put_dir: ?std.fs.Dir,
    get_dir: ?std.fs.Dir,
};

fn doHost(allocator: std.mem.Allocator, positionals: []const []const u8, options: CliVerb.HostArgs) !u8 {
    var state = HostState{
        .put_dir = null,
        .get_dir = null,
    };

    if (positionals.len > 1) {
        var writer = std.io.getStdErr().writer();
        try writer.print("More than one directory is not allowed!\n", .{});
        return 1;
    }

    if ((positionals.len == 0) and (options.@"get-dir" == null) and (options.@"put-dir" == null)) {
        var writer = std.io.getStdErr().writer();
        try writer.print("Expected either one directory name or at least --get-dir or --put-dir set!\n", .{});
        return 1;
    }

    const common_dir: ?[]const u8 = if (positionals.len == 1) positionals[0] else null;

    if (options.@"get-dir" orelse common_dir) |path| {
        state.get_dir = try std.fs.cwd().openDir(path, .{ .access_sub_paths = true, .iterate = false, .no_follow = true });
    }
    defer if (state.get_dir) |*dir| dir.close();

    if (options.@"put-dir" orelse common_dir) |path| {
        state.put_dir = try std.fs.cwd().openDir(path, .{ .access_sub_paths = true, .iterate = false, .no_follow = true });
    }
    defer if (state.put_dir) |*dir| dir.close();

    var sock = try network.Socket.create(.ipv4, .tcp);
    defer sock.close();

    try sock.enablePortReuse(true);

    try sock.bind(network.EndPoint{
        .address = .{ .ipv4 = network.Address.IPv4.any },
        .port = options.port,
    });

    try sock.listen();

    while (true) {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();

        var client = try sock.accept();
        defer client.close();

        // std.log.info("accepted connection from {}", .{try client.getRemoteEndPoint()});

        handleClientConnection(state, arena.allocator(), client) catch |err| {
            if (builtin.mode == .Debug)
                return err;
            std.log.err("handling client connection failed: {s}", .{@errorName(err)});
        };
    }

    return 0;
}

fn handleClientConnection(host: HostState, allocator: std.mem.Allocator, client: network.Socket) !void {
    var buffer: [1024]u8 = undefined;

    var reader = client.reader();
    // var writer = client.writer();

    const query = blk: {
        const query_raw = (try reader.readUntilDelimiterOrEof(&buffer, '\n')) orelse return error.ProtocolViolation;
        if (query_raw.len < 4 or query_raw[query_raw.len - 1] != '\r')
            return error.ProtocolViolation;

        break :blk try allocator.dupe(u8, query_raw[0 .. query_raw.len - 1]);
    };
    defer allocator.free(query);

    const remote_endpoint = try client.getRemoteEndPoint();

    if (std.mem.startsWith(u8, query, "GET ")) {
        if (host.get_dir) |dir| {
            const path = try resolvePath(&buffer, query[4..]);
            std.debug.assert(path[0] == '/');
            std.log.info("{}: GET {s}", .{ remote_endpoint, path });

            var file = try dir.openFile(path[1..], .{ .read = true, .write = false });
            defer file.close();

            try transferFile(file, client, false);
        } else {
            return error.GetNotAllowed;
        }
    } else if (std.mem.startsWith(u8, query, "PUT ")) {
        if (host.put_dir) |dir| {
            const path = try allocator.dupe(u8, try resolvePath(&buffer, query[4..]));
            defer allocator.free(path);

            std.debug.assert(path[0] == '/');

            std.log.info("{}: PUT {s}", .{ remote_endpoint, path });

            try receiveFile(dir, path[1..], client);
        } else {
            return error.PutNotAllowed;
        }
    } else {
        return error.ProtocolViolation;
    }
}

/// Parses and validates a FTZ uri.
const UriInformation = struct {
    const Self = @This();

    host: []const u8,
    port: u16,
    path: []const u8,

    fn parse(allocator: std.mem.Allocator, string: []const u8) !Self {
        const stderr = std.io.getStdErr().writer();

        var uri = uri_parser.parse(string) catch |err| {
            try stderr.print("Failed to parse URI: {s}\n", .{@errorName(err)});
            return error.InvalidUri;
        };

        if (uri.scheme != null and !std.mem.eql(u8, uri.scheme.?, "ftz")) {
            try stderr.print("URI scheme must be 'ftz://'!\n", .{});
            return error.InvalidUri;
        }

        if (uri.user != null or uri.password != null or uri.query != null or uri.fragment != null) {
            try stderr.print("URI contains invalid elements. Found either a user, password, query or fragment!\n", .{});
            return error.InvalidUri;
        }

        if (uri.host == null) {
            try stderr.print("URI requires host name!\n", .{});
            return error.InvalidUri;
        }
        if (uri.path == null) {
            try stderr.print("URI requires host name!\n", .{});
            return error.InvalidUri;
        }

        return Self{
            .host = uri.host.?,
            .port = uri.port orelse default_port,
            .path = try uri_parser.unescapeString(allocator, uri.path.?),
        };
    }

    fn deinit(self: *Self, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        self.* = undefined;
    }
};

fn doGet(allocator: std.mem.Allocator, positionals: []const []const u8, options: CliVerb.GetArgs) !u8 {
    var stderr = std.io.getStdErr().writer();

    if (positionals.len != 1) {
        try stderr.print("Expected both source file and target URI!\n", .{});
        return 1;
    }

    var server_data = UriInformation.parse(allocator, positionals[0]) catch return 1;
    defer server_data.deinit(allocator);

    const target_file = options.output orelse std.fs.path.basename(server_data.path);

    var socket = network.connectToHost(allocator, server_data.host, server_data.port, .tcp) catch |err| switch (err) {
        error.CouldNotConnect => {
            try stderr.writeAll("Failed to connect to host!\n");
            return 1;
        },
        else => |e| return e,
    };
    defer socket.close();
    var writer = socket.writer();

    try writer.print("GET {s}\r\n", .{server_data.path});

    try receiveFile(std.fs.cwd(), target_file, socket);

    return 0;
}

fn doPut(allocator: std.mem.Allocator, positionals: []const []const u8, options: CliVerb.PutArgs) !u8 {
    _ = options;
    var stderr = std.io.getStdErr().writer();

    if (positionals.len != 2) {
        try stderr.print("Expected both source file and target URI!\n", .{});
        return 1;
    }

    var server_data = UriInformation.parse(allocator, positionals[1]) catch return 1;
    defer server_data.deinit(allocator);

    var source_file = std.fs.cwd().openFile(positionals[0], .{ .read = true, .write = false }) catch |err| switch (err) {
        error.FileNotFound => {
            try stderr.writeAll("File not found!\n");
            return 1;
        },
        else => |e| return e,
    };
    defer source_file.close();

    var socket = network.connectToHost(allocator, server_data.host, server_data.port, .tcp) catch |err| switch (err) {
        error.CouldNotConnect => {
            try stderr.writeAll("Failed to connect to host!\n");
            return 1;
        },
        else => |e| return e,
    };
    defer socket.close();
    var writer = socket.writer();

    try writer.print("PUT {s}\r\n", .{server_data.path});

    try transferFile(source_file, socket, options.progress);

    return 0;
}

/// Transfers the given `file` to the `socket`. Will compute the hash for the file and prepend it to the stream.
fn transferFile(file: std.fs.File, socket: network.Socket, show_progress: bool) !void {
    var buffer: [buffer_size]u8 = undefined;

    var progress = std.Progress{};

    const stat = try file.stat();

    const hash = blk: {
        var hash_node = if (show_progress)
            try progress.start("Hashing", stat.size)
        else
            undefined;
        defer if (show_progress) {
            hash_node.end();
        };

        var hasher = HashAlgorithm.init(.{});
        var length: usize = 0;
        while (true) {
            const len = try file.read(&buffer);
            if (len == 0)
                break;
            length += len;

            if (show_progress) {
                hash_node.setCompletedItems(length);
                progress.maybeRefresh();
            }

            hasher.update(buffer[0..len]);
        }

        var hash: [HashAlgorithm.digest_length]u8 = undefined;
        hasher.final(&hash);
        break :blk hash;
    };

    {
        var transfer_node = if (show_progress)
            try progress.start("Uploading", stat.size)
        else
            undefined;
        defer if (show_progress) {
            transfer_node.end();
        };

        try file.seekTo(0);

        var writer = socket.writer();

        try writer.print("{}\r\n", .{std.fmt.fmtSliceHexLower(&hash)});

        var total_transferred: usize = 0;
        while (true) {
            const len = try file.read(&buffer);
            if (len == 0)
                break;
            try writer.writeAll(buffer[0..len]);
            total_transferred += len;
            if (show_progress) {
                transfer_node.setCompletedItems(total_transferred);
                progress.maybeRefresh();
            }
        }
    }
}

/// Receives a file from `socket` and will store it in `path` relative to `dir`.
/// Will unlink the file when receiption failed.
fn receiveFile(dir: std.fs.Dir, path: []const u8, socket: network.Socket) !void {
    var reader = socket.reader();

    var ascii_hash: [2 * HashAlgorithm.digest_length + 2]u8 = undefined;
    reader.readNoEof(&ascii_hash) catch |err| switch (err) {
        error.EndOfStream => return error.ProtocolViolation,
        else => |e| return e,
    };

    if (!std.mem.eql(u8, ascii_hash[2 * HashAlgorithm.digest_length ..], "\r\n")) {
        return error.ProtocolViolation;
    }

    const expected_hash = blk: {
        var hash_buf: [HashAlgorithm.digest_length]u8 = undefined;
        const slice = std.fmt.hexToBytes(&hash_buf, ascii_hash[0 .. 2 * HashAlgorithm.digest_length]) catch {
            return error.ProtocolViolation;
        };
        break :blk slice[0..HashAlgorithm.digest_length].*;
    };

    if (std.fs.path.dirname(path)) |parent| {
        try dir.makePath(parent);
    }

    const actual_hash = blk: {
        var file = try dir.createFile(path, .{});
        defer file.close();

        var hasher = HashAlgorithm.init(.{});

        var buffer: [buffer_size]u8 = undefined;
        while (true) {
            const len = try reader.read(&buffer);
            if (len == 0)
                break;

            hasher.update(buffer[0..len]);
            try file.writer().writeAll(buffer[0..len]);
        }

        var hash: [HashAlgorithm.digest_length]u8 = undefined;
        hasher.final(&hash);
        break :blk hash;
    };

    if (!std.mem.eql(u8, &actual_hash, &expected_hash)) {
        std.log.err("Failed to receive file: Hash mismatch! Expected {}, got {}", .{ std.fmt.fmtSliceHexLower(&expected_hash), std.fmt.fmtSliceHexLower(&actual_hash) });

        dir.deleteFile(path) catch {
            std.log.err("Failed to unlink invalid file: {s}", .{path});
        };
    }
}

fn printUsage(writer: anytype) !void {
    try writer.writeAll(
        \\ftz [verb]
        \\  Quickly transfer files between two systems connected via network.
        \\Verbs:
        \\  ftz help
        \\    Prints this help
        \\
        \\  ftz host [path] [--get-dir path] [--put-dir path] [--port num] 
        \\    Hosts the given directories for either upload or download.
        \\    path            If given, sets both --get-dir and --put-dir to the same directory.
        \\    --get-dir path  Sets the directory for transfers to a client. No access outside this directory is allowed.
        \\    --put-dir path  Sets the directory for transfers from a client. No access outside this directory is allowed.
        \\    --port    num   Sets the port where ftz will serve the data. Default is 17457
        \\
        \\  ftz get [--output file] [uri]
        \\    Fetches a file from [uri] into the current directory. The file name will be the file name in the URI.
        \\    uri             The uri to the file that should be downloaded.
        \\    --output file   Saves the resulting file into [file] instead of the basename of the URI.
        \\
        \\  ftz put [--progress] [file] [uri]
        \\    Uploads [file] (a local path) to [uri] (a ftz uri)
        \\    --progress      Show how much data is already transferred and provide a live update.
        \\
        \\  ftz version
        \\    Prints the ftz version.
        \\
        \\Examples:
        \\  ftz host .
        \\    Open the current directory for both upload and download.
        \\  ftz put debug.log ftz://device.local/debug.log
        \\    Uploads debug.log to the server.
        \\  ftz get ftz://device.local/debug.log
        \\    Downloads debug.log from the server.
        \\
    );
}

/// Resolves a unix-like path and removes all "." and ".." from it. Will not escape the root and can be used to sanitize inputs.
fn resolvePath(buffer: []u8, src_path: []const u8) error{BufferTooSmall}![]u8 {
    if (buffer.len == 0)
        return error.BufferTooSmall;
    if (src_path.len == 0) {
        buffer[0] = '/';
        return buffer[0..1];
    }

    var end: usize = 0;
    buffer[0] = '/';

    var iter = std.mem.tokenize(u8, src_path, "/");
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
    try std.testing.expectEqualStrings(expected, actual);
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

    try testResolve("/new/date.txt", "/new/../../new/date.txt");
}

test "resolvePath overflow" {
    var buf: [1]u8 = undefined;

    try std.testing.expectEqualStrings("/", try resolvePath(&buf, "/"));
    try std.testing.expectError(error.BufferTooSmall, resolvePath(&buf, "a")); // will resolve to "/a"
}
