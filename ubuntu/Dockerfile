# Ubuntu 26.04 + XFCE in the browser (Selkies, websocket on :3000). Chromium,
# xfce4-terminal and mousepad come with the base. s6 init runs as root and drops
# to `abc` (PUID/PGID); $HOME is /config — the PVC.
FROM lscr.io/linuxserver/webtop:ubuntu-xfce-621de5cf-ls1

ARG RCLONE_VERSION=1.75.1

RUN apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      ca-certificates curl wget git openssh-client \
      python3 python3-pip python3-venv pipx \
      vim nano jq less htop procps zip unzip \
      dnsutils iputils-ping iproute2 netcat-openbsd traceroute \
 && rm -rf /var/lib/apt/lists/* \
# ping via unprivileged ICMP sockets (pod sysctl net.ipv4.ping_group_range), not
# cap_net_raw: runtimes that drop NET_RAW refuse to even exec a binary carrying it.
 && setcap -r /usr/bin/ping
# apt's hook pokes PackageKit over the system bus after every install; D-Bus can't
# start it in a container, so `sudo apt install` ended in a (harmless) error.
 && rm /etc/apt/apt.conf.d/20packagekit

# Official release, not the distro package (which lags), checked against its SHA256SUMS.
RUN cd /tmp \
 && curl -fsSLO https://downloads.rclone.org/v${RCLONE_VERSION}/rclone-v${RCLONE_VERSION}-linux-amd64.deb \
 && curl -fsSL https://downloads.rclone.org/v${RCLONE_VERSION}/SHA256SUMS | grep " rclone-v${RCLONE_VERSION}-linux-amd64.deb$" | sha256sum -c - \
 && dpkg -i rclone-v${RCLONE_VERSION}-linux-amd64.deb \
 && rm rclone-v${RCLONE_VERSION}-linux-amd64.deb

# GTK (26.04) decodes every icon/wallpaper through glycin, which sandboxes the
# decoder with bwrap. In a container bwrap gets a user namespace but can't mount
# /dev/pts — an error glycin doesn't recognise, so it doesn't fall back, GTK
# aborts, and xfce4-panel/wallpaper die (black desktop). This stub fails with the
# message glycin does recognise, so it runs the decoders unsandboxed.
# ponytail: decoders lose their inner sandbox (the container is the boundary);
# drop the stub once upstream glycin/webtop handles this.
RUN printf '%s\n' '#!/bin/sh' \
      'echo "bwrap: No permissions to create a new namespace, likely because the kernel does not allow non-privileged user namespaces." >&2' \
      'exit 1' > /usr/bin/bwrap \
 && chmod 755 /usr/bin/bwrap
