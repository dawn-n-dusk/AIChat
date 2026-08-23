"""Errors exposed by the AIChat client."""

from __future__ import annotations

from typing import Any


class AIChatError(Exception):
    """Base class for client-facing AIChat errors."""


class ConfigurationError(AIChatError):
    """Raised when required local configuration is missing or invalid."""


class APIError(AIChatError):
    """Raised when the relay responds with a non-success status."""

    def __init__(
        self,
        message: str,
        *,
        status_code: int | None = None,
        details: Any = None,
    ) -> None:
        super().__init__(message)
        self.status_code = status_code
        self.details = details


class AuthenticationError(APIError):
    """Raised when no token is available or the relay rejects it."""
