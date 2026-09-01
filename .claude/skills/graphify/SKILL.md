---
name: graphify
description: Query a local code graph (CCPKit/CCPUI) instead of grepping — explain/path/query with ~5x fewer tokens when built; use before reading 2+ files to trace widgets.
---

# Graphify — on-demand code map

Code-only graph, built locally with tree-sitter (no LLM, no API key). Useful when you need to trace a symbol across files without pulling those files into context.

## When to reach for it

* “How does `CCPWidget` connect to `WidgetRegistry` / `WidgetID`?” → `path` or `query`
* “What does `SystemStatsAdapter` touch?” → `explain`
* Before opening 2+ files to answer one relationship question.

Skip it for harness work (`bd ready`/`bd show`, `scripts/verify.sh`) — the ledger and gate are the source of truth there, not the code graph.

## Build (only when you need it, code only)

```bash
# scoped to harness code — not vendored UI, not tests, not .build
uvx --from graphifyy graphify extract Sources/CCPKit Sources/CCPUI Sources/ControlCenterPro --code-only --no-viz
# whole-repo variant (larger, ~24M JSON, noisier hubs):
uvx --from graphifyy graphify extract . --code-only --no-viz
# refresh after edits (no LLM):
uvx --from graphifyy graphify update .   # or re-run the extract line above
```

Respects `.graphifyignore` + `.gitignore`. Output is `graphify-out/graph.json` (gitignored). Spike on 2026-09-01: full repo 14,770 nodes / 40,672 edges, ~5x token reduction on avg query (2.3–17.8x per question, `graphify benchmark`); CCPKit-only 400 nodes / 875 edges — prefer the scoped build.

No hooks are installed. The graph is never committed.

## Query

```bash
uvx --from graphifyy graphify explain "CCPWidget" --graph graphify-out/graph.json
uvx --from graphifyy graphify path "CCPWidget" "WidgetRegistry" --graph graphify-out/graph.json --undirected
uvx --from graphifyy graphify query "how does GlassCard connect to WidgetCard" --graph graphify-out/graph.json
# broad queries truncate at ~2000 tokens; raise budget or narrow:
uvx --from graphifyy graphify query "which adapters exist" --graph graphify-out/graph.json --budget 8000
uvx --from graphifyy graphify query "..." --graph graphify-out/graph.json --context_filter call
```

Each edge is tagged `EXTRACTED` (in source) or `INFERRED` (resolved). Check the `Source: … L…` line before trusting a path.

## Revisit & removal

Revisit bead: `ccp-4q8` (“revisit graphify integration - keep or remove”) — `bd show ccp-4q8`. It holds the full turn-off checklist.

Quick removal (no residue):

```bash
rm -rf .claude/skills/graphify
rm -rf graphify-out/ Sources/graphify-out/ .graphifyignore
# if you ever ran `graphify hook install` (spike did not):
uvx --from graphifyy graphify hook uninstall 2>/dev/null; true
git config --unset merge.graphify.driver 2>/dev/null; true
# remove the gitignore line added for this skill:
# delete `graphify-out/` / `Sources/**/graphify-out/` from the CCP block in .gitignore
# remove the Python tool only if you installed it isolated:
uv tool uninstall graphifyy 2>/dev/null; pipx uninstall graphifyy 2>/dev/null; true
scripts/context.py bless  # skill list changed, so bless the lock
scripts/verify.sh --quick
bd close ccp-4q8 --reason "removed — reason …"  # or keep with reason
```
