# image-build-action

Build and push container images with Buildah on the quadronix ARC runners (`arc-azrtydxb-amd64`).
A drop-in for `docker/setup-buildx-action` + `docker/build-push-action`, without BuildKit, without
a registry layer cache to configure, and with multi-arch builds that never use emulation.

```yaml
- uses: actions/checkout@v7
- uses: docker/login-action@v4 # or azrtydxb/ant-setup-action with docker-login: true
  with: { registry: ghcr.io, username: ${{ github.actor }}, password: ${{ secrets.GITHUB_TOKEN }} }
- uses: azrtydxb/image-build-action@v1
  id: img
  with:
    context: .
    file: build/Dockerfile
    platforms: linux/amd64,linux/arm64
    push: true
    tags: |
      ghcr.io/azrtydxb/app:${{ github.sha }}
      ghcr.io/azrtydxb/app:main
```

## How it works

Each runner pod of `arc-azrtydxb-amd64` has a rootless `podman system service` sidecar
(`quay.io/podman/stable`, `BUILDAH_LAYERS=true`, native overlay, `BUILDAH_ISOLATION=chroot`) and the
env `CONTAINER_HOST=unix:///run/podman/podman.sock`. The action downloads a pinned, checksum-verified
static `podman-remote` client per job (no custom runner image), then:

1. `podman-remote build --layers --platform <list>` (with `--manifest <unique name>` for several
   platforms, `-t <unique name> --iidfile` for one);
2. pushes to every tag with `podman-remote manifest push --all` (several platforms) or
   `podman-remote push` (one), using the job's credentials;
3. untags its local names again.

The image store (`/data/buildah/storage`) and the `RUN --mount=type=cache` directory
(`/data/buildah/cache`) are **shared by all runners** on the host, so a layer built by any earlier job
is a cache hit for the next job on any pod (warm builds: seconds instead of minutes). Base images are
pulled through the home Ant (`ant.kw.watteel.lab`) via the sidecar's `registries.conf`.
A nightly CronJob (`quadronix/arc/buildah-gc.yaml` in azrty-infra) prunes the store when it grows past
a limit, and never while a build runs (builds hold a shared `flock`).

## Inputs

| Input | Default | Meaning |
| --- | --- | --- |
| `context` | `.` | Build context directory |
| `file` | `<context>/Dockerfile` | Dockerfile path |
| `platforms` | `linux/amd64` | Comma-separated; more than one builds a manifest list |
| `tags` | | One per line or comma-separated; required with `push` |
| `push` | `false` | Push every tag using the job's registry credentials |
| `load` | `false` | Single platform: also `docker load` the image into the runner's dind |
| `build-args` | | `KEY=VALUE` per line |
| `labels` | | `KEY=VALUE` per line |
| `target` | | Target stage |
| `secrets` | | `id=VALUE` per line, for `RUN --mount=type=secret,id=...` |
| `secret-files` | | `id=PATH` per line |
| `no-cache` | `false` | `--no-cache` |
| `pull` | `false` | `--pull=always` |
| `auth-file` | `$DOCKER_CONFIG/config.json` or `~/.docker/config.json` | Credentials; where `docker/login-action` and `ant-setup-action` write theirs |
| `podman-version` | `6.1.3` | Only versions in the checksum table of `build.sh` |

Outputs: `digest` (of the pushed image or manifest list; empty without push), `imageid`, `metadata`
(JSON with `containerimage.digest`, `containerimage.config.digest`, `image.name`).

## Migrating from docker/build-push-action

Remove these, they have no use with this action:

- `docker/setup-buildx-action` and `azrtydxb/.github/actions/setup-builder` (no builder to create);
- `cache-from` / `cache-to` (type=registry from `ant-setup-action`'s `build-cache` outputs, or type=gha):
  the shared store is the cache. Also drop `build-cache: "true"` from `ant-setup-action` if the job
  builds nothing else with buildx;
- `provenance`, `sbom`, `outputs`, `builder`, `github-token`, `no-cache-filters` (not supported; BuildKit-only).

Keep `docker/login-action` (or `ant-setup-action` with `docker-login: true`): the action reads
`~/.docker/config.json`. Everything else maps by name.

Before:

```yaml
- uses: docker/setup-buildx-action@v4
- id: ant
  uses: azrtydxb/ant-setup-action@v1
  with: { docker-login: true, build-cache: true }
- uses: docker/build-push-action@v7
  with:
    context: .
    file: build/docker/api.Dockerfile
    platforms: linux/amd64,linux/arm64
    push: true
    provenance: false
    tags: ghcr.io/azrtydxb/api:${{ github.sha }}
    cache-from: ${{ steps.ant.outputs.cache-from }}
    cache-to: ${{ steps.ant.outputs.cache-to }}
```

After:

```yaml
- uses: azrtydxb/ant-setup-action@v1
  with: { docker-login: true }
- uses: azrtydxb/image-build-action@v1
  with:
    context: .
    file: build/docker/api.Dockerfile
    platforms: linux/amd64,linux/arm64
    push: true
    tags: ghcr.io/azrtydxb/api:${{ github.sha }}
```

`steps.<id>.outputs.digest` is the same as docker/build-push-action's.

## Requirements and gotchas

- **Runner**: `runs-on: arc-azrtydxb-amd64` (or its labels), a step directly in the runner container.
  A `container:` job runs in another pod that cannot reach the socket; the action then fails with a
  clear message. Build in a separate job without `container:`. GitHub-hosted runners and the arm64
  OKE runners have no sidecar either.
- **Cross-arch without emulation**: QEMU is not allowed. For `linux/arm64` on this amd64 host the
  Dockerfile must cross-compile: build stages `FROM --platform=$BUILDPLATFORM`, use
  `$TARGETOS`/`$TARGETARCH` (`GOOS`/`GOARCH`, `cargo --target`, ...), and the final stage must have no
  `RUN` (use `COPY --from`). A `RUN` in a foreign-arch stage fails with `exec format error`.
- **Dockerfile syntax**: Buildah is not BuildKit. `RUN --mount=type=cache|secret|bind|tmpfs` work;
  `RUN --network`, `ADD --checksum/--link/--keep-git-dir`, `COPY --exclude`, heredocs in `RUN`
  (supported) are the ones to check; `# syntax=docker/dockerfile:1` is ignored.
- **Image names are unique per job** (the store is shared); do not rely on a local name between steps.
  Use `load: true` (single platform) to get the image into dind, or pull what you pushed.
- Secrets: `RUN --mount=type=secret,id=x` reads `/run/secrets/x`. Never pass secrets as build-args.
- The build runs under a shared lock so the store GC cannot prune during it; an unusually long
  build only delays the GC.
- `HOME`-based auth: `docker login` must have run in an earlier step of the same job.

## Development

`.github/workflows/test.yml` builds a tiny multi-arch Dockerfile on `arc-azrtydxb-amd64`, pushes it
to `ghcr.io/azrtydxb/image-build-action-test`, checks both architectures in the manifest list,
a second run for cache hits, and a single-platform `load`. Consumers pin `@v1`; the `v1` tag moves
with compatible changes, `v1.x.y` tags are immutable.
