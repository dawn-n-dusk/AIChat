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

    service_root = ROOT / "connector-service"
    service_required = {
        "README.md",
        "common.ps1",
        "launcher.ps1",
        "install.ps1",
        "check.ps1",
        "rollback.ps1",
        "recover-transaction.ps1",
        "uninstall.ps1",
        "config.example.json",
    }
    assert service_required <= {
        path.name for path in service_root.iterdir() if path.is_file()
    }


def test_example_json_is_valid_and_contains_only_placeholders() -> None:
    config = json.loads((ROOT / "config.example.json").read_text(encoding="utf-8"))
    settings = json.loads((ROOT / "adapter-settings.example.json").read_text(encoding="utf-8"))
    assert "REPLACE" in config["token"]
    assert "REPLACE" in config["agent_id"]
    assert "REPLACE" in config["channel_id"]
    assert "REPLACE" in settings["allowed_sender_ids"]

    connector = json.loads(
        (ROOT / "connector-service" / "config.example.json").read_text(
            encoding="utf-8"
        )
    )
    assert "REPLACE" in connector["expected_agent_id"]
    assert "REPLACE" in connector["channel_id"]
    assert isinstance(connector["allowed_sender_ids"], list)
    assert connector["allowed_sender_ids"]
    assert connector["sandbox_policy"] == {
        "type": "readOnly",
        "networkAccess": False,
    }
    assert connector["egress"] == {
        "enabled": False,
        "acknowledged_channel_id": "",
        "canary_path": "",
        "allowed_reference_hosts": [],
        "max_text_bytes": 8192,
    }
    assert connector["node_binary"].lower().endswith("node.exe")
    assert connector["npm_cli_path"].lower().endswith("npm-cli.js")
    assert connector["codex_app_server_binary"].lower().endswith("codex.exe")


def test_scripts_do_not_embed_secret_shaped_values() -> None:
    text = "\n".join(path.read_text(encoding="utf-8") for path in ROOT.rglob("*.ps1"))
    forbidden = [
        r"sk-[A-Za-z0-9_-]{16,}",
        r"github_pat_[A-Za-z0-9_]{20,}",
        r"Bearer\s+[A-Za-z0-9._~+/-]{20,}",
    ]
    for pattern in forbidden:
        assert re.search(pattern, text, re.IGNORECASE) is None


def test_install_scope_and_safety_contracts_are_present() -> None:
    install = (ROOT / "install.ps1").read_text(encoding="utf-8")
    common = (ROOT / "common.ps1").read_text(encoding="utf-8")
    uninstall = (ROOT / "uninstall.ps1").read_text(encoding="utf-8")
    runner = (ROOT / "run-adapter.ps1").read_text(encoding="utf-8")
    assert "SupportsShouldProcess = $true" in install
    assert "SupportsShouldProcess = $true" in uninstall
    assert "Protect-SecretFile" in install
    assert "Existing AIChat token preserved" in install
    assert "AICHAT_TOKEN = [string]$config.token" in runner
    assert "token value" not in runner.lower()
    assert '$ErrorActionPreference = "Continue"' in common
    assert "ExitCode = $exitCode" in common


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


def test_codex_plugin_mcp_is_explicitly_enabled_and_slow_start_safe() -> None:
    plugin_root = REPOSITORY_ROOT / "plugins" / "aichat"
    manifest = json.loads(
        (plugin_root / ".codex-plugin" / "plugin.json").read_text(encoding="utf-8")
    )
    config = json.loads((plugin_root / ".mcp.json").read_text(encoding="utf-8"))
    entry = config["mcpServers"]["aichat"]
    assert manifest["mcpServers"] == "./.mcp.json"
    assert entry["enabled"] is True
    assert entry["command"] == "uvx"
    assert entry["startup_timeout_sec"] >= 60
    assert entry["tool_timeout_sec"] == 30


def test_installer_refreshes_only_installer_owned_codex_plugin_state() -> None:
    install = (ROOT / "install.ps1").read_text(encoding="utf-8")
    assert '"plugin", "marketplace", "upgrade", "aichat-repo", "--json"' in install
    assert '"plugin", "add", "aichat@aichat-repo", "--json"' in install
    assert "elseif ($ownership.CodexMarketplaceAdded)" in install
    assert "elseif ($ownership.CodexPluginAdded)" in install
    assert "Existing user-managed Codex plugin" in install


def test_ci_runs_windows_powershell_51_plugin_mcp_functional_test() -> None:
    workflow = (REPOSITORY_ROOT / ".github" / "workflows" / "ci.yml").read_text(
        encoding="utf-8"
    )
    functional = ROOT / "tests" / "test_plugin_mcp_autoload.ps1"
    assert functional.is_file()
    assert "powershell.exe -NoProfile -ExecutionPolicy Bypass" in workflow
    assert "test_plugin_mcp_autoload.ps1" in workflow


def test_check_only_requires_selected_or_installed_components() -> None:
    check = (ROOT / "check.ps1").read_text(encoding="utf-8")
    assert "Report-Optional" in check
    assert "if ($codexExpected)" in check
    assert "if ($claudeExpected)" in check
    assert "if ($grokBridgeExpected)" in check
    assert '"import aichat_mcp"' in check
    assert '"codex-plugin-mcp"' in check
    assert '"mcp", "get", "aichat"' in check
    assert "startup_timeout_sec" in check


def test_connector_service_is_disabled_triggerless_and_current_user_only() -> None:
    root = ROOT / "connector-service"
    common = (root / "common.ps1").read_text(encoding="utf-8")
    install = (root / "install.ps1").read_text(encoding="utf-8")
    assert 'RegisterTask("CodexConnector", $xml, 14' in common
    assert "<Enabled>false</Enabled>" in common
    assert "<Triggers" not in common
    assert "<LogonType>InteractiveToken</LogonType>" in common
    assert "<RunLevel>LeastPrivilege</RunLevel>" in common
    assert "<MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>" in common
    assert "AllowStartOnDemand>true" in common
    assert "Assert-AIChatTaskContract -Task $existingTask" in install
    assert "Assert-AIChatTaskDisabledState -Task $Task" in common
    assert "[int]$Task.State -ne 1" in common
    assert "Assert-AIChatTaskSnapshotForMutation" in common
    assert "Connector Scheduled Task appeared before mutation" in common
    assert "Test-AIChatTaskSchedulerNotFoundException" in common
    assert "-2147024894" in common
    assert "-2147024891" in (ROOT / "tests" / "test_connector_service.ps1").read_text(
        encoding="utf-8"
    )
    assert "Connector Scheduled Task still exists after deletion" in "\n".join(
        path.read_text(encoding="utf-8") for path in root.glob("*.ps1")
    )
    assert "Start-ScheduledTask" not in "\n".join(
        path.read_text(encoding="utf-8") for path in root.glob("*.ps1")
    )


def test_connector_service_launcher_fixes_security_and_environment_contract() -> None:
    root = ROOT / "connector-service"
    launcher = (root / "launcher.ps1").read_text(encoding="utf-8")
    common = (root / "common.ps1").read_text(encoding="utf-8")
    checker = (root / "check.ps1").read_text(encoding="utf-8")
    required = {
        '["AICHAT_DELIVER_TYPES"]',
        '$settings.deliver_results',
        '["AICHAT_AUTONOMOUS_TEXT_ENABLED"] = "false"',
        '["AICHAT_WEBSOCKET_ENABLED"] = "true"',
        '["AICHAT_PERIODIC_RECOVERY_ENABLED"] = "false"',
        '["AICHAT_LIFECYCLE_STATUS_ENABLED"] = "false"',
        '["CODEX_DRIVER"] = "app-server"',
        '["CODEX_CONNECTOR_TASK_OWNED"] = "true"',
        '["CODEX_APP_SERVER_APPROVAL_POLICY"] = "never"',
        '["CODEX_DESKTOP_OWNER_IPC_ENABLED"] = "false"',
    }
    for value in required:
        assert value in launcher
    assert '["AICHAT_AUTO_REPLY_ENABLED"]' in launcher
    assert '["AICHAT_EGRESS_CHANNEL_AUDIENCE_ACK"] = "true"' in launcher
    assert '["AICHAT_EGRESS_CANARY_FILE"]' in launcher
    assert '["AICHAT_EGRESS_ALLOWED_REFERENCE_HOSTS"]' in launcher
    assert '["AICHAT_EGRESS_MAX_TEXT_BYTES"]' in launcher
    assert '$processInfo.EnvironmentVariables.Clear()' in launcher
    assert '"USERPROFILE"' not in launcher
    assert '"APPDATA"' not in launcher
    assert "expected_agent_id" in launcher
    assert "/v1/me" in common
    assert "diagnostic suppressed" in launcher
    assert "-RequirePinnedHashes" in launcher
    assert "Get-AIChatTreeHash" in launcher
    assert "ProcessStartInfo" in launcher
    assert "UseShellExecute = $false" in launcher
    assert "-CheckSettings *>&1" in checker
    assert "-CheckSettings 2>&1" not in checker
    assert '"[$label] ${Name}: $Detail"' in checker


def test_connector_service_launcher_has_supervised_durable_one_shot() -> None:
    launcher = (ROOT / "connector-service" / "launcher.ps1").read_text(encoding="utf-8")
    assert "[switch]$Once" in launcher
    assert "[string]$ExpectedMessageId" in launcher
    assert "Once requires an exact GUID ExpectedMessageId" in launcher
    assert '" --once"' in launcher
    assert '"CODEX_APP_SERVER_RECEIPT_DIR"' in launcher
    assert '$_.source_message_id -eq $ExpectedMessageId' in launcher
    assert '$_.sourceMessageId -eq $ExpectedMessageId' in launcher
    assert "$allConnectorReceipts.Count -ne 1" in launcher
    assert "$seenIds.Count -ne 1" in launcher
    assert "$outboundSeenIds.Count -ne 1" in launcher
    assert "$matchingDriverStates.Count -ne 1" in launcher
    assert "$allDriverRecords.Count -ne 1" in launcher
    assert '$driverRecords[0].completionStatus -ne "completed"' in launcher
    assert '[bool]$driverRecords[0].outboundBlocked' in launcher
    assert 'Supervised one-shot acceptance requires a fresh connector state' in launcher
    assert 'Supervised one-shot acceptance requires a fresh app-server receipt' in launcher
    assert 'Assert-AIChatSupervisedResultEgressCheckpoint' in launcher
    assert 'Write-Host "connector_receipt_persisted=true"' in launcher
    assert 'Write-Host "driver_receipt_persisted=true"' in launcher
    assert 'Write-Host "relay_result_checkpointed=$(' in launcher
    assert 'Write-Host "durable_checkpoint_ready=true"' in launcher


def test_supervised_result_egress_checkpoint_is_exactly_bound() -> None:
    common = (ROOT / "connector-service" / "common.ps1").read_text(encoding="utf-8")
    assert 'function Assert-AIChatSupervisedResultEgressCheckpoint' in common
    assert '$DriverRecord.outboundEvent.modelDeclared' in common
    assert '$DriverRecord.outboundEvent.messageType -ne "result"' in common
    assert '$DriverRecord.outboundEvent.eventId -ne' in common
    assert '$ConnectorReceipt.outbound_event_id' in common
    assert '[Guid]::TryParseExact(' in common
    assert '$ConnectorReceipt.outbound_message_id' in common


def test_connector_service_result_egress_is_explicit_and_fail_closed() -> None:
    root = ROOT / "connector-service"
    common = (root / "common.ps1").read_text(encoding="utf-8")
    launcher = (root / "launcher.ps1").read_text(encoding="utf-8")
    example = json.loads((root / "config.example.json").read_text(encoding="utf-8"))
    assert example["egress"]["enabled"] is False
    assert example["deliver_results"] is False
    assert "egress.acknowledged_channel_id must exactly match channel_id" in common
    assert "Assert-AIChatPrivateFile -Path $canaryPath" in common
    assert "exact public DNS hostnames" in common
    assert "egress.max_text_bytes must be from 128 through 100000" in common
    assert '$settings.deliver_results' in launcher
    assert '"deliver_results"' in common
    assert 'Name "deliver_results"' in common
    assert 'AICHAT_LIFECYCLE_STATUS_ENABLED"] = "false"' in launcher
    assert "AICHAT_EGRESS_CHANNEL_AUDIENCE_ACK" in launcher


def test_connector_service_private_path_and_hardlink_contracts_are_fail_closed() -> None:
    common = (ROOT / "connector-service" / "common.ps1").read_text(encoding="utf-8")
    assert "FILE_FLAG_OPEN_REPARSE_POINT" in common
    assert "GetFileInformationByHandle" in common
    assert "NumberOfLinks" in common
    assert "Get-AIChatHardLinkCount" in common
    assert "AreAccessRulesProtected" in common
    assert "GetAccessRules(" in common
    assert "must not contain reparse points" in common
    assert "UNC paths are not allowed" in common
    assert 'Get-AIChatConnectorDataRoot' in common
    assert '"state.json"' in common
    assert "Assert-AIChatConnectorDataTree" in common
    assert "Assert-AIChatConnectorDataFile" in common
    assert "Read-AIChatConnectorDataJson" in common
    assert "Initialize-AIChatConnectorDataDirectory" in common
    assert "Set-AIChatConnectorDataAcl" in common
    assert 'S-1-5-18' in common
    assert "ACL contains an untrusted or missing principal" in common
    assert "ACL inheritance is not protected" in common
    assert "SetNamedSecurityInfo" in common
    assert "OWNER_SECURITY_INFORMATION" in common
    assert "DACL_SECURITY_INFORMATION" in common
    assert "PROTECTED_DACL_SECURITY_INFORMATION" in common
    assert "SACL_SECURITY_INFORMATION" not in common
    assert "Set-Acl -LiteralPath $Path" not in common
    assert "accept only the fixed private ACL contracts" in common


def test_connector_atomic_windows_writes_protect_acl_before_rename() -> None:
    source = (ROOT.parent.parent / "adapters" / "codex-connector" / "src" / "atomic-file.js").read_text(
        encoding="utf-8"
    )
    launcher = (ROOT / "connector-service" / "launcher.ps1").read_text(encoding="utf-8")
    protect_at = source.index("await protectWindowsPrivateFile(temporary)")
    rename_at = source.index("await rename(temporary, path)")
    assert protect_at < rename_at
    assert '"icacls.exe"' in source
    assert '"/setowner"' in source
    assert '"/inheritance:r"' in source
    assert '"/grant:r"' in source
    assert "WINDOWS_SYSTEM_SID" in source
    assert '["AICHAT_WINDOWS_PRIVATE_SID"] = Get-AIChatCurrentSid' in launcher
    assert "Read-AIChatConnectorDataJson -Path $connectorStatePath" in launcher
    assert "-ProtectedRoot $paths.ConnectorDataRoot" not in launcher


def test_connector_service_state_namespace_is_mapping_scoped_and_legacy_safe() -> None:
    root = ROOT / "connector-service"
    common = (root / "common.ps1").read_text(encoding="utf-8")
    install = (root / "install.ps1").read_text(encoding="utf-8")
    launcher = (root / "launcher.ps1").read_text(encoding="utf-8")
    assert "function Get-AIChatConnectorMappingDigest" in common
    assert '"aichat-windows-mapping-v1`0app-server`0local-agent`0"' in common
    assert "[string]$Settings.expected_agent_id" in common
    assert '"state-$digest.json"' in common
    assert 'state_basename = "state.json"' not in common
    assert '$stateBasename = "state.json"' in common
    assert 'MappingStatePath = Join-Path $state "mapping-state.json"' in common
    assert 'mapping_state = $Paths.MappingStatePath' in common
    assert "$schemaVersion -eq 1" in common
    assert "$aclOnlyV2" in common
    assert "$mappingOnlyV2" in common
    assert "$integratedV3" in common
    assert 'Remove-Item -LiteralPath $Paths.MappingStatePath -Force' in common
    assert "PreviousSettings" in install
    assert "PreviousMappingState" in install
    assert 'Write-Host "mapping_state_mode=$(' in install
    assert 'EnvironmentVariables["AICHAT_STATE_FILE"] = $connectorStatePath' in launcher
    assert 'EnvironmentVariables["AICHAT_INSTANCE_LOCK_METADATA_PATH"]' not in launcher
    assert 'CODEX_APP_SERVER_RECEIPT_DIR"] = $paths.ConnectorDataRoot' in launcher


def test_connector_service_whatif_returns_before_mutating_capabilities() -> None:
    install = (ROOT / "connector-service" / "install.ps1").read_text(encoding="utf-8")
    early_return = install.index("if (-not $Apply -or $WhatIfPreference)")
    dot_source = install.index('. (Join-Path $PSScriptRoot "common.ps1")')
    assert early_return < dot_source
    plan_prefix = install[:early_return]
    for forbidden in ("Test-Path", "Resolve-Path", "Get-Item", "Get-ChildItem"):
        assert forbidden not in plan_prefix
    assert 'Write-Host "mutation_performed=false"' in install[early_return:dot_source]
    assert 'Write-Host "mapping_state_selection=deferred_until_apply"' in install[early_return:dot_source]
    assert 'Write-Host "legacy_connector_state_mutated=false"' in install[early_return:dot_source]
    prefix = install[:dot_source]
    for forbidden in (
        "Set-Acl",
        "Add-Type",
        "RegisterTask",
        "Invoke-RestMethod",
        "New-Object -ComObject",
        "Start-Process",
    ):
        assert forbidden not in prefix


def test_connector_service_journal_uses_fixed_ids_hashes_and_inverse_rollback() -> None:
    root = ROOT / "connector-service"
    common = (root / "common.ps1").read_text(encoding="utf-8")
    install = (root / "install.ps1").read_text(encoding="utf-8")
    rollback = (root / "rollback.ps1").read_text(encoding="utf-8")
    assert 'schema_version = 3' in install
    assert 'kind = "aichat-windows-connector-transaction"' in install
    assert 'status = "prepared"' in install
    assert 'Set-AIChatTransactionStatus -Status "applying"' in install
    assert 'Set-AIChatTransactionStatus -Status "applied"' in install
    assert 'Set-AIChatTransactionStatus -Status "committed"' in install
    journal_write = install.index("-Path $paths.TransactionPath")
    data_acl_migration = install.index(
        "Initialize-AIChatConnectorDataDirectory -Path $paths.ConnectorDataRoot"
    )
    assert journal_write < data_acl_migration
    assert 'Invoke-AIChatInstallFailurePoint -Name "after-connector-data-acl"' in install
    assert "Get-AIChatConnectorDataAclSnapshot" in install
    assert "connector_data_acl = $connectorDataAclSnapshot" in install
    assert "Restore-AIChatConnectorDataAclSnapshot" in common
    assert "-RestoreConnectorDataAcl" in install
    assert "UNPROTECTED_DACL_SECURITY_INFORMATION" in common
    assert "Get-AIChatDeploymentTargets" in common
    assert 'common = $Paths.CommonPath' in common
    assert 'active_release = $Paths.ActiveReleasePath' in common
    assert 'mapping_state = $Paths.MappingStatePath' in common
    assert "Get-FileHash" in common
    assert "Assert-AIChatTransactionManifest" in rollback
    assert "Invoke-AIChatManifestRollback" in rollback
    assert "Restore-AIChatTaskSnapshot" in common
    assert 'Write-Host "mapping_state_rollback=deferred_until_apply"' in rollback
    assert 'Write-Host "connector_data_mutated=false"' in rollback


def test_connector_service_incomplete_rollback_recovery_is_read_only_and_exact() -> None:
    root = ROOT / "connector-service"
    common = (root / "common.ps1").read_text(encoding="utf-8")
    recovery = (root / "recover-transaction.ps1").read_text(encoding="utf-8")
    assert "Assert-AIChatManifestRollbackComplete" in common
    assert "Assert-AIChatConnectorDataAclMatchesSnapshot" in common
    assert 'AllowedStatuses @("rollback_incomplete")' in common
    assert "requires an integrated schema-v3 journal" in common
    assert "Assert-AIChatTaskSnapshotForMutation" in common
    assert "Rollback target content does not match" in common
    assert "Failed transaction staging directory still exists" in common
    assert "Failed transaction release is still present" in common
    assert "rollback-incomplete.finalized.json" in recovery
    assert "byte-identical to the live journal" in recovery
    assert recovery.count("Assert-AIChatManifestRollbackComplete") == 2
    assert recovery.index("Copy-AIChatPrivateFileAtomic") < recovery.rindex(
        "Assert-AIChatManifestRollbackComplete"
    ) < recovery.index("Remove-Item -LiteralPath $paths.TransactionPath")
    for forbidden in (
        "RegisterTask(",
        "DeleteTask(",
        "Register-AIChatDisabledTask",
        "Restore-AIChatTaskSnapshot",
        "Start-ScheduledTask",
    ):
        assert forbidden not in recovery
    assert 'Write-Host "task_write_attempted=false"' in recovery
    assert 'Write-Host "connector_state_mutated=false"' in recovery
    restore = common[common.index("function Restore-AIChatTaskSnapshot") :]
    assert restore.index("$null -ne $current") < restore.index(
        'New-Object -ComObject "Schedule.Service"'
    )


def test_connector_service_pins_native_node_npm_and_codex_without_path_shim() -> None:
    root = ROOT / "connector-service"
    common = (root / "common.ps1").read_text(encoding="utf-8")
    install = (root / "install.ps1").read_text(encoding="utf-8")
    assert "must be a native .exe because the connector uses shell=false" in common
    assert "must be a native PE executable" in common
    assert "npm_cli_path must remain inside the pinned Node.js installation" in common
    assert "node_sha256" in common
    assert "npm_cli_sha256" in common
    assert "codex_sha256" in common
    assert common.index("$nodeHash =") < common.index("$nodeVersion =")
    assert common.index("$codexHash =") < common.index("$codexVersion =")
    assert common.index('throw "node_binary hash does not match') < common.index(
        "$nodeVersion ="
    )
    assert common.index('throw "codex_app_server_binary hash does not match') < common.index(
        "$codexVersion ="
    )
    assert "Get-Command \"npm.cmd\"" not in install
    assert "& $settings.node_binary $settings.npm_cli_path ci" in install


def test_online_identity_check_validates_transport_before_authorization() -> None:
    root = ROOT / "connector-service"
    common = (root / "common.ps1").read_text(encoding="utf-8")
    checker = (root / "check.ps1").read_text(encoding="utf-8")
    launcher = (root / "launcher.ps1").read_text(encoding="utf-8")
    validator = common.index("function Get-AIChatValidatedServer")
    authorized_get = common.index("Invoke-RestMethod", validator)
    https_gate = common.index("must use HTTPS outside loopback", validator)
    assert https_gate < authorized_get
    assert "-MaximumRedirection 0" in common[authorized_get : authorized_get + 500]
    assert "Test-AIChatRelayIdentity" in checker
    assert "Invoke-RestMethod" not in checker
    assert "Test-AIChatRelayIdentity" in launcher
    assert "Invoke-RestMethod" not in launcher


def test_ci_runs_windows_connector_service_functional_test() -> None:
    functional = ROOT / "tests" / "test_connector_service.ps1"
    legacy = ROOT / "tests" / "test_legacy_codex_runner_disabled.ps1"
    wrapper = ROOT / "tests" / "test_plugin_mcp_autoload.ps1"
    assert functional.is_file()
    assert legacy.is_file()
    functional_text = functional.read_text(encoding="utf-8")
    assert "*>&1 | Out-String" in functional_text
    assert "2>&1 | Out-String" not in functional_text
    check_failure = functional_text.index("if ($LASTEXITCODE -ne 0) {", functional_text.index("$checkOutput ="))
    check_diagnostic = functional_text.index(
        "Connector service check failed after first install; failed_checks=$failedCheckSummary",
        check_failure,
    )
    assert functional_text.index("$checkOutput.Contains($token)", check_failure) < check_diagnostic
    assert "after first install:`n$checkOutput" not in functional_text
    assert "allowedFailedChecks" in functional_text[check_failure:check_diagnostic]
    assert "[string]$Matches[1]" in functional_text[check_failure:check_diagnostic]
    created_codex_home = functional_text.index("if ($createdCodexHome) {")
    set_codex_owner = functional_text.index("$codexHomeAcl.SetOwner(", created_codex_home)
    assert set_codex_owner < functional_text.index("Set-Acl -LiteralPath $codexHome", set_codex_owner)
    wrapper_text = wrapper.read_text(encoding="utf-8")
    assert "test_connector_service.ps1" in wrapper_text
    assert "test_legacy_codex_runner_disabled.ps1" in wrapper_text
    assert "$protectedRootExisted = Test-Path" in wrapper_text
    assert "test-created AIChat root because it is no longer empty" in wrapper_text
    assert wrapper_text.index("Remove-Item -LiteralPath $protectedRoot -Force") < wrapper_text.index(
        "$connectorServiceTest ="
    )


def test_legacy_codex_runner_fails_before_config_or_process_access() -> None:
    runner = (ROOT / "run-adapter.ps1").read_text(encoding="utf-8")
    guard = runner.index('if ($Mode -eq "CodexConnector")')
    assert guard < runner.index('. (Join-Path $PSScriptRoot "common.ps1")')
    assert guard < runner.index("Read-JsonObject")
    assert guard < runner.index("$env:AICHAT_TOKEN")
    assert '"CodexConnector" {' not in runner
    assert "Legacy CodexConnector runner is disabled" in runner
