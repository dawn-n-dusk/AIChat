"""Python client for the AIChat relay."""

from .client import AIChatClient, MessageType
from .config import AIChatConfig, default_config_path, redact_token
from .errors import AIChatError, APIError, AuthenticationError, ConfigurationError

__all__ = [
    "AIChatClient",
    "MessageType",
    "AIChatConfig",
    "AIChatError",
    "APIError",
    "AuthenticationError",
    "ConfigurationError",
    "default_config_path",
    "redact_token",
]

__version__ = "0.1.0"
