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
image/      Dockerfile + install-gvisor.sh (self-contained installer image)
manifests/  daemonset.yaml, runtimeclass.yaml
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

## Deploy

```bash
kubectl apply -f manifests/daemonset.yaml
kubectl apply -f manifests/runtimeclass.yaml
```

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
- Next: package as a VKS ClusterBootstrap / Carvel addon, add uninstall path,
  pin a specific `GVISOR_RELEASE` instead of `latest`.
