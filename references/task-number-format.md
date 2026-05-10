# Kanban Task Number Mapping — 看板T编号映射文件

**文件路径**：`~/.hermes/kanban_task_numbers.txt`

**作用**：将 kanban 内置ID（t_xxxxxxxx）映射为用户可读的 T1/T2/T3 编号，方便用户在对话中快速引用。

## 文件格式

```
# 注释行
# T1 → t_ec2d063f 公会创建bug修复
# T2 → t_4b3663cb 珍宝阁搜索拦截
T1 → t_ec2d063f 公会创建bug修复
T2 → t_4b3663cb 珍宝阁搜索拦截
T3 → t_6b38b1fd 成就刷新冷却
counter=3
```

- `#` 开头的为注释（可选）
- 映射行格式：`T<N> → <task_id> <描述>`
- `counter=` 记录当前最大编号，下一任务自动取 counter+1

## 读取下一个编号

```bash
source <(grep 'counter=' ~/.hermes/kanban_task_numbers.txt)
next=$((counter + 1))
```

## 写入新映射

```bash
echo "T${next} → ${task_id} <标题>" >> ~/.hermes/kanban_task_numbers.txt
sed -i "s/counter=.*/counter=${next}/" ~/.hermes/kanban_task_numbers.txt
```

## 查询某个T号对应的任务ID

```bash
grep "^T3 →" ~/.hermes/kanban_task_numbers.txt | awk '{print $3}'
```

## 主对话 AI 的职责

- 创建任务时自动分配下一个 T 号
- 创建后立即告知用户 "T<N> 已创建"
- block/unblock 通知消息中始终带 T 号而非 t_xxx ID
- 用户说 "T3 unblock" → 查表得 task_id → 执行 kanban unblock
