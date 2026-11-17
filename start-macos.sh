#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# 一键启动脚本 — macOS（自举式：缺 Python/Node/ffmpeg 自动下载便携版）
# 收件人流程：拿到项目 zip → 解压 → 双击 start.command（或 bash start-macos.sh）
#   → 首次启动自动下载运行时 + 浏览器内核（走国内镜像）→ 自动打开浏览器
# 数据（db/cookies/日志）都在项目目录的 data/ 下，删除文件夹即卸载
# ============================================================

# --- 颜色与符号 ---
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m'
CHECK="${GREEN}✓${NC}"
CROSS="${RED}✗${NC}"
WARN="${YELLOW}!${NC}"
SPINNER=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')

# --- 项目根目录（脚本所在目录）---
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$SCRIPT_DIR"
BACKEND_DIR="$PROJECT_ROOT/backend"
FRONTEND_DIR="$PROJECT_ROOT/frontend"
FRONTEND_DIST="$FRONTEND_DIR/dist"
MCP_DIR="$PROJECT_ROOT/backend-mcp"

# --- 本地依赖目录（优先使用）---
DEP_DIR="$PROJECT_ROOT/dependency"
DEP_BIN_DIR="$DEP_DIR/bin"
for _d in "$DEP_BIN_DIR" "$DEP_DIR/python/bin" "$DEP_DIR/node/bin"; do
    [[ -d "$_d" ]] && export PATH="$_d:$PATH"
done
unset _d

# --- 浏览器后端与内核位置（默认 patchright，免 license；可用环境变量覆盖）---
export BROWSER_BACKEND="${BROWSER_BACKEND:-patchright}"
export PLAYWRIGHT_BROWSERS_PATH="${PLAYWRIGHT_BROWSERS_PATH:-$DEP_DIR/ms-playwright}"
PW_MIRROR="https://cdn.npmmirror.com/binaries/playwright"
NODE_OK=0
MCP_READY=0
MCP_PID=""

# 清理解压产生的隔离属性（否则 Gatekeeper 会拦下载来的 python/ffmpeg）
xattr -dr com.apple.quarantine "$PROJECT_ROOT" 2>/dev/null || true

# 清除系统代理，避免 httpx/cloakbrowser 读取到不支持的 socks:// 代理
unset http_proxy https_proxy all_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY

find_cloakbrowser_binary() {
    local base_dir="$1"
    local candidate

    if [[ ! -d "$base_dir" ]]; then
        return 1
    fi

    for candidate in \
        "$base_dir/chrome" \
        "$base_dir/chrome-bin/chrome" \
        "$base_dir/Chromium.app/Contents/MacOS/Chromium" \
        "$base_dir"/chromium-*/chrome \
        "$base_dir"/chromium-*/chrome-bin/chrome \
        "$base_dir"/chromium-*/Chromium.app/Contents/MacOS/Chromium; do
        if [[ -f "$candidate" ]]; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done

    return 1
}

# CloakBrowser: 如果 dependency/cloakbrowser/ 下有浏览器二进制，优先使用
CLOAKBROWSER_LOCAL="$DEP_DIR/cloakbrowser"
if _chrome_bin=$(find_cloakbrowser_binary "$CLOAKBROWSER_LOCAL"); then
    export CLOAKBROWSER_BINARY_PATH="$_chrome_bin"
fi
unset _chrome_bin

# --- 项目代码管理（git clone / update）---
REPO_URL="https://github.com/DevilJie/social-auto-upload-web-ui.git"
MAIN_BRANCH="master"

if [[ ! -d "$BACKEND_DIR" ]]; then
    # 首次使用：没有项目代码，从 GitHub 克隆
    if ! command -v git &>/dev/null; then
        echo -e "${CROSS} 未找到 git，无法克隆项目代码"
        echo -e "  分发 zip 自带完整代码，请确认解压完整（backend/ 目录是否存在）"
        exit 1
    fi
    echo ""
    echo -e "${CYAN}首次使用，正在从 GitHub 拉取项目代码...${NC}"
    cd "$PROJECT_ROOT"
    git init
    git remote add origin "$REPO_URL" 2>/dev/null || git remote set-url origin "$REPO_URL"
    if ! git fetch origin "$MAIN_BRANCH"; then
        print_fail "无法连接 GitHub，请检查网络连接"
        echo "  如果无法访问 GitHub，请手动下载项目代码到当前目录"
        echo "  仓库地址: $REPO_URL"
        exit 1
    fi
    git checkout -f "$MAIN_BRANCH"
    echo -e "${CHECK} 项目代码拉取完成"
    echo ""
    exec bash "$PROJECT_ROOT/start-macos.sh"
fi

# 已有项目代码：询问用户是否检查更新（仅开发者的 git 目录会走到这里；分发 zip 无 .git 自动跳过）
if command -v git &>/dev/null && [[ -d "$PROJECT_ROOT/.git" ]]; then
    if [[ "${SAU_JUST_UPDATED:-}" == "1" ]]; then
        echo -e "${CHECK} 代码刚已完成更新，跳过更新检查"
    else
        echo ""
        echo -e "${CYAN}是否检查并更新到最新代码？${NC}"
        echo "  输入 Y 拉取最新代码后启动，输入 N 或直接回车跳过更新立即启动"
        read -r -p "请选择 [Y/N]: " UPDATE_CHOICE
        if [[ "$UPDATE_CHOICE" =~ ^[Yy]$ ]]; then
            cd "$PROJECT_ROOT"
            echo -e "${CYAN}正在检查并更新到最新版本...${NC}"
            git remote set-url origin "$REPO_URL" 2>/dev/null
            if git fetch origin "$MAIN_BRANCH" 2>/dev/null; then
                git checkout -f "$MAIN_BRANCH" 2>/dev/null
                git reset --hard "origin/$MAIN_BRANCH"
                echo -e "${CHECK} 已更新到最新版本，重新启动脚本..."
                cd "$PROJECT_ROOT"
                export SAU_JUST_UPDATED=1
                exec bash "$0"
            else
                echo -e "${WARN} 无法连接 GitHub 更新，继续使用本地版本"
            fi
        else
            echo -e "${CHECK} 跳过更新，使用本地版本启动"
        fi
    fi
fi

# --- 日志文件 ---
BACKEND_LOG="$PROJECT_ROOT/backend.log"
FRONTEND_LOG="$PROJECT_ROOT/frontend.log"
MCP_LOG="$PROJECT_ROOT/mcp.log"

# --- 后端/前端/MCP 进程 PID ---
BACKEND_PID=""
FRONTEND_PID=""

# --- MCP transport mode（默认 sse 适合后台 daemon；stdio 需父进程喂 stdin）---
TRANSPORT_MODE="${MCP_TRANSPORT_MODE:-sse}"

# --- 清理函数 ---
cleanup() {
    echo ""
    echo "正在停止服务..."
    if [[ -n "${TAIL_PID:-}" ]] && kill -0 "$TAIL_PID" 2>/dev/null; then
        kill "$TAIL_PID" 2>/dev/null || true
    fi
    if [[ -n "$FRONTEND_PID" ]] && kill -0 "$FRONTEND_PID" 2>/dev/null; then
        kill "$FRONTEND_PID" 2>/dev/null || true
        echo "  前端已停止 (PID: $FRONTEND_PID)"
    fi
    if [[ -n "$MCP_PID" ]] && kill -0 "$MCP_PID" 2>/dev/null; then
        kill "$MCP_PID" 2>/dev/null || true
        echo "  MCP 已停止 (PID: $MCP_PID)"
    fi
    if [[ -n "$BACKEND_PID" ]] && kill -0 "$BACKEND_PID" 2>/dev/null; then
        kill "$BACKEND_PID" 2>/dev/null || true
        echo "  后端已停止 (PID: $BACKEND_PID)"
    fi
    exit 0
}
trap cleanup SIGINT SIGTERM

# --- 辅助函数 ---
print_step() {
    echo ""
    echo -e "[$1/6] $2..."
}

print_ok() {
    echo -e "  ${CHECK} $1"
}

print_fail() {
    echo -e "  ${CROSS} $1"
}

print_warn() {
    echo -e "  ${WARN} $1"
}

# 带旋转动画的等待命令执行
# 用法: run_with_spinner "提示信息" command [args...]
run_with_spinner() {
    local msg="$1"
    shift
    local cmd=("$@")
    local tmp_log
    tmp_log=$(mktemp)

    echo -n -e "  ${CYAN}⏳${NC} ${msg}"

    # 后台执行命令
    "${cmd[@]}" > "$tmp_log" 2>&1 &
    local pid=$!
    local i=0

    while kill -0 "$pid" 2>/dev/null; do
        printf "\r  ${CYAN}%s${NC} %s" "${SPINNER[$i]}" "$msg"
        i=$(( (i + 1) % ${#SPINNER[@]} ))
        sleep 0.2
    done

    wait "$pid" 2>/dev/null
    local exit_code=$?
    rm -f "$tmp_log"

    if [[ $exit_code -eq 0 ]]; then
        printf "\r  ${CHECK} %s\n" "$msg"
    else
        printf "\r  ${CROSS} %s\n" "$msg"
        return 1
    fi
}

kill_port() {
    local port=$1
    local pids
    pids=$(lsof -P -n -ti :"$port" 2>/dev/null || true)
    if [[ -n "$pids" ]]; then
        echo "$pids" | xargs kill -9 2>/dev/null || true
        sleep 1
        pids=$(lsof -P -n -ti :"$port" 2>/dev/null || true)
        if [[ -n "$pids" ]]; then
            print_fail "端口 $port 仍被占用，请手动释放后重试"
            exit 1
        fi
    fi
}

get_dir_hash() {
    local dir=$1
    git -C "$PROJECT_ROOT" log -1 --format=%H -- "$dir" 2>/dev/null || echo "no-git"
}

check_hash_changed() {
    local hash_file=$1
    local current_hash=$2
    if [[ ! -f "$hash_file" ]]; then
        return 0
    fi
    local saved_hash
    saved_hash=$(cat "$hash_file")
    [[ "$current_hash" != "$saved_hash" ]]
}

# ============================================================
# Step 1: 自举运行时（缺什么下载什么，全部落到 dependency/，已有则跳过）
# ============================================================
print_step "1" "检查并自举运行时"

mkdir -p "$DEP_DIR" "$DEP_BIN_DIR"

# 判断命令来源：内置 (dependency/) 还是系统
cmd_source() {
    local cmd_path
    cmd_path=$(command -v "$1" 2>/dev/null || true)
    if [[ -n "$cmd_path" && "$cmd_path" == "$DEP_DIR"* ]]; then
        echo "内置"
    else
        echo "系统"
    fi
}

# 下载到 $2，主 URL 失败自动切换回 URL（$3）
download_file() {
    local output="$1" url="$2" fallback="${3:-}"
    local tmp="$output.part"
    if curl -fsSL --retry 2 -A "Mozilla/5.0" -o "$tmp" "$url"; then
        mv "$tmp" "$output"
        return 0
    fi
    rm -f "$tmp"
    if [[ -n "$fallback" ]]; then
        if curl -fsSL --retry 2 -A "Mozilla/5.0" -o "$tmp" "$fallback"; then
            mv "$tmp" "$output"
            return 0
        fi
    fi
    rm -f "$tmp"
    return 1
}

ensure_python() {
    if command -v python3 &>/dev/null; then
        print_ok "Python $(python3 --version 2>&1 | awk '{print $2}') ($(cmd_source python3))"
        return 0
    fi
    print_warn "未找到系统 python3，下载便携版（约 30MB，仅首次）..."
    local pbs_arch url1 url2 tmp_tar
    case "$(uname -m)" in
        arm64)  pbs_arch="aarch64" ;;
        x86_64) pbs_arch="x86_64" ;;
        *) print_fail "不支持的 CPU 架构: $(uname -m)"; exit 1 ;;
    esac
    url1="https://github.com/astral-sh/python-build-standalone/releases/download/20260414/cpython-3.12.13+20260414-${pbs_arch}-apple-darwin-install_only.tar.gz"
    url2="https://gh-proxy.com/https://github.com/astral-sh/python-build-standalone/releases/download/20260414/cpython-3.12.13+20260414-${pbs_arch}-apple-darwin-install_only.tar.gz"
    tmp_tar="$(mktemp -d)/python.tar.gz"
    if run_with_spinner "下载便携 Python 3.12" bash -c "curl -fsSL --retry 2 -A 'Mozilla/5.0' -o '$tmp_tar' '$url1' || curl -fsSL --retry 2 -A 'Mozilla/5.0' -o '$tmp_tar' '$url2'"; then
        tar -xzf "$tmp_tar" -C "$DEP_DIR"   # install_only 包顶层目录就是 python/
        export PATH="$DEP_DIR/python/bin:$PATH"
        print_ok "Python 内置 $(python3 --version 2>&1 | awk '{print $2}')"
    else
        print_fail "Python 下载失败（Python 为必需项）。请检查网络后重试"
        exit 1
    fi
}

ensure_node() {
    if command -v node &>/dev/null; then
        print_ok "Node $(node --version 2>&1) ($(cmd_source node))"
        NODE_OK=1
        return 0
    fi
    print_warn "未找到 node，下载便携版（MCP/AI 服务需要，约 25MB，仅首次）..."
    local narch url1 url2 tmp_tar
    case "$(uname -m)" in
        arm64)  narch="arm64" ;;
        x86_64) narch="x64" ;;
        *) NODE_OK=0; print_warn "不支持的架构，跳过 Node 下载"; return 1 ;;
    esac
    url1="https://cdn.npmmirror.com/binaries/node/v22.16.0/node-v22.16.0-darwin-${narch}.tar.gz"
    url2="https://nodejs.org/dist/v22.16.0/node-v22.16.0-darwin-${narch}.tar.gz"
    mkdir -p "$DEP_DIR/node"
    tmp_tar="$(mktemp -d)/node.tar.gz"
    if run_with_spinner "下载便携 Node.js v22" bash -c "curl -fsSL --retry 2 -A 'Mozilla/5.0' -o '$tmp_tar' '$url1' || curl -fsSL --retry 2 -A 'Mozilla/5.0' -o '$tmp_tar' '$url2'"; then
        tar -xzf "$tmp_tar" -C "$DEP_DIR/node" --strip-components=1
        ln -sf "$DEP_DIR/node/bin/node" "$DEP_BIN_DIR/node"
        ln -sf "$DEP_DIR/node/bin/npm"  "$DEP_BIN_DIR/npm"
        ln -sf "$DEP_DIR/node/bin/npx"  "$DEP_BIN_DIR/npx"
        export PATH="$DEP_BIN_DIR:$DEP_DIR/node/bin:$PATH"
        NODE_OK=1
        print_ok "Node 内置 $(node --version 2>&1)"
    else
        NODE_OK=0
        print_warn "Node 下载失败 — MCP/AI 服务将不可用（其余功能正常）"
    fi
}

ensure_ffmpeg() {
    if command -v ffmpeg &>/dev/null && command -v ffprobe &>/dev/null; then
        print_ok "ffmpeg $(ffmpeg -version 2>&1 | head -1 | awk '{print $3}') ($(cmd_source ffmpeg))"
        return 0
    fi
    print_warn "未找到 ffmpeg，下载便携版（视频时长/封面抽帧需要）..."
    local tmpd f_url1 f_url2 p_url1 p_url2
    tmpd="$(mktemp -d)"
    if [[ "$(uname -m)" == "arm64" ]]; then
        f_url1="https://www.osxexperts.net/ffmpeg902arm.zip";  f_url2="https://evermeet.cx/ffmpeg/ffmpeg-9.0.2.zip"
        p_url1="https://www.osxexperts.net/ffprobe902arm.zip"; p_url2="https://evermeet.cx/ffmpeg/ffprobe-9.0.2.zip"
    else
        f_url1="https://evermeet.cx/ffmpeg/ffmpeg-9.0.2.zip";  f_url2=""
        p_url1="https://evermeet.cx/ffmpeg/ffprobe-9.0.2.zip"; p_url2=""
    fi
    if ! run_with_spinner "下载 ffmpeg" bash -c "curl -fsSL --retry 2 -A 'Mozilla/5.0' -o '$tmpd/ffmpeg.zip' '$f_url1' || { [[ -n '$f_url2' ]] && curl -fsSL --retry 2 -A 'Mozilla/5.0' -o '$tmpd/ffmpeg.zip' '$f_url2'; }"; then
        print_warn "ffmpeg 下载失败 — 视频时长/封面抽帧不可用，其余功能正常"
        return 1
    fi
    if ! run_with_spinner "下载 ffprobe" bash -c "curl -fsSL --retry 2 -A 'Mozilla/5.0' -o '$tmpd/ffprobe.zip' '$p_url1' || { [[ -n '$p_url2' ]] && curl -fsSL --retry 2 -A 'Mozilla/5.0' -o '$tmpd/ffprobe.zip' '$p_url2'; }"; then
        print_warn "ffprobe 下载失败 — 视频时长/封面抽帧不可用，其余功能正常"
        return 1
    fi
    unzip -o -q "$tmpd/ffmpeg.zip" -d "$tmpd"
    unzip -o -q "$tmpd/ffprobe.zip" -d "$tmpd"
    if [[ -f "$tmpd/ffmpeg" && -f "$tmpd/ffprobe" ]]; then
        mv "$tmpd/ffmpeg" "$DEP_BIN_DIR/ffmpeg"
        mv "$tmpd/ffprobe" "$DEP_BIN_DIR/ffprobe"
        chmod +x "$DEP_BIN_DIR/ffmpeg" "$DEP_BIN_DIR/ffprobe"
        export PATH="$DEP_BIN_DIR:$PATH"
        print_ok "ffmpeg 内置 ($("$DEP_BIN_DIR/ffmpeg" -version 2>&1 | head -1 | awk '{print $3}'))"
    else
        print_warn "ffmpeg 解压异常 — 视频时长/封面抽帧不可用，其余功能正常"
        return 1
    fi
}

ensure_python
ensure_node || true
ensure_ffmpeg || true

# ============================================================
# Step 2: 处理端口冲突
# ============================================================
print_step "2" "处理端口冲突"

kill_port 5409
print_ok "端口 5409 空闲"

kill_port 5410
print_ok "端口 5410 空闲"

# ============================================================
# Step 3: 准备后端环境 (venv) + 浏览器内核
# ============================================================
print_step "3" "准备后端环境"

VENV_DIR="$BACKEND_DIR/.venv"
VENV_PYTHON="$VENV_DIR/bin/python3"
VENV_PIP="$VENV_DIR/bin/pip"
PIP_MIRROR="https://mirrors.aliyun.com/pypi/simple/"
HASH_FILE="$PROJECT_ROOT/.backend_deps_hash"
CURRENT_HASH=$(get_dir_hash "backend")

if [[ ! -d "$VENV_DIR" ]] || [[ ! -f "$VENV_PIP" ]]; then
    echo -n -e "  ${CYAN}⏳${NC} 创建虚拟环境..."
    rm -rf "$VENV_DIR"
    if ! python3 -m venv "$VENV_DIR" 2>/dev/null; then
        printf "\r  ${WARN} 虚拟环境创建失败，请检查 python3 是否完整\n"
        print_fail "venv 创建失败，无法继续"
        exit 1
    fi
    printf "\r  ${CHECK} 虚拟环境创建完成\n"
    "$VENV_PIP" cache purge >/dev/null 2>&1 || true
    echo -e "  ${CYAN}安装 Python 依赖（首次安装，请稍候）...${NC}"
    "$VENV_PIP" install -r "$BACKEND_DIR/requirements.txt" --no-cache-dir -i "$PIP_MIRROR"
    echo "$CURRENT_HASH" > "$HASH_FILE"
    print_ok "后端环境就绪"
elif check_hash_changed "$HASH_FILE" "$CURRENT_HASH"; then
    "$VENV_PIP" cache purge >/dev/null 2>&1 || true
    echo -e "  ${CYAN}检测到变更，更新 Python 依赖...${NC}"
    "$VENV_PIP" install -r "$BACKEND_DIR/requirements.txt" --no-cache-dir -i "$PIP_MIRROR"
    echo "$CURRENT_HASH" > "$HASH_FILE"
    print_ok "依赖更新完成"
else
    print_ok "依赖无变更，跳过"
fi

# --- 浏览器内核 ---
if [[ "$BROWSER_BACKEND" == "patchright" ]]; then
    if compgen -G "$PLAYWRIGHT_BROWSERS_PATH/chromium-*" > /dev/null; then
        print_ok "patchright Chromium 已就绪"
    elif run_with_spinner "下载 patchright Chromium（约 250MB，仅首次）" env PLAYWRIGHT_DOWNLOAD_HOST="$PW_MIRROR" "$VENV_PYTHON" -m patchright install chromium chromium-headless-shell; then
        print_ok "patchright Chromium 就绪"
    elif run_with_spinner "下载 patchright Chromium（官方源重试）" "$VENV_PYTHON" -m patchright install chromium chromium-headless-shell; then
        print_ok "patchright Chromium 就绪"
    else
        print_fail "Chromium 下载失败（登录/发布必需）。可开启代理后重新运行本脚本"
        exit 1
    fi
elif [[ "$BROWSER_BACKEND" == "cloakbrowser" ]]; then
    # 检查 CloakBrowser 二进制文件（仅 cloakbrowser 后端模式）
    CLOAKBROWSER_DIR="$HOME/.cloakbrowser"
    if [[ -n "${CLOAKBROWSER_BINARY_PATH:-}" ]]; then
        print_ok "CloakBrowser (本地依赖)"
    elif ! _chrome_bin=$(find_cloakbrowser_binary "$CLOAKBROWSER_DIR"); then
        echo -e "  ${CYAN}📥 首次使用，下载 CloakBrowser 浏览器${NC}"

        # 从 Python 获取下载信息
        DOWNLOAD_INFO=$("$VENV_PYTHON" -c "
import cloakbrowser.download as d
print(d.get_fallback_download_url())
print(d.get_binary_dir())
print(d.get_binary_path())
" 2>/dev/null)

        DOWNLOAD_URL=$(echo "$DOWNLOAD_INFO" | sed -n '1p')
        BINARY_DIR=$(echo "$DOWNLOAD_INFO" | sed -n '2p')
        BINARY_PATH=$(echo "$DOWNLOAD_INFO" | sed -n '3p')

        if [[ -z "$DOWNLOAD_URL" ]]; then
            print_fail "无法获取下载地址"
            exit 1
        fi

        # 使用 curl 下载（带进度条）
        # macOS 的 mktemp 不接受模板中有非 X 字符（如 .tar.gz 后缀），
        # 先建临时目录，文件放在目录里（路径兼容 Linux 和 macOS）。
        TMP_DIR=$(mktemp -d /tmp/cloakbrowser-XXXXXX)
        TMP_FILE="$TMP_DIR/cloakbrowser.archive"
        echo -e "  ${CYAN}⬇  下载地址: ${DOWNLOAD_URL}${NC}"
        echo ""

        if ! curl -L -# -o "$TMP_FILE" "$DOWNLOAD_URL"; then
            # 主下载失败，尝试 GitHub 备用地址
            GITHUB_URL=$(echo "$DOWNLOAD_URL" | sed 's|cloakbrowser.dev|github.com/CloakHQ/cloakbrowser/releases/download|')
            echo ""
            echo -e "  ${WARN} 主下载失败，尝试 GitHub 备用地址..."
            if ! curl -L -# -o "$TMP_FILE" "$GITHUB_URL"; then
                rm -rf "$TMP_DIR"
                print_fail "CloakBrowser 下载失败，请检查网络连接"
                exit 1
            fi
        fi

        # 解压到目标目录
        echo ""
        echo -n -e "  ${CYAN}📦 解压中...${NC}"
        mkdir -p "$BINARY_DIR"
        if ! tar -xzf "$TMP_FILE" -C "$BINARY_DIR"; then
            rm -rf "$TMP_DIR"
            printf "\r  ${CROSS} CloakBrowser 解压失败\n"
            exit 1
        fi
        rm -rf "$TMP_DIR"

        # 确保实际存在的二进制文件可执行
        if _chrome_bin=$(find_cloakbrowser_binary "$BINARY_DIR"); then
            chmod +x "$_chrome_bin" 2>/dev/null || true
            export CLOAKBROWSER_BINARY_PATH="$_chrome_bin"
            printf "\r  ${CHECK} CloakBrowser 下载完成\n"
        else
            printf "\r  ${CROSS} CloakBrowser 解压失败\n"
            print_warn "未找到 CloakBrowser 二进制文件: chrome、chrome-bin/chrome 或 Chromium.app/Contents/MacOS/Chromium"
            exit 1
        fi
        unset _chrome_bin
    else
        export CLOAKBROWSER_BINARY_PATH="$_chrome_bin"
        unset _chrome_bin
        print_ok "CloakBrowser 已安装"
    fi
fi

# ============================================================
# Step 4: 前端 (Flask 托管 dist) + MCP 环境
# ============================================================
print_step "4" "准备前端 + MCP 环境"

# --- 前端：生产模式由后端同端口托管 frontend/dist；分发包自带 dist，缺失才现场构建 ---
if [[ -f "$FRONTEND_DIST/index.html" ]]; then
    print_ok "前端 dist 就绪（由后端同端口托管）"
else
    print_warn "未找到 frontend/dist（分发包应自带）— 现场构建（需联网，约 2 分钟）"
    run_with_spinner "安装前端依赖" bash -c "cd '$FRONTEND_DIR' && npm install --prefer-offline --registry=https://registry.npmmirror.com 2>&1 | tail -1"
    run_with_spinner "构建前端 dist" bash -c "cd '$FRONTEND_DIR' && npm run build 2>&1 | tail -3"
    if [[ ! -f "$FRONTEND_DIST/index.html" ]]; then
        print_fail "前端构建失败，界面不可用，请查看上方输出"
        exit 1
    fi
    print_ok "前端 dist 构建完成"
fi

# --- MCP: node_modules 缺失才安装；dist 缺失或代码变更才编译（分发包自带 dist，通常跳过）---
if [[ "$NODE_OK" == "1" ]]; then
    HASH_FILE="$PROJECT_ROOT/.mcp_deps_hash"
    MCP_CURRENT_HASH=$(get_dir_hash "backend-mcp")

    if [[ ! -d "$MCP_DIR/node_modules" ]]; then
        run_with_spinner "安装 MCP 依赖（首次安装，请稍候）" bash -c "cd '$MCP_DIR' && npm install --prefer-offline --registry=https://registry.npmmirror.com 2>&1 | tail -1"
        echo "$MCP_CURRENT_HASH" > "$HASH_FILE"
    elif check_hash_changed "$HASH_FILE" "$MCP_CURRENT_HASH"; then
        run_with_spinner "检测到变更，更新 MCP 依赖" bash -c "cd '$MCP_DIR' && npm install --prefer-offline --registry=https://registry.npmmirror.com 2>&1 | tail -1"
        echo "$MCP_CURRENT_HASH" > "$HASH_FILE"
    else
        print_ok "MCP 依赖无变更，跳过"
    fi

    if [[ ! -f "$MCP_DIR/dist/index.js" ]] || check_hash_changed "$HASH_FILE" "$MCP_CURRENT_HASH"; then
        run_with_spinner "编译 MCP (tsc)" bash -c "cd '$MCP_DIR' && npm run build 2>&1 | tail -5"
    fi

    if [[ -f "$MCP_DIR/dist/index.js" ]]; then
        MCP_READY=1
        print_ok "MCP 就绪"
    else
        print_warn "MCP 构建产物缺失 — AI Agent 服务不可用（其余功能正常）"
    fi
else
    print_warn "无 Node.js — 跳过 MCP/AI 服务"
fi

# ============================================================
# Step 5: 启动服务
# ============================================================
print_step "5" "启动服务"

# 确保端口完全释放
for i in $(seq 1 5); do
    if ! lsof -P -n -ti :5409 >/dev/null 2>&1; then
        break
    fi
    sleep 1
done

cd "$BACKEND_DIR"
export SAU_PORT=5409
nohup "$VENV_PYTHON" app.py > "$BACKEND_LOG" 2>&1 &
BACKEND_PID=$!
print_ok "后端已启动 (PID: $BACKEND_PID)"

if [[ "$MCP_READY" == "1" ]]; then
    cd "$MCP_DIR"
    export TRANSPORT_MODE
    nohup "$(command -v node)" dist/index.js > "$MCP_LOG" 2>&1 &
    MCP_PID=$!
    print_ok "MCP 已启动 (PID: $MCP_PID, transport: $TRANSPORT_MODE)"
fi

# 开发者逃生口：SAU_FRONTEND_DEV=1 时保留 vite dev server（5173）
if [[ "${SAU_FRONTEND_DEV:-0}" == "1" ]]; then
    if [[ ! -d "$FRONTEND_DIR/node_modules" ]]; then
        run_with_spinner "安装前端依赖" bash -c "cd '$FRONTEND_DIR' && npm install --prefer-offline --registry=https://registry.npmmirror.com 2>&1 | tail -1"
    fi
    cd "$FRONTEND_DIR"
    nohup npm run dev > "$FRONTEND_LOG" 2>&1 &
    FRONTEND_PID=$!
    print_ok "前端 dev server 已启动 (PID: $FRONTEND_PID)"
fi

cd "$PROJECT_ROOT"

# ============================================================
# Step 6: 等待服务就绪并显示入口
# ============================================================
print_step "6" "等待服务就绪"

# 从日志中获取后端实际端口（后端可能因端口竞争回退到其他端口）
BACKEND_PORT=5409
echo -n "  等待后端就绪"
for i in $(seq 1 30); do
    # 检测日志中的实际端口（使用 sed 替代 grep -P，兼容 macOS）
    if [[ -f "$BACKEND_LOG" ]]; then
        detected_port=$(sed -n 's/.*Serving on http:\/\/0\.0\.0\.0:\([0-9]*\).*/\1/p' "$BACKEND_LOG" 2>/dev/null | tail -1)
        if [[ -n "$detected_port" ]]; then
            BACKEND_PORT="$detected_port"
        fi
    fi
    http_code=$(curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:${BACKEND_PORT}/api/health" 2>/dev/null || true)
    if [[ "$http_code" == "200" ]]; then
        echo ""
        print_ok "后端就绪 (端口: ${BACKEND_PORT})"
        break
    fi
    if [[ $i -eq 30 ]]; then
        echo ""
        print_fail "后端启动超时，请查看日志: $BACKEND_LOG"
        tail -20 "$BACKEND_LOG" 2>/dev/null || true
        exit 1
    fi
    echo -n "."
    sleep 1
done

# 等待 MCP（stdio 模式只要进程存活就 OK；sse/both 等端口 5410 监听）
if [[ "$MCP_READY" == "1" && -n "$MCP_PID" ]]; then
    echo -n "  等待 MCP 就绪"
    for i in $(seq 1 15); do
        if ! kill -0 "$MCP_PID" 2>/dev/null; then
            echo ""
            print_fail "MCP 启动失败，请查看日志: $MCP_LOG"
            tail -20 "$MCP_LOG" 2>/dev/null || true
            exit 1
        fi
        if [[ "$TRANSPORT_MODE" == "sse" || "$TRANSPORT_MODE" == "both" ]]; then
            if lsof -P -n -ti :5410 >/dev/null 2>&1; then
                echo ""
                print_ok "MCP 就绪 (SSE 端口 5410)"
                break
            fi
        else
            # stdio 模式进程存活即就绪
            echo ""
            print_ok "MCP 就绪 (stdio)"
            break
        fi
        if [[ $i -eq 15 ]]; then
            echo ""
            print_warn "MCP 启动检查超时（15 秒），但进程仍在运行"
            break
        fi
        echo -n "."
        sleep 1
    done
fi

echo ""
echo "============================================"
if [[ "${SAU_FRONTEND_DEV:-0}" == "1" ]]; then
    echo -e "  ${GREEN}前端界面(dev): http://localhost:5173${NC}"
    echo -e "  ${GREEN}后端 API: http://localhost:${BACKEND_PORT}${NC}"
else
    echo -e "  ${GREEN}界面入口: http://localhost:${BACKEND_PORT}${NC}"
    open "http://localhost:${BACKEND_PORT}" 2>/dev/null || true
    print_ok "已在浏览器打开界面"
fi
if [[ "$TRANSPORT_MODE" == "sse" || "$TRANSPORT_MODE" == "both" ]]; then
    echo -e "  ${GREEN}MCP  SSE:  http://localhost:5410/sse${NC}"
else
    echo -e "  ${GREEN}MCP  stdio: 启动中 (transport=$TRANSPORT_MODE)${NC}"
fi
echo "============================================"
echo ""
echo "按 Ctrl+C 停止所有服务"
echo ""
echo "--- 后端日志 ---"

tail -f "$BACKEND_LOG" &
TAIL_PID=$!
trap "kill $TAIL_PID 2>/dev/null; cleanup" SIGINT SIGTERM

wait || true
