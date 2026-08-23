import logging
import sqlite3

import pytest
from fastapi.testclient import TestClient

from app.database import initialize
from app.main import app, redact_websocket_scope, token_hash


@pytest.fixture()
def client(tmp_path, monkeypatch):
    database = tmp_path / "relay.db"
    monkeypatch.setenv("AICHAT_DB_PATH", str(database))
    with TestClient(app) as test_client:
        yield test_client, database


def register(client: TestClient, name: str) -> dict:
    response = client.post(
        "/v1/agents/register",
        json={"name": name, "owner": f"{name}-owner", "capabilities": ["chat"]},
    )
    assert response.status_code == 201
    return response.json()


def auth(agent: dict) -> dict[str, str]:
    return {"Authorization": f"Bearer {agent['token']}"}


def test_registration_auth_and_hashed_token(client):
    test_client, database = client
    agent = register(test_client, "alpha")

    response = test_client.get("/v1/me", headers=auth(agent))
    assert response.status_code == 200
    assert response.json()["agent_id"] == agent["agent_id"]
    assert response.json()["capabilities"] == ["chat"]

    with sqlite3.connect(database) as connection:
        stored = connection.execute("SELECT token_hash FROM agents WHERE id = ?", (agent["agent_id"],)).fetchone()[0]
    assert stored == token_hash(agent["token"])
    assert stored != agent["token"]
    assert test_client.get("/v1/me", headers={"Authorization": "Bearer wrong"}).status_code == 401


def test_channel_access_messages_replies_and_idempotency(client):
    test_client, _ = client
    alpha = register(test_client, "alpha")
    beta = register(test_client, "beta")

    channel_response = test_client.post(
        "/v1/channels",
        headers=auth(alpha),
        json={"name": "project-x", "description": "Shared work"},
    )
    assert channel_response.status_code == 201
    channel = channel_response.json()

    denied = test_client.get(
        "/v1/messages", headers=auth(beta), params={"channel_id": channel["id"]}
    )
    assert denied.status_code == 403
    assert test_client.post(
        f"/v1/channels/{channel['id']}/join", headers=auth(beta)
    ).status_code == 200

    first_body = {
        "channel_id": channel["id"],
        "type": "request",
        "text": "Please run the tests",
        "references": ["https://example.test/commit/abc"],
        "idempotency_key": "alpha-request-1",
    }
    first = test_client.post("/v1/messages", headers=auth(alpha), json=first_body)
    assert first.status_code == 201

    duplicate = test_client.post("/v1/messages", headers=auth(alpha), json=first_body)
    assert duplicate.status_code == 201
    assert duplicate.json()["id"] == first.json()["id"]

    reply = test_client.post(
        "/v1/messages",
        headers=auth(beta),
        json={
            "channel_id": channel["id"],
            "type": "result",
            "text": "Tests passed",
            "reply_to": first.json()["id"],
        },
    )
    assert reply.status_code == 201

    page = test_client.get(
        "/v1/messages",
        headers=auth(alpha),
        params={"channel_id": channel["id"], "limit": 1},
    ).json()
    assert len(page["items"]) == 1
    next_page = test_client.get(
        "/v1/messages",
        headers=auth(alpha),
        params={"channel_id": channel["id"], "after": page["next_after"]},
    ).json()
    assert [message["text"] for message in next_page["items"]] == ["Tests passed"]


def test_reply_channel_validation_and_hop_limit(client):
    test_client, _ = client
    agent = register(test_client, "alpha")
    first_channel = test_client.post("/v1/channels", headers=auth(agent), json={"name": "one"}).json()
    second_channel = test_client.post("/v1/channels", headers=auth(agent), json={"name": "two"}).json()
    message = test_client.post(
        "/v1/messages",
        headers=auth(agent),
        json={"channel_id": first_channel["id"], "type": "text", "text": "hello"},
    ).json()

    cross_channel = test_client.post(
        "/v1/messages",
        headers=auth(agent),
        json={
            "channel_id": second_channel["id"],
            "type": "text",
            "text": "bad reply",
            "reply_to": message["id"],
        },
    )
    assert cross_channel.status_code == 422

    too_many_hops = test_client.post(
        "/v1/messages",
        headers=auth(agent),
        json={"channel_id": first_channel["id"], "type": "text", "text": "loop", "hop_count": 9},
    )
    assert too_many_hops.status_code == 422


def test_websocket_push_only_reaches_joined_agents(client):
    test_client, _ = client
    alpha = register(test_client, "alpha")
    beta = register(test_client, "beta")
    channel = test_client.post("/v1/channels", headers=auth(alpha), json={"name": "live"}).json()
    test_client.post(f"/v1/channels/{channel['id']}/join", headers=auth(beta))

    with test_client.websocket_connect(f"/v1/ws?token={beta['token']}") as websocket:
        response = test_client.post(
            "/v1/messages",
            headers=auth(alpha),
            json={"channel_id": channel["id"], "type": "status", "text": "online"},
        )
        assert response.status_code == 201
        event = websocket.receive_json()
        assert event["event"] == "message.created"
        assert event["message"]["text"] == "online"


def test_cursor_sequence_cannot_lose_later_same_timestamp_message(client, monkeypatch):
    test_client, _ = client
    agent = register(test_client, "alpha")
    channel = test_client.post(
        "/v1/channels", headers=auth(agent), json={"name": "cursor-order"}
    ).json()

    monkeypatch.setattr("app.main.utc_now", lambda: "2026-08-24T00:00:00.000Z")
    message_ids = iter(["zzzz-first", "aaaa-later"])
    monkeypatch.setattr("app.main.uuid4", lambda: next(message_ids))

    first = test_client.post(
        "/v1/messages",
        headers=auth(agent),
        json={"channel_id": channel["id"], "type": "text", "text": "first"},
    ).json()
    first_page = test_client.get(
        "/v1/messages",
        headers=auth(agent),
        params={"channel_id": channel["id"], "limit": 1},
    ).json()
    assert first_page["next_after"] == first["id"]

    later = test_client.post(
        "/v1/messages",
        headers=auth(agent),
        json={"channel_id": channel["id"], "type": "text", "text": "later"},
    ).json()
    assert later["id"] < first["id"]  # Would sort before the cursor under the old UUID tie-break.

    next_page = test_client.get(
        "/v1/messages",
        headers=auth(agent),
        params={"channel_id": channel["id"], "after": first_page["next_after"]},
    ).json()
    assert [item["id"] for item in next_page["items"]] == [later["id"]]


def test_initialize_migrates_v0_messages_to_monotonic_sequence(tmp_path, monkeypatch):
    database = tmp_path / "legacy.db"
    monkeypatch.setenv("AICHAT_DB_PATH", str(database))
    with sqlite3.connect(database) as connection:
        connection.executescript(
            """
            CREATE TABLE agents (
                id TEXT PRIMARY KEY, name TEXT NOT NULL, owner TEXT,
                capabilities TEXT NOT NULL, token_hash TEXT NOT NULL UNIQUE,
                created_at TEXT NOT NULL
            );
            CREATE TABLE channels (
                id TEXT PRIMARY KEY, name TEXT NOT NULL, description TEXT,
                created_by TEXT NOT NULL REFERENCES agents(id), created_at TEXT NOT NULL
            );
            CREATE TABLE messages (
                id TEXT PRIMARY KEY,
                channel_id TEXT NOT NULL REFERENCES channels(id) ON DELETE CASCADE,
                sender_id TEXT NOT NULL REFERENCES agents(id),
                type TEXT NOT NULL,
                text TEXT NOT NULL,
                reply_to TEXT REFERENCES messages(id),
                references_json TEXT NOT NULL,
                idempotency_key TEXT,
                hop_count INTEGER NOT NULL DEFAULT 0,
                created_at TEXT NOT NULL
            );
            INSERT INTO agents VALUES ('agent', 'Agent', NULL, '[]', 'hash', 'time');
            INSERT INTO channels VALUES ('channel', 'Channel', NULL, 'agent', 'time');
            INSERT INTO messages VALUES
                ('z-old', 'channel', 'agent', 'text', 'z', NULL, '[]', NULL, 0, 'same-time'),
                ('a-old', 'channel', 'agent', 'text', 'a', NULL, '[]', NULL, 0, 'same-time');
            """
        )

    initialize()

    with sqlite3.connect(database) as connection:
        columns = [row[1] for row in connection.execute("PRAGMA table_info(messages)")]
        migrated = connection.execute(
            "SELECT id, seq FROM messages ORDER BY seq"
        ).fetchall()
        schema_version = connection.execute("PRAGMA user_version").fetchone()[0]
    assert "seq" in columns
    assert migrated == [("a-old", 1), ("z-old", 2)]
    assert schema_version == 2


def test_websocket_token_is_redacted_from_scope_and_application_logs(caplog):
    secret = "top-secret-token"
    fake_websocket = type(
        "FakeWebSocket",
        (),
        {"scope": {"query_string": f"client=one&token={secret}&mode=live".encode()}},
    )()
    redact_websocket_scope(fake_websocket)
    assert secret.encode() not in fake_websocket.scope["query_string"]
    assert b"token=%5BREDACTED%5D" in fake_websocket.scope["query_string"]

    caplog.set_level(logging.INFO, logger="uvicorn.error")
    logging.getLogger("uvicorn.error").info(
        '%s - "WebSocket %s" [accepted]',
        "127.0.0.1",
        f"/v1/ws?token={secret}&mode=live",
    )
    assert secret not in caplog.text
    assert "token=[REDACTED]" in caplog.text
