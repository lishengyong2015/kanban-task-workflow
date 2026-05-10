# kanban-task-workflow

Hermes Agent skill: 5-phase structured Kanban development task pipeline.

## Phases

Research → Plan → Code → Code Review → Build → Complete

Each phase produces artifacts. Key transitions require human approval via kanban_block.

## Usage

```bash
hermes kanban create "Task title" \
  --assignee worker-1 \
  --skill kanban-task-workflow
```

## Publishing Updates

```bash
sync-kanban-skill "feat: add new feature"
```
