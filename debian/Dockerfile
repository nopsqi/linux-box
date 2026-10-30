# Debian 13 + XFCE in the browser (Selkies, websocket on :3000). Chromium,
# xfce4-terminal and mousepad come with the base. s6 init runs as root and drops
# to `abc` (PUID/PGID); $HOME is /home/abc (the PVC).
FROM lscr.io/linuxserver/webtop:debian-xfce-536c698c-ls219

ARG RCLONE_VERSION=1.75.1

# ping works through unprivileged ICMP sockets (pod sysctl net.ipv4.ping_group_range);
#   Debian ships it without cap_net_raw, which matters: the pod drops NET_RAW, and a
#   binary carrying that file capability couldn't even be exec'd.
RUN apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      ca-certificates curl wget git openssh-client \
      python3 python3-pip python3-venv pipx \
      vim nano jq less htop procps zip unzip \
      dnsutils iputils-ping iproute2 netcat-openbsd traceroute \
 && rm -rf /var/lib/apt/lists/*

# Official release, not the distro package (which lags), checked against its SHA256SUMS.
RUN cd /tmp \
 && curl -fsSLO https://downloads.rclone.org/v${RCLONE_VERSION}/rclone-v${RCLONE_VERSION}-linux-amd64.deb \
 && curl -fsSL https://downloads.rclone.org/v${RCLONE_VERSION}/SHA256SUMS | grep " rclone-v${RCLONE_VERSION}-linux-amd64.deb$" | sha256sum -c - \
 && dpkg -i rclone-v${RCLONE_VERSION}-linux-amd64.deb \
 && rm rclone-v${RCLONE_VERSION}-linux-amd64.deb

# The base puts Selkies' private venv (/lsiopy) first on PATH, so in a terminal
# python3/pip were Selkies' own — and `sudo pip install` could break the desktop
# stream. Interactive shells get the system python3/pip; services keep their PATH.
RUN printf '%s\n' '' '# linux-box: system python for interactive shells, not Selkies'"'"' venv' \
      'PATH=$(printf %s "$PATH" | sed "s#/lsiopy/bin:##g"); unset VIRTUAL_ENV' >> /etc/bash.bashrc

# A normal /home/$USER home; the chart mounts the PVC there. /config is left to
# the base's own state (nginx cert, crontabs). init-home runs after PUID/PGID are
# applied and before init-selkies-config writes into $HOME: it seeds a fresh
# volume from /etc/skel (never overwriting) and hands the home to abc.
ENV HOME=/home/abc
RUN usermod -d /home/abc abc \
 && mkdir /home/abc \
 && d=/etc/s6-overlay/s6-rc.d \
 && mkdir -p $d/init-home/dependencies.d \
 && touch $d/init-home/dependencies.d/init-adduser $d/user/contents.d/init-home \
      $d/init-selkies-config/dependencies.d/init-home \
 && echo oneshot > $d/init-home/type \
 && echo $d/init-home/run > $d/init-home/up \
 && printf '%s\n' '#!/bin/sh' 'cp -rn /etc/skel/. /home/abc' 'chown -R abc:abc /home/abc' > $d/init-home/run \
 && chmod 755 $d/init-home/run

# Ad blocker forced on: ad-heavy pages (speedtest.net) alone filled 1.3GB of
# Chromium memory in the box. A managed policy survives restarts and fresh homes.
# Extension: uBlock Origin Lite (Raymond Hill), from the Chrome Web Store.
RUN mkdir -p /etc/chromium/policies/managed \
 && printf '%s\n' '{"ExtensionInstallForcelist": ["ddkjiahejlhfcafbddmgiahcphecmpfh;https://clients2.google.com/service/update2/crx"]}' \
      > /etc/chromium/policies/managed/linux-box.json
