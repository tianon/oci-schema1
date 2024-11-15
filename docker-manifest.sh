#!/usr/bin/env bash
set -Eeuo pipefail

# given an OCI layout, add a Docker-compatible "manifest.json" (Docker v24+ added support for importing OCI layouts directly, so only this is only useful for <v24)
# NOTE: this assumes an already "clean" OCI layout (see "clean.sh"), and will *not* recurse into indexes / manifest lists

# usage: ./docker-manifest.sh oci-layout/

oci="$1"; shift

mkdir -p "$oci"
cd "$oci"

if [ -z "${TMPDIR:-}" ]; then
	mkdir -p .tmp
	export TMPDIR="$PWD/.tmp"
fi
tmp="$(mktemp --directory --tmpdir 'schema1-unsign-XXXXXXXXXX')"
trap "$(printf 'rm -rf %q' "$tmp")" EXIT

# https://github.com/opencontainers/image-spec/blob/v1.1.0/image-layout.md
[ -s oci-layout ] # TODO validate that "imageLayoutVersion" is correct
[ -s index.json ] # TODO validate that "index.json" contains only a single object and that it's valid

shell="$(jq -r '
	reduce .manifests[] as $desc ({};
		.[$desc.digest] += [
			$desc
			| .annotations["io.containerd.image.name"]
			// .annotations["org.opencontainers.image.ref.name"]
			// .digest # TODO figure out if Docker can actually handle this 😇
		]
	)
	| to_entries
	| "manifestFiles=( \(map(.key | "blobs/\(sub(":"; "/"))" | @sh) | join(" ")) )",
		@sh "tags=\(map(.value) | @json)"
' index.json)"
eval "$shell"

jq <<<"$tags" -s '
	[ .[0], .[1:] ]
	| transpose
	| map({
		RepoTags: .[0],
		Config: (.[1].config.digest | "blobs/\(sub(":"; "/"))"),
		Layers: [ .[1].layers[].digest | "blobs/\(sub(":"; "/"))" ],
	})
' - "${manifestFiles[@]}" > "$tmp/manifest.json"
mv "$tmp/manifest.json" .

jq -c '.[].RepoTags' manifest.json
