# ghostty-ai follow-ups: manual test checklist

**What changed:** before this change, running `ghostty-ai` while this
terminal's `ghostty-ai` split was open was refused with "a ghostty-ai split
from this terminal is already open". Now Ghostty sends the note and the new
capture to the open split as a follow-up. It pastes them into the program
there as a bracketed paste, then presses Enter. With the default command,
they arrive as your next message in the same Claude Code session.

The same branch also changed the default command to add
`--strict-mcp-config`, so MCP servers and claude.ai connectors aren't loaded.

Fill in **Result** (pass / fail / unsure) and **Notes** for each item. Notes
are the useful part: what you saw, how it felt, anything surprising.

## Setup

- [ ] Build: `zig build` (includes the macOS app). Run
      `zig-out/Ghostty.app`, not `/Applications/Ghostty.app`.
- [ ] The debug app (`com.mitchellh.ghostty.debug`) has its own
      notification permission. Turn it on in System Settings →
      Notifications, or refusals will only show up in the log.
- [ ] Use the default `ghostty-ai-command` (remove any override from your
      config) unless an item says otherwise. Reload the config after each
      change.
- [ ] Use the `~/code/acme-api` fixture or any repo with a failing command.
- [ ] Logs, if something looks wrong:
      ```
      /usr/bin/log show --last 10m --info --predicate 'subsystem BEGINSWITH "com.mitchellh.ghostty"' | grep -i ghostty-ai
      ```
- [ ] In bash and fish, quote notes that contain `?`, `*` or `[`. zsh no
      longer needs it (see F1).

## A. Core flow

- [ ] **A1. The first request still opens a split.** Run a failing command,
      then `ghostty-ai 3 "why did this fail?"`.
      Expected: a split opens on the right and Claude answers.
      Result: | Notes:

- [ ] **A2. A follow-up goes to the open split.** In the *original* pane, run
      another command (e.g. `ls does-not-exist`), then
      `ghostty-ai 1 "and what about this one?"`.
      Expected: no new split. The message shows up in the Claude split as a
      new user message (a long one may show as `[Pasted text #1 +N lines]`)
      and is sent without you pressing anything. Focus stays in the original
      pane.
      Result: | Notes:

- [ ] **A3. It really is the same session.** Send
      `ghostty-ai 1 "in one line, what did you tell me in your first answer?"`.
      Expected: Claude refers to its earlier answer.
      Result: | Notes:

- [ ] **A4. Enter actually sends it.** In A2 and A3, check the paste did
      not stay sitting in Claude's input box. **Risk:** the paste and the
      Enter arrive together, and a TUI might treat the Enter as part of the
      paste. If it stays in the box, a delay before Enter would fix it.
      Result: | Notes:

- [ ] **A5. A follow-up with no note.** Run a command, then `ghostty-ai 1`.
      Expected: only the capture is sent (it starts with
      `# Terminal history captured by Ghostty`), and Claude responds to it.
      Result: | Notes:

- [ ] **A6. Message format.** Look at a follow-up in the transcript. It is
      the note, a blank line, then the capture with its header line. Does
      Claude understand it's new context? Would you want something else
      (e.g. a "Follow-up:" label, or no repeat of commands it has already
      seen)?
      Result: | Notes:

## B. Content

- [ ] **B1. Special characters in the note.**
      ``ghostty-ai 1 'quotes "x" $HOME `echo hi` ünïcode 🙂'``.
      Expected: Claude receives that text literally. Nothing expands or runs.
      Result: | Notes:

- [ ] **B2. Large capture.** Run something with long output (e.g.
      `seq 1 3000`), then `ghostty-ai 5 "summarize"` as a follow-up.
      Expected: it is pasted and sent as one message, with no freeze and no
      partial send.
      Result: | Notes:

- [ ] **B3. Output with escape sequences.** Run `ls --color=always` or
      `git log --color=always -3`, then send a follow-up.
      Expected: plain text arrives, with no stray characters typed into
      Claude's UI and nothing beyond the one message sent.
      Result: | Notes:

## C. Timing and state

- [ ] **C1. A follow-up while Claude is still answering.** Send one
      follow-up, then immediately send another.
      Expected: Claude Code queues the second message and answers it after
      the first. Record what actually happens.
      Result: | Notes:

- [ ] **C2. Half-typed text in Claude's input.** Click into the split, type
      `hello` in Claude's input without sending, click back into the
      original pane and send a follow-up.
      Expected (a known limitation): the paste is appended to `hello`, and
      both are sent together. Is that acceptable?
      Result: | Notes:

- [ ] **C3. A follow-up right after the split opens.** Run `ghostty-ai`
      twice in quick succession (the second before Claude has finished
      starting).
      Expected: either the follow-up is sent, or it is refused with a
      notification ("the ghostty-ai split is not ready yet" or "does not
      accept pasted text"). It should never be lost silently.
      Result: | Notes:

- [ ] **C4. After quitting Claude in the split.** Exit Claude (`/exit`) and
      let the split close, then run `ghostty-ai` again.
      Expected: a new split opens with a fresh session.
      Result: | Notes:

- [ ] **C5. Within 5 s of closing the split (undo window).** Close the split
      (⌘W), then run `ghostty-ai` within 5 seconds. On macOS a closed split
      stays alive for `undo-timeout` so ⌘Z can restore it (known issue 3 in
      `ghostty-ai-status.md`).
      Expected: refused with "the ghostty-ai split is not visible. If you
      just closed it, try again in a few seconds." Then press ⌘Z: the
      restored split must **not** contain the follow-up. After 5 s without
      undo, `ghostty-ai` opens a new split.
      Result: | Notes:

- [ ] **C6. `wait-after-command = true`.** With this config set, exit Claude
      so the split stays open showing that the process exited, then send a
      follow-up.
      Expected: refused with "the program in the ghostty-ai split has
      exited".
      Result: | Notes:

- [ ] **C7. The split in another tab of the same window.** With the
      ghostty-ai split open, switch to another tab, then back, and send a
      follow-up.
      Expected: sent normally. (Follow-ups to a split that isn't visible
      are refused, so this checks that coming back restores visibility.)
      Result: | Notes:

## D. Several terminals

- [ ] **D1. Follow-ups go to the right split.** Open `ghostty-ai` splits
      from two different tabs (A and B). Send a follow-up from A.
      Expected: it lands only in A's split.
      Result: | Notes:

- [ ] **D2. A split with no follow-up target.** Close A's split, then run
      `ghostty-ai` in A while B's split is still open.
      Expected: A gets a new split, and B's is untouched.
      Result: | Notes:

## E. Refusals and safety

- [ ] **E1. A program that doesn't accept pasted text.** Set
      `ghostty-ai-command = cat "$GHOSTTY_AI_FILE"; read x`, run
      `ghostty-ai` (the split shows the capture and waits), then send a
      follow-up.
      Expected: a notification "the program in the ghostty-ai split does
      not accept pasted text", and nothing typed into the split.
      Result: | Notes:

- [ ] **E2. A read-only split.** Make the Claude split read-only (bind and
      use the `toggle_readonly` action while it's focused), then send a
      follow-up.
      Expected: a notification "the ghostty-ai split is read-only".
      Result: | Notes:

- [ ] **E3. The auto-send risk with a permission prompt.** Set
      ```
      ghostty-ai-command = claude --tools "Read,Grep,Glob" --strict-mcp-config --append-system-prompt "$(cat "$GHOSTTY_AI_FILE")" "$GHOSTTY_AI_NOTE"
      ```
      Ask Claude in the split to read `/etc/hosts` (outside the working
      directory, so it should ask permission). While the permission prompt
      is showing, send a follow-up from the original pane.
      Expected per the docs: the Enter may answer the prompt. Record exactly
      what happened. This decides whether auto-send stays as it is.
      Result: | Notes:

- [ ] **E4. No tools or connectors with the default.** With the default
      command, ask Claude in the split: "List the exact names of every tool
      you can call, or say NONE."
      Expected: `NONE` (no Bash, Read, Gmail, Notion, …).
      Result: | Notes:

## F. Fixes for the 10-29 issues

- [ ] **F1. zsh: an unquoted note.** `ghostty-ai 3 why is the above failing?`
      with no quotes.
      Expected: it works, and Claude gets the note with the `?`.
      Result: | Notes:

- [ ] **F2. No fake tool calls.** With the default command, ask something
      that invites tool use ("why is this failing? check the code").
      Expected: no `<invoke …>` markup. Claude says it can't read files and
      tells you what to run or paste.
      Result: | Notes:

- [ ] **F3. Earlier `ghostty-ai` lines are not in captures.** Run a
      command, `ghostty-ai 1 "first"`, then right away
      `ghostty-ai 1 "follow-up"`.
      Expected: the follow-up's capture shows the real command, not the
      `ghostty-ai 1 "first"` line.
      Result: | Notes:

## Overall

- Does the follow-up flow feel right? What would you change?
- Anything that should be refused but wasn't, or the other way round?
