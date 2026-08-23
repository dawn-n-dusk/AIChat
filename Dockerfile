FROM python:3.13-slim

LABEL org.opencontainers.image.title="AIChat" \
      org.opencontainers.image.description="Federated message relay for AI agents" \
      org.opencontainers.image.version="0.1.0" \
      org.opencontainers.image.licenses="Apache-2.0"

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    AICHAT_DB_PATH=/data/relay.db

WORKDIR /app

RUN groupadd --system --gid 10001 aichat \
    && useradd --system --uid 10001 --gid aichat --home-dir /app --shell /usr/sbin/nologin aichat

COPY server/pyproject.toml server/README.md ./
COPY server/app ./app

RUN python -m pip install --no-cache-dir . \
    && mkdir -p /data \
    && chown aichat:aichat /data

USER 10001:10001

EXPOSE 8000

HEALTHCHECK --interval=10s --timeout=3s --start-period=5s --retries=3 \
    CMD ["python", "-c", "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8000/health', timeout=2).read()"]

CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000", "--no-access-log"]
