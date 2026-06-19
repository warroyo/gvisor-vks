# gVisor for VKS

Runs your pods under [gVisor](https://gvisor.dev) on a VKS cluster. A DaemonSet
installs the `runsc` runtime on the nodes you choose and wires it into
containerd, and a `RuntimeClass` lets workloads opt in with one line:
`runtimeClassName: gvisor`.

It automates the manual
[gVisor + containerd setup](https://gvisor.dev/docs/user_guide/containerd/quick_start/)
so you don't have to touch nodes by hand.

## How it works

The installer runs as a DaemonSet on the node pool you label. On each node it:

1. Drops the `runsc` and `containerd-shim-runsc-v1` binaries into
   `/usr/local/bin`. They're baked into the image and checksum-verified, so the
   node never reaches out to the internet.
2. Registers the `runsc` runtime in the host's containerd config. If the config
   imports a `config.d` directory it writes a drop-in there; otherwise it
   appends the runtime block. Either way it leaves the rest of the config alone,
   and it handles both containerd 1.x (`version = 2`) and 2.x (`version = 3`).
3. Restarts containerd so the new runtime takes effect.

The work is idempotent. Once a node is set up the pod drops a marker file and
goes to sleep, so restarting the pod won't bounce containerd again.

gVisor only lands where you ask for it. The DaemonSet targets nodes labeled
`gvisor=enabled`, and the `RuntimeClass` carries the same selector — so a pod
asking for `runtimeClassName: gvisor` is automatically scheduled onto a node
that actually has `runsc`. Without that, the pod would land anywhere and
containerd would reject it with "runsc runtime not found".

## Install

You need an x86_64 node pool (VKS doesn't run arm), `helm`, and the installer
image reachable from the cluster. By default that's
`ghcr.io/warroyo/gvisor-installer` — make the GHCR package public or hand the
chart an `imagePullSecret`.

First, label the node pool you want gVisor on. Set the label in the VKS node
pool spec so new nodes inherit it:

```yaml
  nodePools:
    - name: gvisor-pool
      labels:
        gvisor: enabled
```

The installer is a privileged, host-mounting pod, and VKS enforces Pod Security
Admission `restricted` by default, which would reject it. Its namespace has to
be labeled `privileged`. Helm can't create the namespace it installs into
(Helm stores release state there before it applies anything), so create the
namespace first, then install the chart:

```bash
kubectl apply -f namespace.yaml
helm install gvisor charts/gvisor-vks -n gvisor-system
```

Watch it roll out — `Ready` should match the size of your gVisor pool:

```bash
kubectl -n gvisor-system rollout status ds/gvisor-gvisor-vks
```

## Running a sandboxed pod

Set `runtimeClassName: gvisor` and you're done. The pod schedules onto a gVisor
node on its own; you don't add a node selector:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: podinfo-gvisor
spec:
  runtimeClassName: gvisor
  securityContext:
    runAsNonRoot: true
    runAsUser: 65532
    runAsGroup: 65532
    seccompProfile:
      type: RuntimeDefault
  containers:
    - name: podinfo
      image: ghcr.io/stefanprodan/podinfo:latest
      securityContext:
        allowPrivilegeEscalation: false
        capabilities:
          drop: ["ALL"]
```

The `securityContext` satisfies Pod Security Admission `restricted`, which VKS
enforces by default, so the workload runs in any namespace. There's a
ready-to-apply version in [`examples/sandboxed-pod.yaml`](examples/sandboxed-pod.yaml):

```bash
kubectl apply -f examples/sandboxed-pod.yaml
```

### Confirming the sandbox

gVisor runs the container against its own user-space kernel, so the easiest
check is to read the kernel log from inside the pod:

```bash
kubectl exec podinfo-gvisor -- dmesg
```

You'll see gVisor's boot banner, which a normal `runc` container never prints:

```
[    0.000000] Starting gVisor...
[    0.183446] Rewriting the kernel in Rust...
[    0.245925] Reticulating splines...
[    0.534288] Creating bureaucratic processes...
...
[    2.264846] Ready!
```

`/proc/version` is the same story — it reports gVisor's faked `4.4.0` kernel
rather than the node's:

```bash
kubectl exec podinfo-gvisor -- cat /proc/version   # Linux version 4.4.0 ... gVisor
```

For a node-side check, the sandbox shows up as a `runsc` process instead of
`runc`:

```bash
NODE=$(kubectl get pod podinfo-gvisor -o jsonpath='{.spec.nodeName}')
# on that node:
ps aux | grep '[r]unsc'
```

## Configuration

Set these with `--set` or a values file:

| Value | Default | Purpose |
|-------|---------|---------|
| `image.repository` | `ghcr.io/warroyo/gvisor-installer` | installer image |
| `image.tag` | chart `appVersion` | pin an image tag |
| `nodeSelector` | `{gvisor: enabled}` | which pool to install on |
| `gvisor.release` | `latest` | gVisor release for the download fallback |
| `imagePullSecrets` | `[]` | for a private GHCR package |
| `runtimeClass.name` | `gvisor` | the name workloads reference |
| `tolerations`, `runtimeClass.tolerations` | `[]` | for a tainted pool |
| `namespace.name` | release namespace | override where resources land |

By default any workload can still schedule on the gVisor pool. To keep the pool
for gVisor only, taint it (for example `gvisor=enabled:NoSchedule`) and set both
`tolerations` and `runtimeClass.tolerations` to match.

## Uninstall

```bash
helm uninstall gvisor -n gvisor-system
```

This removes the DaemonSet and RuntimeClass but leaves the `runsc` binaries and
the containerd runtime entry on the nodes. They're inert once nothing requests
the `gvisor` runtime class.

---

## Developing

### Layout

```
image/                Dockerfile + install-gvisor.sh (the installer image)
charts/gvisor-vks/     Helm chart (DaemonSet + RuntimeClass)
namespace.yaml         privileged namespace, applied before the chart
examples/              sample sandboxed workloads
```

### The installer image

`runsc` and `containerd-shim-runsc-v1` are downloaded and checksum-verified when
the image is built, then baked in. At runtime the DaemonSet only pulls the image
— it never downloads binaries — which keeps it usable on airgapped clusters. The
image is x86_64 only.

If the baked binaries are ever missing, the script falls back to downloading
them from the gVisor release bucket (`wget` is kept in the image for that). The
normal path doesn't touch the network.

### CI

`.github/workflows/build-image.yml` builds and pushes to GHCR on every push to
`main` that touches `image/`, on `v*` tags, and on manual dispatch (where you
pick the `GVISOR_RELEASE`):

```
ghcr.io/warroyo/gvisor-installer:latest        # main
ghcr.io/warroyo/gvisor-installer:sha-<short>   # per commit
ghcr.io/warroyo/gvisor-installer:<tag>         # on v* tags
```

### Building locally

```bash
docker build -t ghcr.io/warroyo/gvisor-installer:latest image/
docker push ghcr.io/warroyo/gvisor-installer:latest
# pin a release: --build-arg GVISOR_RELEASE=20240101.0
```
