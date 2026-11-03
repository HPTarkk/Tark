# Repository agent guidance

## Git branch policy

- The only allowed local and remote branch names are `main` and `release/*`.
- Work on an existing allowed branch. Do not create temporary, feature, fix,
  `codex/*`, or other branches, even when a tool suggests doing so.
- Use `main` for ongoing development. Use a `release/*` branch only when the
  user explicitly requests work on that release; do not automatically backport.
- Before committing or pushing, verify the current branch and inspect the local
  and remote branch lists. Do not push a branch outside the allowed names.
- Preserve `main` and existing `release/*` branches and their history. Do not
  delete them, force-push, or rewrite shared history without explicit user
  authorization. If an unexpected branch exists, report it and obtain user
  authorization before deleting it.

## Graphify context optimization
- Project-scoped Graphify skills live at `.agents/skills/graphify/SKILL.md` and `.codex/skills/graphify/SKILL.md`.
- For codebase architecture, dependency, impact-analysis, and code-navigation questions, use `graphify query`, `graphify path`, or `graphify explain` before broad grep/file reads whenever `graphify-out/graph.json` exists.
- If the graph is missing, invoke the Graphify skill and build a structural code-only graph with `graphify extract . --code-only` before broad repository exploration.
- Treat the graph as an index, never as source of truth: open and verify the exact returned source before edits or definitive claims.
- After code modifications, refresh with `graphify extract . --code-only`; this intentionally avoids semantic LLM passes during routine development.
- Keep generated `graphify-out/` artifacts local and uncommitted. Do not run docs/PDF/image/video semantic extraction unless the task explicitly needs it.
