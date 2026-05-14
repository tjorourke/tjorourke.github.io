#!/usr/bin/env bash
# Install MetalLB on both clusters and configure non-overlapping IP pools.
# Reads CLUSTER1 / CLUSTER2 env vars (default: kind-east / kind-west).
# Replaces cloud-provider-kind, which has a known macOS bug where it fails to
# write the assigned IP back to status.loadBalancer.ingress.
#
# IP layout (kind bridge network 172.22.0.0/16):
#   nodes:         172.22.0.2 - 172.22.0.9   (kind-assigned)
#   CLUSTER1 pool: 172.22.255.200 - 172.22.255.210
#   CLUSTER2 pool: 172.22.255.220 - 172.22.255.230

set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

CLUSTER1="${CLUSTER1:-kind-east}"
CLUSTER2="${CLUSTER2:-kind-west}"

METALLB_VERSION="v0.14.9"
METALLB_URL="https://raw.githubusercontent.com/metallb/metallb/${METALLB_VERSION}/config/manifests/metallb-native.yaml"

# Pool files are named after the cluster suffix (strip "kind-" prefix)
CLUSTER1_NAME="${CLUSTER1#kind-}"
CLUSTER2_NAME="${CLUSTER2#kind-}"

log()    { echo "  → $*"; }
log_ok() { echo "  ✓ $*"; }

log "installing MetalLB ${METALLB_VERSION} on ${CLUSTER1} and ${CLUSTER2}"
kubectl --context="${CLUSTER1}" apply -f "$METALLB_URL" 2>&1 | grep -v unchanged | sed 's/^/    /' &
kubectl --context="${CLUSTER2}" apply -f "$METALLB_URL" 2>&1 | grep -v unchanged | sed 's/^/    /' &
wait
log_ok "MetalLB installed"

log "waiting for MetalLB controller pods"
kubectl --context="${CLUSTER1}" -n metallb-system wait \
  --for=condition=ready pod --selector=component=controller --timeout=120s
kubectl --context="${CLUSTER2}" -n metallb-system wait \
  --for=condition=ready pod --selector=component=controller --timeout=120s
log_ok "controllers ready"

log "applying IP pools"
kubectl --context="${CLUSTER1}" apply -f "$REPO_ROOT/yaml/metallb/${CLUSTER1_NAME}-pool.yaml"
kubectl --context="${CLUSTER2}" apply -f "$REPO_ROOT/yaml/metallb/${CLUSTER2_NAME}-pool.yaml"
log_ok "pools applied"

sleep 5

echo
echo "LoadBalancer services:"
kubectl --context="${CLUSTER1}" get svc -A --field-selector spec.type=LoadBalancer \
  --no-headers 2>/dev/null | awk -v c="${CLUSTER1}" '{printf "  %s  %-40s %s\n", c, $2, $5}'
kubectl --context="${CLUSTER2}" get svc -A --field-selector spec.type=LoadBalancer \
  --no-headers 2>/dev/null | awk -v c="${CLUSTER2}" '{printf "  %s  %-40s %s\n", c, $2, $5}'
