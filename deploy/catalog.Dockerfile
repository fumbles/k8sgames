# File-based catalog image, served by opm.
# opm is multi-arch, so this builds cleanly for any platform.
# The catalog content itself is plain YAML — arch-independent.
FROM quay.io/operator-framework/opm:latest
ENTRYPOINT ["/bin/opm"]
# --cache-enforce-integrity=false: build the cache at startup rather than
# baking it in at image build time (avoids QEMU issues in multi-arch builds).
CMD ["serve", "/configs", "--cache-dir=/tmp/cache", "--cache-enforce-integrity=false"]
ADD catalog /configs
LABEL operators.operatorframework.io.index.configs.v1=/configs
