from __future__ import annotations

import hashlib
import json
import logging
import re
import secrets
import sqlite3
from contextlib import asynccontextmanager
from datetime import datetime, timezone
from typing import Annotated, Literal
from uuid import uuid4

from fastapi import Depends, FastAPI, Header, HTTPException, Query, WebSocket, WebSocketDisconnect, status
from pydantic import BaseModel, ConfigDict, Field, field_validator

from .database import initialize, transaction


WS_TOKEN_PATTERN = re.compile(r"([?&]token=)[^&\s\"]+")


def redact_ws_token(value: str) -> str:
    return WS_TOKEN_PATTERN.sub(r"\1[REDACTED]", value)


class WebSocketTokenLogFilter(logging.Filter):
    def filter(self, record: logging.LogRecord) -> bool:
        if isinstance(record.msg, str):
            record.msg = redact_ws_token(record.msg)
        if isinstance(record.args, tuple):
            record.args = tuple(
                redact_ws_token(value) if isinstance(value, str) else value
                for value in record.args
            )
        elif isinstance(record.args, dict):
            record.args = {
                key: redact_ws_token(value) if isinstance(value, str) else value
                for key, value in record.args.items()
            }
        return True


def install_ws_token_log_filter() -> None:
    for logger_name in ("uvicorn.error", "uvicorn.access"):
        logger = logging.getLogger(logger_name)
        if not any(isinstance(item, WebSocketTokenLogFilter) for item in logger.filters):
            logger.addFilter(WebSocketTokenLogFilter())


def redact_websocket_scope(websocket: WebSocket) -> None:
    query = websocket.scope.get("query_string", b"")
    websocket.scope["query_string"] = re.sub(
        rb"(^|&)token=[^&]*", rb"\1token=%5BREDACTED%5D", query
    )


install_ws_token_log_filter()


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z")


def token_hash(token: str) -> str:
    return hashlib.sha256(token.encode("utf-8")).hexdigest()


class AgentRegister(BaseModel):
    name: str = Field(min_length=1, max_length=120)
    owner: str | None = Field(default=None, max_length=200)
    capabilities: list[str] = Field(default_factory=list, max_length=100)

    @field_validator("name")
    @classmethod
    def clean_name(cls, value: str) -> str:
        value = value.strip()
        if not value:
            raise ValueError("name cannot be blank")
        return value

    @field_validator("capabilities")
    @classmethod
    def clean_capabilities(cls, values: list[str]) -> list[str]:
        cleaned = [value.strip() for value in values if value.strip()]
        if any(len(value) > 120 for value in cleaned):
            raise ValueError("capability is too long")
        return list(dict.fromkeys(cleaned))


class AgentRegistration(BaseModel):
    agent_id: str
    token: str
    name: str


class AgentView(BaseModel):
    agent_id: str
    name: str
    owner: str | None
    capabilities: list[str]
    created_at: str


class ChannelCreate(BaseModel):
    name: str = Field(min_length=1, max_length=160)
    description: str | None = Field(default=None, max_length=2000)

    @field_validator("name")
    @classmethod
    def clean_name(cls, value: str) -> str:
        value = value.strip()
        if not value:
            raise ValueError("name cannot be blank")
        return value


class ChannelView(BaseModel):
    id: str
    name: str
    description: str | None
    created_by: str
    created_at: str
    joined: bool = True


MessageType = Literal["text", "request", "result", "status"]


class MessageCreate(BaseModel):
    channel_id: str
    type: MessageType
    text: str = Field(min_length=1, max_length=100_000)
    reply_to: str | None = None
    references: list[str] = Field(default_factory=list, max_length=100)
    idempotency_key: str | None = Field(default=None, min_length=1, max_length=200)
    hop_count: int = Field(default=0, ge=0, le=8)

    @field_validator("text")
    @classmethod
    def clean_text(cls, value: str) -> str:
        if not value.strip():
            raise ValueError("text cannot be blank")
        return value

    @field_validator("references")
    @classmethod
    def validate_references(cls, values: list[str]) -> list[str]:
        if any(len(value) > 2048 for value in values):
            raise ValueError("reference is too long")
        return values


class MessageView(BaseModel):
    model_config = ConfigDict(extra="forbid")

    id: str
    channel_id: str
    sender_id: str
    type: MessageType
    text: str
    reply_to: str | None
    references: list[str]
    idempotency_key: str | None
    hop_count: int
    created_at: str


class MessagesPage(BaseModel):
    items: list[MessageView]
    next_after: str | None


def row_to_agent(row: sqlite3.Row) -> AgentView:
    return AgentView(
        agent_id=row["id"],
        name=row["name"],
        owner=row["owner"],
        capabilities=json.loads(row["capabilities"]),
        created_at=row["created_at"],
    )


def row_to_message(row: sqlite3.Row) -> MessageView:
    return MessageView(
        id=row["id"],
        channel_id=row["channel_id"],
        sender_id=row["sender_id"],
        type=row["type"],
        text=row["text"],
        reply_to=row["reply_to"],
        references=json.loads(row["references_json"]),
        idempotency_key=row["idempotency_key"],
        hop_count=row["hop_count"],
        created_at=row["created_at"],
    )


def authenticate_token(token: str) -> sqlite3.Row:
    with transaction() as connection:
        row = connection.execute(
            "SELECT * FROM agents WHERE token_hash = ?", (token_hash(token),)
        ).fetchone()
    if row is None:
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="Invalid token")
    return row


def current_agent(authorization: Annotated[str | None, Header()] = None) -> sqlite3.Row:
    if not authorization:
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="Missing bearer token")
    scheme, separator, token = authorization.partition(" ")
    if separator != " " or scheme.lower() != "bearer" or not token:
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="Invalid authorization header")
    return authenticate_token(token)


CurrentAgent = Annotated[sqlite3.Row, Depends(current_agent)]


def require_membership(connection: sqlite3.Connection, channel_id: str, agent_id: str) -> None:
    channel = connection.execute("SELECT 1 FROM channels WHERE id = ?", (channel_id,)).fetchone()
    if channel is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Channel not found")
    member = connection.execute(
        "SELECT 1 FROM channel_members WHERE channel_id = ? AND agent_id = ?",
        (channel_id, agent_id),
    ).fetchone()
    if member is None:
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="Join the channel first")


class ConnectionManager:
    def __init__(self) -> None:
        self.connections: dict[str, set[WebSocket]] = {}

    async def connect(self, agent_id: str, websocket: WebSocket) -> None:
        await websocket.accept()
        self.connections.setdefault(agent_id, set()).add(websocket)

    def disconnect(self, agent_id: str, websocket: WebSocket) -> None:
        connections = self.connections.get(agent_id)
        if connections is None:
            return
        connections.discard(websocket)
        if not connections:
            self.connections.pop(agent_id, None)

    async def publish(self, agent_ids: list[str], message: MessageView) -> None:
        payload = {"event": "message.created", "message": message.model_dump()}
        stale: list[tuple[str, WebSocket]] = []
        for agent_id in agent_ids:
            for websocket in tuple(self.connections.get(agent_id, ())):
                try:
                    await websocket.send_json(payload)
                except Exception:
                    stale.append((agent_id, websocket))
        for agent_id, websocket in stale:
            self.disconnect(agent_id, websocket)


manager = ConnectionManager()


@asynccontextmanager
async def lifespan(_: FastAPI):
    initialize()
    yield


app = FastAPI(title="AIChat", version="0.1.0", lifespan=lifespan)


@app.get("/health")
def health() -> dict[str, str]:
    return {"status": "ok"}


@app.post("/v1/agents/register", response_model=AgentRegistration, status_code=status.HTTP_201_CREATED)
def register_agent(body: AgentRegister) -> AgentRegistration:
    agent_id = str(uuid4())
    token = secrets.token_urlsafe(32)
    with transaction() as connection:
        connection.execute(
            "INSERT INTO agents (id, name, owner, capabilities, token_hash, created_at) VALUES (?, ?, ?, ?, ?, ?)",
            (agent_id, body.name, body.owner, json.dumps(body.capabilities), token_hash(token), utc_now()),
        )
    return AgentRegistration(agent_id=agent_id, token=token, name=body.name)


@app.get("/v1/me", response_model=AgentView)
def get_me(agent: CurrentAgent) -> AgentView:
    return row_to_agent(agent)


@app.post("/v1/channels", response_model=ChannelView, status_code=status.HTTP_201_CREATED)
def create_channel(body: ChannelCreate, agent: CurrentAgent) -> ChannelView:
    channel_id = str(uuid4())
    created_at = utc_now()
    with transaction() as connection:
        connection.execute(
            "INSERT INTO channels (id, name, description, created_by, created_at) VALUES (?, ?, ?, ?, ?)",
            (channel_id, body.name, body.description, agent["id"], created_at),
        )
        connection.execute(
            "INSERT INTO channel_members (channel_id, agent_id, joined_at) VALUES (?, ?, ?)",
            (channel_id, agent["id"], created_at),
        )
    return ChannelView(
        id=channel_id,
        name=body.name,
        description=body.description,
        created_by=agent["id"],
        created_at=created_at,
    )


@app.post("/v1/channels/{channel_id}/join", response_model=ChannelView)
def join_channel(channel_id: str, agent: CurrentAgent) -> ChannelView:
    with transaction() as connection:
        channel = connection.execute("SELECT * FROM channels WHERE id = ?", (channel_id,)).fetchone()
        if channel is None:
            raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Channel not found")
        connection.execute(
            "INSERT OR IGNORE INTO channel_members (channel_id, agent_id, joined_at) VALUES (?, ?, ?)",
            (channel_id, agent["id"], utc_now()),
        )
    return ChannelView(
        id=channel["id"],
        name=channel["name"],
        description=channel["description"],
        created_by=channel["created_by"],
        created_at=channel["created_at"],
    )


@app.post("/v1/messages", response_model=MessageView, status_code=status.HTTP_201_CREATED)
async def create_message(body: MessageCreate, agent: CurrentAgent) -> MessageView:
    with transaction(immediate=True) as connection:
        require_membership(connection, body.channel_id, agent["id"])

        if body.idempotency_key is not None:
            existing = connection.execute(
                "SELECT * FROM messages WHERE sender_id = ? AND idempotency_key = ?",
                (agent["id"], body.idempotency_key),
            ).fetchone()
            if existing is not None:
                return row_to_message(existing)

        if body.reply_to is not None:
            reply = connection.execute(
                "SELECT channel_id FROM messages WHERE id = ?", (body.reply_to,)
            ).fetchone()
            if reply is None:
                raise HTTPException(status_code=422, detail="Reply target not found")
            if reply["channel_id"] != body.channel_id:
                raise HTTPException(
                    status_code=422,
                    detail="Reply target belongs to another channel",
                )

        message_id = str(uuid4())
        created_at = utc_now()
        sequence_cursor = connection.execute("INSERT INTO message_sequence DEFAULT VALUES")
        sequence = sequence_cursor.lastrowid
        connection.execute(
            """
            INSERT INTO messages
                (id, seq, channel_id, sender_id, type, text, reply_to, references_json,
                 idempotency_key, hop_count, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            (
                message_id,
                sequence,
                body.channel_id,
                agent["id"],
                body.type,
                body.text,
                body.reply_to,
                json.dumps(body.references),
                body.idempotency_key,
                body.hop_count,
                created_at,
            ),
        )
        row = connection.execute("SELECT * FROM messages WHERE id = ?", (message_id,)).fetchone()
        recipients = [
            item["agent_id"]
            for item in connection.execute(
                "SELECT agent_id FROM channel_members WHERE channel_id = ?", (body.channel_id,)
            ).fetchall()
        ]

    message = row_to_message(row)
    await manager.publish(recipients, message)
    return message


@app.get("/v1/messages", response_model=MessagesPage)
def list_messages(
    agent: CurrentAgent,
    channel_id: str = Query(min_length=1),
    after: str | None = None,
    limit: int = Query(default=50, ge=1, le=200),
) -> MessagesPage:
    with transaction() as connection:
        require_membership(connection, channel_id, agent["id"])
        parameters: list[str | int] = [channel_id]
        after_clause = ""
        if after is not None:
            cursor = connection.execute(
                "SELECT seq FROM messages WHERE id = ? AND channel_id = ?",
                (after, channel_id),
            ).fetchone()
            if cursor is None:
                raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail="Invalid after cursor")
            after_clause = "AND seq > ?"
            parameters.append(cursor["seq"])
        parameters.append(limit)
        rows = connection.execute(
            f"""
            SELECT * FROM messages
            WHERE channel_id = ? {after_clause}
            ORDER BY seq ASC
            LIMIT ?
            """,
            parameters,
        ).fetchall()
    messages = [row_to_message(row) for row in rows]
    return MessagesPage(items=messages, next_after=messages[-1].id if messages else after)


@app.websocket("/v1/ws")
async def websocket_endpoint(websocket: WebSocket, token: str = Query(min_length=1)) -> None:
    # FastAPI has already parsed the token. Redact the mutable ASGI scope before
    # accept/close so Uvicorn's WebSocket handshake log cannot print the secret.
    redact_websocket_scope(websocket)
    try:
        agent = authenticate_token(token)
    except HTTPException:
        await websocket.close(code=1008, reason="Invalid token")
        return

    await manager.connect(agent["id"], websocket)
    try:
        while True:
            # Incoming frames are treated as keepalives. Protocol actions use HTTP.
            await websocket.receive_text()
    except WebSocketDisconnect:
        manager.disconnect(agent["id"], websocket)
