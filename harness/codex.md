<!-- tracks: scripts/codex-support.py .codex/hooks.json scripts/review.sh -->

# Codex adapter

These instructions apply only to Codex. Follow `AGENTS.md` and read `CLAUDE.md`
for project architecture and taste. The shared skill bodies and agent prompts
remain written for Claude Code; use the mappings below in Codex.

## Starting

`.agents/skills/` links to `.claude/skills/`; edit a shared procedure only when
the change is also intended for Claude Code. Put Codex-only differences here.

The project hooks run the brief on startup, resume, clear and compaction, bring
up the dashboard on startup/resume/clear, and stop it at SessionEnd. New or
changed hooks must be reviewed and trusted in Codex's `/hooks` before they run.
Also check for duplicate user-level Beads hooks there. Until the brief actually
arrives, run `bash scripts/brief.sh` yourself. Do not add `bd prime` on top.

## Completing work

The repository authorizes local commits without another user request. Claim the
bead before implementation and keep its status current. For each completed task,
run the gate and independent review, commit only your changes with the bead id,
then close the bead with the outcome before reporting completion. This applies
to ordinary task replies, not only explicit handoffs. Leave unrelated work out
of the commit. If blocked or paused, record the remaining work and return the
bead to open using the handoff procedure. Push only when the user requests it.

## Shared skill mappings

- **workflow:** use `open_in_codex` with a browser target for the URL printed by
  `scripts/dashboard.py up`. Claude's `preview_start` is not a Codex tool.
  The cost figures and `context.py spend` describe Claude transcripts, not
  Codex usage. Keep the real `.claude/memory-archive/` path when following the
  shared memory archive procedure; do not invent a `.Codex/` replacement.
- **agentic-review:** use `spawn_agent` with `agent_type` set to
  `reviewer-taste` and `reviewer-correctness`. Run them in parallel; add
  `reviewer-design` when anything on screen changes, with captures as required
  by AGENTS.md. Codex inherits the host's model and reasoning settings, including
  for the taste reviewer; do not pass Haiku or Sonnet as Codex model names.
  If a running session has not loaded a new role yet, give a fresh default
  subagent its `.claude/agents/<role>.md` prompt and the review packet path.
  Use `scripts/review.sh --staged` when other work is present, after staging only
  the intended change. Packets have unique paths; use the path the script prints.
- **handoff:** write the shared handoff note and settle the ledger normally.
  Use `create_thread` only when the user explicitly asks for a new sidebar task;
  use `send_message_to_thread` for an existing task and `spawn_agent` for a
  subtask of the current work. Do not translate `claude --bg` into a Codex CLI
  command. Carry bead ids, remaining work and suggested skills in the handoff.
- **beads / graphify:** use the shared CLI procedures. If a skill or reviewer is
  added, removed or renamed, refresh Codex support with the command below.

## Maintaining the adapter

`python3 scripts/codex-support.py write` regenerates `.codex/agents/*.toml`,
`.codex/hooks.json` and skill links. It preserves shared agent prompt bodies and
does not copy Claude's model aliases or tool allowlists into Codex config.
`check` detects drift without writing; the verify gate runs it and its isolated
regression tests. The generator refuses to overwrite a copied skill directory:
reconcile that content before replacing it with a link.

Codex support does not change Claude settings or its model choices. Hook trust
is user-local and is never bypassed by this adapter.

Official references: [skills](https://learn.chatgpt.com/docs/build-skills),
[custom agents](https://learn.chatgpt.com/docs/agent-configuration/subagents),
[hooks](https://learn.chatgpt.com/docs/hooks).
