#!/usr/bin/env bash
set -euo pipefail

PRIMARY_DB=${POSTGRES_DB:-${POSTGRES_USER:-postgres}}
PRIMARY_USER=${POSTGRES_USER:-postgres}

psql -v ON_ERROR_STOP=1 --username "$PRIMARY_USER" --dbname "$PRIMARY_DB" <<'SQL'
CREATE SCHEMA IF NOT EXISTS partman;
CREATE EXTENSION IF NOT EXISTS pg_partman WITH SCHEMA partman;
CREATE EXTENSION IF NOT EXISTS pg_cron;
SQL

psql -v ON_ERROR_STOP=1 --username "$PRIMARY_USER" --dbname template1 <<'SQL'
CREATE SCHEMA IF NOT EXISTS partman;
CREATE EXTENSION IF NOT EXISTS pg_partman WITH SCHEMA partman;
SQL
