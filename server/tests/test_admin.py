from __future__ import annotations

import hashlib
import json
import os
import sqlite3
import stat
import subprocess
import sys
from pathlib import Path

import pytest

from app import admin
from app.database import initialize


def create_database(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> Path:
    database = tmp_path / "relay.db"
    monkeypatch.setenv("AICHAT_DB_PATH", str(database))
    initialize()
    return database


def seed_agent(database: Path) -> tuple[str, str, str]:
    agent_id = "windows-codex-agent"
    old_token = "synthetic-old-token-for-admin-test"
    channel_id = "shared-project-channel"
    with sqlite3.connect(database) as connection:
        connection.execute(
            """INSERT INTO agents
               (id, name, owner, capabilities, token_hash, created_at)
               VALUES (?, ?, ?, ?, ?, ?)""",
            (
                agent_id,
                "Windows Codex",
                "test-owner",
                json.dumps(["code", "windows"]),
                hashlib.sha256(old_token.encode()).hexdigest(),
                "2026-08-24T00:00:00.000Z",
            ),
        )
        connection.execute(
            "INSERT INTO channels (id, name, description, created_by, created_at) VALUES (?, ?, ?, ?, ?)",
            (channel_id, "Project", None, agent_id, "2026-08-24T00:00:00.000Z"),
        )
        connection.execute(
            "INSERT INTO channel_members (channel_id, agent_id, joined_at) VALUES (?, ?, ?)",
            (channel_id, agent_id, "2026-08-24T00:00:00.000Z"),
        )
    return agent_id, old_token, channel_id


def run_admin(*arguments: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [sys.executable, "-m", "app.admin", *arguments],
        cwd=Path(__file__).resolve().parents[1],
        check=False,
        text=True,
        capture_output=True,
    )


def base_arguments(database: Path, agent_id: str, output: Path) -> list[str]:
    return [
        "--database",
        str(database),
        "--agent-id",
        agent_id,
        "--output",
        str(output),
        "--server",
        "https://relay.example.test/aichat/",
        "--confirm-relay-stopped",
    ]


def agent_state(database: Path, agent_id: str) -> tuple:
    with sqlite3.connect(database) as connection:
        return connection.execute(
            "SELECT name, owner, capabilities, token_hash, created_at FROM agents WHERE id = ?",
            (agent_id,),
        ).fetchone()


def test_rotate_preserves_agent_membership_and_writes_secret_only_to_artifact(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    database = create_database(tmp_path, monkeypatch)
    agent_id, old_token, channel_id = seed_agent(database)
    before = agent_state(database, agent_id)
    output = tmp_path / "windows-bootstrap.json"

    result = run_admin(*base_arguments(database, agent_id, output))

    assert result.returncode == 0, result.stderr
    summary = json.loads(result.stdout)
    artifact = json.loads(output.read_text(encoding="utf-8"))
    after = agent_state(database, agent_id)
    assert summary == {
        "action": "rotated",
        "agent_id": agent_id,
        "artifact_path": str(output),
        "membership_count": 1,
        "token_written": True,
    }
    assert artifact["kind"] == "aichat-agent-bootstrap"
    assert artifact["schema_version"] == 1
    assert artifact["server"] == "https://relay.example.test/aichat"
    assert artifact["agent_id"] == agent_id
    assert artifact["agent_name"] == "Windows Codex"
    assert artifact["token"] not in result.stdout
    assert artifact["token"] not in result.stderr
    assert old_token not in result.stdout + result.stderr
    assert hashlib.sha256(artifact["token"].encode()).hexdigest() == after[3]
    assert before[:3] + before[4:] == after[:3] + after[4:]
    assert before[3] != after[3]
    assert stat.S_IMODE(output.stat().st_mode) == 0o600
    with sqlite3.connect(database) as connection:
        memberships = connection.execute(
            "SELECT channel_id FROM channel_members WHERE agent_id = ?", (agent_id,)
        ).fetchall()
    assert memberships == [(channel_id,)]


def test_missing_agent_fails_closed_without_artifact(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    database = create_database(tmp_path, monkeypatch)
    output = tmp_path / "missing.json"
    result = run_admin(*base_arguments(database, "missing-agent", output))
    assert result.returncode == 2
    assert "fail-closed" in result.stderr
    assert not output.exists()


def test_rotation_requires_explicit_offline_confirmation(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    database = create_database(tmp_path, monkeypatch)
    agent_id, _, _ = seed_agent(database)
    output = tmp_path / "offline-required.json"
    arguments = base_arguments(database, agent_id, output)
    arguments.remove("--confirm-relay-stopped")

    result = run_admin(*arguments)

    assert result.returncode == 2
    assert "--confirm-relay-stopped" in result.stderr
    assert not output.exists()


@pytest.mark.parametrize("target_kind", ["file", "symlink"])
def test_existing_or_symlink_artifact_is_never_replaced(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch, target_kind: str
) -> None:
    database = create_database(tmp_path, monkeypatch)
    agent_id, _, _ = seed_agent(database)
    before = agent_state(database, agent_id)
    protected = tmp_path / "protected.txt"
    protected.write_text("keep", encoding="utf-8")
    output = tmp_path / "bootstrap.json"
    if target_kind == "file":
        output.write_text("existing", encoding="utf-8")
    else:
        output.symlink_to(protected)

    result = run_admin(*base_arguments(database, agent_id, output))

    assert result.returncode == 2
    assert "refusing to overwrite" in result.stderr
    assert agent_state(database, agent_id) == before
    if target_kind == "file":
        assert output.read_text(encoding="utf-8") == "existing"
    else:
        assert output.is_symlink()
        assert protected.read_text(encoding="utf-8") == "keep"


def test_upsert_is_explicit_and_requires_name(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    database = create_database(tmp_path, monkeypatch)
    first_output = tmp_path / "without-name.json"
    without_name = run_admin(
        *base_arguments(database, "new-agent", first_output), "--upsert"
    )
    assert without_name.returncode == 2
    assert "requires a non-blank --name" in without_name.stderr
    assert not first_output.exists()

    output = tmp_path / "created.json"
    created = run_admin(
        *base_arguments(database, "new-agent", output),
        "--upsert",
        "--name",
        "New Windows Agent",
        "--owner",
        "lab-user",
        "--capability",
        "code",
    )
    assert created.returncode == 0, created.stderr
    assert json.loads(created.stdout)["action"] == "created"
    artifact = json.loads(output.read_text(encoding="utf-8"))
    with sqlite3.connect(database) as connection:
        row = connection.execute(
            "SELECT name, owner, capabilities, token_hash FROM agents WHERE id = ?",
            ("new-agent",),
        ).fetchone()
    assert row[:3] == ("New Windows Agent", "lab-user", json.dumps(["code"]))
    assert row[3] == hashlib.sha256(artifact["token"].encode()).hexdigest()


def test_commit_failure_rolls_back_hash_and_removes_inactive_artifact(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    database = create_database(tmp_path, monkeypatch)
    agent_id, _, _ = seed_agent(database)
    before = agent_state(database, agent_id)
    output = tmp_path / "rollback.json"

    def fail_commit(_: sqlite3.Connection) -> None:
        raise sqlite3.OperationalError("synthetic commit failure")

    monkeypatch.setattr(admin, "_commit_connection", fail_commit)
    with pytest.raises(admin.AdminError, match="database operation failed"):
        admin.provision_bootstrap(
            database=database,
            agent_id=agent_id,
            output=output,
            server="https://relay.example.test/aichat",
            confirm_relay_stopped=True,
        )

    assert agent_state(database, agent_id) == before
    assert not os.path.lexists(output)


def test_published_artifact_cleanup_failure_is_explicit(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    database = create_database(tmp_path, monkeypatch)
    agent_id, _, _ = seed_agent(database)
    before = agent_state(database, agent_id)
    output = tmp_path / "cleanup-failure.json"
    real_fsync = admin.os.fsync
    real_unlink = admin.os.unlink

    def fail_directory_fsync(descriptor: int) -> None:
        if stat.S_ISDIR(os.fstat(descriptor).st_mode):
            raise OSError("synthetic directory fsync failure")
        real_fsync(descriptor)

    def reject_published_cleanup(path: str | os.PathLike[str]) -> None:
        if Path(path) == output:
            raise PermissionError("synthetic cleanup denial")
        real_unlink(path)

    with monkeypatch.context() as patch:
        patch.setattr(admin.os, "fsync", fail_directory_fsync)
        patch.setattr(admin.os, "unlink", reject_published_cleanup)
        with pytest.raises(admin.AdminError, match="inactive artifact manually"):
            admin.provision_bootstrap(
                database=database,
                agent_id=agent_id,
                output=output,
                server="https://relay.example.test/aichat",
                confirm_relay_stopped=True,
            )

    assert output.exists()
    assert agent_state(database, agent_id) == before
    output.unlink()


def test_temporary_artifact_cleanup_failure_is_explicit(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    database = create_database(tmp_path, monkeypatch)
    agent_id, _, _ = seed_agent(database)
    before = agent_state(database, agent_id)
    output = tmp_path / "temporary-cleanup-failure.json"
    real_unlink = admin.os.unlink

    def reject_publish(
        source: str | os.PathLike[str],
        target: str | os.PathLike[str],
        *,
        follow_symlinks: bool = True,
    ) -> None:
        del source, target, follow_symlinks
        raise PermissionError("synthetic publish denial")

    def reject_temporary_cleanup(path: str | os.PathLike[str]) -> None:
        if Path(path).name.startswith(f".{output.name}.tmp-"):
            raise PermissionError("synthetic temporary cleanup denial")
        real_unlink(path)

    with monkeypatch.context() as patch:
        patch.setattr(admin.os, "link", reject_publish)
        patch.setattr(admin.os, "unlink", reject_temporary_cleanup)
        with pytest.raises(admin.AdminError, match="temporary bootstrap artifact may remain"):
            admin.provision_bootstrap(
                database=database,
                agent_id=agent_id,
                output=output,
                server="https://relay.example.test/aichat",
                confirm_relay_stopped=True,
            )

    residue = list(tmp_path.glob(f".{output.name}.tmp-*"))
    assert len(residue) == 1
    assert agent_state(database, agent_id) == before
    residue[0].unlink()
