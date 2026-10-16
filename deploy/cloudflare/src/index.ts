/**
 * Cloudflare Worker fronting NetBox on Cloudflare Containers.
 *
 * One container runs Postgres, Redis, gunicorn, rqworker and a backup loop.
 * Postgres durability comes from WAL archiving and base backups written to R2:
 * the container talks plain HTTP to the virtual host `r2.internal`, which the
 * outbound handler below maps onto the BACKUPS R2 binding.
 *
 *  - /static/*   -> Workers Static Assets (collectstatic output)
 *  - /__health   -> container state without waking it
 *  - everything  -> NetBox container (gunicorn on 8001)
 *  - cron        -> keeps the container running (it is the database)
 */
import { Container, type OutboundHandlerContext } from "@cloudflare/containers";
import type { DurableObject } from "cloudflare:workers";
export { ContainerProxy } from "@cloudflare/containers";

// Bindings and vars come from the generated worker-configuration.d.ts (`wrangler types`).
// Secrets are not in wrangler.jsonc, so they are merged into the global Env here.
declare global {
  interface Env {
    SECRET_KEY: string;
    API_TOKEN_PEPPERS?: string;
    // Optional first-admin bootstrap, applied idempotently by bin/web.sh.
    NETBOX_SUPERUSER_NAME?: string;
    NETBOX_SUPERUSER_EMAIL?: string;
    NETBOX_SUPERUSER_PASSWORD?: string;
    // Only used by the external-database roles (NETBOX_ROLE=web|worker).
    DATABASE_URL?: string;
    REDIS_TASKS_URL?: string;
    REDIS_CACHE_URL?: string;
    R2_ACCESS_KEY_ID?: string;
    R2_SECRET_ACCESS_KEY?: string;
    COOKIE_SECURE?: string;
    DB_SSLMODE?: string;
  }
}

type DurableObjectCtx = DurableObject["ctx"];

/** Names of env entries forwarded verbatim into the container process when set. */
const FORWARDED_ENV = [
  "ALLOWED_HOSTS",
  "CSRF_TRUSTED_ORIGINS",
  "SECRET_KEY",
  "API_TOKEN_PEPPERS",
  "TIME_ZONE",
  "NETBOX_ROLE",
  "BACKUP_INTERVAL_SECONDS",
  "NETBOX_SUPERUSER_NAME",
  "NETBOX_SUPERUSER_EMAIL",
  "NETBOX_SUPERUSER_PASSWORD",
  "DATABASE_URL",
  "REDIS_TASKS_URL",
  "REDIS_CACHE_URL",
  "R2_BUCKET",
  "R2_ENDPOINT",
  "R2_ACCESS_KEY_ID",
  "R2_SECRET_ACCESS_KEY",
  "COOKIE_SECURE",
  "DB_SSLMODE",
] as const;

const WEB_PORT = 8001;
const INSTANCE = "primary";
const R2_HOST = "r2.internal";
const BACKUP_PREFIX = "backup/";
// First boot runs every migration; a restore replays WAL first. Both can take minutes.
const STARTUP_TIMEOUT_MS = 15 * 60 * 1000;

/**
 * Start options that keep polling the port for the whole startup window. The SDK's
 * default start phase gives up after ~8 s and then waits for the container to exit,
 * which stalls requests when startup is slower than that (always true for NetBox).
 */
function startupWait(port: number, timeoutMs: number) {
  return {
    ports: [port],
    cancellationOptions: { instanceGetTimeoutMS: timeoutMs, portReadyTimeoutMS: timeoutMs, waitInterval: 1000 },
  };
}

function containerEnv(env: Env): Record<string, string> {
  const vars: Record<string, string> = { PORT: String(WEB_PORT), R2_HOST, BACKUP_PREFIX: BACKUP_PREFIX.replace(/\/$/, "") };
  for (const name of FORWARDED_ENV) {
    const value: unknown = env[name];
    if (typeof value === "string" && value.length > 0) {
      vars[name] = value;
    }
  }
  return vars;
}

/** The whole NetBox stack. Singleton: it owns the database. */
export class NetBox extends Container<Env> {
  defaultPort = WEB_PORT;
  requiredPorts = [WEB_PORT];
  // The cron trigger renews activity every 5 minutes, so this only matters if
  // the trigger stalls. Sleeping is safe (WAL is archived) but costs a restore.
  sleepAfter = "1h";
  // No public internet: the only egress is the R2 handler below. Add hosts to
  // allowedHosts for SMTP relays or OIDC providers when needed.
  enableInternet = false;

  constructor(ctx: DurableObjectCtx, env: Env) {
    super(ctx, env);
    this.envVars = containerEnv(env);
  }

  override onStart(): void {
    console.log("netbox: container started");
  }

  override onStop({ exitCode, reason }: { exitCode: number; reason: string }): void {
    console.log(`netbox: container stopped (exit ${exitCode}, ${reason})`);
  }

  override onError(error: unknown): never {
    console.error("netbox: container error", error);
    throw error;
  }

  override async fetch(request: Request): Promise<Response> {
    if (!this.ctx.container?.running) {
      const t0 = Date.now();
      await this.startAndWaitForPorts(startupWait(WEB_PORT, STARTUP_TIMEOUT_MS));
      console.log(`netbox: cold start took ${Date.now() - t0}ms`);
    }
    // Passing the original Request keeps its absolute URL, so Django sees the
    // public hostname in Host and ALLOWED_HOSTS applies as configured.
    return this.containerFetch(request, WEB_PORT);
  }

  /** Called from the cron trigger: start if stopped and push the idle deadline out. */
  async keepAlive(): Promise<string> {
    const before = (await this.getState()).status;
    if (!this.ctx.container?.running) {
      await this.startAndWaitForPorts(startupWait(WEB_PORT, STARTUP_TIMEOUT_MS));
    }
    await this.renewActivityTimeout();
    return before;
  }

  async status() {
    return this.getState();
  }
}

// Registered via the SDK's static setter; a `static` class field would shadow the
// setter and the handler would never be installed ("Origin is disallowed").
NetBox.outboundByHost = {
  [R2_HOST]: r2Handler,
};

/**
 * Outbound handler for http://r2.internal/<key>. Runs in the Workers runtime with
 * the R2 binding; the container only needs curl. Keys are confined to BACKUP_PREFIX.
 *   PUT    /<key>          store body (Content-Length required)
 *   GET    /<key>          fetch object, 404 if missing
 *   HEAD   /<key>          200/404
 *   DELETE /<key>
 *   GET    /?list=<prefix> newline-separated keys
 */
async function r2Handler(request: Request, env: Env, _ctx: OutboundHandlerContext): Promise<Response> {
  const url = new URL(request.url);
  const bucket = env.BACKUPS;

  if (url.pathname === "/" && url.searchParams.has("list")) {
    const prefix = scoped(url.searchParams.get("list") ?? "");
    const keys: string[] = [];
    let cursor: string | undefined;
    do {
      const page = await bucket.list({ prefix, cursor, limit: 1000 });
      for (const obj of page.objects) keys.push(obj.key);
      cursor = page.truncated ? page.cursor : undefined;
    } while (cursor);
    return new Response(keys.join("\n") + (keys.length ? "\n" : ""), { headers: { "Content-Type": "text/plain" } });
  }

  const key = scoped(decodeURIComponent(url.pathname.slice(1)));
  if (!key || key === BACKUP_PREFIX) return new Response("key required", { status: 400 });

  switch (request.method) {
    case "PUT": {
      if (!request.headers.has("Content-Length")) {
        return new Response("Content-Length required", { status: 411 });
      }
      await bucket.put(key, request.body, { httpMetadata: { contentType: "application/octet-stream" } });
      return new Response(null, { status: 201 });
    }
    case "GET": {
      const obj = await bucket.get(key);
      if (!obj) return new Response("not found", { status: 404 });
      return new Response(obj.body, { headers: { "Content-Length": String(obj.size), "ETag": obj.httpEtag } });
    }
    case "HEAD": {
      const obj = await bucket.head(key);
      return new Response(null, { status: obj ? 200 : 404, headers: obj ? { "Content-Length": String(obj.size) } : {} });
    }
    case "DELETE": {
      await bucket.delete(key);
      return new Response(null, { status: 204 });
    }
    default:
      return new Response("method not allowed", { status: 405 });
  }
}

/** Confine every key to the backup prefix, with or without the prefix given. */
function scoped(key: string): string {
  const clean = key.replace(/^\/+/, "").replace(/\.\.(\/|$)/g, "");
  return clean.startsWith(BACKUP_PREFIX) ? clean : BACKUP_PREFIX + clean;
}

function withForwardedProto(request: Request): Request {
  const headers = new Headers(request.headers);
  headers.set("X-Forwarded-Proto", "https");
  headers.set("X-Forwarded-Host", new URL(request.url).host);
  return new Request(request, { headers });
}

export default {
  async fetch(request, env): Promise<Response> {
    const url = new URL(request.url);

    if (url.pathname === "/__health") {
      const state = await env.NETBOX.getByName(INSTANCE).status();
      return Response.json({ netbox: state }, { headers: { "Cache-Control": "no-store" } });
    }

    if (url.pathname.startsWith("/static/")) {
      const assetUrl = new URL(request.url);
      assetUrl.pathname = url.pathname.slice("/static".length);
      return env.ASSETS.fetch(new Request(assetUrl, request));
    }

    return env.NETBOX.getByName(INSTANCE).fetch(withForwardedProto(request));
  },

  async scheduled(_controller, env, ctx): Promise<void> {
    ctx.waitUntil(
      (async () => {
        const status = await env.NETBOX.getByName(INSTANCE).keepAlive();
        console.log(`netbox: keepAlive (was ${status})`);
      })(),
    );
  },
} satisfies ExportedHandler<Env>;
