# syntax=docker/dockerfile:1.9
ARG PG_MAJOR=18
FROM cgr.dev/chainguard/wolfi-base:latest AS base

# Use the same PostgreSQL packages when compiling and running the extension.
RUN apk upgrade --no-cache

FROM base AS hint-builder
ARG PG_MAJOR
ARG PG_HINT_PLAN_VERSION=1.8.1
ARG PG_HINT_PLAN_SHA256=a4fca485e54fe8e67f9104595ab254aee17cf766d0f261666f5079965d225f6a

RUN set -eux; \
    apk add --no-cache build-base curl flex "postgresql-${PG_MAJOR}-dev"; \
    tag="REL${PG_MAJOR}_$(echo "$PG_HINT_PLAN_VERSION" | tr . _)"; \
    curl --fail --location --retry 3 \
        "https://codeload.github.com/ossc-db/pg_hint_plan/tar.gz/refs/tags/${tag}" \
        -o /tmp/pg_hint_plan.tar.gz; \
    echo "${PG_HINT_PLAN_SHA256}  /tmp/pg_hint_plan.tar.gz" | sha256sum -c -; \
    mkdir /tmp/pg_hint_plan; \
    tar -xzf /tmp/pg_hint_plan.tar.gz -C /tmp/pg_hint_plan --strip-components=1; \
    export PATH="/usr/libexec/postgresql${PG_MAJOR}:$PATH"; \
    cd /tmp/pg_hint_plan; \
    make -j"$(nproc)" with_llvm=no; \
    make install with_llvm=no DESTDIR=/extension; \
    mkdir -p /extension/usr/share/licenses/pg_hint_plan; \
    cp COPYRIGHT /extension/usr/share/licenses/pg_hint_plan/

FROM base

LABEL org.opencontainers.image.source="https://github.com/Teams-Work-Ltd/postgres18-partman-cron" \
    org.opencontainers.image.description="Postgres 18 with pg_partman, pg_cron, pgvector, and pg_hint_plan pre-installed."

ARG PG_MAJOR
ARG PG_PARTMAN_VERSION=5.5.1
ARG PG_CRON_VERSION=1.6.8
ARG PGVECTOR_VERSION=0.8.7
ARG PG_HINT_PLAN_VERSION=1.8.1

# uid/gid 999, PGDATA and the volume path match the official Debian postgres image, so volumes created by
# the earlier Debian-based releases of this image mount as-is
RUN set -eux; \
    echo 'postgres:x:999:999:PostgreSQL:/var/lib/postgresql:/bin/bash' >> /etc/passwd; \
    echo 'postgres:x:999:' >> /etc/group; \
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
    PGVECTOR_VERSION=${PGVECTOR_VERSION} \
    PG_HINT_PLAN_VERSION=${PG_HINT_PLAN_VERSION}

COPY --from=hint-builder /extension/ /
COPY --chmod=755 docker-entrypoint-initdb.d/*.sh /docker-entrypoint-initdb.d/
COPY --chmod=755 docker-upgrade-entrypoint.sh /usr/local/bin/

VOLUME /var/lib/postgresql
STOPSIGNAL SIGINT
EXPOSE 5432
ENTRYPOINT ["docker-upgrade-entrypoint.sh"]
CMD ["postgres"]
