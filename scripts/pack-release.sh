#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# 分发者侧打包脚本：产出给收件人下载的项目 zip
# 收件人拿到 zip → 一键启动 → start 脚本自动下载运行时（自举式）
#
# 用法:
#   bash scripts/pack-release.sh             # dist 缺失时才构建
#   bash scripts/pack-release.sh --rebuild   # 强制重新构建前端/MCP
# 产物: _release/QianFanSync-<版本>.zip（mac/Windows 收件人同一个包）
# ============================================================

REBUILD=0
[[ "${1:-}" == "--rebuild" ]] && REBUILD=1

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
RELEASE_DIR="$PROJECT_ROOT/_release"
VERSION="$(tr -d '[:space:]' < "$PROJECT_ROOT/versions" 2>/dev/null || echo "dev")"
STAGE="$RELEASE_DIR/QianFanSync-$VERSION"

info()  { echo "  [INFO] $1"; }
ok()    { echo "  [OK]   $1"; }
fail()  { echo "  [FAIL] $1"; exit 1; }

echo "============================================"
echo "  打包分发包: QianFanSync-$VERSION"
echo "============================================"

# ------------------------------------------------------------
# 1. 预检 + 现场构建（保证产物新鲜）
# ------------------------------------------------------------
if [[ ! -f "$PROJECT_ROOT/frontend/dist/index.html" || "$REBUILD" == "1" ]]; then
    info "构建前端 dist..."
    if [[ ! -d "$PROJECT_ROOT/frontend/node_modules" ]]; then
        (cd "$PROJECT_ROOT/frontend" && npm install --registry=https://registry.npmmirror.com)
    fi
    (cd "$PROJECT_ROOT/frontend" && npm run build)
fi
[[ -f "$PROJECT_ROOT/frontend/dist/index.html" ]] || fail "frontend/dist/index.html 缺失，前端构建失败"

if [[ ! -f "$PROJECT_ROOT/backend-mcp/dist/index.js" || "$REBUILD" == "1" ]]; then
    info "构建 backend-mcp..."
    if [[ ! -d "$PROJECT_ROOT/backend-mcp/node_modules" ]]; then
        (cd "$PROJECT_ROOT/backend-mcp" && npm install --registry=https://registry.npmmirror.com)
    fi
    (cd "$PROJECT_ROOT/backend-mcp" && npm run build)
fi
[[ -f "$PROJECT_ROOT/backend-mcp/dist/index.js" ]] || fail "backend-mcp/dist/index.js 缺失，MCP 构建失败"

# ------------------------------------------------------------
# 2. 装配 staging 目录
# ------------------------------------------------------------
rm -rf "$STAGE"
mkdir -p "$RELEASE_DIR"
rsync -a \
    --exclude '.git' \
    --exclude '.github' \
    --exclude 'data' \
    --exclude 'backend/.venv' \
    --exclude 'backend/tests' \
    --exclude '__pycache__' \
    --exclude '.pytest_cache' \
    --exclude 'backend/bin' \
    --exclude 'dependency' \
    --exclude 'desktop' \
    --exclude 'docs' \
    --exclude 'design-system' \
    --exclude 'scripts' \
    --exclude '_release' \
    --exclude 'release' \
    --exclude 'frontend/node_modules' \
    --exclude 'backend-mcp/tests' \
    --exclude 'versions' \
    --exclude '*.log' \
    --exclude '.backend_deps_hash' \
    --exclude '.frontend_deps_hash' \
    --exclude '.mcp_deps_hash' \
    --exclude 'pr.md' \
    --exclude 'qrcode.png' \
    --exclude 'update.sh' \
    "$PROJECT_ROOT/" "$STAGE/"

# ------------------------------------------------------------
# 3. 使用说明 + 权限/换行收尾
# ------------------------------------------------------------
cat > "$STAGE/START-README.txt" <<EOF
千帆云递 QianFan Sync v$VERSION · 使用说明
============================================

【快速开始 · macOS】
1. 解压本 zip 到任意位置（建议用户目录，不要放只读目录）
2. 进入解压后的文件夹，右键 start.command → 打开（首次需在系统弹窗里再点一次「打开」）
   若提示无法验证开发者：系统设置 → 隐私与安全性 → 仍要打开
3. 脚本会自动下载所需组件并启动，完成后浏览器自动打开操作界面

【快速开始 · Windows】
1. 解压本 zip 到任意位置
2. 双击 start.bat（若被 SmartScreen 拦截：点「更多信息」→「仍要运行」）
3. 脚本会自动下载所需组件并启动，完成后浏览器自动打开操作界面

【首次启动会联网自动下载（国内镜像，仅一次）】
- Python 3.12 / Node.js / ffmpeg 便携版 → 解压目录的 dependency/ 下
- Python 依赖包（pip，阿里云镜像）
- 浏览器内核 Chromium（登录/发布用，约 250MB）
之后启动不再联网，直接就绪。

【默认浏览器内核】
默认使用 patchright（Chromium），无需任何 license。
如需指纹浏览器 CloakBrowser：启动前设置环境变量
  BROWSER_BACKEND=cloakbrowser
首次使用会自动下载（约 200-350MB）。

【数据与账号】
- 所有数据（数据库/登录 cookie/素材/日志）都在解压目录的 data/ 下
- 卸载 = 删除整个文件夹
- 升级新版本：解压新版到新文件夹后，把旧文件夹的 data/ 整个拷贝进来即可

【AI Agent 服务 (MCP)】
启动后自动监听 http://localhost:5410/sse（SSE 模式），可在支持 MCP 的客户端中接入。
EOF

chmod +x "$STAGE/start-macos.sh" "$STAGE/start.command" "$STAGE/merge-data.sh" 2>/dev/null || true
# cmd 对 LF-only 批处理的 goto 标签有已知 bug，统一归一为 CRLF
perl -pi -e 's/\r?\n/\r\n/g' "$STAGE/start.bat"
# 预置 mcp 依赖 hash（分发包无 .git，hash 恒为 no-git；避免收件人首跑多做一次 npm install + 编译）
echo "no-git" > "$STAGE/.mcp_deps_hash"

# ------------------------------------------------------------
# 4. 打 zip（ditto 保留 unix 执行权限；不用 --sequesterRsrc 以避免
#    Windows 端出现 __MACOSX 目录；文件名全部 ASCII，避免 Windows 解压乱码）
# ------------------------------------------------------------
ZIP_PATH="$RELEASE_DIR/QianFanSync-$VERSION.zip"
rm -f "$ZIP_PATH"
ditto -c -k --keepParent "$STAGE" "$ZIP_PATH"

echo ""
ok "产物: $ZIP_PATH"
echo "     解压目录: $STAGE"
du -sh "$ZIP_PATH" "$STAGE" | sed 's/^/     /'
