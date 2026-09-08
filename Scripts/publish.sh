#!/usr/bin/env bash
#
# 发布 Sona 到 GitHub
#
# 用法：
#   1. 先登录 GitHub CLI：  gh auth login
#   2. 运行本脚本：         ./Scripts/publish.sh
#
# 脚本会：
#   - 创建公开的 GitHub 仓库（默认名 Sona，可用第一个参数覆盖）
#   - 将当前 main 分支推送上去
#   - 用当前版本号打 tag 并推送（tag 会触发 Release 流程）
#
# 可选参数：
#   ./Scripts/publish.sh MyRepoName        # 自定义仓库名
#   ./Scripts/publish.sh Sona --private    # 创建私有仓库（先内部review再公开）
#

set -euo pipefail

REPO_NAME="${1:-Sona}"
VISIBILITY="${2:---public}"

cd "$(dirname "$0")/.."

echo "==> 检查 gh 登录状态"
if ! gh auth status >/dev/null 2>&1; then
  echo "❌ 尚未登录 GitHub。请先运行："
  echo "     gh auth login"
  exit 1
fi

GH_USER=$(gh api user --jq '.login')
echo "    已登录为: ${GH_USER}"

# 从 Sona.app/Contents/Info.plist 读取版本号
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "Sona.app/Contents/Info.plist" 2>/dev/null || echo "1.0.0")
echo "    当前版本: v${VERSION}"

echo
echo "==> 创建 GitHub 仓库 ${GH_USER}/${REPO_NAME}"
if gh repo view "${GH_USER}/${REPO_NAME}" >/dev/null 2>&1; then
  echo "    仓库已存在，跳过创建"
else
  gh repo create "${REPO_NAME}" "${VISIBILITY}" \
    --description "macOS 原生音乐播放器 · 本地音乐 + 夸克 / 阿里云盘聚合 · 纯 SwiftUI 零依赖" \
    --homepage "https://github.com/${GH_USER}/${REPO_NAME}" \
    --source . \
    --remote origin \
    --push
  echo "    ✅ 仓库已创建并推送"
fi

echo
echo "==> 确保 remote 正确"
if git remote get-url origin >/dev/null 2>&1; then
  git remote set-url origin "https://github.com/${GH_USER}/${REPO_NAME}.git"
else
  git remote add origin "https://github.com/${GH_USER}/${REPO_NAME}.git"
fi

echo
echo "==> 推送 main 分支"
git push -u origin main

echo
echo "==> 打 tag v${VERSION}"
if git rev-parse "v${VERSION}" >/dev/null 2>&1; then
  echo "    tag v${VERSION} 已存在，跳过"
else
  git tag -a "v${VERSION}" -m "Sona v${VERSION}"
  git push origin "v${VERSION}"
  echo "    ✅ tag v${VERSION} 已推送"
fi

echo
echo "==> 发布 Release（附带 Sona.app.zip）"
if gh release view "v${VERSION}" >/dev/null 2>&1; then
  echo "    Release v${VERSION} 已存在，跳过"
else
  if [ -f "Sona.app.zip" ]; then
    gh release create "v${VERSION}" "Sona.app.zip" \
      --title "Sona v${VERSION}" \
      --generate-notes
    echo "    ✅ Release 已发布（含 Sona.app.zip）"
  else
    gh release create "v${VERSION}" --title "Sona v${VERSION}" --generate-notes
    echo "    ✅ Release 已发布（未找到 Sona.app.zip，仅源码）"
  fi
fi

echo
echo "🎉 完成！"
echo "   仓库:   https://github.com/${GH_USER}/${REPO_NAME}"
echo "   Release: https://github.com/${GH_USER}/${REPO_NAME}/releases"
echo
echo "别忘了："
echo "   1. 在仓库 Settings 中确认 Issues / Discussions 已开启"
echo "   2. 上传一张截图作为 Social Preview（Settings → Social preview）"
echo "   3. 在 About 区域填写仓库描述与官网链接"
