@echo off
chcp 65001 >nul 2>&1
setlocal EnableDelayedExpansion

:: ============================================================
:: 一键启动脚本 — Windows（自举式：缺 Python/Node/ffmpeg 自动下载便携版）
:: 收件人流程：解压 zip → 双击 start.bat → 首次启动自动下载运行时
::   （走国内镜像）→ 自动打开浏览器。数据都在 data/ 下，删除文件夹即卸载
:: ============================================================

:: --- 项目根目录（脚本所在目录）---
set "PROJECT_ROOT=%~dp0"
set "PROJECT_ROOT=%PROJECT_ROOT:~0,-1%"
set "BACKEND_DIR=%PROJECT_ROOT%\backend"
set "FRONTEND_DIR=%PROJECT_ROOT%\frontend"
set "FRONTEND_DIST=%FRONTEND_DIR%\dist"
set "MCP_DIR=%PROJECT_ROOT%\backend-mcp"
set "DEP_PREFIX=%PROJECT_ROOT%\dependency"

:: --- 本地依赖目录（优先使用）---
if exist "%DEP_PREFIX%\bin" (
    set "PATH=%DEP_PREFIX%\bin;%PATH%"
)
if exist "%DEP_PREFIX%\python" (
    set "PATH=%DEP_PREFIX%\python;%DEP_PREFIX%\python\Scripts;%PATH%"
)
if exist "%DEP_PREFIX%\node" (
    set "PATH=%DEP_PREFIX%\node;%PATH%"
)
if exist "%DEP_PREFIX%\cloakbrowser\chrome.exe" (
    set "CLOAKBROWSER_BINARY_PATH=%DEP_PREFIX%\cloakbrowser\chrome.exe"
)

:: --- 浏览器后端与内核位置（默认 patchright，免 license；可用环境变量覆盖）---
if not defined BROWSER_BACKEND set "BROWSER_BACKEND=patchright"
if not defined PLAYWRIGHT_BROWSERS_PATH set "PLAYWRIGHT_BROWSERS_PATH=%DEP_PREFIX%\ms-playwright"
set "PW_MIRROR=https://cdn.npmmirror.com/binaries/playwright"
set "NODE_OK=0"
set "MCP_READY=0"

:: 清除系统代理，避免 httpx/cloakbrowser 读取到不支持的 socks:// 代理
set "http_proxy="
set "https_proxy="
set "all_proxy="
set "HTTP_PROXY="
set "HTTPS_PROXY="
set "ALL_PROXY="

:: --- 项目代码管理（git clone / 强制更新到最新）---
set "REPO_URL=https://github.com/DevilJie/social-auto-upload-web-ui.git"
set "MAIN_BRANCH=master"

if not exist "%BACKEND_DIR%" (
    rem 首次使用：没有项目代码，从 GitHub 克隆
    where git >nul 2>&1
    if !errorlevel! neq 0 (
        echo   X 未找到 git，无法克隆项目代码
        echo     分发 zip 自带完整代码，请确认解压完整（backend 目录是否存在）
        pause
        exit /b 1
    )
    echo.
    echo   首次使用，正在从 GitHub 拉取项目代码...
    cd /d "%PROJECT_ROOT%"
    git init
    git remote add origin "%REPO_URL%" 2>nul || git remote set-url origin "%REPO_URL%"
    git fetch
    git fetch origin "%MAIN_BRANCH%"
    if !errorlevel! neq 0 (
        echo   X 无法连接 GitHub，请检查网络连接
        echo     如果无法访问 GitHub，请手动下载项目代码到当前目录
        echo     仓库地址: %REPO_URL%
        pause
        exit /b 1
    )
    git checkout -f "%MAIN_BRANCH%"
    git reset --hard "origin/%MAIN_BRANCH%"
    echo   √ 项目代码拉取完成
    echo.
    call "%PROJECT_ROOT%\start.bat"
    exit /b
)

:: 已有项目代码：询问用户是否检查更新（仅开发者的 git 目录会走到这里；分发 zip 无 .git 自动跳过）
if exist "%PROJECT_ROOT%\.git" (
    where git >nul 2>&1
    if !errorlevel! equ 0 (
        if defined SAU_JUST_UPDATED (
            echo   √ 代码刚已完成更新，跳过更新检查
        ) else (
            set "UPDATE_CHOICE="
            echo.
            echo   是否检查并更新到最新代码？
            echo     输入 Y 拉取最新代码后启动，输入 N 或直接回车跳过更新立即启动
            set /p "UPDATE_CHOICE=  请选择 [Y/N]: "
            if /i "!UPDATE_CHOICE!"=="Y" (
                cd /d "%PROJECT_ROOT%"
                echo   正在检查并更新到最新版本...
                git remote set-url origin "%REPO_URL%" 2>nul
                git fetch origin "%MAIN_BRANCH%" >nul 2>&1
                if !errorlevel! equ 0 (
                    git checkout -f "%MAIN_BRANCH%" >nul 2>&1
                    git reset --hard "origin/%MAIN_BRANCH%" >nul 2>&1
                    echo   √ 已更新到最新版本，重新启动脚本...
                    set "SAU_JUST_UPDATED=1"
                    cd /d "%PROJECT_ROOT%"
                    cmd /c ""%~f0""
                    exit /b
                ) else (
                    echo   ! 无法连接 GitHub 更新，继续使用本地版本
                )
            ) else (
                echo   跳过更新，使用本地版本启动
            )
        )
    )
)


:: --- 日志文件 ---
set "BACKEND_LOG=%PROJECT_ROOT%\backend.log"
set "FRONTEND_LOG=%PROJECT_ROOT%\frontend.log"
set "MCP_LOG=%PROJECT_ROOT%\mcp.log"

:: --- MCP transport mode（默认 sse 适合后台 daemon；stdio 需父进程喂 stdin）---
if defined MCP_TRANSPORT_MODE (
    set "TRANSPORT_MODE=%MCP_TRANSPORT_MODE%"
) else (
    set "TRANSPORT_MODE=sse"
)

:: ============================================================
:: Step 1: 自举运行时（缺什么下载什么，全部落到 dependency/，已有则跳过）
:: ============================================================
echo.
echo [1/6] 检查并自举运行时...

if not exist "%DEP_PREFIX%" mkdir "%DEP_PREFIX%"
if not exist "%DEP_PREFIX%\bin" mkdir "%DEP_PREFIX%\bin"

:: --- 判断命令来源：内置还是系统 ---
:: Python（注意：WindowsApps 的商店别名 stub 执行会失败，自然被当作未安装）
python --version >nul 2>&1
if !errorlevel! neq 0 (
    echo     未找到系统 Python，下载便携版（约 30MB，仅首次）...
    set "PY_TMP=%TEMP%\qfs-python.tar.gz"
    curl -fL --retry 2 -o "!PY_TMP!" "https://github.com/astral-sh/python-build-standalone/releases/download/20260414/cpython-3.12.13+20260414-x86_64-pc-windows-msvc-install_only.tar.gz"
    if !errorlevel! neq 0 (
        curl -fL --retry 2 -o "!PY_TMP!" "https://gh-proxy.com/https://github.com/astral-sh/python-build-standalone/releases/download/20260414/cpython-3.12.13+20260414-x86_64-pc-windows-msvc-install_only.tar.gz"
        if !errorlevel! neq 0 (
            del /f "!PY_TMP!" >nul 2>&1
            echo   X Python 下载失败（必需项）。请检查网络后重试
            pause
            exit /b 1
        )
    )
    tar -xf "!PY_TMP!" -C "%DEP_PREFIX%"
    del /f "!PY_TMP!" >nul 2>&1
    set "PATH=%DEP_PREFIX%\python;%DEP_PREFIX%\python\Scripts;%PATH%"
    python --version >nul 2>&1
    if !errorlevel! neq 0 (
        echo   X 便携 Python 解压异常
        pause
        exit /b 1
    )
    set "PY_SRC=内置"
    goto python_done
)
set "PY_SRC=系统"
set "PY_PATH="
for /f "tokens=*" %%p in ('where python 2^>nul') do (
    if not defined PY_PATH (
        set "PY_PATH=%%p"
        set "_CHK=%%p"
        if not "!_CHK:%DEP_PREFIX%=!"=="!_CHK!" set "PY_SRC=内置"
    )
)
:python_done
for /f "tokens=2" %%i in ('python --version 2^>^&1') do set "PYTHON_VER=%%i"
echo   √ Python !PYTHON_VER! (!PY_SRC!)

:: --- Node.js ---
node --version >nul 2>&1
if !errorlevel! equ 0 (
    set "NODE_OK=1"
    goto node_done
)
echo     未找到 node，下载便携版（MCP/AI 服务需要，约 25MB，仅首次）...
set "NODE_TMP=%TEMP%\qfs-node.zip"
curl -fL --retry 2 -o "!NODE_TMP!" "https://cdn.npmmirror.com/binaries/node/v22.16.0/node-v22.16.0-win-x64.zip"
if !errorlevel! neq 0 (
    curl -fL --retry 2 -o "!NODE_TMP!" "https://nodejs.org/dist/v22.16.0/node-v22.16.0-win-x64.zip"
    if !errorlevel! neq 0 (
        del /f "!NODE_TMP!" >nul 2>&1
        echo   ! Node 下载失败 — MCP/AI 服务将不可用（其余功能正常）
        goto node_done
    )
)
if not exist "%DEP_PREFIX%\node" mkdir "%DEP_PREFIX%\node"
tar -xf "!NODE_TMP!" -C "%DEP_PREFIX%\node" --strip-components=1
del /f "!NODE_TMP!" >nul 2>&1
set "PATH=%DEP_PREFIX%\node;%PATH%"
node --version >nul 2>&1
if !errorlevel! equ 0 (
    set "NODE_OK=1"
    echo   √ Node 内置
) else (
    echo   ! Node 解压异常 — MCP/AI 服务将不可用（其余功能正常）
)
goto node_check_done
:node_done
set "NODE_OK=1"
:node_check_done

:: --- ffmpeg ---
set "FF_OK=0"
where ffmpeg >nul 2>&1
if !errorlevel! equ 0 (
    where ffprobe >nul 2>&1
    if !errorlevel! equ 0 set "FF_OK=1"
)
if "!FF_OK!"=="1" goto ffmpeg_done
echo     未找到 ffmpeg，下载便携版（视频时长/封面抽帧需要，仅首次）...
set "FF_TMP=%TEMP%\qfs-ffmpeg.zip"
if not exist "%TEMP%\ff_ext" mkdir "%TEMP%\ff_ext"
curl -fL --retry 2 -o "!FF_TMP!" "https://www.gyan.dev/ffmpeg/builds/ffmpeg-release-essentials.zip"
if !errorlevel! neq 0 (
    curl -fL --retry 2 -o "!FF_TMP!" "https://gh-proxy.com/https://github.com/BtbN/FFmpeg-Builds/releases/download/latest/ffmpeg-master-latest-win64-gpl.zip"
    if !errorlevel! neq 0 (
        del /f "!FF_TMP!" >nul 2>&1
        echo   ! ffmpeg 下载失败 — 视频时长/封面抽帧不可用，其余功能正常
        goto ffmpeg_done
    )
)
tar -xf "!FF_TMP!" -C "%TEMP%\ff_ext"
del /f "!FF_TMP!" >nul 2>&1
for /r "%TEMP%\ff_ext" %%f in (ffmpeg.exe) do copy /y "%%f" "%DEP_PREFIX%\bin\" >nul 2>&1
for /r "%TEMP%\ff_ext" %%f in (ffprobe.exe) do copy /y "%%f" "%DEP_PREFIX%\bin\" >nul 2>&1
if exist "%DEP_PREFIX%\bin\ffmpeg.exe" if exist "%DEP_PREFIX%\bin\ffprobe.exe" (
    set "PATH=%DEP_PREFIX%\bin;%PATH%"
    echo   √ ffmpeg 内置
) else (
    echo   ! ffmpeg 解压异常 — 视频时长/封面抽帧不可用，其余功能正常
)
:ffmpeg_done
where ffmpeg >nul 2>&1
if !errorlevel! equ 0 echo   √ ffmpeg 已就绪

:: --- curl / tar（Windows 10 1803+ 自带，是下载解压的前提）---
where curl >nul 2>&1
if !errorlevel! neq 0 (
    echo   X 未找到 curl（Windows 10 1803 以下版本不支持自举）
    pause
    exit /b 1
)
where tar >nul 2>&1
if !errorlevel! neq 0 (
    echo   X 未找到 tar（Windows 10 1803 以下版本不支持自举）
    pause
    exit /b 1
)

:: ============================================================
:: Step 2: 处理端口冲突
:: ============================================================
echo.
echo [2/6] 处理端口冲突...

for /f "tokens=5" %%a in ('netstat -aon ^| findstr :5409 ^| findstr LISTENING 2^>nul') do (
    taskkill /F /PID %%a >nul 2>&1
)
echo   √ 端口 5409 空闲

for /f "tokens=5" %%a in ('netstat -aon ^| findstr :5410 ^| findstr LISTENING 2^>nul') do (
    taskkill /F /PID %%a >nul 2>&1
)
echo   √ 端口 5410 空闲

:: ============================================================
:: Step 3: 准备后端环境 + 浏览器内核
:: ============================================================
echo.
echo [3/6] 准备后端环境...

set "VENV_DIR=%BACKEND_DIR%\.venv"
set "VENV_PYTHON=%VENV_DIR%\Scripts\python.exe"
set "VENV_PIP=%VENV_DIR%\Scripts\pip.exe"
set "PIP_MIRROR=https://mirrors.aliyun.com/pypi/simple/"
set "HASH_FILE=%PROJECT_ROOT%\.backend_deps_hash"

:: 获取 backend 目录最近 git commit hash
set "CURRENT_HASH="
for /f "tokens=*" %%i in ('git -C "%PROJECT_ROOT%" log -1 --format^=%%H -- backend 2^>nul') do set "CURRENT_HASH=%%i"
if "!CURRENT_HASH!"=="" set "CURRENT_HASH=no-git"

:: 检查 venv 是否完整（目录 + pip + flask 都存在）
set "VENV_OK=0"
if exist "%VENV_DIR%" if exist "%VENV_PIP%" (
    rem 检查 flask 是否已安装
    "%VENV_PYTHON%" -c "import flask" >nul 2>&1
    if !errorlevel! equ 0 set "VENV_OK=1"
)

if "!VENV_OK!"=="0" (
    if exist "%VENV_DIR%" rmdir /s /q "%VENV_DIR%" >nul 2>&1
    echo     创建虚拟环境...

    rem 检查 venv 模块是否可用
    python -c "import venv" >nul 2>&1
    if !errorlevel! neq 0 (
        echo   X Python venv 模块不可用
        echo     请确保安装了完整版 Python（从 python.org 下载）
        echo     或运行: python -m ensurepip --default-pip
        pause
        exit /b 1
    )

    python -m venv "%VENV_DIR%" --clear
    if !errorlevel! neq 0 (
        echo   X 虚拟环境创建失败
        echo     可能原因:
        echo       1. 目录权限不足（尝试以管理员运行）
        echo       2. 路径包含中文或特殊字符
        echo       3. 防病毒软件阻止
        echo     当前路径: %VENV_DIR%
        pause
        exit /b 1
    )
    echo     安装 Python 依赖，请稍候...
    echo.
    "%VENV_PIP%" cache purge >nul 2>&1
    "%VENV_PIP%" install -r "%BACKEND_DIR%\requirements.txt" --no-cache-dir -i "%PIP_MIRROR%"
    if !errorlevel! neq 0 (
        echo.
        echo   X Python 依赖安装失败
        pause
        exit /b 1
    )
    echo.
    echo !CURRENT_HASH!> "%HASH_FILE%"
    echo   √ 后端环境就绪
) else (
    rem venv 存在，检查依赖是否有变更
    set "SAVED_HASH="
    if exist "%HASH_FILE%" (
        for /f "tokens=*" %%i in ('type "%HASH_FILE%"') do set "SAVED_HASH=%%i"
    ) else (
        set "SAVED_HASH=none"
    )
    if "!CURRENT_HASH!"=="!SAVED_HASH!" (
        echo   √ 依赖无变更，跳过
    ) else (
        echo     检测到变更，更新后端依赖，请稍候...
        echo.
        "%VENV_PIP%" install -r "%BACKEND_DIR%\requirements.txt" --no-cache-dir -i "%PIP_MIRROR%"
        if !errorlevel! neq 0 (
            echo.
            echo   X Python 依赖更新失败
            pause
            exit /b 1
        )
        echo.
        echo !CURRENT_HASH!> "%HASH_FILE%"
        echo   √ 后端依赖更新完成
    )
)

:: 检查 VC++ 运行时（greenlet/playwright 的 C 扩展依赖 MSVCP140/VCRUNTIME140）
"%VENV_PYTHON%" -c "import greenlet" >nul 2>&1
if !errorlevel! neq 0 (
    echo.
    echo   X 缺少 Microsoft Visual C++ 运行时组件
    echo     greenlet 加载失败，浏览器自动化功能不可用
    echo.
    echo     请下载并安装「Visual C++ Redistributable」:
    echo       https://aka.ms/vs/17/release/vc_redist.x64.exe
    echo.
    echo     安装完成后重新运行本脚本即可。
    echo.
    pause
    exit /b 1
)

:: --- 浏览器内核 ---
if /i "!BROWSER_BACKEND!"=="patchright" (
    set "PW_READY=0"
    for /d %%d in ("%PLAYWRIGHT_BROWSERS_PATH%\chromium-*") do set "PW_READY=1"
    if "!PW_READY!"=="1" (
        echo   √ patchright Chromium 已就绪
    ) else (
        echo     下载 patchright Chromium（约 250MB，仅首次）...
        set "PLAYWRIGHT_DOWNLOAD_HOST=%PW_MIRROR%"
        "%VENV_PYTHON%" -m patchright install chromium chromium-headless-shell
        if !errorlevel! neq 0 (
            echo     镜像下载失败，尝试官方源重试...
            set "PLAYWRIGHT_DOWNLOAD_HOST="
            "%VENV_PYTHON%" -m patchright install chromium chromium-headless-shell
            if !errorlevel! neq 0 (
                echo   X Chromium 下载失败（登录/发布必需）。可开启代理后重新运行本脚本
                pause
                exit /b 1
            )
        )
        echo   √ patchright Chromium 就绪
    )
) else (
    :: 检查 CloakBrowser 二进制文件（仅 cloakbrowser 后端模式）
    set "CB_SRC=系统"
    set "CB_PATH="
    set "CHROME_FOUND=0"
    set "CB_BUILTIN=!DEP_PREFIX!\cloakbrowser\chrome.exe"
    if exist "!CB_BUILTIN!" (
        set "CLOAKBROWSER_BINARY_PATH=!CB_BUILTIN!"
        set "CB_SRC=内置"
        set "CB_PATH=!CB_BUILTIN!"
        set "CHROME_FOUND=1"
    )
    if "!CHROME_FOUND!"=="0" (
        set "CLOAKBROWSER_DIR=!USERPROFILE!\.cloakbrowser"
        for /d %%d in ("!CLOAKBROWSER_DIR!\chromium-*") do (
            if exist "%%d\chrome.exe" set "CHROME_FOUND=1" & set "CB_PATH=%%d\chrome.exe"
        )
    )

    if "!CHROME_FOUND!"=="0" (
        echo     首次使用，下载 CloakBrowser 浏览器（约 200MB）...

        rem 获取下载信息
        "%VENV_PYTHON%" -c "import cloakbrowser.download as d; f=open(r'%TEMP%\cb_info.txt','w'); f.write(str(d.get_fallback_download_url())+'\n'); f.write(str(d.get_binary_dir())+'\n'); f.close()"
        set "DOWNLOAD_URL="
        set "BINARY_DIR="
        if exist "%TEMP%\cb_info.txt" (
            set /p DOWNLOAD_URL=<"%TEMP%\cb_info.txt"
            for /f "skip=1 tokens=*" %%d in ('type "%TEMP%\cb_info.txt"') do set "BINARY_DIR=%%d"
            del /f "%TEMP%\cb_info.txt" >nul 2>&1
        )

        echo     下载地址: !DOWNLOAD_URL!
        echo.

        rem 使用 curl 下载（带进度条）
        rem 从 URL 检测文件格式（.zip 或 .tar.gz）
        set "TMP_EXT=.zip"
        echo !DOWNLOAD_URL! | findstr /C:".tar.gz" >nul 2>&1
        if !errorlevel! equ 0 set "TMP_EXT=.tar.gz"

        set "TMP_FILE=%TEMP%\cloakbrowser!TMP_EXT!"
        curl -L -# -o "!TMP_FILE!" "!DOWNLOAD_URL!"
        if !errorlevel! neq 0 (
            echo.
            echo     主下载失败，尝试 GitHub 备用地址...
            set "GITHUB_URL=!DOWNLOAD_URL:cloakbrowser.dev=github.com/CloakHQ/cloakbrowser/releases/download!"
            curl -L -# -o "!TMP_FILE!" "!GITHUB_URL!"
            if !errorlevel! neq 0 (
                del /f "!TMP_FILE!" >nul 2>&1
                echo   X CloakBrowser 下载失败，请检查网络连接
                pause
                exit /b 1
            )
        )

        echo.
        echo     解压中...

        rem 解压（tar -xf 自动识别 zip 和 tar.gz 格式）
        if not exist "!BINARY_DIR!" mkdir "!BINARY_DIR!"
        tar -xf "!TMP_FILE!" -C "!BINARY_DIR!" >nul 2>&1
        del /f "!TMP_FILE!" >nul 2>&1

        rem 检查是否成功（chrome.exe 可能直接在 BINARY_DIR 或其子目录中）
        set "EXTRACT_OK=0"
        if exist "!BINARY_DIR!\chrome.exe" set "EXTRACT_OK=1"
        if "!EXTRACT_OK!"=="0" (
            for /d %%d in ("!BINARY_DIR!\chromium-*") do (
                if exist "%%d\chrome.exe" set "EXTRACT_OK=1"
            )
        )

        if "!EXTRACT_OK!"=="1" (
            echo   √ CloakBrowser 下载完成
        ) else (
            echo   X CloakBrowser 解压失败
            pause
            exit /b 1
        )
    ) else (
        echo   √ CloakBrowser 已安装 ^(!CB_SRC!^) [!CB_PATH!]
    )
)

:: ============================================================
:: Step 4: 前端 (Flask 托管 dist) + MCP 环境
:: ============================================================
echo.
echo [4/6] 准备前端 + MCP 环境...

:: --- 前端：生产模式由后端同端口托管 frontend/dist；分发包自带 dist，缺失才现场构建 ---
if exist "%FRONTEND_DIST%\index.html" (
    echo   √ 前端 dist 就绪（由后端同端口托管）
) else (
    echo   ! 未找到 frontend/dist（分发包应自带）— 现场构建（需联网，约 2 分钟）...
    cd /d "%FRONTEND_DIR%"
    call npm install --prefer-offline --registry=https://registry.npmmirror.com
    call npm run build
    if not exist "%FRONTEND_DIST%\index.html" (
        echo   X 前端构建失败，界面不可用
        pause
        exit /b 1
    )
    echo   √ 前端 dist 构建完成
)

:: --- MCP: node_modules 缺失才安装；dist 缺失或代码变更才编译（分发包自带 dist，通常跳过）---
if "!NODE_OK!"=="1" goto mcp_setup
echo   ! 无 Node.js — 跳过 MCP/AI 服务
goto mcp_done

:mcp_setup
set "HASH_FILE=%PROJECT_ROOT%\.mcp_deps_hash"
set "CURRENT_HASH="
for /f "tokens=*" %%i in ('git -C "%PROJECT_ROOT%" log -1 --format^=%%H -- backend-mcp 2^>nul') do set "CURRENT_HASH=%%i"
if "!CURRENT_HASH!"=="" set "CURRENT_HASH=no-git"

if not exist "%MCP_DIR%\node_modules" (
    echo     安装 MCP 依赖，请稍候...
    echo.
    cd /d "%MCP_DIR%"
    call npm install --prefer-offline --registry=https://registry.npmmirror.com
    echo.
    echo !CURRENT_HASH!> "%HASH_FILE%"
    echo   √ MCP 依赖就绪
) else (
    set "SAVED_HASH="
    if exist "%HASH_FILE%" (
        for /f "tokens=*" %%i in ('type "%HASH_FILE%"') do set "SAVED_HASH=%%i"
    ) else (
        set "SAVED_HASH=none"
    )
    if "!CURRENT_HASH!"=="!SAVED_HASH!" (
        echo   √ MCP 依赖无变更，跳过
    ) else (
        echo     检测到变更，更新 MCP 依赖，请稍候...
        echo.
        cd /d "%MCP_DIR%"
        call npm install --prefer-offline --registry=https://registry.npmmirror.com
        echo.
        echo !CURRENT_HASH!> "%HASH_FILE%"
        echo   √ MCP 依赖更新完成
    )
)

set "MCP_BUILD=0"
if not exist "%MCP_DIR%\dist\index.js" set "MCP_BUILD=1"
set "SAVED_HASH="
if exist "%HASH_FILE%" (
    for /f "tokens=*" %%i in ('type "%HASH_FILE%"') do set "SAVED_HASH=%%i"
) else (
    set "SAVED_HASH=none"
)
if not "!CURRENT_HASH!"=="!SAVED_HASH!" set "MCP_BUILD=1"

if "!MCP_BUILD!"=="1" (
    echo     编译 MCP ...
    cd /d "%MCP_DIR%"
    call npm run build
    if !errorlevel! neq 0 (
        echo   X MCP 编译失败
        pause
        exit /b 1
    )
    echo !CURRENT_HASH!> "%HASH_FILE%"
    echo   √ MCP 编译完成
) else (
    echo   √ MCP 无变更，跳过编译
)

if exist "%MCP_DIR%\dist\index.js" set "MCP_READY=1"

:mcp_done

:: ============================================================
:: Step 5: 启动服务
:: ============================================================
echo.
echo [5/6] 启动服务...

:: 确保端口完全释放
timeout /t 1 /nobreak >nul

:: 启动后端（使用完整路径避免变量展开问题）
cd /d "%BACKEND_DIR%"
set "SAU_PORT=5409"
start "SAU-Backend" /B cmd /c ""%VENV_DIR%\Scripts\python.exe" app.py > "%BACKEND_LOG%" 2>&1"

:: 等待后端进程启动并获取 PID
timeout /t 2 /nobreak >nul
for /f "tokens=5" %%a in ('netstat -aon ^| findstr :5409 ^| findstr LISTENING 2^>nul') do set "BACKEND_PID=%%a"
echo   √ 后端已启动 (PID: !BACKEND_PID!)

:: 启动 MCP（直跑 node，不再经 npm）
if "!MCP_READY!"=="1" (
    cd /d "%MCP_DIR%"
    start "SAU-MCP" /B cmd /c "set TRANSPORT_MODE=%TRANSPORT_MODE%&& node dist\index.js > "%MCP_LOG%" 2>&1"
    timeout /t 2 /nobreak >nul
    set "MCP_PID="
    for /f "tokens=5" %%a in ('netstat -aon ^| findstr :5410 ^| findstr LISTENING 2^>nul') do set "MCP_PID=%%a"
    if defined MCP_PID (
        echo   √ MCP 已启动 (PID: !MCP_PID!, transport: %TRANSPORT_MODE%)
    ) else (
        echo   √ MCP 已启动 (transport: %TRANSPORT_MODE%, stdio 模式)
    )
    echo !MCP_PID!> "%PROJECT_ROOT%\.mcp.pid"
)

:: 开发者逃生口：SAU_FRONTEND_DEV=1 时保留 vite dev server（5173）
if /i "%SAU_FRONTEND_DEV%"=="1" (
    cd /d "%FRONTEND_DIR%"
    start "SAU-Frontend" /B cmd /c "npm run dev > "%FRONTEND_LOG%" 2>&1"
    timeout /t 2 /nobreak >nul
    for /f "tokens=5" %%a in ('netstat -aon ^| findstr :5173 ^| findstr LISTENING 2^>nul') do set "FRONTEND_PID=%%a"
    echo   √ 前端 dev server 已启动 (PID: !FRONTEND_PID!)
    echo !FRONTEND_PID!> "%PROJECT_ROOT%\.frontend.pid"
)

:: 保存 PID 到文件，用于停止服务
echo !BACKEND_PID!> "%PROJECT_ROOT%\.backend.pid"

cd /d "%PROJECT_ROOT%"

:: ============================================================
:: Step 6: 等待服务就绪并显示入口
:: ============================================================
echo.
echo [6/6] 等待服务就绪...

:: 等待后端（自动检测端口）
set "BACKEND_PORT=5409"
set /a "COUNT=0"
:wait_backend
set /a "COUNT+=1"
if !COUNT! GTR 60 (
    echo   X 后端启动超时，请查看日志: %BACKEND_LOG%
    echo.
    echo   最后 10 行日志:
    powershell -Command "Get-Content '%BACKEND_LOG%' -Tail 10"
    pause
    exit /b 1
)

:: 从日志检测实际端口
if exist "%BACKEND_LOG%" (
    for /f "tokens=*" %%p in ('powershell -Command "Select-String -Path '%BACKEND_LOG%' -Pattern 'Serving on http://0\.0\.0\.0:(\d+)' | ForEach-Object { $_.Matches.Groups[1].Value } | Select-Object -Last 1" 2^>nul') do set "BACKEND_PORT=%%p"
)

curl -s -o nul -w "%%{http_code}" http://127.0.0.1:!BACKEND_PORT!/api/health 2>nul | findstr "200" >nul
if !errorlevel! neq 0 (
    timeout /t 1 /nobreak >nul
    goto wait_backend
)
echo   √ 后端就绪 (端口: !BACKEND_PORT!)

if /i "%SAU_FRONTEND_DEV%"=="1" goto wait_frontend
if "!MCP_READY!"=="1" goto wait_mcp
goto show_info

:: 等待前端（仅 dev 模式）
:wait_frontend
set /a "COUNT=0"
:wait_frontend_loop
set /a "COUNT+=1"
if !COUNT! GTR 60 (
    echo   X 前端启动超时（60秒），但服务可能仍在运行
    echo   请手动访问 http://localhost:5173 检查
    echo.
    goto wait_mcp
)
:: 检查端口 5173 是否被占用（前端已启动）
netstat -an | findstr ":5173" | findstr "LISTENING" >nul 2>&1
if !errorlevel! equ 0 (
    echo   √ 前端就绪
    goto wait_mcp
)
timeout /t 1 /nobreak >nul
goto wait_frontend_loop

:: 等待 MCP（通过日志里的 "[MCP] Server ready" 判断；最长 15 秒）
:wait_mcp
if not "!MCP_READY!"=="1" goto show_info
set /a "MCP_COUNT=0"
:wait_mcp_loop
set /a "MCP_COUNT+=1"
if !MCP_COUNT! GTR 15 (
    echo   ! MCP 启动检查超时（15秒），请查看日志: %MCP_LOG%
    goto show_info
)
if exist "%MCP_LOG%" (
    findstr /C:"Server ready" "%MCP_LOG%" >nul 2>&1
    if !errorlevel! equ 0 (
        echo   √ MCP 就绪 (transport: %TRANSPORT_MODE%)
        goto show_info
    )
)
timeout /t 1 /nobreak >nul
goto wait_mcp_loop

:show_info
:: 显示访问入口
echo.
echo ============================================
if /i "%SAU_FRONTEND_DEV%"=="1" (
    echo   前端界面^(dev^): http://localhost:5173
    echo   后端 API: http://localhost:!BACKEND_PORT!
) else (
    echo   界面入口: http://localhost:!BACKEND_PORT!
    start "" "http://localhost:!BACKEND_PORT!"
)
if /i "%TRANSPORT_MODE%"=="sse" (
    echo   MCP  SSE:   http://localhost:5410/sse
) else if /i "%TRANSPORT_MODE%"=="both" (
    echo   MCP  SSE:   http://localhost:5410/sse
) else (
    echo   MCP  stdio: 启动中 ^(transport=%TRANSPORT_MODE%^)
)
echo ============================================
echo.
echo 按 Ctrl+C 停止所有服务
echo.
echo --- 后端日志 ---
powershell -Command "Get-Content '%BACKEND_LOG%' -Wait -Tail 50"
