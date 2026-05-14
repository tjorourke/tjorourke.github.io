#!/usr/bin/env bash
# Create east and west kind clusters for the ambient multicluster workshop.
# Ref: https://github.com/rvennam/ambient-multicluster-workshop
#
# Distinct pod/service CIDRs prevent cross-cluster routing conflicts:
#   east: pods 10.10.0.0/16  services 10.96.0.0/16
#   west: pods 10.20.0.0/16  services 10.97.0.0/16

set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

log()    { echo "  → $*"; }
log_ok() { echo "  ✓ $*"; }
die()    { echo "ERROR: $*" >&2; exit 1; }

command -v kind   >/dev/null || die "kind not installed — brew install kind"
command -v kubectl >/dev/null || die "kubectl not installed — brew install kubectl"

for cluster in east west; do
  if kind get clusters 2>/dev/null | grep -qx "$cluster"; then
    log_ok "cluster '$cluster' already exists — skipping"
  else
    log "creating cluster '$cluster'..."
    kind create cluster --config "$REPO_ROOT/kind/${cluster}.yaml"
    log_ok "cluster '$cluster' ready"
  fi
done

echo
echo "Contexts:"
kubectl config get-contexts 2>/dev/null | grep -E 'kind-east|kind-west' || true
echo
echo "Next steps (workshop):"
echo "  https://github.com/rvennam/ambient-multicluster-workshop"
