"""发布操作浏览器可见性策略（按平台设置）。

settings 表键 `publishBrowserVisible`：JSON dict，键为平台 id（字符串），
值 True=显示可见有头窗口，False/缺省=隐藏（有头窗口移出屏幕）。
「人工验收」(manualReview) 开启时强制显示可见窗口：验收需要用户亲自在
浏览器里点击平台发布按钮，离屏窗口无法完成，会一直等待。

隐藏模式不再使用真无头(headless=True)：无头指纹易被平台识别（实测抖音
图文提交被静默拒绝：点击发布后 60s 页面不跳转），且 headless 下
`--start-maximized` 失效、无 `--window-size`，配合 `no_viewport=True`
页面视口塌缩到 800×600（见 _browser.py `_HIDDEN_LAUNCH_ARGS` 注释）。
"""

import logging

from ._manual_review import manual_review_enabled
from .settings import read_settings

logger = logging.getLogger(__name__)

_SETTINGS_KEY = "publishBrowserVisible"

# 隐藏模式的哨兵值：create_browser 收到它时按「有头窗口移出屏幕」启动。
# 历史：publish_headless 曾返回 bool（True=真无头），29 处平台调用点以
# `headless=publish_headless(...)` 直传 create_browser，故保留函数名与
# 直传契约，仅把「隐藏」的返回值从 True 改为本哨兵。
PUBLISH_HIDDEN = "hidden"


def publish_headless(platform_id: int) -> bool | str:
    """发布浏览器可见性（按平台设置；默认隐藏）。

    返回 False = 显示可见有头窗口；返回 PUBLISH_HIDDEN("hidden") =
    有头窗口移出屏幕（对平台是真实浏览器指纹，对用户不可见）。
    """
    try:
        if manual_review_enabled():
            return False  # 人工验收必须有可见窗口
    except Exception:
        pass
    try:
        cfg = read_settings().get(_SETTINGS_KEY)
        if isinstance(cfg, dict) and cfg.get(str(platform_id)) is True:
            return False
    except Exception as e:
        logger.warning("[浏览器可见性] 读取设置失败,按隐藏处理: %s", e)
    return PUBLISH_HIDDEN
