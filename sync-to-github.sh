#!/bin/bash
# kanban-task-workflow 同步脚本
# 将本地技能同步到GitHub，自动脱敏
# 用法: ./sync-to-github.sh [commit message]

set -e

# ====== 配置 ======
LOCAL_DIR="$HOME/.hermes/skills/productivity/kanban-task-workflow"
REPO_DIR="/tmp/kanban-task-workflow-gh"
REPO_URL="https://github.com/lishengyong2015/kanban-task-workflow.git"
BRANCH="main"

# ====== 脱敏映射 ======
declare -A SANITIZE_MAP=(
  ["lishengyong198719@163.com"]="reviewer@example.com"
  ["/home/lsy/.hermes/kanban/workspaces/"]="~/.hermes/kanban/workspaces/"
  ["发送邮件给李总"]="发送审核邮件"
  ["审核邮件已发送至李总邮箱"]="审核邮件已发送至审核人邮箱"
  ["李总邮箱"]="审核人邮箱"
  ["邮件已发送至李总邮箱"]="邮件已发送至审核人邮箱"
)

echo "=== 1. 清理旧构建 ==="
rm -rf "$REPO_DIR"

echo "=== 2. clone GitHub仓库 ==="
git clone "$REPO_URL" "$REPO_DIR" --depth 1

echo "=== 3. 复制本地技能文件（覆盖） ==="
# 拷贝除 .git 外的所有文件
rsync -a --exclude='.git' "$LOCAL_DIR/" "$REPO_DIR/"

echo "=== 4. 脱敏处理 ==="
for file in "$REPO_DIR"/SKILL.md "$REPO_DIR"/README.md "$REPO_DIR"/references/*.md; do
  [ -f "$file" ] || continue
  echo "  处理: ${file#$REPO_DIR/}"
  for old in "${!SANITIZE_MAP[@]}"; do
    new="${SANITIZE_MAP[$old]}"
    sed -i "s|$old|$new|g" "$file"
  done
done

# 同步仓库内的 README（如果本地没有README，从GitHub保留）
if [ ! -f "$LOCAL_DIR/README.md" ]; then
  echo "  注意: 本地没有 README.md，保留 GitHub 版本"
fi

echo "=== 5. 提交并推送 ==="
cd "$REPO_DIR"

# 检查是否有变更
if git diff --quiet && git diff --cached --quiet; then
  # 可能有未跟踪的新文件
  UNTRACKED=$(git ls-files --others --exclude-standard)
  if [ -z "$UNTRACKED" ]; then
    echo "  无变更，跳过提交"
    exit 0
  fi
fi

MSG="${1:-sync: kanban-task-workflow 技能同步更新}"
git add -A
git commit -m "$MSG"
git push origin "$BRANCH"

echo ""
echo "=== ✅ 同步完成 ==="
echo "  提交: $MSG"
echo "  仓库: https://github.com/lishengyong2015/kanban-task-workflow"
