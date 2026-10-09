#!/usr/bin/env bash
set -euo pipefail

PRIMARY_DB=${POSTGRES_DB:-${POSTGRES_USER:-postgres}}
PRIMARY_USER=${POSTGRES_USER:-postgres}

psql -v ON_ERROR_STOP=1 --username "$PRIMARY_USER" --dbname "$PRIMARY_DB" <<'SQL'
CREATE EXTENSION IF NOT EXISTS vector;
CREATE SCHEMA IF NOT EXISTS partman;
CREATE EXTENSION IF NOT EXISTS pg_partman WITH SCHEMA partman;
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;
SQL

# pg_cron can only be created in cron.database_name, which 00_configure_extensions.sh sets to postgres
psql -v ON_ERROR_STOP=1 --username "$PRIMARY_USER" --dbname postgres <<'SQL'
CREATE EXTENSION IF NOT EXISTS pg_cron;
SQL

psql -v ON_ERROR_STOP=1 --username "$PRIMARY_USER" --dbname template1 <<'SQL'
CREATE EXTENSION IF NOT EXISTS vector;
CREATE SCHEMA IF NOT EXISTS partman;
CREATE EXTENSION IF NOT EXISTS pg_partman WITH SCHEMA partman;
SQL
