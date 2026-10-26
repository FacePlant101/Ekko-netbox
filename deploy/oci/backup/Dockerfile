# pg_dump/pg_restore matching the database's major version, plus rclone for R2.
# rclone comes from its own image: Debian's 1.60 fails R2 uploads with 501
# NotImplemented. The binary is static, so it runs on the Debian base.
FROM rclone/rclone:1.75.2 AS rclone

FROM postgres:17.11-bookworm
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates \
    && rm -rf /var/lib/apt/lists/*
COPY --from=rclone /usr/local/bin/rclone /usr/local/bin/rclone
COPY backup.sh restore.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/backup.sh /usr/local/bin/restore.sh
ENTRYPOINT []
CMD ["backup.sh"]
