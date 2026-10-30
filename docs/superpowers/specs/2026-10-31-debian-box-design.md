# Debian box: replace ubuntu-box with a lighter Debian XFCE desktop

Date: 2026-10-31. Status: approved in chat, awaiting spec review.

## Why

- **Crash.** On 2026-10-12 13:52 UTC Chromium pushed the desktop container past
  its 1 GiB limit. The kernel killed `chromium`, `pulseaudio` and `s6-svscan`,
  and the session restarted.
- **WARP leak.** `warp-svc` grows to its 256 MiB limit and is OOM-killed about
  every 1.6 days: 12 times since 2026-10-11. Each kill means a few seconds
  offline, with no leak.
- **Ubuntu feels heavy.**

## Goals and non-goals

- **Needs:**
  - a GUI with a web browser, file manager and editor;
  - CLI work: rclone, Python scripts, network tools;
  - egress through WARP;
  - a persistent home.
- **Success means no browser OOM crashes.** Speed and server load were not
  raised as problems.
- **Not changing:**
  - the streaming stack (Selkies);
  - the window manager (XFCE);
  - the access path (cloudflared and Cloudflare Access);
  - the security model:
    - no Kubernetes token in the box;
    - the box's NetworkPolicy;
    - the host nftables rule that blocks the node's public IP;
    - the WARP kill switch;
    - `NET_RAW` dropped;
    - exec probes only.
- **Budget:** the CX33 only, with about 1.9 GiB free on the node (measured
  2026-10-30).

A distro change alone does not fix the crash: a browser with a few tabs needs
about 1 GiB on any distro. The fix is the memory limit; Debian lowers the
idle baseline and the number of workarounds.

## Design

### 1. Image: `linux-box/debian/`

**Base.** `FROM lscr.io/linuxserver/webtop:debian-xfce-<version>`, pinned to the newest
versioned tag when it is built, like the Ubuntu image.

**Carried over from `ubuntu/Dockerfile`:**
- the CLI packages:
  - `ca-certificates curl wget git openssh-client`
  - `python3 python3-pip python3-venv pipx`
  - `vim nano jq less htop procps zip unzip`
  - `dnsutils iputils-ping iproute2 netcat-openbsd traceroute`
  - Debian package names are confirmed at build time.
- `setcap -r /usr/bin/ping`, because the pod drops `NET_RAW`;
- the official rclone `.deb`, checked against its `SHA256SUMS`;
- the `/etc/bash.bashrc` PATH fix, so terminals get the system Python instead
  of `/lsiopy`;
- `HOME=/home/abc` and the s6 oneshot `init-home`, ordered after
  `init-adduser` and before `init-selkies-config`.

**Kept only if the Debian base needs them.** Each is checked on the real image
before it is dropped:
- **PackageKit apt hook removal:** check whether
  `/etc/apt/apt.conf.d/20packagekit` exists.
- **`bwrap` stub:** check whether the desktop renders without it, with the
  panel and wallpaper alive.

**Gate.** Before any cluster change:
1. Run `ubuntu-xfce` (the current image) and `debian-xfce` locally under
   podman with no client connected.
2. Compare idle RSS of the whole container.
3. If Debian is not lighter, stop and report.

### 2. Memory (chart `values.yaml`, shared)

- `resources.limits.memory`: `1Gi` → `1.5Gi`. The request stays at `256Mi`.
- `shmSize` stays at 512Mi. `MAX_RES` stays at 3840x2160 (about 56 MB more
  than FHD).

### 3. WARP sidecar

- **Rebuild** the image so it picks up the current `cloudflare-warp`.
- **Memory limit** `256Mi` → `384Mi` (`warp.resources.limits.memory`).
- **Remove** the `ct state established,related accept` rule from
  `killswitch.nft`. It has been unnecessary since the probes became exec
  probes.
- **Watch** restarts for 7 days after the rollout. If OOM kills continue,
  propose a daily restart at a quiet hour as a separate change.

### 4. Homelab wiring (`~/Projects/personal/hetzner/new`)

**New files:**
- `helm/linux-box/values.debian.yaml`: `image.repository:
  ghcr.io/nopsqi/linux-box-debian`, plus a hostname comment;
- `helm/linux-box/values.debian.prod.yaml`: `image.tag`, bumped by CI;
- `argocd/prod/linux-box-debian.yaml`: namespace `linux-box-debian`, target
  revision `prod`. Value files:
  - `values.yaml`
  - `values.debian.yaml`
  - `values.debian.prod.yaml`
  - `values.warp.prod.yaml`

**Edits:**
- `helm/cloudflared/values.yaml`: add a `debian-box.nopsqi.dev` route to
  `http://linux-box-service.linux-box-debian.svc.cluster.local:3000`;
- `helm/assistant/values.yaml`: add `linux-box-debian` to `logNamespaces`.

**Check:** confirm the host nftables rule that blocks the node's public IP
(from commit `cccf9e6`) applies to pods in `linux-box-debian`, not only
`linux-box-ubuntu`.

**CI:**
- add `debian` to the build matrix in `.github/workflows/build.yml`;
- during the transition the matrix is `[ubuntu, debian, warp]`;
- after cutover it is `[debian, warp]`;
- changes reach production through the existing master → prod promotion PR.

**Ordering.** Push the Application file, and let it reach prod, before
anything depends on a value file it lists. See the memory note on
ComparisonError.

### 5. Cutover

1. Deploy debian-box alongside ubuntu-box. Both running costs about +0.3 GiB.
2. **User:** create the DNS record for `debian-box.nopsqi.dev` in the
   Cloudflare dashboard, and an Access application with the same policy as
   ubuntu-box.
3. Copy the home:
   - scale both Deployments to 0;
   - on the node, `rsync -aHAX` the ubuntu local-path volume into the debian
     one, keeping numeric owners;
   - confirm `abc`'s UID and GID match in both images first;
   - scale debian back to 1.
4. **User:** use debian-box and confirm it works.
5. Remove ubuntu-box:
   - delete its Application, cloudflared route, `values.ubuntu*.yaml`,
     `ubuntu/` and its CI matrix entry, and drop `linux-box-ubuntu` from the
     assistant's `logNamespaces`;
   - its home PVC survives the removal (`Prune=false,Delete=false`), and is
     deleted only on the user's explicit OK;
   - **user:** remove the `ubuntu-box` DNS record and Access application.

## Verification (definition of done)

- **Pod:** `linux-box-debian` is 2/2 Ready, and ArgoCD shows Synced/Healthy.
- **Egress:** from the box, `cdn-cgi/trace` shows `warp=on` over IPv4 and
  IPv6.
- **Kill switch:** with WARP killed in the throwaway pod, nothing gets out
  directly.
- **`ping`** works, and `CapBnd` has no `NET_RAW`.
- **Node IP blocked:** a request to the node's public IP on port 6443 times
  out.
- **Desktop:** it renders, with panel and wallpaper.
- **Browser memory:** Chromium with 5 real tabs keeps the container under
  1.5 GiB. Record peak memory from `kubectl top` and the cgroup.
- **Home:** the user's files (`.python_history`, rclone config, `.config`) are
  present and owned by `abc`.
- **WARP leak:** 7 days after rollout, record the WARP sidecar's restart
  count and reasons.
