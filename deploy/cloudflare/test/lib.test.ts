import { describe, expect, it } from "vitest";
import { BACKUP_PREFIX, isAdminAuthorized, scoped, staticAssetUrl } from "../src/lib";

describe("scoped", () => {
  it("prefixes bare keys", () => {
    expect(scoped("wal/0001")).toBe("backup/wal/0001");
  });
  it("keeps keys that already carry the prefix", () => {
    expect(scoped("backup/base/LATEST")).toBe("backup/base/LATEST");
  });
  it("strips leading slashes", () => {
    expect(scoped("///base/LATEST")).toBe("backup/base/LATEST");
  });
  it("cannot escape the prefix with ..", () => {
    expect(scoped("../secrets")).toBe("backup/secrets");
    expect(scoped("backup/../../x")).toBe("backup/x");
    expect(scoped("backup/a/..")).toBe("backup/a/");
    expect(scoped("..")).toBe(BACKUP_PREFIX);
  });
  it("never returns a key outside the prefix", () => {
    for (const k of ["", "/", "..", "../", "backup", "backupx/y", "/../../etc/passwd"]) {
      expect(scoped(k).startsWith(BACKUP_PREFIX)).toBe(true);
    }
  });
});

describe("isAdminAuthorized", () => {
  const withToken = (t?: string) =>
    new Request("https://example.test/__admin/diag", { headers: t === undefined ? {} : { "X-Admin-Token": t } });
  it("rejects everything when no token is configured", () => {
    expect(isAdminAuthorized(withToken("x"), undefined)).toBe(false);
    expect(isAdminAuthorized(withToken(""), "")).toBe(false);
  });
  it("rejects a missing or wrong header", () => {
    expect(isAdminAuthorized(withToken(), "secret")).toBe(false);
    expect(isAdminAuthorized(withToken("nope"), "secret")).toBe(false);
  });
  it("accepts the exact token", () => {
    expect(isAdminAuthorized(withToken("secret"), "secret")).toBe(true);
  });
});

describe("staticAssetUrl", () => {
  it("drops the /static prefix and keeps the query", () => {
    expect(staticAssetUrl("https://h/static/netbox.css?v=1").pathname).toBe("/netbox.css");
    expect(staticAssetUrl("https://h/static/netbox.css?v=1").search).toBe("?v=1");
  });
});
