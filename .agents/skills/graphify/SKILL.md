---
name: graphify
description: Query a local Graphify code knowledge graph before broad source reads to reduce context/token usage for architecture, dependency, impact-analysis, and code-navigation questions.
---

# Graphify code-context workflow

Use Graphify-Labs/graphify v8+ as a local code index. The graph narrows context; repository source remains authoritative.

1. If `graphify-out/graph.json` exists, start with `graphify query "<question>" --budget 1200`.
   - Use `graphify path "<A>" "<B>"` for relationship questions.
   - Use `graphify explain "<concept>"` for focused concepts.
2. Open only the source files/locations returned by the graph, then verify the exact code before editing or making a factual claim.
3. If the graph does not exist, ensure the CLI is available (`uv tool install graphifyy`, fallback `pipx install graphifyy`) and run `graphify extract . --code-only`.
4. After code changes, refresh with `graphify extract . --code-only`. This intentionally keeps routine refreshes structural/local and avoids semantic LLM passes over docs/media.
5. Do not run semantic extraction over docs, PDFs, images, or video unless the user explicitly needs that material in the graph.
6. Do not commit generated `graphify-out/` artifacts. If a graph query is insufficient, raise the budget to 2000-3000 before falling back to broad grep/source browsing.
7. If the graph is stale, inconsistent, or missing relevant source, trust the repository source and rebuild/fall back rather than guessing.

When the user invokes `/graphify`, follow this workflow.
