# Postgres 18 + pg_partman + pg_cron

Custom Postgres 18 image that pre-installs the [pg_partman](https://github.com/pgpartman/pg_partman) partition management extension and the [pg_cron](https://github.com/citusdata/pg_cron) job scheduler. The image automatically configures `shared_preload_libraries`, enables a default `cron.database_name`, and creates the extensions during cluster initialization so they are ready immediately.

## What's inside

- Base image: `postgres:18`
- Build arguments to pin extension versions (`PG_PARTMAN_VERSION`, `PG_CRON_VERSION`)
- Compiles both extensions from source for maximum compatibility across architectures (pg_partman v5.2.4 by default)
- `docker-entrypoint-initdb.d` helpers that:
  - Append `shared_preload_libraries = 'pg_cron'` and set `cron.database_name = 'postgres'`
  - Create a `partman` schema and install `pg_partman` (in the target DB and `template1`)
  - Install `pg_cron` in the primary database so the background worker is available immediately

## Usage

### Build locally

```bash
# Optional: override extension versions
export PG_PARTMAN_VERSION=v5.2.4
export PG_CRON_VERSION=v1.6.2

docker build \
  --build-arg PG_PARTMAN_VERSION \
  --build-arg PG_CRON_VERSION \
  -t ghcr.io/<owner>/<repo>:local .
```

### Run

```bash
docker run --rm \
  -e POSTGRES_PASSWORD=postgres \
  -p 5432:5432 \
  ghcr.io/<owner>/<repo>:local
```

The initialization scripts will:

1. Set `shared_preload_libraries = 'pg_cron'` in the generated `postgresql.conf`
2. Set `cron.database_name` to `postgres`
3. Create the `partman` schema and install the extensions

### Creating extensions in additional databases

Because `pg_partman` is installed in `template1`, any database created after the initial cluster will inherit it. To add `pg_cron` to another database, run:

```sql
CREATE EXTENSION IF NOT EXISTS pg_cron;
```

Remember to update `cron.database_name` if you want the worker to target a different database.

## GitHub Actions workflow

The workflow in `.github/workflows/build-and-push.yml`:

- Triggers on pushes/PRs touching Docker-related files or workflows, plus manual dispatch
- Detects the Postgres base image version from the `Dockerfile`
- Builds multi-arch images (`linux/amd64`, `linux/arm64`) using Buildx + QEMU
- Publishes tags to GitHub Container Registry (GHCR) with ref, PR, SHA, and Postgres version tags
- Caches layers via the GitHub Actions cache backend for faster rebuilds

Secrets required: none beyond the default `GITHUB_TOKEN` for pushing to GHCR.

### Releasing a new image

1. Update the relevant build args in the `Dockerfile` (for example `PG_PARTMAN_VERSION=v5.2.4`).
2. Mirror the change in the `README.md` so the documented defaults stay in sync.
3. Build and sanity-check the image locally:

```bash
docker build -t ghcr.io/teams-work-ltd/postgres18-partman-cron:test .
docker run --rm --name partman-test -e POSTGRES_PASSWORD=postgres -d ghcr.io/teams-work-ltd/postgres18-partman-cron:test
docker exec partman-test psql -U postgres -d postgres -c "\\dx"
docker stop partman-test
```

4. Commit and push the changes to `main` (or open a PR). The GitHub Actions workflow will build and push the GHCR tags automatically when the branch merges.
5. Pull the published tag locally (e.g., `docker pull ghcr.io/teams-work-ltd/postgres18-partman-cron:18`) and, if desired, create a release tag in Git to document the change.

## Notes & assumptions

- The Docker host must support Buildx and multi-arch builds when reproducing the workflow locally.
- Change the `pg_partman`/`pg_cron` versions via build args if newer releases are needed.
- `pg_cron`’s background worker can target only one database. Update `cron.database_name` in `docker-entrypoint-initdb.d/00_configure_pg_cron.sh` (or replace the script) if you need a different default.

## License

Released under the [MIT License](./LICENSE).
