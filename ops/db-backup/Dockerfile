# Nightly off-host Postgres backups (KAN-46). The client major version must
# match the postgres image in docker-compose.prod.yml — pg_dump refuses to
# dump a newer server, which fails the run and trips the healthcheck ping.
FROM alpine:3.20

RUN apk add --no-cache bash coreutils postgresql16-client rclone curl ca-certificates

COPY backup.sh scheduler.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/backup.sh /usr/local/bin/scheduler.sh

ENTRYPOINT ["/usr/local/bin/scheduler.sh"]
