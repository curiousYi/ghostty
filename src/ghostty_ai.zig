//! Helpers for `ghostty-ai`: the shell function asks Ghostty (via OSC 6767)
//! to capture the last few commands and open a split running the
//! configured `ghostty-ai-command` with them.
//!
//! The IO thread uses `isPlausible` and `capture` while it holds the
//! terminal lock, at the moment the request is parsed. By the time the
//! app thread sees the request the shell has usually drawn its next
//! prompt, so the active command is no longer `ghostty-ai`. The app thread
//! uses the rest to validate the request and launch the split.
const std = @import("std");
const Allocator = std.mem.Allocator;
const configpkg = @import("config.zig");
const terminal = @import("terminal/main.zig");

/// The environment variable that holds the capture file path.
pub const env_file = "GHOSTTY_AI_FILE";

/// The environment variable that holds the note.
pub const env_note = "GHOSTTY_AI_NOTE";

/// The environment variable that holds the request id, which ties the
/// split back to the surface that launched it.
pub const env_parent = "GHOSTTY_AI_PARENT";

/// The name of the shell function, which must be the active command.
const function_name = "ghostty-ai";

/// The maximum number of note bytes shown in the split title.
const title_note_max = 60;

/// Returns true if the active command on the primary screen is the
/// `ghostty-ai` shell function, as recorded by shell integration. The
/// caller must hold the terminal lock.
///
/// This is a cheap guard against a program printing the request
/// sequence. It is not a security boundary: output can also fake the
/// prompt marks.
pub fn isPlausible(alloc: Allocator, t: *terminal.Terminal) Allocator.Error!bool {
    const screen = t.screens.get(.primary).?;
    if (!screen.semantic_prompt.seen) return false;

    var it = screen.cursor.page_pin.promptIterator(.left_up, null);
    const prompt = it.next() orelse return false;
    const hl = screen.pages.highlightSemanticContent(
        prompt,
        .input,
    ) orelse return false;

    const input = try screen.selectionString(alloc, .{
        .sel = .init(hl.start, hl.end, false),
        .trim = false,
    });
    defer alloc.free(input);
    return isPlausibleInput(input);
}

/// Returns true if `input`, the text of a command line, runs the
/// `ghostty-ai` function: after trimming whitespace it is `ghostty-ai`
/// or starts with `ghostty-ai ` (followed by a space).
pub fn isPlausibleInput(input: []const u8) bool {
    const trimmed = std.mem.trim(u8, input, " \t\r\n");
    if (!std.mem.startsWith(u8, trimmed, function_name)) return false;
    const rest = trimmed[function_name.len..];
    return rest.len == 0 or rest[0] == ' ';
}

/// The result of capturing commands for a request.
pub const Capture = union(enum) {
    /// The header line followed by the plain text of the commands.
    text: []const u8,

    /// The alternate screen is active.
    alternate_screen,

    /// There are no commands to capture: no prompt marks, or nothing
    /// before the active `ghostty-ai` command.
    no_commands,

    pub fn deinit(self: Capture, alloc: Allocator) void {
        switch (self) {
            .text => |v| alloc.free(v),
            .alternate_screen, .no_commands => {},
        }
    }
};

/// Capture the last `count` commands before the active one, which is
/// the `ghostty-ai` command itself. The text starts with a header line
/// that names the count and the working directory. The caller must hold
/// the terminal lock.
pub fn capture(
    alloc: Allocator,
    t: *terminal.Terminal,
    count: u8,
) (Allocator.Error || std.Io.Writer.Error)!Capture {
    if (t.screens.active_key == .alternate) return .alternate_screen;

    const screen = t.screens.active;
    const sel = screen.selectCommands(
        count,
        .{ .exclude_active = true },
    ) orelse return .no_commands;

    var aw: std.Io.Writer.Allocating = .init(alloc);
    errdefer aw.deinit();
    const writer = &aw.writer;

    try writer.print(
        "# Terminal history captured by Ghostty (last {d} command{s}, cwd {s})\n\n",
        .{
            count,
            if (count == 1) "" else "s",
            t.getPwd() orelse "unknown",
        },
    );

    var formatter: terminal.formatter.ScreenFormatter = .init(screen, .{
        .emit = .plain,
        .unwrap = true,
    });
    formatter.content = .{ .selection = sel.ordered(screen, .forward) };
    try formatter.format(writer);
    try writer.writeByte('\n');

    return .{ .text = try aw.toOwnedSlice() };
}

/// Returns true if the note contains no control bytes other than tab and
/// newline. The note becomes an environment variable and part of the
/// split title, so escape sequences in it are refused.
pub fn isValidNote(note: []const u8) bool {
    for (note) |c| switch (c) {
        '\t', '\n' => {},
        0...0x08, 0x0B...0x1F, 0x7F => return false,
        else => {},
    };
    return true;
}

/// Format the split title: `ghostty-ai: N commands — <note>`. Tabs and
/// newlines in the note become spaces, and a long note is truncated on a
/// UTF-8 boundary with an ellipsis.
pub fn formatTitle(
    buf: []u8,
    count: u8,
    note: []const u8,
) std.Io.Writer.Error![:0]const u8 {
    var writer: std.Io.Writer = .fixed(buf);
    try writer.print("ghostty-ai: {d} command{s}", .{
        count,
        if (count == 1) "" else "s",
    });

    const trimmed = std.mem.trim(u8, note, " \t\n");
    if (trimmed.len > 0) {
        var len = @min(trimmed.len, title_note_max);
        while (len > 0 and len < trimmed.len and
            trimmed[len] & 0xC0 == 0x80) len -= 1;

        try writer.writeAll(" — ");
        for (trimmed[0..len]) |c| try writer.writeByte(switch (c) {
            '\t', '\n' => ' ',
            else => c,
        });
        if (len < trimmed.len) try writer.writeAll("…");
    }

    try writer.writeByte(0);
    const written = writer.buffered();
    return written[0 .. written.len - 1 :0];
}

/// Returns the command as a string for `/bin/sh -c`. A `shell:` command is
/// used as is. Each argument of a `direct:` command is single-quoted, so
/// nothing in it is expanded. Returns null for an empty command.
pub fn shellCommand(
    alloc: Allocator,
    command: configpkg.Command,
) Allocator.Error!?[:0]const u8 {
    switch (command) {
        .shell => |v| {
            if (std.mem.trim(u8, v, " \t\n").len == 0) return null;
            return try alloc.dupeSentinel(u8, v, 0);
        },

        .direct => |args| {
            if (args.len == 0) return null;

            var aw: std.Io.Writer.Allocating = .init(alloc);
            errdefer aw.deinit();
            const writer = &aw.writer;
            for (args, 0..) |arg, i| {
                if (i > 0) writer.writeByte(' ') catch return error.OutOfMemory;
                writeShellQuoted(writer, arg) catch return error.OutOfMemory;
            }
            return try aw.toOwnedSliceSentinel(0);
        },
    }
}

/// Write `arg` single-quoted for a POSIX shell.
fn writeShellQuoted(writer: *std.Io.Writer, arg: []const u8) std.Io.Writer.Error!void {
    try writer.writeByte('\'');
    for (arg) |c| {
        if (c == '\'') {
            try writer.writeAll("'\\''");
        } else {
            try writer.writeByte(c);
        }
    }
    try writer.writeByte('\'');
}

/// Test helper: a terminal with the given VT input applied.
fn testTerminal(alloc: Allocator, input: []const u8) !terminal.Terminal {
    var t: terminal.Terminal = try .init(std.testing.io, alloc, .{
        .cols = 40,
        .rows = 20,
    });
    errdefer t.deinit(alloc);

    var s = t.vtStream();
    defer s.deinit();
    s.nextSlice(input);
    return t;
}

/// Test helper: VT input for a finished command.
fn testCommand(comptime input: []const u8, comptime output: []const u8) []const u8 {
    return "\x1b]133;A\x07$ \x1b]133;B\x07" ++ input ++
        "\r\n\x1b]133;C\x07" ++ output ++ "\x1b]133;D;0\x07";
}

/// Test helper: VT input for the running `ghostty-ai` command.
fn testRunning(comptime input: []const u8) []const u8 {
    return "\x1b]133;A\x07$ \x1b]133;B\x07" ++ input ++ "\r\n\x1b]133;C\x07";
}

test "isPlausibleInput" {
    const testing = std.testing;
    try testing.expect(isPlausibleInput("ghostty-ai"));
    try testing.expect(isPlausibleInput("ghostty-ai 5 why?"));
    try testing.expect(isPlausibleInput("  ghostty-ai  "));
    try testing.expect(!isPlausibleInput(""));
    try testing.expect(!isPlausibleInput("ghostty-aix"));
    try testing.expect(!isPlausibleInput("ghostty-ai\t5"));
    try testing.expect(!isPlausibleInput("cat evil.txt"));
    try testing.expect(!isPlausibleInput("echo ghostty-ai"));
}

test "isPlausible running ghostty-ai" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var t = try testTerminal(alloc, comptime testCommand("make", "ok\r\n") ++
        testRunning("ghostty-ai 3 why"));
    defer t.deinit(alloc);
    try testing.expect(try isPlausible(alloc, &t));
}

test "isPlausible other command" {
    const testing = std.testing;
    const alloc = testing.allocator;

    // A file containing the sequence is printed by another command.
    var t = try testTerminal(alloc, comptime testRunning("cat evil.txt"));
    defer t.deinit(alloc);
    try testing.expect(!try isPlausible(alloc, &t));
}

test "isPlausible no shell integration" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var t = try testTerminal(alloc, "$ ghostty-ai 3\r\n");
    defer t.deinit(alloc);
    try testing.expect(!try isPlausible(alloc, &t));
}

test "capture excludes the ghostty-ai command" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var t = try testTerminal(alloc, comptime testCommand("one", "1\r\n") ++
        testCommand("two", "2a\r\n2b\r\n") ++
        testRunning("ghostty-ai 1 why"));
    defer t.deinit(alloc);
    try t.setPwd("/home/me/project");

    {
        const result = try capture(alloc, &t, 1);
        defer result.deinit(alloc);
        try testing.expectEqualStrings(
            "# Terminal history captured by Ghostty (last 1 command, cwd /home/me/project)\n\n" ++
                "$ two\n2a\n2b\n",
            result.text,
        );
    }
    {
        const result = try capture(alloc, &t, 5);
        defer result.deinit(alloc);
        try testing.expectEqualStrings(
            "# Terminal history captured by Ghostty (last 5 commands, cwd /home/me/project)\n\n" ++
                "$ one\n1\n$ two\n2a\n2b\n",
            result.text,
        );
    }
}

test "capture with nothing before ghostty-ai" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var t = try testTerminal(alloc, comptime testRunning("ghostty-ai"));
    defer t.deinit(alloc);
    try testing.expectEqual(Capture.no_commands, try capture(alloc, &t, 5));
}

test "capture on the alternate screen" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var t = try testTerminal(alloc, comptime testCommand("one", "1\r\n") ++
        testRunning("ghostty-ai") ++ "\x1b[?1049h");
    defer t.deinit(alloc);
    try testing.expectEqual(Capture.alternate_screen, try capture(alloc, &t, 5));
}

test "isValidNote" {
    const testing = std.testing;
    try testing.expect(isValidNote(""));
    try testing.expect(isValidNote("why is\tthis\nfailing? ✓"));
    try testing.expect(!isValidNote("evil\x1b]0;title\x07"));
    try testing.expect(!isValidNote("cr\r"));
    try testing.expect(!isValidNote("nul\x00"));
    try testing.expect(!isValidNote("del\x7f"));
}

test "formatTitle" {
    const testing = std.testing;
    var buf: [256]u8 = undefined;

    try testing.expectEqualStrings(
        "ghostty-ai: 1 command",
        try formatTitle(&buf, 1, ""),
    );
    try testing.expectEqualStrings(
        "ghostty-ai: 5 commands — why is this failing?",
        try formatTitle(&buf, 5, "why is\tthis\nfailing?"),
    );

    // Truncated at 60 bytes with an ellipsis.
    const a70: [70]u8 = @splat('a');
    try testing.expectEqualStrings(
        "ghostty-ai: 2 commands — " ++ a70[0..60] ++ "…",
        try formatTitle(&buf, 2, &a70),
    );

    // Truncation never splits a codepoint. "é" is 2 bytes, so 30 of them
    // fill the 60 bytes exactly.
    const e31_pairs: [31][2]u8 = @splat("é".*);
    const e31: *const [62]u8 = @ptrCast(&e31_pairs);
    try testing.expectEqualStrings(
        "ghostty-ai: 2 commands — " ++ e31[0..60] ++ "…",
        try formatTitle(&buf, 2, e31),
    );

    // With one ASCII byte first, the 60th byte is mid-codepoint, so only
    // 59 bytes fit.
    const ae31 = "a" ++ e31.*;
    try testing.expectEqualStrings(
        "ghostty-ai: 2 commands — " ++ ae31[0..59] ++ "…",
        try formatTitle(&buf, 2, ae31),
    );
}

test "shellCommand" {
    const testing = std.testing;
    const alloc = testing.allocator;

    {
        const cmd = (try shellCommand(alloc, .{ .shell = "llm \"$GHOSTTY_AI_NOTE\"" })).?;
        defer alloc.free(cmd);
        try testing.expectEqualStrings("llm \"$GHOSTTY_AI_NOTE\"", cmd);
    }
    {
        const cmd = (try shellCommand(alloc, .{ .direct = &.{ "llm", "it's $HOME" } })).?;
        defer alloc.free(cmd);
        try testing.expectEqualStrings("'llm' 'it'\\''s $HOME'", cmd);
    }
    try testing.expect(try shellCommand(alloc, .{ .shell = "  " }) == null);
    try testing.expect(try shellCommand(alloc, .{ .direct = &.{} }) == null);
}
