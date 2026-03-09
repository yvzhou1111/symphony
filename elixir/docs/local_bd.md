# Local `bd` + Symphony workflow

This is the simplest way to use Symphony entirely on a local Ubuntu machine.

## What it gives you

- `bd` acts as the task inbox
- Symphony runs locally as the orchestrator
- Codex runs locally inside isolated workspaces
- A local dashboard is exposed on a non-default port such as `43117`

## Recommended commands

```bash
cd ~/symphony/elixir
./bin/symphony-local start /path/to/repo --port 43117
./bin/symphony-local task /path/to/repo "Fix flaky probe validation"
./bin/symphony-local status /path/to/repo
./bin/symphony-local logs /path/to/repo
./bin/symphony-local stop /path/to/repo
```

## One-command habit

From inside your repo:

```bash
symphony-local do "Add a new health check endpoint"
```

That command starts Symphony if needed, writes `.symphony/WORKFLOW.bd.md`, creates a new `bd`
issue, and lets the local orchestrator pick it up.

## Notes

- The launcher auto-initializes `bd` in the target repo when `.beads/` is missing.
- The generated workflow clones the target repo into the Symphony workspace root.
- Override the Codex command with `SYMPHONY_LOCAL_CODEX_COMMAND` when needed.
- Override the workspace root with `SYMPHONY_LOCAL_WORKSPACE_ROOT` when needed.
