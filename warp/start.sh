#!/bin/sh
set -e
# Kill switch before anything else can send a packet.
nft -f /killswitch.nft

warp-svc &
pid=$!
trap 'kill $pid' TERM INT
until warp-cli --accept-tos status >/dev/null 2>&1; do sleep 1; done
# Registration is kept on an emptyDir, so container restarts reuse it.
warp-cli --accept-tos registration show >/dev/null 2>&1 || warp-cli --accept-tos registration new
warp-cli --accept-tos connect
wait $pid
