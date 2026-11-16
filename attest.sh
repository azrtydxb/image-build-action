#!/usr/bin/env bash
# image-build-action: SBOM and provenance attestations for the pushed image, keyless with cosign
# (GitHub OIDC, Sigstore), stored in the registry next to the image. Inputs: IBB_* env (action.yml).
set -euo pipefail

die() { echo "::error::image-build-action: $*"; exit 1; }
is_on() { case "${1:-}" in "" | false | none) return 1 ;; *) return 0 ;; esac; }

[ -n "${IBB_DIGEST:-}" ] || die "attestations need a pushed digest (push: true)"
[ -n "${ACTIONS_ID_TOKEN_REQUEST_URL:-}" ] || die "sbom/provenance need 'permissions: id-token: write' on the job (keyless signing)"

case "$(uname -m)" in
x86_64) arch=amd64 ;;
aarch64 | arm64) arch=arm64 ;;
*) die "unsupported machine $(uname -m)" ;;
esac
syft_version=1.54.1
cosign_version=3.1.4
case "$arch" in
amd64) syft_sha=c069905b391cc4c20a5ba65ad5c10be2a7ba074f8ea6ad203e24d14e303dad47
	cosign_sha=424e2c97d0b45fd7a6b608a87f090f35633f4c23ece5f092d48bba11aaf4bbfa ;;
arm64) syft_sha=dfdf0537610113edbefe1f1fc6548bc957b2d77439636ec824fcf0e10d46d054
	cosign_sha=ade83b7aac62e131cacfe96d958948b2150cc9efec46a570a2649b8e27dedad2 ;;
esac
tools=${RUNNER_TOOL_CACHE:-${RUNNER_TEMP:-/tmp}}/ibb-attest
work=$(mktemp -d "${RUNNER_TEMP:-/tmp}/ibb-attest.XXXXXX")
trap 'rm -rf "$work"' EXIT
mkdir -p "$tools"

fetch() { # fetch <url> <sha256> <dest>
	curl -fsSL --retry 3 --retry-delay 2 -o "$work/dl" "$1" || die "download of $1 failed"
	echo "$2  $work/dl" | sha256sum -c - >/dev/null || die "checksum mismatch for $1"
	mv "$work/dl" "$3"
}
cosign=$tools/cosign-$cosign_version-$arch
if [ ! -x "$cosign" ]; then
	fetch "https://github.com/sigstore/cosign/releases/download/v$cosign_version/cosign-linux-$arch" "$cosign_sha" "$cosign.tmp$$"
	chmod 0755 "$cosign.tmp$$"; mv -f "$cosign.tmp$$" "$cosign"
fi
syft=$tools/syft-$syft_version-$arch
if is_on "${IBB_SBOM:-}" && [ ! -x "$syft" ]; then
	fetch "https://github.com/anchore/syft/releases/download/v$syft_version/syft_${syft_version}_linux_$arch.tar.gz" "$syft_sha" "$work/syft.tgz"
	tar -xzf "$work/syft.tgz" -C "$work" syft
	install -m 0755 "$work/syft" "$syft.tmp$$"; mv -f "$syft.tmp$$" "$syft"
fi

# registry credentials: cosign and syft read $DOCKER_CONFIG/config.json
auth=${IBB_AUTH_FILE:-}
[ -n "$auth" ] || auth=${DOCKER_CONFIG:-$HOME/.docker}/config.json
if [ -f "$auth" ]; then
	mkdir -p "$work/docker"; cp "$auth" "$work/docker/config.json"
	export DOCKER_CONFIG=$work/docker
fi

# repositories of the pushed tags (the tag, not a registry port, is stripped)
repos=()
while IFS= read -r t; do
	for x in ${t//,/ }; do
		last=${x##*/}
		case "$last" in *:*) x=${x%:*} ;; esac
		x=${x%@*}
		dup=false
		for r in "${repos[@]:-}"; do [ "$r" = "$x" ] && dup=true; done
		$dup || repos+=("$x")
	done
done < <(printf '%s\n' "$IBB_TAGS" | sed -e 's/\r$//' -e '/^[[:space:]]*$/d')
[ ${#repos[@]} -gt 0 ] || die "no repositories to attest"

# what to attest: the index (provenance) and every platform manifest (SBOM); one image: itself
platforms=()
if [ -n "${IBB_PLATFORM_DIGESTS:-}" ]; then
	while IFS= read -r l; do [ -n "$l" ] && platforms+=("$l"); done <<<"$IBB_PLATFORM_DIGESTS"
else
	platforms+=("${IBB_PLATFORMS:-linux/amd64} $IBB_DIGEST")
fi

predicate_provenance() { # predicate_provenance <digest> > file
	python3 - "$1" <<'PY'
import json, os, sys
e = os.environ
repo = e.get("GITHUB_REPOSITORY", "")
ref = e.get("GITHUB_WORKFLOW_REF", "")
print(json.dumps({
    "buildDefinition": {
        "buildType": "https://actions.github.io/buildtypes/workflow/v1",
        "externalParameters": {"workflow": {"ref": e.get("GITHUB_REF", ""), "repository": "https://github.com/" + repo,
                                            "path": ref.split("@")[0].split(repo + "/", 1)[-1]}},
        "internalParameters": {"github": {"event_name": e.get("GITHUB_EVENT_NAME", ""), "runner_environment": e.get("RUNNER_ENVIRONMENT", "")}},
        "resolvedDependencies": [{"uri": "git+https://github.com/" + repo + "@" + e.get("GITHUB_REF", ""), "digest": {"gitCommit": e.get("GITHUB_SHA", "")}}],
    },
    "runDetails": {
        "builder": {"id": "https://github.com/azrtydxb/image-build-action", "version": {"podman-remote": e.get("IBB_PODMAN_VERSION", "")}},
        "metadata": {"invocationId": "https://github.com/%s/actions/runs/%s/attempts/%s" % (repo, e.get("GITHUB_RUN_ID", ""), e.get("GITHUB_RUN_ATTEMPT", "1"))},
    },
}))
PY
}

export COSIGN_YES=true
for repo in "${repos[@]}"; do
	if is_on "${IBB_SBOM:-}"; then
		for p in "${platforms[@]}"; do
			plat=${p%% *}; dig=${p##* }
			echo "::group::sbom $repo@$dig ($plat)"
			sargs=(scan "registry:$repo@$dig" -o "spdx-json=$work/sbom.json")
			# syft refuses a manifest of another arch than the host unless told which one it is
			case "$plat" in */*) sargs+=(--platform "$plat") ;; esac
			"$syft" "${sargs[@]}"
			"$cosign" attest --yes --type spdxjson --predicate "$work/sbom.json" "$repo@$dig"
			echo "::endgroup::"
		done
	fi
	if is_on "${IBB_PROVENANCE:-}"; then
		echo "::group::provenance $repo@$IBB_DIGEST"
		predicate_provenance "$IBB_DIGEST" >"$work/provenance.json"
		"$cosign" attest --yes --type slsaprovenance1 --predicate "$work/provenance.json" "$repo@$IBB_DIGEST"
		echo "::endgroup::"
	fi
done
echo "attested $IBB_DIGEST"
