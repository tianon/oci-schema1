#!/usr/bin/env bash
set -Eeuo pipefail

# remove duplicate tags inside "index.json" of an OCI layout, preferring OCI media types, then Docker schema2, then unsigned schema1, then signed schema1

# usage: ./clean.sh oci-layout/

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

jq '
	.manifests |= (
		sort_by(
			.mediaType as $mediaType
			| [
				# preferred media types, in order of preference

				# OCI: https://github.com/opencontainers/image-spec/blob/v1.1.0/media-types.md
				"application/vnd.oci.image.index.v1+json",    # "image index"
				"application/vnd.oci.image.manifest.v1+json", # "image manifest"

				# Docker Manifest v2 schema 2: https://github.com/distribution/distribution/blob/v3.0.0-rc.1/docs/content/spec/manifest-v2-2.md#media-types
				"application/vnd.docker.distribution.manifest.list.v2+json", # "manifest list"
				"application/vnd.docker.distribution.manifest.v2+json",      # "image manifest"

				# Docker Manifest v2 schema 1: https://github.com/distribution/distribution/blob/e9864ce8b9d5676f23a46d67403bfba6c8a54cc8/docs/spec/manifest-v2-1.md#image-manifest-version-2-schema-1
				"application/vnd.docker.distribution.manifest.v1+json",      # unsigned/"canonical"
				"application/vnd.docker.distribution.manifest.v1+prettyjws", # signed

				empty # trailing comma hack
			]
			| index($mediaType) // length
		)
		| unique_by(
			.annotations["io.containerd.image.name"]
			// .annotations["org.opencontainers.image.ref.name"]
			// .digest
		)
	)
' index.json > "$tmp/index.json"
mv "$tmp/index.json" .
jq -r '
	.manifests[]
	| "\(
		.annotations["io.containerd.image.name"]
		// .annotations["org.opencontainers.image.ref.name"]
		// .digest
	) (\(.mediaType))"
' index.json
