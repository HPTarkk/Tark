# Repository agent guidance

## Graphify context optimization
- Project-scoped Graphify skills live at `.agents/skills/graphify/SKILL.md` and `.codex/skills/graphify/SKILL.md`.
- For codebase architecture, dependency, impact-analysis, and code-navigation questions, use `graphify query`, `graphify path`, or `graphify explain` before broad grep/file reads whenever `graphify-out/graph.json` exists.
- If the graph is missing, invoke the Graphify skill and build a structural code-only graph with `graphify extract . --code-only` before broad repository exploration.
- Treat the graph as an index, never as source of truth: open and verify the exact returned source before edits or definitive claims.
- After code modifications, refresh with `graphify extract . --code-only`; this intentionally avoids semantic LLM passes during routine development.
- Keep generated `graphify-out/` artifacts local and uncommitted. Do not run docs/PDF/image/video semantic extraction unless the task explicitly needs it.
