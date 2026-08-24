from __future__ import annotations

import json
import re
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
REPOSITORY_ROOT = ROOT.parents[1]


def test_required_windows_package_files_exist() -> None:
    required = {
        "README.md",
        "common.ps1",
        "install.ps1",
        "import-bootstrap.ps1",
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
    assert "Write-SecretJsonAtomic" in common
    assert "[IO.File]::Replace" in common
    assert "$stream.Flush($true)" in common


def test_bootstrap_import_has_no_secret_argument_or_secret_output() -> None:
    script = (ROOT / "import-bootstrap.ps1").read_text(encoding="utf-8")
    assert "[Parameter(Mandatory = $true)][string]$BootstrapPath" in script
    assert "[string]$Token" not in script
    assert "[IO.FileStream]::new(" in script
    assert "[IO.FileShare]::None" in script
    assert "Write-SecretJsonAtomic -Path $paths.ConfigPath -Value $config -ProtectedRoot $protectedRoot" in script
    assert "Remove-Item -LiteralPath $artifactPath -Force" in script
    assert "token_present=true" in script
    assert re.search(r"Write-(?:Host|Output|Error)[^\n]*\$token", script, re.IGNORECASE) is None


def test_bootstrap_import_restricts_acl_before_read_and_preserves_other_config() -> None:
    script = (ROOT / "import-bootstrap.ps1").read_text(encoding="utf-8")
    protect_at = script.index("Protect-SecretFile -Path $artifactPath")
    read_at = script.index("$artifactStream = [IO.FileStream]::new(")
    assert protect_at < read_at
    assert "[IO.FileAttributes]::ReparsePoint" in script
    assert "Assert-AIChatPathWithinProtectedRoot" in script
    assert 'Join-Path $protectedRoot "bootstrap"' in script
    assert "$config = Read-JsonObject -Path $paths.ConfigPath" in script
    for field in ("server", "agent_id", "agent_name", "token"):
        assert f'Set-ObjectProperty -Object $config -Name "{field}"' in script


def test_secret_file_acl_is_replaced_with_current_sid_only() -> None:
    common = (ROOT / "common.ps1").read_text(encoding="utf-8")
    assert "[Security.Principal.WindowsIdentity]::GetCurrent()" in common
    assert "[Security.AccessControl.DirectorySecurity]::new()" in common
    assert "$security.SetAccessRuleProtection($true, $false)" in common
    assert "[Security.AccessControl.FileSystemRights]::FullControl" in common
    assert "Set-Acl -LiteralPath $Path -AclObject $security" in common
    assert "[IO.File]::Replace($temporary, $Path, $replacementBackup)" in common
    assert "Restricted secret residue may remain" in common
    assert "if ($rules.Count -ne 1)" in common
    assert "$ruleSid -ne $identity.User.Value" in common


def test_secret_paths_are_limited_to_non_reparse_localappdata_root() -> None:
    common = (ROOT / "common.ps1").read_text(encoding="utf-8")
    importer = (ROOT / "import-bootstrap.ps1").read_text(encoding="utf-8")
    assert "function Get-AIChatProtectedRoot" in common
    assert "function Assert-AIChatPathWithinProtectedRoot" in common
    assert "Secret path must remain below" in common
    assert "Protected secret paths must not contain reparse points" in common
    assert "$segments = @(if ($relative)" in common
    assert "same-SID process or administrator remains inside" in importer


def test_ci_runs_windows_powershell_51_bootstrap_functional_test() -> None:
    workflow = (REPOSITORY_ROOT / ".github" / "workflows" / "ci.yml").read_text(
        encoding="utf-8"
    )
    functional = ROOT / "tests" / "test_import_bootstrap.ps1"
    assert functional.is_file()
    assert "windows-bootstrap:" in workflow
    assert "runs-on: windows-latest" in workflow
    assert "powershell.exe -NoProfile -ExecutionPolicy Bypass" in workflow
    assert "test_import_bootstrap.ps1" in workflow


def test_check_only_requires_selected_or_installed_components() -> None:
    check = (ROOT / "check.ps1").read_text(encoding="utf-8")
    assert "Report-Optional" in check
    assert "if ($codexExpected)" in check
    assert "if ($claudeExpected)" in check
    assert "if ($grokBridgeExpected)" in check
    assert '"import aichat_mcp"' in check
