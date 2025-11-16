#!/usr/bin/env bash
set -euo pipefail

PRIMARY_DB=${POSTGRES_DB:-${POSTGRES_USER:-postgres}}

cat >>"${PGDATA}/postgresql.conf" <<EOF

# Auto-configured by docker-entrypoint-initdb.d/00_configure_pg_cron.sh
shared_preload_libraries = 'pg_cron'
cron.database_name = '${PRIMARY_DB}'
EOF
