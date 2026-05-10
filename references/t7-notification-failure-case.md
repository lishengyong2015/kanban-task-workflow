> **2026-05-11 更新**：自 kanban-worker v2.1.0 起，worker 工具集已加入 `send_message`，上述 Path A 问题已解决。详见 kanban-worker 技能的 `send_message tool` 章节。

# T7 Notification Failure Case Study

Date: 2026-05-10
Task: T7 (t_c47afcf2) — 实现多游戏大区共享账号（编码实现）

## Background

Based on T5 design document (doc/多服务器共享账号密码/方案.md), implement dual-database shared account system for Legend game project. Multiple game regions connecting to a shared MySQL account database while keeping role data isolated per region.

## Timeline

| Time | Event |
|------|-------|
| 20:12 | T7 created w/ --max-runtime 30m, notify-subscribed to weixin |
| 20:12~27 | Run 21: Research→Plan→Code→Code Review→Build. Reclaimed at 903s |
| 20:27~32 | Run 22: Continuation detection, re-Build. Blocked at Phase 4 |
| 21:04 | User retreat: "设计不通过，驳回到第一阶段" (concurrent DB access concern) |
| 21:04~12 | Run 23: Phase 1 re-Research. Found: SQLite can't handle concurrent writes. Recommend force MySQL for shared DB |
| 21:17 | User: "unblock, 同意使用方案A" |
| 21:17~32 | Run 24: Phase 2 Plan. Blocked at Phase 2 |
| 21:39 | User: "unblock, 进入下一个阶段" |
| 21:39~47 | Run 25: Phase 3 Code → Phase 3.5 Code Review → Phase 4 Build. Blocked at Phase 4 |
| 22:23 | User: "T7 unblock" (final time) |
| 22:23+ | Run 26: Phase 5 Complete |

## Key Lessons

### 1. Notification: Both paths failed

**Path A: Worker send_message** — Worker toolset does NOT include messaging tools. The workflow's "STEP 3: 发送通知给创建者" was never executed by any of the 6 runs. User received zero push notifications.

**Path B: notify-subscribe** — Subscription was created at task creation (20:12). But WeChat iLink API rate limits caused the gateway notification system to auto-delete the subscription after 3 failed delivery attempts. By ~21:00, `notify-list` showed T7 subscription as empty.

**Result**: The only way the user knew about task progress was by asking the conversation AI ("查看看板", "完成了吗").

### 2. --max-runtime 30m didn't take effect

Despite passing `--max-runtime 30m` at task creation, run 21 was still reclaimed at exactly 903 seconds. Per-task max-runtime may only affect the dispatch scheduling timeout, not the stale_lock detection timeout which seems to be a hard 15-minute limit.

**Workaround**: Split large tasks into smaller sub-tasks, each finishable within 15 minutes. Or archive + recreate (old code changes on disk persist).

### 3. Retreat from Phase 4 back to Phase 1

When the user said "驳回到第一阶段" while the task was blocked at Phase 4:

**Manual steps required** (worker won't auto-detect this since it's blocked):
1. Write comment with retreat reason (hermes kanban comment)
2. Unblock (hermes kanban unblock)
3. Update TASK.md: set current_phase: phase0, increment retreat_count
4. Back up all phase files (.old): implementation-plan.md.old, build-result.md.old, code-review-result.md.old

**Code preservation**: Code changes on disk (project source files) were NOT rolled back. This is important — the worker continued from existing code state and only adjusted the DB connection logic for MySQL concurrency.

### 4. Continuation detection across archive+recreate

T6 (t_fe1c2059) was archived and T7 (t_c47afcf2) created fresh. But source code had already been partially modified by T6's runs. T7's worker needed to detect this:

```bash
stat --format='%y %n' platform/database/database.h platform/database/database.cpp
# → Found timestamps from T6's runs → knew code was already written
# → Skipped re-coding database.h/cpp
# → Only modified connectToAccountDb() for MySQL concurrency
```

### 5. Worker effort summary

| Run | Duration | Outcome | Work done |
|-----|----------|---------|-----------|
| 21 | 903s | reclaimed | Full cycle Research→Code→Review→Build |
| 22 | 296s | blocked | Continuation detect, re-Build, send emails |
| 23 | 439s | blocked | Re-Research, MySQL concurrency finding |
| 24 | 902s | blocked | Re-Plan |
| 25 | 448s | blocked | Re-Code (MySQL), Re-Build |
| 26 | — | complete | Phase 5 summary |
