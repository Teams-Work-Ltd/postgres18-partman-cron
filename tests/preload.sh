#!/usr/bin/env bash
# Check persisted libraries, explicit replacements and PG_AUTO_UPGRADE=false.
# usage: tests/preload.sh <image>
set -euo pipefail
IMG=$1
C=pgpc-test-preload
TEST_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

cleanup() {
	docker rm -f "$C" >/dev/null 2>&1 || true
	docker volume rm "$C" >/dev/null 2>&1 || true
}
trap cleanup EXIT
cleanup

q() { docker exec -i "$C" psql -U postgres -d postgres -v ON_ERROR_STOP=1 -Atq "$@"; }
stop() { docker stop "$C" >/dev/null; docker rm "$C" >/dev/null; }
start() {
	local ready=false
	docker run -d --name "$C" -v "$C:/var/lib/postgresql" \
		-e POSTGRES_PASSWORD=test -e PG_AUTO_UPGRADE=false "$IMG" "$@" >/dev/null
	for _ in $(seq 1 120); do
		[ "$(docker inspect -f '{{.State.Running}}' "$C")" = true ] || break
		if docker exec "$C" pg_isready -U postgres -d postgres -h 127.0.0.1 -q 2>/dev/null; then
			ready=true
			break
		fi
		sleep 0.5
	done
	if [ "$ready" != true ]; then
		docker logs "$C"
		return 1
	fi
}

start
q -c "ALTER SYSTEM SET shared_preload_libraries = 'pg_cron', 'pg_stat_statements', 'auto_explain'" >/dev/null
stop
start
[ "$(q -c 'SHOW shared_preload_libraries')" = 'pg_cron, pg_stat_statements, auto_explain,pg_hint_plan' ]
q < "$TEST_DIR/hints.sql" >/dev/null
echo 'PASS existing configuration preserved with automatic upgrades disabled'
stop

for option in split attached long; do
	case "$option" in
		split) start postgres -c shared_preload_libraries=pg_cron,pg_stat_statements,auto_explain ;;
		attached) start postgres -cshared_preload_libraries=pg_cron,pg_stat_statements,auto_explain ;;
		long) start postgres --shared_preload_libraries=pg_cron,pg_stat_statements,auto_explain ;;
	esac
	[ "$(q -c 'SHOW shared_preload_libraries')" = 'pg_cron,pg_stat_statements,auto_explain' ]
	echo "PASS explicit preload replacement: $option"
	stop
done

start postgres -c shared_preload_libraries=pg_cron,pg_stat_statements,auto_explain,pg_hint_plan
q < "$TEST_DIR/hints.sql" >/dev/null
echo 'PASS explicit preload replacement can include pg_hint_plan'
stop

start
[ "$(q -c 'SHOW shared_preload_libraries')" = 'pg_cron, pg_stat_statements, auto_explain,pg_hint_plan' ]
echo 'PASS explicit replacement did not change persisted configuration'
echo '### RESULT: ALL PASS'
