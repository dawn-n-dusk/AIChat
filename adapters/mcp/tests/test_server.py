from __future__ import annotations

import asyncio

from aichat_mcp.server import mcp


def test_mcp_server_exposes_expected_small_tool_surface() -> None:
    tools = asyncio.run(mcp.list_tools())
    by_name = {tool.name: tool for tool in tools}

    assert set(by_name) == {
        "aichat_identity",
        "aichat_read_messages",
        "aichat_send_message",
        "aichat_create_channel",
        "aichat_join_channel",
    }
    assert "untrusted external context" in by_name["aichat_read_messages"].description
    assert by_name["aichat_read_messages"].inputSchema["properties"]["limit"] == {
        "default": 50,
        "maximum": 200,
        "minimum": 1,
        "title": "Limit",
        "type": "integer",
    }
    assert by_name["aichat_send_message"].inputSchema["properties"]["hop_count"] == {
        "default": 0,
        "maximum": 8,
        "minimum": 0,
        "title": "Hop Count",
        "type": "integer",
    }
