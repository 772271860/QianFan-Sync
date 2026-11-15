"""抖音图集话题合并单元测试:标签 + 描述 #xxx + 官方活动 → 统一话题列表。

只测纯函数 ``DouyinPlatform._collect_topics``,不触发浏览器流程。
"""
import sys
from pathlib import Path

# 把 backend 目录加进 sys.path（与项目其他测试一致）
sys.path.insert(0, str(Path(__file__).parent.parent.parent))

from impl.douyin.platform import DouyinPlatform  # noqa: E402


def test_collect_from_tags_only():
    desc, topics = DouyinPlatform._collect_topics("描述正文", ["毛衣", "冬季"], [])
    assert desc == "描述正文"
    assert topics == ["毛衣", "冬季"]


def test_collect_moves_desc_hashtags_to_topics():
    desc, topics = DouyinPlatform._collect_topics("好看 #毛衣 很暖", ["冬季"], [])
    assert desc == "好看 很暖"
    assert topics == ["冬季", "毛衣"]


def test_collect_includes_activities():
    desc, topics = DouyinPlatform._collect_topics("正文", ["标签"], ["官方活动"])
    assert desc == "正文"
    assert topics == ["标签", "官方活动"]


def test_collect_dedupes_and_strips_hash_prefix():
    desc, topics = DouyinPlatform._collect_topics(
        "#毛衣 好看 #冬季", ["#毛衣", "冬季"], ["毛衣"]
    )
    assert desc == "好看"
    assert topics == ["毛衣", "冬季"]


def test_collect_caps_at_five_topics():
    desc, topics = DouyinPlatform._collect_topics(
        "#a #b #c", ["d", "e"], ["f"]
    )
    assert len(topics) == 5
    assert topics == ["d", "e", "a", "b", "c"]


def test_collect_ignores_inline_and_url_hashes():
    desc, topics = DouyinPlatform._collect_topics(
        "文案 a#b http://example.com#section", [], []
    )
    assert desc == "文案 a#b http://example.com#section"
    assert topics == []


def test_collect_empty_inputs():
    desc, topics = DouyinPlatform._collect_topics("", [], [])
    assert desc == ""
    assert topics == []
