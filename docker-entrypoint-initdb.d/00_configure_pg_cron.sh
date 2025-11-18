#!/usr/bin/env bash
set -euo pipefail

PRIMARY_DB=postgres
PRIMARY_USER=${POSTGRES_USER:-postgres}

psql -v ON_ERROR_STOP=1 --username "$PRIMARY_USER" --dbname postgres <<SQL
ALTER SYSTEM SET shared_preload_libraries = 'pg_cron';
ALTER SYSTEM SET cron.database_name = '${PRIMARY_DB}';
SQL

pg_ctl -D "$PGDATA" -m fast restart >/dev/null 2>&1

until pg_isready -U "$PRIMARY_USER" -d "$PRIMARY_DB" >/dev/null 2>&1; do
	sleep 1
done
