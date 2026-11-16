"""发布操作浏览器可见性策略（按平台设置）。

settings 表键 `publishBrowserVisible`：JSON dict，键为平台 id（字符串），
值 True=显示窗口(headed)，False/缺省=隐藏(headless)。
「人工验收」(manualReview) 开启时强制有头：验收需要用户亲自在浏览器里
点击平台发布按钮，无头窗口无法完成，会一直等待。
"""

import logging

from ._manual_review import manual_review_enabled
from .settings import read_settings

logger = logging.getLogger(__name__)

_SETTINGS_KEY = "publishBrowserVisible"


def publish_headless(platform_id: int) -> bool:
    """发布操作是否使用无头浏览器（按平台设置；默认 True=隐藏）。"""
    try:
        if manual_review_enabled():
            return False  # 人工验收必须有头浏览器
    except Exception:
        pass
    try:
        cfg = read_settings().get(_SETTINGS_KEY)
        if isinstance(cfg, dict) and cfg.get(str(platform_id)) is True:
            return False
    except Exception as e:
        logger.warning("[浏览器可见性] 读取设置失败,按隐藏处理: %s", e)
    return True
