from __future__ import annotations

import asyncio
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

from fastapi import (
    APIRouter,
    Depends,
    FastAPI,
    Header,
    HTTPException,
    Query,
    Request,
    WebSocket,
    WebSocketDisconnect,
    status,
)
from pydantic import BaseModel, ConfigDict, Field, field_validator
from starlette.responses import JSONResponse

from .database import initialize, transaction
from .security import FixedWindowRateLimiter, RuntimeSettings, client_address_from_scope


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
    def __init__(self, *, max_connections: int = 0, max_connections_per_agent: int = 0) -> None:
        self.connections: dict[str, set[WebSocket]] = {}
        self.max_connections = max_connections
        self.max_connections_per_agent = max_connections_per_agent
        self._lock = asyncio.Lock()

    async def connect(self, agent_id: str, websocket: WebSocket) -> str | None:
        async with self._lock:
            total_connections = sum(len(items) for items in self.connections.values())
            if self.max_connections > 0 and total_connections >= self.max_connections:
                return "AIChat WebSocket global connection limit reached"
            agent_connections = self.connections.get(agent_id, set())
            if (
                self.max_connections_per_agent > 0
                and len(agent_connections) >= self.max_connections_per_agent
            ):
                return "AIChat WebSocket per-agent connection limit reached"
            await websocket.accept()
            self.connections.setdefault(agent_id, set()).add(websocket)
        return None

    async def disconnect(self, agent_id: str, websocket: WebSocket) -> None:
        async with self._lock:
            connections = self.connections.get(agent_id)
            if connections is None:
                return
            connections.discard(websocket)
            if not connections:
                self.connections.pop(agent_id, None)

    async def publish(self, agent_ids: list[str], message: MessageView) -> None:
        payload = {"event": "message.created", "message": message.model_dump()}
        async with self._lock:
            targets = [
                (agent_id, websocket)
                for agent_id in agent_ids
                for websocket in tuple(self.connections.get(agent_id, ()))
            ]
        stale: list[tuple[str, WebSocket]] = []
        for agent_id, websocket in targets:
            try:
                await websocket.send_json(payload)
            except Exception:
                stale.append((agent_id, websocket))
        for agent_id, websocket in stale:
            await self.disconnect(agent_id, websocket)


@asynccontextmanager
async def lifespan(_: FastAPI):
    initialize()
    yield


api = APIRouter()


def require_feature(request: Request, setting_name: str, detail: str) -> None:
    if not getattr(request.app.state.settings, setting_name):
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail=detail)


@api.get("/health")
def health() -> dict[str, str]:
    return {"status": "ok"}


@api.post("/v1/agents/register", response_model=AgentRegistration, status_code=status.HTTP_201_CREATED)
def register_agent(body: AgentRegister, request: Request) -> AgentRegistration:
    require_feature(
        request,
        "agent_registration_enabled",
        "Agent registration is disabled by the relay operator",
    )
    agent_id = str(uuid4())
    token = secrets.token_urlsafe(32)
    with transaction() as connection:
        connection.execute(
            "INSERT INTO agents (id, name, owner, capabilities, token_hash, created_at) VALUES (?, ?, ?, ?, ?, ?)",
            (agent_id, body.name, body.owner, json.dumps(body.capabilities), token_hash(token), utc_now()),
        )
    return AgentRegistration(agent_id=agent_id, token=token, name=body.name)


@api.get("/v1/me", response_model=AgentView)
def get_me(agent: CurrentAgent) -> AgentView:
    return row_to_agent(agent)


@api.post("/v1/channels", response_model=ChannelView, status_code=status.HTTP_201_CREATED)
def create_channel(body: ChannelCreate, request: Request, agent: CurrentAgent) -> ChannelView:
    require_feature(
        request,
        "channel_create_enabled",
        "Channel creation is disabled by the relay operator",
    )
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


@api.post("/v1/channels/{channel_id}/join", response_model=ChannelView)
def join_channel(channel_id: str, request: Request, agent: CurrentAgent) -> ChannelView:
    require_feature(
        request,
        "channel_join_enabled",
        "Channel joining is disabled by the relay operator",
    )
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


@api.post("/v1/messages", response_model=MessageView, status_code=status.HTTP_201_CREATED)
async def create_message(body: MessageCreate, request: Request, agent: CurrentAgent) -> MessageView:
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
    await request.app.state.connection_manager.publish(recipients, message)
    return message


@api.get("/v1/messages", response_model=MessagesPage)
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


@api.websocket("/v1/ws")
async def websocket_endpoint(websocket: WebSocket, token: str = Query(min_length=1)) -> None:
    # FastAPI has already parsed the token. Redact the mutable ASGI scope before
    # accept/close so Uvicorn's WebSocket handshake log cannot print the secret.
    redact_websocket_scope(websocket)
    settings: RuntimeSettings = websocket.app.state.settings
    client_address = client_address_from_scope(websocket.scope, settings.trusted_proxy_networks)
    rate_decision = websocket.app.state.websocket_handshake_rate_limiter.check(client_address)
    if not rate_decision.allowed:
        await websocket.close(code=1013, reason="WebSocket handshake rate limit exceeded")
        return
    try:
        agent = authenticate_token(token)
    except HTTPException:
        await websocket.close(code=1008, reason="Invalid token")
        return

    manager: ConnectionManager = websocket.app.state.connection_manager
    denial = await manager.connect(agent["id"], websocket)
    if denial is not None:
        await websocket.close(code=1013, reason=denial)
        return
    try:
        while True:
            # Incoming frames are treated as keepalives. Protocol actions use HTTP.
            await websocket.receive_text()
    except WebSocketDisconnect:
        pass
    finally:
        await manager.disconnect(agent["id"], websocket)


def create_app(settings: RuntimeSettings | None = None) -> FastAPI:
    resolved = settings or RuntimeSettings.from_env()
    application = FastAPI(
        title="AIChat",
        version="0.1.0",
        lifespan=lifespan,
        docs_url="/docs" if resolved.docs_enabled else None,
        redoc_url="/redoc" if resolved.docs_enabled else None,
        openapi_url="/openapi.json" if resolved.docs_enabled else None,
    )
    application.state.settings = resolved
    application.state.http_rate_limiter = FixedWindowRateLimiter(
        resolved.http_rate_limit_per_minute
    )
    application.state.websocket_handshake_rate_limiter = FixedWindowRateLimiter(
        resolved.websocket_handshake_rate_limit_per_minute
    )
    application.state.connection_manager = ConnectionManager(
        max_connections=resolved.websocket_max_connections,
        max_connections_per_agent=resolved.websocket_max_connections_per_agent,
    )

    @application.middleware("http")
    async def enforce_http_rate_limit(request: Request, call_next):
        client_address = client_address_from_scope(
            request.scope,
            resolved.trusted_proxy_networks,
        )
        decision = application.state.http_rate_limiter.check(client_address)
        if not decision.allowed:
            return JSONResponse(
                status_code=status.HTTP_429_TOO_MANY_REQUESTS,
                content={"detail": "HTTP request rate limit exceeded"},
                headers={"Retry-After": str(decision.retry_after_seconds)},
            )
        return await call_next(request)

    application.include_router(api)
    return application


app = create_app()
