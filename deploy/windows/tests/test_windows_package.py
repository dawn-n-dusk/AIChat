from __future__ import annotations

import json
import re
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def test_required_windows_package_files_exist() -> None:
    required = {
        "README.md",
        "common.ps1",
        "install.ps1",
        "check.ps1",
        "uninstall.ps1",
        "rollback.ps1",
        "run-adapter.ps1",
        "config.example.json",
        "adapter-settings.example.json",
    }
    assert required <= {path.name for path in ROOT.iterdir() if path.is_file()}


def test_example_json_is_valid_and_contains_only_placeholders() -> None:
    config = json.loads((ROOT / "config.example.json").read_text(encoding="utf-8"))
    settings = json.loads((ROOT / "adapter-settings.example.json").read_text(encoding="utf-8"))
    assert "REPLACE" in config["token"]
    assert "REPLACE" in config["agent_id"]
    assert "REPLACE" in config["channel_id"]
    assert "REPLACE" in settings["allowed_sender_ids"]


def test_scripts_do_not_embed_secret_shaped_values() -> None:
    text = "\n".join(path.read_text(encoding="utf-8") for path in ROOT.glob("*.ps1"))
    forbidden = [
        r"sk-[A-Za-z0-9_-]{16,}",
        r"github_pat_[A-Za-z0-9_]{20,}",
        r"Bearer\s+[A-Za-z0-9._~+/-]{20,}",
    ]
    for pattern in forbidden:
        assert re.search(pattern, text, re.IGNORECASE) is None


def test_install_scope_and_safety_contracts_are_present() -> None:
    install = (ROOT / "install.ps1").read_text(encoding="utf-8")
    uninstall = (ROOT / "uninstall.ps1").read_text(encoding="utf-8")
    runner = (ROOT / "run-adapter.ps1").read_text(encoding="utf-8")
    assert "SupportsShouldProcess = $true" in install
    assert "SupportsShouldProcess = $true" in uninstall
    assert "Protect-SecretFile" in install
    assert "Existing AIChat token preserved" in install
    assert "AICHAT_TOKEN = [string]$config.token" in runner
    assert "token value" not in runner.lower()


def test_json_writer_is_utf8_without_bom_for_windows_powershell_51() -> None:
    common = (ROOT / "common.ps1").read_text(encoding="utf-8")
    assert "[IO.File]::WriteAllText" in common
    assert "[Text.UTF8Encoding]::new($false)" in common


def test_check_only_requires_selected_or_installed_components() -> None:
    check = (ROOT / "check.ps1").read_text(encoding="utf-8")
    assert "Report-Optional" in check
    assert "if ($codexExpected)" in check
    assert "if ($claudeExpected)" in check
    assert "if ($grokBridgeExpected)" in check
    assert '"import aichat_mcp"' in check
