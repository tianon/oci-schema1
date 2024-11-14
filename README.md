# schema1

Docker Manifest v2 schema 1 specification: https://github.com/distribution/distribution/blob/e9864ce8b9d5676f23a46d67403bfba6c8a54cc8/docs/spec/manifest-v2-1.md

OCI image-spec:
- "OCI layout": https://github.com/opencontainers/image-spec/blob/v1.1.0/image-layout.md
- image manifest: https://github.com/opencontainers/image-spec/blob/v1.1.0/manifest.md
- image config: https://github.com/opencontainers/image-spec/blob/v1.1.0/config.md

Usage:

```console
$ ./pull.sh oci tianon/scratch:schema1
$ ./unsign.sh oci
$ ./convert.sh oci
$ # TODO write ./strip.sh or ./clean.sh or something to clean out the schema1 cruft from index.json
$ # TODO `tar -cC oci . | docker load` (or similar, assuming Docker v24+)
```
