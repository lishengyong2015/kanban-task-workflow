# kanban-task-workflow

A Hermes Agent skill for structured Kanban development task execution.

## Overview

This skill defines a 5-phase pipeline for Kanban workers:

```
Research → Plan → Code → Code Review → Build → Complete
```

Each phase produces artifacts in the workspace, and key phase transitions require human approval via `kanban_block`/`kanban_unblock`.

## Phases

| Phase | Description | Output |
|-------|-------------|--------|
| Phase 0: Orientation | Read task, analyze comments, detect rework instructions | TASK.md |
| Phase 1: Research | Code analysis, dependency mapping, risk identification | research-findings.md |
| Phase 2: Plan | Per-file change plan with encoding/build constraints | implementation-plan.md |
| Phase 3: Code | File modifications with encoding safety rules | Modified source files |
| Phase 3.5: Code Review | Orphan function/event/encoding corruption checks | code-review-result.md |
| Phase 4: Build | Compilation verification | build-result.md |
| Phase 5: Complete | Summary and finalization | kanban_complete() |

## Key Features

- **Rework handling**: Automatically detects "not approved" comments and falls back to the appropriate phase
- **Encoding safety**: Enforces safe file editing rules for GBK/GB2312 encoded files
- **Continuation detection**: Skips completed phases on worker restart (after unblock)
- **Rework limit**: Blocks and requests human intervention after 3 consecutive rework cycles
- **Artifact backups**: Old phase outputs are backed as `.old` files instead of deleted

## Comment-based Rework

Users write comments on blocked tasks to trigger rework:

```
T3 代码不通过，修改意见：编码有问题，用safe_write.py修改
```

Supported keywords: `研究不通过`, `方案不通过`, `代码不通过`, `research`, `plan`, `code`

## Installation

```bash
hermes skills install <source>/kanban-task-workflow
```

Or manually place in your skills directory:

```bash
cp -r kanban-task-workflow ~/.hermes/skills/productivity/
```

## Usage

Create a Kanban task with this skill:

```bash
hermes kanban create "Task title" \
  --assignee worker-1 \
  --skill kanban-task-workflow \
  --body "objective: ...
scope: ...
success_criteria: ..."
```

## Dependencies

- Hermes Agent (Kanban system)
- `kanban-worker` skill (builtin, loaded automatically by dispatcher)

## Related

- [kanban-worker](https://github.com/nousresearch/hermes-agent) — Base lifecycle skill for Kanban workers

## License

MIT
