#!/usr/bin/env bash
set -Eeuo pipefail

# usage: ./pull.sh oci-layout-output-directory/ image-in-registry [image ...]

oci="$1"; shift

mkdir -p "$oci"
cd "$oci"

if [ -z "${TMPDIR:-}" ]; then
	mkdir -p .tmp
	export TMPDIR="$PWD/.tmp"
fi
tmp="$(mktemp --directory --tmpdir 'schema1-pull-XXXXXXXXXX')"
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

for img; do
	export img # so "jq" can use it for better errors

	echo "$img:"

	crane manifest "$img" > "$tmp/manifest.json"

	# https://github.com/distribution/distribution/blob/e9864ce8b9d5676f23a46d67403bfba6c8a54cc8/docs/spec/manifest-v2-1.md

	manifestSize="$(stat -c '%s' "$tmp/manifest.json")"
	sha256="$(sha256sum "$tmp/manifest.json" | cut -d' ' -f1)"
	export manifestDigest="sha256:$sha256" manifestSize

	shell="$(
		jq -r '
			if .schemaVersion != 1 then
				error("\(env.img) is not a schema1 image")
			else . end
			| @sh "export manifestDescriptor=\(
					{
						mediaType: (
							if .signatures | type == "array" and length > 0 then
								"application/vnd.docker.distribution.manifest.v1+prettyjws"
							else
								"application/vnd.docker.distribution.manifest.v1+json"
							end
						),
						digest: env.manifestDigest,
						size: (env.manifestSize | tonumber),
						# TODO pull "platform" out of .history[0].v1Compatibility ("os" + "architecture")
						annotations: {
							"org.opencontainers.image.ref.name": env.img,
						},
					}
					| @json
				)",
				"layers=( \(.fsLayers | map(.blobSum | @sh) | join(" ") ) )"
		' "$tmp/manifest.json"
	)"
	eval "$shell"

	mkdir -p blobs/sha256
	mv "$tmp/manifest.json" "blobs/sha256/$sha256"

	jq <<<"$manifestDescriptor" .

	echo "layers (${#layers[@]}):"

	repo="${img%%@*}" # strip off any @digest so we can use it for pulling layers
	for layer in "${layers[@]}"; do
		echo " - $layer"
		sha256="${layer#sha256:}"
		if [ "$layer" = "$sha256" ]; then
			echo >&2 "error: '$layer' does not appear to use sha256 (as is required by the spec)"
			exit 1
		fi
		target="blobs/sha256/$sha256"
		if [ -s "$target" ]; then
			sha256sum <<<"$sha256 *$target" --check --quiet --strict -
		else
			crane blob "$repo@$layer" > "$tmp/blob"
			sha256sum <<<"$sha256 *$tmp/blob" --check --quiet --strict -
			mv "$tmp/blob" "blobs/sha256/$sha256"
		fi
	done

	jq '
		(env.manifestDescriptor | fromjson) as $desc
		| if [ .manifests[].digest ] | index($desc.digest) then . else 
			.manifests += [ $desc ]
		end
	' index.json > "$tmp/index.json"
	mv "$tmp/index.json" .
done
