#!/usr/bin/env bash
# image-build-action: build (and push) with podman-remote against the Podman service sidecar.
# Inputs arrive as IBB_* environment variables (action.yml). Outputs go to $GITHUB_OUTPUT.
set -euo pipefail

die() { echo "::error::image-build-action: $*"; exit 1; }
is_true() { [ "${1:-}" = "true" ]; }
# lines of a multi-line input without blanks and # comments
lines() { printf '%s\n' "${1:-}" | sed -e 's/\r$//' -e '/^[[:space:]]*$/d' -e '/^[[:space:]]*#/d'; }

export CONTAINER_HOST="${CONTAINER_HOST:-unix:///run/podman/podman.sock}"
sock=${CONTAINER_HOST#unix://}
for i in $(seq 1 60); do [ -S "$sock" ] && break; sleep 2; done
[ -S "$sock" ] || die "no Podman service socket at $sock. This action needs a job that runs in the runner container of arc-azrtydxb-amd64 (not in a 'container:' job, and not on a GitHub-hosted runner)."

# ---- podman-remote, pinned and checksum-verified ---------------------------------------------
case "$(uname -m)" in
x86_64) arch=amd64 ;;
aarch64 | arm64) arch=arm64 ;;
*) die "unsupported machine $(uname -m)" ;;
esac
version=$IBB_PODMAN_VERSION
case "$version/$arch" in
6.1.3/amd64) sha=23ee4f71873810a864389b78ffe0d7536296432bb96d0c2acfbbfc7d50ee9c1b ;;
6.1.3/arm64) sha=a0e949d1df0198bd5fe4a8aa4aa57b3038dd1946acbb2088ab318ea0e89bd349 ;;
*) die "podman-version $version/$arch is not in the checksum table (build.sh); add its sha256 from the release's shasums file" ;;
esac
tools=${RUNNER_TOOL_CACHE:-${RUNNER_TEMP:-/tmp}}/podman-remote/$version/$arch
podman=$tools/podman-remote
if [ ! -x "$podman" ] || ! "$podman" --version >/dev/null 2>&1; then
	mkdir -p "$tools"
	tmp=$(mktemp -d)
	url=https://github.com/containers/podman/releases/download/v$version/podman-remote-static-linux_$arch.tar.gz
	curl -fsSL --retry 3 --retry-delay 2 -o "$tmp/p.tgz" "$url" || die "download of $url failed"
	echo "$sha  $tmp/p.tgz" | sha256sum -c - >/dev/null || die "checksum mismatch for $url"
	tar -xzf "$tmp/p.tgz" -C "$tmp"
	install -m 0755 "$tmp/bin/podman-remote-static-linux_$arch" "$podman.$$"
	mv -f "$podman.$$" "$podman"
	rm -rf "$tmp"
fi
# The sidecar may still be starting on a fresh pod: wait up to 120s for the service to answer.
for i in $(seq 1 60); do
	"$podman" version >/dev/null 2>&1 && break
	[ "$i" = 1 ] && echo "waiting for the Podman service at $CONTAINER_HOST"
	sleep 2
done
"$podman" version >/dev/null 2>&1 || die "cannot reach the Podman service at $CONTAINER_HOST after 120s"

# ---- registry credentials the job already has ----------------------------------------------------
auth=${IBB_AUTH_FILE:-}
[ -n "$auth" ] || auth=${DOCKER_CONFIG:-$HOME/.docker}/config.json
if [ -f "$auth" ]; then
	export REGISTRY_AUTH_FILE=$auth
else
	unset REGISTRY_AUTH_FILE
	is_true "$IBB_PUSH" && echo "::warning::image-build-action: no $auth; pushing without credentials"
fi

# ---- names: the store is shared by every runner, so everything is unique per job -----------
uniq="${GITHUB_RUN_ID:-0}-${GITHUB_RUN_ATTEMPT:-1}-$$-$RANDOM"
local_name=localhost/ibb-$uniq
platforms=$(printf '%s' "$IBB_PLATFORMS" | tr -d ' \n\r')
[ -n "$platforms" ] || platforms=linux/amd64
multi=false
case "$platforms" in *,*) multi=true ;; esac
tags=()
while IFS= read -r t; do
	for x in ${t//,/ }; do tags+=("$x"); done
done < <(lines "$IBB_TAGS")
is_true "$IBB_PUSH" && [ ${#tags[@]} -eq 0 ] && die "push needs at least one tag"
is_true "$IBB_LOAD" && is_true "$multi" && die "load works for a single platform only"

# ---- cleanup of everything this run put into the shared store and on disk ---------------------
secdir=$(mktemp -d "${RUNNER_TEMP:-/tmp}/ibb-secrets.XXXXXX")
iidfile=$secdir/iid
digestfile=$secdir/digest
cleanup() {
	rc=$?
	set +e
	# Untag only: removing the image could also remove its untagged parents, which are the
	# layer cache the next build needs. Dangling leftovers are pruned by the store GC.
	if is_true "$multi"; then "$podman" manifest rm "$local_name" >/dev/null 2>&1; fi
	"$podman" untag "$local_name" >/dev/null 2>&1
	rm -rf "$secdir"
	exit $rc
}
trap cleanup EXIT

# ---- build arguments -------------------------------------------------------------------------------
args=(build --layers)
[ -n "$IBB_FILE" ] && args+=(-f "$IBB_FILE")
[ -n "$IBB_TARGET" ] && args+=(--target "$IBB_TARGET")
is_true "$IBB_NO_CACHE" && args+=(--no-cache)
is_true "$IBB_PULL" && args+=(--pull=always)
while IFS= read -r l; do args+=(--build-arg "$l"); done < <(lines "$IBB_BUILD_ARGS")
while IFS= read -r l; do args+=(--label "$l"); done < <(lines "$IBB_LABELS")
while IFS= read -r l; do
	id=${l%%=*}
	[ "$id" != "$l" ] || die "secrets: '$id' is not id=VALUE"
	( umask 077; printf '%s' "${l#*=}" >"$secdir/s-$id" )
	args+=(--secret "id=$id,src=$secdir/s-$id")
done < <(lines "$IBB_SECRETS")
while IFS= read -r l; do
	id=${l%%=*}
	[ "$id" != "$l" ] || die "secret-files: '$id' is not id=PATH"
	args+=(--secret "id=$id,src=${l#*=}")
done < <(lines "$IBB_SECRET_FILES")
if is_true "$multi"; then
	args+=(--platform "$platforms" --manifest "$local_name")
else
	args+=(--platform "$platforms" -t "$local_name" --iidfile "$iidfile")
fi
args+=("$IBB_CONTEXT")

# ---- build under the shared lock, so the store GC never runs under a build ----------------------
# gate.lock is held shared only while queueing for builds.lock; the GC takes gate.lock first so
# it cannot starve behind new builds (quadronix/arc/buildah-gc.yaml).
lockdir=${BUILDAH_LOCK_DIR:-/var/lock/buildah}
if [ -d "$lockdir" ] && [ -w "$lockdir" ]; then
	exec 8>"$lockdir/gate.lock" 9>"$lockdir/builds.lock"
	flock -s 8
	flock -s 9
	flock -u 8
fi

echo "::group::podman build ($platforms)"
"$podman" "${args[@]}"
echo "::endgroup::"

if is_true "$multi"; then
	imageid=$("$podman" images --no-trunc --format '{{.ID}}' "$local_name" | head -n1)
else
	imageid=$(cat "$iidfile")
fi

digest=
if is_true "$IBB_PUSH"; then
	for t in "${tags[@]}"; do
		echo "::group::push $t"
		if is_true "$multi"; then
			"$podman" manifest push --all --digestfile "$digestfile" "$local_name" "docker://$t"
		else
			"$podman" push --digestfile "$digestfile" "$local_name" "docker://$t"
		fi
		echo "::endgroup::"
		digest=$(cat "$digestfile")
	done
fi

# digest of every platform manifest of the pushed list (for attestations), "os/arch[/variant] digest"
platform_digests=
if is_true "$IBB_PUSH" && is_true "$multi"; then
	platform_digests=$("$podman" manifest inspect "$local_name" | python3 -c '
import json, sys
for m in json.load(sys.stdin).get("manifests", []):
    p = m.get("platform", {})
    plat = "/".join(x for x in (p.get("os"), p.get("architecture"), p.get("variant")) if x)
    print(plat, m["digest"])') || platform_digests=
fi

if is_true "$IBB_LOAD"; then
	command -v docker >/dev/null 2>&1 || die "load: no docker CLI in this job"
	"$podman" save --format docker-archive "$local_name" | docker load
	for t in "${tags[@]}"; do docker tag "$local_name" "$t"; done
fi

# ---- outputs -------------------------------------------------------------------------------------------
meta=$(printf '{"containerimage.digest":"%s","containerimage.config.digest":"%s","image.name":"%s"}' \
	"$digest" "$imageid" "$(IFS=,; echo "${tags[*]:-}")")
{
	echo "digest=$digest"
	echo "imageid=$imageid"
	echo "metadata=$meta"
	echo "platform-digests<<IBB_EOF"
	echo "$platform_digests"
	echo "IBB_EOF"
} >>"${GITHUB_OUTPUT:-/dev/null}"
[ -z "$digest" ] || echo "pushed $digest"
echo "built $imageid"
