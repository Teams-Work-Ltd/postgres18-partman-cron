#!/usr/bin/env bash
# Creates a volume with a previous release, then swaps only the image and checks it upgrades itself.
# usage: tests/upgrade.sh <image> [previous image]
set -uo pipefail
IMG=$1
OLD=${2:-ghcr.io/teams-work-ltd/postgres18-partman-cron:v1.0.2}
C=pgpc-test-upgrade
U=app_admin
ARGS=(postgres -c shared_buffers=256MB -c max_connections=200 -c shared_preload_libraries=pg_cron,pg_stat_statements -c jit=off)
fail=0

chk() { if eval "$2"; then echo "PASS $1"; else echo "FAIL $1"; fail=1; fi; }
q() { docker exec -i $C psql -U $U -d "$1" -v ON_ERROR_STOP=1 -Atq "${@:2}"; }
exts() { q "$1" -c "SELECT string_agg(extname || ' ' || extversion, ', ' ORDER BY extname) FROM pg_extension"; }
stop() { docker stop $C >/dev/null; docker rm $C >/dev/null; }

run() {
	docker run -d --name $C -v $C:/var/lib/postgresql --shm-size 256m \
		-e POSTGRES_USER=$U -e POSTGRES_PASSWORD=test -e POSTGRES_DB=postgres "$1" "${ARGS[@]}" >/dev/null
	for _ in $(seq 1 120); do
		[ "$(docker inspect -f '{{.State.Running}}' $C)" = true ] || break
		l=$(docker logs $C 2>&1)
		grep -q "database system is ready to accept connections" <<<"$l" \
			&& grep -qE "init process complete|Skipping initialization" <<<"$l" \
			&& docker exec $C pg_isready -U $U -d postgres -q 2>/dev/null && return 0
		sleep 0.5
	done
	echo "FAIL $1 did not start"
	docker logs $C 2>&1 | tail -20
	docker rm -f $C >/dev/null 2>&1; docker volume rm $C >/dev/null 2>&1
	exit 1
}

docker rm -f $C >/dev/null 2>&1; docker volume rm $C >/dev/null 2>&1

echo "### seed volume with $OLD"
run "$OLD"
q postgres <<'SQL'
CREATE TABLE events (id bigint, created_at timestamptz NOT NULL, note text) PARTITION BY RANGE (created_at);
SELECT partman.create_parent(p_parent_table := 'public.events', p_control := 'created_at', p_interval := '1 day') \g /dev/null
INSERT INTO events SELECT g, now() - (g || ' hours')::interval, 'n' || g FROM generate_series(1, 48) g;
SELECT cron.schedule('pm', '* * * * *', 'CALL partman.run_maintenance_proc()') \g /dev/null
-- every BMP character, alone and embedded, to catch collation ordering changes between libc builds
CREATE TABLE corpus (s text);
INSERT INTO corpus SELECT chr(i) FROM generate_series(1, 65535) i WHERE i NOT BETWEEN 55296 AND 57343;
INSERT INTO corpus SELECT 'a' || chr(i) || 'b' FROM generate_series(32, 65535) i WHERE i NOT BETWEEN 55296 AND 57343;
CREATE INDEX corpus_s ON corpus (s);
CREATE DATABASE tenant_a;
SQL
q tenant_a <<'SQL'
CREATE TABLE docs (id int, title text, emb vector(3));
INSERT INTO docs SELECT g, md5(g::text) || ' Title ' || chr(65 + g % 58), ARRAY[g, g + 1, g + 2]::vector FROM generate_series(1, 5000) g;
CREATE INDEX docs_title ON docs (title);
-- built in C order then relabelled en_US.utf8, so it is misordered and the upgrade must reindex it
CREATE TABLE bad (s text);
INSERT INTO bad SELECT x FROM unnest(ARRAY['a', 'B', 'c', 'D', 'e', 'F', 'g', 'H']) x;
CREATE INDEX bad_s ON bad (s COLLATE "C");
UPDATE pg_index SET indcollation = (SELECT oid FROM pg_collation WHERE collname = 'en_US.utf8')::text::oidvector
WHERE indexrelid = 'bad_s'::regclass;
SQL
for db in postgres tenant_a template1; do echo "  $db: $(exts $db)"; done
stop

echo "### swap to $IMG"
run "$IMG"
docker logs $C 2>&1 | grep -E "Image changed|upgrading database|updated extension|reindexing|auto-upgrade" | sort -u | sed 's/^/  /'
chk "healthcheck" 'docker exec $C pg_isready -U $U -d postgres -q'
for db in postgres tenant_a template1; do
	echo "  $db: $(exts $db)"
	chk "$db: no warnings on connect" '[ -z "$(docker exec $C psql -U $U -d $db -Atc "SELECT 1" 2>&1 >/dev/null)" ]'
	chk "$db: no outdated extensions" '[ "$(q $db -c "SELECT count(*) FROM pg_extension e JOIN pg_available_extensions a ON a.name = e.extname WHERE e.extversion <> a.default_version")" = 0 ]'
done
chk "temporary amcheck extension removed" '[ "$(q tenant_a -c "SELECT count(*) FROM pg_extension WHERE extname = '"'"'amcheck'"'"'")" = 0 ]'
chk "misordered index was reindexed" 'docker logs $C 2>&1 | grep "index bad_s failed amcheck" >/dev/null'
chk "all text indexes valid (heapallindexed)" 'q postgres -c "CREATE EXTENSION amcheck; SELECT bt_index_check('"'"'corpus_s'"'"', true); DROP EXTENSION amcheck" >/dev/null && q tenant_a -c "CREATE EXTENSION amcheck; SELECT bt_index_check('"'"'docs_title'"'"', true), bt_index_check('"'"'bad_s'"'"', true); DROP EXTENSION amcheck" >/dev/null'
chk "data and pgvector intact" '[ "$(q tenant_a -c "SELECT count(*) FROM docs WHERE emb <-> '"'"'[1,2,3]'"'"' < 10")" -ge 1 ] && [ "$(q postgres -c "SELECT count(*) FROM events")" = 48 ]'
chk "partman maintenance" 'q postgres -c "CALL partman.run_maintenance_proc()" >/dev/null'
chk "no errors in log" '! docker logs $C 2>&1 | grep -E "ERROR|FATAL" | grep -v "pg_cron launcher\" due to administrator command"'
echo "  waiting for pg_cron to fire"
sleep 62
chk "pg_cron job succeeded after swap" '[ "$(q postgres -c "SELECT count(*) FROM cron.job_run_details WHERE status = '"'"'succeeded'"'"' AND start_time > now() - interval '"'"'2 min'"'"'")" -ge 1 ]'
stop

echo "### restart"
run "$IMG"
chk "second start skips the upgrade" '! docker logs $C 2>&1 | grep "Image changed" >/dev/null'
stop

echo "### roll back to $OLD"
run "$OLD"
chk "previous release reads data" '[ "$(q postgres -c "SELECT count(*) FROM events" 2>/dev/null)" = 48 ]'
chk "previous release runs partman maintenance" 'q postgres -c "CALL partman.run_maintenance_proc()" >/dev/null 2>&1'
stop

echo "### forward again"
run "$IMG"
chk "no warnings on connect" '[ -z "$(docker exec $C psql -U $U -d postgres -Atc "SELECT 1" 2>&1 >/dev/null)" ]'
stop
docker volume rm $C >/dev/null

echo "### RESULT: $([ $fail = 0 ] && echo ALL PASS || echo FAILURES)"
exit $fail
