# OCI image for ifnh (ACTIVE_PLAN F-08): the released static musl binary on
# scratch. The build context is a directory laid out as <os>/<arch>/ifnh, for
# example linux/amd64/ifnh and linux/arm64/ifnh, taken from the F-01 linux-musl
# tarballs (see .github/workflows/image.yml). Nothing is compiled here.
#   docker buildx build -f packaging/docker/Dockerfile --platform linux/amd64 <context>
#
# The image has no shell, git or coreutils, so the agent's bash/git tools cannot
# run inside it; it suits `ifnh ask`, `ifnh serve` and other tool-free use.
#
# User: root (the default). The image exists to work on a bind-mounted project
# (-v "$PWD":/work), and a fixed non-root uid such as 65534 usually cannot write
# a directory owned by the host user, while scratch has no /etc/passwd to map one.
# Run as yourself with `--user "$(id -u):$(id -g)" -e HOME=/work/.ifnh-home`.
FROM scratch
ARG TARGETOS
ARG TARGETARCH
ARG VERSION=unknown
ARG REVISION=unknown
LABEL org.opencontainers.image.title="ifnh" \
      org.opencontainers.image.description="Lightweight agentic coding harness" \
      org.opencontainers.image.url="https://github.com/Abide-Integrations/IFNH-Insert-Fancy-Name-Here" \
      org.opencontainers.image.source="https://github.com/Abide-Integrations/IFNH-Insert-Fancy-Name-Here" \
      org.opencontainers.image.licenses="MIT" \
      org.opencontainers.image.version="${VERSION}" \
      org.opencontainers.image.revision="${REVISION}"
COPY --chmod=0755 ${TARGETOS}/${TARGETARCH}/ifnh /ifnh
ENV HOME=/root
WORKDIR /work
ENTRYPOINT ["/ifnh"]
