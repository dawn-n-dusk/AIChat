"""AIChat's protocol-first MCP adapter."""

from .client import AIChatAPI, AIChatAPIError
from .config import AdapterConfig, AdapterConfigurationError
from .service import AIChatService

__all__ = [
    "AIChatAPI",
    "AIChatAPIError",
    "AIChatService",
    "AdapterConfig",
    "AdapterConfigurationError",
]

__version__ = "0.1.0"
