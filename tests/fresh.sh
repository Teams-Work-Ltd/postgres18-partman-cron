#!/usr/bin/env bash
# Initialises empty volumes under common env configurations and checks the extensions work.
# usage: tests/fresh.sh <image>
set -uo pipefail
IMG=$1
C=pgpc-test-fresh
fail=0

chk() { if eval "$2"; then echo "PASS $1"; else echo "FAIL $1"; fail=1; fi; }
q() { docker exec -i $C psql -U "$1" -d "$2" -v ON_ERROR_STOP=1 -Atq "${@:3}"; }
cleanup() { docker rm -f $C >/dev/null 2>&1; docker volume rm $C >/dev/null 2>&1; }

start() {
	cleanup
	docker run -d --name $C -v $C:/var/lib/postgresql -e POSTGRES_PASSWORD=test "$@" "$IMG" >/dev/null
	for _ in $(seq 1 120); do
		[ "$(docker inspect -f '{{.State.Running}}' $C)" = true ] || return 1
		grep -q "init process complete" <<<"$(docker logs $C 2>&1)" \
			&& docker exec $C pg_isready -U "$user" -d postgres -h 127.0.0.1 -q 2>/dev/null && return 0
		sleep 0.5
	done
	return 1
}

# name | superuser | database holding vector/pg_partman | extra docker run args
configs=(
	"defaults|postgres|postgres|"
	"custom POSTGRES_DB|postgres|appdb|-e POSTGRES_DB=appdb"
	"custom POSTGRES_USER, no POSTGRES_DB|app_admin|app_admin|-e POSTGRES_USER=app_admin"
	"custom POSTGRES_USER and POSTGRES_DB=postgres|app_admin|postgres|-e POSTGRES_USER=app_admin -e POSTGRES_DB=postgres"
)

for cfg in "${configs[@]}"; do
	IFS='|' read -r name user db args <<<"$cfg"
	echo "### $name"
	# shellcheck disable=SC2086
	if ! start $args; then
		echo "FAIL $name: container did not initialise"
		docker logs $C 2>&1 | grep -E "ERROR|FATAL" | head -5
		fail=1
		continue
	fi
	chk "init log has no errors" '! docker logs $C 2>&1 | grep -E "ERROR|FATAL" | grep -v "pg_cron launcher\" due to administrator command"'
	chk "shared_preload_libraries" '[ "$(q $user postgres -c "SHOW shared_preload_libraries")" = "pg_cron, pg_stat_statements" ]'
	chk "listens on all interfaces" '[ "$(q $user postgres -c "SHOW listen_addresses")" = "*" ]'
	chk "vector, pg_partman, pg_stat_statements in $db" '[ "$(q $user $db -c "SELECT count(*) FROM pg_extension WHERE extname IN ('"'"'vector'"'"', '"'"'pg_partman'"'"', '"'"'pg_stat_statements'"'"')")" = 3 ]'
	chk "vector, pg_partman in template1" '[ "$(q $user template1 -c "SELECT count(*) FROM pg_extension WHERE extname IN ('"'"'vector'"'"', '"'"'pg_partman'"'"')")" = 2 ]'
	chk "pg_cron in postgres" '[ "$(q $user postgres -c "SELECT count(*) FROM pg_extension WHERE extname = '"'"'pg_cron'"'"'")" = 1 ]'
	chk "partman, pgvector, pg_stat_statements work" 'q $user $db >/dev/null <<SQL
CREATE TABLE ev (id bigint, created_at timestamptz NOT NULL, emb vector(3)) PARTITION BY RANGE (created_at);
SELECT partman.create_parent(p_parent_table := '"'"'public.ev'"'"', p_control := '"'"'created_at'"'"', p_interval := '"'"'1 day'"'"');
INSERT INTO ev VALUES (1, now(), '"'"'[1,2,3]'"'"');
DO \$\$ BEGIN IF (SELECT emb <-> '"'"'[1,2,4]'"'"' FROM ev) <> 1 THEN RAISE EXCEPTION '"'"'vector distance'"'"'; END IF; END \$\$;
SELECT 1 / (count(*) > 0)::int FROM pg_stat_statements;
SQL'
	if [ "$name" = defaults ]; then
		q $user postgres -c "SELECT cron.schedule('pm', '* * * * *', 'CALL partman.run_maintenance_proc()')" >/dev/null
		echo "  waiting for pg_cron to fire"
		sleep 62
		chk "pg_cron job succeeded" '[ "$(q $user postgres -c "SELECT count(*) FROM cron.job_run_details WHERE status = '"'"'succeeded'"'"'")" -ge 1 ]'
	fi
	cleanup
done

echo "### RESULT: $([ $fail = 0 ] && echo ALL PASS || echo FAILURES)"
exit $fail
