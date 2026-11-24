# Postgres 18 + pg_partman + pg_cron + pgvector + pg_hint_plan

Postgres 18 image with the [pg_partman](https://github.com/pgpartman/pg_partman) partition management extension, the [pg_cron](https://github.com/citusdata/pg_cron) job scheduler, and the [pgvector](https://github.com/pgvector/pgvector) vector similarity extension pre-installed, plus [pg_hint_plan](https://github.com/ossc-db/pg_hint_plan) for SQL comment hints. The image configures `shared_preload_libraries`, sets a default `cron.database_name`, and creates the extensions during cluster initialization so they are ready immediately.

## What's inside

- Base image: [Wolfi](https://github.com/wolfi-dev) (`cgr.dev/chainguard/wolfi-base`), with Postgres, pg_partman, pg_cron and pgvector installed from Wolfi packages
- Build arguments select extension versions (`PG_PARTMAN_VERSION=5.5.1`, `PG_CRON_VERSION=1.6.8`, `PGVECTOR_VERSION=0.8.7`) while allowing Wolfi package rebuilds
- `pg_hint_plan` 1.8.1, compiled against PostgreSQL 18 in a separate build stage from the upstream `REL18_1_8_1` archive, checked against `PG_HINT_PLAN_SHA256`; the runtime image contains no build tools
- The docker-library `docker-entrypoint.sh`, so the usual `POSTGRES_*` environment variables and `/docker-entrypoint-initdb.d` work as they do with the official image
- Same postgres uid/gid (999), `PGDATA` (`/var/lib/postgresql/18/docker`) and volume path (`/var/lib/postgresql`) as the official Debian image
- `docker-entrypoint-initdb.d` helpers that:
  - Set `shared_preload_libraries = 'pg_cron,pg_stat_statements,pg_hint_plan'` and `cron.database_name = 'postgres'`
  - Create a `partman` schema and install `pg_partman` (in the target DB and `template1`)
  - Install `pgvector` (extension name: `vector`) and `pg_stat_statements` in the target DB, and `pgvector` in `template1`
  - Install `pg_cron` in the `postgres` database so the background worker is available immediately

## Usage

### Build locally

```bash
# Optional: override extension versions
export PG_PARTMAN_VERSION=5.5.1
export PG_CRON_VERSION=1.6.8
export PGVECTOR_VERSION=0.8.7

docker build \
  --build-arg PG_PARTMAN_VERSION \
  --build-arg PG_CRON_VERSION \
  --build-arg PGVECTOR_VERSION \
  -t ghcr.io/<owner>/<repo>:local .
```

To change pg_hint_plan, supply both `--build-arg PG_HINT_PLAN_VERSION=<version>` and `--build-arg PG_HINT_PLAN_SHA256=<archive-sha256>`. Use a release for PostgreSQL 18.

### Run

```bash
docker run --rm \
  -e POSTGRES_PASSWORD=postgres \
  -p 5432:5432 \
  -v pgdata:/var/lib/postgresql \
  ghcr.io/<owner>/<repo>:local
```

The initialization scripts will:

1. Set `shared_preload_libraries = 'pg_cron,pg_stat_statements,pg_hint_plan'`
2. Set `cron.database_name` to `postgres`
3. Create the `partman` schema and install the extensions

### SQL comment hints

Comment hints work in every database without `CREATE EXTENSION pg_hint_plan`:

```sql
EXPLAIN SELECT /*+ SeqScan(e) */ * FROM events e WHERE id = 42;
```

The hint uses the table alias from the query. The optional hint table requires `CREATE EXTENSION pg_hint_plan` in each database where it is needed, and `pg_hint_plan.enable_hint_table=on`. The image leaves the hint table disabled.

An explicit command-line `shared_preload_libraries` setting replaces the image default. Include `pg_hint_plan` in that list to keep hints enabled. For example, append these arguments after the image name:

```bash
postgres -c shared_preload_libraries=pg_cron,pg_stat_statements,pg_hint_plan,auto_explain
```

### Creating extensions in additional databases

Because `pg_partman` and `pgvector` are installed in `template1`, any database created after the initial cluster will inherit them.

`pg_cron` lives in the `postgres` database. To schedule a job that runs in another database, use `cron.schedule_in_database`:

```sql
SELECT cron.schedule_in_database('partman-maintenance', '*/15 * * * *', 'CALL partman.run_maintenance_proc()', 'appdb');
```

To add `pgvector` to an existing database (if needed), run:

```sql
CREATE EXTENSION IF NOT EXISTS vector;
```

To enable `pg_stat_statements` for query performance monitoring, run:

```sql
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;
```

## Upgrading existing volumes

Existing PostgreSQL 18 volumes can be reused, including volumes from v1.1.0 and Debian-based v1.0.x releases. This does not perform a PostgreSQL major-version upgrade.

On existing volumes, startup reads the effective preload configuration and adds `pg_hint_plan` to the server arguments, preserving other libraries. It does not write that addition to the volume. This also works with `PG_AUTO_UPGRADE=false`. Explicit command-line preload settings take precedence and must include `pg_hint_plan` to enable hints.

A fresh build currently installs PostgreSQL 18.7. Review its [migration notes](https://www.postgresql.org/docs/release/18.7/) before deploying: some affected indexes require rebuilding, existing incremental backups need a new full backup, and C extensions need rebuilding. The automatic checks below only repair libc collation issues; they do not cover every migration action in the release notes.

On start, `docker-upgrade-entrypoint.sh` compares a stamp in `PGDATA` against the image's libc, Postgres and extension versions. When they differ, it starts a socket-only temporary server and, in every database:

1. If the libc collation version changed, checks every btree index that uses a libc collation with `amcheck`, reindexes any that fail, then refreshes the recorded collation versions (this clears the `collation version mismatch` warning)
2. Runs `ALTER EXTENSION ... UPDATE` for any extension older than the version in the image

It then writes the stamp and starts Postgres normally, so later starts skip the check. If any step fails, it logs a warning, starts Postgres anyway and retries on the next start. Set `PG_AUTO_UPGRADE=false` to turn it off.

For volumes initialized with an older image, the automatic preload addition leaves the original configuration available for rollback. Extension upgrades are not reversed, and the older image may log warnings about newer extension or collation versions. Test rollback before relying on it.

Volumes initialized with this release store `pg_hint_plan` in their preload list. Before using an older image that lacks the library, remove it from that persisted list. The same applies if you add it yourself with `ALTER SYSTEM`.

## GitHub Actions workflow

The workflow in `.github/workflows/build-and-push.yml`:

- Triggers on pushes/PRs touching Docker-related files, tests or workflows (including git tags), weekly on Monday, plus manual dispatch
- Tests `linux/amd64` and `linux/arm64` on matching native Blacksmith runners before publishing: fresh installations, upgrades from v1.1.0 and v1.0.2, restarts, rollback, actual comment hints and custom preload settings
- Reads the Postgres major version from `ARG PG_MAJOR` in the `Dockerfile`
- Builds multi-arch images (`linux/amd64`, `linux/arm64`) using Buildx + QEMU
- Publishes tags to GitHub Container Registry (GHCR) with ref, PR, SHA, and Postgres version tags

The weekly run refreshes `main`, `18` and the SHA tags with the latest Wolfi packages. Release tags such as `v1.1.0` are only built when the git tag is pushed, so cut a new release to ship security fixes to consumers that pin a version.

Secrets required: none beyond the default `GITHUB_TOKEN` for pushing to GHCR.

### Releasing a new image

1. Update the relevant build args in the `Dockerfile` (for example `PG_PARTMAN_VERSION=5.5.1`).
2. Mirror the change in the `README.md` so the documented defaults stay in sync.
3. Build and test the image locally:

```bash
# Repeat for linux/amd64 and linux/arm64.
export DOCKER_DEFAULT_PLATFORM=linux/arm64
docker buildx build --platform "$DOCKER_DEFAULT_PLATFORM" --load -t postgres18-partman-cron:test .
for script in docker-upgrade-entrypoint.sh docker-entrypoint-initdb.d/*.sh tests/*.sh; do
  bash -n "$script" || exit
done
tests/fresh.sh postgres18-partman-cron:test
tests/upgrade.sh postgres18-partman-cron:test
tests/upgrade.sh postgres18-partman-cron:test ghcr.io/teams-work-ltd/postgres18-partman-cron:v1.0.2
tests/preload.sh postgres18-partman-cron:test
```

4. Commit and push the changes to `main` (or open a PR). The GitHub Actions workflow will build and push the GHCR tags automatically when the branch merges.
5. Create an annotated git tag that reflects the release (for example `git tag -a v1.1.0 -m "Release 1.1.0" && git push origin v1.1.0`). The workflow runs for tag pushes and publishes an image tag with the exact same name (`ghcr.io/teams-work-ltd/postgres18-partman-cron:v1.1.0`).
6. Pull whichever tag you need locally (e.g., `docker pull ghcr.io/teams-work-ltd/postgres18-partman-cron:v1.1.0` or `:18`) before promoting it to other environments.

## Notes & assumptions

- The Docker host must support Buildx and multi-arch builds when reproducing the workflow locally.
- The unix socket is in `/tmp` (the Wolfi Postgres default) instead of `/var/run/postgresql`. `psql` and `pg_isready` inside the container use it automatically; only clients that mount the socket from outside the container need the new path.
- `pg_cron`'s background worker can target only one database. Update `cron.database_name` in `docker-entrypoint-initdb.d/00_configure_extensions.sh` (or replace the script) if you need a different default.

## License

Released under the [MIT License](./LICENSE).
