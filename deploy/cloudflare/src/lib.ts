/**
 * Pure helpers for the Worker, kept free of Cloudflare runtime types so they can
 * be unit-tested with plain vitest.
 */

/** Every R2 key the container may touch lives under this prefix. */
export const BACKUP_PREFIX = "backup/";

/** Confine a key to the backup prefix, with or without the prefix given. */
export function scoped(key: string): string {
  const clean = key.replace(/^\/+/, "").replace(/\.\.(\/|$)/g, "");
  return clean.startsWith(BACKUP_PREFIX) ? clean : BACKUP_PREFIX + clean;
}

/** True when the request carries the configured admin token. An unset token disables the admin routes. */
export function isAdminAuthorized(request: Request, adminToken: string | undefined): boolean {
  return Boolean(adminToken) && request.headers.get("X-Admin-Token") === adminToken;
}

/** Map /static/<path> to the asset path served by Workers Static Assets. */
export function staticAssetUrl(requestUrl: string): URL {
  const url = new URL(requestUrl);
  url.pathname = url.pathname.slice("/static".length);
  return url;
}
