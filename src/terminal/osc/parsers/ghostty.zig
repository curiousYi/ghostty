//! OSC 6767: Ghostty-private requests
//!
//! The first field after the number names a subcommand. Every
//! Ghostty-private request shares this number and adds its own
//! subcommand. An unknown subcommand is ignored and logged.
//!
//! The only subcommand today is `ai`, which the `ghostty-ai` shell
//! function sends to ask Ghostty to hand the last few commands to the
//! configured LLM tool:
//!
//! ```
//! ESC ] 6767 ; ai ; count=<n> ; note=<base64> ST
//! ```
//!
//! The fields after the subcommand are `key=value` pairs separated by `;`,
//! in any order. Each key may appear at most once.
//!
//! - `count` is required, a decimal integer from 1 to 99.
//! - `note` is optional, standard padded base64 (RFC 4648) that must
//!   decode to valid UTF-8 of at most `max_note_bytes` bytes. An empty
//!   note is the same as no note.
//! - Unknown keys are ignored, so later versions can add keys.
//!
//! A duplicate key, a malformed count, bad base64, invalid UTF-8, or an
//! oversized note makes the whole request invalid. Invalid requests are
//! dropped and logged.
//!
//! Example:
//!
//! ```zig
//! var p: osc.Parser = .init(null);
//! p.nextSlice("6767;ai;count=3;note=aGk=");
//! const req = p.end('\x1b').?.ghostty_ai;
//! req.count; // 3
//! req.note; // "hi"
//! ```

const std = @import("std");
const lib = @import("../../lib.zig");
const osc = @import("../../osc.zig");

const assert = @import("../../../quirks.zig").inlineAssert;
const Parser = osc.Parser;
const OSCCommand = osc.Command;

const log = std.log.scoped(.osc_ghostty);

/// The longest note after base64 decoding, in bytes. This matches the
/// fixed-size body of a desktop notification so the surface message
/// that carries the note stays fixed-size.
pub const max_note_bytes = 255;

/// The smallest and largest `count`.
pub const min_count = 1;
pub const max_count = 99;

/// A valid `ai` request.
pub const Ai = struct {
    /// How many commands to capture, from `min_count` to `max_count`.
    count: u8,

    /// The decoded note: valid UTF-8, at most `max_note_bytes` bytes,
    /// possibly empty. This points into the parser's buffer and is only
    /// valid until the next parser call.
    note: []const u8,

    pub const C = extern struct {
        count: u8,
        note: lib.String,
    };

    pub fn cval(self: Ai) Ai.C {
        return .{
            .count = self.count,
            .note = .init(self.note),
        };
    }
};

const Error = error{
    DuplicateKey,
    MissingCount,
    InvalidCount,
    InvalidNote,
    NoteTooLong,
};

/// Parse an OSC 6767 sequence. Returns null, and marks the parser
/// invalid, for an unknown subcommand or an invalid request.
pub fn parse(parser: *Parser, _: ?u8) ?*OSCCommand {
    assert(parser.state == .@"6767");

    const cap = if (parser.capture) |*c| c else {
        parser.state = .invalid;
        return null;
    };

    const data = cap.trailing();
    const sep = std.mem.indexOfScalar(u8, data, ';');
    const subcommand = data[0 .. sep orelse data.len];
    const fields = if (sep) |i| data[i + 1 ..] else data[data.len..];

    if (std.mem.eql(u8, subcommand, "ai")) {
        const ai = parseAi(fields) catch |err| {
            log.warn("invalid OSC 6767 ai request err={}", .{err});
            parser.state = .invalid;
            return null;
        };

        parser.command = .{ .ghostty_ai = ai };
        return &parser.command;
    }

    log.warn("unknown OSC 6767 subcommand, ignoring len={d}", .{subcommand.len});
    parser.state = .invalid;
    return null;
}

/// Parse and validate the fields of an `ai` request. The note is decoded
/// in place, over its own base64 text in `fields`, which is always long
/// enough because decoding shrinks the data.
fn parseAi(fields: []u8) Error!Ai {
    // Each key may appear at most once, including keys we don't know.
    // Fields are bounded by the parser's fixed buffer, so the quadratic
    // scan is bounded too, and it stops at the first duplicate.
    var outer = std.mem.splitScalar(u8, fields, ';');
    while (outer.next()) |field| {
        if (field.len == 0) continue;
        const key = keyOf(field);
        var inner = outer;
        while (inner.next()) |other| {
            if (other.len == 0) continue;
            if (std.mem.eql(u8, key, keyOf(other))) return error.DuplicateKey;
        }
    }

    var count_value: ?[]const u8 = null;
    var note_value: ?[]u8 = null;
    var it = std.mem.splitScalar(u8, fields, ';');
    while (it.next()) |field| {
        if (field.len == 0) continue;
        const key = keyOf(field);
        if (std.mem.eql(u8, key, "count")) {
            // A count with no `=` is malformed.
            if (key.len == field.len) return error.InvalidCount;
            count_value = field[key.len + 1 ..];
        } else if (std.mem.eql(u8, key, "note")) {
            if (key.len == field.len) return error.InvalidNote;
            // The split iterator yields const slices of our mutable
            // buffer. Recover the mutable slice by its offset.
            const offset = @intFromPtr(field.ptr) - @intFromPtr(fields.ptr);
            note_value = fields[offset + key.len + 1 ..][0 .. field.len - key.len - 1];
        }
        // Unknown keys are ignored.
    }

    const count = try parseCount(count_value orelse return error.MissingCount);
    const note: []const u8 = if (note_value) |v| try decodeNote(v) else "";
    return .{ .count = count, .note = note };
}

/// The key of a `key=value` field, or the whole field if it has no `=`.
fn keyOf(field: []const u8) []const u8 {
    const eq = std.mem.indexOfScalar(u8, field, '=') orelse return field;
    return field[0..eq];
}

/// Parse a decimal count from `min_count` to `max_count`. Only ASCII
/// digits are accepted, so signs, spaces and underscores are rejected.
fn parseCount(value: []const u8) Error!u8 {
    if (value.len == 0) return error.InvalidCount;
    // At most max_count * 10 + 9 before the range check, so u16 can't
    // overflow.
    var n: u16 = 0;
    for (value) |c| {
        const digit = std.fmt.charToDigit(c, 10) catch return error.InvalidCount;
        n = n * 10 + digit;
        if (n > max_count) return error.InvalidCount;
    }
    if (n < min_count) return error.InvalidCount;
    return @intCast(n);
}

/// Decode a base64 note in place and check that it is valid UTF-8 within
/// `max_note_bytes`. Returns the decoded note, a prefix of `value`.
fn decodeNote(value: []u8) Error![]const u8 {
    if (value.len == 0) return "";

    const decoder = std.base64.standard.Decoder;
    const len = decoder.calcSizeForSlice(value) catch return error.InvalidNote;
    if (len > max_note_bytes) return error.NoteTooLong;

    // Decode into a separate buffer first: the decoder doesn't promise
    // that its source and destination may overlap.
    var buf: [max_note_bytes]u8 = undefined;
    const decoded = buf[0..len];
    decoder.decode(decoded, value) catch return error.InvalidNote;
    if (!std.unicode.utf8ValidateSlice(decoded)) return error.InvalidNote;

    // Decoding shrinks the data, so the note fits over its encoding.
    assert(len <= value.len);
    @memcpy(value[0..len], decoded);
    return value[0..len];
}

const testing = std.testing;

/// Feed `input` to a fresh parser and end it with `terminator`.
fn testParse(p: *Parser, input: []const u8, terminator: ?u8) ?*OSCCommand {
    p.reset();
    for (input) |ch| p.next(ch);
    return p.end(terminator);
}

test "OSC 6767: ai with count only" {
    var p: Parser = .init(null);
    defer p.deinit();

    const cmd = testParse(&p, "6767;ai;count=5", '\x1b').?.*;
    try testing.expect(cmd == .ghostty_ai);
    try testing.expectEqual(@as(u8, 5), cmd.ghostty_ai.count);
    try testing.expectEqualStrings("", cmd.ghostty_ai.note);
}

test "OSC 6767: ai with count and note" {
    var p: Parser = .init(null);
    defer p.deinit();

    // "why is this failing?"
    const cmd = testParse(
        &p,
        "6767;ai;count=10;note=d2h5IGlzIHRoaXMgZmFpbGluZz8=",
        '\x1b',
    ).?.*;
    try testing.expectEqual(@as(u8, 10), cmd.ghostty_ai.count);
    try testing.expectEqualStrings("why is this failing?", cmd.ghostty_ai.note);
}

test "OSC 6767: ai fields in any order" {
    var p: Parser = .init(null);
    defer p.deinit();

    const cmd = testParse(&p, "6767;ai;note=aGk=;count=99", '\x1b').?.*;
    try testing.expectEqual(@as(u8, 99), cmd.ghostty_ai.count);
    try testing.expectEqualStrings("hi", cmd.ghostty_ai.note);
}

test "OSC 6767: ai with BEL and ST terminators" {
    var p: Parser = .init(null);
    defer p.deinit();

    const bel = testParse(&p, "6767;ai;count=1;note=aGk=", 0x07).?.*;
    try testing.expectEqual(@as(u8, 1), bel.ghostty_ai.count);
    try testing.expectEqualStrings("hi", bel.ghostty_ai.note);

    const st = testParse(&p, "6767;ai;count=1;note=aGk=", '\x1b').?.*;
    try testing.expectEqual(@as(u8, 1), st.ghostty_ai.count);
    try testing.expectEqualStrings("hi", st.ghostty_ai.note);

    // The whole sequence through the stream parser, with nextSlice.
    p.reset();
    p.nextSlice("6767;ai;count=2;note=aGk=");
    const slice = p.end(0x07).?.*;
    try testing.expectEqual(@as(u8, 2), slice.ghostty_ai.count);
    try testing.expectEqualStrings("hi", slice.ghostty_ai.note);
}

test "OSC 6767: ai with empty note" {
    var p: Parser = .init(null);
    defer p.deinit();

    const cmd = testParse(&p, "6767;ai;count=3;note=", '\x1b').?.*;
    try testing.expectEqual(@as(u8, 3), cmd.ghostty_ai.count);
    try testing.expectEqualStrings("", cmd.ghostty_ai.note);
}

test "OSC 6767: ai with UTF-8 note" {
    var p: Parser = .init(null);
    defer p.deinit();

    var enc_buf: [64]u8 = undefined;
    const encoded = std.base64.standard.Encoder.encode(&enc_buf, "héllo Я 🚀");

    var input_buf: [128]u8 = undefined;
    const input = try std.fmt.bufPrint(&input_buf, "6767;ai;count=4;note={s}", .{encoded});
    const cmd = testParse(&p, input, '\x1b').?.*;
    try testing.expectEqualStrings("héllo Я 🚀", cmd.ghostty_ai.note);
}

test "OSC 6767: ai ignores unknown keys and empty fields" {
    var p: Parser = .init(null);
    defer p.deinit();

    const cmd = testParse(&p, "6767;ai;future=1;count=7;;flag;note=aGk=;", '\x1b').?.*;
    try testing.expectEqual(@as(u8, 7), cmd.ghostty_ai.count);
    try testing.expectEqualStrings("hi", cmd.ghostty_ai.note);
}

test "OSC 6767: ai bad base64" {
    var p: Parser = .init(null);
    defer p.deinit();

    // Invalid character
    try testing.expect(testParse(&p, "6767;ai;count=1;note=a*k=", '\x1b') == null);
    // Missing padding: the contract requires padded base64
    try testing.expect(testParse(&p, "6767;ai;count=1;note=aGk", '\x1b') == null);
    // Wrong length
    try testing.expect(testParse(&p, "6767;ai;count=1;note=a", '\x1b') == null);
}

test "OSC 6767: ai invalid UTF-8 note" {
    var p: Parser = .init(null);
    defer p.deinit();

    // 0xFF 0xFE is never valid UTF-8.
    try testing.expect(testParse(&p, "6767;ai;count=1;note=//4=", '\x1b') == null);
}

test "OSC 6767: ai missing count" {
    var p: Parser = .init(null);
    defer p.deinit();

    try testing.expect(testParse(&p, "6767;ai", '\x1b') == null);
    try testing.expect(testParse(&p, "6767;ai;", '\x1b') == null);
    try testing.expect(testParse(&p, "6767;ai;note=aGk=", '\x1b') == null);
}

test "OSC 6767: ai count out of range or malformed" {
    var p: Parser = .init(null);
    defer p.deinit();

    const bad = [_][]const u8{
        "6767;ai;count=0",
        "6767;ai;count=00",
        "6767;ai;count=100",
        "6767;ai;count=255",
        "6767;ai;count=256",
        "6767;ai;count=99999999999",
        "6767;ai;count=",
        "6767;ai;count",
        "6767;ai;count=abc",
        "6767;ai;count=5x",
        "6767;ai;count=-3",
        "6767;ai;count=+3",
        "6767;ai;count= 3",
        "6767;ai;count=1_0",
    };
    for (bad) |input| {
        if (testParse(&p, input, '\x1b') != null) {
            std.log.err("accepted: {s}", .{input});
            return error.TestUnexpectedResult;
        }
    }

    try testing.expectEqual(@as(u8, 1), testParse(&p, "6767;ai;count=1", '\x1b').?.ghostty_ai.count);
    try testing.expectEqual(@as(u8, 99), testParse(&p, "6767;ai;count=99", '\x1b').?.ghostty_ai.count);
}

test "OSC 6767: ai duplicate keys" {
    var p: Parser = .init(null);
    defer p.deinit();

    try testing.expect(testParse(&p, "6767;ai;count=1;count=2", '\x1b') == null);
    try testing.expect(testParse(&p, "6767;ai;count=1;note=aGk=;note=aGk=", '\x1b') == null);
    try testing.expect(testParse(&p, "6767;ai;count=1;note=;note=aGk=", '\x1b') == null);
    try testing.expect(testParse(&p, "6767;ai;x=1;count=1;x=2", '\x1b') == null);
}

test "OSC 6767: unknown subcommand" {
    var p: Parser = .init(null);
    defer p.deinit();

    try testing.expect(testParse(&p, "6767;foo;count=1", '\x1b') == null);
    try testing.expect(testParse(&p, "6767;AI;count=1", '\x1b') == null);
    try testing.expect(testParse(&p, "6767;", '\x1b') == null);
    try testing.expect(testParse(&p, "6767", '\x1b') == null);
    try testing.expect(testParse(&p, "676;ai;count=1", '\x1b') == null);
}

/// Build "6767;ai;count=1;note=<base64 of n bytes of 'a'>" into `buf`.
fn noteOfLen(buf: []u8, n: usize) ![]const u8 {
    var raw: [max_note_bytes + 1]u8 = undefined;
    @memset(raw[0..n], 'a');
    const prefix = "6767;ai;count=1;note=";
    @memcpy(buf[0..prefix.len], prefix);
    const encoded = std.base64.standard.Encoder.encode(buf[prefix.len..], raw[0..n]);
    return buf[0 .. prefix.len + encoded.len];
}

test "OSC 6767: ai note of exactly max_note_bytes is accepted" {
    var p: Parser = .init(null);
    defer p.deinit();

    var buf: [512]u8 = undefined;
    const input = try noteOfLen(&buf, max_note_bytes);
    const cmd = testParse(&p, input, '\x1b').?.*;
    try testing.expectEqual(@as(usize, max_note_bytes), cmd.ghostty_ai.note.len);
    for (cmd.ghostty_ai.note) |c| try testing.expectEqual(@as(u8, 'a'), c);
}

test "OSC 6767: ai note over max_note_bytes is rejected" {
    var p: Parser = .init(null);
    defer p.deinit();

    var buf: [512]u8 = undefined;
    const input = try noteOfLen(&buf, max_note_bytes + 1);
    try testing.expect(testParse(&p, input, '\x1b') == null);
}

test "OSC 6767: parser still works after an invalid request" {
    var p: Parser = .init(null);
    defer p.deinit();

    try testing.expect(testParse(&p, "6767;ai;count=0", '\x1b') == null);
    const cmd = testParse(&p, "6767;ai;count=2", '\x1b').?.*;
    try testing.expectEqual(@as(u8, 2), cmd.ghostty_ai.count);
}
