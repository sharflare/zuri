const std = @import("std");
const progress = @import("progress.zig");
const shutdown = @import("shutdown.zig");

pub const PackageDownload = struct {
    name: []const u8,
    version: []const u8,
    host: []const u8,
    port: u16,
    path: []const u8,
    size: u64,
    dest_path: []const u8,
    sha256: []const u8,
};

pub const DownloadConfig = struct {
    max_concurrent: u8 = 8,
    retry_count: u3 = 3,
    initial_retry_delay_ms: u64 = 1000,
};

pub fn fetchAll(
    allocator: std.mem.Allocator,
    downloads: []const PackageDownload,
    config: DownloadConfig,
    mp: *progress.MultiProgress,
    environ_map: *const std.process.Environ.Map,
) !void {
    var threaded = std.Io.Threaded.init(allocator, .{
        .concurrent_limit = .limited(config.max_concurrent),
    });
    defer threaded.deinit();

    const io = threaded.io();

    var group: std.Io.Group = .init;
    defer group.cancel(io);

    var semaphore = std.Io.Semaphore{ .permits = config.max_concurrent };
    var cancelled = std.atomic.Value(bool).init(false);

    for (downloads, 0..) |dl, i| {
        group.async(io, fetchPackage, .{ dl, @as(usize, i), config, mp, &semaphore, &cancelled, io, environ_map });
    }

    try group.await(io);

    if (mp.anyFailed()) return error.DownloadFailed;
}

fn fetchPackage(
    dl: PackageDownload,
    idx: usize,
    cfg: DownloadConfig,
    mp: *progress.MultiProgress,
    sem: *std.Io.Semaphore,
    cancelled: *std.atomic.Value(bool),
    io: std.Io,
    environ_map: *const std.process.Environ.Map,
) void {
    if (cancelled.load(.monotonic) or shutdown.isCancelled()) {
        mp.setFailed(idx);
        return;
    }

    sem.wait(io) catch return;
    defer sem.post(io);

    if (cancelled.load(.monotonic) or shutdown.isCancelled()) {
        mp.setFailed(idx);
        return;
    }

    mp.setTotal(idx, dl.size);

    if (destPathIsCached(dl, io)) {
        mp.setCurrent(idx, dl.size);
        mp.setDone(idx);
        return;
    }

    mp.setProgress(idx, 0);

    var retry_delay = cfg.initial_retry_delay_ms;
    var attempt: u3 = 0;

    while (attempt <= cfg.retry_count) : (attempt += 1) {
        if (cancelled.load(.monotonic) or shutdown.isCancelled()) {
            mp.setFailed(idx);
            return;
        }

        if (attempt > 0) {
            io.sleep(std.Io.Duration.fromMilliseconds(@as(i64, @intCast(retry_delay))), .awake) catch {};
            retry_delay *|= 2;
        }

        if (doBlockingDownload(dl, idx, mp, io, environ_map)) |_| {
            mp.setDone(idx);
            return;
        } else |err| {
            if (attempt < cfg.retry_count) {
                var ebuf: [4096]u8 = undefined;
                var w = std.Io.File.stderr().writer(io, &ebuf);
                w.interface.print("  {s}: {s}: {s} (retry {d}/{d})\n", .{
                    dl.host, dl.name, @errorName(err), attempt + 1, cfg.retry_count + 1,
                }) catch {};
                w.flush() catch {};
            }
        }
    }

    var ebuf: [4096]u8 = undefined;
    var w = std.Io.File.stderr().writer(io, &ebuf);
    w.interface.print("  ✗ {s}: failed after {d} attempts\n", .{
        dl.name, cfg.retry_count + 1,
    }) catch {};
    w.flush() catch {};

    cancelled.store(true, .monotonic);
    mp.setFailed(idx);
}

pub fn destPathIsCached(dl: PackageDownload, io: std.Io) bool {
    if (dl.sha256.len == 0) return false;
    const hex = computeSHA256(dl.dest_path, io) catch return false;
    defer std.heap.page_allocator.free(hex);
    const match = std.ascii.eqlIgnoreCase(hex, dl.sha256);
    if (!match) std.Io.Dir.deleteFileAbsolute(io, dl.dest_path) catch {};
    return match;
}

fn setupProxyFromEnv(client: *std.http.Client, environ_map: *const std.process.Environ.Map) void {
    const allocator = client.allocator;
    inline for (.{ "https_proxy", "HTTPS_PROXY", "all_proxy", "ALL_PROXY" }) |name| {
        if (environ_map.get(name)) |raw| {
            if (raw.len > 0) {
                if (createProxy(raw, allocator)) |proxy| {
                    client.https_proxy = proxy;
                }
                break;
            }
        }
    }

    inline for (.{ "http_proxy", "HTTP_PROXY", "all_proxy", "ALL_PROXY" }) |name| {
        if (environ_map.get(name)) |raw| {
            if (raw.len > 0) {
                if (createProxy(raw, allocator)) |proxy| {
                    client.http_proxy = proxy;
                }
                break;
            }
        }
    }
}

fn createProxy(url: []const u8, allocator: std.mem.Allocator) ?*std.http.Client.Proxy {
    const uri = std.Uri.parse(url) catch return null;
    var host_buf: [std.Io.net.HostName.max_len]u8 = undefined;
    const host_name = uri.getHost(&host_buf) catch return null;
    const host_owned = allocator.dupe(u8, host_name.bytes) catch return null;
    const protocol: std.http.Client.Protocol = if (std.mem.eql(u8, uri.scheme, "https")) .tls else .plain;

    const proxy = allocator.create(std.http.Client.Proxy) catch {
        allocator.free(host_owned);
        return null;
    };
    proxy.* = .{
        .protocol = protocol,
        .host = std.Io.net.HostName{ .bytes = host_owned },
        .authorization = null,
        .port = uri.port orelse 8080,
        .supports_connect = true,
    };
    return proxy;
}

fn doBlockingDownload(dl: PackageDownload, idx: usize, mp: *progress.MultiProgress, io: std.Io, environ_map: *const std.process.Environ.Map) !u64 {
    var client = std.http.Client{ .allocator = std.heap.page_allocator, .io = io };
    client.now = std.Io.Timestamp.now(io, .real);
    try client.ca_bundle.rescan(client.allocator, io, client.now.?);
    defer client.deinit();

    setupProxyFromEnv(&client, environ_map);

    var url_buf: [4096]u8 = undefined;
    const url = if (dl.port == 443)
        try std.fmt.bufPrint(&url_buf, "https://{s}{s}", .{ dl.host, dl.path })
    else
        try std.fmt.bufPrint(&url_buf, "http://{s}:{}{s}", .{ dl.host, dl.port, dl.path });

    const uri = try std.Uri.parse(url);

    const protocol: std.http.Client.Protocol = if (dl.port == 443) .tls else .plain;
    var host_name_buffer: [std.Io.net.HostName.max_len]u8 = undefined;
    const host = try uri.getHost(&host_name_buffer);

    const conn = try client.connectTcpOptions(.{
        .host = host,
        .port = dl.port,
        .protocol = protocol,
        .timeout = .{ .duration = .{
            .raw = .fromSeconds(30),
            .clock = .awake,
        } },
    });
    errdefer conn.closing = true;

    var req = try client.request(.GET, uri, .{ .connection = conn });
    defer req.deinit();

    try req.sendBodiless();

    var redirect_buf: [8192]u8 = undefined;
    var response = try req.receiveHead(&redirect_buf);

    const out_file = try std.Io.Dir.createFileAbsolute(io, dl.dest_path, .{});
    defer out_file.close(io);
    var file_buf: [8192]u8 = undefined;
    var file_writer = out_file.writer(io, &file_buf);

    var transfer_buf: [64]u8 = undefined;
    var decompress: std.http.Decompress = undefined;
    var decompress_buf: [std.compress.flate.max_window_len]u8 = undefined;
    var body_reader = response.readerDecompressing(&transfer_buf, &decompress, &decompress_buf);

    var sha = if (dl.sha256.len > 0)
        std.crypto.hash.sha2.Sha256.init(.{})
    else
        null;

    var read_buf: [8192]u8 = undefined;
    var total: u64 = 0;
    while (true) {
        const n = body_reader.readSliceShort(&read_buf) catch |err| switch (err) {
            error.ReadFailed => return response.bodyErr().?,
            else => |e| return e,
        };
        if (n == 0) break;
        _ = try file_writer.interface.write(read_buf[0..n]);
        if (sha) |*h| h.update(read_buf[0..n]);
        total += n;
        mp.setProgress(idx, total);
    }

    try file_writer.flush();
    out_file.sync(io) catch {};

    if (sha) |*h| {
        const hash = h.finalResult();
        const hex = try std.fmt.allocPrint(std.heap.page_allocator, "{x}", .{&hash});
        defer std.heap.page_allocator.free(hex);
        if (!std.ascii.eqlIgnoreCase(hex, dl.sha256)) return error.ChecksumMismatch;
    }

    return total;
}

fn computeSHA256(path: []const u8, io: std.Io) ![]u8 {
    var file = try std.Io.Dir.openFileAbsolute(io, path, .{});
    defer file.close(io);

    var sha = std.crypto.hash.sha2.Sha256.init(.{});
    var buf: [8192]u8 = undefined;
    while (true) {
        const n = file.readStreaming(io, &.{buf[0..]}) catch |err| switch (err) {
            error.EndOfStream => break,
            else => |e| return e,
        };
        sha.update(buf[0..n]);
    }
    const hash = sha.finalResult();
    return std.fmt.allocPrint(std.heap.page_allocator, "{x}", .{&hash});
}
