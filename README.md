# gVisor VKS Addon — Node Installer

Step 1 of the gVisor VKS addon: a DaemonSet that translates the manual
[gVisor + containerd quick start](https://gvisor.dev/docs/user_guide/containerd/quick_start/)
into an automated per-node install.

## What it does

On every node, the `gvisor-installer` DaemonSet:

1. Downloads `runsc` + `containerd-shim-runsc-v1` (sha512-verified) into the
   host `/usr/local/bin`.
2. Registers the `runsc` runtime handler in the host containerd config —
   additively. If `config.toml` imports a `config.d` dir, it writes a drop-in
   there; otherwise it appends the runtime block. Existing config untouched.
   Detects config `version = 2` (containerd 1.x) vs `version = 3` (2.x).
3. Restarts containerd on the host via `nsenter` into PID 1.

Idempotent. After a clean install it writes a sentinel and idles, so pod
restarts don't re-bounce containerd. A `RuntimeClass` named `gvisor` (handler
`runsc`) lets pods opt in.

## Layout

```
image/                Dockerfile + install-gvisor.sh (self-contained installer image)
charts/gvisor-vks/    Helm chart (DaemonSet + RuntimeClass)
```

## Build & push

`runsc` + `containerd-shim-runsc-v1` are fetched and sha512-verified at **build
time** and baked into the image. The DaemonSet does **no runtime download** —
only an image pull from the registry (airgap-friendly). x86_64 only.

### CI (default)

`.github/workflows/build-image.yml` builds and pushes to GHCR on every push to
`main` that touches `image/`, on `v*` tags, and via manual dispatch (where you
can pick the `GVISOR_RELEASE`). Published as:

```
ghcr.io/warroyo/gvisor-installer:latest      # main
ghcr.io/warroyo/gvisor-installer:sha-<short> # per commit
ghcr.io/warroyo/gvisor-installer:<tag>        # on v* tags
```

Make the GHCR package public, or add an imagePullSecret to the namespace.

### Local

```bash
docker build -t ghcr.io/warroyo/gvisor-installer:latest image/
docker push ghcr.io/warroyo/gvisor-installer:latest
# pin release: --build-arg GVISOR_RELEASE=20240101.0
```

> Fallback: if baked binaries are ever absent, the script downloads from the
> gVisor bucket at runtime (`wget` kept in the image for this). Normal path
> never touches the network.

## Targeting node pools

gVisor is confined to node pools labeled `gvisor=enabled` — it is **not**
installed cluster-wide. Two pieces key on that label:

- The installer DaemonSet has `nodeSelector: { gvisor: enabled }`, so runsc is
  installed only on that pool.
- The `gvisor` RuntimeClass has a `scheduling.nodeSelector` of the same label.
  The RuntimeClass admission controller injects it into every pod that sets
  `runtimeClassName: gvisor`, so those pods only land on nodes that have runsc.
  (Without it, a gvisor pod on a non-gvisor node fails at containerd:
  "runsc runtime not found".)

Set the label on the VKS node pool spec; nodes inherit it:

```yaml
  nodePools:
    - name: gvisor-pool
      labels:
        gvisor: enabled
```

No taint, so ordinary workloads may still schedule on the pool. To **dedicate**
a pool to gvisor instead, taint it (e.g. `gvisor=enabled:NoSchedule`) and set
both `tolerations` and `runtimeClass.tolerations` in chart values.

## Install (Helm)

```bash
helm install gvisor charts/gvisor-vks \
  --namespace gvisor-system --create-namespace
```

Common overrides (`--set` or a values file):

| Value | Default | Purpose |
|-------|---------|---------|
| `image.repository` | `ghcr.io/warroyo/gvisor-installer` | installer image |
| `image.tag` | `""` → chart appVersion | pin an image tag |
| `nodeSelector` | `{gvisor: enabled}` | which pool to install on |
| `gvisor.release` | `latest` | gVisor release (env, fallback path) |
| `tolerations` / `runtimeClass.tolerations` | `[]` | for a tainted/dedicated pool |
| `imagePullSecrets` | `[]` | if the GHCR package is private |
| `runtimeClass.name` | `gvisor` | RuntimeClass name workloads reference |

Uninstall: `helm uninstall gvisor -n gvisor-system`. (The installed runsc
binaries + containerd config on nodes are not removed by uninstall — a cleanup
DaemonSet is future work.)

## Use

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: nginx-gvisor
spec:
  runtimeClassName: gvisor
  containers:
    - name: nginx
      image: nginx
```

## Notes / TODO (later addon steps)

- Restarting containerd briefly disrupts the node's CRI; rollout is
  `maxUnavailable: 1` to limit blast radius.
- Pod runs `privileged` + `hostPID` — required for nsenter and host writes.
- Self-contained image (no node network pkg installs) for airgapped VKS.
- Next: wrap this chart as a VKS Carvel/ClusterBootstrap addon, add an uninstall
  cleanup path, pin a specific `GVISOR_RELEASE` instead of `latest`.
