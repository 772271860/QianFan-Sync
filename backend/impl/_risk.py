"""平台风控 / 人机校验识别。

目标：发布被平台拦截时，把「风控」和「元素没找到」区分开，并留下现场证据。

只做只读检测，不改页面状态；检测本身抛的任何异常都吞掉，不能影响发布。

用法::

    from impl._risk import guard, RiskControlError

    await guard(page, "小红书")   # 命中即截图 + raise RiskControlError
"""

from __future__ import annotations

from datetime import datetime
from pathlib import Path

from conf import BASE_DIR
from util._logger import get_channel_logger

logger = get_channel_logger("risk")

# 验证码 / 安全校验容器（选择器大小写不敏感）
_RISK_SELECTORS = (
    '[class*="captcha" i]',
    '[id*="captcha" i]',
    'iframe[src*="captcha" i]',
    'iframe[src*="verify" i]',
    ".secsdk-captcha-drag-wrapper",
    "#captcha_container",
    '[class*="slide-verify"]',
    '[class*="slider-verify"]',
    '[class*="sec-verify"]',
)

# 限流 / 异常提示文案
_RISK_TEXTS = (
    "请完成安全验证",
    "完成安全验证",
    "拖动滑块",
    "滑动验证",
    "操作过于频繁",
    "操作太频繁",
    "请求过于频繁",
    "访问过于频繁",
    "账号存在异常",
    "账号异常",
    "发布次数已达上限",
    "今日发布已达上限",
    "超过今日发布",
    "内容存在风险",
)

_TEXT_SCAN_LIMIT = 20000


class RiskControlError(RuntimeError):
    """平台风控 / 人机校验拦截。

    调用方应中止该账号的后续动作，不要当普通失败重试。
    """

    def __init__(self, platform: str, detail: str):
        super().__init__(f"{platform}触发平台风控：{detail}")
        self.platform = platform
        self.detail = detail


async def detect_risk(target) -> str | None:
    """检测 Page/Frame 上的风控信号，命中返回描述，否则 None。"""
    try:
        for sel in _RISK_SELECTORS:
            try:
                loc = target.locator(sel)
                if not await loc.count():
                    continue
                if await loc.first.is_visible():
                    return f"页面出现验证码容器 {sel}"
            except Exception:
                continue

        try:
            text = await target.evaluate(
                "(limit) => (document.body ? document.body.innerText : '').slice(0, limit)",
                _TEXT_SCAN_LIMIT,
            )
        except Exception:
            return None
        for marker in _RISK_TEXTS:
            if marker in (text or ""):
                return f"页面提示「{marker}」"
    except Exception as e:
        logger.info("[风控] 检测异常（忽略）: %s", e)
    return None


async def capture(page, platform: str) -> str:
    """截图留证到 data/logs/risk/，返回路径（失败返回空串）。"""
    try:
        out_dir = Path(BASE_DIR) / "logs" / "risk"
        out_dir.mkdir(parents=True, exist_ok=True)
        path = out_dir / f"{platform}_{datetime.now():%Y%m%d_%H%M%S}.png"
        await page.screenshot(path=str(path), full_page=True)
        return str(path)
    except Exception as e:
        logger.info("[风控] 截图失败: %s", e)
        return ""


async def guard(page, platform: str) -> None:
    """检测到风控就截图并抛 RiskControlError；未命中则静默返回。"""
    hit = await detect_risk(page)
    if not hit:
        return
    shot = await capture(page, platform)
    logger.warning("[风控] %s 命中: %s（截图: %s）", platform, hit, shot or "无")
    raise RiskControlError(platform, hit + (f"，截图 {shot}" if shot else ""))
