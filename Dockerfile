# syntax=docker/dockerfile:1.9
FROM postgres:18

LABEL org.opencontainers.image.source="https://github.com/Teams-Work-Ltd/postgres18-partman-cron" \
    org.opencontainers.image.description="Postgres 18 with pg_partman and pg_cron pre-installed."

ARG PG_PARTMAN_VERSION=v4.7.1
ARG PG_CRON_VERSION=v1.6.2
ARG BUILD_DEPS="build-essential ca-certificates curl libpq-dev postgresql-server-dev-18 pkg-config libssl-dev libkrb5-dev libicu-dev cmake"

ENV PG_PARTMAN_VERSION=${PG_PARTMAN_VERSION} \
    PG_CRON_VERSION=${PG_CRON_VERSION}

RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends $BUILD_DEPS; \
    update-ca-certificates

# Build pg_partman
RUN set -eux; \
    mkdir -p /tmp/build && cd /tmp/build; \
    curl -fsSL "https://github.com/pgpartman/pg_partman/archive/refs/tags/${PG_PARTMAN_VERSION}.tar.gz" -o pg_partman.tar.gz; \
    tar -xzf pg_partman.tar.gz; \
    cd pg_partman-${PG_PARTMAN_VERSION#v}; \
    make && make install; \
    cd /; \
    rm -rf /tmp/build

# Build pg_cron
RUN set -eux; \
    mkdir -p /tmp/build && cd /tmp/build; \
    curl -fsSL "https://github.com/citusdata/pg_cron/archive/refs/tags/${PG_CRON_VERSION}.tar.gz" -o pg_cron.tar.gz; \
    tar -xzf pg_cron.tar.gz; \
    cd pg_cron-${PG_CRON_VERSION#v}; \
    make && make install; \
    cd /; \
    rm -rf /tmp/build

# Remove build dependencies
RUN set -eux; \
    apt-get purge -y --auto-remove $BUILD_DEPS; \
    rm -rf /var/lib/apt/lists/*

COPY docker-entrypoint-initdb.d/*.sh /docker-entrypoint-initdb.d/
RUN chmod +x /docker-entrypoint-initdb.d/*.sh
