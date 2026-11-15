"""图文发布演练脚本（淘宝光合 / 视频号 / 抖音），跨机器可直接复用。

所有路径都来自 ``conf.BASE_DIR`` 或命令行参数，脚本里没有任何本机绝对路径。
默认只做「填完表单不提交」的演练，方便人工核对（重点看话题标签有没有变成芯片）；
加 ``--publish`` 才会真的点发布。

用法::

    python backend/tests/dryrun_image_publish.py \
        --platform channels \
        --cookie 459a8224-xxxx.json \
        --images data/materials/2026/11/15/a.jpeg data/materials/2026/11/15/b.jpeg \
        --title "测试标题" --desc "测试描述" --tags 好物分享 测试

    --platform both   依次演练淘宝光合和视频号（各开一个窗口）

浏览器后端跟随环境变量 ``BROWSER_BACKEND``（默认 cloakbrowser）；
本机没装 cloakbrowser 时加 ``BROWSER_BACKEND=patchright`` 即可。
"""

from __future__ import annotations

import argparse
import asyncio
import os
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from conf import BASE_DIR  # noqa: E402


def parse_args():
    ap = argparse.ArgumentParser(description="图文发布演练（不提交）")
    ap.add_argument(
        "--platform", choices=["guanghe", "channels", "douyin", "both"], default="channels"
    )
    ap.add_argument("--cookie", required=True, help="cookiesFile 下的 cookie 文件名")
    ap.add_argument(
        "--images", nargs="+", required=True, help="图片路径（相对路径按当前目录解析）"
    )
    ap.add_argument("--title", default="图文自动化演练")
    ap.add_argument("--desc", default="这是自动化演练内容，请忽略。")
    ap.add_argument("--tags", nargs="*", default=["好物分享", "测试"])
    ap.add_argument("--claim", default="内容无需标注", help="淘宝光合创作者声明")
    ap.add_argument("--music", default="", help="抖音：指定音乐名，空=自动选推荐")
    ap.add_argument("--hotspot", default="", help="抖音：热点词")
    ap.add_argument(
        "--hold",
        type=int,
        default=0,
        help="淘宝光合填完后保持窗口的秒数，0=等人工关闭",
    )
    ap.add_argument(
        "--publish",
        action="store_true",
        help="真的点发布（默认只填表不提交，会抛「未实际发布」）",
    )
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


def build_platform(name: str):
    if name == "guanghe":
        from impl.taobao_guanghe.platform import TaobaoGuanghePlatform

        return TaobaoGuanghePlatform()
    if name == "douyin":
        from impl.douyin.platform import DouyinPlatform

        return DouyinPlatform()
    from impl.channels.platform import ChannelsPlatform

    return ChannelsPlatform()


def run_platform(name: str, args, cookie: str, images: list[str]) -> None:
    platform = build_platform(name)
    kwargs = dict(
        title=args.title,
        desc=args.desc,
        tags=list(args.tags),
        files=images,
        account_file=[cookie],
        dry_run=not args.publish,
    )
    if name == "guanghe":
        kwargs["guanghe_claim"] = args.claim
    if name == "douyin":
        kwargs["music_name"] = args.music
        kwargs["hotspot"] = args.hotspot
        kwargs["ai_content"] = "无需添加自主声明"
    print(f"\n===== 演练平台: {name} =====", flush=True)
    try:
        result = platform.publish_image(**kwargs)
        if asyncio.iscoroutine(result):
            asyncio.run(result)
    except RuntimeError as exc:
        # 演练结束会主动抛出「未实际发布」，属预期
        print(f"[dryrun] {name} 演练结束: {exc}", flush=True)


def main() -> None:
    args = parse_args()
    images = resolve_images(args.images)
    cookie = check_cookie(args.cookie)
    names = ["guanghe", "channels"] if args.platform == "both" else [args.platform]

    if args.hold > 0:
        os.environ["GUANGHE_DRY_RUN_HOLD_MS"] = str(args.hold * 1000)
        os.environ["DOUYIN_DRY_RUN_HOLD_SECONDS"] = str(args.hold)

    for name in names:
        run_platform(name, args, cookie, images)

    print("\n[dryrun] 演练完成，请人工核对窗口，之后自行关闭", flush=True)


if __name__ == "__main__":
    main()
