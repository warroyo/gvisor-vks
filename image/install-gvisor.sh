#!/usr/bin/env bash
#
# install-gvisor.sh
#
# Runs inside the gvisor-installer DaemonSet pod on every node. Performs the
# three steps of the gVisor/containerd quick-start against the host:
#   1. Install runsc + containerd-shim-runsc-v1 into the host /usr/local/bin
#   2. Register the "runsc" runtime handler in the host containerd config
#      (additive: drop-in file when config.d imports exist, else append)
#   3. Restart containerd on the host via nsenter into PID 1
#
# The host root filesystem is mounted at ${HOST_ROOT} (default /host) and the
# host PID namespace is shared so nsenter can reach the host's systemd.
#
# Idempotent: safe to re-run. After a successful install the pod idles so the
# DaemonSet stays Ready without re-restarting containerd on every pod restart.

set -euo pipefail

HOST_ROOT="${HOST_ROOT:-/host}"
GVISOR_RELEASE="${GVISOR_RELEASE:-latest}"
GVISOR_BASE_URL="${GVISOR_BASE_URL:-https://storage.googleapis.com/gvisor/releases/release}"
BAKED_DIR="${BAKED_DIR:-/opt/gvisor}"          # binaries baked into image at build time
HOST_BIN_DIR="${HOST_BIN_DIR:-/usr/local/bin}"
CONTAINERD_CONFIG="${CONTAINERD_CONFIG:-/etc/containerd/config.toml}"
SENTINEL="${HOST_ROOT}${HOST_BIN_DIR}/.gvisor-installed"

log() { echo "[gvisor-installer] $*"; }

# x86_64 only (VKS does not support arm). Guard against unexpected node arch.
arch="$(uname -m)"
case "${arch}" in
  x86_64|amd64) : ;;
  *) log "FATAL: unsupported arch ${arch}; VKS/this addon is x86_64 only"; exit 1 ;;
esac

URL="${GVISOR_BASE_URL}/${GVISOR_RELEASE}/x86_64"

# --- step 1: install binaries -----------------------------------------------
# Prefer binaries baked into the image (no runtime internet). Fall back to
# downloading from the gVisor release bucket only if they are absent.
install_binaries() {
  install -d "${HOST_ROOT}${HOST_BIN_DIR}"

  if [ -x "${BAKED_DIR}/runsc" ] && [ -x "${BAKED_DIR}/containerd-shim-runsc-v1" ]; then
    log "installing baked-in binaries from ${BAKED_DIR} (no download)"
    install -m 0755 "${BAKED_DIR}/runsc" "${HOST_ROOT}${HOST_BIN_DIR}/runsc"
    install -m 0755 "${BAKED_DIR}/containerd-shim-runsc-v1" "${HOST_ROOT}${HOST_BIN_DIR}/containerd-shim-runsc-v1"
    log "binaries installed to ${HOST_BIN_DIR}"
    return
  fi

  log "no baked binaries; downloading runsc + shim from ${URL}"
  local tmp; tmp="$(mktemp -d)"
  pushd "${tmp}" >/dev/null

  wget -q "${URL}/runsc" "${URL}/runsc.sha512" \
          "${URL}/containerd-shim-runsc-v1" "${URL}/containerd-shim-runsc-v1.sha512"

  log "verifying sha512 checksums"
  sha512sum -c runsc.sha512
  sha512sum -c containerd-shim-runsc-v1.sha512

  chmod a+rx runsc containerd-shim-runsc-v1
  # install (not mv) to handle the busy-binary case atomically
  install -m 0755 runsc "${HOST_ROOT}${HOST_BIN_DIR}/runsc"
  install -m 0755 containerd-shim-runsc-v1 "${HOST_ROOT}${HOST_BIN_DIR}/containerd-shim-runsc-v1"

  popd >/dev/null
  rm -rf "${tmp}"
  log "binaries installed to ${HOST_BIN_DIR}"
}

# --- step 2: register runsc runtime in containerd config ---------------------
# Detect config schema version (2 vs 3) to pick the correct CRI plugin key.
runtime_block() {
  local cfg="$1"
  local plugin_key='io.containerd.grpc.v1.cri'        # config version 2 (containerd 1.x)
  if grep -Eq '^[[:space:]]*version[[:space:]]*=[[:space:]]*3' "${cfg}" 2>/dev/null; then
    plugin_key='io.containerd.cri.v1.runtime'         # config version 3 (containerd 2.x)
  fi
  cat <<EOF
[plugins."${plugin_key}".containerd.runtimes.runsc]
  runtime_type = "io.containerd.runsc.v1"
EOF
}

configure_containerd() {
  local main="${HOST_ROOT}${CONTAINERD_CONFIG}"
  install -d "$(dirname "${main}")"
  [ -f "${main}" ] || { log "WARN: ${CONTAINERD_CONFIG} missing, creating minimal"; printf 'version = 2\n' > "${main}"; }

  if grep -q 'containerd.runtimes.runsc' "${main}" 2>/dev/null \
     || grep -rq 'containerd.runtimes.runsc' "${HOST_ROOT}/etc/containerd/config.d" 2>/dev/null; then
    log "runsc runtime already present in containerd config; skipping patch"
    return
  fi

  # Does the main config import a config.d drop-in directory?
  local dropin_dir=""
  if grep -Eq '^[[:space:]]*imports' "${main}"; then
    dropin_dir="$(grep -Eo '/[^"]*config\.d' "${main}" | head -n1 || true)"
  fi

  if [ -n "${dropin_dir}" ]; then
    install -d "${HOST_ROOT}${dropin_dir}"
    local f="${HOST_ROOT}${dropin_dir}/runsc.toml"
    runtime_block "${main}" > "${f}"
    log "wrote drop-in ${dropin_dir}/runsc.toml"
  else
    log "no config.d import found; appending runsc block to ${CONTAINERD_CONFIG}"
    { echo ""; echo "# gvisor-installer: runsc runtime handler"; runtime_block "${main}"; } >> "${main}"
  fi
}

# --- step 3: restart containerd on the host ---------------------------------
restart_containerd() {
  log "restarting containerd on host via nsenter PID 1"
  # Enter host mount/UTS/IPC/net/PID namespaces and run systemctl on the host.
  nsenter -t 1 -m -u -i -n -p -- systemctl restart containerd
  log "containerd restarted"
}

# --- main -------------------------------------------------------------------
install_binaries
configure_containerd

# Only restart when something actually changed since the last successful run.
if [ -f "${SENTINEL}" ]; then
  log "sentinel present; binaries/config refreshed, skipping containerd restart"
else
  restart_containerd
  touch "${SENTINEL}"
fi

log "install complete; idling"
exec sleep infinity
