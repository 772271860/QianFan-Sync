"""发布请求 payload 捕获（诊断「标题填了但平台不同步」类问题）。

走真实发布流程填表，但在点击发布按钮前拦截该页面所有网络请求并 abort，
请求不会到达平台服务器，因此【绝不会真正发布】。同时抓取表单 DOM 值，
对比「DOM 里看到的」和「实际提交出去的」差在哪里。

用法::

    backend/.venv/bin/python backend/tests/capture_publish_payload.py \
        --platform douyin \
        --cookie 55497300-xxxx.json \
        --images data/materials/2026/11/16/xxx.jpg \
        --title "演练勿发-标题同步测试" --desc "演练正文"

    --platform guanghe 同理（cookie 换光合账号）

捕获到的 POST payload 写入 data/logs/publish_payload_<platform>.json。
"""

from __future__ import annotations

import argparse
import asyncio
import json
import os
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
# 与正在运行的后端保持一致（后端进程也是 BROWSER_BACKEND=patchright）
os.environ.setdefault("BROWSER_BACKEND", "patchright")

from conf import BASE_DIR  # noqa: E402


def parse_args():
    ap = argparse.ArgumentParser(description="捕获发布 payload（不真正发布）")
    ap.add_argument("--platform", choices=["douyin", "guanghe"], required=True)
    ap.add_argument("--cookie", required=True, help="cookiesFile 下的 cookie 文件名")
    ap.add_argument("--images", nargs="+", required=True, help="图片路径")
    ap.add_argument("--title", default="演练勿发-标题同步测试")
    ap.add_argument("--desc", default="演练正文标题同步测试")
    ap.add_argument("--tags", nargs="*", default=[])
    ap.add_argument("--music", default="", help="抖音：空=自动选推荐")
    return ap.parse_args()


def resolve_images(paths: list[str]) -> list[str]:
    out = []
    for p in paths:
        path = Path(p).expanduser()
        if not path.is_absolute():
            path = Path.cwd() / path
        if not path.is_file():
            raise SystemExit(f"图片不存在: {path}")
        out.append(str(path))
    return out


def check_cookie(name: str) -> str:
    if not (BASE_DIR / "cookiesFile" / name).is_file():
        raise SystemExit(f"cookie 不存在: {BASE_DIR / 'cookiesFile' / name}")
    return name


async def install_capture(page, captured: list) -> None:
    """拦截该页面（含所有 iframe）之后的所有请求：记录并 abort，杜绝真实发布。"""

    async def handler(route, request):
        captured.append(
            {
                "method": request.method,
                "url": request.url,
                "post_data": (request.post_data or "")[:30000],
            }
        )
        try:
            await route.abort()
        except Exception:
            pass

    await page.route("**/*", handler)


async def dump_form_inputs(locator_owner, label: str) -> None:
    """打印表单里所有可见 input/textarea 的 placeholder 与当前值。"""
    try:
        rows = await locator_owner.evaluate(
            """() => [...document.querySelectorAll('input, textarea')].map(el => ({
                tag: el.tagName.toLowerCase(),
                placeholder: el.getAttribute('placeholder') || '',
                maxlength: el.maxLength > 0 ? el.maxLength : 0,
                value: (el.value || '').slice(0, 60),
                type: el.type || '',
                visible: !!(el.offsetWidth || el.offsetHeight),
            }))"""
        )
        print(f"[DOM] {label} 可见输入框:")
        for r in rows:
            if r.get("visible"):
                print(
                    f"    placeholder={r['placeholder']!r} maxlength={r['maxlength']} "
                    f"value={r['value']!r}"
                )
    except Exception as e:
        print(f"[DOM] {label} 输入框读取失败: {e}")


async def douyin_capture(page, captured: list) -> None:
    title_val = ""
    try:
        title_val = await page.get_by_placeholder("添加作品标题").input_value()
    except Exception as e:
        title_val = f"<读取失败: {e}>"
    editor_text = ""
    try:
        editor = page.locator(
            'div[data-zone-container="*"][contenteditable="true"]'
        ).first
        editor_text = (await editor.inner_text()) or ""
    except Exception as e:
        editor_text = f"<读取失败: {e}>"
    print(f"[DOM] 抖音标题输入框值: {title_val!r}")
    print(f"[DOM] 抖音描述编辑器文本: {editor_text!r}")
    await dump_form_inputs(page, "抖音")

    await install_capture(page, captured)
    btn = page.get_by_role("button", name="发布", exact=True)
    await btn.wait_for(state="visible", timeout=10000)
    print("[capture] 已拦截所有请求，点击发布按钮（请求全部 abort，不会真的发布）")
    await btn.click()
    await asyncio.sleep(8)


async def guanghe_capture(frame, main_page, captured: list) -> None:
    await dump_form_inputs(frame, "光合图文 iframe")
    title_val = ""
    try:
        title_val = (
            await frame.locator('input[placeholder*="标题"], input[maxlength="30"]')
            .first.input_value()
        )
    except Exception as e:
        title_val = f"<读取失败: {e}>"
    print(f"[DOM] 光合标题输入框值(选择器命中): {title_val!r}")

    await install_capture(main_page, captured)
    btn = frame.locator('.next-btn-primary:has-text("立即发布")').first
    await btn.wait_for(state="visible", timeout=15000)
    print("[capture] 已拦截所有请求，点击立即发布（请求全部 abort，不会真的发布）")
    await btn.click()
    await asyncio.sleep(8)


def dump_captured(captured: list, name: str) -> None:
    log_dir = Path(BASE_DIR) / "logs"
    log_dir.mkdir(parents=True, exist_ok=True)
    out = log_dir / f"publish_payload_{name}.json"
    out.write_text(json.dumps(captured, ensure_ascii=False, indent=2))
    print(f"\n[capture] 共捕获 {len(captured)} 个请求，已写入 {out}")
    for i, item in enumerate(captured):
        body = item.get("post_data") or ""
        print(f"--- 请求#{i} {item['method']} {item['url'][:140]}")
        if body:
            print(f"    body[:1200]: {body[:1200]}")


def run_douyin(args) -> None:
    import impl.douyin.platform as douyin_mod
    from impl.douyin.platform import DouyinPlatform

    captured: list = []

    async def fake_wait_for_manual_publish(page, platform_name):
        await douyin_capture(page, captured)
        raise RuntimeError("payload 已捕获，演练结束（未真正发布）")

    # 让流程走「人工验收」分支，但由脚本接管：拦截请求并代替点击
    douyin_mod.manual_review_enabled = lambda: True
    douyin_mod.wait_for_manual_publish = fake_wait_for_manual_publish

    platform = DouyinPlatform()
    try:
        asyncio.run(
            platform.publish_image(
                title=args.title,
                desc=args.desc,
                tags=list(args.tags),
                files=resolve_images(args.images),
                account_file=[args.cookie],
                music_name=args.music,
                ai_content="无需添加自主声明",
                dry_run=False,
            )
        )
    except RuntimeError as exc:
        print(f"[capture] {exc}")
    finally:
        dump_captured(captured, "douyin")


def run_guanghe(args) -> None:
    from impl.taobao_guanghe.platform import TaobaoGuanghePlatform

    captured: list = []

    async def fake_click_publish(frame, main_page=None):
        await guanghe_capture(frame, main_page or frame.page, captured)
        raise RuntimeError("payload 已捕获，演练结束（未真正发布）")

    TaobaoGuanghePlatform._click_publish = staticmethod(fake_click_publish)

    platform = TaobaoGuanghePlatform()
    try:
        platform.publish_image(
            title=args.title,
            desc=args.desc,
            tags=list(args.tags),
            files=resolve_images(args.images),
            account_file=[args.cookie],
            guanghe_claim="内容无需标注",
            dry_run=False,
        )
    except RuntimeError as exc:
        print(f"[capture] {exc}")
    finally:
        dump_captured(captured, "guanghe")


def main() -> None:
    args = parse_args()
    cookie = check_cookie(args.cookie)
    args.cookie = cookie
    if args.platform == "douyin":
        run_douyin(args)
    else:
        run_guanghe(args)


if __name__ == "__main__":
    main()
