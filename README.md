# Postgres 18 + pg_partman + pg_cron + pgvector

Postgres 18 image with the [pg_partman](https://github.com/pgpartman/pg_partman) partition management extension, the [pg_cron](https://github.com/citusdata/pg_cron) job scheduler, and the [pgvector](https://github.com/pgvector/pgvector) vector similarity extension pre-installed. The image configures `shared_preload_libraries`, sets a default `cron.database_name`, and creates the extensions during cluster initialization so they are ready immediately.

## What's inside

- Base image: [Wolfi](https://github.com/wolfi-dev) (`cgr.dev/chainguard/wolfi-base`), with Postgres and the extensions installed from Wolfi packages
- Build arguments to pin extension versions (`PG_PARTMAN_VERSION`, `PG_CRON_VERSION`, `PGVECTOR_VERSION`); each pins the upstream version and still picks up Wolfi security rebuilds
- The docker-library `docker-entrypoint.sh`, so the usual `POSTGRES_*` environment variables and `/docker-entrypoint-initdb.d` work as they do with the official image
- Same postgres uid/gid (999), `PGDATA` (`/var/lib/postgresql/18/docker`) and volume path (`/var/lib/postgresql`) as the official Debian image
- `docker-entrypoint-initdb.d` helpers that:
  - Set `shared_preload_libraries = 'pg_cron,pg_stat_statements'` and `cron.database_name = 'postgres'`
  - Create a `partman` schema and install `pg_partman` (in the target DB and `template1`)
  - Install `pgvector` (extension name: `vector`) and `pg_stat_statements` in the target DB, and `pgvector` in `template1`
  - Install `pg_cron` in the `postgres` database so the background worker is available immediately

## Usage

### Build locally

```bash
# Optional: override extension versions
export PG_PARTMAN_VERSION=5.5.0
export PG_CRON_VERSION=1.6.8
export PGVECTOR_VERSION=0.8.7

docker build \
  --build-arg PG_PARTMAN_VERSION \
  --build-arg PG_CRON_VERSION \
  --build-arg PGVECTOR_VERSION \
  -t ghcr.io/<owner>/<repo>:local .
```

### Run

```bash
docker run --rm \
  -e POSTGRES_PASSWORD=postgres \
  -p 5432:5432 \
  -v pgdata:/var/lib/postgresql \
  ghcr.io/<owner>/<repo>:local
```

The initialization scripts will:

1. Set `shared_preload_libraries = 'pg_cron,pg_stat_statements'`
2. Set `cron.database_name` to `postgres`
3. Create the `partman` schema and install the extensions

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

Swap the image tag and start the container. No manual steps are needed, including when moving from the Debian-based `v1.0.x` releases.

On start, `docker-upgrade-entrypoint.sh` compares a stamp in `PGDATA` against the image's libc, Postgres and extension versions. When they differ, it starts a socket-only temporary server and, in every database:

1. If the libc collation version changed, checks every btree index that uses a libc collation with `amcheck`, reindexes any that fail, then refreshes the recorded collation versions (this clears the `collation version mismatch` warning)
2. Runs `ALTER EXTENSION ... UPDATE` for any extension older than the version in the image

It then writes the stamp and starts Postgres normally, so later starts skip the check. If any step fails, it logs a warning, starts Postgres anyway and retries on the next start. Set `PG_AUTO_UPGRADE=false` to turn it off.

Rolling back to an older tag works, but the older image logs warnings, because the recorded collation and extension versions are now newer than the ones it ships.

## GitHub Actions workflow

The workflow in `.github/workflows/build-and-push.yml`:

- Triggers on pushes/PRs touching Docker-related files, tests or workflows (including git tags), weekly on Monday, plus manual dispatch
- Runs `tests/fresh.sh` (empty volumes under several `POSTGRES_USER`/`POSTGRES_DB` combinations) and `tests/upgrade.sh` (a `v1.0.2` volume swapped to the new image, restart, rollback); publishing only runs if both pass
- Reads the Postgres major version from `ARG PG_MAJOR` in the `Dockerfile`
- Builds multi-arch images (`linux/amd64`, `linux/arm64`) using Buildx + QEMU
- Publishes tags to GitHub Container Registry (GHCR) with ref, PR, SHA, and Postgres version tags

The weekly run refreshes `main`, `18` and the SHA tags with the latest Wolfi packages. Release tags such as `v1.1.0` are only built when the git tag is pushed, so cut a new release to ship security fixes to consumers that pin a version.

Secrets required: none beyond the default `GITHUB_TOKEN` for pushing to GHCR.

### Releasing a new image

1. Update the relevant build args in the `Dockerfile` (for example `PG_PARTMAN_VERSION=5.5.0`).
2. Mirror the change in the `README.md` so the documented defaults stay in sync.
3. Build and test the image locally:

```bash
docker build -t postgres18-partman-cron:test .
tests/fresh.sh postgres18-partman-cron:test
tests/upgrade.sh postgres18-partman-cron:test
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
