from __future__ import annotations

import argparse
import hashlib
import json
import os
import secrets
import sqlite3
import stat
import sys
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from urllib.parse import urlsplit, urlunsplit
from uuid import uuid4


BOOTSTRAP_KIND = "aichat-agent-bootstrap"
BOOTSTRAP_SCHEMA_VERSION = 1
TOKEN_BYTES = 48


class AdminError(RuntimeError):
    """An operator-safe error that never contains a bearer token."""


class ChannelConflict(AdminError):
    """An immutable existing channel prevents the requested ensure operation."""

    def __init__(self, summary: ChannelSummary):
        super().__init__(
            f"channel definition conflicts with existing state ({summary.conflict_reason})"
        )
        self.summary = summary


@dataclass(frozen=True)
class BootstrapSummary:
    agent_id: str
    action: str
    membership_count: int
    artifact_path: str

    def as_dict(self) -> dict[str, object]:
        return {
            "agent_id": self.agent_id,
            "action": self.action,
            "membership_count": self.membership_count,
            "artifact_path": self.artifact_path,
            "token_written": True,
        }


@dataclass(frozen=True)
class ChannelSummary:
    action: str
    channel_id: str | None
    name: str
    created_by_agent_id: str
    member_count: int
    dry_run: bool
    conflict_reason: str | None = None

    def as_dict(self) -> dict[str, object]:
        summary: dict[str, object] = {
            "action": self.action,
            "channel_id": self.channel_id,
            "name": self.name,
            "created_by_agent_id": self.created_by_agent_id,
            "member_count": self.member_count,
            "dry_run": self.dry_run,
        }
        if self.conflict_reason is not None:
            summary["conflict_reason"] = self.conflict_reason
        return summary


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="milliseconds").replace(
        "+00:00", "Z"
    )


def token_hash(token: str) -> str:
    return hashlib.sha256(token.encode("utf-8")).hexdigest()


def normalize_server(value: str) -> str:
    parsed = urlsplit(value.strip())
    if (
        parsed.scheme not in {"http", "https"}
        or not parsed.netloc
        or parsed.username is not None
        or parsed.password is not None
        or parsed.query
        or parsed.fragment
    ):
        raise AdminError(
            "--server must be an absolute HTTP(S) base URL without credentials, query, or fragment"
        )
    path = parsed.path.rstrip("/")
    return urlunsplit((parsed.scheme, parsed.netloc, path, "", ""))


def require_database(path: Path) -> Path:
    if path.is_symlink():
        raise AdminError("database path must not be a symlink")
    try:
        resolved = path.expanduser().resolve(strict=True)
    except FileNotFoundError as error:
        raise AdminError("database file does not exist; no database was created") from error
    if not resolved.is_file():
        raise AdminError("database path must identify an existing regular file")
    return resolved


def require_output(path: Path) -> Path:
    expanded = path.expanduser()
    if os.path.lexists(expanded):
        raise AdminError("bootstrap output already exists; refusing to overwrite it")
    try:
        parent = expanded.parent.resolve(strict=True)
    except FileNotFoundError as error:
        raise AdminError("bootstrap output directory does not exist") from error
    if not parent.is_dir():
        raise AdminError("bootstrap output parent must be a directory")
    output = parent / expanded.name
    if os.path.lexists(output):
        raise AdminError("bootstrap output already exists; refusing to overwrite it")
    return output


def _write_all(descriptor: int, payload: bytes) -> None:
    view = memoryview(payload)
    while view:
        written = os.write(descriptor, view)
        if written <= 0:
            raise OSError("short write")
        view = view[written:]


def write_bootstrap_exclusive(path: Path, artifact: dict[str, object]) -> None:
    """Atomically create a mode-0600 artifact without replacing any target."""

    temporary = path.parent / f".{path.name}.tmp-{secrets.token_hex(12)}"
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    descriptor: int | None = None
    published = False
    try:
        descriptor = os.open(temporary, flags, 0o600)
        payload = (json.dumps(artifact, sort_keys=True) + "\n").encode("utf-8")
        _write_all(descriptor, payload)
        os.fsync(descriptor)
        os.fchmod(descriptor, 0o600)
        os.close(descriptor)
        descriptor = None

        # A hard link gives create-if-absent semantics. os.replace() would
        # silently overwrite a target created between validation and publish.
        os.link(temporary, path, follow_symlinks=False)
        published = True
        os.unlink(temporary)
        directory = os.open(path.parent, os.O_RDONLY)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
        if stat.S_IMODE(path.stat().st_mode) != 0o600:
            raise AdminError("bootstrap artifact permissions are not 0600")
    except FileExistsError as error:
        raise AdminError(
            "bootstrap output already exists; refusing to overwrite it"
        ) from error
    except Exception:
        if published and os.path.lexists(path):
            try:
                os.unlink(path)
            except OSError as cleanup_error:
                raise AdminError(
                    f"bootstrap artifact may remain at {path}; database activation did not complete, so remove the inactive artifact manually"
                ) from cleanup_error
        raise
    finally:
        if descriptor is not None:
            os.close(descriptor)
        if os.path.lexists(temporary):
            try:
                os.unlink(temporary)
            except OSError as cleanup_error:
                raise AdminError(
                    f"temporary bootstrap artifact may remain at {temporary}; database activation did not complete, so remove the inactive artifact manually"
                ) from cleanup_error


def _commit_connection(connection: sqlite3.Connection) -> None:
    connection.execute("COMMIT")


def _insert_channel(
    connection: sqlite3.Connection,
    *,
    channel_id: str,
    name: str,
    description: str,
    created_by: str,
    created_at: str,
) -> None:
    connection.execute(
        """INSERT INTO channels (id, name, description, created_by, created_at)
           VALUES (?, ?, ?, ?, ?)""",
        (channel_id, name, description, created_by, created_at),
    )


def _insert_channel_members(
    connection: sqlite3.Connection,
    *,
    channel_id: str,
    member_agent_ids: list[str],
    joined_at: str,
) -> None:
    connection.executemany(
        """INSERT INTO channel_members (channel_id, agent_id, joined_at)
           VALUES (?, ?, ?)""",
        [(channel_id, agent_id, joined_at) for agent_id in member_agent_ids],
    )


def _remove_artifact(path: Path) -> None:
    try:
        path.unlink()
        directory = os.open(path.parent, os.O_RDONLY)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
    except FileNotFoundError:
        return


def _current_hash(database: Path, agent_id: str) -> str | None:
    try:
        with sqlite3.connect(f"{database.as_uri()}?mode=ro", uri=True) as connection:
            row = connection.execute(
                "SELECT token_hash FROM agents WHERE id = ?", (agent_id,)
            ).fetchone()
    except sqlite3.Error:
        return None
    return row[0] if row else None


def provision_bootstrap(
    *,
    database: Path,
    agent_id: str,
    output: Path,
    server: str,
    upsert: bool = False,
    name: str | None = None,
    owner: str | None = None,
    capabilities: list[str] | None = None,
    confirm_relay_stopped: bool = False,
) -> BootstrapSummary:
    database = require_database(database)
    output = require_output(output)
    server = normalize_server(server)
    agent_id = agent_id.strip()
    if not agent_id or len(agent_id) > 200:
        raise AdminError("--agent-id must contain between 1 and 200 characters")
    if not confirm_relay_stopped:
        raise AdminError(
            "offline rotation requires --confirm-relay-stopped so previously authenticated sessions are disconnected"
        )
    if upsert and (name is None or not name.strip()):
        raise AdminError("--upsert requires a non-blank --name")
    if not upsert and any(value is not None for value in (name, owner, capabilities)):
        raise AdminError("--name, --owner, and --capability require explicit --upsert")

    clean_name = name.strip() if name is not None else None
    clean_owner = owner.strip() if owner is not None and owner.strip() else None
    clean_capabilities = (
        list(dict.fromkeys(item.strip() for item in capabilities if item.strip()))
        if capabilities is not None
        else None
    )
    if clean_name is not None and len(clean_name) > 120:
        raise AdminError("--name must not exceed 120 characters")
    if clean_owner is not None and len(clean_owner) > 200:
        raise AdminError("--owner must not exceed 200 characters")
    if clean_capabilities is not None and (
        len(clean_capabilities) > 100 or any(len(item) > 120 for item in clean_capabilities)
    ):
        raise AdminError("capabilities exceed the supported count or length")

    connection = sqlite3.connect(database, timeout=10, isolation_level=None)
    connection.row_factory = sqlite3.Row
    connection.execute("PRAGMA foreign_keys = ON")
    artifact_created = False
    old_hash: str | None = None
    new_hash: str | None = None
    try:
        connection.execute("BEGIN IMMEDIATE")
        row = connection.execute(
            "SELECT id, name, owner, capabilities, token_hash FROM agents WHERE id = ?",
            (agent_id,),
        ).fetchone()
        if row is None and not upsert:
            raise AdminError(
                "agent does not exist; default rotation is fail-closed (use --upsert explicitly to create)"
            )

        if row is None:
            action = "created"
            agent_name = clean_name
            assert agent_name is not None
            stored_owner = clean_owner
            stored_capabilities = clean_capabilities or []
        else:
            action = "rotated"
            agent_name = row["name"]
            stored_owner = row["owner"]
            stored_capabilities = json.loads(row["capabilities"])
            old_hash = row["token_hash"]
            if upsert:
                if clean_name != agent_name:
                    raise AdminError(
                        "existing Agent metadata does not match --name; rotation preserves metadata"
                    )
                if owner is not None and clean_owner != stored_owner:
                    raise AdminError(
                        "existing Agent metadata does not match --owner; rotation preserves metadata"
                    )
                if capabilities is not None and clean_capabilities != stored_capabilities:
                    raise AdminError(
                        "existing Agent metadata does not match --capability; rotation preserves metadata"
                    )

        token = secrets.token_urlsafe(TOKEN_BYTES)
        new_hash = token_hash(token)
        if row is None:
            connection.execute(
                """INSERT INTO agents
                   (id, name, owner, capabilities, token_hash, created_at)
                   VALUES (?, ?, ?, ?, ?, ?)""",
                (
                    agent_id,
                    agent_name,
                    stored_owner,
                    json.dumps(stored_capabilities),
                    new_hash,
                    utc_now(),
                ),
            )
        else:
            connection.execute(
                "UPDATE agents SET token_hash = ? WHERE id = ?", (new_hash, agent_id)
            )

        membership_count = connection.execute(
            "SELECT COUNT(*) FROM channel_members WHERE agent_id = ?", (agent_id,)
        ).fetchone()[0]
        artifact = {
            "schema_version": BOOTSTRAP_SCHEMA_VERSION,
            "kind": BOOTSTRAP_KIND,
            "server": server,
            "agent_id": agent_id,
            "agent_name": agent_name,
            "token": token,
            "created_at": utc_now(),
        }
        write_bootstrap_exclusive(output, artifact)
        artifact_created = True
        _commit_connection(connection)
        return BootstrapSummary(
            agent_id=agent_id,
            action=action,
            membership_count=membership_count,
            artifact_path=str(output),
        )
    except Exception as error:
        try:
            connection.execute("ROLLBACK")
        except sqlite3.Error:
            pass
        if artifact_created and new_hash is not None:
            current_hash = _current_hash(database, agent_id)
            unchanged = current_hash == old_hash
            created_not_committed = old_hash is None and current_hash is None
            if unchanged or created_not_committed:
                try:
                    _remove_artifact(output)
                except OSError as cleanup_error:
                    raise AdminError(
                        "database change was rolled back, but the inactive bootstrap artifact could not be deleted; remove it manually"
                    ) from cleanup_error
            elif current_hash == new_hash:
                raise AdminError(
                    "database commit outcome was uncertain but the new hash is active; bootstrap artifact was retained for recovery"
                ) from error
            else:
                raise AdminError(
                    "database state could not be verified after failure; bootstrap artifact was retained and the pre-rotation backup may be required"
                ) from error
        if isinstance(error, AdminError):
            raise
        if isinstance(error, sqlite3.Error):
            raise AdminError(
                "database operation failed; inspect the pre-rotation backup before retrying"
            ) from error
        raise AdminError("bootstrap operation failed before completion") from error
    finally:
        connection.close()


def _normalize_channel_request(
    *,
    name: str,
    description: str,
    created_by_agent_id: str,
    member_agent_ids: list[str] | None,
) -> tuple[str, str, str, list[str]]:
    clean_name = name.strip()
    if not clean_name or len(clean_name) > 160:
        raise AdminError("--name must contain between 1 and 160 characters")
    if not isinstance(description, str):
        raise AdminError("--description is required")
    if len(description) > 2000:
        raise AdminError("--description must not exceed 2000 characters")
    if not member_agent_ids:
        raise AdminError("at least one --member-agent-id is required")
    if len(member_agent_ids) > 100:
        raise AdminError("no more than 100 --member-agent-id values are supported")

    clean_members: list[str] = []
    seen: set[str] = set()
    for value in member_agent_ids:
        agent_id = value.strip()
        if not agent_id or len(agent_id) > 200:
            raise AdminError(
                "each --member-agent-id must contain between 1 and 200 characters"
            )
        if agent_id in seen:
            raise AdminError("duplicate --member-agent-id values are not allowed")
        seen.add(agent_id)
        clean_members.append(agent_id)
    clean_created_by = created_by_agent_id.strip()
    if not clean_created_by or len(clean_created_by) > 200:
        raise AdminError(
            "--created-by-agent-id must contain between 1 and 200 characters"
        )
    if clean_created_by not in seen:
        raise AdminError(
            "--created-by-agent-id must also be listed as a --member-agent-id"
        )
    return clean_name, description, clean_created_by, clean_members


def ensure_channel(
    *,
    database: Path,
    name: str,
    description: str,
    created_by_agent_id: str,
    member_agent_ids: list[str] | None,
    dry_run: bool = False,
) -> ChannelSummary:
    """Create one immutable channel definition or reuse its exact name match."""

    database = require_database(database)
    (
        clean_name,
        clean_description,
        clean_created_by,
        clean_members,
    ) = _normalize_channel_request(
        name=name,
        description=description,
        created_by_agent_id=created_by_agent_id,
        member_agent_ids=member_agent_ids,
    )
    requested_members = set(clean_members)

    connection = sqlite3.connect(database, timeout=10, isolation_level=None)
    connection.row_factory = sqlite3.Row
    connection.execute("PRAGMA foreign_keys = ON")
    transaction_active = False
    try:
        # Dry runs intentionally acquire the same write reservation as a real
        # ensure so their validation view cannot race a concurrent provisioner.
        connection.execute("BEGIN IMMEDIATE")
        transaction_active = True

        placeholders = ",".join("?" for _ in clean_members)
        existing_agents = {
            row["id"]
            for row in connection.execute(
                f"SELECT id FROM agents WHERE id IN ({placeholders})", clean_members
            ).fetchall()
        }
        if existing_agents != requested_members:
            missing_count = len(requested_members - existing_agents)
            raise AdminError(
                f"{missing_count} requested member Agent(s) do not exist; no channel was created"
            )

        matches = connection.execute(
            "SELECT id, description, created_by FROM channels WHERE name = ? ORDER BY id",
            (clean_name,),
        ).fetchall()
        if len(matches) > 1:
            raise ChannelConflict(
                ChannelSummary(
                    action="would_conflict" if dry_run else "conflict",
                    channel_id=None,
                    name=clean_name,
                    created_by_agent_id=clean_created_by,
                    member_count=len(clean_members),
                    dry_run=dry_run,
                    conflict_reason="ambiguous_name",
                )
            )

        if matches:
            channel_id = matches[0]["id"]
            existing_members = {
                row["agent_id"]
                for row in connection.execute(
                    "SELECT agent_id FROM channel_members WHERE channel_id = ?",
                    (channel_id,),
                ).fetchall()
            }
            conflicts: list[str] = []
            if matches[0]["description"] != clean_description:
                conflicts.append("description")
            if matches[0]["created_by"] != clean_created_by:
                conflicts.append("created_by")
            if existing_members != requested_members:
                conflicts.append("membership")
            if conflicts:
                raise ChannelConflict(
                    ChannelSummary(
                        action="would_conflict" if dry_run else "conflict",
                        channel_id=channel_id,
                        name=clean_name,
                        created_by_agent_id=clean_created_by,
                        member_count=len(clean_members),
                        dry_run=dry_run,
                        conflict_reason="_and_".join(conflicts) + "_mismatch",
                    )
                )

            action = "would_reuse" if dry_run else "reused"
            summary = ChannelSummary(
                action=action,
                channel_id=channel_id,
                name=clean_name,
                created_by_agent_id=clean_created_by,
                member_count=len(clean_members),
                dry_run=dry_run,
            )
            if dry_run:
                connection.execute("ROLLBACK")
            else:
                _commit_connection(connection)
            transaction_active = False
            return summary

        if dry_run:
            connection.execute("ROLLBACK")
            transaction_active = False
            return ChannelSummary(
                action="would_create",
                channel_id=None,
                name=clean_name,
                created_by_agent_id=clean_created_by,
                member_count=len(clean_members),
                dry_run=True,
            )

        channel_id = str(uuid4())
        created_at = utc_now()
        _insert_channel(
            connection,
            channel_id=channel_id,
            name=clean_name,
            description=clean_description,
            created_by=clean_created_by,
            created_at=created_at,
        )
        _insert_channel_members(
            connection,
            channel_id=channel_id,
            member_agent_ids=clean_members,
            joined_at=created_at,
        )
        _commit_connection(connection)
        transaction_active = False
        return ChannelSummary(
            action="created",
            channel_id=channel_id,
            name=clean_name,
            created_by_agent_id=clean_created_by,
            member_count=len(clean_members),
            dry_run=False,
        )
    except Exception as error:
        if transaction_active:
            try:
                connection.execute("ROLLBACK")
            except sqlite3.Error:
                pass
        if isinstance(error, AdminError):
            raise
        if isinstance(error, sqlite3.Error):
            raise AdminError(
                "database operation failed; no channel change was accepted"
            ) from error
        raise AdminError("channel provisioning failed before completion") from error
    finally:
        connection.close()


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description=(
            "Rotate an existing AIChat Agent token in a local SQLite database and "
            "write the new credential once to a protected bootstrap artifact."
        )
    )
    parser.add_argument("--database", required=True, type=Path)
    parser.add_argument("--agent-id", required=True)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--server", required=True)
    parser.add_argument(
        "--confirm-relay-stopped",
        action="store_true",
        help=(
            "confirm the Relay process is stopped so old authenticated HTTP/WebSocket "
            "sessions cannot survive rotation"
        ),
    )
    parser.add_argument(
        "--upsert",
        action="store_true",
        help="explicitly allow creating a missing Agent; requires --name",
    )
    parser.add_argument("--name")
    parser.add_argument("--owner")
    parser.add_argument("--capability", action="append", dest="capabilities")
    return parser


def build_channel_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="python -m app.admin ensure-channel",
        description=(
            "Transactionally create or exactly reuse one channel in an existing "
            "local AIChat SQLite database."
        ),
    )
    parser.add_argument("--database", required=True, type=Path)
    parser.add_argument("--name", required=True)
    parser.add_argument(
        "--description",
        required=True,
        help="exact description to store or match",
    )
    parser.add_argument(
        "--created-by-agent-id",
        required=True,
        help="logical creator/audit owner; must also be an exact channel member",
    )
    parser.add_argument(
        "--member-agent-id",
        action="append",
        dest="member_agent_ids",
        help="exact channel member; repeat once per Agent",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="validate under an immediate transaction and roll back without writing",
    )
    return parser


def main(argv: list[str] | None = None) -> int:
    raw_arguments = list(argv) if argv is not None else sys.argv[1:]
    if raw_arguments and raw_arguments[0] == "ensure-channel":
        arguments = build_channel_parser().parse_args(raw_arguments[1:])
        try:
            summary = ensure_channel(
                database=arguments.database,
                name=arguments.name,
                description=arguments.description,
                created_by_agent_id=arguments.created_by_agent_id,
                member_agent_ids=arguments.member_agent_ids,
                dry_run=arguments.dry_run,
            )
        except ChannelConflict as error:
            print(json.dumps(error.summary.as_dict(), sort_keys=True))
            print(f"ERROR: {error}", file=sys.stderr)
            return 2
        except AdminError as error:
            print(f"ERROR: {error}", file=sys.stderr)
            return 2
        print(json.dumps(summary.as_dict(), sort_keys=True))
        return 0

    arguments = build_parser().parse_args(raw_arguments)
    try:
        summary = provision_bootstrap(
            database=arguments.database,
            agent_id=arguments.agent_id,
            output=arguments.output,
            server=arguments.server,
            upsert=arguments.upsert,
            name=arguments.name,
            owner=arguments.owner,
            capabilities=arguments.capabilities,
            confirm_relay_stopped=arguments.confirm_relay_stopped,
        )
    except AdminError as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 2
    print(json.dumps(summary.as_dict(), sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
