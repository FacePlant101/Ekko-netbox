# pg_dump/pg_restore matching the database's major version, plus rclone for R2.
FROM postgres:17.11-bookworm
RUN apt-get update && apt-get install -y --no-install-recommends rclone ca-certificates \
    && rm -rf /var/lib/apt/lists/*
COPY backup.sh restore.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/backup.sh /usr/local/bin/restore.sh
ENTRYPOINT []
CMD ["backup.sh"]
