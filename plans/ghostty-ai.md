# ghostty-ai: plan

Debug your terminal history with an LLM. The user runs:

```
~/code/acme-api ❯ ghostty-ai 10 "I upgraded node yesterday. Why is this failing?"
```

Ghostty captures the last 10 commands and their full output into a private temp
file, then opens a split beside the current one running the user's configured
LLM tool with that file and the note. Ghostty only moves text; it never talks to
a provider or holds an API key.

This plan is the outcome of a design grilling session. Every decision below is
settled unless listed under "Open questions".

## Work structure

The work is split into independent workstreams that run in parallel against
frozen contracts (section "Contracts"). Each workstream touches a disjoint set
of files, so they can be developed in separate git worktrees and merged without
conflicts. Only the integration step touches `src/Surface.zig`.

```
            ┌─ WS-A  capture core (Screen.selectCommands)  ─┐
            ├─ WS-B  keybind parse (write_command_file)     ─┤
 Step 0 ────┼─ WS-C  OSC parser                             ─┼──► Step 2 ──► Step 3
 contracts  ├─ WS-D  shell functions (zsh, bash, fish)      ─┤   integrate   demo +
            ├─ WS-E  config options + docs                  ─┤   (Surface)   report
            ├─ WS-F  apprt new_split_command (core/mac/GTK) ─┤
            └─ WS-G  demo fixture (~/code/acme-api)         ─┘
```

| Workstream | Files touched | Depends on |
| --- | --- | --- |
| Step 0: contracts (done) | this file | nothing |
| WS-A capture core | `src/terminal/Screen.zig` (maybe `PageList.zig` helpers) | Step 0 |
| WS-B keybind parse | `src/input/Binding.zig` | Step 0 |
| WS-C OSC parser | `src/terminal/osc.zig`, `src/terminal/osc/parsers/ghostty.zig` (new), `src/terminal/stream.zig`, `src/termio/stream_handler.zig`, `src/apprt/surface.zig` (Message) | Step 0 |
| WS-D shell functions | `src/shell-integration/{zsh,bash,fish}/…` | Step 0 (OSC format) |
| WS-E config | `src/config/Config.zig` | Step 0 (names) |
| WS-F apprt split action | `src/apprt/action.zig`, `include/ghostty.h`, `src/apprt/embedded.zig`, `macos/…`, `src/apprt/gtk/…` | Step 0 (payload) |
| WS-G demo fixture | `~/code/acme-api` (outside repo) + a reset script | nothing |
| Step 2 integration | `src/Surface.zig`, `src/App.zig` | A–F |
| Step 3 demo + report | none (manual) | Step 2, G |

WS-G can start immediately, even before Step 0.

### Worktrees and merge order

- Each of WS-A through WS-F is developed in its own git worktree, on a branch
  cut from `ghostty-ai` after Step 0 is committed. WS-G lives outside the repo
  and needs no worktree.
- Merge the worktrees into `ghostty-ai` **one at a time**, rebasing each onto
  the current branch first so history stays linear. Run that workstream's
  targeted tests after each merge, so a breakage shows up at the merge that
  caused it.
- Merge order: **E** (config) → **A** (capture) → **C** (OSC) → **D** (shell) →
  **B** (keybind) → **F** (split action) → **Step 2** integration, done
  directly on `ghostty-ai`.
- Build cost: each worktree has its own `.zig-cache`, so its first build is
  cold. Only WS-F builds the macOS app. Every other workstream uses
  `-Demit-macos-app=false` and targeted `-Dtest-filter` runs.

### Stub convention

Zig switches must be exhaustive. A workstream that adds a new enum or union
case therefore won't compile until every switch over it handles the case:

- WS-B adds a binding action, which `Surface.performBindingAction` must handle.
- WS-C adds a surface message, which `Surface.handleMessage` must handle.
- WS-F adds an apprt action, which each apprt's `performAction` must handle.

Each of these workstreams adds a **minimal stub** wherever the compiler asks for
one, outside the files it owns. A stub either returns `false` (not performed)
or logs that the case is unimplemented and ignores it. Mark every stub with
`// ghostty-ai: stub, replaced in integration` so Step 2 can find them all with
grep. Stubs may cause one- or two-line merge conflicts in `Surface.zig`;
resolve them during the rebase. Step 2 replaces every stub with real handling.

## Step 0: contracts (frozen)

Each workstream codes against these. Changing one means updating this section
first and telling every workstream that depends on it.

### C0.1 Capture API (WS-A provides, Step 2 consumes)

In `src/terminal/Screen.zig`:

```zig
pub const SelectCommandsOptions = struct {
    /// When true, exclude the command at the active prompt, even if it
    /// is running. The OSC path uses this, because the active command is
    /// `ghostty-ai` itself. The keybind path leaves it false, so a
    /// running command counts as #1.
    exclude_active: bool = false,
};

/// Returns null when there are no prompt marks or the alternate screen
/// is active.
pub fn selectCommands(self: *Screen, count: u16, opts: SelectCommandsOptions) ?Selection
```

An idle current prompt, where nothing has been executed, is always excluded.

### C0.2 Keybind action (WS-B)

In `src/input/Binding.zig`:

```zig
write_command_file: WriteCommand,

pub const WriteCommand = struct {
    action: WriteScreen.Action,   // copy | paste | open
    emit: WriteScreen.Format,     // plain | vt | html; default .plain
    count: u16,                   // default 1, 0 is a parse error
};
```

The field is named `emit` to match `WriteScreen`. Syntax:
`write_command_file:<action>[,<format>][,<count>]`. Each argument after the
action is recognized by its type (format enum or integer), so `copy,5` works.

### C0.3 OSC wire format (WS-C parses, WS-D emits)

```
ESC ] 6767 ; ai ; count=<n> ; note=<base64> ST
```

- **Number: 6767.** It is not defined by xterm (which uses numbers up to 119),
  WezTerm, mintty (`440`, `701`, `77xx`, `77119`), iTerm2 (`1337`), kitty
  (`5113`, `5522`, `30001`, `30101`, plus low numbers), VS Code (`633`),
  ConEmu (`9`), rxvt (`7xx`), or the `3008`/`7501` specs that Ghostty
  already parses. A web search for "OSC 6767" finds nothing. There is no
  formal OSC registry (terminal-wg issue #10 asks for one), so this is a best
  effort check.
- **Namespace:** the first field (`ai`) is a subcommand. Any future
  Ghostty-private request reuses `6767` with a new subcommand. An unknown
  subcommand is ignored and logged.
- **Fields:** `key=value` pairs separated by `;`, in any order. Each key may
  appear at most once.
  - `count` is required, a decimal integer from 1 to 99.
  - `note` is optional, standard base64 (RFC 4648, padded), and must decode
    to valid UTF-8 of at most **255 bytes**. An empty or missing note means
    no note.
  - Unknown keys are ignored, which leaves room for later additions.
  - A duplicate key, a malformed count, bad base64, invalid UTF-8, or an
    oversized note makes the request invalid. Invalid requests are dropped
    and logged.
- **Terminators:** both ST (`ESC \`) and BEL are accepted, as with other OSCs.
  The shell functions emit ST.
- **Note limit:** the shell function rejects a note longer than 255 bytes
  with an error on stderr, instead of truncating it silently. 255 bytes
  matches `DesktopNotification.body` and keeps the surface message
  fixed-size.

### C0.4 Surface message (WS-C produces, Step 2 consumes)

**Changed in Step 2.** The original fixed-size `{ count, note }` message
raced: the OSC is parsed on the IO thread, but the app thread handles the
message later, by which time the shell has usually drawn its next prompt.
The active command is then no longer `ghostty-ai`, so both the plausibility
check and `exclude_active` would look at the wrong command.

The IO thread (`termio/stream_handler.zig`) therefore checks
`ghostty-ai-access` and plausibility, and captures the commands while it
holds the terminal lock. It then sends an owned pointer, following the
`kitty_clipboard_write` pattern:

```zig
ghostty_ai_request: *GhosttyAiRequest,   // receiver must destroy()

pub const GhosttyAiRequest = struct {
    alloc: Allocator,
    count: u8,                  // 1-99, already validated by the parser
    note: [255:0]u8,            // UTF-8, NUL-terminated, may be empty
    capture: ghostty_ai.Capture, // .text (header + plain text), .alternate_screen, .no_commands
};
```

### C0.5 apprt action (WS-F provides, Step 2 consumes)

The C action union must stay at most 24 bytes (an assertion in
`src/apprt/action.zig` checks this). So the payload is a direction plus a
pointer to a details struct, not the strings themselves:

```zig
new_split_command: NewSplitCommand,

pub const NewSplitCommand = struct {
    direction: SplitDirection,
    command: [:0]const u8,       // run via /bin/sh -c
    env: []const EnvVar,         // { key: [:0]const u8, value: [:0]const u8 }
    title: [:0]const u8,         // becomes the user title override

    pub const C = extern struct {
        direction: SplitDirection,
        details: *const Details,
    };
    pub const Details = extern struct {
        command: [*:0]const u8,
        env_vars: [*]const EnvVar.C,   // same layout as ghostty_env_var_s
        env_var_count: usize,
        title: [*:0]const u8,
    };
};
```

C mirror in `include/ghostty.h`: `ghostty_action_new_split_command_s` and
`ghostty_action_new_split_command_details_s`, reusing the existing
`ghostty_env_var_s`. Every pointer is valid only for the duration of the
`performAction` call, so the apprt copies whatever it keeps. This is the same
rule `open_url` follows.

### C0.6 Config (WS-E)

In `src/config/Config.zig`:

```zig
@"ghostty-ai-command": ?Command = <default from WS-E>,
@"ghostty-ai-access": GhosttyAiAccess = .allow,

pub const GhosttyAiAccess = enum { allow, deny };
```

`Command` is the existing `src/config/command.zig` type. The default uses the
`shell:` form, so `$GHOSTTY_AI_*` expand.

### C0.7 Environment for the child (Step 2 sets, WS-F passes through)

| Variable | Value |
| --- | --- |
| `GHOSTTY_AI_FILE` | absolute path of the 0600 capture file |
| `GHOSTTY_AI_NOTE` | the decoded note, possibly empty |
| `GHOSTTY_AI_PARENT` | decimal id used for one-at-a-time tracking; private |

### C0.8 Stub marker

Every stub is marked `// ghostty-ai: stub, replaced in integration`.

## Layer 1: capture core and keybind

### WS-A: `Screen.selectCommands(count)`

- Walk prompt marks backwards with `PageList.promptIterator`, starting from the
  active prompt or cursor.
- The selection starts at the prompt `count` commands back and runs to the end
  of the most recent output. It is one contiguous selection.
- A **running** command (output streaming, no new prompt yet) counts as #1, and
  its partial output up to the cursor is included.
- An **idle** current prompt (nothing executed) is excluded.
- If fewer than `count` commands exist, capture what exists.
- Return `null` when there are no prompt marks or the screen is the alternate
  screen.
- Use `highlightSemanticContent` to find the boundaries between prompt, input
  and output.

Tests (required): count = 1, count larger than the history, soft-wrapped
output, no shell integration. Extra tests: running command, idle prompt
excluded.

### WS-B: `write_command_file:<copy|paste|open>[,<plain|vt|html>][,<count>]`

- Classify each comma-separated argument by type (action enum, format enum,
  integer), so `copy,5` works without spelling out `plain`.
- Defaults: format `plain`, count `1`.
- `count` is a `u16`. `0` is a parse error. There is no upper cap.
- `write_screen_file` and its siblings keep parsing exactly as before.
- Parse tests sit next to the existing `write_screen_file:copy,html` tests.

## Layer 2: the ghostty-ai request

### WS-C: OSC parser and routing

- New parser in `src/terminal/osc/parsers/`, modelled on `semantic_prompt.zig`.
- Tests: valid input; bad base64; missing or duplicate fields; count outside
  1–99; unknown subcommand.
- Routing follows the desktop notification path: parser → `stream.zig` →
  `termio/stream_handler.zig` → `surfaceMessageWriter` → `Surface.handleMessage`.
- libghostty-vt's `stream_terminal.zig` treats the request as an unimplemented
  callback for now.

### WS-D: `ghostty-ai` shell function (zsh, bash, fish)

- Usage: `ghostty-ai [count] [note...]`. The default count is **5**.
- The first argument is a count only if it is a whole number from 1 to 99.
  Anything else (`404`, `2fa`, `-3`) starts the note.
- `--` ends option parsing, so everything after it is the note.
- The function base64-encodes the note, emits the OSC, and returns.
- It does not send the cwd. Ghostty already knows it (OSC 7).
- The function is named `ghostty-ai` with no leading slash; `/ghostty-ai` would
  resolve to a file path.

## Layer 3: launch the configured tool in a split

### WS-E: config

```ini
ghostty-ai-command = claude --tools "" --append-system-prompt "$(cat "$GHOSTTY_AI_FILE")" "$GHOSTTY_AI_NOTE"
ghostty-ai-access = allow   # allow | deny
```

- Document both options in the same doc-comment style as the options around
  them.
- `--tools ""` disables every Claude tool, so the default can only give text
  advice. (Verified against `claude --help`.)
- Document the known limitation: Linux allows roughly 128 KB per argument, and
  a very large capture can exceed it.
- Document that pointing `ghostty-ai-command` at an agent that can run commands
  accepts more risk.
- `ghostty-ai-access` gates only the OSC request, never the keybind.
- Describe `ask` (a confirmation dialog like the one behind
  `clipboard-read = ask`) as the probable upstream default and as future work.
  Cite the precedent of `title-report` being disabled by default for this class
  of risk.

### WS-F: apprt `new_split_command`

- `new_split` can't take a command today: its payload is only a
  `SplitDirection`, and that type is part of the C ABI. Add a separate,
  internal-only action instead of changing it, so libghostty embedders are not
  broken. Users can't bind the new action in v1.
- **macOS:** map the action to `SurfaceConfiguration` (which already has
  `command` and `environmentVariables`; see the AppleScript `split …
  configuration` precedent), then call `BaseTerminalController.newSplit`. Set
  `titleOverride` on the new view.
- **GTK:** add `env` to `Overrides` and call
  `SplitTree.newSplit(direction, parent, overrides)`. `Overrides.title` becomes
  `title_override`.
- Commands run through `/bin/sh -c`, so `$GHOSTTY_AI_*` expand inside the child
  and the note is never spliced into the command string.
- With a command set, `wait-after-command` is forced on, so the split stays
  open after the tool exits.

## Step 2: integration (`Surface.zig`, `App.zig`)

1. Add `WriteScreenLoc.command` and wire the `write_command_file` keybind
   through the existing `writeScreenFile` (temp file, 0600, formatter,
   copy/paste/open).
2. Handle `ghostty_ai_request` with these checks, in order:
   1. `ghostty-ai-access = deny`: refuse.
   2. **Plausibility:** read the active command's input cells
      (`highlightSemanticContent(.input)`). Trim leading whitespace; the text
      must equal `ghostty-ai` or start with `ghostty-ai ` (followed by a space).
      If the input cells are missing, refuse.
   3. **One at a time:** if a split launched by this surface is still open,
      refuse.
   4. No prompt marks, or the alternate screen: refuse.
3. **Refusals:** if the request passed the plausibility check, show a desktop
   notification (`ghostty-ai request refused: <reason>`) through the existing
   rate-limited `showDesktopNotification`. If it failed the check, which is the
   likely spoof case, only log it. Never write anything to the pty.
4. **Capture:** `selectCommands(count)` on the originating surface, excluding
   the active `ghostty-ai` command. Write plain text with this header:
   `# Terminal history captured by Ghostty (last N commands, cwd <pwd>)`. The
   note is not written to the file.
5. **Launch:** perform `new_split_command` with:
   - direction: right
   - command: `ghostty-ai-command`
   - env: `GHOSTTY_AI_FILE`, `GHOSTTY_AI_NOTE`, `GHOSTTY_AI_PARENT=<id>`
   - title: `ghostty-ai: N commands — <note truncated to ~60 chars>`
   - cwd: inherited
6. **One-at-a-time tracking:** the parent stores a monotonic request id and an
   "AI split open" flag. When the child's core Surface deinits, it reads
   `GHOSTTY_AI_PARENT`, finds the parent in `App.surfaces` (nothing happens if
   the parent is gone), clears the flag, and deletes the capture temp dir.

## Security model (decided)

- Any program's output can contain the OSC bytes, for example `cat evil.txt`,
  `curl`, or a process on a remote SSH host. We accept that residual risk
  because the default tool is text-only. An attacker can't choose where the
  history goes; the worst case is the user's history going to the user's own
  provider, plus misleading advice.
- The cheap guards are: the plausibility check, one split at a time, the
  visible title that the child can't overwrite, `ghostty-ai-access`, and the
  0600 capture file deleted when the split closes.

## Step 3: demo and verification

- **WS-G fixture:** an offline, resettable Node project at `~/code/acme-api`:
  - a local bare "upstream" repo, so `git pull` brings in a commit bumping a
    vendored dependency from v1 to v2;
  - v2 renames `createSession`, so `npm test` fails with
    `client.createSession is not a function`;
  - a reset script.
- **Demo script:**
  1. `git pull` → `git log -1 --oneline` → `npm install` → `npm run build` →
     `npm test` (fails)
  2. `ghostty-ai 5 "why is this failing?"`: the answer identifies the
     major-version bump.
  3. Contrast: `ghostty-ai 1 …` sees only the test failure and can only guess.
- Verify the split launch by hand in the built macOS app and record the steps
  in the report.
- GTK is verified only by compiling it, and the report says so.

## Process

- Local branch `ghostty-ai`. One commit per workstream, merged in the order
  under "Worktrees and merge order"; integration is its own commit.
- No issues or PRs. AI assistance is disclosed per `AI_POLICY.md`.
- The user writes the "why users will like this" summary themselves.
- The final report follows the brief: changes file by file, how the capture
  walks prompt marks, test results, how the split launch works, open questions,
  follow-ups.

## Open questions

- None blocking. OSC 6767 is a best-effort pick because no registry exists.
  Upstream may prefer a different number during design discussion.

## Follow-ups (out of scope for v1)

- `ghostty-ai-access = ask` confirmation dialog (native UI in both apps)
- A `--lines` unit
- Per-command output caps
- Secret redaction
- `adjust_selection:previous_command`
- Making `new_split_command` a public keybind action
- ssh and tmux passthrough of the request
