# Deploying NetBox on Cloudflare Containers

Status: Phases 1 to 3 implemented. The deployment now runs entirely on Cloudflare
(section 1a): one container with Postgres and Redis inside, durable via WAL
archiving to R2. Section 1's external-database layout remains supported through
`NETBOX_ROLE=web|worker` but is not the deployed configuration. Written against the Cloudflare Containers
docs as of October 2026 and this fork (upstream v4.5.10 plus the AV-connector /
GPIO additions in `dcim/choices.py`).

## 1. Shape of the deployment

Cloudflare Containers run a Linux image behind a Worker. Every request enters
the Worker, which forwards it to a Durable Object that owns the container
instance. Three platform facts drive the whole design:

| Fact | Consequence for NetBox |
| --- | --- |
| Container disk is ephemeral and reset on every start | PostgreSQL, Redis, media uploads and custom scripts must live outside the container |
| Workers bindings (Hyperdrive, R2, KV) are reachable from the container only via HTTP outbound handlers on ports 80/443 | Postgres and Redis are reached directly over TCP to an external provider. Hyperdrive cannot sit in front of the database for a container |
| Instances sleep after inactivity (`sleepAfter`), no autoscaling yet, max 15 min SIGTERM grace | Web tier must tolerate cold starts; the RQ worker needs something to keep it awake |

Target topology:

```
Internet ──> Worker (netbox-edge)
               ├── /static/*  ──> Workers Static Assets (collectstatic output)
               └── /*         ──> NetBoxWeb container  (gunicorn, port 8001)
             Cron trigger     ──> NetBoxWorker container (rqworker)

NetBoxWeb / NetBoxWorker ──TCP──> managed PostgreSQL (Neon / Supabase / RDS ...)
                         ──TLS──> managed Redis      (Upstash / Redis Cloud ...)
                         ──S3 API──> R2 bucket (media, custom scripts)
```

Both container classes use the **same image** with different entrypoints.

### Managed services to provision

| Need | Choice | Notes |
| --- | --- | --- |
| PostgreSQL 14+ | Neon or Supabase (any provider with a public TLS endpoint) | Prefer a region close to where the container is likely to start. Use the provider's pooled endpoint, since each gunicorn worker and the RQ worker hold connections |
| Redis 4+ | Upstash Redis (TLS, `rediss://`) | NetBox uses two logical DBs (tasks = 0, caching = 1). Upstash exposes one DB, so run two Upstash databases or one Redis Cloud instance with multiple DBs |
| Object storage | Cloudflare R2, S3 API | `STORAGES["default"]` and `STORAGES["scripts"]` via `storages.backends.s3.S3Storage`. `django-storages` is already in `requirements.txt`; add `boto3` to the image |
| Static files | Workers Static Assets | Built by `collectstatic` in CI, served by the Worker, never hits the container |

### Instance sizing

NetBox with gunicorn (3 workers x 3 threads) comfortably needs 1.5 to 2.5 GiB.
Start with:

| Class | Instance type | Why |
| --- | --- | --- |
| `NetBox` (all-in-one, deployed) | `standard-2` (1 vCPU, 6 GiB, 12 GB disk) | Postgres (512 MB shared buffers), Redis, gunicorn and rqworker together; disk holds the database plus one base backup in flight |
| `NetBoxWeb` (external DB layout) | `standard-1` (1/2 vCPU, 4 GiB, 8 GB disk) | Headroom for migrations and large table exports |
| `NetBoxWorker` (external DB layout) | `basic` (1/4 vCPU, 1 GiB) | Idle most of the time |

Requires the Workers Paid plan. Rough steady-state cost at 1 web instance running
24h: ~0.5 vCPU x 730 h plus 4 GiB x 730 h of memory, on the order of USD 30 to 40
per month plus the external Postgres and Redis. Letting the web container sleep
outside working hours cuts this proportionally.

## 1a. All-on-Cloudflare layout (deployed)

Cloudflare has no managed PostgreSQL or Redis, and a container can only reach
Workers bindings over HTTP. So the database runs inside the NetBox container and
is made durable with Postgres' own archiving, written to R2 through the Worker:

```
Internet ──> Worker (netbox)
               ├── /static/*  ──> Workers Static Assets
               └── /*         ──> NetBox container (standard-2, singleton)
             Cron (*/5)       ──> keepAlive(): container never idles out

NetBox container (supervisord):
  postgres 15 (127.0.0.1:5432)   archive_command ──HTTP──> http://r2.internal/backup/wal/<seg>
  redis 7    (127.0.0.1:6379)
  gunicorn   (0.0.0.0:8001)      ──> Worker proxies here
  rqworker
  backup loop: pg_basebackup + media/scripts tar every 6 h ──> r2.internal/backup/base/<ts>/

Worker outbound handler for host r2.internal ──> R2 binding BACKUPS (bucket netbox-media)
```

Durability model:

| Event | Effect |
| --- | --- |
| Planned stop (deploy, idle) | SIGTERM: `pre-stop.sh` switches WAL and waits for it to archive; zero loss |
| Crash / host restart | Lose the writes since the last archived segment: normally under 60 s (`archive_timeout`), up to about two minutes right after a restart because Postgres' first forced switch is measured from startup |
| Next start | `pg-prepare.sh` restores the newest base backup from R2, replays archived WAL, promotes |
| Media uploads, custom scripts | Tarred with each base backup (up to 6 h old after a crash) |

WAL segments are gzipped on upload (`bin/wal-put.sh` / `bin/wal-get.sh`), since
forced switches archive mostly empty 16 MB files. Recovery point: about 60 s. Recovery time: container start plus restore, proportional to
database size (seconds for a typical NetBox). This is a single-node database with
no HA; see risks in section 4.

Files: `bin/pg-prepare.sh` (restore or initdb), `bin/pg-backup.sh`,
`bin/backup-loop.sh`, `bin/pre-stop.sh`, `bin/r2.sh` (curl wrapper for the
handler), `bin/web.sh`, `bin/rqworker.sh`, `supervisord.conf`. The Worker's
`r2Handler` confines all keys to the `backup/` prefix and requires
`Content-Length` on uploads (R2 streams need a known length), so backups are
written to local disk first and uploaded with `curl -T`.

`enableInternet` is false: egress is the R2 handler plus `allowedHosts` in
`src/index.ts` (currently only the NetBox news-feed host used by the default
dashboard widget). Add an SMTP relay or OIDC provider there when needed. The
container also gets `RES_OPTIONS=timeout:1 attempts:1`: without it, a lookup for
any other host hangs for the resolver's full retry budget (about 20 s per page
render that triggers one).

## 2. Repository changes

All new files go under `deploy/cloudflare/` so the upstream merge path stays clean.

```
deploy/cloudflare/
  Dockerfile
  entrypoint.sh            # web (migrate + gunicorn), worker (wait for schema + rqworker), migrate, manage
  configuration.py         # env-var driven NetBox configuration
  gunicorn_config.py       # bind 0.0.0.0:8001 (plain gunicorn.py is gitignored repo-wide)
  collectstatic.sh         # builds the image and copies /static out for Workers Static Assets
  wrangler.jsonc
  package.json             # npm run typecheck | dev | deploy | deploy:immediate
  tsconfig.json
  src/index.ts             # Worker: routing, two Container classes, cron handler
  .dev.vars                # local secrets for wrangler dev (gitignored)
.dockerignore              # repo root, since the image build context is the repo root
```

### 2.1 Dockerfile

- Base `python:3.12-slim`, multi-stage. Builder stage installs `gcc`, `libpq-dev`
  for `psycopg[c]`, then `pip install -r requirements.txt boto3`. Runtime stage
  copies the venv and `netbox/`, installs only `libpq5`.
- Build with `--platform linux/amd64` (mandatory on Apple Silicon; the platform
  only runs amd64).
- Copy `deploy/cloudflare/configuration.py` to `netbox/netbox/configuration.py`
  at build time. It reads everything from environment variables.
- Run `manage.py collectstatic --no-input` in the builder stage as well, so the
  image is self-sufficient for `wrangler dev` even though production serves
  static via Static Assets.
- Non-root user, `EXPOSE 8001`, `ENTRYPOINT ["/opt/netbox/entrypoint.sh"]`.
- Handle `SIGTERM`: gunicorn and `rqworker` both exit gracefully on it, so
  `exec` them from the entrypoint rather than running them as children of a shell.

### 2.2 configuration.py (env driven)

| Env var | Maps to |
| --- | --- |
| `DATABASE_URL` or `DB_HOST/DB_NAME/DB_USER/DB_PASSWORD/DB_SSLMODE` | `DATABASES["default"]`, `sslmode=require`, `conn_max_age` 300 |
| `REDIS_TASKS_URL`, `REDIS_CACHE_URL` | `REDIS["tasks"]`, `REDIS["caching"]`, `SSL=True` |
| `SECRET_KEY` | `SECRET_KEY` |
| `ALLOWED_HOSTS` (comma list), `CSRF_TRUSTED_ORIGINS` | the same |
| `R2_BUCKET`, `R2_ENDPOINT`, `R2_ACCESS_KEY_ID`, `R2_SECRET_ACCESS_KEY` | `STORAGES["default"]` and `STORAGES["scripts"]` S3 backends |
| `BASE_PATH`, `TIME_ZONE`, `PLUGINS` (comma list) | optional passthrough |

`SECURE_PROXY_SSL_HEADER` and `USE_X_FORWARDED_HOST` are already set in
`settings.py`, so the Worker only has to forward `X-Forwarded-Proto: https`.

### 2.3 entrypoint.sh

```
case "$NETBOX_ROLE" in
  web)    python manage.py migrate --no-input
          python manage.py remove_stale_contenttypes --no-input
          exec gunicorn -c /opt/netbox/gunicorn.py netbox.wsgi ;;
  worker) exec python manage.py rqworker high default low ;;
esac
```

The worker role waits for `manage.py migrate --check` to pass before starting
rqworker, so it cannot race the web instance's migrations on first deploy.

Running `migrate` on web start is acceptable for a single web instance.
`django-pglocks` is already a dependency; if a second web instance is ever added,
wrap the migrate step in an advisory lock or move it to a one-shot
`NETBOX_ROLE=migrate` run triggered from the Worker.

Bootstrap tasks (first superuser, API token) are done once with
`NETBOX_ROLE=shell` style one-off runs or via the Worker's
`POST /__admin/bootstrap` guarded by a secret, not baked into the image.

### 2.4 wrangler.jsonc (sketch)

```jsonc
{
  "name": "netbox",
  "main": "src/index.ts",
  "compatibility_date": "2026-10-01",
  "assets": { "directory": "../../netbox/static", "binding": "ASSETS", "run_worker_first": true },
  "containers": [
    { "class_name": "NetBoxWeb",    "image": "./Dockerfile", "instance_type": "standard-1", "max_instances": 1 },
    { "class_name": "NetBoxWorker", "image": "./Dockerfile", "instance_type": "basic",      "max_instances": 1 }
  ],
  "durable_objects": { "bindings": [
    { "name": "NETBOX_WEB",    "class_name": "NetBoxWeb" },
    { "name": "NETBOX_WORKER", "class_name": "NetBoxWorker" }
  ]},
  "exports": {
    "NetBoxWeb":    { "type": "durable-object", "storage": "sqlite" },
    "NetBoxWorker": { "type": "durable-object", "storage": "sqlite" }
  },
  "triggers": { "crons": ["*/5 * * * *"] },
  "observability": { "enabled": true },
  "vars": { "ALLOWED_HOSTS": "netbox.example.com", "CSRF_TRUSTED_ORIGINS": "https://netbox.example.com" }
}
```

Secrets (`wrangler secret put`): `SECRET_KEY`, `DATABASE_URL`, `REDIS_TASKS_URL`,
`REDIS_CACHE_URL`, `R2_ACCESS_KEY_ID`, `R2_SECRET_ACCESS_KEY`, `ADMIN_TOKEN`.

### 2.5 src/index.ts (as implemented)

- `NetBoxWeb extends Container`: `defaultPort = 8001`, `requiredPorts = [8001]`,
  `sleepAfter = "2h"`, `envVars` built in the constructor from `env` (vars and
  secrets) plus `NETBOX_ROLE=web`. `fetch` is overridden to wait up to 10 min for
  the port, because the first boot against an empty database runs every migration.
- `NetBoxWorker extends Container`: `NETBOX_ROLE=worker`, `sleepAfter = "30m"`,
  readiness port 8002 (a stdlib `http.server` started by the entrypoint next to
  rqworker). `keepAlive()` starts it if stopped and renews the idle timer.
- Both classes start with `instanceGetTimeoutMS` and `portReadyTimeoutMS` set to
  the full startup window. The SDK's default start phase polls the port for only
  about 8 s; if the port is still closed and the error is not the production
  "not listening" string (as under `wrangler dev`), it then waits for the
  container to exit, which stalls every request until the instance dies. NetBox
  always needs longer than 8 s to boot, so the long timeout is required.
- Worker `fetch`: `/__health` returns both containers' `getState()` without
  starting anything; `/static/<path>` is rewritten to `/<path>` and served by the
  `ASSETS` binding; everything else goes to the `primary` web instance with
  `X-Forwarded-Proto: https` and `X-Forwarded-Host` set.
- Worker `scheduled` (every 5 min): calls `keepAlive()` on the worker and, when
  `WEB_ALWAYS_ON=true`, `keepWarm()` on the web instance.
- Secrets are read from `env` and passed as process environment; a changed secret
  takes effect on the next container start.

### First admin account

Set the Worker secrets `NETBOX_SUPERUSER_NAME`, `NETBOX_SUPERUSER_EMAIL` and
`NETBOX_SUPERUSER_PASSWORD`; `bin/web.sh` creates that superuser after
migrations if it does not exist yet. The secrets can be deleted afterwards or
left in place (existing users are never modified).

### Deploying by hand

```
cd deploy/cloudflare
npm ci
./collectstatic.sh                         # Workers Static Assets input
npx wrangler secret put SECRET_KEY         # once; 50+ random characters
npx wrangler secret put API_TOKEN_PEPPERS  # once; "1=<50+ random characters>"
npx wrangler deploy --containers-rollout immediate
```

A rollout replaces the running container only when the image or instance type
changed: SIGTERM archives the last WAL segment and the new instance restores
from R2 (about one minute plus restore time; a fresh database with all
migrations took about 11 minutes on one vCPU). A Worker-only deploy leaves the
container running, so changes to the environment it receives (`envVars`,
secrets) take effect on its next start. Outbound policy changes (`allowedHosts`,
handlers) apply to the running container.

## 3. Rollout plan

### Phase 0: prerequisites (half a day)
1. Workers Paid plan enabled, `wrangler` >= 4.141, Docker Desktop or Colima.
2. Provision Postgres and two Redis databases; note TLS URLs.
3. Create R2 bucket `netbox-media`, an R2 API token scoped to it.
4. Create the Worker secrets listed above.

### Phase 1: image and local run (1 day)
1. Write `Dockerfile`, `configuration.py`, `entrypoint.sh`, `gunicorn_config.py`.
2. `docker build --platform linux/amd64` and run locally against the managed
   Postgres/Redis to confirm migrate + login + image upload to R2 + a custom
   script run via `rqworker` all work. This validates everything except the
   Cloudflare routing layer.

### Phase 2: Worker and first deploy (1 day)
1. Write `wrangler.jsonc`, `src/index.ts`, `package.json`.
2. `npx wrangler dev` with both containers local.
3. `npx wrangler deploy --containers-rollout immediate`. First deploy takes
   several minutes to provision; the Worker URL responds before the container
   does.
4. Verify: `wrangler containers list`, log tail, login, `/api/`, GraphQL,
   `/static/` served from assets, an RQ job completing.
5. Bind the custom domain; put Cloudflare Access in front of the hostname
   (optional but cheap, and NetBox's own login still applies).

### Phase 3: CI (implemented)
`.github/workflows/cloudflare-deploy.yml` runs on push to `master` (only when
NetBox code, requirements or `deploy/cloudflare/` change) and on manual dispatch
with a rollout choice (gradual, immediate, none). Steps: `npm ci`, typecheck,
`collectstatic.sh` (Docker build on a native amd64 runner, static assets copied
out), then `wrangler deploy`. It uses a GitHub environment named `cloudflare`;
create it and add `CLOUDFLARE_API_TOKEN` and `CLOUDFLARE_ACCOUNT_ID` there
(environment protection rules can then gate production deploys). Runtime
secrets are managed with `wrangler secret put`, outside CI. Concurrency is
serialised so two pushes cannot interleave rollouts.

### Phase 4: operations
- Backups: rely on the Postgres provider's PITR; R2 has versioning.
- Upgrades: merge upstream, rebuild, deploy. Migrations run on first start of
  the new web instance. For breaking schema changes accept the brief window
  while the old instance drains (up to 15 min SIGTERM grace, usually seconds).
- Logs: Workers Logs with 7-day retention; add Logpush if longer is needed.
- Monitoring: external uptime check on `/__health`, plus
  `django-prometheus` metrics at `/metrics` if desired (already a dependency).

## 4. Risks and open decisions

| Item | Risk | Mitigation / decision needed |
| --- | --- | --- |
| Cold start after sleep | migrate + gunicorn boot is 15 to 40 s; the first request waits | Keep `sleepAfter` long (2h), or add a cron ping during business hours. Decide: always-on vs cost |
| Single web instance | No horizontal scaling; a host restart means a short outage | Acceptable for an internal source of truth. Scaling to N requires moving migrate out of the entrypoint and using `getRandom` |
| Database inside the container | Single node, no HA; up to 60 s of writes lost on a crash; restore time grows with DB size | Accepted for now. Moving to a managed Postgres later only needs `NETBOX_ROLE=web|worker` and the URLs as secrets |
| Backup correctness | A bug in the archive/restore scripts silently breaks recovery | Test a restore regularly: stop the container (or `wrangler containers delete`) and confirm the data comes back; consider a monthly `pg_dump` to R2 as a second copy |
| RQ worker kept alive by cron | Up to 5 min gap after an unexpected kill; cron fires are best-effort | Keep heavy scheduled jobs idempotent; NetBox's own jobs already are |
| Container location vs database region | Instances start near the first requester; DB latency can vary | Pick a DB region near the user base. Smart Placement can be enabled on the Worker |
| Redis egress to Upstash on every request | Latency and per-command billing | Enable the Redis `caching` DB only (NetBox requires it); consider Redis Cloud fixed plan if command volume is high |
| Image size | Full NetBox venv is ~600 MB; must fit the instance disk | `standard-1` has 8 GB, fine. Keep the slim multi-stage build |
| Mixed-version window on deploy | New Worker code runs while old image drains | Keep Worker routing logic stable; container changes are self-contained |
| Email, LDAP, remote auth | Outbound SMTP works (any port allowed when `enableInternet` is true); LDAP to a private network is not reachable | Use OIDC via `social-auth` (already a dependency) or Cloudflare Access headers with `REMOTE_AUTH_ENABLED` |

## 5. Out of scope

- Running Postgres or Redis inside the container. Disk is reset on every
  start, so that is only viable for throwaway demos.
- Multi-region active/active. One web instance, one worker instance.
- Hyperdrive. It is a Workers binding and cannot proxy TCP for a container.

## 6. Phase 1 verification log (2026-10-15)

Image built with `docker build --platform linux/amd64 -f deploy/cloudflare/Dockerfile .`
(184 MB, venv 364 MB uncompressed, static 25 MB). Checked against local
`postgres:16-alpine` and `redis:7-alpine` containers:

- Env-driven configuration parses `DATABASE_URL`, two `rediss://` URLs, R2
  storages, `ALLOWED_HOSTS`, `CSRF_TRUSTED_ORIGINS` and `API_TOKEN_PEPPERS`.
- `NETBOX_ROLE=web`: migrations apply from empty DB, gunicorn listens on
  0.0.0.0:8001, `/login/` returns 200, a foreign Host header returns 400.
- `NETBOX_ROLE=worker`: rqworker listens on high/default/low.
- Both roles exit 0 within 2 s of SIGTERM.
- `/static/` is 404 from the container by design; the Worker serves it.

Phase 2 (`wrangler dev --test-scheduled`, local Postgres/Redis reached via
`host.docker.internal`, secrets in `.dev.vars`):

- `wrangler deploy --dry-run` builds both containers from the repo-root context.
- `/__health` reports both containers stopped without starting them.
- `/static/netbox.css` is served by Static Assets (200, text/css).
- `/__scheduled` started the worker container. It died with
  `column core_job.queue_name does not exist` because the web instance was still
  migrating: a real first-deploy race. Fixed by making the worker role poll
  `migrate --check` before starting rqworker.
- First request to `/login/` started the web container and ran all migrations,
  but the request itself never completed: see the SDK start-timeout note in 2.5.
- With the long start timeout (fresh `.wrangler/state`, database already migrated):
  cron starts the worker and it reports `healthy`; cold-start `/login/` returns
  200 after 174 s (emulated; expect well under 30 s on Cloudflare); warm
  `/login/` in 80 ms; `/static/*` 200 from assets; `/api/` 403 anonymous;
  `/__health` shows both `healthy`; the RQ worker is registered in Redis;
  a CSRF-protected POST login through the Worker returns 302 and the session
  cookie then authenticates `/` and `/api/status/`.
- Not yet tested: real R2 upload, TLS to a managed Postgres/Redis, a real deploy.

Local-only caveat: Cloudflare runs `linux/amd64` only, so on an Apple Silicon
Mac every local container run is emulated and the initial migration pass takes
15 to 20 minutes instead of about a minute. Production is not affected. For
faster local iteration, run a native build for testing only:
`docker build --platform linux/arm64 -f deploy/cloudflare/Dockerfile -t netbox-cf:arm64 .`
and point `wrangler dev` at it by temporarily setting `image` to that tag.
