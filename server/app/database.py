from __future__ import annotations

import os
import sqlite3
from collections.abc import Iterator
from contextlib import contextmanager
from pathlib import Path


DEFAULT_DB_PATH = Path(__file__).resolve().parents[1] / "data" / "relay.db"


def database_path() -> Path:
    configured = os.environ.get("AICHAT_DB_PATH") or os.environ.get("AI_RELAY_DB_PATH")
    return Path(configured).expanduser() if configured else DEFAULT_DB_PATH


def connect() -> sqlite3.Connection:
    path = database_path()
    path.parent.mkdir(parents=True, exist_ok=True)
    connection = sqlite3.connect(path, timeout=10)
    connection.row_factory = sqlite3.Row
    connection.execute("PRAGMA foreign_keys = ON")
    connection.execute("PRAGMA journal_mode = WAL")
    return connection


@contextmanager
def transaction(*, immediate: bool = False) -> Iterator[sqlite3.Connection]:
    connection = connect()
    try:
        if immediate:
            connection.execute("BEGIN IMMEDIATE")
        yield connection
        connection.commit()
    except Exception:
        connection.rollback()
        raise
    finally:
        connection.close()


def initialize() -> None:
    with transaction(immediate=True) as connection:
        statements = (
            """CREATE TABLE IF NOT EXISTS agents (
                id TEXT PRIMARY KEY,
                name TEXT NOT NULL,
                owner TEXT,
                capabilities TEXT NOT NULL,
                token_hash TEXT NOT NULL UNIQUE,
                created_at TEXT NOT NULL
            )""",
            """CREATE TABLE IF NOT EXISTS channels (
                id TEXT PRIMARY KEY,
                name TEXT NOT NULL,
                description TEXT,
                created_by TEXT NOT NULL REFERENCES agents(id),
                created_at TEXT NOT NULL
            )""",
            """CREATE TABLE IF NOT EXISTS channel_members (
                channel_id TEXT NOT NULL REFERENCES channels(id) ON DELETE CASCADE,
                agent_id TEXT NOT NULL REFERENCES agents(id) ON DELETE CASCADE,
                joined_at TEXT NOT NULL,
                PRIMARY KEY (channel_id, agent_id)
            )""",
            """CREATE TABLE IF NOT EXISTS message_sequence (
                seq INTEGER PRIMARY KEY AUTOINCREMENT
            )""",
            """CREATE TABLE IF NOT EXISTS messages (
                id TEXT PRIMARY KEY,
                seq INTEGER NOT NULL,
                channel_id TEXT NOT NULL REFERENCES channels(id) ON DELETE CASCADE,
                sender_id TEXT NOT NULL REFERENCES agents(id),
                type TEXT NOT NULL CHECK (type IN ('text', 'request', 'result', 'status')),
                text TEXT NOT NULL,
                reply_to TEXT REFERENCES messages(id),
                references_json TEXT NOT NULL,
                idempotency_key TEXT,
                hop_count INTEGER NOT NULL DEFAULT 0 CHECK (hop_count BETWEEN 0 AND 8),
                created_at TEXT NOT NULL
            )""",
        )
        for statement in statements:
            connection.execute(statement)

        columns = {
            row["name"] for row in connection.execute("PRAGMA table_info(messages)").fetchall()
        }
        if "seq" not in columns:
            # V0 prototype migration: preserve existing rows and assign their initial
            # order deterministically. All new rows use the AUTOINCREMENT allocator.
            connection.execute("ALTER TABLE messages ADD COLUMN seq INTEGER")

        max_message_seq = connection.execute(
            "SELECT COALESCE(MAX(seq), 0) FROM messages"
        ).fetchone()[0]
        max_allocated_seq = connection.execute(
            "SELECT COALESCE(MAX(seq), 0) FROM message_sequence"
        ).fetchone()[0]
        if max_message_seq > max_allocated_seq:
            connection.execute(
                "INSERT INTO message_sequence(seq) VALUES (?)", (max_message_seq,)
            )

        rows = connection.execute(
            "SELECT id FROM messages WHERE seq IS NULL ORDER BY created_at ASC, id ASC"
        ).fetchall()
        for row in rows:
            cursor = connection.execute("INSERT INTO message_sequence DEFAULT VALUES")
            connection.execute(
                "UPDATE messages SET seq = ? WHERE id = ?", (cursor.lastrowid, row["id"])
            )

        connection.execute(
            """CREATE UNIQUE INDEX IF NOT EXISTS idx_messages_sender_idempotency
                ON messages(sender_id, idempotency_key)
                WHERE idempotency_key IS NOT NULL"""
        )
        connection.execute(
            "CREATE UNIQUE INDEX IF NOT EXISTS idx_messages_seq ON messages(seq)"
        )
        connection.execute("DROP INDEX IF EXISTS idx_messages_channel_created")
        connection.execute(
            "CREATE INDEX IF NOT EXISTS idx_messages_channel_seq ON messages(channel_id, seq)"
        )
        connection.execute(
            """CREATE TRIGGER IF NOT EXISTS messages_seq_required
            BEFORE INSERT ON messages
            WHEN NEW.seq IS NULL
            BEGIN
                SELECT RAISE(ABORT, 'messages.seq is required');
            END"""
        )
        connection.execute("PRAGMA user_version = 2")
