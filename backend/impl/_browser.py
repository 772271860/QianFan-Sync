"""浏览器工厂 — 统一入口。

默认使用 CloakBrowser stealth 浏览器；通过环境变量 BROWSER_BACKEND 可切换：
  - cloakbrowser（默认）：CloakBrowser stealth Chromium
  - patchright：patchright（Playwright 补丁版 Chromium，免 license）
  - bitbrowser：连接本机比特浏览器（BitBrowser）的指纹环境

所有打开浏览器的入口都集中在这里。调用方不要直接调 browser.new_context
或 cloakbrowser.launch_*，避免东一套西一套。

所有 context 使用 no_viewport=True，页面内容跟随窗口大小自动 reflow。
"""

from __future__ import annotations

import asyncio
import json
import os

from conf import LOGIN_HEADLESS, LOCAL_CHROME_HEADLESS
from util._logger import get_channel_logger

logger = get_channel_logger("browser")

# ──────────── 后端选择 ────────────
# BROWSER_BACKEND=bitbrowser 时走比特浏览器本地 API（默认 cloakbrowser）
_BROWSER_BACKEND = os.environ.get("BROWSER_BACKEND", "cloakbrowser").strip().lower()
_BIT_API_BASE = os.environ.get("BITBROWSER_API", "http://127.0.0.1:54345").rstrip("/")
_BIT_ENV_ID = os.environ.get("BITBROWSER_ENV_ID", "").strip()


def _bit_backend() -> bool:
    return _BROWSER_BACKEND == "bitbrowser"


def _patchright_backend() -> bool:
    return _BROWSER_BACKEND == "patchright"


def _bind_playwright(obj, pw):
    """把 playwright 实例绑到 browser/context 上，close 时一并 stop。

    cloakbrowser 的 launch_* 内部管理 playwright 生命周期；patchright 是
    原生 Playwright API，需要调用方自己 stop，否则 driver 进程会残留。
    """
    obj._pw = pw
    orig_close = obj.close

    async def _close(*args, **kwargs):
        try:
            return await orig_close(*args, **kwargs)
        finally:
            try:
                await pw.stop()
            except Exception:
                pass

    obj.close = _close
    return obj


def _bind_playwright_sync(obj, pw):
    """_bind_playwright 的同步版。"""
    obj._pw = pw
    orig_close = obj.close

    def _close(*args, **kwargs):
        try:
            return orig_close(*args, **kwargs)
        finally:
            try:
                pw.stop()
            except Exception:
                pass

    obj.close = _close
    return obj


def _bit_post(path: str, payload: dict, timeout: float = 30.0) -> dict:
    """调用比特浏览器本地 API（同步，需放到线程里执行）。"""
    import requests

    resp = requests.post(f"{_BIT_API_BASE}{path}", json=payload, timeout=timeout)
    resp.raise_for_status()
    body = resp.json()
    if not body.get("success"):
        raise RuntimeError(f"比特浏览器 API {path} 失败: {body.get('msg') or body}")
    return body.get("data") or {}


def _bit_resolve_env_id() -> str:
    """确定要打开的比特浏览器环境 id：优先环境变量，否则取列表第一个。"""
    if _BIT_ENV_ID:
        return _BIT_ENV_ID
    data = _bit_post("/browser/list", {"page": 0, "pageSize": 1})
    items = data.get("list") or data.get("records") or []
    if not items:
        raise RuntimeError("比特浏览器里还没有环境，请先在客户端创建一个环境")
    env_id = items[0].get("id")
    if not env_id:
        raise RuntimeError(f"无法读取比特浏览器环境 id: {items[0]}")
    logger.info("[bitbrowser] 未指定 BITBROWSER_ENV_ID，使用第一个环境: %s", env_id)
    return env_id


def _bit_open(env_id: str) -> dict:
    """打开比特浏览器环境，返回含 ws（CDP 地址）的 data。"""
    return _bit_post(
        "/browser/open",
        {"id": env_id, "args": ["--start-maximized"]},
        timeout=60.0,
    )


def _bit_close(env_id: str) -> None:
    try:
        _bit_post("/browser/close", {"id": env_id}, timeout=15.0)
    except Exception as e:  # 窗口已被用户关闭时也会走到这里
        logger.info("[bitbrowser] 关闭环境 %s 时收到异常（可忽略）: %s", env_id, e)


def _load_storage_cookies(storage_state) -> list | None:
    """从 Playwright storage_state（文件路径或 dict）里取 cookies。"""
    if not storage_state:
        return None
    if isinstance(storage_state, dict):
        return storage_state.get("cookies") or None
    try:
        with open(storage_state, "r", encoding="utf-8") as f:
            return json.load(f).get("cookies") or None
    except Exception as e:
        logger.warning("[bitbrowser] 读取 cookie 文件失败: %s", e)
        return None


class _BitContext:
    """比特浏览器环境 context 的代理。

    close() 不真正关闭 context（关闭会拆掉整个指纹环境），只把后续
    browser.close() 视为代码主动关闭，避免 watchdog 误判为用户关窗。
    """

    def __init__(self, context, owner):
        self._context = context
        self._owner = owner

    def __getattr__(self, name):
        return getattr(self._context, name)

    async def close(self):
        self._owner._is_close_by_code = True

    def __repr__(self):
        return f"<BitContext {self._context!r}>"


class _BitBrowser:
    """比特浏览器环境的 Playwright Browser 代理。"""

    def __init__(self, playwright, browser, env_id: str, sync: bool = False):
        self._pw = playwright
        self._browser = browser
        self._env_id = env_id
        self._is_close_by_code = False
        self._context_proxy = None
        self._sync = sync

    def __getattr__(self, name):
        return getattr(self._browser, name)

    def _wrap_context(self, ctx):
        proxy = self._context_proxy
        if proxy is None or proxy._context is not ctx:
            proxy = _BitContext(ctx, self)
            self._context_proxy = proxy
        return proxy

    def is_connected(self) -> bool:
        try:
            return self._browser.is_connected()
        except Exception:
            return False

    def __repr__(self):
        return f"<BitBrowser env={self._env_id}>"


class _BitBrowserAsync(_BitBrowser):
    async def new_context(self, storage_state=None, user_agent=None, **kwargs):
        contexts = self._browser.contexts
        ctx = contexts[0] if contexts else await self._browser.new_context()
        cookies = _load_storage_cookies(storage_state)
        if cookies:
            try:
                await ctx.add_cookies(cookies)
            except Exception as e:
                logger.warning("[bitbrowser] 注入 cookie 失败: %s", e)
        return self._wrap_context(ctx)

    async def close(self):
        self._is_close_by_code = True
        try:
            await self._browser.close()
        except Exception:
            pass
        await asyncio.to_thread(_bit_close, self._env_id)
        try:
            await self._pw.stop()
        except Exception:
            pass


class _BitBrowserSync(_BitBrowser):
    def new_context(self, storage_state=None, user_agent=None, **kwargs):
        contexts = self._browser.contexts
        ctx = contexts[0] if contexts else self._browser.new_context()
        cookies = _load_storage_cookies(storage_state)
        if cookies:
            try:
                ctx.add_cookies(cookies)
            except Exception as e:
                logger.warning("[bitbrowser] 注入 cookie 失败: %s", e)
        return self._wrap_context(ctx)

    def close(self):
        self._is_close_by_code = True
        try:
            self._browser.close()
        except Exception:
            pass
        _bit_close(self._env_id)
        try:
            self._pw.stop()
        except Exception:
            pass


def _create_bit_browser_sync():
    from playwright.sync_api import sync_playwright

    env_id = _bit_resolve_env_id()
    info = _bit_open(env_id)
    ws = info.get("ws")
    if not ws:
        raise RuntimeError(f"比特浏览器未返回 CDP 地址: {info}")
    pw = sync_playwright().start()
    browser = pw.chromium.connect_over_cdp(ws)
    logger.info("[bitbrowser] 已连接环境 %s", env_id)
    return _BitBrowserSync(pw, browser, env_id, sync=True)


async def _create_bit_browser(login_mode: bool = False):
    from playwright.async_api import async_playwright

    env_id = await asyncio.to_thread(_bit_resolve_env_id)
    info = await asyncio.to_thread(_bit_open, env_id)
    ws = info.get("ws")
    if not ws:
        raise RuntimeError(f"比特浏览器未返回 CDP 地址: {info}")
    pw = await async_playwright().start()
    browser = await pw.chromium.connect_over_cdp(ws)
    wrapper = _BitBrowserAsync(pw, browser, env_id)
    logger.info("[bitbrowser] 已连接环境 %s", env_id)
    if login_mode:
        _install_close_watchdog(wrapper)
    return wrapper


def _download_binary():
    """Download CloakBrowser stealth binary."""
    from cloakbrowser import ensure_binary
    ensure_binary()


def init():
    """Pre-download CloakBrowser binary at startup (skipped for BitBrowser)."""
    if _bit_backend():
        logger.info("浏览器后端: 比特浏览器（%s）", _BIT_API_BASE)
        return
    if _patchright_backend():
        logger.info("浏览器后端: patchright（Playwright 补丁版 Chromium）")
        return
    try:
        _download_binary()
        logger.info("CloakBrowser 隐匿浏览器已就绪")
    except Exception as e:
        logger.warning("CloakBrowser 隐匿浏览器不可用(%s)", e)


# ──────────── 异步入口 ────────────

def _install_close_watchdog(browser) -> None:
    """用户手动关浏览器时 cancel 当前 task。

    login 或有头浏览器（发布场景）：用户主动关浏览器 → cancel 当前 task，
    使 login/发布流程立即终止，避免后端 worker 一直阻塞、日志狂刷。

    判定标志 is_close_by_code（挂在 browser 对象上）：
      False（默认）= 代码尚未主动关浏览器。此时浏览器若断开 = 用户手动关闭
                    → watchdog / disconnected 回调 cancel 当前 task。
      True = 代码（发布成功/失败收尾）主动调用了关闭。
            → 是正常收尾，绝不 cancel（避免把成功发布误判为失败）。

    各平台发布收尾应走 BasePlatform.close_browser(browser, is_close_by_code=True)，
    它会先置标志再关闭。双重机制：disconnected 事件（快速路径）+ watchdog
    轮询 is_connected()（可靠兜底）。
    """
    task = asyncio.current_task()
    browser._is_close_by_code = False  # 标志位，默认"非代码关闭"

    def _should_cancel():
        """是否应当 cancel: 浏览器断开 且 非代码主动关闭 且 task 仍存活。"""
        return (
            not browser._is_close_by_code
            and task is not None
            and not task.done()
        )

    def _on_browser_closed():
        if _should_cancel():
            logger.info("[浏览器] 检测到用户关闭了浏览器，取消当前发布任务")
            task.cancel()

    try:
        browser.on("disconnected", _on_browser_closed)
    except Exception as e:
        logger.info("[浏览器] 关闭事件注册失败，改用轮询兜底: %s", e)

    # watchdog: 后台轮询 is_connected(), 断开且非代码关闭则 cancel 发布 task。
    # 解决「平台 while True 循环在浏览器关闭后无限刷日志」的统一方案,
    # 对所有平台适用, 各平台代码只需在发布收尾走 close_browser 即可。
    async def _watchdog():
        try:
            while True:
                await asyncio.sleep(0.5)
                if browser._is_close_by_code or task is None or task.done():
                    return  # 代码已主动关闭 / task 已结束 → 退出
                try:
                    if not browser.is_connected():
                        logger.info("[浏览器] 轮询检测到用户关闭了浏览器，取消当前发布任务")
                        task.cancel()
                        return
                except Exception:
                    # is_connected 自身异常(对象已释放)也视为断开
                    if _should_cancel():
                        logger.info("[浏览器] 轮询检测到浏览器异常断开，取消当前发布任务")
                        task.cancel()
                    return
        except asyncio.CancelledError:
            pass

    if task is not None:
        asyncio.create_task(_watchdog())

    # 包装 close：代码主动关闭时置 is_close_by_code=True，
    # 使 disconnected 回调和 watchdog 都不再 cancel（正常收尾）。
    _orig_close = browser.close

    async def _safe_close(*args, **kwargs):
        browser._is_close_by_code = True  # 同步置标志，在 await 之前生效
        return await _orig_close(*args, **kwargs)

    browser.close = _safe_close


async def _create_patchright_browser(headless: bool, login_mode: bool):
    """patchright 后端：启动一个 Playwright 补丁版 Chromium。"""
    from patchright.async_api import async_playwright

    pw = await async_playwright().start()
    browser = await pw.chromium.launch(headless=headless, args=["--start-maximized"])
    _bind_playwright(browser, pw)
    logger.info("[patchright] 浏览器已启动 (headless=%s)", headless)
    if login_mode or headless is False:
        _install_close_watchdog(browser)
    return browser


async def create_browser(
    headless: bool | None = None,
    login_mode: bool = False,
    humanize: bool = False,
    human_preset: str = "default",
):
    """异步入口：创建 stealth Chromium 浏览器。

    不接 proxy / extra_args —— 历史代理配置已废弃。

    login_mode=True 或 headless=False（有头）时，自动监听浏览器关闭
    事件：**用户手动**关浏览器会 cancel 当前 asyncio task，使 login/发布
    流程立即终止并返回失败。而发布成功后平台代码主动 browser.close()
    的正常收尾不会误触发（内部已 disarm）。

    humanize=True 时启用 CloakBrowser 拟人化操作层（贝塞尔鼠标轨迹、
    逐键打字、平滑滚动等），仅建议在发布动作开启——会让操作明显变慢，
    login/check_cookie/sync_profile 等高频轻量调用保持关闭更稳妥。
    human_preset: 'default'(正常人速度) 或 'careful'(更慢更谨慎)。
    """
    if _bit_backend():
        return await _create_bit_browser(login_mode=login_mode)

    if headless is None:
        headless = LOGIN_HEADLESS if login_mode else LOCAL_CHROME_HEADLESS

    if _patchright_backend():
        return await _create_patchright_browser(headless=headless, login_mode=login_mode)

    from cloakbrowser import launch_async
    browser = await launch_async(
        headless=headless,
        args=["--start-maximized"],
        humanize=humanize,
        human_preset=human_preset,
    )

    if login_mode or headless is False:
        _install_close_watchdog(browser)

    return browser


async def create_context(
    browser,
    storage_state: str | None = None,
    user_agent: str | None = None,
):
    """异步入口：创建 browser context（no_viewport，跟随窗口自适应）。"""
    return await browser.new_context(
        storage_state=storage_state,
        user_agent=user_agent,
        no_viewport=True,
    )


async def close_browser(browser, is_close_by_code: bool = True) -> None:
    """统一关闭浏览器入口（发布/图集收尾用）。

    Args:
        browser: create_browser 返回的 browser 对象。
        is_close_by_code: True=代码主动关闭（发布成功/失败收尾），此时
            _browser.py 的 watchdog/disconnected 监听不会 cancel 当前 task；
            False 仅用于特殊场景，默认 True。

    各平台发布/图集上传方法在 finally 里关闭浏览器时，应统一调用本方法
    （或通过 BasePlatform.close_browser 委托），避免 watchdog 把「代码主动
    关闭」误判为「用户手动关闭」而触发 task cancel。

    模块级发布函数（如 xiaohongshu._publish_single_video，无 self）直接
    调用本函数；类方法走 BasePlatform.close_browser（内部委托本函数）。
    """
    try:
        browser._is_close_by_code = is_close_by_code
    except Exception:
        pass
    try:
        await browser.close()
    except Exception:
        pass


async def create_persistent_context(
    user_data_dir: str,
    headless: bool = False,
):
    """异步入口：登录扫码用持久化 context（no_viewport，跟随窗口自适应）。"""
    if _bit_backend():
        browser = await _create_bit_browser(login_mode=False)
        return await browser.new_context()
    if _patchright_backend():
        from patchright.async_api import async_playwright

        pw = await async_playwright().start()
        context = await pw.chromium.launch_persistent_context(
            user_data_dir,
            headless=headless,
            no_viewport=True,
            args=["--window-size=1920,1080", "--start-maximized"],
        )
        return _bind_playwright(context, pw)
    from cloakbrowser import launch_persistent_context_async
    return await launch_persistent_context_async(
        user_data_dir,
        headless=headless,
        no_viewport=True,
        args=["--window-size=1920,1080", "--start-maximized"],
    )


# ──────────── 同步入口 ────────────

def create_browser_sync(headless: bool = False):
    """同步入口：创建 stealth Chromium 浏览器。"""
    if _bit_backend():
        return _create_bit_browser_sync()
    if _patchright_backend():
        from patchright.sync_api import sync_playwright

        pw = sync_playwright().start()
        browser = pw.chromium.launch(headless=headless)
        return _bind_playwright_sync(browser, pw)
    from cloakbrowser import launch
    return launch(headless=headless)


def create_context_sync(
    browser,
    storage_state: str | None = None,
    user_agent: str | None = None,
):
    """同步入口：创建 browser context（no_viewport，跟随窗口自适应）。

    平台层不要直接调 browser.new_context()，统一走这个入口。
    """
    return browser.new_context(
        storage_state=storage_state,
        user_agent=user_agent,
        no_viewport=True,
    )
