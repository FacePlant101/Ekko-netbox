# syntax=docker/dockerfile:1
# NetBox image for Cloudflare Containers. Build from the repository root:
#   docker build --platform linux/amd64 -f deploy/cloudflare/Dockerfile -t netbox-cf .
# Cloudflare only runs linux/amd64 images.

ARG PYTHON_VERSION=3.12

############################
# Builder
############################
FROM python:${PYTHON_VERSION}-slim-bookworm AS builder

ENV PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PIP_NO_CACHE_DIR=1 \
    PYTHONDONTWRITEBYTECODE=1

RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential \
        libpq-dev \
        libffi-dev \
        libssl-dev \
        libxml2-dev \
        libxslt1-dev \
        libjpeg-dev \
        zlib1g-dev \
    && rm -rf /var/lib/apt/lists/*

RUN python -m venv /opt/venv
ENV PATH="/opt/venv/bin:$PATH"

WORKDIR /opt/netbox
COPY requirements.txt ./
COPY deploy/cloudflare/plugin_requirements.txt ./plugin_requirements.txt
RUN pip install --upgrade pip wheel \
    && pip install -r requirements.txt -r plugin_requirements.txt supervisor

COPY netbox/ ./netbox/
COPY deploy/cloudflare/configuration.py ./netbox/netbox/configuration.py

# Build the bundled documentation into netbox/project-static/docs (mkdocs.yml
# site_dir), which settings.py serves at /static/docs/ (the footer's Docs link).
# It must exist before collectstatic below picks it up.
COPY mkdocs.yml ./
COPY docs/ ./docs/
RUN mkdocs build

# Enabled plugins; configuration.py reads this file (see plugins.txt).
COPY deploy/cloudflare/plugins.txt /opt/netbox/plugins.txt

# Collect static files with a throwaway configuration. gunicorn does not serve
# them (DEBUG=False); the Worker serves /static/ from Workers Static Assets built
# from the same output, both in production and under wrangler dev. The plugins
# listed in plugins.txt are enabled, so their static files are collected too.
RUN SECRET_KEY=build-only-placeholder-not-a-secret-0123456789abcdefghijklmnopqrstuvwxyz \
    REDIS_TASKS_URL=redis://localhost:6379/0 \
    REDIS_CACHE_URL=redis://localhost:6379/1 \
    DB_HOST=localhost \
    python netbox/manage.py collectstatic --no-input

############################
# Runtime
############################
FROM python:${PYTHON_VERSION}-slim-bookworm AS runtime

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PATH="/opt/venv/bin:$PATH" \
    NETBOX_ROLE=allinone \
    PORT=8001 \
    PGDATA=/opt/netbox/pgdata

# postgresql-15 and redis-server back the all-in-one role; the image also works as a
# plain web/worker image against external services.
RUN apt-get update && apt-get install -y --no-install-recommends \
        libpq5 \
        libxml2 \
        libxslt1.1 \
        libjpeg62-turbo \
        zlib1g \
        ca-certificates \
        curl \
        postgresql-common \
    && echo "create_main_cluster = false" >> /etc/postgresql-common/createcluster.conf \
    && apt-get install -y --no-install-recommends \
        postgresql-15 \
        postgresql-client-15 \
        redis-server \
    && rm -rf /var/lib/apt/lists/* \
    && groupadd --system --gid 999 netbox \
    && useradd --system --uid 999 --gid netbox --home-dir /opt/netbox --shell /usr/sbin/nologin netbox

COPY --from=builder /opt/venv /opt/venv
COPY --from=builder --chown=netbox:netbox /opt/netbox/netbox /opt/netbox/netbox
COPY --chown=netbox:netbox deploy/cloudflare/gunicorn_config.py /opt/netbox/gunicorn_config.py
COPY --chown=netbox:netbox deploy/cloudflare/entrypoint.sh /opt/netbox/entrypoint.sh
COPY --chown=netbox:netbox deploy/cloudflare/supervisord.conf /opt/netbox/supervisord.conf
COPY --chown=netbox:netbox deploy/cloudflare/plugins.txt /opt/netbox/plugins.txt
COPY --chown=netbox:netbox deploy/cloudflare/bin/ /opt/netbox/bin/

# Writable locations for the filesystem fallbacks (local testing without R2).
RUN mkdir -p /opt/netbox/netbox/media /opt/netbox/netbox/scripts /opt/netbox/netbox/reports /opt/netbox/pgdata \
    && chown -R netbox:netbox /opt/netbox/netbox/media /opt/netbox/netbox/scripts /opt/netbox/netbox/reports /opt/netbox/pgdata \
    && chmod +x /opt/netbox/bin/*.sh

USER netbox
WORKDIR /opt/netbox/netbox

EXPOSE 8001

HEALTHCHECK --interval=30s --timeout=5s --start-period=300s --retries=3 \
    CMD curl -fsS "http://127.0.0.1:${PORT}/login/" > /dev/null || exit 1

ENTRYPOINT ["/opt/netbox/entrypoint.sh"]
