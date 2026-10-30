# Debian Box Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace ubuntu-box with a Debian XFCE box (debian-box.nopsqi.dev)
that doesn't OOM-crash on browsing. Also stop the WARP sidecar's OOM loop.

**Architecture:** This is the same pod shape as today: the webtop desktop plus
a native WARP sidecar, deployed by the shared homelab chart `helm/linux-box`.
1. Add a `debian/` image beside `ubuntu/`.
2. Deploy it as a second Application, `linux-box-debian`.
3. Copy the home volume over on the node.
4. Remove the ubuntu box.

**Tech Stack:**
- linuxserver webtop `debian-xfce` with Selkies, s6-overlay;
- Cloudflare WARP sidecar with an nftables kill switch;
- Helm, ArgoCD (branch `prod`), k3s, local-path PVCs;
- GitHub Actions to GHCR, then CI tag bumps on homelab `master` and a
  master → prod PR.

**Spec:** `docs/superpowers/specs/2026-10-31-debian-box-design.md`

**Repos:**
- `~/Projects/personal/linux-box` (LB): commit straight to `main`.
- `~/Projects/personal/hetzner/new` (HL): commit to `master`. Prod only
  changes through the `master → prod` PR, which the user merges.
- HL is public: never write the node's public IP into a tracked file or a
  commit.
- HL's working tree has the user's own uncommitted `README.md` edit: never
  stage it.

## Global Constraints

- Desktop memory: `resources.limits.memory: "1.5Gi"`, request stays `256Mi`.
  `shmSize` stays `512Mi`, `MAX_RES` stays `3840x2160`.
- WARP sidecar memory: `warp.resources.limits.memory: "384Mi"`.
- Names:
  - image `ghcr.io/nopsqi/linux-box-debian`;
  - namespace and Application `linux-box-debian`;
  - host `debian-box.nopsqi.dev`;
  - cloudflared target
    `http://linux-box-service.linux-box-debian.svc.cluster.local:3000`.
- Keep the security model unchanged:
  - no service account token;
  - the box's NetworkPolicy;
  - the kill switch;
  - `NET_RAW` dropped;
  - exec probes only;
  - the home PVC keeps `Prune=false,Delete=false`.
- The host's node-IP block, `ansible/roles/common/templates/homelab.nft.j2`,
  matches `ip saddr 10.42.0.0/16`. It covers every pod whatever the namespace,
  so no Ansible change is needed (checked 2026-10-31).
- Any push to LB `main` builds every matrix image and bumps HL `master`. So
  push LB only when its commit is meant to ship.

## Review Focus

1. **A fresh, empty home on Debian.** `init-home` must seed `/etc/skel` and
   hand ownership to `abc` before Selkies writes there. If not, the desktop
   starts with root-owned dotfiles.
2. **`abc`'s UID and GID differ between the images.** Then the copied home
   would be owned by the wrong user and the desktop can't write its config.
   Checked in Task 1 and again in Task 6.
3. **The kill switch after the WARP rebuild.** A newer `cloudflare-warp` could
   change its fwmark from `0x100cf` or its interface name from
   `CloudflareWARP`. Then traffic would either be blocked entirely or leak.
   Task 3 re-runs the local leak test against the new build.
4. **Chromium on Debian still OOMs at 1.5Gi** with 5 real tabs. Task 5
   measures the peak.
5. **Ordering between the Application and its value files.** The promotion PR
   must carry the Application and the value files it lists in the same prod
   commit. Task 4 puts them in one HL commit.

---

### Task 1: Gate: is Debian lighter? Facts for the Dockerfile

**Files:** none. The output is numbers and facts, recorded in Task 2's
commit message.

**Produces:**
- `DEBIAN_TAG`: the newest `debian-xfce-<version>` tag;
- idle memory of Ubuntu vs Debian;
- `abc`'s UID and GID in each image;
- whether `/etc/apt/apt.conf.d/20packagekit` exists;
- whether the desktop renders without the `bwrap` stub.

- [ ] **Step 1: Find `DEBIAN_TAG`**

  Read the newest `debian-xfce-…-ls…` release on
  `https://github.com/linuxserver/docker-webtop/releases`. Do not list every
  registry tag with `skopeo list-tags`: it ran past 2 minutes.

- [ ] **Step 2: Run both bases idle, with nothing connected**

  ```bash
  podman run -d --name gate-ubuntu --shm-size=512m -e MAX_RES=3840x2160 -e NO_GAMEPAD=true ghcr.io/nopsqi/linux-box-ubuntu:sha-6bef723
  podman run -d --name gate-debian --shm-size=512m -e MAX_RES=3840x2160 -e NO_GAMEPAD=true lscr.io/linuxserver/webtop:$DEBIAN_TAG
  ```

  Wait 3 minutes, then run
  `podman stats --no-stream --format '{{.Name}} {{.MemUsage}}' gate-ubuntu gate-debian`.

  **Expected:** Debian's memory is lower. If it isn't, stop and report to
  the user.

- [ ] **Step 3: Collect the facts from the Debian base**

  In `gate-debian`:
  - `id abc` prints the UID and GID. Compare with `gate-ubuntu`; they must
    match.
  - `ls /etc/apt/apt.conf.d/20packagekit` says whether the PackageKit hook
    exists.
  - `pgrep -a xfce4-panel; pgrep -a xfdesktop` must both print a process.
  - `podman logs gate-debian 2>&1 | grep -i -E 'glycin|bwrap|abort'` must
    print nothing.

  If the panel or desktop process is missing, or glycin/bwrap errors show up,
  the `bwrap` stub stays.

- [ ] **Step 4: Clean up**

  `podman rm -f gate-ubuntu gate-debian`. Keep the pulled images: Task 2
  reuses the Debian one.

### Task 2: `debian/Dockerfile`

**Files:**
- Create: `debian/Dockerfile`, copied from `ubuntu/Dockerfile` and then
  changed as listed below.

**Consumes:** Task 1's facts.

**Produces:** the local image `linux-box-debian:test`.

- [ ] **Step 1: Write `debian/Dockerfile`**

  - **Header comment:** say "Debian + XFCE" instead of Ubuntu.
  - **`FROM`:** `lscr.io/linuxserver/webtop:$DEBIAN_TAG`.
  - **apt layer:** same package list. Keep `setcap -r /usr/bin/ping`.
  - **PackageKit:** keep `rm /etc/apt/apt.conf.d/20packagekit` only if Task 1
    found the file.
  - **rclone:** same layer, same `ARG RCLONE_VERSION=1.75.1`.
  - **`bwrap` stub:** keep only if Task 1 Step 3 failed without it.
  - **Unchanged:** the `/etc/bash.bashrc` PATH fix and the `init-home` s6
    block.

- [ ] **Step 2: Build**

  `podman build -t linux-box-debian:test debian`

  **Expected:** it exits 0. If a package name differs on Debian (for example
  `dnsutils`), use the Debian name and note it in the commit.

- [ ] **Step 3: Run it the way the pod does**

  ```bash
  podman volume create gate-home
  podman run -d --name gate --shm-size=512m -v gate-home:/home/abc -e NO_GAMEPAD=true linux-box-debian:test
  ```

  Let it settle for 60 seconds.

- [ ] **Step 4: Verify inside `gate`. Every line must hold:**

  - `stat -c '%U' /home/abc /home/abc/.bashrc` prints `abc abc`. This covers
    Review Focus 1, the empty home.
  - `sudo -u abc bash -ic 'command -v python3 pip'` prints `/usr/bin/…`, not
    `/lsiopy`.
  - `rclone version | head -1` prints `rclone v1.75.1`.
  - `getcap /usr/bin/ping` prints nothing.
  - `pgrep xfce4-panel && pgrep xfdesktop` both succeed.

- [ ] **Step 5: Clean up and commit**

  ```bash
  podman rm -f gate && podman volume rm gate-home
  git add debian/Dockerfile
  git commit
  ```

  Commit message: `feat: debian xfce desktop image`. In the body, put
  Task 1's idle-memory numbers, the UID/GID check, and which Ubuntu
  workarounds were dropped and why.

### Task 3: WARP sidecar refresh

**Files:**
- Modify: `warp/killswitch.nft`. Delete the `ct state established,related
  accept` line and its two-line comment.

**Produces:** an unchanged interface:
- fwmark `0x100cf`;
- interface name `CloudflareWARP`;
- `/start.sh` as the entrypoint.

- [ ] **Step 1: Edit `killswitch.nft`**

  Make the deletion above.

- [ ] **Step 2: Rebuild fresh, so apt pulls the current `cloudflare-warp`**

  `podman build --no-cache -t lbw:t warp`

  Record the version with
  `podman run --rm --entrypoint warp-cli lbw:t --version`.

- [ ] **Step 3: Re-run the local leak test, covering Review Focus 3**

  Run the sidecar with `--security-opt label=disable --cap-add NET_ADMIN
  --device /dev/net/tun -p 18080:8080`, and `python:3-alpine` running
  `python -m http.server 8080` in `--network container:<sidecar>`, as on
  2026-09-29.

  **Expected:**
  - `curl 127.0.0.1:18080` returns `200`;
  - `cdn-cgi/trace` from the app container shows `warp=on`;
  - after `pkill warp-svc`, a request from the app to `https://github.com`
    is blocked;
  - `nft list ruleset` still shows `meta mark 0x100cf` in
    `inet cloudflare-warp`. If the mark changed, update `killswitch.nft` to
    match and repeat this step.

- [ ] **Step 4: Clean up and commit**

  Remove the containers and images. Then:

  ```bash
  git add warp/killswitch.nft
  git commit
  ```

  Commit message: `fix(warp): drop unused conntrack rule; rebuild for
  cloudflare-warp <version>`.

### Task 4: CI matrix and homelab wiring, shipped together

**Files:**
- LB, modify `.github/workflows/build.yml`: `image: [ubuntu, debian, warp]`
  in both matrices, `build` and `helm`.
- HL, create:
  - `helm/linux-box/values.debian.yaml`: `image.repository:
    ghcr.io/nopsqi/linux-box-debian`, with a header comment like
    `values.ubuntu.yaml` that names `debian-box.nopsqi.dev`;
  - `helm/linux-box/values.debian.prod.yaml`: the same header as
    `values.ubuntu.prod.yaml`, plus `image.tag: sha-<LB HEAD short sha after
    Step 1>`;
  - `argocd/prod/linux-box-debian.yaml`: a copy of
    `argocd/prod/linux-box-ubuntu.yaml` with `name` and `namespace` set to
    `linux-box-debian`. Value files: `values.yaml`, `values.debian.yaml`,
    `values.debian.prod.yaml`, `values.warp.prod.yaml`.
- HL, modify:
  - `helm/linux-box/values.yaml`: `resources.limits.memory: "1.5Gi"` and
    `warp.resources.limits.memory: "384Mi"`. Update the comments to say
    why: the Oct 12 Chromium OOM, and warp-svc reaching 256Mi about every
    1.6 days;
  - `helm/cloudflared/values.yaml`: add a `debian-box.nopsqi.dev` ingress
    entry above the catch-all, pointing at the cloudflared target in Global
    Constraints;
  - `helm/assistant/values.yaml`: add `linux-box-debian` to
    `logNamespaces`, keeping alphabetical order.

**Consumes:** the LB commits from Tasks 2 and 3.

- [ ] **Step 1: Commit the LB workflow change locally**

  Commit message: `ci: build the debian image`. Note `git rev-parse --short
  HEAD`: that is the tag every image gets.

- [ ] **Step 2: Write the HL files, then validate before any push**

  ```bash
  helm template t helm/linux-box -f helm/linux-box/values.yaml -f helm/linux-box/values.debian.yaml \
    -f helm/linux-box/values.debian.prod.yaml -f helm/linux-box/values.warp.prod.yaml \
    | kubectl apply --dry-run=server -n linux-box-ubuntu -f -
  ```

  **Expected:** every object prints `(server dry run)` with no error. Also
  run `git diff --cached` and grep it for IPv4 addresses: expect none.

- [ ] **Step 3: Commit HL as one commit (Review Focus 5) and push to `master`**

  Commit message: `feat(linux-box): debian-box alongside ubuntu-box; 1.5Gi
  desktop, 384Mi warp`.

  `master` doesn't deploy prod, so this push changes nothing live yet.

- [ ] **Step 4: Push LB `main` and wait for CI**

  `gh run watch <id> --exit-status`

  **Expected:**
  - `build (ubuntu|debian|warp)` and `helm (…)` all succeed;
  - HL `master` gains the CI tag-bump commits for ubuntu and warp. Debian's
    tag already matches;
  - a `promote: master -> prod` PR is open.

- [ ] **Step 5: Hand off to the user**

  Ask the user to:
  1. merge the promotion PR (the auto-mode classifier blocks Claude from
     merging);
  2. in the Cloudflare dashboard, add a DNS record for
     `debian-box.nopsqi.dev` pointing at the tunnel, plus an Access
     application with ubuntu-box's policy.

### Task 5: Verify debian-box on the cluster

**Consumes:** the merged PR and the user's dashboard changes.

- [ ] **Step 1: Wait for ArgoCD**

  Wait until `kubectl -n argocd get application linux-box-debian` shows
  `Synced Healthy`, and the pod in `linux-box-debian` is `2/2`.

  Also check that ubuntu-box rolled to `1.5Gi` and its WARP sidecar to
  `384Mi`:
  `kubectl get deploy -A -l app=linux-box -o jsonpath=…resources`.

- [ ] **Step 2: Network checks from `deploy/linux-box-deployment -c linux-box`
  in `linux-box-debian`. Expected:**

  - `curl -s cdn-cgi/trace` shows `warp=on`, and so does `curl -4 -s …`;
  - `ping -c1 1.1.1.1` gets 1 received;
  - `grep CapBnd /proc/self/status` shows `00000000a80405fb`;
  - `curl -sk --max-time 5 https://<node-ip>:6443` exits with code 28. Read
    the node IP from `kubectl get node` at runtime and never echo it.

- [ ] **Step 3: Desktop and browser memory (Review Focus 4)**

  The user opens `https://debian-box.nopsqi.dev`, checks that the panel and
  wallpaper render, and opens Chromium with 5 real sites.

  Meanwhile, sample `kubectl top pod --containers` and the cgroup's peak:
  `cat /sys/fs/cgroup/memory.peak` in the container.

  **Expected:** the peak stays under 1.5Gi and the pod's `restartCount`
  stays the same. If not, report the peak and stop.

### Task 6: Copy the home volume

**Files:** none (cluster operation).

- [ ] **Step 1: Find both PVs' host paths**

  For each of `linux-box-ubuntu` and `linux-box-debian`, run
  `kubectl get pvc linux-box-home -o jsonpath='{.spec.volumeName}'`. Then
  read `spec.hostPath.path` (or `local.path`) from the PV.

- [ ] **Step 2: Check `abc`'s IDs (Review Focus 2)**

  `ssh root@100.64.67.55 'stat -c "%u:%g" <ubuntu-path> <debian-path>'`
  must show the same UID and GID twice. If they differ, stop: the copy needs
  a `chown` mapping. Report to the user.

- [ ] **Step 3: Make sure neither box is in use**

  Ask the user to close both browser tabs and confirm. Don't scale the
  Deployments to 0: ArgoCD selfHeal restores `replicas: 1`, and pausing
  auto-sync doesn't hold either, because the root app re-syncs the
  Application's settings.

- [ ] **Step 4: Copy on the node**

  `rsync -aHAX --numeric-ids <ubuntu-path>/ <debian-path>/`

  Ubuntu's home overwrites the fresh seed in the Debian volume.

  **Expected:** it exits 0, and `du -s --apparent-size` of the two
  directories matches within a few KB.

- [ ] **Step 5: Restart debian and check the home**

  `kubectl -n linux-box-debian delete pod -l app=linux-box`, so the session
  starts on the copied home. Wait for `2/2`.

  In the box, `ls -la /home/abc` must show `.python_history`,
  `.config/rclone` (if it existed) and `.config`, all owned by `abc`. The
  user confirms their files are there.

### Task 7: Remove ubuntu-box

**Gate:** the user has said debian-box works.

**Files:**
- LB: delete `ubuntu/`. In `.github/workflows/build.yml`, set both matrices
  to `[debian, warp]`.
- HL:
  - delete `argocd/prod/linux-box-ubuntu.yaml`,
    `helm/linux-box/values.ubuntu.yaml` and
    `helm/linux-box/values.ubuntu.prod.yaml`;
  - remove the `ubuntu-box.nopsqi.dev` entry from
    `helm/cloudflared/values.yaml`;
  - remove `linux-box-ubuntu` from `helm/assistant/values.yaml`
    `logNamespaces`.

- [ ] **Step 1: Validate, commit and push HL**

  Run Task 4 Step 2's dry-run, then commit and push to `master`. Commit
  message: `chore(linux-box): retire ubuntu-box`.

- [ ] **Step 2: Commit and push LB**

  Commit message: `chore: retire the ubuntu image`. Wait for CI as in Task 4
  Step 4. **Expected:** `build (debian|warp)` succeeds and there is no
  `ubuntu` job.

- [ ] **Step 3: Hand off to the user**

  Ask the user to:
  1. merge the promotion PR;
  2. remove the `ubuntu-box` DNS record and Access application;
  3. decide whether to delete the leftover PVC `linux-box-home` in namespace
     `linux-box-ubuntu`. It survives the removal on purpose. Delete it only
     on their explicit OK.

- [ ] **Step 4: Verify**

  - The `linux-box-ubuntu` Application is gone.
  - The ubuntu pods are gone.
  - `linux-box-debian` is still `Synced Healthy`.

- [ ] **Step 5: Update memory**

  Update `linux-box-project.md` and `MEMORY.md`:
  - the box is now debian-box;
  - the 1.5Gi and 384Mi limits;
  - the ubuntu-specific gotchas: bwrap/glycin (if it was dropped) and
    PackageKit.

### Task 8: WARP follow-up, 7 days after Task 5

- [ ] **Step 1: Check the WARP sidecar's restarts**

  Record the restart count and reasons:
  `kubectl -n linux-box-debian get pod -l app=linux-box -o jsonpath='{.items[0].status.initContainerStatuses[0].restartCount} {.items[0].status.initContainerStatuses[0].lastState.terminated.reason}'`.
  Also check the node kernel log for `warp-svc` OOM kills.

  **Expected:** 0 OOM kills. If there are any, report them and propose the
  daily restart as a separate change. Don't build it within this plan.
