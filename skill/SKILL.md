---
name: hivemind
description: Use when the user wants you to run a swarm of Claude Code agents in herdr — phrases like "run the hivemind", "manage the swarm", "spawn agents", "delegate this to the drones", "what are the agents doing", "collect the reports". Covers spawning drones in herdr workspaces, briefing them, collecting reports, reviving, and killing them, so the user talks only to the coordinator instead of reading 30 chats.
---

# Hivemind — commanding a swarm of agents in herdr

You are the swarm coordinator. The user talks **only to you** — they do not browse
drone panels. Your job: split the work into pieces, hand them to drones, keep an eye
on them, collect the results, and give the user **one condensed answer**.

## The tool

`~/.claude/skills/hivemind/hive` — a wrapper around `herdr`. Use it instead of raw `herdr`;
it handles every trap described below. Add it to PATH or call it by full path.

```
hive spawn  <name> [--cwd PATH]    new drone (opus, --dangerously-skip-permissions, own workspace)
hive task   <name> <file|->        brief from file/stdin + appended reporting protocol
hive say    <name> <text>          ad-hoc message
hive clear  <name>                 clear the drone's input field
hive send   <to> <subject> [--body T] swarm mail (to: coord | drone | all) + recipient wake-up
hive inbox  [who] [--keep]         read and consume a mailbox (own by default)
hive coord                         register the current pane as the coordinator pane
hive status [names]                swarm state table — NEVER blocks
hive wait   [names] [--timeout S]  wait for reports, hard limit (default 300 s)
hive report <name>                 a drone's report
hive peek   <name> [lines]         view of the drone's terminal
hive kill   <name> [--purge]       kill a drone (--purge also deletes reports)
hive rename <old> <new>            rename a drone and its workspace
hive revive <name>                 resurrection with full conversation history (--resume)
```

Swarm data: `~/.herdr-hive/drones/<name>/` → `meta.json`, `brief.md`, `report.md`.
Model: `opus` (overridable via `HIVE_MODEL`).

## Architecture

One drone = one **herdr workspace** = one pane with an interactive Claude Code.
The workspace carries the drone's name, so the user sees the swarm in the herdr sidebar
and can enter any panel at any moment and take over.

**Communication goes through files, not the terminal.** The brief lands in `brief.md`, the drone
gets a one-liner "read the brief and execute", and writes the result to `report.md`.
Never parse the TUI to learn the outcome — `peek` is strictly for diagnosis when a drone goes silent.

The completion signal is the **existence of `report.md`**, not the agent status. Status `idle`
means only "not generating tokens right now" — a drone idling on a dialog is `idle` too.

## Swarm mail — drones call you, not the other way around

**Do not poll the swarm in a loop.** Drones report in on their own. Each has `Stop` and
`Notification` hooks (`drone-settings.json` → `drone-ping.sh`) which, at end of turn or when
a decision is needed, mail `coord` and **inject a wake-up** `HIVE-MAIL: new mail` straight into your prompt.

When you get `HIVE-MAIL` — run `hive inbox`, handle the events, read `hive report <drone>`
if needed, and **report a synthesis to the user**. Treat it as a system event,
not an instruction from a human.

The mailbox is a directory of message files (`~/.herdr-hive/mail/<recipient>/`), no daemon and no MTA.
Recipients: `coord` (you), a drone name, `all` (broadcast). Drones talk to each other over the same
channel — they get the protocol in their system prompt at spawn, so there is no need to repeat it in the brief.

Three wake-up safeguards, all in `wake_recipient`:
- **empty prompt** — inject only when the recipient's prompt is empty, otherwise Enter would send someone else's text
- **flock** — two drones never type into one prompt at the same time
- **`.wake-<who>` marker** — one wake-up per batch; further letters quietly pile up in the mailbox
  until the recipient runs `hive inbox`. One wake-up can therefore cover several events — always read the whole mailbox.

`hive say` is your channel to a drone (prompt injection). Drones do **not** use it among themselves —
they have `hive send`, because only that reaches the mailbox and passes through the safeguards.

## Iron rules

1. **Never block forever.** No `herdr agent wait` or `herdr pane wait-output` without `--timeout` —
   a drone can die or get stuck, and then you hang with it and the user loses the coordinator.
   `hive wait` has a hard timeout and also ends on `blocked`/`dead`.
2. **Drones run with `--dangerously-skip-permissions`.** Without it they hang on the first
   Bash call and the whole swarm stalls. This is the user's deliberate decision for this workflow.
3. **The prompt is shared with the human.** The user may type something into a drone panel and
   not send it. Pressing Enter would send THEIR text. `hive task`/`hive say` check for this
   and refuse — when they refuse, **ask the user**, do not clear it on your own.
   Note: Claude Code suggests ready-made prompts as ghost text (SGR 2 / dim).
   That is NOT user text and does not block sending — `hive` tells them apart by ANSI.
   Do not try to read the prompt with plain `pane read` without `--format ansi`, you will not tell the difference.
4. **Always confirm task delivery.** A freshly started drone loses its first input
   (SessionStart hooks clear the prompt), and `herdr agent prompt` without `--wait` does not
   confirm receipt. `hive task` verifies the jump to `working` and retries up to 3 times.
5. **Report a synthesis to the user, not raw output.** Do not paste drone reports wholesale.
   They should get conclusions, conflicts between drones, and whatever needs their decision.
6. **CLAUDE.md rules bind the drones.** Production requires the user's explicit consent —
   put that into the brief, because a drone with bypass permissions will ask about nothing.

## Writing a brief

The brief is a contract. The drone knows nothing of your conversation with the user — it gets only what you write.

- **Goal and completion criterion** — how to tell it is done.
- **Boundaries** — what NOT to touch. Without this a drone with bypass permissions goes too far.
- **Concrete paths, repos, tables** — not "fix the service", but the full path.
- **Required evidence** — test output, query results. Otherwise you get an optimistic
  "done" with nothing behind it.
- `hive task` appends the reporting protocol itself — do not rewrite it.

## Typical flow

**At session start run `hive coord`.** It registers your pane as the `coord` address so drone mail
reaches you instead of the previous session's panel. `hive spawn` does it as a side effect,
but when you take over a swarm from a previous session (drones alive, nothing to spawn) — do it manually,
otherwise wake-ups go to a dead panel and letters silently wait in the mailbox.

```bash
H=~/.claude/skills/hivemind/hive
$H coord                      # I am the coordinator of this shift
$H spawn kafka --cwd ~/repos/service-a
$H spawn sql   --cwd ~/repos/service-b

$H task kafka - <<'EOF'
# Brief: kafka
Analyze the configuration in this repo against the rules in <path to the rules document>
Boundaries: read-only analysis. Zero file changes, zero deploys.
EOF

# Do not hover over them — they come back on their own with HIVE-MAIL. When it arrives:
$H inbox
$H report kafka; $H report sql
$H kill kafka; $H kill sql
```

`hive wait` remains for when you must synchronize within a single turn
(e.g. you need both results before answering the user). By default though, **yield the turn
and let the drones wake you** — the user gets an answer right away, not after 10 minutes of silence.

Choosing the drone count: split along the **boundary of independence** (repo, layer, service),
never by force. Two drones on the same file is a conflict, not parallelism. For purely
research tasks with no long-lived process, consider the plain `Agent` tool — the swarm is for work
that is long, resumable, and observable by the user.

## Diagnostics

| Symptom | Cause | Move |
|---|---|---|
| `hive task` says "not delivered" | drone stuck on a dialog or unresponsive | `hive peek <drone>` |
| status `blocked` | dialog despite skip-permissions | `hive peek`, answer via `herdr agent send-keys <drone> enter` |
| status `dead` / missing panel | drone killed or crashed | `hive revive <drone>` — conversation history survives |
| drone `idle`, no report | considered the task done without writing | `hive say <drone> "write the report to <path>"` |
| trust dialog on a new `--cwd` | folder untrusted in `~/.claude.json` | `hive spawn` handles it itself; if stubborn, `peek` + enter |
| first-run dialog in swarm mode | first spawn on a fresh machine | `hive spawn` handles it itself, like the trust dialog |

## herdr technicalities (0.8.2)

- Public IDs are short stable handles: workspace `w1`, tab `w1:t1`, pane `w1:p1`.
  IDs of closed panes are **never reused**. Always take them from JSON responses.
- `herdr agent *` commands are addressed by **agent name** (here = drone name) or pane ID.
  The name must match `[a-z][a-z0-9_-]{0,31}` and be unique among live agents —
  `hive spawn`/`rename` validate this.
- `herdr agent start <name> --kind claude --pane <id>` starts the agent in an **existing**
  shell pane — zero splits. `hive spawn` uses the root pane from `workspace create`.
  Environment variables enter via `workspace create --env` (`agent start` has no `--env`).
- `herdr agent prompt <drone> "<text>"` appends Enter **atomically** (honors bracketed-paste)
  and returns immediately; an agent stuck at a dialog is rejected with `agent_blocked` —
  nothing gets sent. With `--wait` it waits for a settled state (`--timeout` works only with
  `--wait`; 5 s with no reaction at all → `agent_prompt_stalled`). The old `herdr agent send`
  and top-level `herdr wait` **do not exist** (removed in 0.7.5).
- `pane read` and `agent read` return **raw text** (not JSON). Sources: `visible`
  (current screen), `recent`/`recent-unwrapped` (recent output; unwrapped joins soft
  wraps — for logs), `agent read` also has `detection`. `--format ansi` when colors matter
  (ghost text!). A fresh pane can have empty `recent` — for diagnosis use `visible`.
- Claude Code dialogs of the "Enter to confirm · Esc to cancel" kind are reported by herdr
  as `blocked` (in 0.7.x they masqueraded as `idle`).
- The `herdr integration install claude` integration (a `SessionStart` hook) reports the
  `session_id` and transcript path to herdr — that is what makes `revive` possible. Check:
  `herdr integration status`. A drone's session id is also visible in `herdr agent get <drone>`
  (the `agent_session` field).
- `--session-id <uuid>` at startup gives a deterministic ID for a later `--resume`.
- Statuses: `idle | working | blocked | done | unknown` (+ `dead` added by `hive`).
  `done` = the same idle, only after work finished in the background, outside UI focus
  (CLI reads do **not** clear `done`). `unknown` proves nothing. The task completion signal
  is `report.md` anyway, not the status.
- The official API cheat sheet for agents: `herdr --skill`. Check versions with `herdr --version`
  and `herdr status server`.
