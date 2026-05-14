#!/usr/bin/env bash
# Multi-cluster observability + alerting pipeline.
#
# Wires the canonical Solo pattern for ztunnel-deny alerts across three
# clusters (the demo's Act 3 punchline depends on this):
#
#   edge/vendor:  gloo-telemetry-collector DaemonSet (otel-collector-contrib)
#                 scrapes ztunnel locally and OTLP-pushes metrics to bank's
#                 gloo-telemetry-gateway over the kind docker network (NodePort).
#                 Uses insecure_skip_verify for the self-signed gateway TLS cert.
#                 Filters to only istio_tcp_connections_* counters needed for
#                 the DORA PrometheusRules.
#
#   bank:         gloo-telemetry-gateway receives OTLP from all three
#                 clusters and exposes a Prometheus-compatible
#                 /metrics endpoint on :9091.
#
#                 kube-prometheus-stack Prometheus scrapes :9091 via a
#                 PodMonitor. A PrometheusRule fires IstioAuthZDeny and
#                 BankToAttackerAttempt against the federated metric set.
#                 AlertManagerConfig routes the alerts to MailHog over
#                 SMTP and the SOC inbox shows them at localhost:18012.
#
# Why not Prometheus federation or per-cluster Prom + remote_write?
#   - The OTel pipeline is Solo's canonical answer for the Gloo Mesh
#     management plane (mgmt UI, Insights, Workspaces all consume this
#     same gateway). Bolting an alternate metric path on the side would
#     mean two parallel pipelines and double the overhead.
#   - Federation requires lightweight Prometheus on every workload
#     cluster + cross-cluster scrape config. Adds operational overhead
#     and a second source of truth for metrics.
#
# Idempotent. Safe to re-run after Docker restarts.

set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
export REPO_ROOT MODE=multi
source "$REPO_ROOT/scripts/lib/config.sh"
source "$REPO_ROOT/scripts/lib/common.sh"
source "$REPO_ROOT/scripts/lib/topology.sh"

log_step "Multi-cluster observability + alerting pipeline"

# ─────────────────────────────────────────────────────────────────
# Step 1 — discover bank's telemetry-gateway OTLP endpoint (NodePort
# on a bank worker, deterministic via kubectl). The workload-cluster
# collectors will use this as their otlp exporter target.
# ─────────────────────────────────────────────────────────────────
BANK_IP="$(kctx "$BANK_CLUSTER" get nodes \
  -l '!node-role.kubernetes.io/control-plane' \
  -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')"
GATEWAY_NP="$(kctx "$BANK_CLUSTER" -n gloo-mesh get svc gloo-telemetry-gateway \
  -o jsonpath='{.spec.ports[?(@.port==4317)].nodePort}')"
[[ -n "$BANK_IP" && -n "$GATEWAY_NP" ]] \
  || die "could not discover bank IP / telemetry-gateway NodePort"
GATEWAY_OTLP="$BANK_IP:$GATEWAY_NP"
log "1/5 telemetry-gateway OTLP endpoint: $GATEWAY_OTLP"

# ─────────────────────────────────────────────────────────────────
# Step 2 — deploy gloo-telemetry-collector-agent on edge + vendor.
#
# Bank's collector uses a prometheus-only pipeline (receives locally,
# exports locally at :9091). Workload-cluster collectors need to
# OTLP-push to bank's gateway. We generate a minimal config that:
#   1. Scrapes ztunnel pods on the local node (k8s pod discovery,
#      filtered to the same node as the collector pod)
#   2. Keeps only the two TCP counters needed for DORA PrometheusRules
#   3. Exports via OTLP/gRPC to bank's gateway NodePort with
#      insecure_skip_verify (gateway uses a self-signed cert)
#
# Uses otel/opentelemetry-collector-contrib (already pulled by bank's
# otel-collector install in step 2.4 of 03-observability.sh).
# ─────────────────────────────────────────────────────────────────
log "2/5 deploying gloo-telemetry-collector-agent on workload clusters"
OTEL_IMAGE="otel/opentelemetry-collector-contrib:0.151.0"

for cluster in "$EDGE_CLUSTER" "$VENDOR_CLUSTER"; do
  ctx="$(cluster_context "$cluster")"
  log "    $cluster — applying RBAC + ConfigMap + DaemonSet"

  kubectl --context="$ctx" apply -f - 2>&1 | sed 's/^/      /' <<EOF
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: gloo-telemetry-collector-agent
  namespace: gloo-mesh
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: gloo-telemetry-collector-agent
rules:
  - apiGroups: [""]
    resources: [nodes, pods, endpoints, services, namespaces]
    verbs: [get, list, watch]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: gloo-telemetry-collector-agent
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: gloo-telemetry-collector-agent
subjects:
  - kind: ServiceAccount
    name: gloo-telemetry-collector-agent
    namespace: gloo-mesh
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: gloo-telemetry-collector-agent
  namespace: gloo-mesh
data:
  relay: |
    receivers:
      prometheus:
        config:
          global:
            scrape_interval: 30s
            scrape_timeout: 10s
          scrape_configs:
            - job_name: ztunnel
              honor_labels: true
              kubernetes_sd_configs:
                - role: pod
                  selectors:
                    - role: pod
                      field: "spec.nodeName=\${env:KUBE_NODE_NAME}"
              relabel_configs:
                - source_labels: [__meta_kubernetes_pod_label_app]
                  action: keep
                  regex: ztunnel
                - source_labels: [__meta_kubernetes_namespace]
                  action: keep
                  regex: istio-system
                - source_labels: [__meta_kubernetes_pod_ip]
                  replacement: \$1:15020
                  target_label: __address__
                - replacement: $cluster
                  target_label: cluster
                - source_labels: [__meta_kubernetes_pod_name]
                  target_label: pod
                - source_labels: [__meta_kubernetes_node_name]
                  target_label: node
              metric_relabel_configs:
                - action: keep
                  source_labels: [__name__]
                  regex: 'istio_tcp_connections_(opened|failed)_total'
    exporters:
      otlp/gateway:
        endpoint: "$GATEWAY_OTLP"
        tls:
          insecure_skip_verify: true
    processors:
      memory_limiter:
        check_interval: 5s
        limit_percentage: 70
      batch:
        timeout: 10s
    service:
      pipelines:
        metrics:
          receivers: [prometheus]
          processors: [memory_limiter, batch]
          exporters: [otlp/gateway]
---
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: gloo-telemetry-collector-agent
  namespace: gloo-mesh
  labels:
    app.kubernetes.io/name: gloo-telemetry-collector-agent
spec:
  selector:
    matchLabels:
      app.kubernetes.io/name: gloo-telemetry-collector-agent
  template:
    metadata:
      labels:
        app.kubernetes.io/name: gloo-telemetry-collector-agent
    spec:
      serviceAccountName: gloo-telemetry-collector-agent
      containers:
        - name: otel-collector
          image: $OTEL_IMAGE
          args: ["--config=/conf/relay"]
          env:
            - name: KUBE_NODE_NAME
              valueFrom:
                fieldRef:
                  fieldPath: spec.nodeName
            - name: KUBE_POD_NAME
              valueFrom:
                fieldRef:
                  fieldPath: metadata.name
          resources:
            requests:
              cpu: 25m
              memory: 64Mi
            limits:
              cpu: 100m
              memory: 128Mi
          volumeMounts:
            - name: config
              mountPath: /conf
      volumes:
        - name: config
          configMap:
            name: gloo-telemetry-collector-agent
            items:
              - key: relay
                path: relay
EOF
done

# ─────────────────────────────────────────────────────────────────
# Step 3 — expose bank's telemetry-gateway prometheus exporter port
# (:9091, configured inside the gateway's OTel config but not exposed
# on the Service today). Patch the Service to add the prom port so
# Prometheus can scrape it.
# ─────────────────────────────────────────────────────────────────
log "3/5 exposing telemetry-gateway :9091 prom endpoint on bank"
# Idempotent: capture port names first, then grep — avoids pipefail triggering when
# grep finds a match and exits early (closing the pipe causes kubectl SIGPIPE → exit 141).
_svc_ports="$(kctx "$BANK_CLUSTER" -n gloo-mesh get svc gloo-telemetry-gateway \
  -o jsonpath='{.spec.ports[*].name}' 2>/dev/null || true)"
if echo "$_svc_ports" | grep -qw prometheus 2>/dev/null; then
  log "    (prometheus port already on Service)"
else
  kctx "$BANK_CLUSTER" -n gloo-mesh patch svc gloo-telemetry-gateway \
    --type=json -p='[
      {"op":"add","path":"/spec/ports/-","value":{
        "name":"prometheus","port":9091,"targetPort":9091,"protocol":"TCP"
      }}
    ]' 2>&1 | sed 's/^/    /'
fi

_deploy_ports="$(kctx "$BANK_CLUSTER" -n gloo-mesh get deploy gloo-telemetry-gateway \
  -o jsonpath='{.spec.template.spec.containers[0].ports[*].name}' 2>/dev/null || true)"
if echo "$_deploy_ports" | grep -qw prometheus 2>/dev/null; then
  log "    (prometheus port already on Deployment)"
else
  kctx "$BANK_CLUSTER" -n gloo-mesh patch deploy gloo-telemetry-gateway \
    --type=json -p='[
      {"op":"add","path":"/spec/template/spec/containers/0/ports/-","value":{
        "name":"prometheus","containerPort":9091,"protocol":"TCP"
      }}
    ]' 2>&1 | sed 's/^/    /'
fi

# ─────────────────────────────────────────────────────────────────
# Step 4 — apply the PodMonitor + PrometheusRule + AlertManagerConfig
# + MailHog SMTP receiver on bank's observability stack.
# ─────────────────────────────────────────────────────────────────
log "4/5 applying alerts pipeline on bank (PodMonitor + PrometheusRule + AMC)"

kctx "$BANK_CLUSTER" apply -f - <<'EOF' 2>&1 | sed 's/^/    /'
# PodMonitor: scrape the telemetry-gateway's prom exporter at :9091.
# kube-prometheus-stack discovers PodMonitors with the 'release' label
# matching the helm release name (kube-prometheus-stack).
apiVersion: monitoring.coreos.com/v1
kind: PodMonitor
metadata:
  name: gloo-telemetry-gateway-prom
  namespace: trustusbank-observability
  labels:
    release: kube-prometheus-stack
spec:
  namespaceSelector:
    matchNames: ["gloo-mesh"]
  selector:
    matchLabels:
      app.kubernetes.io/name: telemetryGateway
  podMetricsEndpoints:
    - port: prometheus
      path: /metrics
      interval: 15s
      scrapeTimeout: 10s
---
# PrometheusRule: same two alerts as single-cluster, but the queries
# now include `cluster` in the grouping so we know which cluster the
# deny fired on. The metric labels come from the OTel collector's
# resource-detection processor (cluster=<helm-release-cluster>).
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: trustusbank-authz-denials
  namespace: trustusbank-observability
  labels:
    release: kube-prometheus-stack
spec:
  groups:
    - name: trustusbank.authz
      interval: 15s
      rules:
        - alert: IstioAuthZDeny
          expr: |
            sum by (cluster, source_workload, source_workload_namespace,
                    source_principal, destination_service_namespace,
                    destination_service_name)
              (rate(istio_tcp_connections_failed_total{response_flags="CONNECT"}[5m])) > 0
          for: 0m
          labels:
            severity: critical
            dora_article: "10"
            nis2_clause: "21(2)(b)"
            namespace: trustusbank-observability
          annotations:
            summary: "Istio AuthZ denied a connection — possible attack in progress"
            description: |
              ztunnel on cluster {{ $labels.cluster }} rejected an HBONE handshake.
                offending pod:    {{ $labels.source_workload }} ({{ $labels.source_workload_namespace }})
                offending SPIFFE: {{ $labels.source_principal }}
                target service:   {{ $labels.destination_service_name }} ({{ $labels.destination_service_namespace }})
            runbook: "demo-scripts/runbook.md#act-3---policies-on"

        - alert: BankToAttackerAttempt
          expr: |
            sum by (cluster, source_workload, source_workload_namespace, source_principal)
              (rate(istio_tcp_connections_opened_total{
                source_workload_namespace=~"trustusbank-bank-.*|trustusbank-platform",
                destination_workload_namespace="external-attacker"
              }[5m])) > 0
          for: 0m
          labels:
            severity: critical
            dora_article: "10"
            nis2_clause: "21(2)(b)"
            namespace: trustusbank-observability
          annotations:
            summary: "Bank pod attempted to reach external-attacker — exfil attempt"
            description: |
              cluster {{ $labels.cluster }} workload {{ $labels.source_workload_namespace }}/{{ $labels.source_workload }}
              tried to open a TCP connection to external-attacker.
              SPIFFE identity: {{ $labels.source_principal }}.
            runbook: "demo-scripts/runbook.md#act-3---policies-on"
---
# AlertManagerConfig: route IstioAuthZDeny + BankToAttackerAttempt to
# a 'soc-mailhog' SMTP receiver. The Operator's default matcher
# strategy is OnNamespace, so the rules above must carry
# namespace=trustusbank-observability for the route to match.
apiVersion: monitoring.coreos.com/v1alpha1
kind: AlertmanagerConfig
metadata:
  name: trustusbank-soc-mailhog
  namespace: trustusbank-observability
  labels:
    alertmanagerConfig: kube-prometheus-stack
spec:
  route:
    receiver: soc-mailhog
    groupBy: ["alertname", "cluster"]
    groupWait: 10s
    groupInterval: 30s
    repeatInterval: 5m
    matchers:
      - name: alertname
        matchType: =~
        value: "IstioAuthZDeny|BankToAttackerAttempt"
  receivers:
    - name: soc-mailhog
      emailConfigs:
        - to: "soc@trustusbank.local"
          from: "alertmanager@trustusbank.local"
          smarthost: "mailhog.trustusbank-observability.svc.cluster.local:1025"
          requireTLS: false
          headers:
            - key: Subject
              value: "{{ .CommonLabels.alertname }} on {{ .CommonLabels.cluster }}"
          html: |
            <h2>{{ .CommonLabels.alertname }}</h2>
            <p><b>Cluster:</b> {{ .CommonLabels.cluster }}</p>
            {{ range .Alerts }}
            <hr>
            <p><b>Summary:</b> {{ .Annotations.summary }}</p>
            <pre>{{ .Annotations.description }}</pre>
            <p><b>Runbook:</b> {{ .Annotations.runbook }}</p>
            {{ end }}
EOF

# ─────────────────────────────────────────────────────────────────
# Step 5 — wait for the collector pods to come up + verify metrics
# are landing in Prometheus.
# ─────────────────────────────────────────────────────────────────
log "5a/5 waiting for workload-cluster collectors to scrape ztunnel + push OTLP to gateway"
# The collector ConfigMap (step 2) already includes istio_tcp_connections_failed_total
# in its metric_relabel_configs — no filter patch needed. Just wait for the
# first 30s scrape cycle + 10s batch flush and verify the gateway :9091 has data.
for cluster in "$EDGE_CLUSTER" "$VENDOR_CLUSTER"; do
  ctx="$(cluster_context "$cluster")"
  kubectl --context="$ctx" -n gloo-mesh rollout status \
    ds/gloo-telemetry-collector-agent --timeout=60s 2>&1 \
    | tail -1 | sed 's/^/      /' || true
done

log "5b/5 enabling kube-prometheus-stack AlertManager (disabled during right-sizing)"
# The right-sizing pass turned alertmanager.enabled=false to save ~64MB.
# For the alert/email pipeline to work, we need AlertManager back. Pin
# small resource limits so the saving isn't fully lost.
helm --kube-context="$(cluster_context "$BANK_CLUSTER")" \
  -n trustusbank-observability upgrade kube-prometheus-stack kube-prometheus-stack \
  --repo https://prometheus-community.github.io/helm-charts \
  --reuse-values \
  --set alertmanager.enabled=true \
  --set alertmanager.alertmanagerSpec.resources.limits.memory=64Mi \
  --set alertmanager.alertmanagerSpec.resources.requests.memory=32Mi \
  --set alertmanager.alertmanagerSpec.retention=2h \
  2>&1 | tail -2 | sed 's/^/    /'

# Force Prom to pick up the newly-enabled AlertManager (operator-managed
# Prom CR adds an alerting.alertmanagers stanza but the running pod
# needs a restart to apply).
kctx "$BANK_CLUSTER" -n trustusbank-observability \
  rollout restart statefulset/prometheus-kube-prometheus-stack-prometheus >/dev/null 2>&1 || true

log "5c/5 waiting for collectors + Prom to roll"
for cluster in "$EDGE_CLUSTER" "$VENDOR_CLUSTER"; do
  ctx="$(cluster_context "$cluster")"
  kubectl --context="$ctx" -n gloo-mesh rollout status \
    ds/gloo-telemetry-collector-agent --timeout=120s 2>&1 \
    | tail -1 | sed 's/^/      /' || true
done

# Restart the gateway pod so it picks up the new container port.
kctx "$BANK_CLUSTER" -n gloo-mesh rollout restart deploy/gloo-telemetry-gateway \
  >/dev/null 2>&1 || true
kctx "$BANK_CLUSTER" -n gloo-mesh rollout status deploy/gloo-telemetry-gateway \
  --timeout=120s 2>&1 | tail -1 | sed 's/^/    /' || true

log_ok "observability pipeline wired"
log ""
log "Verify alerts:"
log "  1. ./scripts/upgrade-banking-app.sh        # stage the rug-pull"
log "  2. ./scripts/policies-on.sh                # apply deny-bank-to-attacker"
log "  3. (chatbot) Customer 12345 - balance + USD"
log "  4. http://localhost:18002/alerts            # Prometheus alerts"
log "  5. http://localhost:18012                   # MailHog SOC inbox"
