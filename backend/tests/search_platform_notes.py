"""在平台管理页搜索关键词，确认工具发布的作品是否真的存在（只读）。"""

from __future__ import annotations

import asyncio
import os
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
os.environ.setdefault("BROWSER_BACKEND", "patchright")

from conf import BASE_DIR  # noqa: E402

COOKIES = {
    "guanghe": "459a8224-e0ff-11f1-97f0-f3279faefabc.json",
    "douyin": "55497300-e10a-11f1-97f0-f3279faefabc.json",
}


async def search_guanghe(keyword: str) -> None:
    from impl._browser import create_browser, create_context, close_browser

    cookie_path = str(Path(BASE_DIR) / "cookiesFile" / COOKIES["guanghe"])
    browser = await create_browser(headless=False)
    try:
        context = await create_context(browser, storage_state=cookie_path)
        page = await context.new_page()
        await page.goto(
            "https://creator.guanghe.taobao.com/page/workspace/tb",
            wait_until="domcontentloaded",
            timeout=60000,
        )
        await asyncio.sleep(9)
        # 搜索框在主 frame（Next 组件），输入关键词后点搜索
        box = page.locator('input[placeholder*="作品ID或关键字"]').first
        await box.wait_for(state="visible", timeout=15000)
        await box.fill(keyword)
        await page.get_by_text("搜索", exact=True).first.click()
        await asyncio.sleep(6)
        await page.screenshot(
            path=str(Path(BASE_DIR) / "logs" / "search_guanghe_result.png"),
            full_page=False,
        )
        texts = await page.evaluate(
            """() => [...document.querySelectorAll('div,span,p')]
                .map(el => (el.innerText || '').trim())
                .filter(t => t.includes('狐狸绒') || /ID:\\d{10,}/.test(t.replace(/\\s/g,'')))
                .slice(0, 12)"""
        )
        print("===== 光合搜索结果 =====")
        for t in texts[:12]:
            print("-", t.replace("\n", " | ")[:200])
        await context.close()
    finally:
        await close_browser(browser, is_close_by_code=True)


async def search_douyin(keyword: str) -> None:
    from impl._browser import create_browser, create_context, close_browser

    cookie_path = str(Path(BASE_DIR) / "cookiesFile" / COOKIES["douyin"])
    browser = await create_browser(headless=False)
    try:
        context = await create_context(browser, storage_state=cookie_path)
        page = await context.new_page()
        await page.goto(
            "https://creator.douyin.com/creator-micro/content/manage",
            wait_until="domcontentloaded",
            timeout=60000,
        )
        await asyncio.sleep(8)
        # 关掉可能的引导弹层
        for label in ("知道了", "我知道了"):
            try:
                btn = page.get_by_text(label, exact=True).first
                if await btn.is_visible():
                    await btn.click()
                    await asyncio.sleep(1)
            except Exception:
                pass
        box = page.locator('input[placeholder*="搜索作品标题"]').first
        await box.wait_for(state="visible", timeout=15000)
        await box.fill(keyword)
        await page.keyboard.press("Enter")
        await asyncio.sleep(6)
        await page.screenshot(
            path=str(Path(BASE_DIR) / "logs" / "search_douyin_result.png"),
            full_page=False,
        )
        body = await page.evaluate("() => document.body.innerText.slice(0, 4000)")
        print("===== 抖音搜索结果 =====")
        print(body.replace("\n\n", "\n")[:2500])
        await context.close()
    finally:
        await close_browser(browser, is_close_by_code=True)


def main():
    platform = sys.argv[1] if len(sys.argv) > 1 else "guanghe"
    keyword = sys.argv[2] if len(sys.argv) > 2 else "狐狸绒"
    if platform == "guanghe":
        asyncio.run(search_guanghe(keyword))
    else:
        asyncio.run(search_douyin(keyword))


if __name__ == "__main__":
    main()
