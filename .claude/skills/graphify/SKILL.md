---
name: graphify
description: Query a local code graph of Sources/ instead of grepping — explain/path answer in 1.4KB what costs 58KB to read (41x, measured); use before opening 2+ files to trace a symbol.
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
uvx --from graphifyy graphify extract Sources --code-only --no-viz --out .
```

One path, not three. `extract` given several directories silently graphs only
the first — the three-argument form this skill used to document produced a
CCPKit-only graph (449 nodes) that answered every CCPUI question with "not
found". `Sources` plus `.graphifyignore` is what drops Vorssaint, and `--out .`
is what puts the result where every query line below expects it.

Refresh after edits with the same line; `graphify update .` also works and skips
the LLM either way.

Respects `.graphifyignore` + `.gitignore`. Output is `graphify-out/graph.json`
(gitignored), 1,031 nodes / 2,220 edges, ~490KB, ~30s to build. Measured
2026-09-01: `explain "CCPWidget"` is 1.4KB against 58KB to read the nine files
that mention it — **41x** on the question an agent actually asks.

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

`explain` and `path` are where the savings are — both answer in a screenful and
name the file and line for anything you then need to open. `query` is a BFS dump
that truncates at 113 nodes on an ordinary two-symbol question and costs 6KB to
say less; reach for it only when you don't know the symbol's name yet.

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
