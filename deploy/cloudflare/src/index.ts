/**
 * Cloudflare Worker fronting NetBox on Cloudflare Containers.
 *
 *  - /static/*   -> Workers Static Assets (collectstatic output)
 *  - /__health   -> container state without waking the web tier
 *  - everything  -> NetBoxWeb container (gunicorn on 8001)
 *  - cron        -> keeps NetBoxWorker (rqworker) running
 *
 * Both container classes share one image; NETBOX_ROLE selects the process.
 */
import { Container, getContainer } from "@cloudflare/containers";
import type { DurableObject } from "cloudflare:workers";

// Bindings and vars come from the generated worker-configuration.d.ts (`wrangler types`).
// Secrets are not in wrangler.jsonc, so they are merged into the global Env here.
declare global {
  interface Env {
    SECRET_KEY: string;
    DATABASE_URL: string;
    REDIS_TASKS_URL: string;
    REDIS_CACHE_URL: string;
    R2_ACCESS_KEY_ID?: string;
    R2_SECRET_ACCESS_KEY?: string;
    API_TOKEN_PEPPERS?: string;
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
  "DATABASE_URL",
  "REDIS_TASKS_URL",
  "REDIS_CACHE_URL",
  "R2_BUCKET",
  "R2_ENDPOINT",
  "R2_ACCESS_KEY_ID",
  "R2_SECRET_ACCESS_KEY",
  "API_TOKEN_PEPPERS",
  "TIME_ZONE",
  // Local development only (.dev.vars): plain-HTTP cookies and non-TLS Postgres.
  "COOKIE_SECURE",
  "DB_SSLMODE",
] as const;

const WEB_PORT = 8001;
const WORKER_HEALTH_PORT = 8002;
const WEB_INSTANCE = "primary";
const WORKER_INSTANCE = "primary";
// Migrations run on web start; the first boot against an empty database can take minutes.
const WEB_STARTUP_TIMEOUT_MS = 10 * 60 * 1000;
// The worker waits for the web instance's migrations before it opens its health port.
const WORKER_STARTUP_TIMEOUT_MS = 15 * 60 * 1000;

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

function containerEnv(env: Env, role: "web" | "worker"): Record<string, string> {
  const vars: Record<string, string> = {
    NETBOX_ROLE: role,
    PORT: String(WEB_PORT),
    WORKER_HEALTH_PORT: String(WORKER_HEALTH_PORT),
  };
  for (const name of FORWARDED_ENV) {
    const value: unknown = env[name];
    if (typeof value === "string" && value.length > 0) {
      vars[name] = value;
    }
  }
  return vars;
}

/** gunicorn web tier. Singleton; migrations run in its entrypoint. */
export class NetBoxWeb extends Container<Env> {
  defaultPort = WEB_PORT;
  requiredPorts = [WEB_PORT];
  // Long idle window: a cold start re-runs migrations and boots gunicorn.
  sleepAfter = "2h";
  enableInternet = true;

  constructor(ctx: DurableObjectCtx, env: Env) {
    super(ctx, env);
    this.envVars = containerEnv(env, "web");
  }

  override onStart(): void {
    console.log("netbox-web: container started");
  }

  override onStop({ exitCode, reason }: { exitCode: number; reason: string }): void {
    console.log(`netbox-web: container stopped (exit ${exitCode}, ${reason})`);
  }

  override onError(error: unknown): never {
    console.error("netbox-web: container error", error);
    throw error;
  }

  override async fetch(request: Request): Promise<Response> {
    if (!this.ctx.container?.running) {
      const t0 = Date.now();
      await this.startAndWaitForPorts(startupWait(WEB_PORT, WEB_STARTUP_TIMEOUT_MS));
      console.log(`netbox-web: cold start took ${Date.now() - t0}ms`);
    }
    // Passing the original Request keeps its absolute URL, so Django sees the
    // public hostname in Host and ALLOWED_HOSTS applies as configured.
    return this.containerFetch(request, WEB_PORT);
  }

  /** Called from the cron trigger when WEB_ALWAYS_ON is enabled. */
  async keepWarm(): Promise<void> {
    await this.startAndWaitForPorts(startupWait(WEB_PORT, WEB_STARTUP_TIMEOUT_MS));
    await this.renewActivityTimeout();
  }

  async status() {
    return this.getState();
  }
}

/** RQ background worker. Exposes only a readiness port; kept alive by the cron trigger. */
export class NetBoxWorker extends Container<Env> {
  defaultPort = WORKER_HEALTH_PORT;
  requiredPorts = [WORKER_HEALTH_PORT];
  // Cron renews this every 5 minutes, so 30m only matters if the trigger stalls.
  sleepAfter = "30m";
  enableInternet = true;

  constructor(ctx: DurableObjectCtx, env: Env) {
    super(ctx, env);
    this.envVars = containerEnv(env, "worker");
  }

  override onStart(): void {
    console.log("netbox-worker: container started");
  }

  override onStop({ exitCode, reason }: { exitCode: number; reason: string }): void {
    console.log(`netbox-worker: container stopped (exit ${exitCode}, ${reason})`);
  }

  override onError(error: unknown): never {
    console.error("netbox-worker: container error", error);
    throw error;
  }

  /** Start if stopped and push the idle deadline out. */
  async keepAlive(): Promise<string> {
    const before = (await this.getState()).status;
    if (!this.ctx.container?.running) {
      await this.startAndWaitForPorts(startupWait(WORKER_HEALTH_PORT, WORKER_STARTUP_TIMEOUT_MS));
    }
    await this.renewActivityTimeout();
    return before;
  }

  async status() {
    return this.getState();
  }
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
      const [web, worker] = await Promise.all([
        getContainer(env.NETBOX_WEB, WEB_INSTANCE).status(),
        getContainer(env.NETBOX_WORKER, WORKER_INSTANCE).status(),
      ]);
      return Response.json({ web, worker }, { headers: { "Cache-Control": "no-store" } });
    }

    if (url.pathname.startsWith("/static/")) {
      const assetUrl = new URL(request.url);
      assetUrl.pathname = url.pathname.slice("/static".length);
      return env.ASSETS.fetch(new Request(assetUrl, request));
    }

    return getContainer(env.NETBOX_WEB, WEB_INSTANCE).fetch(withForwardedProto(request));
  },

  async scheduled(_controller, env, ctx): Promise<void> {
    ctx.waitUntil(
      (async () => {
        const status = await getContainer(env.NETBOX_WORKER, WORKER_INSTANCE).keepAlive();
        console.log(`netbox-worker: keepAlive (was ${status})`);
        if ((env.WEB_ALWAYS_ON as string) === "true") {
          await getContainer(env.NETBOX_WEB, WEB_INSTANCE).keepWarm();
        }
      })(),
    );
  },
} satisfies ExportedHandler<Env>;
