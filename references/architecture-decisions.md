# 架构决策记录 — kanban-task-workflow

> 记录了技能的架构决策及其背景，避免后续循环论证。

## ADR-1: 单worker串行执行（2026-05-11）

**上下文**：Code → Code Review → Build（通过时）的切换过程是否需要重启worker？

**决策**：不重启，同一worker进程内连续执行。

**理由**：
- Code、Review、Build（通过时）之间没有人类确认点，不需要中断
- 重启worker需要3-5分钟热身（读TASK.md、续跑检测、重新理解上下文）
- 只有**Review发现问题→block等人→unblock**时才需要重启worker，因为block后worker进程必须退出

**替代方案**：每步都block后重启 — 被拒绝，无收益且有成本。

## ADR-2: 不自动拆分子看板（2026-05-11）

**上下文**：Plan阶段是否可以自动拆分为子看板任务，由多个worker并行执行Code？

**决策**：不实现自动化子看板拆分，保持单worker串行。

**理由**：
- parent无法自动等待子任务完成 — kanban没有built-in wait机制，worker 15分钟超时硬限制，不能写循环轮询
- 无法"删除"子看板 — kanban状态机只有 todo/ready/running/blocked/done/archived，没有delete
- 子看板方案需要外部监控机制（cronjob轮询子任务状态→全部done后unblock parent），复杂度增加但收益有限
- 拆成独立T任务各自跑，效果一样（各任务独立完成），运维负担更低

**替代方案**：子看板并行方案 — 被先生（用户）评估为"没什么好处"，已拒绝。

## ADR-3: "拆子任务"是手动操作（2026-05-11）

**上下文**：技能中"大任务拆成多个子任务"的建议是否应该自动化？

**决策**：保持为手动建议，不实现自动化。

**理由**：
- 子任务拆分依赖人对task scope的理解和判断，不适合算法化
- 技能只提供指导原则（逐文件拆分、逐模块拆分），具体实施由主对话AI执行
- 15分钟超时是基础设施限制，绕过方式是归档重建或手动拆T任务

## ADR-4: 专用审查worker方案评估（2026-05-11，已拒绝）

**上下文**：Code Review阶段仅做机械检查（孤立函数/孤立事件/编码），不做语义检查。是否应通过 delegate_task 派发专用审查worker来做两轮检查（机械+语义）？

**决策**：**已拒绝并回退**。评估后发现6个硬问题，未通过走查。

**拒绝理由**：
1. delegate_task失败无兜底 — 审查worker内部报错/crash退出后无重试机制，无fallback逻辑
2. 审查worker写文件路径不可靠 — 审查worker写code-review-result.md到parent workspace，写错路径/失败/权限不足时parent读到空文件，判定出错
3. 15分钟超时窗口压缩 — Code + delegate_task审查(3-5min) + Build 合计可能超过15分钟硬限制，超时可能从Review阶段触发
4. 决策1声明矛盾 — 决策1写"Code→Review→Build在同一worker进程内连续执行"，delegate_task打破了这一点（Review不在同一进程）
5. 审查worker工具集隐式依赖 — parent worker需有terminal+file工具才能让delegate_task继承，否则审查worker无法执行检查
6. 审查worker上下文不足 — 语义检查需要理解项目全局结构才能判断边界条件/副作用，当前只传了changed_files/plan_items，上下文不够全面

**替代方案**：保持原有单worker内联审查（机械检查3项），语义检查依赖人工在用户确认点把关。先生同意回退。

## ADR-5: Research + Plan 合并为 Design（v2.0.0，2026-05-11）

**上下文**：原技能有独立的 Research 和 Plan 两个阶段，各发一次邮件审核。两个阶段之间没有用户确认点，但 worker 需要两次热身。

**决策**：合并为单一 Design 阶段，产出 design-report.md。

**理由**：
- 两个阶段之间没有人类确认点，分开执行浪费 worker 热身时间（3-5分钟/次）
- 合并后全量轨道保留一次邮件审核，确认点从 3 次（Research→Plan→Build）减到 2 次（Design→Build）
- 旧版 workspace 中的 research-findings.md 和 implementation-plan.md 兼容识别
- Design Report 模板新增「需求分析」章节，弥补之前没有需求确认环节的缺失

**替代方案**：保持拆分 — 被拒绝，无收益且效率更低。

## ADR-6: 双轨制（轻量/全量轨道）（v2.0.0，2026-05-11）

**上下文**：一刀切的邮件审核流程对小改动（bugfix、单文件改动）太重。

**决策**：引入双轨制，任务创建时自动判定或显式指定轨道。

**理由**：
- 轻量轨道：0 次 block，Design 完成后只发通知不等人，直接进编码
- 全量轨道：保留邮件审核，Design 和 Build 各 block 一次等人
- 自动判定规则：单文件/低风险 → light，跨模块/核心改动 → full
- 不增加新阶段或新中间产物，只在 TASK.md 中加一个 `review_track` 字段
- Code Review 通过后自动通知 + 5分钟超时自动进 Build（轻量/全量通用，全量轨道额外有 Build 邮件审核）

## 讨论历史

- 2026-05-11: 先生提出「子看板并行方案」，经评估后确认「不可行 → 没什么好处」，最终决定保持现状。
- 2026-05-11: 先生指出Code Review存在盲点（只查语法不查逻辑），尝试改为专用审查worker（delegate_task）+ 两轮制（v1.4.0）。走查后发现6个硬问题，**回退至v1.3.0**。结论：审查worker方案已拒绝，保持内联机械审查。
- 2026-05-11: v2.0.0 — Research + Plan 合并为 Design 阶段，引入双轨制（轻量/全量）。
