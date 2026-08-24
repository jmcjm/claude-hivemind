# Hivemind — a swarm of Claude Code agents in herdr

A package reproducing 1:1 a working system in which **one Claude Code (the coordinator) commands
a swarm of other Claude Codes (drones)** running in separate [herdr](https://herdr.dev) panels.
The human talks only to the coordinator and never browses drone panels.

Reading this as a Claude who is supposed to set it up on a new machine? Read **all of it** before
you start — the "Why this way and not another" section describes the traps that cost a few
burnt drones. The installer is easy; understanding the architecture is what counts.

## Installation

```bash
git clone https://github.com/jmcjm/claude-hivemind.git
cd claude-hivemind
./install.sh
```

Idempotent. Every overwritten file lands as `*.bak-<timestamp>` first. It does six things:
checks requirements, copies the skill, exposes `hive` in PATH, installs the herdr↔Claude Code
integration, appends a section to `~/.claude/CLAUDE.md`, verifies syntax.

**Requirements:** `herdr` (tested on 0.7.3 and 0.7.4), `claude` (Claude Code CLI), `python3`, `flock`.
The herdr server must be running — check `herdr status`.

## Verifying the 1:1 reproduction

After installation run the smoke test. It should pass **without a single manual click**:

```bash
hive coord                      # -> coord: wN:pM
hive spawn testdrone            # -> spawn: testdrone  ws=.. pane=.. model=opus
hive task testdrone - <<'BRIEF'
# Brief: testdrone
Count the files in the home directory and report the number. Boundaries: read-only.
BRIEF
                                # -> task: testdrone <- ... (attempt 1)   <= MUST say "attempt 1"
```

Now **do not poll**. Within ~30 s the message `HIVE-MAIL: new mail. Run: hive inbox` should appear
in the coordinator's prompt on its own. Then:

```bash
hive inbox                      # -> a [finished] entry from drone "testdrone"
hive report testdrone           # -> STATUS: DONE + content
hive kill testdrone --purge
```

If `task` showed "attempt 2/3" — the drone was losing input, but the retry mechanism worked (OK).
If `HIVE-MAIL` never arrived — see "Diagnostics" below.

## What lands where

| Path | Role |
|---|---|
| `~/.claude/skills/hivemind/SKILL.md` | doctrine for the coordinator, loaded automatically |
| `~/.claude/skills/hivemind/hive` | swarm CLI (a wrapper around `herdr`) |
| `~/.claude/skills/hivemind/drone-ping.sh` | drone hook: reports end of turn / needed decision |
| `~/.claude/skills/hivemind/drone-settings.json` | `Stop`/`Notification` hooks **for drones only** |
| `~/.local/bin/hive` | symlink so drones have `hive` in PATH |
| `~/.claude/CLAUDE.md` | the "Hivemind" section — the coordinator's identity |
| `~/.claude/hooks/herdr-agent-state.sh` | installed by `herdr integration install claude` |
| `~/.herdr-hive/drones/<name>/` | `meta.json`, `brief.md`, `report.md` |
| `~/.herdr-hive/mail/<recipient>/` | mailboxes (file = message) |

The global `~/.claude/settings.json` receives **only** the herdr integration hook. Swarm hooks
ride on the drones' `--settings`, so the human's session is untouched.

## Architecture

**Drone = herdr workspace = a panel with an interactive Claude Code on opus.** The workspace carries
the drone's name, so the human sees the swarm in the sidebar and can take over any panel at any time.

**Communication goes through files, not the terminal.** Brief → `brief.md`, result → `report.md`.
The TUI is read (`hive peek`) strictly for diagnosis.

**Drones call the coordinator, not the other way around.** The `Stop` and `Notification` hooks mail
the `coord` mailbox and inject a `HIVE-MAIL` wake-up straight into the coordinator's prompt. The
coordinator yields the turn and comes back only when there is a reason to — zero polling.

**Mail is a directory of files**, no daemon and no MTA. Atomic writes (`mktemp` + `mv`).
Recipients: `coord`, a drone name, `all`. Drones talk to each other over the same channel.

## Why this way and not another

Each of these points comes from a burnt drone or a hung coordinator. Do not "simplify" them.

1. **`--dangerously-skip-permissions`, not `acceptEdits`.** With `acceptEdits` a drone stops at the
   first Bash question (in our case: `xargs`) and the whole swarm waits. Consequence: the drone will
   ask about nothing, so **boundaries must be in the brief** ("read-only", "zero deploys").
2. **No blocking `herdr` waits without a limit.** When a drone gets stuck, the coordinator hangs with
   it and the human loses their only interface. `hive wait` has a hard timeout and also ends on `blocked`/`dead`.
3. **The completion signal is `report.md`, not the agent status.** `idle` means only "not generating
   tokens right now" — a drone hanging on a dialog is `idle` too.
4. **`workspace create` + `agent start` yields TWO panes**, because `agent start` always does a split.
   `hive spawn` closes the orphaned `<ws>:p1` shell.
5. **A fresh drone loses its first input** — `SessionStart` hooks clear the prompt. `hive task` confirms
   delivery (the status must jump to `working`) and retries up to 3 times.
6. **The prompt is shared with the human.** Sending Enter would send the text the human is typing
   right now. `hive task`/`say`/`wake_recipient` check for this and refuse.
7. **But ghost text is not human text.** Claude Code suggests ready-made prompts as dimmed text
   (SGR `2`). A naive detector takes them for input and **blocks every idle drone**.
   `prompt_pending` reads `--format ansi` and counts only characters outside dim fragments.
8. **The swarm protocol sits in `--append-system-prompt`, not in the brief.** When it lived in the
   brief, drones improvised and used `hive say` instead of `hive send`, bypassing the mailbox and the safeguards.
9. **One wake-up per batch** (the `.wake-<who>` marker) + `flock`. Without it, five drones finishing
   at once all type into one prompt simultaneously and the result is mush.

## herdr 0.7.x technicalities

- `herdr pane read` returns **raw text**, `herdr agent read` returns **JSON**. Easy to get burnt.
- `herdr agent send` types text **without Enter** — you must follow up with `pane send-keys <pane> enter`.
- `herdr pane current` correctly detects the caller's pane (hence `hive coord`).
- `herdr agent start --env K=V` propagates variables into the drone process (that is how drones learn `HIVE_DRONE`).
- The trust dialog ("Is this a project you trust?") appears for an untrusted `--cwd` **despite**
  `--dangerously-skip-permissions`. `hive spawn` detects and accepts it.
- The first spawn on a fresh machine has an extra first-run dialog —
  `hive spawn` handles it in the bootstrap the same way as the trust dialog.
- Statuses: `idle | working | blocked | done | unknown` (`dead` is added by `hive`).

## Diagnostics

| Symptom | Cause | Move |
|---|---|---|
| `HIVE-MAIL` never arrives | `coord.pane` points at a previous session's panel | `hive coord`, then `hive inbox` |
| `HIVE-MAIL` never arrives, coord OK | human has text in the prompt — wake-up withheld | the letter waits in the mailbox: `hive inbox` |
| `hive task` says the drone did not start | drone hanging on a dialog | `hive peek <drone>` |
| drone `idle`, no report | considered the task done without writing | `hive say <drone> "write the report to <path>"` |
| status `dead` | drone killed or crashed | `hive revive <drone>` — conversation history survives |
| `hive revive` loses history | herdr integration missing | `herdr integration status` → must say `claude: current` |
| drones bypass the mailbox | old spawn without the system prompt | kill and spawn anew |

## Customization

- Drone model: `HIVE_MODEL=sonnet hive spawn <name>` (default `opus`).
- Swarm directory: `HIVE_DIR=/other/path` (consistently for all invocations).
- Language: the skill and the drones' system prompt are in English — translate `SKILL.md` and
  `$sysprompt` in the `cmd_spawn` function if the target human speaks another language.
