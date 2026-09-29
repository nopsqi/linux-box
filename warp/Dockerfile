# WARP sidecar for the box: tunnels the whole pod (shared network namespace)
# through Cloudflare WARP, so sites see a Cloudflare IP instead of the node's.
# Needs NET_ADMIN and /dev/net/tun; the desktop container gets neither.
FROM debian:bookworm-slim

RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl gpg nftables \
 && curl -fsSL https://pkg.cloudflareclient.com/pubkey.gpg \
    | gpg --dearmor -o /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg \
 && echo "deb [signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] https://pkg.cloudflareclient.com/ bookworm main" \
    > /etc/apt/sources.list.d/cloudflare-client.list \
 && apt-get update \
 && apt-get install -y --no-install-recommends cloudflare-warp \
 && apt-get purge -y curl && apt-get autoremove -y \
 && rm -rf /var/lib/apt/lists/*

COPY killswitch.nft start.sh /
ENTRYPOINT ["/start.sh"]
