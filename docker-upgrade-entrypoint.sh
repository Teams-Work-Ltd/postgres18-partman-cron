#!/usr/bin/env bash
# Wraps the stock docker-entrypoint.sh. When an existing data directory was last used with a
# different glibc, Postgres or extension build, it starts a socket-only temp server once to
# verify text indexes, refresh collation versions and update extensions, then hands off.
# Set PG_AUTO_UPGRADE=false to skip.
set -Eeo pipefail
source /usr/local/bin/docker-entrypoint.sh

upgrade_sql=$(cat <<'SQL'
DO $do$
DECLARE
	r record;
	created_amcheck boolean := false;
	coll_changed boolean;
BEGIN
	coll_changed := EXISTS (
			SELECT 1 FROM pg_database
			WHERE datname = current_database() AND datlocprovider = 'c'
				AND datcollversion IS DISTINCT FROM pg_database_collation_actual_version(oid))
		OR EXISTS (
			SELECT 1 FROM pg_collation
			WHERE collprovider = 'c' AND collversion IS NOT NULL
				AND collversion IS DISTINCT FROM pg_collation_actual_version(oid));

	IF coll_changed THEN
		IF NOT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'amcheck') THEN
			CREATE EXTENSION amcheck;
			created_amcheck := true;
		END IF;

		-- every btree index ordered by a libc collation must still be in order under the new glibc
		FOR r IN
			SELECT DISTINCT c.oid::regclass AS idx
			FROM pg_index i
			JOIN pg_class c ON c.oid = i.indexrelid AND c.relkind = 'i' AND c.relpersistence <> 't'
			JOIN pg_am am ON am.oid = c.relam AND am.amname = 'btree'
			CROSS JOIN LATERAL unnest(i.indcollation::oid[]) AS ic(coll)
			JOIN pg_collation co ON co.oid = ic.coll
			JOIN pg_database d ON d.datname = current_database()
			WHERE i.indisvalid AND i.indisready
				AND ((co.collprovider = 'd' AND d.datlocprovider = 'c' AND d.datcollate NOT IN ('C', 'POSIX') AND d.datcollate NOT ILIKE 'C.%')
					OR (co.collprovider = 'c' AND co.collcollate NOT IN ('C', 'POSIX') AND co.collcollate NOT ILIKE 'C.%'))
		LOOP
			BEGIN
				PERFORM bt_index_check(r.idx, false);
			EXCEPTION WHEN OTHERS THEN
				RAISE WARNING 'index % failed amcheck under new collation (%), reindexing', r.idx, SQLERRM;
				EXECUTE format('REINDEX INDEX %s', r.idx);
			END;
		END LOOP;

		IF created_amcheck THEN
			DROP EXTENSION amcheck;
		END IF;

		IF EXISTS (SELECT 1 FROM pg_database WHERE datname = current_database() AND datlocprovider = 'c'
				AND datcollversion IS DISTINCT FROM pg_database_collation_actual_version(oid)) THEN
			EXECUTE format('ALTER DATABASE %I REFRESH COLLATION VERSION', current_database());
		END IF;
		FOR r IN
			SELECT oid::regcollation AS coll FROM pg_collation
			WHERE collprovider = 'c' AND collversion IS NOT NULL
				AND collversion IS DISTINCT FROM pg_collation_actual_version(oid)
		LOOP
			EXECUTE format('ALTER COLLATION %s REFRESH VERSION', r.coll);
		END LOOP;
	END IF;

	FOR r IN
		SELECT e.extname, e.extversion, a.default_version
		FROM pg_extension e
		JOIN pg_available_extensions a ON a.name = e.extname
		WHERE e.extversion IS DISTINCT FROM a.default_version
	LOOP
		EXECUTE format('ALTER EXTENSION %I UPDATE', r.extname);
		RAISE NOTICE 'updated extension % from % to %', r.extname, r.extversion, r.default_version;
	END LOOP;
END
$do$;
SQL
)

auto_upgrade() {
	local db failed=
	export PGPASSWORD="${PGPASSWORD:-$POSTGRES_PASSWORD}"
	export PGUSER="${PGUSER:-$POSTGRES_USER}"
	docker_temp_server_start "$@" || failed=1
	if [ -z "$failed" ]; then
		mapfile -t dbs < <(psql --no-psqlrc --no-password -Atc "SELECT datname FROM pg_database WHERE datallowconn ORDER BY datname" -d postgres) || failed=1
		for db in "${dbs[@]}"; do
			echo "  upgrading database: $db"
			psql -v ON_ERROR_STOP=1 --no-psqlrc --no-password -q -d "$db" <<<"$upgrade_sql" || failed=1
		done
		docker_temp_server_stop || failed=1
	fi
	unset PGPASSWORD PGUSER
	[ -z "$failed" ] && echo "$stamp" > "$stamp_file"
}

if [ "${1:0:1}" = '-' ]; then
	set -- postgres "$@"
fi

if [ "$1" = 'postgres' ] && ! _pg_want_help "$@" && [ "${PG_AUTO_UPGRADE:-true}" = 'true' ]; then
	docker_setup_env
	if [ "$(id -u)" = '0' ]; then
		docker_create_db_directories
		exec gosu postgres "$BASH_SOURCE" "$@"
	fi

	# fingerprint of everything that can invalidate collations or extension versions: libc, server, extension control files
	libc=$(grep -m1 -oE '/[^ ]*libc\.so\.6' /proc/$$/maps) || true
	stamp="$(md5sum "$libc" | cut -c1-12) | $(postgres -V) | $(find /usr/share/postgresql* -path '*/extension/*.control' -exec cat {} + | md5sum | cut -c1-12)" || true
	stamp_file="$PGDATA/.image-upgrade-stamp"
	if [ -n "$DATABASE_ALREADY_EXISTS" ] && [ "$(cat "$stamp_file" 2>/dev/null)" != "$stamp" ]; then
		echo "Image changed since this data directory was last upgraded; checking collations and extensions"
		auto_upgrade "$@" || echo "WARNING: auto-upgrade did not complete, starting anyway; it will retry on next start" >&2
	fi
fi

exec docker-entrypoint.sh "$@"
