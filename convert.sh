#!/usr/bin/env bash
set -Eeuo pipefail

# take (unsigned) schema1 images from an OCI layout and convert them to OCI images

# usage: ./convert.sh oci-layout/

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
	"set -- \(
		.manifests
		| map(
			select(.mediaType == "application/vnd.docker.distribution.manifest.v1+json")
			| @json
			| @sh
		)
		| join(" ")
	)"
' index.json)"
eval "$shell"

for schema1Desc; do
	export schema1Desc

	shell="$(jq -r <<<"$schema1Desc" '
		@sh "export name=\(
			.annotations["org.opencontainers.image.ref.name"]
			// .annotations["io.containerd.image.name"]
			// .digest
		)",
		@sh "export schema1Digest=\(.digest)",
		@sh "expectedSize=\(.size)"
	')"
	eval "$shell"

	echo "$name ($schema1Digest):"

	sha256="${schema1Digest#sha256:}"
	if [ "$schema1Digest" = "$sha256" ]; then
		echo >&2 "error: non-sha256 manifest unimplemented"
		exit 1
	fi

	manifest="blobs/${schema1Digest//://}"
	size="$(stat -c '%s' "$manifest")"
	if [ "$size" != "$expectedSize" ]; then
		echo >&2 "error: unexpected manifest size: $size (vs $expectedSize)"
		exit 1
	fi
	sha256sum <<<"$sha256 *$manifest" --check --quiet --strict -

	# https://github.com/distribution/distribution/blob/e9864ce8b9d5676f23a46d67403bfba6c8a54cc8/docs/spec/manifest-v2-1.md

	# https://github.com/opencontainers/image-spec/blob/v1.1.0/manifest.md
	# https://github.com/opencontainers/image-spec/blob/v1.1.0/config.md

	shell="$(jq -r '
		if (.fsLayers | type) != "array" or (.history | type) != "array" then
			error("\(env.name) has invalid fsLayers or history")
		elif (.fsLayers | length) != (.history | length) then
			error("\(env.name) has inconsistent fsLayers and history lengths (these have to match)")
		elif (.fsLayers | length) < 1 then
			error("\(env.name) has no layers (and thus no metadata we can convert)")
		else . end

		# there is a fun bug in many (most?) schema1 images where the final layer of the image (at the top of the relevant lists) is *duplicated*, so we detect and strip that (even though it should be mostly harmless)
		| if (.fsLayers | length > 1) and .fsLayers[0].blobSum == .fsLayers[1].blobSum and .history[0].v1Compatibility == .history[1].v1Compatibility then
			.fsLayers |= .[1:]
			| .history |= .[1:]
		else . end

		| (.fsLayers | map(.blobSum)) as $layers
		| (
			[ .history, $layers ]
			| transpose
			| map(
				.[1] as $blob
				| .[0].v1Compatibility
				| fromjson
				# encoding/json in Go is case insensitive 🙈
				| with_entries(.key |= ascii_downcase)
				| .layer_blob = $blob
				| .empty_layer = (
					# https://github.com/containerd/containerd/blob/013fe433345d3b8bddf2b0a8548a644ba3f0de3a/core/remotes/docker/schema1/converter.go#L515-L535
					.throwaway == true
					or .size == 0
					# if all else fails, a list of known "empty" blobs
					or ($blob | IN(
						"sha256:3c2cba919283a210665e480bcbf943eaaf4ed87a83f02e81bb286b8bdead0e75", # tianon/scratch:schema1
						"sha256:a3ed95caeb02ffe68cdd9fd84406680ae93d633cb16422d00e8a7c22955b46d4", # postgres:8
						empty # trailing comma hack
					))
				)
			)
			# layers are in reverse order in schema1
			| reverse
		) as $history

		# the difference between the OCI config structure and the old v1 image format is minimal, so we can get away with supplementing the existing object with more fields for the purposes of conversion
		| $history[-1]
		# (minus the fields we created + fields we should not persist in the config)
		| del(.empty_layer, .layer_blob, .throwaway, .size, .id, .parent)
		| . + {
			history: ($history | map(
				{}
				+ if .created then { created: .created } else {} end
				+ if .comment then
					{ created_by: .comment }
				elif .container_config.Cmd then
					# https://github.com/moby/moby/issues/22436 (join(" ")) 😭
					{ created_by: (.container_config.Cmd | join(" ")) }
				else {} end
				+ if .empty_layer then { empty_layer: .empty_layer } else {} end
			)),
			rootfs: {
				diff_ids: [],
				type: "layers",
			},
		}

		| @sh "config=\(@json)",
			"layers=( \(
				$history
				| map(
					select(.empty_layer | not)
					| .layer_blob
					| @sh
				)
				| join(" ")
			) )"
	' "$manifest")"
	eval "$shell"

	manifest="$(jq -nc '{
		schemaVersion: 2,
		mediaType: "application/vnd.oci.image.manifest.v1+json",
		config: {
			mediaType: "application/vnd.oci.image.config.v1+json",
			digest: "TODO",
			size: 0,
		},
		layers: [],
		# TODO should we add an annotation saying this was converted?
	}')"
	echo "layers (${#layers[@]}):"
	for layer in "${layers[@]}"; do
		echo -n " - $layer => "
		blob="blobs/${layer//://}"
		layerSize="$(stat -c '%s' "$blob")"
		if [ "$layerSize" = 0 ]; then
			echo >&2 "warning: layer '$layer' is empty, but we didn't detect it properly! (please file a bug)"
		fi
		sha256="${layer#sha256:}"
		if [ "$layer" = "$sha256" ]; then
			echo >&2 "error: layer '$layer' is not using sha256"
			exit 1
		fi
		sha256sum <<<"$sha256 *$blob" --check --quiet --strict -
		# TODO cache diffid calculations *somewhere* so we can avoid redoing them if they're layers we've already seen
		diffId="$(
			if command -v igzip > /dev/null; then
				igzip -d
			elif command -v pigz > /dev/null; then
				pigz -d
			else
				gzip -d
			fi \
			< "$blob" \
			| sha256sum \
			| cut -d' ' -f1
		)"
		if [ "$diffId" = 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855' ]; then
			# echo -n '' | sha256sum ==> e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
			echo >&2 "warning: layer '$layer' is empty (when uncompressed), but we didn't detect it properly! (please file a bug)"
		fi
		export diffId="sha256:$diffId" layer layerSize
		echo "$diffId ($layerSize)"
		config="$(jq <<<"$config" -c '.rootfs.diff_ids += [ env.diffId ]')"
		manifest="$(jq <<<"$manifest" -c '
			.layers += [ {
				mediaType: "application/vnd.oci.image.layer.v1.tar+gzip",
				digest: env.layer,
				size: (env.layerSize | tonumber),
			} ]
		')"
	done

	jq <<<"$config" . > "$tmp/config.json"
	configSize="$(stat -c '%s' "$tmp/config.json")"
	sha256="$(sha256sum "$tmp/config.json" | cut -d' ' -f1)"
	export configDigest="sha256:$sha256" configSize
	mv "$tmp/config.json" "blobs/${configDigest//://}"

	manifest="$(jq <<<"$manifest" -c '
		.config.digest = env.configDigest
		| .config.size = (env.configSize | tonumber)
	')"
	jq <<<"$manifest" . > "$tmp/manifest.json"
	manifestSize="$(stat -c '%s' "$tmp/manifest.json")"
	sha256="$(sha256sum "$tmp/manifest.json" | cut -d' ' -f1)"
	export manifestDigest="sha256:$sha256" manifestSize
	mv "$tmp/manifest.json" "blobs/${manifestDigest//://}"

	manifestDesc="$(jq <<<"$schema1Desc" -c '
		. * {
			mediaType: "application/vnd.oci.image.manifest.v1+json",
			digest: env.manifestDigest,
			size: (env.manifestSize | tonumber),
			# TODO pull "platform" out of .history[0].v1Compatibility ("os" + "architecture"), if missing from schema1Desc
			annotations: {
				"org.opencontainers.image.ref.name": env.name,
				"io.containerd.image.name": env.name,
			},
		}
	')"
	jq <<<"$manifestDesc" .
	export manifestDesc

	jq '
		(env.manifestDesc | fromjson) as $desc
		| if [ .manifests[].digest ] | index($desc.digest) then . else 
			.manifests += [ $desc ]
		end
	' index.json > "$tmp/index.json"
	mv "$tmp/index.json" .
done
