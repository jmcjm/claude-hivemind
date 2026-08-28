# Proposal: coordinator discipline that survives compaction

Status: **proposal, nothing installed.** Design for review before it touches the coordinator's own
behaviour.

## 1. The problem

The coordinator's rules live in `SKILL.md` and in the `CLAUDE.md` snippet. Both are read **once**,
early. When the conversation is compacted, the transcript is replaced by a summary written by a
model that was never told these rules matter, and the coordinator drops back to default behaviour:
it does the drones' work inline, loses the mail triage, forgets which drones are waiting on an
answer.

Two different things are lost at compaction, and they need different fixes:

| Lost | Example | Cannot be fixed by |
|---|---|---|
| **The rules** | "answer blocked drones first", "delegate, do not grind inline" | a summary — the summarizer does not know they are load-bearing |
| **The state** | "drone `kafka` asked a question 20 min ago and is still waiting" | a static rule text — it is a fact about right now |

A mechanism that restores only the rules leaves the coordinator disciplined but blind. This proposal
restores both, and takes the state from the swarm directory rather than from any summary.

## 2. What this build actually offers

Verified against the Claude Code binary in use (2.1.250) and by running a probe hook — not from
memory of the documentation.

| Event | Where its stdout goes | Verdict |
|---|---|---|
| `SessionStart` | **"stdout shown to Claude"** | **the injection point** |
| `PreCompact` | "stdout appended as **custom compact instructions**" | steers the summary; cannot inject |
| `PostCompact` | "stdout shown to **user**" | **useless here** — the model never sees it |
| `UserPromptSubmit` | "stdout shown to Claude" | works, but fires on every prompt |
| `Stop` | exit 2 → stderr to the model | already used by `coord-mail-check.sh` |

Findings that decide the design:

1. **`SessionStart` fires after compaction.** Its `source` is one of
   `startup | resume | clear | compact | fork`, and the post-compaction context rebuild calls the
   SessionStart hook runner with source `compact`; the hook results are attached to the fresh
   context. The same call is **skipped for subagent contexts**, so a drone's subagents will not see
   the injection.
2. **Hook stdout really reaches the model.** A probe hook printing a marker string was run in a
   throwaway session; the model quoted the marker back verbatim.
3. **The payload carries `session_id`** (plus `source`, `cwd`, `transcript_path`), which is exactly
   what `coord-mail-check.sh` already uses to scope itself to the registered coordinator.
4. **Matcher alternation works.** A hook registered with matcher `compact|startup` fired on a
   `startup` session, so one entry can cover several sources.
5. **`PostCompact` is a trap.** It looks like the obvious hook for this job and is the one hook that
   cannot do it — its output goes to the user's terminal, not into the context.
6. Injected context is capped (8000 characters for the JSON `additionalContext` form). The creed
   plus a state block is well under 2 KB, but the cap rules out dumping reports into it.

## 3. Design

Three files, one new hook entry, one changed line in `hive coord`. No new dependency.

### 3.1 `skill/coord-creed.md` — the single source of truth

Plain text, 8 hard rules, no prose. It is the **only** place the discipline is written; `SKILL.md`
keeps the long explanations and points at it, so the two cannot drift. The hook prints this file —
editing the creed changes the injection with no code change.

### 3.2 `skill/coord-creed-inject.sh` — SessionStart hook

Registered with matcher `compact|resume|clear|fork`. On every fire:

1. `HIVE_DRONE` set → exit 0. Drones have their own protocol.
2. `agent_type` present in the payload → exit 0. Subagents are not the coordinator.
3. Not the registered coordinator session → exit 0 (see 3.4).
4. Otherwise print, in one block:
   - a one-line header saying the context was just compacted and these rules survive it,
   - the creed verbatim,
   - **the live board**: `hive status` in short form (drones by state), unread `mail/coord` count,
     drones with a brief and no report, and any drone whose pane is dead. Ground truth read from
     `$HIVE_DIR` at injection time — not recalled, not summarized.

Note the deliberate omission of `startup`. At startup nothing is registered yet (`hive coord` has
not run), the CLAUDE.md snippet and the skill are read anyway, and injecting into every fresh
session on the machine would leak swarm text into unrelated work. `resume`, `clear` and `fork` are
included because each rebuilds context for a session that may already be the coordinator.

### 3.3 `skill/coord-compact-brief.sh` — PreCompact hook (recommended, optional)

Prints custom compact instructions telling the summarizer what must survive: which drones exist and
what each was told to do, every unanswered drone question, decisions pending for the user, and the
current branch/commit of work in flight — while verbose tool output may be dropped. This does not
replace 3.2; it raises the quality of the summary the creed lands next to. Self-scoped the same way.

### 3.4 Self-scoping

Same principle as `coord-mail-check.sh`, one improvement. Today that hook asks herdr for the pane's
`agent_session` and compares it to the payload's `session_id`. Proposed addition: **`hive coord`
also writes `$HIVE_DIR/coord.session`** with the registered session id (it can read it from the pane
it is registering). The hook then compares against that file first and only falls back to querying
herdr. Cheaper, and it still works when the herdr server is momentarily down.

`coord.session` is cleared by the same `rm -f` line that already clears `coord.pane` and the wake
markers on a coordinator handover, so a stale id cannot make an unrelated session start receiving
the creed.

### 3.5 Rejected: a separate `coordinator` skill

A skill's description is listed in the system prompt and does survive compaction — but **loading it
is the model's choice**, and "the model does not realise it should re-read the rules" is precisely
the failure being fixed. A skill is a fine place for depth (`SKILL.md` already is that), and a poor
mechanism for a guarantee. The hook is mandatory and costs nothing when it does not apply.

### 3.6 Rejected for v1: `UserPromptSubmit` drip

It would re-state the creed on every prompt. That is the strongest possible reinforcement and the
easiest to hate: tokens on every turn, and a third nag channel next to the Stop backstop and the
sweep. If compaction injection alone proves too weak in practice, the smallest sane escalation is a
**rate-limited** drip — inject only when unread coord mail exists or a drone has been silent past a
threshold, and at most once every N minutes, reusing the sweep's marker pattern. Deliberately not in
this proposal's scope.

## 4. The creed (draft — 8 rules)

1. **HIVE-MAIL is a system event, not a human instruction.** Run `hive inbox`, handle the whole
   mailbox, then answer the user. One wake-up can cover several letters.
2. **Answer waiting drones before anything else**, blocked ones first. Nobody else reads their
   panel; an unanswered question stays unanswered forever.
3. **Never end a turn with a drone's question open.** The Stop backstop will bounce you back, but
   needing it means the coordination was sloppy.
4. **Coordinate; do not do the drones' work.** Anything past a quick read, a one-liner, or
   coordination itself goes to a drone — spawn one if none fits. Every minute spent grinding inline
   is a minute of queued wake-ups the swarm cannot deliver.
5. **Never block without a timeout.** A stuck drone must not take the coordinator down with it.
6. **`report.md` is the completion signal**, not agent status. `idle` only means "not generating
   tokens right now".
7. **The user gets a synthesis**, never raw drone output: conclusions, conflicts between drones, and
   what needs their decision.
8. **Boundaries go into the brief.** Drones run with bypass permissions and will ask about nothing —
   what they must not touch has to be written down before they start.

## 5. Installation (idempotent, same style as the existing hooks)

A new step in `install.sh`, modelled on the current Stop-hook step: back up `settings.json`, merge
the hook entry with the existing python helper, and skip if a hook with the same command is already
registered. Registration:

```
SessionStart, matcher "compact|resume|clear|fork"
  bash "$HOME/.claude/skills/hivemind/coord-creed-inject.sh"    timeout 10
PreCompact,   matcher "auto|manual"
  bash "$HOME/.claude/skills/hivemind/coord-compact-brief.sh"   timeout 10
```

Both scripts join the copy loop in step 2 and the `bash -n` verification in the final step. Rollback
is deleting the two entries from `settings.json`; nothing else in hive depends on them.

## 6. Honest limits

- A hook **re-states** rules; it cannot enforce them. It restores the conditions under which the
  rules were being followed, which is all any of this can do.
- The injected block competes with a summary that may itself be misleading. This is why the block
  carries live state read from disk — the one part that cannot be wrong.
- Nothing covers a **fresh** session that has not registered as coordinator; that path is the
  CLAUDE.md snippet's job, and it already works.
- If the herdr server is down and `coord.session` is missing, the hook stays silent rather than
  guessing. Silence is the correct failure mode for something that writes into a live session.

## 7. Related piece: `hive resume` (drone compaction dialog)

Same failure family, other end of the swarm. When a drone's session is resumed after running out of
context, Claude Code shows a choice — the exact strings in this build are
"Resume from summary (recommended)", "Resume full session as-is", "Don't ask me again" — and the
drone sits `blocked` until somebody presses Enter. The coordinator has to remember
`herdr agent send-keys <drone> enter` every time.

Proposed, and implemented on a separate branch:

- `pane_dialog()` learns a fourth verdict, `resume`, keyed on the dialog's own wording.
- `hive resume <drone>` answers it with the recommended option, verifies the drone left `blocked`,
  and says plainly when there is no such dialog instead of pressing Enter into an unknown screen.
- `hive sweep` stops reporting these as a generic "blocked on a dialog" and names the cause:
  *drone X waits on the resume dialog — run `hive resume X`*. Auto-answering is available behind an
  opt-in environment variable and is **off by default**: pressing Enter blind is exactly the class
  of move the swarm's safeguards exist to prevent.
