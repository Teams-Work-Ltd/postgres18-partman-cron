\set ON_ERROR_STOP on

-- Comment hints must work without CREATE EXTENSION, including in existing databases.
CREATE TEMP TABLE hint_probe (id integer PRIMARY KEY);
INSERT INTO hint_probe SELECT generate_series(1, 10000);
ANALYZE hint_probe;
SET enable_seqscan = off;

DO $test$
DECLARE
	plan json;
BEGIN
	PERFORM set_config('pg_hint_plan.enable_hint', 'off', false);
	EXECUTE 'EXPLAIN (FORMAT JSON, COSTS OFF) SELECT /*+ SeqScan(p) */ * FROM hint_probe p WHERE id = 42' INTO plan;
	IF plan->0->'Plan'->>'Node Type' = 'Seq Scan' THEN
		RAISE EXCEPTION 'baseline must use an index';
	END IF;
	PERFORM set_config('pg_hint_plan.enable_hint', 'on', false);
	EXECUTE 'EXPLAIN (FORMAT JSON, COSTS OFF) SELECT /*+ SeqScan(p) */ * FROM hint_probe p WHERE id = 42' INTO plan;
	IF plan->0->'Plan'->>'Node Type' <> 'Seq Scan' THEN
		RAISE EXCEPTION 'SeqScan hint was ignored: %', plan;
	END IF;
END
$test$;
