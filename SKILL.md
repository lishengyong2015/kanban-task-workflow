---
name: kanban-task-workflow
description: 通用看板任务执行工作流——Research → Plan → Code → Build → Complete，每阶段有用户确认点。适用于任何看板开发任务。用户发起看板开发时加载此技能。
version: 1.1.0
created: 2026-05-10
tags: [kanban, workflow, multi-agent, development]
---

# Kanban Task Workflow — 看板任务执行工作流

> 通用看板任务执行规范，适用于任何开发类 kanban 任务。
> 触发条件：用户发起看板开发任务，或任务 body 中包含"按工作流执行"。
>
> **关联技能：** `kanban-worker`（devops/kanban-worker）— 自动注入每个 worker，提供 kanban 生命周期基础（claim/block/complete/heartbeat）、状态机参考和通知机制。本技能是**上层工作流编排**，kanban-worker 是**底层生命周期**。两个技能配合使用。

## 核心原则

1. **分阶段执行** — Research → Plan → Code → **Code Review** → Build → Complete
2. **用户确认点** — 关键阶段间 `kanban_block` 等人解锁
3. **代码审查** — Coding 完成后自动审查孤立函数/孤立事件/编码乱码，有问题退回编码
4. **目标锚点** — 每个阶段开始前重新校准目标
5. **中间产物存档** — 每阶段产出写入 workspace 供后续阶段使用

## 铁律：Worker 禁止提问

kanban worker 是**后台自主运行**的，没有人类在终端前等它。

- ❌ **禁止问"要不要发邮件"** — 技能说了发就发，不发就不发，没有选择
- ❌ **禁止问"可以继续吗"** — 技能规则唯一决定下一步，不需要许可
- ❌ **禁止问"需要调整吗"** — 有问题就 kanban_block 等用户 unblock
- ✅ **做就是了** — 技能说发送邮件就调用脚本，说 block 就 block，说 complete 就 complete
- ✅ **有异常就 block** — 失败/异常/不确定 → kanban_block 写明原因，让用户决定

> 你是一台开发流水线上的机器，不是对话助手。没有人在看着你输出。执行技能指令，不要创造分支路径。

## 任务接收（Phase 0: Orientation）

当 dispatcher 派发任务后：

1. 读取 `$HERMES_KANBAN_TASK` 对应的任务信息（`kanban_show`）
2. 提取：目标描述、涉及文件、验收标准、关联技能
3. 读取所有 comments，检查是否有**退回修改指令**

   **退回指令格式**（用户写的任意 comment，支持 T+数字 前缀）：
   ```
   T3 当前阶段不通过，修改意见：xxx
   ```
   或更具体指定阶段：
   ```
   T3 方案不通过，修改意见：xxx
   T3 代码不通过，修改意见：xxx
   ```

   **解析规则**：
   - 先 trim 掉 `T\d+\s+` 前缀（如 "T3 当前阶段不通过" → "当前阶段不通过"）
   - 再匹配关键词

   **退回阶段自动检测**：
   - 用户写 "研究不通过" 或 "research不通过" → 退回到 Phase 1 Research
   - 用户写 "方案不通过" 或 "plan不通过" → 退回到 Phase 2 Plan
   - 用户写 "代码不通过" 或 "code不通过" → 退回到 Phase 3 Code
   - 用户写 "当前阶段不通过"（无具体指定）→ 按以下优先级判断退回哪个阶段：
     1. 读取 TASK.md 中的 `current_phase` 字段 → 退回上一个阶段
     2. 若 TASK.md 中无 `current_phase`，检查 workspace 文件：
        - code-review-result.md 存在且标记"发现问题" → 退回 Phase 3 Code
        - build-result.md 存在 → 退回 Phase 4 Build（重新编译）
        - implementation-plan.md 存在 → 退回 Phase 2 Plan
        - research-findings.md 存在 → 退回 Phase 1 Research

   **退回次数防护**：
   - 每次退回前读取 TASK.md 中的 `retreat_count` 字段
   - 如果 `retreat_count >= 3`，不再自动退回，改为直接 block 并通知创建者人工介入
   - 通知内容："⚠️ [介入] ${task_number} ${task_title} 已退回修改 3 次仍未通过，请人工介入处理"
   - 否则：retreat_count += 1，写入 TASK.md

   **中间产物处理（备份替代删除）**：
   - 不再直接删除，改为备份：`mv xxx.md xxx.md.old`
   - 备份文件供 worker 后续阶段参考（worker 可以看到旧的方案/代码分析）
   - 示例：退回 Phase 2 时 → `mv implementation-plan.md implementation-plan.md.old`
   - 退回 Phase 3 时 → 保留 research-findings.md 和 implementation-plan.md，删除 build-result.md（备份为 .old）

4. 创建 `TASK.md` — 写入 workspace 目录：
   - 从 task body 中提取 `notify_target: <平台>:<chat_id>`（如 `feishu:oc_xxx`）
   - 如 body 中没有 notify_target，默认发到当前对话
   - 读取 `~/.hermes/kanban_task_numbers.txt` 获取当前 T-number

```
# <task_id> — <标题>
task_number: T<N>
objective: <从 task body 提取的一行目标>
scope: <明确哪些文件/模块>
success_criteria:
  - <验收标准1>
  - <验收标准2>
source: <任务来源：父任务、用户直接创建等>
notify_target: <从 body 提取的平台:chat_id>
task_title: <任务标题>
current_phase: phase0
retreat_count: 0
```

5. 加载任务 body 中提到的关联技能
6. 检查 workspace 中是否已有 Phase 1+ 的中间产物 → 若有则续跑
7. **续跑检测**：如果 `research-findings.md` 已存在且完整，跳过 Phase 1 直接从 Phase 2 开始

---

## 阶段流程

### Phase 1: Research — 代码/需求研究

**入口**：重新读取 `TASK.md` 校准目标

**执行**：
1. 读取目标文件（看 scope 列出的文件）
2. 理解现有结构、模式、关键位置
3. 识别风险点（依赖关系、编码约束、API 兼容性）
4. 记录发现

**产出**：`workspace/research-findings.md`
```markdown
# Research Findings — <task_id>

## 分析的文件
- path/to/file1: 关键函数/结构分析
- path/to/file2: 需要修改的位置

## 关键发现
- 当前实现的核心流程
- 需要修改的精确位置（行号/函数名）
- 潜在风险

## 改动点摘要
- File A: line XXX — 修改 A
- File B: line YYY — 新增 B
```

**出口**（依次执行，禁止跳过）：

**STEP 1** — 校验是否偏离 TASK.md 目标

**STEP 2** — 发送邮件给李总（含研究文档附件）
```
使用 terminal 工具运行：
python3 ~/.openclaw/workspace/skills/email-sender/scripts/send_email.py \
  --to lishengyong198719@163.com \
  --subject "[审核] ${task_id} Research完成 - ${task_title}" \
  --body "研究阶段完成，请审核附件中的研究文档后回复确认或提出修改意见。如需继续下一阶段，我将在收到确认后进入方案设计。" \
  --attach /home/lsy/.hermes/kanban/workspaces/${task_id}/research-findings.md \
  --body-type plain
```
需要将 task_id 和 task_title 替换为 TASK.md 中的实际值。

**STEP 3** — 发送通知给创建者
```
使用 send_message 工具：
target: 从 TASK.md 读取 notify_target
message: "⊘ [blocked] ${task_number} Research完成，审核邮件已发送至李总邮箱，请查阅"
```

**STEP 4** — 记录阶段状态后阻塞等待审核
```
# 更新 TASK.md 记录当前阶段
sed -i "s/current_phase:.*/current_phase: phase1/" /home/lsy/.hermes/kanban/workspaces/${task_id}/TASK.md

# 阻塞
kanban_block(reason="研究完成，邮件已发送至李总邮箱，等待审核确认后 unblock")
```

**STEP 5** — 等待用户 unblock 后进入 Phase 2

> ⚠️ 铁律：以上 4 步必须全部执行，禁止跳过任何一步。不要问"要不要发邮件"。不要问"可以直接下一阶段吗"。直接按顺序执行。

---

### Phase 2: Plan — 实施方案

**入口**：
1. 重新读取 `TASK.md` 校准目标
2. 读取 `research-findings.md` 获取前序分析

**执行**：
1. 根据研究结果制定逐文件改动计划
2. 明确每个文件的改动方式（新增/修改/删除）
3. 明确编码约束（文件编码、行终止符等）
4. 明确编译验证步骤
5. 检查是否有用户特别约束（如安全规则、文件保护）

**产出**：`workspace/implementation-plan.md`
```markdown
# Implementation Plan — <task_id>

## 改动清单
| 文件 | 操作 | 改动内容 | 编码约束 |
|------|------|---------|---------|
| path/file1.cpp | 修改 | 函数XXX添加逻辑 | GBK/CRLF |
| path/file2.h | 新增 | 声明XXX | GBK/CRLF |

## 编码注意事项
- 文件编码检测：`file xxx.cpp`
- 修改方法：二进制读写 decode('gbk')，禁止使用 patch 工具（会破坏编码）

## 验证步骤
1. 编译命令
2. 验证可执行文件存在
3. 检查编码
```

**出口**（依次执行，禁止跳过）：

**STEP 1** — 校验计划范围是否与 TASK.md scope 一致

**STEP 2** — 发送邮件给李总（含方案文档附件）
```
terminal: python3 ~/.openclaw/workspace/skills/email-sender/scripts/send_email.py \
  --to lishengyong198719@163.com \
  --subject "[审核] ${task_id} 方案完成 - ${task_title}" \
  --body "实施方案已制定，请审核附件中的方案文档后回复确认或提出修改意见。如需继续执行编码，我将在收到确认后开始实现。" \
  --attach /home/lsy/.hermes/kanban/workspaces/${task_id}/implementation-plan.md \
  --body-type plain
```

**STEP 3** — 发送通知给创建者
```
send_message: target=notify_target, message="⊘ [blocked] ${task_number} 方案完成，审核邮件已发送至李总邮箱，请查阅"
```

**STEP 4** — 记录阶段状态后阻塞等待审核
```
sed -i "s/current_phase:.*/current_phase: phase2/" /home/lsy/.hermes/kanban/workspaces/${task_id}/TASK.md
kanban_block(reason="方案完成，邮件已发送至李总邮箱，等待审核确认后 unblock")
```

**STEP 5** — 等待用户 unblock 后进入 Phase 3

> ⚠️ 铁律：以上步骤禁止跳过。不要问问题。直接执行。

---

### Phase 3: Code — 编码实现

**入口**：
1. 重新读取 `TASK.md` 校准目标
2. 读取 `implementation-plan.md` 获取改动方案

**执行**：
1. 按计划逐文件修改
2. 严格遵守编码约束（编码、换行符、缩进风格）
3. **每次修改后验证文件编码未被破坏**
4. 不修改 scope 以外的文件
5. 不引入无关的优化或重构
6. 中途出现 >3 步的大改动，每完成一个子步骤进行一次快速自查

**编码安全规则**：
- 对 GBK/GB2312/GB18030 编码的文件：使用 `execute_code` + 二进制 read/decode/edit/encode/write
- 禁止使用 `patch` 工具修改编码敏感文件
- 禁止用 `write_file` 直接写入非 UTF-8 文件

**产出**：修改后的物理文件（原地修改）

**出口**：
1. 校验所有计划中的改动已执行
2. `file xxx` 检查所有修改文件编码未变
3. 不 block，直接进入 Phase 3.5 Code Review

---

### Phase 3.5: Code Review — 代码审查

**入口**：
1. 重新读取 `TASK.md` 校准目标
2. 确认所有文件改动已完成

**执行**：

审查所有涉及文件，逐项检查以下三类问题：

**1. 孤立函数检查（Orphan Functions）**
- 在 .h 文件中声明了但在 .cpp 中未实现的函数（只有签名没有实现体）
- 在 .cpp 中实现但在任何 .h 中未声明的函数（无法被外部调用）
- 已删除的旧函数对应的声明/实现未被清理

检查方法：
```bash
# 对比 .h 声明列表和 .cpp 实现列表
grep -n "void \|int \|bool \|QString " path/to/module.h  # 查看.h中的函数声明
grep -n "::" path/to/module.cpp                            # 查看.cpp中的实现
```

**2. 孤立事件检查（Orphan Events）**
- 事件 ID 在 `Events.h` 中定义了，但没有对应的 `PostEvent` 调用
- 事件 ID 在 `Events.h` 中定义了，但没有在 `initService()` 中注册 `AddNotifyHandler`
- 事件处理 handler 已实现，但事件从未被触发

检查方法（以 Legend 项目的 EVENT_ACHV_* 为例）：
```python
# 三重对照验证：
# 1. Events.h 中的事件定义
# 2. initService() 中的 AddNotifyHandler 注册
# 3. 全文搜索 PostEvent(EVENT_XXX) 调用
# 缺少任意一环即为孤立事件
```

**3. 编码混乱检查（Encoding Corruption）**
- 所有修改过的 .cpp/.h/.c 文件编码验证

检查方法：
```bash
# 逐个文件验证编码
for f in path/to/file1.cpp path/to/file2.h; do
  result=$(file "$f")
  echo "$result"
  if echo "$result" | grep -q "ISO-8859\|ASCII\|Non-ISO extended-ASCII"; then
    echo "  → 编码 OK"
  else
    echo "  → 编码异常！可能是 UTF-8"
  fi
done
```

**产出**：`workspace/code-review-result.md`
```markdown
# Code Review Result — <task_id>

## 编码检查
- path/file1.cpp — ISO-8859, CRLF ✅
- path/file2.h — ISO-8859, CRLF ✅

## 孤立函数检查
- 无异常 ✅（所有声明均有对应实现）

## 孤立事件检查
- EVENT_XXX — 已定义 ✅ → 已注册 AddNotifyHandler ✅ → 有 PostEvent 调用 ✅

## 审查结论
[通过 / 发现 X 个问题]
```

**出口**（分支逻辑）：

**分支 A — 审查通过，无问题：**
1. 写入 code-review-result.md（结论：通过）
2. 不 block，直接进入 Phase 4 Build

**分支 B — 发现问题，需返工：**
1. 写入 code-review-result.md（列出具体问题）
2. **发送邮件给李总**（附审查报告）：
   ```
   terminal: python3 ~/.openclaw/workspace/skills/email-sender/scripts/send_email.py \
     --to lishengyong198719@163.com \
     --subject "[审查] ${task_id} 代码审查发现问题 - ${task_title}" \
     --body "代码审查发现以下问题：\n1. 编码问题：...\n2. 孤立函数：...\n3. 孤立事件：...\n\n将退回编码阶段修复。" \
     --attach /home/lsy/.hermes/kanban/workspaces/${task_id}/code-review-result.md \
     --body-type plain
   ```
3. **发送通知给创建者**：
   ```
   send_message: target=notify_target, message="🔄 [review] ${task_number} 代码审查发现问题，已退回编码阶段修复，查收邮件"
   ```
4. 记录阶段并阻塞：
```
sed -i "s/current_phase:.*/current_phase: phase3_5/" /home/lsy/.hermes/kanban/workspaces/${task_id}/TASK.md
kanban_block(reason="代码审查发现 X 个问题（编码/孤立函数/孤立事件），已退回编码阶段。审核邮件已发送至李总邮箱")
```
5. 用户 unblock 后 → **重新进入 Phase 3 Code**（续跑检测跳过 Phase 1/2 直接回到编码）

---

### Phase 4: Build — 编译验证

**入口**：
1. 重新读取 `TASK.md` 校准目标
2. 确认所有文件改动已完成

**执行**：
1. 执行项目构建命令
2. 记录编译日志
3. 验证编译 errors = 0
4. 验证产物存在
5. 非必须：不执行耗时测试，除非 task body 明确要求

**产出**：`workspace/build-result.md`
```markdown
# Build Result — <task_id>

## 编译命令
<实际执行的编译命令>

## 编译结果
- Errors: 0
- Warnings: <数量>
- 产物: path/to/exe (已生成)

## 修改文件确认
- path/file1.cpp — 编码: ISO-8859 ✓
- path/file2.h — 编码: ISO-8859 ✓
```

**出口**（依次执行，禁止跳过）：

**STEP 1** — 校验编译结果，errors ≠ 0 应修复后重试

**STEP 2** — 校验产物存在

**STEP 3** — 发送邮件给李总（含编译结果附件）
```
terminal: python3 ~/.openclaw/workspace/skills/email-sender/scripts/send_email.py \
  --to lishengyong198719@163.com \
  --subject "[审核] ${task_id} 编译完成 - ${task_title}" \
  --body "编译验证通过（0 error），请审核附件中的编译结果文档后回复确认。如需完成收尾，我将在收到确认后执行完成总结。" \
  --attach /home/lsy/.hermes/kanban/workspaces/${task_id}/build-result.md \
  --body-type plain
```

**STEP 4** — 发送通知给创建者
```
send_message: target=notify_target, message="⊘ [blocked] ${task_number} 编译完成（0 error），审核邮件已发送至李总邮箱，请查阅"
```

**STEP 5** — 记录阶段状态后阻塞等待审核
```
sed -i "s/current_phase:.*/current_phase: phase4/" /home/lsy/.hermes/kanban/workspaces/${task_id}/TASK.md
kanban_block(reason="编译完成，邮件已发送至李总邮箱，等待审核确认后 unblock")
```

**STEP 6** — 等待用户 unblock 后进入 Phase 5

> ⚠️ 铁律：以上步骤禁止跳过。不要问问题。直接执行。

---

### Phase 5: Complete — 完成总结

**入口**：
1. 重新读取 `TASK.md` 校准目标
2. 读取 `build-result.md` 获取编译结果

**执行**：
1. 汇总所有阶段产出
2. 对照 success_criteria 逐条确认
3. 生成完成总结

**出口**（依次执行）：

**STEP 1** — 发送通知给创建者（任务完成）
```
send_message: target=notify_target, message="✅ [done] ${task_number} ${task_title} 已完成。修改: [文件列表] 编译: 0 error"
```

**STEP 2** — 完成操作
```
kanban_complete(
    summary="<一句话描述完成任务> 修改文件: [file1, file2] 编译: 0 error",
    metadata={
        "phases_completed": ["research", "plan", "code", "code_review", "build"],
        "changed_files": ["path/file1", "path/file2"],
        "build_errors": 0,
        "build_warnings": 0,
    },
)
```

---

## 用户确认点一览

| 阶段间 | Block 原因 | 通知内容示例 | 用户需要做什么 |
|--------|-----------|-------------|--------------|
| Research → Plan | 研究完成 | ⊘ [blocked] T6 Research完成，审核邮件已发送 | 查收邮件，审核 research-findings.md 附件，回复后 unblock |
| Plan → Code | 方案完成 | ⊘ [blocked] T6 方案完成，审核邮件已发送 | 查收邮件，审核 implementation-plan.md 附件，确认范围后 unblock |
| Code Review → Code（返工） | 审查发现问题 | 🔄 [review] T6 代码审查发现问题，已退回编码 | 查收邮件，审核 code-review-result.md，确认问题后 unblock（自动退回编码） |
| Build → Complete | 编译完成 | ⊘ [blocked] T6 编译完成（0 error），审核邮件已发送 | 查收邮件，审核 build-result.md 附件，确认编译通过后 unblock |
| 退回超3次 | 人工介入 | ⚠️ [介入] T6 已退回3次仍未通过 | 人工查看 worker 执行情况，直接处理 |

**注意**：Code Review 通过后直接进入 Build，不 block。只有发现问题退回编码时才 block。

**用户回复方式**（任选）：
- 微信/飞书说：`unblock T3`（由对话中的 AI 代为执行）
- 或带修改意见：`T3 方案不通过，修改意见：重新设计`（AI 自动写 comment 后 unblock）
- 终端：`hermes kanban unblock <task_id>`
- 或直接 `hermes kanban comment <task_id> "可以继续" && hermes kanban unblock <task_id>`

---

## 通知订阅机制

看板通知是**按任务单独订阅**的，没有全局默认通知目标。每个任务需要通过 `notify-subscribe` 单独设置。

### 订阅方式

创建任务后，订阅到当前用户所在的对话平台：

```bash
# 订阅到飞书 DM
hermes kanban notify-subscribe <task_id> \
  --platform feishu \
  --chat-id <chat_id>

# 订阅到微信 DM
hermes kanban notify-subscribe <task_id> \
  --platform weixin \
  --chat-id <weixin_chat_id>
```

### 订阅生命周期

```
subscribe → 任务发生 blocked/complete/done → 通知器发消息
         → 如果连续发消息失败（如 WeChat rate limit）
         → 通知器自动取消订阅（notify-list 立刻变空）
         → 用户收不到任何后续通知 → 需要重新 subscribe
```

关键排查命令：
- `hermes kanban notify-list` — 查看当前所有订阅。如果为空，说明订阅已被自动清除
- `hermes kanban notify-list <task_id>` — 查看具体任务的订阅状态

### 最佳实践：创建时顺便订阅

当用户在对话中说"开看板任务做xxx"时，**创建任务后立即订阅到当前对话**：

```bash
# 先创建任务
task=$(hermes kanban create "<标题>" \
  --assignee <worker-profile> \
  --skill kanban-task-workflow \
  --body "..." \
  --json | python3 -c "import sys,json; print(json.load(sys.stdin)['task_id'])")

# 再订阅到当前对话
hermes kanban notify-subscribe "$task" \
  --platform feishu \
  --chat-id "<当前对话的chat_id>"
```

注意：当前系统**不支持"自动跟来源走"** — 没有内置"从哪创建就通知到哪"的功能，必须显式 subscribe。

### 订阅失效后的应对

如果用户问"没有收到通知"，处理步骤：

1. `hermes kanban notify-list` — 检查订阅是否还在
2. 如果空 → 重新 subscribe 到当前对话平台
3. 如果存在 → 可能是平台静默丢消息（见下方 WeChat 陷阱）
4. 直接 `hermes kanban list --status blocked` 查状态并回复用户，比重新订阅更快

### 各平台可靠性

| 平台 | 通知可靠性 | 说明 |
|------|-----------|------|
| 飞书 | 高 | 无频率限制问题 |
| 微信 | 低 | 高频对话下通知静默丢失，且3次失败后自动删订阅 |
| 终端 | N/A | notify-subscribe 不适用 |

---

## 看板创建任务时的用法

用户说"开看板任务做xxx"时，主对话 AI 按以下流程执行：

### 自动流程

```bash
# 1. 读取当前编号
source <(grep 'counter=' ~/.hermes/kanban_task_numbers.txt)
next=$((counter + 1))

# 2. 创建任务
# notify_target 由主对话 AI 自动从当前对话提取，无需手动填写
result=$(hermes kanban create "T${next}: <标题>" \
  --assignee <worker-profile> \
  --skill kanban-task-workflow \
  --body "目标: xxx
scope: yyy文件
验收标准: ...
notify_target: <由AI自动填入>
task_number: T${next}")

# 3. 记录编号映射
task_id=$(echo "$result" | grep -oP 't_[a-f0-9]+')
echo "T${next} → ${task_id} <标题>" >> ~/.hermes/kanban_task_numbers.txt
sed -i "s/counter=.*/counter=${next}/" ~/.hermes/kanban_task_numbers.txt

echo "T${next} (${task_id}) 已创建，指派给 <worker>"
```

### 主对话 AI 的职责

创建任务时，主对话 AI 自动执行：
1. **分配 T 编号** — 从映射文件读取下一个编号
2. **提取 notify_target** — 从当前对话自动获取 platform:chat_id，写入 body
3. **通知用户** — 创建完成后告诉用户"T${next} 已创建"
4. **订阅通知** — 立即 subscribe 到当前对话平台

### 你只需要说

```
开T6任务：修复公会创建失败bug，指派worker-1
```

或

```
开新任务：修复公会创建失败bug，指派worker-1
```
（不指定T号时 AI 自动分配下一个）

### 退回修改用法

worker block 后，写 comment（中英文都支持）：

```
T3 当前阶段不通过，修改意见：应该也检查items.txt的数据
```
或指定阶段：
```
T3 方案不通过，修改意见：重新设计拦截位置
```
```
代码不通过，修改意见：编码有问题，用safe_write.py修改
```

然后 unblock → worker 自动检测 comment、退回对应阶段重做。旧产物备份为 .old 供参考。

### 附：支持的 comment 关键词

| 你写的关键词 | 退回阶段 |
|---|---|
| 研究不通过 / research不通过 | Phase 1 Research |
| 方案不通过 / plan不通过 | Phase 2 Plan |
| 代码不通过 / code不通过 | Phase 3 Code |
| 当前阶段不通过（无指定） | 自动检测（见上方"退回阶段自动检测"） |

超过 3 次退回后不再自动循环，直接 block 通知人工介入。

---

## 扩展指南：创建领域特定工作流技能

本技能是**通用版本**。对于特定项目（如 Legend、梦幻西游等），可以基于此模式创建领域专用工作流技能，做法：

1. **复制阶段结构** — 保留 5 阶段 + 3 确认点的框架
2. **替换领域规则** — 把"编码安全规则"替换为项目具体规则
3. **固化编译验证** — 替换 Phase 4 的构建命令为项目特定命令
4. **内置防护** — 编码约束、禁止操作（如 patch 工具）直接写在技能里

**什么时候该创建领域专用版：**
- 项目有独特的编码/编译约束（Legend 的 GBK+CRLF）
- 项目有固定的构建命令路径
- 每次任务都用同一套工具链（如 safe_write.py）

**什么时候直接用通用版：**
- 一次性任务
- 编译/编码没有特殊约束
- 任务 scope 不固定

本通用技能覆盖了 80% 场景，领域专用版用于剩下的 20%。

---

## 已知限制

- **看板状态机只有 6 种状态**（todo/ready/running/blocked/done/archived），不支持 "researching"、"coding" 等自定义阶段状态。本技能通过 workspace 中的中间产物文件（research-findings.md 等）模拟阶段感，底层看板始终只看到 blocked ↔ running ↔ done。**返工循环**（Code Review → Code）通过 unblock 后续跑检测实现，不是真正的状态回退。
- **用户确认点依赖 kanban_block/unblock 机制**：blocked 状态下 worker 进程退出，unblock 后 dispatcher 重新 spawn worker。续跑检测（检查已有的阶段文件）确保不重复劳动。

---

## 故障恢复

### worker 中途被中断（gateway 重启/dispatcher 重调度）
1. 检查 workspace 中已有哪些阶段文件
2. 从缺失的阶段续跑，不重复已完成的阶段
3. 已完成阶段对应的 block 如果已被 unblock，直接进入下一阶段

### 编译失败
1. 记录完整编译日志到 workspace
2. 尝试修复（常见：依赖未更新、编码问题）
3. 重新编译
4. 连续 2 次失败 → `kanban_block(reason="编译失败<日志>")`

### 发现 scope 之外需要改动的文件
1. `kanban_block(reason="发现额外需要修改的文件 xxx，是否纳入？")`
2. 等待用户指示

---

## 禁止事项

- ❌ **不允许执行破坏性系统命令** — 包括但不限于 `rm -rf /`、`format`、覆盖系统配置文件等
- ❌ **不允许跳过用户确认点** — Research→Plan、Plan→Code、Build→Complete 三个 block 点必须等人
- ❌ **不允许修改 TASK.md scope 以外的文件** — 除非用户明确授权
- ❌ **不允许对编码敏感文件使用 patch 工具**
- ❌ **不允许修改文件后不做编码验证**
- ❌ **不允许在 block 前跳过邮件发送或 send_message 通知**
- ❌ **不允许向用户提问** — 后台 worker 没有人在终端前。执行技能指令，不要创造分支路径。

---

## 关键陷阱：通知不可靠（WeChat 静默丢消息 + 订阅自动清除）

**问题**：看板通知**经常无法到达用户**。表现为：
- 创建任务后从未收到任何通知
- `hermes kanban notify-list` 返回空
  
**两个独立原因**：

1. **订阅被自动清除** — WeChat iLink API rate limit 导致通知器连续 3 次发送失败后，自动删除该任务的订阅。这是最可能的原因（见上方「通知订阅机制」的订阅生命周期）。
2. **消息被微信静默丢弃** — 即使订阅还在，网关和用户对话频繁时，block 通知会被微信静默丢弃——不报错、不返回错误码。kanban 通知器的 `adapter.send()` 返回成功，但消息从未到达用户。

**最佳应对**：

当用户问"任务怎么样了？没有收到通知"：
1. `hermes kanban notify-list` — 检查订阅是否存在
2. 如果空 → 重新 subscribe 到当前对话平台
3. 直接查任务状态回复用户，不要依赖重新订阅后的通知来工作

```bash
hermes kanban list --status blocked   # 看谁在等你
hermes kanban list --status running   # 看谁在跑
hermes kanban show <task_id>          # 看详情
```

---

## 参考文档

- `references/task-number-format.md` — T编号映射文件（`~/.hermes/kanban_task_numbers.txt`）的格式说明与读写命令
