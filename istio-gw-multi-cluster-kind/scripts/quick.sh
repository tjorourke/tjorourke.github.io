#!/usr/bin/env bash
# quick.sh — end-to-end setup for Solo Enterprise Istio Ambient multicluster
#
# Follows the rvennam/ambient-multicluster-workshop flow with kind fixes applied.
# Clusters: kind-east-istio (east-istio) + kind-west-istio (west-istio)
# MetalLB:  east .200-.210, west .220-.230  (non-overlapping with agentgw demo)
#
# Usage:
#   ./quick.sh            — full setup (~15 min first run, ~5 min if images cached)
#   ./quick.sh teardown   — delete both clusters + certs/

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SECRETS_FILE="${SECRETS_FILE:-/Users/tomorourke/code/solo/secrets/secrets-envs.sh}"

CLUSTER1=kind-east-istio
CLUSTER2=kind-west-istio
NAME1=east-istio
NAME2=west-istio

GLOO_OPERATOR_VERSION="${GLOO_OPERATOR_VERSION:-0.5.2}"
SOLO_ISTIO_VERSION="${SOLO_ISTIO_VERSION:-1.29.2-patch0-solo}"
ISTIO_VERSION_OPERATOR="${SOLO_ISTIO_VERSION%-solo}"
GATEWAY_API_VERSION="${GATEWAY_API_VERSION:-v1.5.0}"
METALLB_VERSION="${METALLB_VERSION:-v0.14.9}"
ISTIO_REGISTRY="us-docker.pkg.dev/soloio-img/istio"
ISTIO_TAG="${SOLO_ISTIO_VERSION%-solo}"
CERTS_DIR="$REPO_ROOT/certs"

# ── Utilities ─────────────────────────────────────────────────────────────────

log()    { echo "  $*"; }
log_ok() { echo "  ✓ $*"; }
step()   { echo ""; echo "══> $*"; }
die()    { echo "ERROR: $*" >&2; exit 1; }
require() { command -v "$1" >/dev/null 2>&1 || die "$1 not found — install it first"; }

wait_deploy() {
  local ctx="$1" ns="$2" name="$3" timeout="${4:-300s}"
  kubectl --context "$ctx" -n "$ns" wait \
    --for=condition=Available deployment/"$name" --timeout="$timeout" >/dev/null
}

# ── Teardown ──────────────────────────────────────────────────────────────────

if [[ "${1:-}" == "teardown" ]]; then
  step "Tearing down istio-gw clusters"
  kind delete cluster --name "$NAME1" 2>/dev/null && log_ok "$NAME1 deleted" || true
  kind delete cluster --name "$NAME2" 2>/dev/null && log_ok "$NAME2 deleted" || true
  rm -rf "$CERTS_DIR" && log_ok "certs/ removed" || true
  echo ""; echo "Done."; exit 0
fi

# ── Secrets ───────────────────────────────────────────────────────────────────

[[ -f "$SECRETS_FILE" ]] && { set -a; source "$SECRETS_FILE"; set +a; }
[[ -n "${SOLO_ISTIO_LICENSE_KEY:-}" ]] || die "SOLO_ISTIO_LICENSE_KEY not set (source secrets-envs.sh)"

# ── Prereqs ───────────────────────────────────────────────────────────────────

step "Checking prereqs"
require kind; require kubectl; require helm; require docker; require openssl; require istioctl
log_ok "all tools present"

# ── Step 1: kind clusters ─────────────────────────────────────────────────────

step "Creating kind clusters"
for NAME in "$NAME1" "$NAME2"; do
  if kind get clusters 2>/dev/null | grep -qx "$NAME"; then
    log "[$NAME] already exists — skipping"
  else
    CFG="$REPO_ROOT/kind/${NAME}.yaml"
    [[ -f "$CFG" ]] || die "kind config not found: $CFG"
    log "[$NAME] creating..."
    kind create cluster --config "$CFG"
    log_ok "[$NAME] ready"
  fi
done

# ── Step 2: MetalLB ───────────────────────────────────────────────────────────

step "Installing MetalLB $METALLB_VERSION"
# Use {{println}} so each subnet is on its own line, then grep -v ':' to drop IPv6.
KIND_CIDR="$(docker network inspect kind \
  --format '{{range .IPAM.Config}}{{println .Subnet}}{{end}}' 2>/dev/null \
  | grep -v ':' | head -1)"
[[ -n "$KIND_CIDR" ]] || die "kind Docker network not found — clusters must be up first"
BASE="$(echo "$KIND_CIDR" | cut -d. -f1,2)"
log "kind network: $KIND_CIDR  (base: $BASE)"

for CTX in "$CLUSTER1" "$CLUSTER2"; do
  kubectl --context "$CTX" apply -f \
    "https://raw.githubusercontent.com/metallb/metallb/${METALLB_VERSION}/config/manifests/metallb-native.yaml" \
    >/dev/null
done
for CTX in "$CLUSTER1" "$CLUSTER2"; do
  kubectl --context "$CTX" -n metallb-system wait \
    --for=condition=Ready pod -l app=metallb,component=controller --timeout=90s >/dev/null
  log_ok "[${CTX#kind-}] MetalLB controller ready"
done

# istio-gw demo uses .200-.210 / .220-.230
kubectl --context "$CLUSTER1" apply -f - >/dev/null <<EOF
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata: { name: kind-pool, namespace: metallb-system }
spec:
  addresses: ["${BASE}.255.200-${BASE}.255.210"]
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata: { name: kind-l2, namespace: metallb-system }
EOF

kubectl --context "$CLUSTER2" apply -f - >/dev/null <<EOF
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata: { name: kind-pool, namespace: metallb-system }
spec:
  addresses: ["${BASE}.255.220-${BASE}.255.230"]
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata: { name: kind-l2, namespace: metallb-system }
EOF
log_ok "MetalLB pools configured  ($NAME1 .200-.210  /  $NAME2 .220-.230)"

# ── Step 3: Bookinfo ──────────────────────────────────────────────────────────

step "Deploying Bookinfo to both clusters"
BOOKINFO_BASE="https://raw.githubusercontent.com/istio/istio/release-1.24/samples/bookinfo/platform/kube"
for CTX in "$CLUSTER1" "$CLUSTER2"; do
  kubectl --context "$CTX" create namespace bookinfo 2>/dev/null || true
  kubectl --context "$CTX" apply -n bookinfo -f "${BOOKINFO_BASE}/bookinfo.yaml" >/dev/null
  kubectl --context "$CTX" apply -n bookinfo -f "${BOOKINFO_BASE}/bookinfo-versions.yaml" >/dev/null
  log_ok "[${CTX#kind-}] Bookinfo applied"
done

# ── Step 4: Shared root CA ────────────────────────────────────────────────────

step "Generating shared root CA + per-cluster intermediates"
mkdir -p "$CERTS_DIR"

if [[ ! -f "$CERTS_DIR/root-ca.crt" ]]; then
  openssl genrsa -out "$CERTS_DIR/root-ca.key" 4096 2>/dev/null
  openssl req -new -x509 -days 3650 \
    -key "$CERTS_DIR/root-ca.key" \
    -subj "/O=Solo Demo/CN=Shared Root CA" \
    -out "$CERTS_DIR/root-ca.crt" 2>/dev/null
  log_ok "root CA generated"
fi

for NAME in "$NAME1" "$NAME2"; do
  if [[ ! -f "$CERTS_DIR/${NAME}-ca.crt" ]]; then
    openssl genrsa -out "$CERTS_DIR/${NAME}-ca.key" 4096 2>/dev/null
    cat > "$CERTS_DIR/${NAME}-csr.conf" <<EOF
[req]
distinguished_name = req_distinguished_name
req_extensions     = v3_req
prompt = no
[req_distinguished_name]
O  = Solo Demo
CN = ${NAME} Intermediate CA
[v3_req]
subjectAltName = URI:spiffe://cluster.local/ns/istio-system/sa/citadel
basicConstraints = CA:TRUE
keyUsage = keyCertSign, cRLSign
EOF
    openssl req -new \
      -key "$CERTS_DIR/${NAME}-ca.key" \
      -config "$CERTS_DIR/${NAME}-csr.conf" \
      -out "$CERTS_DIR/${NAME}-ca.csr" 2>/dev/null
    openssl x509 -req -days 3650 \
      -in  "$CERTS_DIR/${NAME}-ca.csr" \
      -CA  "$CERTS_DIR/root-ca.crt" -CAkey "$CERTS_DIR/root-ca.key" \
      -CAcreateserial \
      -extfile "$CERTS_DIR/${NAME}-csr.conf" -extensions v3_req \
      -out "$CERTS_DIR/${NAME}-ca.crt" 2>/dev/null
    log_ok "[$NAME] intermediate CA generated"
  fi
done

for PAIR in "${CLUSTER1}:${NAME1}" "${CLUSTER2}:${NAME2}"; do
  CTX="${PAIR%%:*}"; NAME="${PAIR##*:}"
  cat "$CERTS_DIR/${NAME}-ca.crt" "$CERTS_DIR/root-ca.crt" > "$CERTS_DIR/${NAME}-ca-chain.crt"
  kubectl --context "$CTX" create namespace istio-system 2>/dev/null || true
  kubectl --context "$CTX" create namespace istio-gateways 2>/dev/null || true
  kubectl --context "$CTX" -n istio-system create secret generic cacerts \
    --from-file=ca-cert.pem="$CERTS_DIR/${NAME}-ca.crt" \
    --from-file=ca-key.pem="$CERTS_DIR/${NAME}-ca.key" \
    --from-file=root-cert.pem="$CERTS_DIR/root-ca.crt" \
    --from-file=cert-chain.pem="$CERTS_DIR/${NAME}-ca-chain.crt" \
    --dry-run=client -o yaml | kubectl --context "$CTX" apply -f - >/dev/null
  log_ok "[$NAME] cacerts secret applied"
done

# ── Step 5: Gateway API CRDs ──────────────────────────────────────────────────

step "Installing Gateway API CRDs $GATEWAY_API_VERSION"
for CTX in "$CLUSTER1" "$CLUSTER2"; do
  kubectl --context "$CTX" apply -f \
    "https://github.com/kubernetes-sigs/gateway-api/releases/download/${GATEWAY_API_VERSION}/standard-install.yaml" \
    >/dev/null
  log_ok "[${CTX#kind-}] Gateway API CRDs applied"
done

# ── Step 6: Pre-pull Solo Istio images ────────────────────────────────────────

step "Pre-pulling Solo Istio images ($ISTIO_TAG)"
for IMG in pilot proxyv2 install-cni ztunnel; do
  FULL="${ISTIO_REGISTRY}/${IMG}:${ISTIO_TAG}"
  if docker image inspect "$FULL" >/dev/null 2>&1; then
    log_ok "cached: $IMG"
  else
    log "pulling $IMG..."
    docker pull --quiet "$FULL"
    log_ok "$IMG pulled"
  fi
done
for NAME in "$NAME1" "$NAME2"; do
  for IMG in pilot proxyv2 install-cni ztunnel; do
    kind load docker-image "${ISTIO_REGISTRY}/${IMG}:${ISTIO_TAG}" --name "$NAME" >/dev/null
  done
  log_ok "[$NAME] images loaded"
done

# ── Step 7: Gloo Operator + Solo Istio ───────────────────────────────────────

step "Installing Gloo Operator $GLOO_OPERATOR_VERSION"
for CTX in "$CLUSTER1" "$CLUSTER2"; do
  helm upgrade --install gloo-operator \
    oci://us-docker.pkg.dev/solo-public/gloo-operator-helm/gloo-operator \
    --kube-context "$CTX" \
    --namespace gloo-system --create-namespace \
    --version "$GLOO_OPERATOR_VERSION" \
    --set manager.env.SOLO_ISTIO_LICENSE_KEY="${SOLO_ISTIO_LICENSE_KEY}" \
    --wait >/dev/null
  log_ok "[${CTX#kind-}] Gloo Operator ready"
done

step "Applying ServiceMeshController CRs"
for PAIR in "${CLUSTER1}:${NAME1}" "${CLUSTER2}:${NAME2}"; do
  CTX="${PAIR%%:*}"; NAME="${PAIR##*:}"
  kubectl --context "$CTX" apply -f - >/dev/null <<EOF
apiVersion: operator.gloo.solo.io/v1
kind: ServiceMeshController
metadata:
  name: managed-istio
  namespace: gloo-system
spec:
  cluster: ${NAME}
  network: ${NAME}
  trustDomain: cluster.local
  version: "${ISTIO_VERSION_OPERATOR}"
  dataplaneMode: Ambient
  distribution: Standard
  scalingProfile: Demo
EOF
  log_ok "[$NAME] SMC applied"
done

step "Waiting for istiod-gloo"
for CTX in "$CLUSTER1" "$CLUSTER2"; do
  wait_deploy "$CTX" istio-system istiod-gloo 300s
  log_ok "[${CTX#kind-}] istiod-gloo ready"
done

step "Patching istiod env vars"
for CTX in "$CLUSTER1" "$CLUSTER2"; do
  kubectl --context "$CTX" -n istio-system patch deployment istiod-gloo \
    --type=json -p='[
      {"op":"add","path":"/spec/template/spec/containers/0/env/-","value":{"name":"L7_ENABLED","value":"true"}},
      {"op":"add","path":"/spec/template/spec/containers/0/env/-","value":{"name":"PILOT_ENABLE_K8S_SELECT_WORKLOAD_ENTRIES","value":"false"}}
    ]' >/dev/null
  log_ok "[${CTX#kind-}] env patched"
done

for CTX in "$CLUSTER1" "$CLUSTER2"; do
  kubectl --context "$CTX" -n istio-system rollout status deployment/istiod-gloo --timeout=120s >/dev/null
done
log_ok "istiod-gloo rollout complete on both clusters"

# ── Step 8: Peer clusters via istioctl multicluster expose ────────────────────

step "Waiting for istiod pods to be Running before exposing"
for CTX in "$CLUSTER1" "$CLUSTER2"; do
  kubectl --context "$CTX" -n istio-system wait \
    --for=condition=Ready pod -l app=istiod --timeout=120s >/dev/null
done

step "Exposing clusters for multicluster via istioctl"
# multicluster expose creates the east-west gateway in istio-gateways namespace
# and outputs a remote secret YAML to be applied to the peer cluster.
istioctl --context "$CLUSTER1" multicluster expose -n istio-gateways \
  | kubectl --context "$CLUSTER2" apply -f - >/dev/null
log_ok "[${NAME2}] remote secret from ${NAME1} applied"

istioctl --context "$CLUSTER2" multicluster expose -n istio-gateways \
  | kubectl --context "$CLUSTER1" apply -f - >/dev/null
log_ok "[${NAME1}] remote secret from ${NAME2} applied"

# Wait for east-west gateway LoadBalancer IPs
step "Waiting for east-west gateway IPs"
for CTX in "$CLUSTER1" "$CLUSTER2"; do
  EW_IP=""
  for i in $(seq 1 30); do
    EW_IP="$(kubectl --context "$CTX" -n istio-gateways \
      get svc istio-eastwest -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)"
    [[ -n "$EW_IP" ]] && break
    echo -n "."; sleep 3
  done
  echo ""
  log "[${CTX#kind-}] east-west IP: ${EW_IP:-pending}"
done

# ── Step 9: Label bookinfo namespace ─────────────────────────────────────────

step "Labelling bookinfo namespace for Ambient + network topology"
for PAIR in "${CLUSTER1}:${NAME1}" "${CLUSTER2}:${NAME2}"; do
  CTX="${PAIR%%:*}"; NAME="${PAIR##*:}"
  kubectl --context "$CTX" label namespace bookinfo \
    istio.io/dataplane-mode=ambient \
    topology.istio.io/network="$NAME" \
    --overwrite >/dev/null
  log_ok "[$NAME] bookinfo labelled"
done

# ── Step 10: Wait for Bookinfo + label productpage global ────────────────────

step "Waiting for Bookinfo pods"
for CTX in "$CLUSTER1" "$CLUSTER2"; do
  kubectl --context "$CTX" -n bookinfo wait \
    --for=condition=Ready pod -l app=productpage --timeout=120s >/dev/null &
  kubectl --context "$CTX" -n bookinfo wait \
    --for=condition=Ready pod -l app=details --timeout=120s >/dev/null &
done
wait
log_ok "Bookinfo pods ready"

step "Labelling productpage as global service"
for CTX in "$CLUSTER1" "$CLUSTER2"; do
  kubectl --context "$CTX" label svc productpage -n bookinfo \
    solo.io/service-scope=global --overwrite >/dev/null
done
log_ok "productpage labelled global"

# ── Step 11: Istio Gateway + HTTPRoute ───────────────────────────────────────

step "Applying bookinfo-gateway (istio GatewayClass)"
kubectl --context "$CLUSTER1" apply -f - >/dev/null <<'YAML'
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: bookinfo-gateway
  namespace: bookinfo
spec:
  gatewayClassName: istio
  listeners:
  - name: http
    port: 8080
    protocol: HTTP
    allowedRoutes:
      namespaces:
        from: Same
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: productpage
  namespace: bookinfo
spec:
  parentRefs:
  - name: bookinfo-gateway
  rules:
  - backendRefs:
    - name: productpage
      port: 9080
YAML
log_ok "bookinfo-gateway + HTTPRoute applied"

step "Waiting for bookinfo-gateway LoadBalancer IP"
GW_IP=""
for i in $(seq 1 40); do
  GW_IP="$(kubectl --context "$CLUSTER1" -n bookinfo \
    get svc bookinfo-gateway-istio -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)"
  [[ -n "$GW_IP" ]] && break
  echo -n "."; sleep 3
done
echo ""
[[ -n "$GW_IP" ]] || { log "gateway IP not assigned — check MetalLB"; GW_IP="pending"; }
log_ok "bookinfo-gateway-istio IP: $GW_IP"

# ── Smoke test ────────────────────────────────────────────────────────────────

step "Smoke test — curl productpage via port-forward"
PF_PID=""
cleanup_pf() { [[ -n "$PF_PID" ]] && kill "$PF_PID" 2>/dev/null || true; }
trap cleanup_pf EXIT

kubectl --context "$CLUSTER1" -n bookinfo \
  port-forward svc/bookinfo-gateway-istio 18081:8080 >/dev/null 2>&1 &
PF_PID=$!
sleep 4

HTTP_STATUS="$(curl -s -o /dev/null -w "%{http_code}" \
  http://localhost:18081/productpage 2>/dev/null || echo "failed")"
cleanup_pf; trap - EXIT; PF_PID=""

if [[ "$HTTP_STATUS" == "200" ]]; then
  log_ok "productpage: HTTP $HTTP_STATUS — PASS"
else
  log "productpage: HTTP $HTTP_STATUS — check gateway/bookinfo logs"
fi

# ── Summary ───────────────────────────────────────────────────────────────────

echo ""
echo "════════════════════════════════════════════════════════════════════"
echo "  Solo Enterprise Istio Ambient — Multicluster on kind"
echo "════════════════════════════════════════════════════════════════════"
echo ""
echo "  Clusters:   $CLUSTER1   $CLUSTER2"
echo "  Gateway IP: ${GW_IP}  (east-istio)"
echo ""
echo "  Access bookinfo:"
echo "    kubectl --context $CLUSTER1 -n bookinfo \\"
echo "      port-forward svc/bookinfo-gateway-istio 8080:8080"
echo "    open http://localhost:8080/productpage"
echo ""
echo "  Verify peering:"
echo "    kubectl --context $CLUSTER1 -n istio-system logs deploy/istiod-gloo | grep 'remote cluster'"
echo "    kubectl --context $CLUSTER2 -n istio-system logs deploy/istiod-gloo | grep 'remote cluster'"
echo ""
echo "  Failover test:"
echo "    kubectl --context $CLUSTER1 scale deploy productpage-v1 -n bookinfo --replicas=0"
echo "    # curl productpage — traffic should still flow via $CLUSTER2"
echo "    kubectl --context $CLUSTER1 scale deploy productpage-v1 -n bookinfo --replicas=1"
echo ""
echo "  Teardown:"
echo "    ./quick.sh teardown"
echo ""
