#!/usr/bin/env bash
set -Eeuo pipefail

# take schema1 images from an OCI layout and strip libtrust signatures from them
# (https://github.com/moby/moby/commit/011bfd666eeb21a111ca450c42a3893ad03c9324)

# usage: ./unsign.sh oci-layout/

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
if [ ! -s oci-layout ]; then
	jq -n '{ imageLayoutVersion: "1.0.0" }' > "$tmp/oci-layout"
	mv "$tmp/oci-layout" .
fi
# TODO validate that "imageLayoutVersion" is correct in a pre-existing layout
if [ ! -s index.json ]; then
	jq -n '{
		schemaVersion: 2,
		mediaType: "application/vnd.oci.image.index.v1+json",
		manifests: [],
	}' > "$tmp/index.json"
	mv "$tmp/index.json" .
fi
# TODO validate that "index.json" contains only a single object and that it's valid

shell="$(jq -r '
	"set -- \(
		.manifests
		| map(
			select(.mediaType == "application/vnd.docker.distribution.manifest.v1+prettyjws")
			| @json
			| @sh
		)
		| join(" ")
	)"
' index.json)"
eval "$shell"

for signedDesc; do
	export signedDesc

	shell="$(jq -r <<<"$signedDesc" '
		@sh "export name=\(
			.annotations["org.opencontainers.image.ref.name"]
			// .annotations["io.containerd.image.name"]
			// .digest
		)",
		@sh "export signedDigest=\(.digest)",
		@sh "expectedSize=\(.size)"
	')"
	eval "$shell"

	echo "$name ($signedDigest):"

	sha256="${signedDigest#sha256:}"
	if [ "$signedDigest" = "$sha256" ]; then
		echo >&2 "error: non-sha256 manifest unimplemented"
		exit 1
	fi

	manifest="blobs/${signedDigest//://}"
	size="$(stat -c '%s' "$manifest")"
	if [ "$size" != "$expectedSize" ]; then
		echo >&2 "error: unexpected manifest size: $size (vs $expectedSize)"
		exit 1
	fi
	sha256sum <<<"$sha256 *$manifest" --check --quiet --strict -

	shell="$(jq -r '
		.signatures
		| if type == "array" and length > 0 then
			map(.protected)
			| unique
			| if length != 1 then
				error("\(env.name) has mismatched signatures")
			else
				.[0]
				| @base64d
				| fromjson
				| @sh "formatLength=\(.formatLength)",
					@sh "formatTail=\(.formatTail)"
			end
		else error("\(env.name) claims to be signed schema1, but has missing (or invalid) signatures") end
	' "$manifest")"
	eval "$shell"

	head --bytes="$formatLength" "$manifest" > "$tmp/manifest.json"
	base64 <<<"$formatTail" --decode - >> "$tmp/manifest.json"

	manifestSize="$(stat -c '%s' "$tmp/manifest.json")"
	sha256="$(sha256sum "$tmp/manifest.json" | cut -d' ' -f1)"
	export manifestDigest="sha256:$sha256" manifestSize

	manifestDesc="$(jq <<<"$signedDesc" -c '
		. * {
			mediaType: "application/vnd.docker.distribution.manifest.v1+json",
			digest: env.manifestDigest,
			size: (env.manifestSize | tonumber),
			# TODO pull "platform" out of .history[0].v1Compatibility ("os" + "architecture"), if missing from signedDesc
			annotations: {
				"org.opencontainers.image.ref.name": env.name,
				"io.containerd.image.name": env.name,
			},
		}
	')"
	jq <<<"$manifestDesc" .
	export manifestDesc

	mkdir -p blobs/sha256 # TODO
	mv "$tmp/manifest.json" "blobs/${manifestDigest//://}"

	jq '
		(env.manifestDesc | fromjson) as $desc
		| if [ .manifests[].digest ] | index($desc.digest) then . else 
			.manifests += [ $desc ]
		end
	' index.json > "$tmp/index.json"
	mv "$tmp/index.json" .
done
