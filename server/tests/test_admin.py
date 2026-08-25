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
        sequence = connection.execute(
            "INSERT INTO message_sequence DEFAULT VALUES"
        ).lastrowid
        connection.execute(
            """INSERT INTO messages
               (id, seq, channel_id, sender_id, type, text, reply_to,
                references_json, idempotency_key, hop_count, created_at)
               VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)""",
            (
                "existing-message",
                sequence,
                channel_id,
                agent_id,
                "status",
                "Existing project state",
                None,
                "[]",
                None,
                0,
                "2026-08-24T00:01:00.000Z",
            ),
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


def add_agent(database: Path, agent_id: str) -> None:
    with sqlite3.connect(database) as connection:
        connection.execute(
            """INSERT INTO agents
               (id, name, owner, capabilities, token_hash, created_at)
               VALUES (?, ?, ?, ?, ?, ?)""",
            (
                agent_id,
                f"Agent {agent_id}",
                "test-owner",
                "[]",
                hashlib.sha256(f"secret-for-{agent_id}".encode()).hexdigest(),
                "2026-08-25T00:00:00.000Z",
            ),
        )


def ensure_arguments(
    database: Path,
    name: str,
    members: list[str],
    *,
    description: str,
    created_by_agent_id: str | None = None,
    dry_run: bool = False,
) -> list[str]:
    arguments = [
        "ensure-channel",
        "--database",
        str(database),
        "--name",
        name,
        "--description",
        description,
        "--created-by-agent-id",
        created_by_agent_id or sorted(member.strip() for member in members)[0],
    ]
    for member in members:
        arguments.extend(["--member-agent-id", member])
    if dry_run:
        arguments.append("--dry-run")
    return arguments


def database_state(database: Path) -> dict[str, list[tuple]]:
    with sqlite3.connect(database) as connection:
        return {
            "agents": connection.execute(
                "SELECT id, name, owner, capabilities, token_hash, created_at FROM agents ORDER BY id"
            ).fetchall(),
            "channels": connection.execute(
                "SELECT id, name, description, created_by, created_at FROM channels ORDER BY id"
            ).fetchall(),
            "members": connection.execute(
                "SELECT channel_id, agent_id, joined_at FROM channel_members ORDER BY channel_id, agent_id"
            ).fetchall(),
            "messages": connection.execute(
                """SELECT id, seq, channel_id, sender_id, type, text, reply_to,
                          references_json, idempotency_key, hop_count, created_at
                   FROM messages ORDER BY id"""
            ).fetchall(),
            "sequence": connection.execute(
                "SELECT seq FROM message_sequence ORDER BY seq"
            ).fetchall(),
        }


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


def test_ensure_channel_creates_exact_membership_and_reuses_same_channel(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    database = create_database(tmp_path, monkeypatch)
    first_agent, _, existing_channel = seed_agent(database)
    second_agent = "mac-codex-agent"
    add_agent(database, second_agent)
    before = database_state(database)

    created = run_admin(
        *ensure_arguments(
            database,
            "  Research Project  ",
            [second_agent, first_agent],
            description="Exact shared scope",
        )
    )

    assert created.returncode == 0, created.stderr
    created_summary = json.loads(created.stdout)
    assert created_summary["action"] == "created"
    assert created_summary["name"] == "Research Project"
    assert created_summary["created_by_agent_id"] == second_agent
    assert created_summary["member_count"] == 2
    assert created_summary["dry_run"] is False
    channel_id = created_summary["channel_id"]
    assert channel_id and channel_id != existing_channel

    reused = run_admin(
        *ensure_arguments(
            database,
            "Research Project",
            [first_agent, second_agent],
            description="Exact shared scope",
        )
    )

    assert reused.returncode == 0, reused.stderr
    assert json.loads(reused.stdout) == {
        "action": "reused",
        "channel_id": channel_id,
        "created_by_agent_id": second_agent,
        "dry_run": False,
        "member_count": 2,
        "name": "Research Project",
    }
    after = database_state(database)
    assert after["agents"] == before["agents"]
    assert after["messages"] == before["messages"]
    assert after["sequence"] == before["sequence"]
    assert all(channel in after["channels"] for channel in before["channels"])
    assert len(after["channels"]) == len(before["channels"]) + 1
    assert all(member in after["members"] for member in before["members"])
    assert len(after["members"]) == len(before["members"]) + 2
    with sqlite3.connect(database) as connection:
        channel = connection.execute(
            "SELECT name, description, created_by FROM channels WHERE id = ?",
            (channel_id,),
        ).fetchone()
        members = connection.execute(
            "SELECT agent_id FROM channel_members WHERE channel_id = ? ORDER BY agent_id",
            (channel_id,),
        ).fetchall()
    assert channel == ("Research Project", "Exact shared scope", second_agent)
    assert members == sorted([(first_agent,), (second_agent,)])


def test_ensure_channel_dry_run_reports_create_and_reuse_without_writes(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    database = create_database(tmp_path, monkeypatch)
    agent_id, _, _ = seed_agent(database)
    original = database_state(database)

    would_create = run_admin(
        *ensure_arguments(
            database,
            "Dry Run Channel",
            [agent_id],
            description="dry-run definition",
            dry_run=True,
        )
    )

    assert would_create.returncode == 0, would_create.stderr
    assert json.loads(would_create.stdout) == {
        "action": "would_create",
        "channel_id": None,
        "created_by_agent_id": agent_id,
        "dry_run": True,
        "member_count": 1,
        "name": "Dry Run Channel",
    }
    assert database_state(database) == original

    created = run_admin(
        *ensure_arguments(
            database,
            "Dry Run Channel",
            [agent_id],
            description="dry-run definition",
        )
    )
    assert created.returncode == 0, created.stderr
    after_create = database_state(database)
    channel_id = json.loads(created.stdout)["channel_id"]

    would_reuse = run_admin(
        *ensure_arguments(
            database,
            "Dry Run Channel",
            [agent_id],
            description="dry-run definition",
            dry_run=True,
        )
    )

    assert would_reuse.returncode == 0, would_reuse.stderr
    assert json.loads(would_reuse.stdout) == {
        "action": "would_reuse",
        "channel_id": channel_id,
        "created_by_agent_id": agent_id,
        "dry_run": True,
        "member_count": 1,
        "name": "Dry Run Channel",
    }
    assert database_state(database) == after_create


@pytest.mark.parametrize(
    ("description", "members", "created_by_agent_id", "reason"),
    [
        (
            "changed",
            ["windows-codex-agent", "mac-codex-agent"],
            "mac-codex-agent",
            "description_mismatch",
        ),
        (
            "original",
            ["mac-codex-agent"],
            "mac-codex-agent",
            "membership_mismatch",
        ),
        (
            "original",
            ["windows-codex-agent", "mac-codex-agent", "linux-agent"],
            "mac-codex-agent",
            "membership_mismatch",
        ),
        (
            "original",
            ["windows-codex-agent", "mac-codex-agent"],
            "windows-codex-agent",
            "created_by_mismatch",
        ),
    ],
)
def test_ensure_channel_conflicts_on_description_or_non_exact_membership(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    description: str,
    members: list[str],
    created_by_agent_id: str,
    reason: str,
) -> None:
    database = create_database(tmp_path, monkeypatch)
    first_agent, _, _ = seed_agent(database)
    add_agent(database, "mac-codex-agent")
    add_agent(database, "linux-agent")
    created = run_admin(
        *ensure_arguments(
            database,
            "Immutable Channel",
            [first_agent, "mac-codex-agent"],
            description="original",
        )
    )
    assert created.returncode == 0, created.stderr
    channel_id = json.loads(created.stdout)["channel_id"]
    before = database_state(database)

    conflict = run_admin(
        *ensure_arguments(
            database,
            "Immutable Channel",
            members,
            description=description,
            created_by_agent_id=created_by_agent_id,
            dry_run=True,
        )
    )

    assert conflict.returncode == 2
    assert json.loads(conflict.stdout) == {
        "action": "would_conflict",
        "channel_id": channel_id,
        "conflict_reason": reason,
        "created_by_agent_id": created_by_agent_id,
        "dry_run": True,
        "member_count": len(members),
        "name": "Immutable Channel",
    }
    assert reason in conflict.stderr
    assert database_state(database) == before


def test_ensure_channel_rejects_missing_empty_and_duplicate_members(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    database = create_database(tmp_path, monkeypatch)
    agent_id, _, _ = seed_agent(database)
    add_agent(database, "other-agent")
    before = database_state(database)

    missing = run_admin(
        *ensure_arguments(
            database,
            "Missing Member",
            [agent_id, "not-an-agent"],
            description="missing member check",
        )
    )
    empty = run_admin(
        "ensure-channel",
        "--database",
        str(database),
        "--name",
        "Empty Members",
        "--description",
        "empty member check",
        "--created-by-agent-id",
        agent_id,
    )
    duplicate = run_admin(
        *ensure_arguments(
            database,
            "Duplicate Member",
            [agent_id, f" {agent_id} "],
            description="duplicate member check",
        )
    )
    nonmember_creator = run_admin(
        *ensure_arguments(
            database,
            "Nonmember Creator",
            [agent_id],
            description="nonmember creator check",
            created_by_agent_id="other-agent",
        )
    )

    assert missing.returncode == 2
    assert "1 requested member Agent(s) do not exist" in missing.stderr
    assert empty.returncode == 2
    assert "at least one --member-agent-id" in empty.stderr
    assert duplicate.returncode == 2
    assert "duplicate --member-agent-id" in duplicate.stderr
    assert nonmember_creator.returncode == 2
    assert "must also be listed as a --member-agent-id" in nonmember_creator.stderr
    assert database_state(database) == before


def test_ensure_channel_cli_requires_explicit_description_without_writes(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    database = create_database(tmp_path, monkeypatch)
    agent_id, _, _ = seed_agent(database)
    before = database_state(database)

    result = run_admin(
        "ensure-channel",
        "--database",
        str(database),
        "--name",
        "Missing Description",
        "--created-by-agent-id",
        agent_id,
        "--member-agent-id",
        agent_id,
    )

    assert result.returncode == 2
    assert "--description" in result.stderr
    assert "required" in result.stderr
    assert database_state(database) == before


def test_ensure_channel_rejects_ambiguous_duplicate_name_without_modifying_rows(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    database = create_database(tmp_path, monkeypatch)
    agent_id, _, _ = seed_agent(database)
    with sqlite3.connect(database) as connection:
        for suffix in ("one", "two"):
            channel_id = f"duplicate-{suffix}"
            connection.execute(
                "INSERT INTO channels (id, name, description, created_by, created_at) VALUES (?, ?, ?, ?, ?)",
                (channel_id, "Duplicate Name", None, agent_id, "2026-08-25T00:00:00.000Z"),
            )
            connection.execute(
                "INSERT INTO channel_members (channel_id, agent_id, joined_at) VALUES (?, ?, ?)",
                (channel_id, agent_id, "2026-08-25T00:00:00.000Z"),
            )
    before = database_state(database)

    result = run_admin(
        *ensure_arguments(
            database,
            "Duplicate Name",
            [agent_id],
            description="duplicate name check",
            dry_run=True,
        )
    )

    assert result.returncode == 2
    assert json.loads(result.stdout) == {
        "action": "would_conflict",
        "channel_id": None,
        "conflict_reason": "ambiguous_name",
        "created_by_agent_id": agent_id,
        "dry_run": True,
        "member_count": 1,
        "name": "Duplicate Name",
    }
    assert database_state(database) == before


def test_ensure_channel_real_conflict_fails_closed_without_repairing_channel(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    database = create_database(tmp_path, monkeypatch)
    agent_id, _, _ = seed_agent(database)
    created = run_admin(
        *ensure_arguments(
            database,
            "Existing Definition",
            [agent_id],
            description="original",
        )
    )
    assert created.returncode == 0, created.stderr
    channel_id = json.loads(created.stdout)["channel_id"]
    before = database_state(database)

    result = run_admin(
        *ensure_arguments(
            database,
            "Existing Definition",
            [agent_id],
            description="replacement",
        )
    )

    assert result.returncode == 2
    assert json.loads(result.stdout) == {
        "action": "conflict",
        "channel_id": channel_id,
        "conflict_reason": "description_mismatch",
        "created_by_agent_id": agent_id,
        "dry_run": False,
        "member_count": 1,
        "name": "Existing Definition",
    }
    assert database_state(database) == before


def test_ensure_channel_commit_failure_rolls_back_every_write(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    database = create_database(tmp_path, monkeypatch)
    agent_id, _, _ = seed_agent(database)
    before = database_state(database)

    def fail_commit(_: sqlite3.Connection) -> None:
        raise sqlite3.OperationalError("synthetic commit failure")

    monkeypatch.setattr(admin, "_commit_connection", fail_commit)
    with pytest.raises(admin.AdminError, match="no channel change was accepted"):
        admin.ensure_channel(
            database=database,
            name="Commit Rollback",
            description="commit rollback check",
            created_by_agent_id=agent_id,
            member_agent_ids=[agent_id],
        )

    assert database_state(database) == before


def test_ensure_channel_membership_write_failure_rolls_back_channel_insert(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    database = create_database(tmp_path, monkeypatch)
    agent_id, _, _ = seed_agent(database)
    before = database_state(database)

    def fail_membership_write(
        _: sqlite3.Connection,
        *,
        channel_id: str,
        member_agent_ids: list[str],
        joined_at: str,
    ) -> None:
        del channel_id, member_agent_ids, joined_at
        raise sqlite3.IntegrityError("synthetic membership write failure")

    monkeypatch.setattr(admin, "_insert_channel_members", fail_membership_write)
    with pytest.raises(admin.AdminError, match="no channel change was accepted"):
        admin.ensure_channel(
            database=database,
            name="Write Rollback",
            description="write rollback check",
            created_by_agent_id=agent_id,
            member_agent_ids=[agent_id],
        )

    assert database_state(database) == before


def test_ensure_channel_output_never_contains_agent_secret_or_digest(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    database = create_database(tmp_path, monkeypatch)
    agent_id, old_secret, _ = seed_agent(database)
    old_digest = hashlib.sha256(old_secret.encode()).hexdigest()

    result = run_admin(
        *ensure_arguments(
            database,
            "Safe Summary",
            [agent_id],
            description="safe summary check",
        )
    )

    assert result.returncode == 0, result.stderr
    combined = result.stdout + result.stderr
    assert old_secret not in combined
    assert old_digest not in combined
    assert "token_hash" not in combined
    assert '"token"' not in combined
