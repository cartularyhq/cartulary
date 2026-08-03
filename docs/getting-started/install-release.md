<!-- SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0 -->

# Install a packaged release

The packaged release includes and supervises a checksum-pinned pg0 PostgreSQL
distribution with pgvector.

## Choose a build

Open [Cartulary Releases](https://github.com/cartularyhq/cartulary/releases),
select a version, and download the archive and adjacent `.sha256` file matching
your machine:

| System | Architecture check | Archive |
| --- | --- | --- |
| macOS, Apple Silicon | `uname -m` prints `arm64` | `cartulary-macos-arm64.tar.gz` |
| macOS, Intel | `uname -m` prints `x86_64` | `cartulary-macos-x86_64.tar.gz` |
| Linux, Intel/AMD 64-bit | `uname -m` prints `x86_64` | `cartulary-linux-x86_64.tar.gz` |
| Windows, Intel/AMD 64-bit | Settings → System → About → System type | `cartulary-windows-x86_64.zip` |

The container build for external PostgreSQL is
`ghcr.io/cartularyhq/cartulary:<version>`.

## Download and verify

The browser download works without extra tools. The commands below use the
[GitHub CLI](https://cli.github.com/) to download both required files. Replace
`v0.3.2` with the release tag you want.

=== "macOS"

    ```bash
    release_tag=v0.3.2
    arch=$(uname -m)
    mkdir -p cartulary-download
    gh release download "$release_tag" \
      --repo cartularyhq/cartulary \
      --pattern "cartulary-macos-${arch}.tar.gz*" \
      --dir cartulary-download
    cd cartulary-download
    shasum -a 256 -c "cartulary-macos-${arch}.tar.gz.sha256"
    tar -xzf "cartulary-macos-${arch}.tar.gz"
    cd cartulary
    ```

=== "Linux"

    ```bash
    release_tag=v0.3.2
    mkdir -p cartulary-download
    gh release download "$release_tag" \
      --repo cartularyhq/cartulary \
      --pattern "cartulary-linux-x86_64.tar.gz*" \
      --dir cartulary-download
    cd cartulary-download
    sha256sum -c cartulary-linux-x86_64.tar.gz.sha256
    tar -xzf cartulary-linux-x86_64.tar.gz
    cd cartulary
    ```

=== "Windows"

    ```powershell
    $releaseTag = "v0.3.2"
    $download = "cartulary-download"
    gh release download $releaseTag `
      --repo cartularyhq/cartulary `
      --pattern "cartulary-windows-x86_64.zip*" `
      --dir $download
    Set-Location $download
    $expected = (Get-Content cartulary-windows-x86_64.zip.sha256).Split()[0]
    $actual = (Get-FileHash -Algorithm SHA256 cartulary-windows-x86_64.zip).Hash.ToLowerInvariant()
    if ($actual -ne $expected) { throw "Checksum verification failed" }
    Expand-Archive cartulary-windows-x86_64.zip
    Set-Location cartulary
    ```

Do not run an archive when its checksum fails. Download both files again from
the same release and retry verification.

## Recommended local setup

For a single-machine installation, use the packaged PostgreSQL, keep all
durable state in one private directory, and enable signed patch/minor updates
before each start:

=== "macOS / Linux"

    ```bash
    export CARTULARY_DATA_ROOT="$HOME/.cartulary"
    export CARTULARY_DATABASE_MODE=pg0
    export CARTULARY_AUTO_MIGRATE=true
    export CARTULARY_UPDATE_CHECK=true
    export CARTULARY_AUTO_UPDATE=minor
    export CARTULARY_UPDATE_CHECK_INTERVAL_HOURS=24

    bin/server
    ```

=== "Windows"

    ```powershell
    $env:CARTULARY_DATA_ROOT = "$HOME\.cartulary"
    $env:CARTULARY_DATABASE_MODE = "pg0"
    $env:CARTULARY_AUTO_MIGRATE = "true"
    $env:CARTULARY_UPDATE_CHECK = "true"
    $env:CARTULARY_AUTO_UPDATE = "minor"
    $env:CARTULARY_UPDATE_CHECK_INTERVAL_HOURS = "24"

    .\bin\server.bat
    ```

`minor` accepts only an eligible signed stable patch/minor release in the
current major version. Use `bin/update --check` to inspect availability, or
set `CARTULARY_AUTO_UPDATE=off` when you want to approve every update yourself.

## Run it

From the extracted `cartulary` directory:

=== "macOS / Linux"

    ```bash
    bin/server
    ```

=== "Windows"

    ```powershell
    .\bin\server.bat
    ```

The macOS archives are not yet signed or notarized by Apple. If macOS blocks
the verified build, try to open it once, then use **System Settings → Privacy &
Security → Open Anyway**. Apple documents the security tradeoff and exact steps
in [Safely open apps on your Mac](https://support.apple.com/en-us/102445). Do
not disable Gatekeeper globally.

On first start the launcher:

1. creates a private data root at `~/.cartulary` on macOS/Linux or `%USERPROFILE%\.cartulary` on Windows;
2. generates the local signing secret;
3. starts the packaged pg0 binary and creates its PostgreSQL cluster;
4. runs every migration against the fresh database;
5. starts Phoenix on port 4000.

Confirm it is up:

```bash
curl -fsS http://127.0.0.1:4000/api/ready
```

A 200 means the database, job queues, and model roles are ready. A 503 names
failing components with content-safe counts, versions, and error classes.

!!! warning "It fails closed, on purpose"
    If the port is occupied, or the data directory and configuration are
    unhealthy, the release refuses to accept traffic rather than starting in a
    half-working state.

## Change the defaults

Set these **before the first start**; they decide where durable state is
created:

| Variable | Default | Meaning |
| --- | --- | --- |
| `CARTULARY_DATA_ROOT` | `~/.cartulary` | Private data root for database, blobs, and secrets |
| `PORT` | `4000` | HTTP port |
| `CARTULARY_PG0_PORT` | `5432` | Port the supervised PostgreSQL listens on |

The complete list is in [Configuration](../reference/configuration.md).

## Point it at your own PostgreSQL instead

The same release can use operator-run PostgreSQL 18 with pgvector:

```bash
export CARTULARY_DATABASE_MODE=external
export DATABASE_URL='ecto://user:password@db.example/cartulary'
export CARTULARY_AUTO_MIGRATE=true
export CARTULARY_AUTH_SIGNING_SECRET='at-least-64-random-bytes...'
export CARTULARY_BLOB_ROOT=/absolute/durable/blob/path
bin/cartulary start
```

Set `CARTULARY_AUTO_MIGRATE=false` when change control requires migrations to
be a separate step, then run `bin/migrate` before starting the release.

## Build a release from source

Both scripts download the exact pg0 asset named in `rel/pg0/VERSION`, verify it
against `rel/pg0/checksums.txt`, and stage it only for release assembly:

=== "macOS / Linux"

    ```bash
    ./scripts/package-release
    ```

=== "Windows"

    ```powershell
    scripts\package-release.ps1
    ```

## Next

- [Quickstart tutorial](quickstart.md) — bootstrap an administrator and record
  your first observation.
- [Operations overview](../operations/index.md) — upgrades, backups, and
  running this in earnest.
