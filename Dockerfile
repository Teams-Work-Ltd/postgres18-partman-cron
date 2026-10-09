# syntax=docker/dockerfile:1.9
FROM cgr.dev/chainguard/wolfi-base:latest

LABEL org.opencontainers.image.source="https://github.com/Teams-Work-Ltd/postgres18-partman-cron" \
    org.opencontainers.image.description="Postgres 18 with pg_partman, pg_cron, and pgvector pre-installed."

ARG PG_MAJOR=18
ARG PG_PARTMAN_VERSION=5.5.0
ARG PG_CRON_VERSION=1.6.8
ARG PGVECTOR_VERSION=0.8.7

# uid/gid 999, PGDATA and the volume path match the official Debian postgres image, so volumes created by
# the earlier Debian-based releases of this image mount as-is
RUN set -eux; \
    echo 'postgres:x:999:999:PostgreSQL:/var/lib/postgresql:/bin/bash' >> /etc/passwd; \
    echo 'postgres:x:999:' >> /etc/group; \
    apk upgrade --no-cache; \
    apk add --no-cache \
        bash glibc-locale-en tzdata \
        "postgresql-${PG_MAJOR}" \
        "postgresql-${PG_MAJOR}-client" \
        "postgresql-${PG_MAJOR}-contrib" \
        "postgresql-${PG_MAJOR}-oci-entrypoint-compat" \
        "pg-partman-${PG_MAJOR}~${PG_PARTMAN_VERSION}" \
        "pg_cron-${PG_MAJOR}~${PG_CRON_VERSION}" \
        "pgvector-${PG_MAJOR}~${PGVECTOR_VERSION}"; \
    mkdir -p /var/lib/postgresql /var/run/postgresql /docker-entrypoint-initdb.d; \
    chown -R postgres:postgres /var/lib/postgresql /var/run/postgresql; \
    chmod 3777 /var/run/postgresql

ENV PATH=/usr/libexec/postgresql${PG_MAJOR}:$PATH \
    LANG=en_US.utf8 \
    PG_MAJOR=${PG_MAJOR} \
    PGDATA=/var/lib/postgresql/${PG_MAJOR}/docker \
    PG_PARTMAN_VERSION=${PG_PARTMAN_VERSION} \
    PG_CRON_VERSION=${PG_CRON_VERSION} \
    PGVECTOR_VERSION=${PGVECTOR_VERSION}

COPY --chmod=755 docker-entrypoint-initdb.d/*.sh /docker-entrypoint-initdb.d/
COPY --chmod=755 docker-upgrade-entrypoint.sh /usr/local/bin/

VOLUME /var/lib/postgresql
STOPSIGNAL SIGINT
EXPOSE 5432
ENTRYPOINT ["docker-upgrade-entrypoint.sh"]
CMD ["postgres"]
