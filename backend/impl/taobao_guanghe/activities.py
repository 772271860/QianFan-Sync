"""淘宝光合「参与话题活动」数据源 —— 浏览器一次性抓取全量话题名。

发布页编辑器 iframe 内「点击添加话题」弹层的数据由 mtop JSONP 预取
(mtop.taobao.media.guang.topic.topicselector，搜索为前端过滤)；
lib.mtop 未暴露在 window 上且 mtop 需签名，无法纯 HTTP 直连，
因此走 DOM 解析(skill §3 第 3 层级)：
- 弹层左侧分类为 Fusion Next 菜单(``.next-menu-item``)，逐个点击遍历
- 话题卡片带稳定追踪属性 ``data-autolog="key=topic_item_card&text=可选话题:<名称>"``
  (CSS Modules 哈希 class 不可靠，追踪属性跨改版稳定)
- 每个分类切一次、扫一遍属性，汇总去重；调用方须加 TTL 缓存
"""

from __future__ import annotations

import asyncio

from util._logger import get_channel_logger

from .._browser import create_browser, create_context
from .platform import (
    _COOKIE_INVALID_MARKERS,
    _GUANGHE_IMAGE_PUBLISH_URL,
    TaobaoGuanghePlatform,
)

logger = get_channel_logger("taobao_guanghe")

_SCAN_TOPIC_NAMES_JS = """() => {
    const out = [];
    const seen = new Set();
    for (const el of document.querySelectorAll('[data-autolog]')) {
        const v = el.getAttribute('data-autolog') || '';
        if (!v.includes('可选话题:')) continue;
        const name = v.split('可选话题:')[1];
        if (name && !seen.has(name)) { seen.add(name); out.push(name); }
    }
    return out;
}"""


async def _scan_topic_names(frame) -> list:
    return await frame.evaluate(_SCAN_TOPIC_NAMES_JS)


async def _scan_with_scroll(frame, max_rounds: int = 3) -> list:
    """扫描当前分类的话题，并向下滚动列表补懒加载(分类内分页)。"""
    names = await _scan_topic_names(frame)
    for _ in range(max_rounds):
        await frame.evaluate(
            """() => {
            const list = document.querySelector('[class*="right-list"]');
            if (list) list.scrollTop = list.scrollHeight;
        }"""
        )
        await asyncio.sleep(1.2)
        new_names = await _scan_topic_names(frame)
        if len(new_names) <= len(names):
            break
        names = new_names
    return names


async def fetch_activities(cookie_path: str) -> list:
    """打开图文发布页 → 点「点击添加话题」→ 遍历分类抓全量话题。

    Returns:
        ``[{"name": ..., "category": ...}, ...]``，抓取失败抛异常。
    """
    browser = await create_browser(headless=True)
    try:
        ctx = await create_context(browser, storage_state=cookie_path)
        page = await ctx.new_page()
        await page.goto(_GUANGHE_IMAGE_PUBLISH_URL, wait_until="domcontentloaded", timeout=30000)
        await asyncio.sleep(5)
        if any(m in (page.url or "") for m in _COOKIE_INVALID_MARKERS):
            raise RuntimeError("cookie 失效，请重新登录淘宝光合")

        await TaobaoGuanghePlatform._dismiss_guide_modal(page)
        frame = await TaobaoGuanghePlatform._find_image_publish_frame(page)

        entry = frame.locator("text=点击添加话题").first
        await entry.wait_for(state="visible", timeout=15000)
        await entry.click()
        search_input = frame.locator('input[placeholder*="关键词"]').first
        await search_input.wait_for(state="visible", timeout=10000)
        await asyncio.sleep(2)  # 等弹层预取分页

        seen: dict[str, str] = {}
        # 默认「推荐」tab
        for n in await _scan_with_scroll(frame):
            seen.setdefault(n, "推荐")

        # 遍历左侧分类菜单（动态枚举，不硬编码分类名）
        cats = await frame.evaluate(
            """() => [...document.querySelectorAll('.next-menu-item')]
            .map((el, i) => ({i, text: (el.innerText || '').trim()}))
            .filter(x => x.text)"""
        )
        logger.info("[话题活动] 分类 %d 个: %s", len(cats), [c["text"] for c in cats])
        for c in cats:
            cat = c["text"]
            try:
                await frame.locator(".next-menu-item").nth(c["i"]).click(timeout=4000)
            except Exception as exc:
                logger.warning("[话题活动] 分类 %s 点击失败(跳过): %s", cat, str(exc)[:80])
                continue
            await asyncio.sleep(1.2)
            for n in await _scan_with_scroll(frame):
                seen.setdefault(n, cat)

        # 关闭弹层(取消)，把页面还原干净
        try:
            await TaobaoGuanghePlatform._js_click(frame, 'button:has-text("取消")', timeout_s=5)
        except Exception:
            pass

        result = [{"name": n, "category": cat} for n, cat in seen.items()]
        logger.info("[话题活动] ✓ 抓取到 %d 个话题", len(result))
        return result
    finally:
        await browser.close()
