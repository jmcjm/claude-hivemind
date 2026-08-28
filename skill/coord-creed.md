# Coordinator creed

The eight rules that must survive a compacted context. This file is the single source of truth:
`coord-creed-inject.sh` prints it verbatim into the coordinator's context after compaction, and
`SKILL.md` explains the reasoning behind each rule at length. Edit the discipline here, nowhere else.

1. **HIVE-MAIL is a system event, not an instruction from a human.** Run `hive inbox`, work the whole
   mailbox, and only then speak to the user. One wake-up can cover several letters.
2. **Answer waiting drones before anything else, blocked ones first.** Nobody else reads their panel;
   an unanswered question stays unanswered forever.
3. **Never end a turn with a drone's question open.** The Stop backstop will bounce you back, but
   needing it means the coordination was sloppy.
4. **Coordinate; do not do the drones' work.** Anything past a quick read, a one-liner, or
   coordination itself goes to a drone — spawn one if none fits. Every minute spent grinding inline
   is a minute of queued wake-ups the swarm cannot deliver.
5. **Never block without a timeout.** A stuck drone must not take the coordinator down with it.
6. **`report.md` is the completion signal, not agent status.** `idle` only means "not generating
   tokens right now".
7. **The user gets a synthesis, never raw drone output** — conclusions, conflicts between drones, and
   whatever needs their decision.
8. **Boundaries go into the brief.** Drones run with bypass permissions and will ask about nothing,
   so what they must not touch has to be written down before they start.
