# Self-contained installer image. Binaries are baked in at BUILD time so the
# DaemonSet needs NO runtime internet — only an image pull from your registry.
# x86_64 only (VKS does not support arm).
#
# Build:
#   docker build -t REGISTRY/gvisor-installer:latest image/
#
# Pin a release instead of latest with: --build-arg GVISOR_RELEASE=20240101.0

# ---- stage 1: fetch + verify runsc binaries at build time ------------------
FROM debian:stable-slim AS fetch
ARG GVISOR_RELEASE=latest
ARG GVISOR_BASE_URL=https://storage.googleapis.com/gvisor/releases/release

RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates wget coreutils \
 && rm -rf /var/lib/apt/lists/*

RUN set -eux; \
    URL="${GVISOR_BASE_URL}/${GVISOR_RELEASE}/x86_64"; \
    mkdir -p /opt/gvisor; cd /opt/gvisor; \
    wget -q "${URL}/runsc" "${URL}/runsc.sha512" \
            "${URL}/containerd-shim-runsc-v1" "${URL}/containerd-shim-runsc-v1.sha512"; \
    sha512sum -c runsc.sha512; \
    sha512sum -c containerd-shim-runsc-v1.sha512; \
    rm -f ./*.sha512; \
    chmod 0755 runsc containerd-shim-runsc-v1

# ---- stage 2: runtime image ------------------------------------------------
FROM debian:stable-slim

# bash for the script, util-linux for nsenter (host containerd restart).
# wget + ca-certificates kept only for the rare download fallback when baked
# binaries are absent; the normal path does no runtime network access.
RUN apt-get update \
 && apt-get install -y --no-install-recommends bash util-linux coreutils wget ca-certificates \
 && rm -rf /var/lib/apt/lists/*

COPY --from=fetch /opt/gvisor/ /opt/gvisor/
COPY install-gvisor.sh /usr/local/bin/install-gvisor.sh
RUN chmod +x /usr/local/bin/install-gvisor.sh

ENTRYPOINT ["/usr/local/bin/install-gvisor.sh"]
