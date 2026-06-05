const std = @import("std");
const linux = std.os.linux;

// --- xbps C API types ---

const xbps_object_t = *anyopaque;
const xbps_dictionary_t = xbps_object_t;
const xbps_array_t = xbps_object_t;
const xbps_dictionary_keysym_t = xbps_object_t;
const xbps_trans_type_t = c_uint;

const trans_install: xbps_trans_type_t = 1;
const trans_remove: xbps_trans_type_t = 2;
const trans_update: xbps_trans_type_t = 4;
const trans_reinstall: xbps_trans_type_t = 16;

// --- Types ---

pub const Handle = extern struct {
    _pad0: [72]u8 = undefined,
    transd: xbps_dictionary_t,
    _pad1: [1088]u8 = undefined,
    rootdir: [512]u8,
    cachedir: [512]u8,
    _pad2: [576]u8 = undefined,
    flags: c_int,
    _pad3: [4]u8 = undefined,

    comptime {
        std.debug.assert(@sizeOf(Handle) == 2776);
        std.debug.assert(@offsetOf(Handle, "transd") == 72);
        std.debug.assert(@offsetOf(Handle, "rootdir") == 1168);
        std.debug.assert(@offsetOf(Handle, "cachedir") == 1680);
        std.debug.assert(@offsetOf(Handle, "flags") == 2768);
    }
};

const Repo = extern struct {
    _pad0: [24]u8 = @splat(0),
    idx: xbps_dictionary_t,
    _pad1: [40]u8 = @splat(0),
};

// --- libc externs ---

extern fn calloc(nmemb: usize, size: usize) ?*anyopaque;
extern fn free(ptr: ?*anyopaque) void;
extern fn strdup(s: [*:0]const u8) ?[*:0]u8;

// --- libxbps externs ---

extern fn xbps_init(xhp: *Handle) c_int;
extern fn xbps_end(xhp: *Handle) void;
extern fn xbps_repo_store(xhp: *Handle, url: [*:0]const u8) bool;
extern fn xbps_rpool_sync(xhp: *Handle, repos: ?*anyopaque) c_int;

const RpoolCb = *const fn (repo: *Repo, arg: ?*anyopaque, loop_done: *bool) callconv(.c) c_int;
extern fn xbps_rpool_foreach(xhp: *Handle, fn_: RpoolCb, arg: ?*anyopaque) c_int;

extern fn xbps_dictionary_get(dict: xbps_dictionary_t, key: [*:0]const u8) ?xbps_object_t;
extern fn xbps_dictionary_get_cstring_nocopy(dict: xbps_dictionary_t, key: [*:0]const u8, val: *?[*:0]const u8) bool;
extern fn xbps_dictionary_get_uint64(dict: xbps_dictionary_t, key: [*:0]const u8, val: *u64) bool;
extern fn xbps_dictionary_all_keys(dict: xbps_dictionary_t) ?xbps_array_t;
extern fn xbps_dictionary_keysym_cstring_nocopy(sym: xbps_dictionary_keysym_t) ?[*:0]const u8;
extern fn xbps_array_count(arr: xbps_array_t) usize;
extern fn xbps_array_get(arr: xbps_array_t, idx: usize) ?xbps_object_t;
extern fn xbps_pkgdb_get_pkg(xhp: *Handle, pkgname: [*:0]const u8) ?xbps_dictionary_t;
extern fn xbps_rpool_get_pkg(xhp: *Handle, pkgname: [*:0]const u8) ?xbps_dictionary_t;
extern fn xbps_transaction_pkg_type(pkg: xbps_dictionary_t) xbps_trans_type_t;
extern fn xbps_archive_fetch_plist(path: [*:0]const u8, subpath: [*:0]const u8) ?xbps_dictionary_t;
extern fn xbps_object_release(obj: xbps_object_t) void;

extern fn xbps_pkgdb_lock(xhp: *Handle) c_int;
extern fn xbps_pkgdb_unlock(xhp: *Handle) void;
extern fn xbps_transaction_install_pkg(xhp: *Handle, pkg: [*:0]const u8, force: bool) c_int;
extern fn xbps_transaction_remove_pkg(xhp: *Handle, pkgname: [*:0]const u8, recursive: bool) c_int;
extern fn xbps_transaction_autoremove_pkgs(xhp: *Handle) c_int;
extern fn xbps_transaction_prepare(xhp: *Handle) c_int;
extern fn xbps_transaction_commit(xhp: *Handle) c_int;
extern fn xbps_configure_packages(xhp: *Handle, ignpkgs: ?*anyopaque) c_int;
extern fn xbps_pkgdb_update(xhp: *Handle, flush: bool, update_: bool) c_int;
extern fn xbps_transaction_update_packages(xhp: *Handle) c_int;

// --- Flag constants ---

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

// --- Init / Deinit ---

pub fn init(rootdir: ?[]const u8, cachedir: ?[]const u8, flags_val: c_int) !*Handle {
    const raw = calloc(1, @sizeOf(Handle)) orelse return error.XbpsInitFailed;
    const xhp = @as(*Handle, @ptrCast(@alignCast(raw)));

    if (rootdir) |r| {
        const n = @min(r.len, xhp.rootdir.len - 1);
        @memcpy(xhp.rootdir[0..n], r[0..n]);
        xhp.rootdir[n] = 0;
    }
    if (cachedir) |c| {
        const n = @min(c.len, xhp.cachedir.len - 1);
        @memcpy(xhp.cachedir[0..n], c[0..n]);
        xhp.cachedir[n] = 0;
    }
    xhp.flags = flags_val;

    if (xbps_init(xhp) != 0) {
        free(xhp);
        return error.XbpsInitFailed;
    }
    return xhp;
}

pub fn end(xhp: *Handle) void {
    xbps_end(xhp);
    free(xhp);
}

pub fn addFlags(xhp: *Handle, flags_val: c_int) void {
    xhp.flags |= flags_val;
}

// --- Repo ---

pub fn storeRepo(xhp: *Handle, repo_url: [:0]const u8) !void {
    if (!xbps_repo_store(xhp, repo_url))
        return error.RepoStoreFailed;
}

pub fn syncRpool(xhp: *Handle) !void {
    try check(xbps_rpool_sync(xhp, null));
}

pub fn syncRpoolQ(xhp: *Handle) !void {
    stderrOff();
    defer stderrOn();
    try check(xbps_rpool_sync(xhp, null));
}

// --- Error ---

fn check(rc: c_int) !void {
    if (rc == 0) return;
    return switch (rc) {
        1, 13 => error.AccessDenied,
        16 => error.Busy,
        17 => error.AlreadyExists,
        2 => error.NotFound,
        12 => error.OutOfMemory,
        6, 19 => error.NoDevice,
        22 => error.InvalidArgument,
        11 => error.WouldBlock,
        28 => error.NoSpaceLeft,
        5 => error.IOError,
        30 => error.AccessDenied,
        95 => error.NotSupported,
        -1 => error.Unexpected,
        else => {
            std.log.err("xbps error: {d}", .{rc});
            return error.Unexpected;
        },
    };
}

// --- StdErr ---

var saved_stderr: i32 = -1;

const O_WRONLY: linux.O = @bitCast(@as(u32, 1));

pub fn stderrOff() void {
    if (saved_stderr != -1) return;
    const rc = linux.dup(2);
    if (@as(isize, @bitCast(rc)) < 0) return;
    saved_stderr = @intCast(rc);

    const null_fd = linux.open("/dev/null", O_WRONLY, 0);
    if (@as(isize, @bitCast(null_fd)) < 0) {
        _ = linux.close(@intCast(saved_stderr));
        saved_stderr = -1;
        return;
    }
    _ = linux.dup2(@intCast(null_fd), 2);
    _ = linux.close(@intCast(null_fd));
}

pub fn stderrOn() void {
    if (saved_stderr == -1) return;
    _ = linux.dup2(saved_stderr, 2);
    _ = linux.close(@intCast(saved_stderr));
    saved_stderr = -1;
}

// --- Search ---

const SearchResultRaw = struct {
    pkgver: []const u8,
    short_desc: []const u8,
    pkgname: []const u8,
};

const SearchContext = struct {
    list: *std.ArrayListUnmanaged(SearchResultRaw),
    pattern: []const u8,
    allocator: std.mem.Allocator,
};

fn ciStrstr(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;
    for (0..haystack.len - needle.len + 1) |i| {
        var match = true;
        for (0..needle.len) |j| {
            if (std.ascii.toLower(haystack[i + j]) != needle[j]) {
                match = false;
                break;
            }
        }
        if (match) return true;
    }
    return false;
}

fn isDup(arr: []const SearchResultRaw, name: []const u8) bool {
    for (arr) |entry| {
        if (std.mem.eql(u8, entry.pkgname, name)) return true;
    }
    return false;
}

fn searchRepoCb(repo: *Repo, arg: ?*anyopaque, loop_done: *bool) callconv(.c) c_int {
    _ = loop_done;
    const ctx = @as(*SearchContext, @ptrCast(@alignCast(arg orelse return 0)));

    if (@intFromPtr(repo.idx) == 0) return 0;

    const keys = xbps_dictionary_all_keys(repo.idx) orelse return 0;
    const nkeys = xbps_array_count(keys);

    for (0..nkeys) |i| {
        const key_obj = xbps_array_get(keys, i) orelse continue;
        const pkgname = xbps_dictionary_keysym_cstring_nocopy(@ptrCast(key_obj)) orelse continue;

        const pn = std.mem.sliceTo(pkgname, 0);
        if (isDup(ctx.list.items, pn)) continue;

        const pkgd = xbps_dictionary_get(repo.idx, pkgname) orelse continue;

        var pkgver: ?[*:0]const u8 = null;
        _ = xbps_dictionary_get_cstring_nocopy(pkgd, "pkgver", &pkgver);
        const pv = pkgver orelse continue;

        var short_desc: ?[*:0]const u8 = null;
        _ = xbps_dictionary_get_cstring_nocopy(pkgd, "short_desc", &short_desc);
        const sd = if (short_desc) |s| std.mem.sliceTo(s, 0) else "";

        const pv_s = std.mem.sliceTo(pv, 0);
        if (!ciStrstr(pv_s, ctx.pattern) and !ciStrstr(sd, ctx.pattern))
            continue;

        const entry = SearchResultRaw{
            .pkgver = ctx.allocator.dupe(u8, pv_s) catch return 0,
            .short_desc = ctx.allocator.dupe(u8, sd) catch return 0,
            .pkgname = ctx.allocator.dupe(u8, pn) catch return 0,
        };
        ctx.list.append(ctx.allocator, entry) catch return 0;
    }

    return 0;
}

// --- Public search API ---

pub const SearchResult = struct {
    pkgver: []const u8,
    short_desc: []const u8,
    pkgname: []const u8,
    installed: bool,
};

pub fn searchPkgs(allocator: std.mem.Allocator, xhp: *Handle, pattern: []const u8) ![]SearchResult {
    if (pattern.len > 1024) return error.NameTooLong;
    var pattern_lower_buf: [1025]u8 = undefined;
    const pattern_lower = std.ascii.lowerString(pattern_lower_buf[0..pattern.len], pattern);

    var list: std.ArrayListUnmanaged(SearchResultRaw) = .empty;
    defer {
        for (list.items) |item| {
            allocator.free(item.pkgver);
            allocator.free(item.short_desc);
            allocator.free(item.pkgname);
        }
        list.deinit(allocator);
    }

    var ctx = SearchContext{
        .list = &list,
        .pattern = pattern_lower,
        .allocator = allocator,
    };

    _ = xbps_rpool_foreach(xhp, searchRepoCb, @ptrCast(&ctx));

    var results = try allocator.alloc(SearchResult, list.items.len);
    for (0..list.items.len) |i| {
        const raw = &list.items[i];
        results[i] = .{
            .pkgver = raw.pkgver,
            .short_desc = raw.short_desc,
            .pkgname = raw.pkgname,
            .installed = pkgdbHasPkg(xhp, @ptrCast(raw.pkgname.ptr)) != 0,
        };
    }
    list.items.len = 0;
    return results;
}

fn pkgdbHasPkg(xhp: *Handle, pkgname: [*:0]const u8) c_int {
    return if (xbps_pkgdb_get_pkg(xhp, pkgname) != null) 1 else 0;
}

// --- Package Info ---

pub const PkgInfo = struct {
    pkgver: []const u8,
    short_desc: []const u8,
    homepage: []const u8,
    license: []const u8,
    repository: []const u8,
    installed_size: u64,
    installed: bool,
};

pub fn pkgInfo(allocator: std.mem.Allocator, xhp: *Handle, pkgname: []const u8) !?PkgInfo {
    if (pkgname.len > 1024) return error.NameTooLong;
    var buf: [1025]u8 = undefined;
    @memcpy(buf[0..pkgname.len], pkgname);
    buf[pkgname.len] = 0;
    const key = @as([*:0]const u8, @ptrCast(&buf));

    const pkgd = if (xbps_pkgdb_get_pkg(xhp, key)) |p|
        p
    else if (xbps_rpool_get_pkg(xhp, key)) |p|
        p
    else
        return null;
    const installed = xbps_pkgdb_get_pkg(xhp, key) != null;

    var pkgver: []const u8 = "";
    var short_desc: []const u8 = "";
    var homepage: []const u8 = "";
    var license: []const u8 = "";
    var repository: []const u8 = "";
    errdefer {
        if (pkgver.len > 0) allocator.free(pkgver);
        if (short_desc.len > 0) allocator.free(short_desc);
        if (homepage.len > 0) allocator.free(homepage);
        if (license.len > 0) allocator.free(license);
        if (repository.len > 0) allocator.free(repository);
    }

    var val: ?[*:0]const u8 = null;
    if (xbps_dictionary_get_cstring_nocopy(pkgd, "pkgver", &val) and val != null)
        pkgver = try allocator.dupe(u8, std.mem.sliceTo(val.?, 0));
    if (xbps_dictionary_get_cstring_nocopy(pkgd, "short_desc", &val) and val != null)
        short_desc = try allocator.dupe(u8, std.mem.sliceTo(val.?, 0));
    if (xbps_dictionary_get_cstring_nocopy(pkgd, "homepage", &val) and val != null)
        homepage = try allocator.dupe(u8, std.mem.sliceTo(val.?, 0));
    if (xbps_dictionary_get_cstring_nocopy(pkgd, "license", &val) and val != null)
        license = try allocator.dupe(u8, std.mem.sliceTo(val.?, 0));
    if (xbps_dictionary_get_cstring_nocopy(pkgd, "repository", &val) and val != null)
        repository = try allocator.dupe(u8, std.mem.sliceTo(val.?, 0));

    var usize_val: u64 = 0;
    _ = xbps_dictionary_get_uint64(pkgd, "installed_size", &usize_val);

    return PkgInfo{
        .pkgver = pkgver,
        .short_desc = short_desc,
        .homepage = homepage,
        .license = license,
        .repository = repository,
        .installed_size = usize_val,
        .installed = installed,
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

// --- Tx Pkg Metadata ---

pub const PkgDownload = struct {
    pkgver: []const u8,
    filename: []const u8,
    sha256: []const u8,
    size: u64,
    local_path: []const u8,
};

pub fn txPkgs(allocator: std.mem.Allocator, xhp: *Handle) ![]PkgDownload {
    if (@intFromPtr(xhp.transd) == 0) return &.{};

    const pkgs = xbps_dictionary_get(xhp.transd, "packages") orelse return &.{};
    const n = xbps_array_count(@ptrCast(pkgs));

    var want: usize = 0;
    for (0..n) |i| {
        const pkg_obj = xbps_array_get(@ptrCast(pkgs), i) orelse continue;
        const ttype = xbps_transaction_pkg_type(@ptrCast(pkg_obj));
        if (ttype != trans_install and ttype != trans_reinstall and
            ttype != trans_update and ttype != trans_remove) continue;
        var pkgver: ?[*:0]const u8 = null;
        _ = xbps_dictionary_get_cstring_nocopy(@ptrCast(pkg_obj), "pkgver", &pkgver);
        if (pkgver != null) want += 1;
    }

    var result = try allocator.alloc(PkgDownload, want);
    errdefer {
        for (result) |*p| {
            if (p.pkgver.len > 0) allocator.free(p.pkgver);
            if (p.filename.len > 0) allocator.free(p.filename);
            if (p.sha256.len > 0) allocator.free(p.sha256);
            if (p.local_path.len > 0) allocator.free(p.local_path);
        }
        allocator.free(result);
    }

    var out: usize = 0;
    for (0..n) |i| {
        const pkg_obj = xbps_array_get(@ptrCast(pkgs), i) orelse continue;
        const pkg: xbps_dictionary_t = @ptrCast(pkg_obj);

        const ttype = xbps_transaction_pkg_type(pkg);
        if (ttype != trans_install and ttype != trans_reinstall and
            ttype != trans_update and ttype != trans_remove) continue;

        var pkgver: ?[*:0]const u8 = null;
        _ = xbps_dictionary_get_cstring_nocopy(pkg, "pkgver", &pkgver);
        const pv = pkgver orelse continue;

        var arch: ?[*:0]const u8 = null;
        _ = xbps_dictionary_get_cstring_nocopy(pkg, "architecture", &arch);

        var sha: ?[*:0]const u8 = null;
        _ = xbps_dictionary_get_cstring_nocopy(pkg, "filename-sha256", &sha);

        var fsz: u64 = 0;
        _ = xbps_dictionary_get_uint64(pkg, "filename-size", &fsz);

        var fname_str: []const u8 = undefined;
        var local_path_str: []const u8 = "";

        var fname_dict: ?[*:0]const u8 = null;
        if (xbps_dictionary_get_cstring_nocopy(pkg, "filename", &fname_dict) and fname_dict != null) {
            fname_str = try allocator.dupe(u8, std.mem.sliceTo(fname_dict.?, 0));
        } else {
            const pv_s = std.mem.sliceTo(pv, 0);
            if (arch != null and !std.mem.eql(u8, std.mem.sliceTo(arch.?, 0), "noarch")) {
                const a_s = std.mem.sliceTo(arch.?, 0);
                fname_str = try std.mem.join(allocator, "", &.{ pv_s, ".", a_s, ".xbps" });
            } else {
                fname_str = try std.mem.join(allocator, "", &.{ pv_s, ".xbps" });
            }
        }

        var local_path_val: ?[*:0]const u8 = null;
        if (xbps_dictionary_get_cstring_nocopy(pkg, "local-path", &local_path_val) and local_path_val != null)
            local_path_str = try allocator.dupe(u8, std.mem.sliceTo(local_path_val.?, 0));

        result[out] = .{
            .pkgver = try allocator.dupe(u8, std.mem.sliceTo(pv, 0)),
            .filename = fname_str,
            .sha256 = if (sha) |s| try allocator.dupe(u8, std.mem.sliceTo(s, 0)) else "",
            .size = fsz,
            .local_path = local_path_str,
        };
        out += 1;
    }

    return result;
}

// --- Local pkg metadata ---

fn freeStr(ptr: ?*anyopaque) void {
    free(ptr);
}

fn dupCStr(allocator: std.mem.Allocator, ptr: ?*anyopaque) ![]const u8 {
    const c_ptr = ptr orelse return error.NotFound;
    const slice = @as([*:0]u8, @ptrCast(c_ptr));
    defer freeStr(c_ptr);
    return allocator.dupe(u8, std.mem.sliceTo(slice, 0));
}

pub fn binpkgPkgver(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    var buf: [4096]u8 = undefined;
    if (path.len > buf.len - 1) return error.NameTooLong;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    return dupCStr(allocator, getBinpkgPkgver(@ptrCast(&buf)));
}

pub fn binpkgArch(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    var buf: [4096]u8 = undefined;
    if (path.len > buf.len - 1) return error.NameTooLong;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    return dupCStr(allocator, getBinpkgArch(@ptrCast(&buf)));
}

fn getBinpkgPkgver(path: [*:0]const u8) ?*anyopaque {
    const meta = xbps_archive_fetch_plist(path, "/props.plist") orelse return null;
    defer xbps_object_release(meta);
    var pkgver: ?[*:0]const u8 = null;
    _ = xbps_dictionary_get_cstring_nocopy(meta, "pkgver", &pkgver);
    if (pkgver) |pv| return strdup(pv);
    return null;
}

fn getBinpkgArch(path: [*:0]const u8) ?*anyopaque {
    const meta = xbps_archive_fetch_plist(path, "/props.plist") orelse return null;
    defer xbps_object_release(meta);
    var arch: ?[*:0]const u8 = null;
    _ = xbps_dictionary_get_cstring_nocopy(meta, "architecture", &arch);
    if (arch) |a| return strdup(a);
    return null;
}
