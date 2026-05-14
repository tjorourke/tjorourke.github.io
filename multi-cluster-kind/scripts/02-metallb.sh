#!/usr/bin/env bash
# Install MetalLB on east and west clusters and configure non-overlapping IP pools.
# Replaces cloud-provider-kind, which has a known macOS bug where it fails to
# write the assigned IP back to status.loadBalancer.ingress.
#
# IP layout (kind bridge network 172.22.0.0/16):
#   nodes:      172.22.0.2 - 172.22.0.9  (kind-assigned)
#   east pool:  172.22.255.200 - 172.22.255.210
#   west pool:  172.22.255.220 - 172.22.255.230

set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

METALLB_VERSION="v0.14.9"
METALLB_URL="https://raw.githubusercontent.com/metallb/metallb/${METALLB_VERSION}/config/manifests/metallb-native.yaml"

log()    { echo "  → $*"; }
log_ok() { echo "  ✓ $*"; }

log "installing MetalLB ${METALLB_VERSION} on east and west"
kubectl --context=kind-east apply -f "$METALLB_URL" 2>&1 | grep -v unchanged | sed 's/^/    /' &
kubectl --context=kind-west apply -f "$METALLB_URL" 2>&1 | grep -v unchanged | sed 's/^/    /' &
wait
log_ok "MetalLB installed"

log "waiting for MetalLB controller pods"
kubectl --context=kind-east -n metallb-system wait \
  --for=condition=ready pod --selector=component=controller --timeout=120s
kubectl --context=kind-west -n metallb-system wait \
  --for=condition=ready pod --selector=component=controller --timeout=120s
log_ok "controllers ready"

log "applying IP pools"
kubectl --context=kind-east apply -f "$REPO_ROOT/yaml/metallb/east-pool.yaml"
kubectl --context=kind-west apply -f "$REPO_ROOT/yaml/metallb/west-pool.yaml"
log_ok "pools applied"

sleep 5

echo
echo "LoadBalancer services:"
kubectl --context=kind-east get svc -A --field-selector spec.type=LoadBalancer \
  --no-headers 2>/dev/null | awk '{printf "  east  %-40s %s\n", $2, $5}'
kubectl --context=kind-west get svc -A --field-selector spec.type=LoadBalancer \
  --no-headers 2>/dev/null | awk '{printf "  west  %-40s %s\n", $2, $5}'
