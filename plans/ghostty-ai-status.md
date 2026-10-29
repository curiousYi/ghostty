# ghostty-ai: status and handoff

Status as of 2026-10-29. Read `plans/ghostty-ai.md` first: it holds the design,
the frozen Step 0 contracts and the work structure. This note says what is
done, what is decided since the plan, and what is next.

## Summary

- Step 0 (contracts) and workstreams A–G are done.
- A–F are merged into the local branch `ghostty-ai`. G (the demo fixture)
  lives outside the repo.
- **Step 2 (integration) is done** (see "Step 2: integration (done)").
  Step 3 (demo and report) is next.
- Neither the macOS app nor GTK has been built. See "Environment".

## Branch `ghostty-ai`

The merge order followed the plan (E → A → C → D → B → F). Each commit was
cherry-picked from its workstream branch.

| Commit | Workstream | What it adds |
| --- | --- | --- |
| `a948f7eed` | E config | `ghostty-ai-command`, `ghostty-ai-access`, and their docs |
| `a5c5328e8` | A capture | `Screen.selectCommands` and 14 tests |
| `fb0f3f673` | C OSC | the OSC 6767 parser, routed through to the surface message |
| `8f0722b50` | D shell | the `ghostty-ai` function for zsh, bash and fish |
| `cf242a9be` | B keybind | `write_command_file` parsing |
| `1672a80c7` | F apprt | the internal `new_split_command` action for macOS and GTK |

The workstream branches (`ws-a-capture` … `ws-f-split`) and their worktrees
under `.claude/worktrees/` still exist and can be deleted. `.claude/` is
untracked.

## What each piece does

### A: `Screen.selectCommands(count, .{ .exclude_active })` (`src/terminal/Screen.zig`)

It returns one contiguous selection covering the last `count` commands:

1. Walk up from the cursor with `promptIterator(.left_up)`. The first prompt
   found is the active command.
2. Decide whether that command is idle or running, using the same rule as
   `Terminal.cursorIsAtPrompt`. An idle command, or any command when
   `exclude_active` is set, is skipped. A running command counts as #1.
3. Keep stepping up to older prompts until `count` commands are found or the
   prompts run out.
4. The selection runs from that prompt's first row to the end of the latest
   output, with trailing blanks trimmed. Soft-wrapped rows come along
   automatically.

It returns null when:

- `count` is 0;
- there are no prompt marks;
- excluding the active command leaves nothing.

Differences from the plan:

- It does not use `highlightSemanticContent`.
- **`Screen` cannot know whether it is the alternate screen, so the caller
  must check `screens.active_key == .alternate`.**

Known limitation: if a shell emits OSC 133;C before the newline, a running
command looks idle.

### B: `write_command_file:<copy|paste|open>[,<plain|vt|html>][,<count>]` (`src/input/Binding.zig`)

- Arguments after the action are classified by type, so they can come in any
  order.
- Giving the same kind twice is an error.
- `count` is a `u16`, defaults to 1, and 0 is an error. Leading zeros are
  accepted.
- Formatting a binding always prints all three fields.
- Stub: `src/Surface.zig:5455` returns `false`.

### C: OSC 6767 (`src/terminal/osc/parsers/ghostty.zig` and routing)

- Format: `ESC ] 6767 ; ai ; count=N ; note=<base64> ST|BEL`.
- Path: parser → `Command.ghostty_ai` → stream action `ghostty_ai_request` →
  `termio/stream_handler.zig` → `apprt.surface.Message.ghostty_ai_request { count: u8, note: [255:0]u8 }`
  → `Surface.handleMessage`.
- Stub: `src/Surface.zig:1154` only logs the request.
- libghostty-vt (`stream_terminal.zig`) logs the request as unimplemented.
- Also touched: `include/ghostty/vt/osc.h`, which gains
  `GHOSTTY_OSC_COMMAND_GHOSTTY_AI = 29`.
- Rules that go beyond the contract:
  - A `count` or `note` without `=` makes the request invalid. Other bare words
    are ignored.
  - A count of `07` is accepted as 7.
  - Base64 must be padded.
  - A duplicate key is rejected, even an unknown one.
- The parser allocates nothing. It decodes the note back into the existing
  2048-byte OSC buffer.

### D: the `ghostty-ai` shell function (`src/shell-integration/{bash,zsh,fish}`)

- The first argument is a count only if it matches `^[1-9][0-9]?$`, so `05`,
  `404` and `2fa` are note text. The default count is 5.
- `--` is honoured only first or right after a count.
- `-h`/`--help` prints usage only as the first argument.
- The function errors if the note is over 255 bytes, and leaves out `;note=`
  when the note is empty.
- zsh writes to `$_ghostty_fd` (the tty). bash and fish write to stdout, like
  their other sequences.
- The function is currently always defined. Q25 below changes that.
- Test script (not in the repo; it lives in the original session's scratch
  directory and may be gone):
  `/private/tmp/claude-501/-Users-yichao-github-ghostty/a37383c5-613e-4b7b-8125-25b9e4d20543/scratchpad/test_ghostty_ai.py`.
  It passed 30/30 cases on zsh 5.9 and bash 3.2 (macOS), and on zsh, bash 5.2
  and fish 3.7.1 (Alpine with GNU base64). fish 4.x is untested.

### E: config (`src/config/Config.zig`)

- The default `ghostty-ai-command` (shell form):
  `claude --tools "" --append-system-prompt "$(cat "$GHOSTTY_AI_FILE")" "$GHOSTTY_AI_NOTE"`.
  - The flags were checked against `claude --help` for version 2.1.312.
  - **`--tools` takes any number of values, so it must not come directly
    before the note.**
- `ghostty-ai-access` defaults to `allow`.
- The docs cover the `title-report` precedent, the risk of pointing the
  command at an agent that can execute commands, and the Linux limit of about
  128 KB per argument.

### F: the `new_split_command` apprt action

- **Core:**
  - `src/apprt/action.zig` adds `NewSplitCommand`, `EnvVar` and `CStorage`.
    The new tag is last, so existing action numbers don't change.
  - `include/ghostty.h` adds the matching C structs.
  - `embedded.performAction` builds the C payload in a `CStorage` on its own
    stack, so the pointers are valid only during the callback.
  - `Action.cval` has an `unreachable` branch for this action.
- **macOS (`Ghostty.App.swift`):**
  1. Copies the strings.
  2. Gets the inherited split config and sets the command and env.
  3. Calls `BaseTerminalController.newSplit(at:direction:baseConfig:)`, as the
     AppleScript path does.
  4. Sets `titleOverride` on the new view.
- **GTK:**
  - `Overrides` gains `env` and `wait_after_command`.
  - The surface deep-copies the env into `config.env`.
  - `SplitTree.newSplit` now passes all overrides through.
- **Caveat:** on GTK the split opens next to the tree's *focused* surface,
  not necessarily the one that sent the request.

### G: demo fixture (outside the repo)

- `~/code/acme-api`, reset by `~/code/.acme-api-fixture/reset.sh` (offline and
  idempotent).
- After a reset, the 4 tests pass.
- `git pull` brings in
  `c9f40d6 chore(deps): bump @acme/session-client from 1.4.2 to 2.0.0`, after
  which `npm test` fails with `TypeError: client.createSession is not a function`.
- Verified by re-running reset → pull → install → test → reset.

## Test results on the merged branch (`1672a80c7`)

All runs used `-Demit-macos-app=false -Demit-xcframework=false`. All passed.

| Filter | Result |
| --- | --- |
| build | 67/67 steps |
| `config` | 270/273 passed, 3 skipped |
| `selectCommands` | 91/91; libghostty-vt 95/95 |
| `osc` | 462/463 passed, 1 skipped; libghostty-vt 846/850 passed, 4 skipped |
| `6767` | 94/94 |
| `GhosttyAiRequest` | 78/78 |
| `write_command_file` | 82/82 |
| `parse:` | 126/126 |
| `ghostty.h` | 99/99 |
| `NewSplitCommand` | 78/78 |

A filter that matches nothing still runs 77 baseline tests.

## Decisions made after the plan

- **Q25: yes.** Add a `ghostty-ai` feature to `shell-integration-features`,
  enabled by default, and gate the function on it in all three shells, the way
  `sudo` and `ssh-*` are gated.
- **Q26: yes.** bash and fish keep writing the sequence to stdout, matching
  their other sequences. `ghostty-ai > file` then fails safe: nothing opens.
- **Q27: yes.**
  - In Step 2, reject a note that contains control bytes other than tab and
    newline. A request that passed the plausibility check gets a desktop
    notification; one that failed it is only logged.
  - In the split title only, replace tab and newline with a space.
    `GHOSTTY_AI_NOTE` keeps newlines.
- **An empty or null `ghostty-ai-command`** is treated as a refusal: a desktop
  notification saying "ghostty-ai-command is not set", and no split.

## Step 2: integration (done)

- **Contract change (C0.4).** The IO thread now checks `ghostty-ai-access`
  and plausibility and captures the commands while it holds the terminal
  lock, then sends an owned `*GhosttyAiRequest` with the capture. Doing this
  on the app thread raced with the shell drawing its next prompt. See C0.4
  in `plans/ghostty-ai.md`.
- `src/ghostty_ai.zig` (new): `isPlausible`, `capture` (header + plain
  text), `isValidNote` (Q27), `formatTitle`, `shellCommand` (`direct:`
  arguments are single-quoted for `/bin/sh -c`), with tests.
- `src/Surface.zig`:
  - `write_command_file` goes through `writeScreenFile` with
    `WriteScreenLoc.command`; it does nothing on the alternate screen.
  - `ghosttyAiRequest` refuses with a desktop notification for: a note with
    control bytes, a split already open, the alternate screen, no commands,
    or an empty `ghostty-ai-command`. Otherwise it writes `commands.txt`
    (0600) and performs `new_split_command` to the right.
  - One split at a time: `ghostty_ai_split` holds the request id and the
    temp dir. The child reads `GHOSTTY_AI_PARENT` from `config.env` and calls
    `App.ghosttyAiSplitClosed` on deinit. If the parent closes first, it
    deletes the temp dir itself.
- Q25: `ghostty-ai` feature in `shell-integration-features` (default on);
  the function is gated on it in zsh, bash and fish.
- The header says "last N commands" with the requested N, even when fewer
  were captured.
- Verified: the targeted test filters pass, `zig build` (including the
  macOS app) succeeds. Not yet verified end to end in the app.

## Manual testing: issues reported (2026-10-29)

The user tested the debug macOS build (`zig-out/Ghostty.app`, built from
`e244b443a`'s tree) against the `~/code/acme-api` fixture, without following
the demo script exactly. **The end-to-end flow works:** `ghostty-ai` opened
a split running `claude`, which named the `@acme/session-client` 1.4.2 →
2.0.0 bump as the likely cause. The issues below were recorded and are not
addressed yet.

1. **zsh globbing breaks unquoted notes.** `ghostty-ai 5 "why is the above
   failing"?` fails with `zsh: no matches found` before the function runs,
   because the `?` outside the quotes is a glob. Nothing reaches Ghostty.
   Possible fix: `alias ghostty-ai='noglob ghostty-ai'` in the zsh
   integration.

2. **Output a command shows on the alternate screen is not captured.**
   `git log -1 --oneline` printed nothing on the primary screen: the pager
   (`less` without `-X`) drew it on the alternate screen, which was cleared
   on exit. The capture therefore has the command but not its output. This
   is how terminals work, not a ghostty-ai bug, but it can hide useful
   context. For the demo, use `git --no-pager log -1 --oneline`.

3. **"Already open" refusal right after closing the split.** After closing
   the AI split, two `ghostty-ai` requests (10:47:04, 10:47:13) were refused
   with `a ghostty-ai split from this terminal is already open`. The split's
   surface was only destroyed at 10:47:17. On macOS a closed split stays
   alive for `undo-timeout` (5 s by default) so ⌘Z can restore it, and the
   flag is cleared on surface deinit. Options: mention undo in the refusal
   text and docs, or clear the flag when the split closes (but then a
   restored split's capture file is already gone).

4. **Refusals are invisible when notifications are blocked.** The refusals
   above showed nothing on screen. The log has `Notifications are not
   allowed for this application`: the debug bundle
   (`com.mitchellh.ghostty.debug`) has its own notification permission,
   which was off. With notifications off, the only trace of a refusal is a
   log line. The plan rules out writing to the pty, so alternatives would be
   a bell or an in-app message.

5. **The default `claude --tools ""` still tries to call tools.** With every
   tool disabled, Claude printed raw `<invoke name="Read">` / `<invoke
   name="Bash">` markup as text, then said "every tool call I made ... came
   back with no output" and asked the user to run commands. The diagnosis
   was still right, but the output is noisy and misleading. Claude Code's
   own system prompt still describes tools, and `--append-system-prompt`
   only adds to it. Options: tell the model in the appended prompt that it
   has no tools and must answer from the capture, try `--system-prompt`, or
   use print mode (`-p`).

6. **Garbled text in Claude's answer.** Parts of the reply were cut or
   merged ("Both failures throw at the sam", "update src/n the commands
   above, orlet me know"). Cause unknown: it may be how the TUI text was
   copied rather than the output itself. Needs a second look.

7. **Failed attempts end up in later captures.** The capture included the
   earlier failed `ghostty-ai ... ?` line and its zsh error, and Claude
   commented on it. This is harmless and expected (it is a command in the
   history), but earlier `ghostty-ai` lines could be skipped.

## Environment (as of 2026-10-29, after Step 2)

- **Xcode is active:** `xcode-select -p` shows
  `/Applications/Xcode.app/Contents/Developer` (Xcode 26.3). The Metal
  toolchain is available through `xcrun`.
  - The full `zig build`, including the macOS app and the xcframework,
    succeeds, so the Swift code in F now compiles for real.
  - The app is at `zig-out/Ghostty.app` (bundle id
    `com.mitchellh.ghostty.debug`). It is a separate app from
    `/Applications/Ghostty.app`, with its own permissions, including
    notifications.
  - The placeholder Metal scripts (`…/scratchpad/fakebin`) from the earlier
    session are no longer needed. Don't put them on `PATH`.
- **Zig 0.17.0 is installed with Homebrew** (`/opt/homebrew/bin/zig`). The
  scratch-directory Zig from the earlier session is no longer needed.
- **Logs:** the debug app logs to the unified log. Use the full path, because
  `log` is a zsh builtin:
  ```
  /usr/bin/log show --last 30m --info --predicate 'subsystem BEGINSWITH "com.mitchellh.ghostty"'
  ```
  The `ghostty-ai` refusals are logged at info level by the `surface` scope.
- **GTK still can't compile on this Mac** (no gtk and adwaita headers). F's
  GTK code has only passed `zig ast-check`.
- **Still not installed:** `prettier`, `swiftlint`, `shellcheck`, `fish`,
  `pandoc`, `llm`, `ollama`. The fish changes (including the Q25 gating) are
  untested.

## Still open

- OSC 6767 was a best-effort pick, because no OSC registry exists.

## Process reminders

- Don't push or open issues or PRs. `AI_POLICY.md` requires disclosing AI
  assistance.
- The user writes the "why users will like this" summary.
