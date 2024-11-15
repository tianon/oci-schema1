# schema1

Docker Manifest v2 schema 1 specification: https://github.com/distribution/distribution/blob/e9864ce8b9d5676f23a46d67403bfba6c8a54cc8/docs/spec/manifest-v2-1.md

OCI image-spec:
- "OCI layout": https://github.com/opencontainers/image-spec/blob/v1.1.0/image-layout.md
- image manifest: https://github.com/opencontainers/image-spec/blob/v1.1.0/manifest.md
- image config: https://github.com/opencontainers/image-spec/blob/v1.1.0/config.md

Usage:

```console
$ # pull (likely "signed") schema1 images into local OCI layout
$ ./pull.sh oci tianon/scratch:schema1

$ # strip signatures from signed schema1 images (no-op if no images are signed)
$ ./unsign.sh oci

$ # convert (unsigned) schema1 images into OCI media types
$ # NOTE: this is the expensive step, since we have to calculate "DiffIDs" for all layers
$ ./convert.sh oci

$ # remove now duplicated tag names from the OCI layout (in preference order OCI > schema2 > schema1)
$ ./clean.sh oci

$ # if you're on Docker v23 or older, you'll need "manifest.json"
$ # (see https://github.com/google/go-containerregistry/blob/v0.20.2/pkg/v1/tarball/README.md)
$ ./docker-manifest.sh oci

$ # "load" the result into Docker (could also "crane push", "ctr image import", etc)
$ tar -cC oci . | docker load
```
