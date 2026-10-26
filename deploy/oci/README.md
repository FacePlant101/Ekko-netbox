# NetBox on Oracle Cloud (OCI)

NetBox runs on one Ampere A1 VM in `eu-frankfurt-1` (the tenancy's home region,
where Always Free resources live) with Docker Compose. It replaces the Cloudflare
Containers deployment in `deploy/cloudflare/`, using the same image.

```
browser ──> Cloudflare (netbox.lydfirmaetekko.no, TLS)
              └── Cloudflare Tunnel ──> cloudflared ──> nginx ──> netbox (gunicorn)
                                         (outbound only)  /static     ├── postgres 17
                                                                       └── redis
            worker (rqworker) ──> postgres, redis
            systemd timer (02:30) ──> backup ──> R2 bucket netbox-media/oci/<timestamp>/
```

- **Shape:** `VM.Standard.A1.Flex`, 2 OCPU / 12 GB, 50 GB boot volume. All of it is
  inside the Always Free allowance (4 OCPU, 24 GB, 200 GB block storage), so the VM
  costs nothing. R2 storage for the backups is a few cents a month.
- **No inbound ports** except SSH from one admin address. The tunnel connects out
  to Cloudflare, which keeps the domain, TLS and (optionally) Cloudflare Access.
- **Data** lives in Docker volumes on the boot volume: `pgdata`, `redisdata`,
  `media`, `scripts`, `reports`.
- **Backups:** nightly `pg_dump` plus media and scripts to R2 under `oci/`, newest
  14 kept. `oci/LATEST` names the newest one.

## 1. Prerequisites

- A working OCI CLI: `oci iam region list` must succeed.
- An **R2 API token** (Cloudflare dashboard → R2 → Manage API tokens) with *Object
  Read & Write* on `netbox-media`. Note the access key ID and secret.
- A **Cloudflare Tunnel** (Zero Trust → Networks → Tunnels → Create, type
  cloudflared). Copy its token. Public hostnames are added in step 4 and 6.
- The current Worker secret values `SECRET_KEY`, `API_TOKEN_PEPPERS` and
  `ADMIN_TOKEN` (wrangler cannot read them back; use the copies you stored).

## 2. Provision the VM

From this directory on a workstation:

```bash
ADMIN_CIDR="$(curl -s https://ifconfig.me)/32" ./provision.sh
```

It creates `netbox-vcn`, an internet gateway, a security list (SSH from
`ADMIN_CIDR` only), a public subnet and the instance `netbox`, then prints the
public IP. cloud-init installs Docker, clones this repository's current branch to
`/opt/netbox-oci` and enables the backup timer. Wait for it to finish:

```bash
ssh -i ~/.ssh/oracle_cloud_key ubuntu@<ip> cloud-init status --wait
```

"Out of host capacity" means there is no free A1 capacity in the region at the
moment. Retry later, or upgrade the tenancy to Pay As You Go (A1 stays free within
the Always Free limits and capacity is much easier to get).

## 3. Configure and start

On the VM, in `/opt/netbox-oci/deploy/oci`, create `.env`, `netbox.env`,
`tunnel.env` and `backup.env` from the blocks in `env.example` (`chmod 600`).
For the trial run, add the trial hostname too:

```
ALLOWED_HOSTS=netbox.lydfirmaetekko.no,netbox-oci.lydfirmaetekko.no,localhost,127.0.0.1
CSRF_TRUSTED_ORIGINS=https://netbox.lydfirmaetekko.no,https://netbox-oci.lydfirmaetekko.no
```

Then build and start. The first build compiles the image on the VM and takes
10 to 20 minutes:

```bash
docker compose up -d --build
docker compose ps
docker compose logs -f netbox
```

## 4. Trial on a separate hostname

In the tunnel, add the public hostname `netbox-oci.lydfirmaetekko.no` with service
`http://nginx:80`. Restore the latest Cloudflare data (step 5, without the freeze)
and check NetBox at https://netbox-oci.lydfirmaetekko.no while the Cloudflare
instance keeps serving the real hostname.

## 5. Move the data

1. Tell users not to make changes until the cutover is done.
2. Export from the Cloudflare deployment. This dumps the live database and media to
   R2 under `backup/export/<timestamp>/` and prints the result:

   ```bash
   curl -X POST -H "X-Admin-Token: $ADMIN_TOKEN" https://netbox.lydfirmaetekko.no/__admin/export
   ```

3. On the VM, restore it and start NetBox again (the web container applies any
   pending migrations on start):

   ```bash
   docker compose stop netbox worker
   docker compose run --rm backup restore.sh export --yes
   docker compose up -d
   ```

## 6. Cut over the hostname

1. Remove the Worker's custom domain: Workers & Pages → `netbox` → Settings →
   Domains & Routes → remove `netbox.lydfirmaetekko.no`. The hostname is down from
   here until the next step.
2. In the tunnel, add the public hostname `netbox.lydfirmaetekko.no` →
   `http://nginx:80`. Cloudflare creates the DNS record.
3. Check login, a few objects, and an API call with an existing token.

## 7. Backups

The timer runs `docker compose run --rm backup` nightly. Run one now and check it:

```bash
sudo systemctl start netbox-backup.service
journalctl -u netbox-backup.service -n 20
```

Restore the newest nightly backup (for example onto a fresh VM):

```bash
docker compose stop netbox worker
docker compose run --rm backup restore.sh backup --yes
docker compose up -d
```

`restore.sh oci/<timestamp> --yes` restores a specific backup.

## 8. Updates

```bash
cd /opt/netbox-oci && git pull
cd deploy/oci && docker compose up -d --build
```

## 9. Retire the Cloudflare deployment

Once NetBox has run on OCI for a while: stop the container's cron keep-alive and
delete the Worker (`npx wrangler delete` in `deploy/cloudflare/`), which also stops
the container billing. Keep the `netbox-media` bucket: it holds the OCI backups.
The old `backup/` prefix (Cloudflare WAL and base backups, and the export) can be
deleted after that.
