FROM python:3.12-slim AS base

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1

WORKDIR /srv

RUN apt-get update \
 && apt-get install -y --no-install-recommends curl tini \
 && rm -rf /var/lib/apt/lists/*

COPY requirements.txt .
RUN pip install -r requirements.txt

COPY app ./app
COPY scripts ./scripts
RUN chmod +x scripts/*.sh

ARG BUILD_SHA=dev
ARG BUILD_TIME=unknown
ENV BUILD_SHA=${BUILD_SHA} \
    BUILD_TIME=${BUILD_TIME}

# Drop privileges. Gunicorn binds 8080.
RUN useradd --system --uid 10001 app
USER app

EXPOSE 8080

HEALTHCHECK --interval=10s --timeout=3s --start-period=5s --retries=3 \
  CMD curl -fsS http://127.0.0.1:8080/healthz || exit 1

ENTRYPOINT ["/usr/bin/tini", "--", "scripts/entrypoint.sh"]
