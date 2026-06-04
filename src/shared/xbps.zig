const std = @import("std");

// --- Types ---

pub const Handle = opaque {};

pub const Flag = struct {
    pub const verbose = 0x00000001;
    pub const force_configure = 0x00000002;
    pub const force_remove_files = 0x00000004;
    pub const install_auto = 0x00000010;
    pub const debug = 0x00000020;
    pub const force_unpack = 0x00000040;
    pub const disable_syslog = 0x00000080;
    pub const bestmatch = 0x00000100;
    pub const ignore_conf_repos = 0x00000200;
    pub const repos_memsync = 0x00000400;
    pub const force_remove_revdeps = 0x00000800;
    pub const unpack_only = 0x00001000;
    pub const download_only = 0x00002000;
    pub const ignore_file_conflicts = 0x00004000;
    pub const install_repro = 0x00008000;
    pub const keep_config = 0x00010000;
    pub const use_stage = 0x00020000;
};

// --- C Externs ---

extern fn zuri_xbps_init(rootdir: ?[*:0]const u8, cachedir: ?[*:0]const u8, flags: c_int) ?*Handle;
extern fn zuri_xbps_end(*Handle) void;

extern fn xbps_pkgdb_lock(*Handle) c_int;
extern fn xbps_pkgdb_unlock(*Handle) void;
extern fn xbps_transaction_install_pkg(*Handle, pkg: [*:0]const u8, force: bool) c_int;
extern fn xbps_transaction_remove_pkg(*Handle, pkgname: [*:0]const u8, recursive: bool) c_int;
extern fn xbps_transaction_autoremove_pkgs(*Handle) c_int;
extern fn xbps_transaction_prepare(*Handle) c_int;
extern fn xbps_transaction_commit(*Handle) c_int;
extern fn xbps_configure_packages(*Handle, ignpkgs: ?*anyopaque) c_int;
extern fn xbps_pkgdb_update(*Handle, flush: bool, update_: bool) c_int;

extern fn xbps_transaction_update_packages(*Handle) c_int;

extern fn zuri_stderr_suppress() void;
extern fn zuri_stderr_restore() void;

extern fn zuri_repo_store(*Handle, repo_url: [*:0]const u8) c_int;
extern fn zuri_rpool_sync(*Handle) c_int;
extern fn zuri_free_str_array(ptr: ?*anyopaque, count: usize) void;

// --- Init / Deinit ---

pub fn init(rootdir: ?[]const u8, cachedir: ?[]const u8, flags_val: c_int) !*Handle {
    const root: ?[*:0]const u8 = if (rootdir) |r| @ptrCast(r.ptr) else null;
    const cache: ?[*:0]const u8 = if (cachedir) |c| @ptrCast(c.ptr) else null;
    return zuri_xbps_init(root, cache, flags_val) orelse error.XbpsInitFailed;
}

pub fn end(xhp: *Handle) void {
    zuri_xbps_end(xhp);
}

// --- Error ---

fn check(rc: c_int) !void {
    if (rc == 0) return;
    return switch (rc) {
        1, 13 => error.AccessDenied, // EPERM, EACCES
        16 => error.Busy, // EBUSY
        17 => error.AlreadyExists, // EEXIST
        2 => error.NotFound, // ENOENT
        12 => error.OutOfMemory, // ENOMEM
        6 => error.NoDevice, // ENXIO
        19 => error.NoDevice, // ENODEV
        22 => error.InvalidArgument, // EINVAL
        11 => error.WouldBlock, // EAGAIN
        28 => error.NoSpaceLeft, // ENOSPC
        5 => error.IOError, // EIO
        30 => error.AccessDenied, // EROFS
        95 => error.NotSupported, // EOPNOTSUPP
        -1 => error.Unexpected,
        else => blk: {
            std.log.err("xbps error: {d}", .{rc});
            break :blk error.Unexpected;
        },
    };
}

// --- Lock ---

pub fn lockPkgdb(xhp: *Handle) !void {
    try check(xbps_pkgdb_lock(xhp));
}

pub fn unlockPkgdb(xhp: *Handle) void {
    xbps_pkgdb_unlock(xhp);
}

// --- Transaction ---

pub fn removePkg(xhp: *Handle, pkg: []const u8, recursive: bool) !void {
    if (pkg.len > 1024) return error.NameTooLong;
    var buf: [1025]u8 = undefined;
    @memcpy(buf[0..pkg.len], pkg);
    buf[pkg.len] = 0;
    try check(xbps_transaction_remove_pkg(xhp, @ptrCast(&buf), recursive));
}

pub fn autoRemovePkgs(xhp: *Handle) !void {
    try check(xbps_transaction_autoremove_pkgs(xhp));
}

pub fn installPkg(xhp: *Handle, pkg: []const u8, force: bool) !void {
    if (pkg.len > 1024) return error.NameTooLong;
    var buf: [1025]u8 = undefined;
    @memcpy(buf[0..pkg.len], pkg);
    buf[pkg.len] = 0;
    try check(xbps_transaction_install_pkg(xhp, @ptrCast(&buf), force));
}

pub fn installPkgQ(xhp: *Handle, pkg: []const u8, force: bool) !void {
    if (pkg.len > 1024) return error.NameTooLong;
    var buf: [1025]u8 = undefined;
    @memcpy(buf[0..pkg.len], pkg);
    buf[pkg.len] = 0;
    stderrOff();
    const rc = xbps_transaction_install_pkg(xhp, @ptrCast(&buf), force);
    stderrOn();
    try check(rc);
}

pub fn prepTx(xhp: *Handle) !void {
    try check(xbps_transaction_prepare(xhp));
}

pub fn prepTxQ(xhp: *Handle) !void {
    stderrOff();
    defer stderrOn();
    try check(xbps_transaction_prepare(xhp));
}

pub fn txCommit(xhp: *Handle) !void {
    try check(xbps_transaction_commit(xhp));
}

pub fn updAllPkgs(xhp: *Handle) !void {
    try check(xbps_transaction_update_packages(xhp));
}

pub fn cfgPkgs(xhp: *Handle) !void {
    try check(xbps_configure_packages(xhp, null));
}

pub fn pkgdbUpd(xhp: *Handle, flush: bool, update_: bool) !void {
    try check(xbps_pkgdb_update(xhp, flush, update_));
}

pub fn stderrOff() void {
    zuri_stderr_suppress();
}

pub fn stderrOn() void {
    zuri_stderr_restore();
}

// --- Repo ---

pub fn storeRepo(xhp: *Handle, repo_url: [:0]const u8) !void {
    if (zuri_repo_store(xhp, repo_url) != 0)
        return error.RepoStoreFailed;
}

pub fn syncRpool(xhp: *Handle) !void {
    try check(zuri_rpool_sync(xhp));
}

pub fn syncRpoolQ(xhp: *Handle) !void {
    stderrOff();
    defer stderrOn();
    try check(zuri_rpool_sync(xhp));
}

// --- Tx Pkg Metadata ---

pub const PkgDownload = struct {
    pkgver: []const u8,
    filename: []const u8,
    sha256: []const u8,
    size: u64,
};

const CZuriPkgDownload = extern struct {
    pkgver: ?[*:0]u8,
    filename: ?[*:0]u8,
    sha256: ?[*:0]u8,
    size: u64,
};

extern fn zuri_transaction_pkgs(*Handle, count: *usize) ?[*]CZuriPkgDownload;
extern fn zuri_free_pkg_downloads(arr: ?[*]CZuriPkgDownload, count: usize) void;

pub fn txPkgs(allocator: std.mem.Allocator, xhp: *Handle) ![]PkgDownload {
    var count: usize = 0;
    const arr = zuri_transaction_pkgs(xhp, &count) orelse return &.{};
    defer zuri_free_pkg_downloads(arr, count);

    var result = try allocator.alloc(PkgDownload, count);
    errdefer {
        for (result) |p| {
            allocator.free(p.pkgver);
            allocator.free(p.filename);
            allocator.free(p.sha256);
        }
        allocator.free(result);
    }

    for (0..count) |i| {
        const pkgver = arr[i].pkgver orelse return error.Unexpected;
        const filename = arr[i].filename orelse return error.Unexpected;
        const sha256 = arr[i].sha256 orelse "";
        result[i] = .{
            .pkgver = try allocator.dupe(u8, std.mem.sliceTo(pkgver, 0)),
            .filename = try allocator.dupe(u8, std.mem.sliceTo(filename, 0)),
            .sha256 = try allocator.dupe(u8, std.mem.sliceTo(sha256, 0)),
            .size = arr[i].size,
        };
    }
    return result;
}
