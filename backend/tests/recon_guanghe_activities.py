"""侦察光合发布页「参与话题活动」弹层：抓列表/搜索 XHR 与弹层 DOM 结构。

用法:
    cd backend && BROWSER_BACKEND=patchright .venv/bin/python tests/recon_guanghe_activities.py

产物:
    data/screenshots/gh_activity_dialog.png       弹层打开后的整页截图
    data/screenshots/gh_activity_searched.png     搜索后的整页截图
    data/screenshots/gh_activity_recon.json       XHR 记录 + DOM 摘要
"""
import asyncio
import json
import os
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent.parent
sys.path.insert(0, str(REPO / "backend"))
os.environ.setdefault("BROWSER_BACKEND", "patchright")

from impl._browser import create_browser, create_context
from impl.taobao_guanghe.platform import (
    _GUANGHE_IMAGE_PUBLISH_URL,
    TaobaoGuanghePlatform,
)

COOKIE = REPO / "data" / "cookiesFile" / "459a8224-e0ff-11f1-97f0-f3279faefabc.json"
OUT = REPO / "data" / "screenshots"

XHR_KEYWORDS = ("topic", "activity", "subject", "campaign", "match", "game", "huodong")


async def main():
    OUT.mkdir(parents=True, exist_ok=True)
    xhrs = []

    async def on_response(resp):
        url = resp.url or ""
        if "topicselector" not in url:
            return
        try:
            body = await resp.text()
        except Exception:
            body = ""
        try:
            post = resp.request.post_data
        except Exception:
            post = None
        xhrs.append({"type": resp.request.resource_type, "url": url, "status": resp.status,
                     "post_data": post, "body": body})

    browser = await create_browser(headless=True)
    try:
        ctx = await create_context(browser, storage_state=str(COOKIE))
        page = await ctx.new_page()
        page.on("response", on_response)
        await page.goto(_GUANGHE_IMAGE_PUBLISH_URL, wait_until="domcontentloaded", timeout=30000)
        await asyncio.sleep(5)
        await TaobaoGuanghePlatform._dismiss_guide_modal(page)
        frame = await TaobaoGuanghePlatform._find_image_publish_frame(page)

        # 1. 点开「点击添加话题」入口（xhrs 从页面加载起持续抓取，含 script/JSONP）
        entry = frame.locator("text=点击添加话题").first
        await entry.wait_for(state="visible", timeout=15000)
        await entry.click()
        await asyncio.sleep(3)
        await page.screenshot(path=str(OUT / "gh_activity_dialog.png"), full_page=True)

        # 2. dump 弹层文本与候选容器 DOM（弹层可能在 iframe 内或页面层）
        def dump_js(marker):
            return """(mk) => {
                const hits = [];
                for (const el of document.querySelectorAll('div')) {
                    const t = (el.innerText || '');
                    if (t.includes(mk) && t.length < 800) {
                        hits.push({cls: el.className, text: t.slice(0, 300)});
                    }
                }
                return hits.slice(0, 10);
            }"""
        frame_dump = await frame.evaluate(dump_js("征稿"))
        page_dump = await page.evaluate(dump_js("征稿"))

        # 3. 按「话题选择」标题定位弹层根节点
        dialog_html = await frame.evaluate(
            """() => {
                const heading = [...document.querySelectorAll('*')].find(
                    el => el.children.length === 0 && (el.textContent || '').trim() === '话题选择'
                );
                if (!heading) return null;
                let root = heading;
                for (let i = 0; i < 10 && root; i++) {
                    root = root.parentElement;
                    const t = (root && root.innerText) || '';
                    if (t.includes('确认提交') && t.length < 2500) break;
                }
                return root ? root.outerHTML.slice(0, 20000) : null;
            }"""
        )

        # 4. 解析话题卡片列表（最内层匹配元素，任意标签）
        card_list = await frame.evaluate(
            """() => {
                const out = [];
                const seen = new Set();
                const isCardText = (t) => t.includes('#') && t.includes('作品数') && t.length < 250;
                for (const el of document.querySelectorAll('*')) {
                    const t = (el.innerText || '').replace(/\\s+/g, ' ').trim();
                    if (!isCardText(t)) continue;
                    // 跳过「更外层」的重复匹配：子元素里还有同样命中的就跳过
                    let inner = false;
                    for (const child of el.querySelectorAll('*')) {
                        if (isCardText((child.innerText || '').replace(/\\s+/g, ' ').trim())) { inner = true; break; }
                    }
                    if (inner) continue;
                    const key = t.slice(0, 60);
                    if (seen.has(key)) continue;
                    seen.add(key);
                    el.setAttribute('data-sau-topic', String(out.length));
                    out.push({idx: out.length, text: t.slice(0, 150), tag: el.tagName, cls: String(el.className).slice(0, 90)});
                }
                return out;
            }"""
        )
        # 分类侧边栏
        cats = await frame.evaluate(
            """() => {
                const out = [];
                for (const el of document.querySelectorAll('div, span')) {
                    if (el.children.length) continue;
                    const t = (el.textContent || '').trim();
                    if (['推荐', '时尚', '美妆', '家居', '美食', '宠物', '母婴', '运动', '数码'].includes(t)) {
                        out.push({text: t, cls: String(el.className).slice(0, 80)});
                    }
                }
                return out;
            }"""
        )

        # 4.5 尝试在 iframe 内用 lib.mtop 重放 topicselector 接口（分页拉全量）
        replay = None
        try:
            replay = await frame.evaluate(
                """async () => {
                const mtop = (window.lib && window.lib.mtop) || window.mtop;
                if (!mtop) return {err: 'no lib.mtop in frame'};
                const out = [];
                let cursor = '';
                let firstRaw = null;
                for (let i = 0; i < 30; i++) {
                    const res = await mtop.request({
                        api: 'mtop.taobao.media.guang.topic.topicselector',
                        v: '1.0',
                        data: Object.assign({}, cursor ? {cursor: cursor} : {}),
                    });
                    const d = (res && res.data) || {};
                    if (!firstRaw) firstRaw = {ret: res && res.ret, dataKeys: Object.keys(d)};
                    const topics = d.topics || [];
                    out.push(...topics);
                    cursor = d.cursor || '';
                    if (!cursor || !topics.length) break;
                }
                return {
                    count: out.length,
                    firstRaw,
                    sample: out.slice(0, 3).map(t => ({name: t.name || t.title, keys: Object.keys(t)})),
                    nameList: out.slice(0, 20).map(t => t.name || t.title || ''),
                };
            }"""
            )
        except Exception as exc:
            replay = {"err": str(exc)[:200]}
        print("replay:", json.dumps(replay, ensure_ascii=False)[:400])

        # 5. 演练选择流程：点第 0 张卡片 → 确认提交 → 读回填状态
        selected_flow = {"clicked": False, "confirmed": False, "after_text": None}
        try:
            card0 = frame.locator('[data-sau-topic="0"]').first
            await card0.click(timeout=5000)
            selected_flow["clicked"] = True
            await asyncio.sleep(1.5)
            await page.screenshot(path=str(OUT / "gh_activity_selected.png"), full_page=True)
            await TaobaoGuanghePlatform._js_click(frame, 'button:has-text("确认提交")', timeout_s=8)
            selected_flow["confirmed"] = True
            await asyncio.sleep(2)
            selected_flow["after_text"] = await frame.evaluate(
                """() => {
                    const root = document.querySelector('[class*="topic-v2-root"], [class*="topic-v2"]');
                    return root ? (root.innerText || '').slice(0, 300) : null;
                }"""
            )
            await page.screenshot(path=str(OUT / "gh_activity_confirmed.png"), full_page=True)
        except Exception as exc:
            selected_flow["error"] = str(exc)[:200]
        # 扫内嵌全局 state / 内联 script 里的话题数据
        state_keys = await frame.evaluate(
            """() => {
                const keys = Object.keys(window).filter(k => /state|store|props|INITIAL/i.test(k));
                let scriptHit = null;
                for (const s of document.scripts) {
                    if (!s.src && s.textContent && s.textContent.includes('作品数')) {
                        scriptHit = s.textContent.slice(0, 3000);
                        break;
                    }
                }
                return {keys, scriptHit};
            }"""
        )

        report = {
            "selected_flow": selected_flow,
            "frame_dump": frame_dump,
            "page_dump": page_dump,
            "dialog_html": dialog_html,
            "card_list": card_list,
            "categories": cats,
            "state_keys": state_keys,
            "xhrs": xhrs,
        }
        (OUT / "gh_activity_recon.json").write_text(
            json.dumps(report, ensure_ascii=False, indent=1), encoding="utf-8"
        )
        print(
            f"DONE flow={selected_flow} dialog_html={bool(dialog_html)} "
            f"cards={len(card_list)} cats={len(cats)} xhrs={len(xhrs)}"
        )
    finally:
        await browser.close()


if __name__ == "__main__":
    asyncio.run(main())
