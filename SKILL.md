---
name: kanban-task-workflow
description: 通用看板任务执行工作流——Design → Code → Code Review → Build → Complete，双轨制（轻量/全量轨道），每阶段有用户确认点。适用于任何看板开发任务。用户发起看板开发时加载此技能。
version: 2.0.0
created: 2026-05-10
updated: 2026-05-11
tags: [kanban, workflow, multi-agent, development]
---

# Kanban Task Workflow — 看板任务执行工作流

> 通用看板任务执行规范，适用于任何开发类 kanban 任务。
> 触发条件：用户发起看板开发任务，或任务 body 中包含"按工作流执行"。
>
> **关联技能：** `kanban-worker`（devops/kanban-worker）— 自动注入每个 worker，提供 kanban 生命周期基础（claim/block/complete/heartbeat）、状态机参考和通知机制。本技能是**上层工作流编排**，kanban-worker 是**底层生命周期**。两个技能配合使用。

## 核心原则

1. **分阶段执行** — Design → Code → **Code Review** → Build → Complete
2. **双轨制** — 轻量轨道（跳过邮件审核，自主完成）和全量轨道（保留邮件审核确认点），由任务复杂度自动判定或在 task body 中显式指定
3. **用户确认点** — 全量轨道关键阶段间 `kanban_block` 等人解锁
4. **代码审查** — Coding 完成后自动审查，含机械检查（孤立函数/孤立事件/编码乱码）和语义检查（功能正确性/边界条件/业务合规性/副作用），有问题退回编码
5. **目标锚点** — 每个阶段开始前重新校准目标
6. **中间产物存档** — 每阶段产出写入 workspace 供后续阶段使用

## 关键设计决策（架构不变项）

以下决策在本技能的生命周期内应视为**已定方案**，后续迭代不应重新辩论：

### 决策1：单worker串行执行（Code→Review→Build为原子块）

Code → Code Review → Build（通过时）在**同一worker进程内连续执行，不重启worker**。原因：
- 三个子步骤之间没有人类确认点，无需中断
- 重启worker需要3-5分钟热身（读TASK.md、续跑检测、重新理解上下文）
- 只有**发现问题需要等人**时才block并重启worker

```mermaid
flow LR
  Code --> Review-->|通过| Build
  Review-->|发现问题| block[kanban_block]-->|unblock后| Code
```

### 决策2：Plan不自动拆分子看板

Plan阶段的产出是**线性改动清单**（`implementation-plan.md`），不会自动拆分成多个子看板任务。评估并拒绝了「子看板并行方案」，原因：
- **parent无法自动等待子任务完成** — kanban没有built-in wait机制，worker 15分钟超时硬限制
- **无法"删除"子看板** — 只能archive，没有delete操作
- **复杂度 > 收益** — 拆成独立T任务各自跑，效果一样，运维负担更低

### 决策3：大任务拆子任务 = 手动操作，非自动化

"拆成多个子任务"是**应对15分钟超时限制的人肉工作流建议**，不是技能自动化功能。当任务scope涉及5+文件或编码量较大时，由主对话AI手动创建多个独立T任务，各自独立运行。

### 决策4：Research + Plan 合并为 Design 阶段（v2.0.0）

原 Research（需求/代码研究）和 Plan（实施方案）**合并为单一 Design 阶段**。原因：
- 两个阶段之间没有人类确认点，分开执行浪费 worker 热身时间
- 合并后全量轨道仍保留一次邮件审核（Design 完成后统一发），确认点从 3 次减到 2 次
- 旧版 workspace 中的 research-findings.md 和 implementation-plan.md 兼容识别

### 决策5：双轨制 — 轻量/全量自动分流（v2.0.0）

任务创建时自动判定轨道，不再一刀切走邮件审核流程：
- **轻量轨道**：单文件改动/bugfix → Design 完成后只发通知，不 block，直接进编码
- **全量轨道**：跨模块/核心改动 → 保留邮件审核，Design 完成后 block 等人
- 轨道可在 task body 中显式指定（`track: full` 或 `track: light`）覆盖自动判定
- 不增加新阶段或新文件，只在 TASK.md 中多一个 `review_track` 字段

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
   - 用户写 "设计不通过" 或 "research不通过" 或 "plan不通过" → 退回到 Phase 1 Design
   - 用户写 "代码不通过" 或 "code不通过" → 退回到 Phase 2 Code
   - 用户写 "当前阶段不通过"（无具体指定）→ 按以下优先级判断退回哪个阶段：
     1. 读取 TASK.md 中的 `current_phase` 字段 → 退回上一个阶段
     2. 若 TASK.md 中无 `current_phase`，检查 workspace 文件：
        - code-review-result.md 存在且标记"发现问题" → 退回 Phase 2 Code
        - build-result.md 存在 → 退回 Phase 3 Build（重新编译）
        - design-report.md 存在 → 退回 Phase 1 Design
        - research-findings.md 存在（旧版兼容） → 退回 Phase 1 Design

   **退回次数防护**：
   - 每次退回前读取 TASK.md 中的 `retreat_count` 字段
   - 如果 `retreat_count >= 3`，不再自动退回，改为直接 block 并通知创建者人工介入
   - 通知内容："⚠️ [介入] ${task_number} ${task_title} 已退回修改 3 次仍未通过，请人工介入处理"
   - 否则：retreat_count += 1，写入 TASK.md

   **中间产物处理（备份替代删除）**：
   - 不再直接删除，改为备份：`mv xxx.md xxx.md.old`
   - 备份文件供 worker 后续阶段参考（worker 可以看到旧的方案/代码分析）
   - 示例：退回 Phase 2 时 → `mv design-report.md design-report.md.old`（无 design-report.md 则备份 implementation-plan.md.old）
   - 退回 Phase 3 时 → 保留 design-report.md，删除 build-result.md（备份为 .old）
   - 退回 Phase 1 时（从 Phase 3+ 深层退回）→ 所有阶段文件（design-report.md、code-review-result.md、build-result.md 等）全部备份为 .old，只留 TASK.md

4. 创建 `TASK.md` — 写入 workspace 目录：
   - 从 task body 中提取 `notify_target: <平台>:<chat_id>`（如 `feishu:oc_xxx`）
   - 如 body 中没有 notify_target，默认发到当前对话
   - 读取 `~/.hermes/kanban_task_numbers.txt` 获取当前 T-number
   - **自动判定轨道**（`review_track`）：从 task body 中提取 `track` 字段，若无则按以下规则自动判定：
     - 单文件改动 → `light`
     - 2-3 文件 + 非核心模块 → `light`
     - 改核心模块（Events.h 事件注册、数据库、跨进程通信）→ `full`
     - 改 4+ 文件 → `full`
     - body 显式写了 `track: full` 或 `track: light` → 直接使用

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
review_track: light    # light: 通知不block | full: 邮件+block
```

5. 加载任务 body 中提到的关联技能
6. 检查 workspace 中是否已有 Phase 1+ 的中间产物 → 若有则续跑
7. **续跑检测**：如果 `design-report.md` 已存在且完整，跳过 Phase 1 直接从 Phase 2（编码）开始；如果 `design-report.md` 不存在但 `research-findings.md` 和 `implementation-plan.md` 都存在（旧版 workspace 兼容），则从 Phase 2 开始

---

## 阶段流程

### Phase 1: Design — 需求分析 + 代码研究 + 方案设计

> 本阶段将原来的 Research（代码/需求研究）和 Plan（实施方案）合并为一次执行。
> 两个子步骤之间没有人类确认点，合并可减少 worker 热身时间和一次邮件来回。

**入口**：重新读取 `TASK.md` 校准目标

**执行**：

**子步骤 A — 需求分析：**
1. 检查需求是否完整、scope 定义是否清晰、验收标准是否可测量
2. 如果需求模糊或 scope 不完整 → `kanban_block` 让创建者澄清
3. 记录需求分析结论

**子步骤 B — 代码研究：**
1. 读取 scope 列出的目标文件
2. 理解现有结构、模式、关键位置
3. 识别风险点（依赖关系、编码约束、API 兼容性）

**子步骤 C — 方案设计：**
1. 根据研究结果制定逐文件改动计划
2. 明确每个文件的改动方式（新增/修改/删除）
3. 明确编码约束（文件编码、行终止符等）
4. 明确编译验证步骤
5. 检查是否有用户特别约束（如安全规则、文件保护）
6. **设计原则约束：方案必须符合以下 SOLID 原则，不得违反：**
   - **开闭原则 OCP** — 对扩展开放，对修改封闭。新增功能应通过扩展实现，不应修改已有的稳定代码
   - **单一职责原则 SRP** — 每个类/函数只负责一个职责，不应出现"万能函数"
   - **里氏替换原则 LSP** — 子类应能替换父类，派生类不应破坏基类的行为约定
   - **接口隔离原则 ISP** — 接口应当小而专，不应强迫依赖方实现不需要的方法
   - **依赖倒置原则 DIP** — 高层模块不应依赖低层模块，两者应依赖抽象（接口/抽象类）

**产出**：`workspace/design-report.md`（兼容旧版：如果 `research-findings.md` 和 `implementation-plan.md` 都存在，视为 Design 阶段已完成）
```markdown
# Design Report — <task_id>

## 需求分析
- 目标是否清晰：[是/否]
- scope 有无遗漏：[是/否，列出可能遗漏点]
- 验收标准可测量：[是/否]

## 分析的文件
- path/to/file1: 关键函数/结构分析
- path/to/file2: 需要修改的位置

## 关键发现
- 当前实现的核心流程
- 需要修改的精确位置（行号/函数名）
- 潜在风险

## 改动方案
| 文件 | 操作 | 改动内容 | 编码约束 |
|------|------|---------|---------|
| path/file1.cpp | 修改 | 函数XXX添加逻辑 | GBK/CRLF |
| path/file2.h | 新增 | 声明XXX | GBK/CRLF |

## SOLID 合规检查
- [ ] OCP — 新增通过扩展实现，未修改稳定代码
- [ ] SRP — 每个类/函数职责单一
- [ ] LSP — 子类可替换父类，未破坏基类约定
- [ ] ISP — 接口小而专，无胖接口
- [ ] DIP — 高层依赖抽象，非具体实现

## 编码注意事项
- 文件编码检测：`file xxx.cpp`
- 修改方法：二进制读写 decode('gbk')，禁止使用 patch 工具（会破坏编码）

## 验证步骤
1. 编译命令
2. 验证可执行文件存在
3. 检查编码
```

**出口**（依次执行，禁止跳过）：

**STEP 1** — 校验设计是否偏离 TASK.md 目标

**STEP 2** — 校验计划范围是否与 TASK.md scope 一致

**STEP 3** — 判断轨道，分支执行：

**分支 A — 轻量轨道（`review_track: light`）：**
1. `sed -i "s/current_phase:.*/current_phase: phase1/" ~/.hermes/kanban/workspaces/${task_id}/TASK.md`
2. send_message: `target=notify_target, message="ℹ️ [设计完成] ${task_number} ${task_title} 设计方案已出 (轻量轨道，跳过审核直接进入编码阶段)"`
3. 不 block，直接进入 Phase 2（编码）

**分支 B — 全量轨道（`review_track: full`）：**
1. 发送审核邮件（含 Design Report 附件）：
```
terminal: python3 ~/.openclaw/workspace/skills/email-sender/scripts/send_email.py \
  --to reviewer@example.com \
  --subject "[审核] ${task_id} 设计方案完成 - ${task_title}" \
  --body "设计方案已完成，请审核附件中的设计文档后回复确认或提出修改意见。如需继续下一阶段，我将在收到确认后进入编码实现。" \
  --attach ~/.hermes/kanban/workspaces/${task_id}/design-report.md \
  --body-type plain
```
2. 发送通知给创建者：
```
send_message: target=notify_target, message="⊘ [blocked] ${task_number} 设计方案完成，审核邮件已发送至审核人邮箱，请查阅"
```
3. `sed -i "s/current_phase:.*/current_phase: phase1/" ~/.hermes/kanban/workspaces/${task_id}/TASK.md`
4. `kanban_block(reason="设计方案完成，邮件已发送至审核人邮箱，等待审核确认后 unblock")`
5. 等待用户 unblock 后进入 Phase 2（编码）

> ⚠️ 铁律：以上步骤禁止跳过。分支判定只需检查 TASK.md 中的 `review_track` 字段，不要问用户走哪个轨道。

### Phase 2: Code — 编码实现

**入口**：
1. 重新读取 `TASK.md` 校准目标
2. 读取 `design-report.md` 获取改动方案（旧版兼容：若无则读 `implementation-plan.md`）

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
3. 不 block，直接进入 Phase 2.5 Code Review

---

### Phase 2.5: Code Review — 代码审查

**入口**：
1. 重新读取 `TASK.md` 校准目标
2. 确认所有文件改动已完成

**执行**：

审查所有涉及文件，逐项检查以下三类问题：

**1. 孤立函数检查（Orphan Functions）**
- 在 .h 文件中声明了但在 .cpp 中未实现的函数（只有签名没有实现体）
- 在 .cpp 中实现但在任何 .h 中未声明的函数（无法被外部调用）
- 已删除的旧函数对应的声明/实现未被清理
- **新增接口零调用检查** — 本次改动新增的函数/接口，搜索整个项目确认是否有至少一处调用（除自身定义和注册语句外），零调用的新增接口视为设计问题，必须退回

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

**3. 编码混乱检查（Encoding Corruption）** — **重点：防止中文乱码**
- 所有修改过的 .cpp/.h/.c 文件编码验证
- 编码验证通过 `file` 命令确认文件编码未被破坏（GBK/GB2312/GB18030 文件应保持 ISO-8859 输出，不应变为 UTF-8）
- **中文内容完整性验证** — 对每个修改过的文件，pick 2~3 行含中文的代码（从改动内容中选取已知的中文字符串），用 `grep` 或 `python3 -c "print(open('f','rb').read().decode('gbk').encode('utf-8').decode('utf-8'))"` 验证中文是否可以被正常 decode，不可读则说明编码被破坏、必出乱码

检查方法：
```bash
# Step 1: 检测文件编码
for f in path/to/file1.cpp path/to/file2.h; do
  result=$(file "$f")
  echo "$result"
  if echo "$result" | grep -q "ISO-8859\\|ASCII\\|Non-ISO extended-ASCII"; then
    echo "  → 编码 OK (GBK/GB18030 系)"
  else
    echo "  → ⚠️ 编码异常！可能被破坏为 UTF-8，中文将乱码"
  fi
done

# Step 2: 验证中文内容完整性
# 从设计报告改动方案中选一个已知的中文字符串，如"创建公会"
python3 -c "
import os, glob
# 取修改的文件列表
files = ['path/to/file1.cpp', 'path/to/file2.h']
for f in files:
    try:
        raw = open(f, 'rb').read()
        text = raw.decode('gbk')
        # 验证已知中文关键词可读
        if '创建' in text or '公会' in text:
            print(f'{f}: 中文内容可读 ✅')
        else:
            print(f'{f}: ⚠️ 未找到中文关键词，文件可能被破坏')
    except:
        print(f'{f}: ⚠️ decode(gbk) 失败，编码已破坏！')
"
```

**4. 功能正确性检查（Function Correctness）**
- 逐条对照 design-report.md（或旧版 implementation-plan.md）改动清单 → 代码是否完成了每一条？
- 是否有遗漏的修改点（plan写了但代码没改）？
- 是否有多余的修改（代码改了但plan没写）？

**5. 边界条件检查（Boundary Conditions）**
- 新增代码中指针/引用的地方：有判空吗？
- 数组/容器访问：有越界风险吗？
- 字符串操作：有截断/溢出风险吗？
- 新分支/if-else：所有分支覆盖了？有遗漏else吗？
- 函数返回值：检查了错误码吗？

**6. 业务合规性检查（Business Compliance）**
- 改动内容是否在 TASK.md scope 范围内？
- 改动是否满足所有 success_criteria 验收标准？
- 是否引入了scope之外的非必要改动？

**7. 副作用检查（Side Effects）**
- 扫描所有改动文件列表，逐一确认是否在scope内
- 有scope之外的文件改动 → 标记为超范围，需要退回

**产出**：`workspace/code-review-result.md`
```markdown
# Code Review Result — <task_id>

## 编码检查（含中文乱码验证）
- path/file1.cpp — ISO-8859, CRLF ✅，中文内容可读 ✅
- path/file2.h — ISO-8859, CRLF ✅，中文内容可读 ✅

## 孤立函数检查
- 无异常 ✅（所有声明均有对应实现）
- 新增接口零调用：无异常 ✅（所有新增接口均有调用方）

## 孤立事件检查
- EVENT_XXX — 已定义 ✅ → 已注册 AddNotifyHandler ✅ → 有 PostEvent 调用 ✅

## 功能正确性
- 改动点1（来自implementation-plan）: ✅ 已实现
- 改动点2（来自implementation-plan）: ✅ 已实现

## 边界条件
- 文件A 函数B 指针判空: ✅ / ❌ 未判空
- 文件C 数组访问: ✅ / ❌ 越界风险

## 业务合规性
- scope内: ✅ / ❌ 超范围改动
- 验收标准满足: ✅ / ❌ 不满足

## 副作用
- 改动文件均在scope内: ✅ / ❌ 有超范围文件

## 审查结论
[通过 / 发现 X 个问题（机械/语义）]
```

**出口**（分支逻辑）：

**分支 A — 审查通过，无问题：**
1. 写入 code-review-result.md（结论：通过）
2. **发送通知给创建者**（不经邮件，轻量通知）：
   ```
   send_message: target=notify_target, message="✅ [review通过] ${task_number} 代码审查通过，5分钟后自动编译。如需暂停请回复 stop"
   ```
3. 等待 5 分钟（如收到创建者回复"stop"则 block 等人，否则超时后自动进入 Phase 3 Build）

**分支 B — 发现问题，需返工：**
1. 写入 code-review-result.md（列出具体问题）
2. **发送审核邮件**（附审查报告）：
   ```
   terminal: python3 ~/.openclaw/workspace/skills/email-sender/scripts/send_email.py \
     --to reviewer@example.com \
     --subject "[审查] ${task_id} 代码审查发现问题 - ${task_title}" \
     --body "代码审查发现以下问题：\n1. 编码问题：...\n2. 孤立函数：...\n3. 孤立事件：...\n\n将退回编码阶段修复。" \
     --attach ~/.hermes/kanban/workspaces/${task_id}/code-review-result.md \
     --body-type plain
   ```
3. **发送通知给创建者**：
   ```
   send_message: target=notify_target, message="🔄 [review] ${task_number} 代码审查发现问题，已退回编码阶段修复，查收邮件"
   ```
4. 记录阶段并阻塞：
```
sed -i "s/current_phase:.*/current_phase: phase2_5/" ~/.hermes/kanban/workspaces/${task_id}/TASK.md
kanban_block(reason="代码审查发现 X 个问题（编码/孤立函数/孤立事件），已退回编码阶段。审核邮件已发送至审核人邮箱")
```
5. 用户 unblock 后 → **重新进入 Phase 2 Code**（续跑检测跳过 Phase 1 直接回到编码）

---

### Phase 3: Build — 编译验证

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

**STEP 3** — 判断轨道，分支执行：

**分支 A — 轻量轨道（`review_track: light`）：**
1. 不 block，直接进入 Phase 4 Complete

**分支 B — 全量轨道（`review_track: full`）：**
1. 发送审核邮件（含编译结果附件）：
```
terminal: python3 ~/.openclaw/workspace/skills/email-sender/scripts/send_email.py \
  --to reviewer@example.com \
  --subject "[审核] ${task_id} 编译完成 - ${task_title}" \
  --body "编译验证通过（0 error），请审核附件中的编译结果文档后回复确认。如需完成收尾，我将在收到确认后执行完成总结。" \
  --attach ~/.hermes/kanban/workspaces/${task_id}/build-result.md \
  --body-type plain
```
2. 发送通知给创建者：
```
send_message: target=notify_target, message="⊘ [blocked] ${task_number} 编译完成（0 error），审核邮件已发送至审核人邮箱，请查阅"
```
3. `sed -i "s/current_phase:.*/current_phase: phase3/" ~/.hermes/kanban/workspaces/${task_id}/TASK.md`
4. `kanban_block(reason="编译完成，邮件已发送至审核人邮箱，等待审核确认后 unblock")`
5. 等待用户 unblock 后进入 Phase 4

> ⚠️ 铁律：以上步骤禁止跳过。不要问问题。直接执行。

---

### Phase 4: Complete — 完成总结

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
        "phases_completed": ["design", "code", "code_review", "build"],
        "changed_files": ["path/file1", "path/file2"],
        "build_errors": 0,
        "build_warnings": 0,
    },
)
```

---

## 用户确认点一览

| 轨道 | 阶段间 | Block 原因 | 通知内容示例 | 用户需要做什么 |
|------|--------|-----------|-------------|--------------|
| 全量 | Design → Code | 设计方案完成 | ⊘ [blocked] T6 设计方案完成，审核邮件已发送 | 查收邮件，审核 design-report.md 附件，回复后 unblock |
| 全量 | Code Review → Code（返工） | 审查发现问题 | 🔄 [review] T6 代码审查发现问题，已退回编码 | 查收邮件，审核 code-review-result.md，确认问题后 unblock |
| 全量 | Build → Complete | 编译完成 | ⊘ [blocked] T6 编译完成（0 error），审核邮件已发送 | 查收邮件，审核 build-result.md 附件，确认编译通过后 unblock |
| 全量/轻量 | 退回超3次 | 人工介入 | ⚠️ [介入] T6 已退回3次仍未通过 | 人工查看 worker 执行情况，直接处理 |
| 轻量 | Design → Code | 设计完成（通知不block） | ℹ️ [设计完成] T6 设计方案已出，直接进入编码 | 无需操作，如需审核请在通知后回复 block |
| 轻量 | Code Review → Build | 审查通过（通知不block） | ✅ [review通过] T6 代码审查通过，5分钟后自动编译 | 如需暂停请在5分钟内回复 stop |
| 轻量 | Build → Complete | 编译完成（通知不block） | 无通知，自动进入完成 | 无需操作 |

**注意**：
- **全量轨道**：Design 和 Build 两个确认点 block 等人，共 2 次邮件审核
- **轻量轨道**：0 次 block，Code Review 通过后 5 分钟超时自动进 Build

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
3. **自动判定轨道** — 根据 scope 涉及文件数判断 `review_track`（light/full），写入 body：
   - 单文件/低风险 → `track: light`
   - 跨模块/核心改动/4+文件 → `track: full`
   - 用户指定的轨道优先覆盖自动判定
4. **评估任务规模** — 如果 scope 涉及 5+ 个文件的修改或编码量较大，创建时加上 `--max-runtime 30m`（或更长），避免默认 15 分钟超时中断
5. **通知用户** — 创建完成后告诉用户"T${next} 已创建，轨道: light/full"
6. **订阅通知** — 立即 subscribe 到当前对话平台

### 主对话 AI 处理用户退回指令

当用户说"驳回到 X 阶段"（而不是 worker 自动退回）时，主对话 AI 需手动执行：

1. **写 comment** — 记录退回原因和用户意见到任务
2. **unblock** — 如果任务处于 blocked 状态，先 unblock
3. **更新 TASK.md** — 手动改 current_phase 为目标阶段、retreat_count += 1、加 retreat_reason 字段
4. **备份中间产物** — 将 workspace 中的阶段文件（design-report.md、build-result.md、code-review-result.md 等）重命名为 `.old`，让 worker 下一轮从零开始

```bash
cd ~/.hermes/kanban/workspaces/${task_id}/
mv design-report.md design-report.md.old 2>/dev/null; true
mv implementation-plan.md implementation-plan.md.old 2>/dev/null; true
mv build-result.md build-result.md.old 2>/dev/null; true
mv code-review-result.md code-review-result.md.old 2>/dev/null; true
# ... 其他阶段文件同理
```

注意：如果是 worker 自己检测 comment 后自动退回，worker 内部会执行备份和 TASK.md 更新，主对话 AI 不需要介入。只有当**用户直接在对话中说"驳回到X阶段"**时才需要手动处理。

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

**注意：worker 自动退回只适用于 Phase 1~3 之间的循环退回。如果用户在对话中要求"驳回到第一阶段"而任务已到 Phase 4（编译完成），worker 检测不到 comment（因为 block 在邮箱确认阶段，worker 不会自动调度）。此时需要主对话 AI 手动处理**（见上方「主对话 AI 处理用户退回指令」）。

### 附：支持的 comment 关键词

| 你写的关键词 | 退回阶段 |
|---|---|
| 设计不通过 / 研究不通过 / research不通过 / plan不通过 | Phase 1 Design |
| 代码不通过 / code不通过 | Phase 2 Code |
| 当前阶段不通过（无指定） | 自动检测（见上方"退回阶段自动检测"） |

超过 3 次退回后不再自动循环，直接 block 通知人工介入。

**注意**：worker 自动退回只适用于 Phase 1~2 之间的循环退回（Design ↔ Code）。如果任务已到 Phase 3（编译完成）且 block 在邮箱确认阶段，用户说"驳回到第一阶段"时 worker 检测不到 comment，需要主对话 AI 手动处理（见「主对话 AI 处理用户退回指令」）。

---

## 扩展指南：创建领域特定工作流技能

本技能是**通用版本**。对于特定项目（如 Legend、梦幻西游等），可以基于此模式创建领域专用工作流技能，做法：

1. **复制阶段结构** — 保留 4 阶段 + 2 确认点（全量）或 0 确认点（轻量）的框架
2. **替换领域规则** — 把"编码安全规则"替换为项目具体规则
3. **固化编译验证** — 替换 Phase 3 的构建命令为项目特定命令
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

- **看板状态机只有 6 种状态**（todo/ready/running/blocked/done/archived），不支持 "designing"、"coding" 等自定义阶段状态。本技能通过 workspace 中的中间产物文件（design-report.md 等）模拟阶段感，底层看板始终只看到 blocked ↔ running ↔ done。**返工循环**（Code Review → Code）通过 unblock 后续跑检测实现，不是真正的状态回退。
- **用户确认点依赖 kanban_block/unblock 机制**：blocked 状态下 worker 进程退出，unblock 后 dispatcher 重新 spawn worker。续跑检测（检查已有的阶段文件）确保不重复劳动。

## Worker 运行时配置

### 默认超时

Worker 的默认运行超时约为 15 分钟（903s），超时后 dispatcher SIGTERM（再 SIGKILL）worker 并重新调度。重跑时通过续跑检测恢复上下文。

### 调大超时

**两种方式**：

1. **创建任务时指定**（推荐，针对大任务）：
   ```bash
   hermes kanban create "标题" \
     --assignee worker-1 \
     --max-runtime 30m    # 支持: 90s, 30m, 2h, 1d
   ```

2. **全局设置**（影响所有新调度任务，不影响已创建任务）：
   ```bash
   hermes config set kanban.max_runtime 30m
   ```
   ⚠️ 注意：该全局设置在已创建的运行中任务上不生效。如果任务已创建但还没开始跑，需要先 `hermes kanban archive` 再重建。

### 超时影响

- 代码修改已写入物理文件（持久化），不会丢失
- 重跑时 worker 读取 workspace 中间产物（TASK.md、design-report.md 或 implementation-plan.md）进行续跑
- **续跑时必须检查源文件 mtime**：前一轮可能已修改部分代码但没来得及记录完成状态。用 `stat --format='%y'` 检查文件时间戳，对照 design-report.md（或旧版 implementation-plan.md）中的改动清单，逐文件确认是否已修改
- 每次重跑都会浪费约 5-10 分钟的热身时间（重新理解上下文、检查已改文件）
- **大任务由主对话AI手动拆成多个独立T任务**，而非依赖调大超时或子看板并行（见「关键设计决策」）

### ⚠️ 已知限制：`--max-runtime` 可能不生效

**关键踩坑（2026-05-10 实测）**：即使任务创建时显式传了 `--max-runtime 30m`，worker 仍然在 903 秒（约 15 分钟）被 reclaim。可能原因：
- `--max-runtime` 对 `reclaim` 超时（stale_lock detection）无影响，只影响 dispatch 阶段的调度超时
- 或者该版本不支持 per-task max-runtime 覆盖

**应对策略**：
- 如果 15 分钟不够，不要依赖 `--max-runtime` 延长时间
- 而是由主对话AI手动拆成多个独立T任务，每个控制在15分钟内可完成（如逐文件拆分、逐模块拆分）——本技能不提供自动化拆分（见「关键设计决策」）
- 或者走归档+重建流程（见下方「重创任务流程」）

---

## 故障恢复

### worker 中途被中断（timeout/reclaim/重调度）
1. 检查 workspace 中已有哪些阶段文件
2. 从缺失的阶段续跑，不重复已完成的阶段
3. **关键**：对于 Code 阶段被中断的情况，还要检查**项目源文件的修改时间戳**（`stat --format='%y' <files>`），因为前一轮可能已经改了一部分代码但没来得及记录完成状态。对照 design-report.md（或旧版 implementation-plan.md）中的改动清单，逐文件确认是否已修改，避免重复或遗漏。
4. ⚠️ 默认 worker 运行超时约 15 分钟（903 秒）。如果 coding 任务涉及 5+ 个文件的大改动，考虑：
   - 由主对话AI手动拆分成多个独立T任务（逐文件/逐模块拆分），每任务控制在 15 分钟可完成——本技能不提供自动化拆分
   - 或者跟创建者沟通是否需要放宽超时限制
5. **重创任务流程（当调大超时仍不够，或需要重建上下文时）**：
   - `hermes kanban archive <task_id>` — 归档当前任务（代码修改已写入磁盘，不受影响）
   - 创建新任务时加 `--max-runtime 30m`（或更长）
   - **复制旧工作区文件到新工作区**，让新 worker 可以续跑：
     ```bash
     cp ~/.hermes/kanban/workspaces/<old_id>/design-report.md \
        ~/.hermes/kanban/workspaces/<new_id>/ 2>/dev/null
     cp ~/.hermes/kanban/workspaces/<old_id>/implementation-plan.md \
        ~/.hermes/kanban/workspaces/<new_id>/ 2>/dev/null
     ```
   - 如果旧版 Research 阶段产物（research-findings.md）也有价值，一并复制
   - 注意：TASK.md 会被新 worker 自动重新生成，无需复制
6. 已完成阶段对应的 block 如果已被 unblock，直接进入下一阶段

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
- ❌ **不允许跳过用户确认点** — 全量轨道的 Design→Code、Build→Complete 两个 block 点必须等人。轻量轨道无 block 点，但 Code Review 通过后通知发出时用户可回复 stop 暂停
- ❌ **不允许修改 TASK.md scope 以外的文件** — 除非用户明确授权
- ❌ **不允许对编码敏感文件使用 patch 工具**
- ❌ **不允许修改文件后不做编码验证**
- ❌ **不允许在 block 前跳过邮件发送或 send_message 通知**
- ❌ **不允许向用户提问** — 后台 worker 没有人在终端前。执行技能指令，不要创造分支路径。

---

## 通知机制：send_message vs notify-subscribe

### 两条通知路径

看板任务的状态通知走**两条独立路径**：

| 路径 | 发送方 | 机制 | 可靠性 |
|------|--------|------|--------|
| Worker 内部 send_message | Kanban worker（子智能体） | 在 Phase 出口调用 `send_message` 工具向 notify_target 发消息 | **✅ 可用** — detached worker 无 origin 时需配显式 target |
| kanban notify-subscribe | Gateway 通知器（dispatcher） | 任务状态变化时自动推送到订阅的平台 | **❌ 不可靠** — WeChat 限流/静默丢消息 |

### 路径一：Worker 的 send_message 可用（需注意 detached 场景）

技能在每个阶段的出口都要求 worker 执行 `send_message` 通知创建者。现在 **kanban worker 的工具集中已加入 `send_message` 工具**，可以直接调用。

**注意事项**：
- `target="origin"` 发回到触发该任务的对话。对于 detached/scheduled worker（无 active conversation context），origin 不存在，消息发不出去。此时需要在 TASK.md `notify_target` 中指定显式平台（如 `telegram` 或 `feishu`），worker 用 `send_message(target=notify_target, message=...)`。
- 即使 send_message 可用，**邮件仍是 worker 最可靠的外部通知通道**（不依赖任何对话上下文）。
- 发完通知后应配合 `kanban_comment` 留底，方便追溯。
- `send_message` 不能替代 `kanban_complete`，任务完成必须调 complete。

**工作流修正**：各阶段出口中的 "STEP 3 发送通知给创建者" 现在 worker 可以实际执行。但考虑到 detached 场景可能需要显式 target，建议 worker 从 TASK.md 读取 `notify_target`，如果值是 "origin" 但无 active origin，改用邮件通知作为保底。

### 路径二：notify-subscribe 被自动清除（二次失效）

整体流程见下方"微信/飞书通知可靠性"章节。  

## 关键陷阱二：Worker 默认运行超时（15分钟限制）

Worker 的默认运行超时约为 **15 分钟（903 秒）**，超时后 dispatcher SIGTERM → SIGKILL 并重新调度。这是一个高频踩坑点。

### 调大超时的尝试与结果

**两种方式**：

1. **创建任务时指定 `--max-runtime`**：
   ```bash
   hermes kanban create "标题" --assignee worker-1 --max-runtime 30m
   ```
   支持格式：`90s`, `30m`, `2h`, `1d`

2. **全局设置**（影响新调度的任务）：
   ```bash
   hermes config set kanban.max_runtime 30m
   ```

**⚠️ 踩坑（2026-05-10 实测）**：即使设置了 `--max-runtime 30m`，worker 仍然在 903 秒被 reclaim。说明 per-task `--max-runtime` 在 reclaim 阶段未生效，可能只影响调度的超时阈值，不影响 stale_lock 检测的 15 分钟硬限制。

**应对策略**：
- **不要依赖调大超时**来解决复杂长任务
- **拆任务**：大任务拆成多个子任务，每个控制在 15 分钟内可完成（如逐文件拆分、逐模块拆分）
- 如果必须重建：归档旧任务 → 创建新任务（带 `--max-runtime`）→ 复制旧 workspace 的 implementation-plan.md 到新 workspace → 新 worker 续跑

### 超时后的续跑检测

当 worker 被中断后重跑时，**不能只看 workspace 中的阶段文件**，因为代码可能已经修改了源文件但没来得及更新 workspace：

```bash
# 检查源文件修改时间，推断编码进度
stat --format='%y %n' /path/to/modified/files/*.cpp /path/to/modified/files/*.h | sort -k2
# 对照 implementation-plan.md 中的改动清单，逐文件确认是否已修改
```

文件修改时间在 15 分钟窗口内的，说明前一轮已改过或部分改过。重跑时不再重复修改，而是检查完整性后继续。

## 微信/飞书通知可靠性（完整分析）

### 问题表现

看板通知**经常无法到达用户**。表现为：
- 创建任务后从未收到任何通知
- `hermes kanban notify-list` 返回空

### 完整失效链路（多路径分析）

看板任务的状态通知走**两条路径**，send_message 可用后通知可靠性显著提升：

| 路径 | 发送方 | 机制 | 当前状态 |
|------|--------|------|---------|
| Worker 内 `send_message` | Kanban worker | 在 Phase 出口调用 `send_message` 工具向 notify_target 发消息 | **可用**（v2.1.0），detached worker 需用显式 target |
| `notify-subscribe` 自动通知 | Gateway 通知器 | 任务状态变化时推送到订阅平台 | 微信限流 3 次后自动删除订阅，**不靠谱** |

### 两个独立原因

1. **订阅被自动清除** — WeChat iLink API rate limit 导致通知器连续 3 次发送失败后，自动删除该任务的订阅。这是最可能的原因（见上方「通知订阅机制」的订阅生命周期）。
2. **消息被微信静默丢弃** — 即使订阅还在，网关和用户对话频繁时，block 通知会被微信静默丢弃——不报错、不返回错误码。kanban 通知器的 `adapter.send()` 返回成功，但消息从未到达用户。

### 最佳应对

当用户问"任务怎么样了？没有收到通知"：

1. `hermes kanban notify-list` — 检查订阅是否存在
2. 如果空 → 重新 subscribe 到当前对话平台（但仍可能再被限流删除）
3. **最可靠方式**：直接查任务状态回复用户：
   ```bash
   hermes kanban list --status blocked   # 看谁在等你
   hermes kanban list --status running   # 看谁在跑
   hermes kanban show <task_id>          # 看详情
   ```
4. 如果还需要知道更多细节，检查 workspace 中间产物：
   ```bash
   ls ~/.hermes/kanban/workspaces/<task_id>/
   ```
   以及项目源文件修改时间：
   ```bash
   stat --format='%y %n' /path/to/scope/files  | sort
   ```

### 策略建议：send_message 首选，notify-subscribe 备用

- **首选**：worker 直接用 `send_message` 发通知给创建者（detached 场景配显式 target）
- **备用**：邮件发给李总（最可靠，不依赖对话上下文）
- **不推荐**：依赖 notify-subscribe 自动推送（微信不可靠）
- **兜底**：主对话 AI 定期轮询看板状态，主动告知用户

---

## 参考文档

- `references/task-number-format.md` — T编号映射文件（`~/.hermes/kanban_task_numbers.txt`）的格式说明与读写命令
- `references/publish-to-github.md` — 将 Hermes 技能发布到 GitHub 仓库的完整工作流（含发布前 diff 验证 + API 上传 + git push 备选）
- `references/t7-notification-failure-case.md` — 2026-05-10 完整案例复盘：T7 任务从创建→5次调度→退回→重新编码→完成的完整过程，含通知双路径失效分析、--max-runtime 失效、退回到第一阶段的手动操作等关键教训
- `references/architecture-decisions.md` — 关键架构决策记录（单worker串行、不拆子看板、手动拆任务等），避免后续重新辩论
