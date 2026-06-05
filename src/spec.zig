const cli = @import("clingy");

pub const install = cli.Command{
    .name = "install",
    .description = "Install one or more packages",
    .flags = &.{
        cli.Flag{ .long = "yes", .short = 'y', .kind = .bool, .description = "Skip confirmation prompt" },
        cli.Flag{ .long = "force", .short = 'f', .kind = .bool, .description = "Force re-install even if already installed" },
    },
    .positionals = &.{
        cli.Positional{ .name = "pkg", .description = "Package(s) to install", .variadic = true },
    },
};

pub const remove = cli.Command{
    .name = "remove",
    .description = "Remove one or more packages",
    .flags = &.{
        cli.Flag{ .long = "yes", .short = 'y', .kind = .bool, .description = "Skip confirmation prompt" },
        cli.Flag{ .long = "keep-deps", .short = 'd', .kind = .bool, .description = "Do not remove orphaned dependencies" },
    },
    .positionals = &.{
        cli.Positional{ .name = "pkg", .description = "Package(s) to remove", .variadic = true },
    },
};

pub const update = cli.Command{
    .name = "update",
    .description = "Sync repositories and upgrade all packages",
    .flags = &.{
        cli.Flag{ .long = "yes", .short = 'y', .kind = .bool, .description = "Skip confirmation prompt" },
    },
};

pub const search = cli.Command{
    .name = "search",
    .description = "Search available packages",
    .aliases = &.{"query"},
    .positionals = &.{
        cli.Positional{ .name = "query", .description = "Search query", .required = true },
    },
};

pub const info = cli.Command{
    .name = "info",
    .description = "Show package details",
    .positionals = &.{
        cli.Positional{ .name = "pkg", .description = "Package name", .required = true },
    },
};

pub const build = cli.Command{
    .name = "build",
    .description = "Build and install from void-packages template",
    .flags = &.{
        cli.Flag{ .long = "force", .short = 'f', .kind = .bool, .description = "Force rebuild" },
    },
    .positionals = &.{
        cli.Positional{ .name = "template", .description = "Template name", .required = true },
    },
};

pub const clean = cli.Command{
    .name = "clean",
    .description = "Remove cached packages",
    .flags = &.{
        cli.Flag{ .long = "all", .short = 'a', .kind = .bool, .description = "Remove all cached files including partials" },
        cli.Flag{ .long = "orphans", .short = 'o', .kind = .bool, .description = "Also remove orphaned dependencies" },
    },
};

pub const root = cli.Command{
    .name = "zuri",
    .description = "a feature filled alternative to xbps",
    .version = "0.1.0",
    .flags = &.{
        cli.Flag{ .long = "dry-run", .short = 'n', .kind = .bool, .description = "Show what would happen without executing" },
        cli.Flag{ .long = "no-color", .short = 'C', .kind = .bool, .description = "Disable color output" },
        cli.Flag{ .long = "root", .short = 'r', .kind = .string, .description = "Operate on an alternate root" },
        cli.Flag{ .long = "sudo-loop", .short = 'L', .kind = .bool, .description = "Call sudo in the background to not lose persistant sudo" },
    },
    .subcommands = &.{ install, remove, update, search, info, build, clean },
};

pub fn formatZuriErr(writer: anytype, comptime cmd: cli.Command, err: cli.ParseError, args: []const []const u8) !void {
    switch (err) {
        cli.ParseError.AmbiguousSubcommand => {
            for (args) |arg| {
                if (arg.len > 0 and arg[0] == '-') continue;
                var matches: [64][]const u8 = undefined;
                const count = cli.collectPrefixMatches(cmd, arg, &matches);
                if (count > 1) {
                    try writer.print("{s}: '{s}' is ambiguous, did you mean:", .{ cmd.name, arg });
                    for (matches[0..count], 0..) |m, i| {
                        try writer.print(" {s}{s}", .{ m, if (i == count - 1) "?" else "," });
                    }
                    try writer.writeAll("\n");
                    return;
                }
            }
            try cli.formatError(writer, cmd, err, args);
        },
        else => try cli.formatError(writer, cmd, err, args),
    }
}
