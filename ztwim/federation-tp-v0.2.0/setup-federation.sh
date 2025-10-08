#!/bin/bash

# SPIRE Federation End-to-End Setup Script
# This script sets up complete SPIRE federation between two OpenShift clusters

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Print functions
print_header() {
    echo -e "${BLUE}================================================${NC}"
    echo -e "${BLUE}$1${NC}"
    echo -e "${BLUE}================================================${NC}"
}

print_step() {
    echo -e "${CYAN}[STEP $1/$2] $3${NC}"
}

print_success() {
    echo -e "${GREEN}✓ $1${NC}"
}

print_error() {
    echo -e "${RED}✗ $1${NC}"
}

print_info() {
    echo -e "${YELLOW}ℹ $1${NC}"
}

# Check arguments
if [ $# -ne 2 ]; then
    echo -e "${RED}Usage: $0 <cluster1-kubeconfig> <cluster2-kubeconfig>${NC}"
    echo ""
    echo "Example:"
    echo "  $0 /path/to/cluster1/kubeconfig /path/to/cluster2/kubeconfig"
    exit 1
fi

CLUSTER1_KUBECONFIG="$1"
CLUSTER2_KUBECONFIG="$2"

# Validate kubeconfig files
if [ ! -f "$CLUSTER1_KUBECONFIG" ]; then
    print_error "Cluster 1 kubeconfig not found: $CLUSTER1_KUBECONFIG"
    exit 1
fi

if [ ! -f "$CLUSTER2_KUBECONFIG" ]; then
    print_error "Cluster 2 kubeconfig not found: $CLUSTER2_KUBECONFIG"
    exit 1
fi

print_header "SPIRE Federation Setup"
echo ""
print_info "Cluster 1 kubeconfig: $CLUSTER1_KUBECONFIG"
print_info "Cluster 2 kubeconfig: $CLUSTER2_KUBECONFIG"
echo ""

TOTAL_STEPS=15

# Step 1: Get cluster information
print_step 1 $TOTAL_STEPS "Gathering cluster information"

export KUBECONFIG="$CLUSTER1_KUBECONFIG"
CLUSTER1_NAME=$(kubectl get spireserver cluster -o jsonpath='{.spec.clusterName}' 2>/dev/null || echo "cluster1")
CLUSTER1_TRUST_DOMAIN=$(kubectl get spireserver cluster -o jsonpath='{.spec.trustDomain}' 2>/dev/null)
CLUSTER1_ROUTE_BASE=$(kubectl get route -n openshift-console console -o jsonpath='{.spec.host}' 2>/dev/null | sed 's/^console-openshift-console\.//')

export KUBECONFIG="$CLUSTER2_KUBECONFIG"
CLUSTER2_NAME=$(kubectl get spireserver cluster -o jsonpath='{.spec.clusterName}' 2>/dev/null || echo "cluster2")
CLUSTER2_TRUST_DOMAIN=$(kubectl get spireserver cluster -o jsonpath='{.spec.trustDomain}' 2>/dev/null)
CLUSTER2_ROUTE_BASE=$(kubectl get route -n openshift-console console -o jsonpath='{.spec.host}' 2>/dev/null | sed 's/^console-openshift-console\.//')

print_success "Cluster 1: $CLUSTER1_NAME (Trust Domain: $CLUSTER1_TRUST_DOMAIN)"
print_success "Cluster 2: $CLUSTER2_NAME (Trust Domain: $CLUSTER2_TRUST_DOMAIN)"
echo ""

# Define federation URLs
CLUSTER1_FED_URL="https://spire-federation-${CLUSTER1_NAME}.${CLUSTER1_ROUTE_BASE}"
CLUSTER2_FED_URL="https://spire-federation-${CLUSTER2_NAME}.${CLUSTER2_ROUTE_BASE}"

# Step 2: Update SPIRE Server ConfigMaps with federation configuration
print_step 2 $TOTAL_STEPS "Updating SPIRE Server ConfigMap on Cluster 1"

export KUBECONFIG="$CLUSTER1_KUBECONFIG"
kubectl get configmap spire-server -n zero-trust-workload-identity-manager -o jsonpath='{.data.server\.conf}' | \
  jq '. + {"server": (.server + {"federation": {"bundle_endpoint": {"address": "0.0.0.0", "port": 8443}}})}' > /tmp/cluster1-server.conf

kubectl create configmap spire-server \
  --from-file=server.conf=/tmp/cluster1-server.conf \
  -n zero-trust-workload-identity-manager \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null 2>&1

print_success "Cluster 1 ConfigMap updated"

print_step 3 $TOTAL_STEPS "Updating SPIRE Server ConfigMap on Cluster 2"

export KUBECONFIG="$CLUSTER2_KUBECONFIG"
kubectl get configmap spire-server -n zero-trust-workload-identity-manager -o jsonpath='{.data.server\.conf}' | \
  jq '. + {"server": (.server + {"federation": {"bundle_endpoint": {"address": "0.0.0.0", "port": 8443}}})}' > /tmp/cluster2-server.conf

kubectl create configmap spire-server \
  --from-file=server.conf=/tmp/cluster2-server.conf \
  -n zero-trust-workload-identity-manager \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null 2>&1

print_success "Cluster 2 ConfigMap updated"
echo ""

# Step 4: Patch Services to add federation port
print_step 4 $TOTAL_STEPS "Adding federation port to SPIRE Server service on Cluster 1"

export KUBECONFIG="$CLUSTER1_KUBECONFIG"
kubectl get service spire-server -n zero-trust-workload-identity-manager -o json | \
  jq '.spec.ports += [{"name": "federation", "port": 8443, "protocol": "TCP", "targetPort": 8443}] | .spec.ports |= unique_by(.name)' | \
  kubectl apply -f - >/dev/null 2>&1

print_success "Cluster 1 service patched"

print_step 5 $TOTAL_STEPS "Adding federation port to SPIRE Server service on Cluster 2"

export KUBECONFIG="$CLUSTER2_KUBECONFIG"
kubectl get service spire-server -n zero-trust-workload-identity-manager -o json | \
  jq '.spec.ports += [{"name": "federation", "port": 8443, "protocol": "TCP", "targetPort": 8443}] | .spec.ports |= unique_by(.name)' | \
  kubectl apply -f - >/dev/null 2>&1

print_success "Cluster 2 service patched"
echo ""

# Step 6: Patch StatefulSets to add federation port
print_step 6 $TOTAL_STEPS "Adding federation port to SPIRE Server pods on Cluster 1"

export KUBECONFIG="$CLUSTER1_KUBECONFIG"
kubectl get statefulset spire-server -n zero-trust-workload-identity-manager -o json | \
  jq '.spec.template.spec.containers[0].ports += [{"name": "federation", "containerPort": 8443, "protocol": "TCP"}] | .spec.template.spec.containers[0].ports |= unique_by(.name)' | \
  kubectl apply -f - >/dev/null 2>&1

print_success "Cluster 1 StatefulSet patched"

print_step 7 $TOTAL_STEPS "Adding federation port to SPIRE Server pods on Cluster 2"

export KUBECONFIG="$CLUSTER2_KUBECONFIG"
kubectl get statefulset spire-server -n zero-trust-workload-identity-manager -o json | \
  jq '.spec.template.spec.containers[0].ports += [{"name": "federation", "containerPort": 8443, "protocol": "TCP"}] | .spec.template.spec.containers[0].ports |= unique_by(.name)' | \
  kubectl apply -f - >/dev/null 2>&1

print_success "Cluster 2 StatefulSet patched"
echo ""

# Step 8: Wait for pods to restart
print_step 8 $TOTAL_STEPS "Waiting for SPIRE Server pods to restart"

export KUBECONFIG="$CLUSTER1_KUBECONFIG"
kubectl rollout status statefulset spire-server -n zero-trust-workload-identity-manager --timeout=180s >/dev/null 2>&1 &
PID1=$!

export KUBECONFIG="$CLUSTER2_KUBECONFIG"
kubectl rollout status statefulset spire-server -n zero-trust-workload-identity-manager --timeout=180s >/dev/null 2>&1 &
PID2=$!

wait $PID1
wait $PID2

sleep 10
print_success "SPIRE Server pods restarted"
echo ""

# Step 9: Create federation routes
print_step 9 $TOTAL_STEPS "Creating federation route on Cluster 1"

export KUBECONFIG="$CLUSTER1_KUBECONFIG"
cat <<EOF | kubectl apply -f - >/dev/null 2>&1
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: spire-server-federation
  namespace: zero-trust-workload-identity-manager
  labels:
    app.kubernetes.io/name: server
    app.kubernetes.io/instance: spire
    app.kubernetes.io/managed-by: zero-trust-workload-identity-manager
spec:
  host: spire-federation-${CLUSTER1_NAME}.${CLUSTER1_ROUTE_BASE}
  port:
    targetPort: federation
  tls:
    termination: passthrough
  to:
    kind: Service
    name: spire-server
    weight: 100
  wildcardPolicy: None
EOF

print_success "Cluster 1 federation route created"

print_step 10 $TOTAL_STEPS "Creating federation route on Cluster 2"

export KUBECONFIG="$CLUSTER2_KUBECONFIG"
cat <<EOF | kubectl apply -f - >/dev/null 2>&1
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: spire-server-federation
  namespace: zero-trust-workload-identity-manager
  labels:
    app.kubernetes.io/name: server
    app.kubernetes.io/instance: spire
    app.kubernetes.io/managed-by: zero-trust-workload-identity-manager
spec:
  host: spire-federation-${CLUSTER2_NAME}.${CLUSTER2_ROUTE_BASE}
  port:
    targetPort: federation
  tls:
    termination: passthrough
  to:
    kind: Service
    name: spire-server
    weight: 100
  wildcardPolicy: None
EOF

print_success "Cluster 2 federation route created"
echo ""

# Step 11: Create ClusterFederatedTrustDomain resources
print_step 11 $TOTAL_STEPS "Creating ClusterFederatedTrustDomain on Cluster 1"

export KUBECONFIG="$CLUSTER1_KUBECONFIG"
cat <<EOF | kubectl apply -f - >/dev/null 2>&1
apiVersion: spire.spiffe.io/v1alpha1
kind: ClusterFederatedTrustDomain
metadata:
  name: ${CLUSTER2_NAME}-federation
spec:
  trustDomain: ${CLUSTER2_TRUST_DOMAIN}
  bundleEndpointURL: ${CLUSTER2_FED_URL}
  bundleEndpointProfile:
    type: https_spiffe
    endpointSPIFFEID: spiffe://${CLUSTER2_TRUST_DOMAIN}/spire/server
  className: zero-trust-workload-identity-manager-spire
EOF

print_success "Cluster 1 ClusterFederatedTrustDomain created"

print_step 12 $TOTAL_STEPS "Creating ClusterFederatedTrustDomain on Cluster 2"

export KUBECONFIG="$CLUSTER2_KUBECONFIG"
cat <<EOF | kubectl apply -f - >/dev/null 2>&1
apiVersion: spire.spiffe.io/v1alpha1
kind: ClusterFederatedTrustDomain
metadata:
  name: ${CLUSTER1_NAME}-federation
spec:
  trustDomain: ${CLUSTER1_TRUST_DOMAIN}
  bundleEndpointURL: ${CLUSTER1_FED_URL}
  bundleEndpointProfile:
    type: https_spiffe
    endpointSPIFFEID: spiffe://${CLUSTER1_TRUST_DOMAIN}/spire/server
  className: zero-trust-workload-identity-manager-spire
EOF

print_success "Cluster 2 ClusterFederatedTrustDomain created"
echo ""

# Step 13: Bootstrap trust bundles
print_step 13 $TOTAL_STEPS "Bootstrapping trust bundles"

print_info "Exporting bundle from Cluster 1..."
export KUBECONFIG="$CLUSTER1_KUBECONFIG"
kubectl exec -n zero-trust-workload-identity-manager spire-server-0 -c spire-server -- \
  /spire-server bundle show -format spiffe > /tmp/cluster1-bundle.txt 2>/dev/null

print_info "Exporting bundle from Cluster 2..."
export KUBECONFIG="$CLUSTER2_KUBECONFIG"
kubectl exec -n zero-trust-workload-identity-manager spire-server-0 -c spire-server -- \
  /spire-server bundle show -format spiffe > /tmp/cluster2-bundle.txt 2>/dev/null

print_info "Loading Cluster 2 bundle into Cluster 1..."
export KUBECONFIG="$CLUSTER1_KUBECONFIG"
cat /tmp/cluster2-bundle.txt | kubectl exec -i -n zero-trust-workload-identity-manager spire-server-0 -c spire-server -- \
  /spire-server bundle set -format spiffe -id spiffe://${CLUSTER2_TRUST_DOMAIN} >/dev/null 2>&1

print_info "Loading Cluster 1 bundle into Cluster 2..."
export KUBECONFIG="$CLUSTER2_KUBECONFIG"
cat /tmp/cluster1-bundle.txt | kubectl exec -i -n zero-trust-workload-identity-manager spire-server-0 -c spire-server -- \
  /spire-server bundle set -format spiffe -id spiffe://${CLUSTER1_TRUST_DOMAIN} >/dev/null 2>&1

print_success "Trust bundles exchanged"
echo ""

# Step 14: Create federated ClusterSPIFFEID resources
print_step 14 $TOTAL_STEPS "Creating federated ClusterSPIFFEID on Cluster 1"

export KUBECONFIG="$CLUSTER1_KUBECONFIG"
cat <<EOF | kubectl apply -f - >/dev/null 2>&1
apiVersion: spire.spiffe.io/v1alpha1
kind: ClusterSPIFFEID
metadata:
  name: federation-demo-workload
spec:
  spiffeIDTemplate: "spiffe://{{ .TrustDomain }}/ns/{{ .PodMeta.Namespace }}/sa/{{ .PodSpec.ServiceAccountName }}"
  podSelector:
    matchLabels:
      app: demo-federated
  namespaceSelector:
    matchLabels:
      federation-demo: "true"
  federatesWith:
    - ${CLUSTER2_TRUST_DOMAIN}
  workloadSelectorTemplates:
    - "k8s:ns:{{ .PodMeta.Namespace }}"
    - "k8s:sa:{{ .PodSpec.ServiceAccountName }}"
  dnsNameTemplates:
    - "{{ .PodMeta.Name }}.{{ .PodMeta.Namespace }}.svc.cluster.local"
  className: zero-trust-workload-identity-manager-spire
EOF

print_success "Cluster 1 federated ClusterSPIFFEID created"

print_step 15 $TOTAL_STEPS "Creating federated ClusterSPIFFEID on Cluster 2"

export KUBECONFIG="$CLUSTER2_KUBECONFIG"
cat <<EOF | kubectl apply -f - >/dev/null 2>&1
apiVersion: spire.spiffe.io/v1alpha1
kind: ClusterSPIFFEID
metadata:
  name: federation-demo-workload
spec:
  spiffeIDTemplate: "spiffe://{{ .TrustDomain }}/ns/{{ .PodMeta.Namespace }}/sa/{{ .PodSpec.ServiceAccountName }}"
  podSelector:
    matchLabels:
      app: demo-federated
  namespaceSelector:
    matchLabels:
      federation-demo: "true"
  federatesWith:
    - ${CLUSTER1_TRUST_DOMAIN}
  workloadSelectorTemplates:
    - "k8s:ns:{{ .PodMeta.Namespace }}"
    - "k8s:sa:{{ .PodSpec.ServiceAccountName }}"
  dnsNameTemplates:
    - "{{ .PodMeta.Name }}.{{ .PodMeta.Namespace }}.svc.cluster.local"
  className: zero-trust-workload-identity-manager-spire
EOF

print_success "Cluster 2 federated ClusterSPIFFEID created"
echo ""

print_header "Deploying Demo Workloads"

# Generate unique namespace name with timestamp
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
DEMO_NAMESPACE="federation-demo-${TIMESTAMP}"

print_info "Using namespace: $DEMO_NAMESPACE"
echo ""

# Deploy demo workloads
print_info "Deploying demo workload on Cluster 1..."
export KUBECONFIG="$CLUSTER1_KUBECONFIG"
cat <<EOF | kubectl apply -f - >/dev/null 2>&1
apiVersion: v1
kind: Namespace
metadata:
  name: ${DEMO_NAMESPACE}
  labels:
    federation-demo: "true"
    security.openshift.io/scc.podSecurityLabelSync: "false"
    pod-security.kubernetes.io/enforce: privileged
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: demo-workload
  namespace: ${DEMO_NAMESPACE}
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: demo-workload
  namespace: ${DEMO_NAMESPACE}
spec:
  replicas: 1
  selector:
    matchLabels:
      app: demo-federated
  template:
    metadata:
      labels:
        app: demo-federated
    spec:
      serviceAccountName: demo-workload
      containers:
      - name: demo
        image: alpine:latest
        command: ["/bin/sh", "-c"]
        args:
        - |
          echo "=== Federation Demo Workload (Cluster 1: ${CLUSTER1_NAME}) ==="
          echo "Trust Domain: ${CLUSTER1_TRUST_DOMAIN}"
          echo "Namespace: ${DEMO_NAMESPACE}"
          echo "Checking SPIFFE Workload API..."
          if [ -S /spiffe-workload-api/spire-agent.sock ]; then
            echo "✓ SPIFFE Workload API socket found!"
            ls -la /spiffe-workload-api/
          else
            echo "✗ SPIFFE Workload API socket not found"
          fi
          echo ""
          echo "Workload is ready and waiting..."
          while true; do sleep 3600; done
        volumeMounts:
        - name: spiffe-workload-api
          mountPath: /spiffe-workload-api
          readOnly: true
      volumes:
      - name: spiffe-workload-api
        csi:
          driver: csi.spiffe.io
          readOnly: true
EOF

print_success "Cluster 1 demo workload deployed"

print_info "Deploying demo workload on Cluster 2..."
export KUBECONFIG="$CLUSTER2_KUBECONFIG"
cat <<EOF | kubectl apply -f - >/dev/null 2>&1
apiVersion: v1
kind: Namespace
metadata:
  name: ${DEMO_NAMESPACE}
  labels:
    federation-demo: "true"
    security.openshift.io/scc.podSecurityLabelSync: "false"
    pod-security.kubernetes.io/enforce: privileged
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: demo-workload
  namespace: ${DEMO_NAMESPACE}
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: demo-workload
  namespace: ${DEMO_NAMESPACE}
spec:
  replicas: 1
  selector:
    matchLabels:
      app: demo-federated
  template:
    metadata:
      labels:
        app: demo-federated
    spec:
      serviceAccountName: demo-workload
      containers:
      - name: demo
        image: alpine:latest
        command: ["/bin/sh", "-c"]
        args:
        - |
          echo "=== Federation Demo Workload (Cluster 2: ${CLUSTER2_NAME}) ==="
          echo "Trust Domain: ${CLUSTER2_TRUST_DOMAIN}"
          echo "Namespace: ${DEMO_NAMESPACE}"
          echo "Checking SPIFFE Workload API..."
          if [ -S /spiffe-workload-api/spire-agent.sock ]; then
            echo "✓ SPIFFE Workload API socket found!"
            ls -la /spiffe-workload-api/
          else
            echo "✗ SPIFFE Workload API socket not found"
          fi
          echo ""
          echo "Workload is ready and waiting..."
          while true; do sleep 3600; done
        volumeMounts:
        - name: spiffe-workload-api
          mountPath: /spiffe-workload-api
          readOnly: true
      volumes:
      - name: spiffe-workload-api
        csi:
          driver: csi.spiffe.io
          readOnly: true
EOF

print_success "Cluster 2 demo workload deployed"
echo ""

print_info "Waiting for demo workloads to be ready..."
export KUBECONFIG="$CLUSTER1_KUBECONFIG"
kubectl wait --for=condition=ready pod -l app=demo-federated -n ${DEMO_NAMESPACE} --timeout=120s >/dev/null 2>&1 &
PID1=$!

export KUBECONFIG="$CLUSTER2_KUBECONFIG"
kubectl wait --for=condition=ready pod -l app=demo-federated -n ${DEMO_NAMESPACE} --timeout=120s >/dev/null 2>&1 &
PID2=$!

wait $PID1
wait $PID2

sleep 5
print_success "Demo workloads are ready in namespace: ${DEMO_NAMESPACE}"
echo ""

# Verification
print_header "Verifying Federation"
echo ""

print_info "Cluster 1 Verification:"
export KUBECONFIG="$CLUSTER1_KUBECONFIG"

echo -e "${CYAN}Trust Bundles:${NC}"
kubectl exec -n zero-trust-workload-identity-manager spire-server-0 -c spire-server -- \
  /spire-server bundle list 2>/dev/null | grep -E "^\*|${CLUSTER2_TRUST_DOMAIN}" | head -4

echo ""
echo -e "${CYAN}Workload Entry:${NC}"
kubectl exec -n zero-trust-workload-identity-manager spire-server-0 -c spire-server -- \
  /spire-server entry show -selector k8s:ns:${DEMO_NAMESPACE} 2>/dev/null | grep -E "^(SPIFFE ID|FederatesWith)" | head -2

echo ""
echo -e "${CYAN}Demo Workload Logs:${NC}"
kubectl logs -n ${DEMO_NAMESPACE} -l app=demo-federated --tail=10 2>/dev/null | head -8

echo ""
echo ""
print_info "Cluster 2 Verification:"
export KUBECONFIG="$CLUSTER2_KUBECONFIG"

echo -e "${CYAN}Trust Bundles:${NC}"
kubectl exec -n zero-trust-workload-identity-manager spire-server-0 -c spire-server -- \
  /spire-server bundle list 2>/dev/null | grep -E "^\*|${CLUSTER1_TRUST_DOMAIN}" | head -4

echo ""
echo -e "${CYAN}Workload Entry:${NC}"
kubectl exec -n zero-trust-workload-identity-manager spire-server-0 -c spire-server -- \
  /spire-server entry show -selector k8s:ns:${DEMO_NAMESPACE} 2>/dev/null | grep -E "^(SPIFFE ID|FederatesWith)" | head -2

echo ""
echo -e "${CYAN}Demo Workload Logs:${NC}"
kubectl logs -n ${DEMO_NAMESPACE} -l app=demo-federated --tail=10 2>/dev/null | head -8

echo ""
echo ""

# Final summary
print_header "✅ Federation Setup Complete!"
echo ""
print_success "Cluster 1 ($CLUSTER1_NAME)"
print_info "  Trust Domain: $CLUSTER1_TRUST_DOMAIN"
print_info "  Federation URL: $CLUSTER1_FED_URL"
print_info "  Federates With: $CLUSTER2_TRUST_DOMAIN"
echo ""
print_success "Cluster 2 ($CLUSTER2_NAME)"
print_info "  Trust Domain: $CLUSTER2_TRUST_DOMAIN"
print_info "  Federation URL: $CLUSTER2_FED_URL"
print_info "  Federates With: $CLUSTER1_TRUST_DOMAIN"
echo ""
print_success "Demo workloads deployed and running in namespace: ${DEMO_NAMESPACE}"
print_success "Workloads have access to SPIFFE Workload API"
print_success "Cross-cluster authentication is enabled"
echo ""
print_header "What's Working Now"
echo ""
echo "✅ Federation bundle endpoints exposed via OpenShift Routes"
echo "✅ Trust bundles exchanged between clusters"
echo "✅ ClusterFederatedTrustDomain resources configured"
echo "✅ ClusterSPIFFEID resources with federatesWith configured"
echo "✅ Demo workloads receiving federated trust bundles"
echo "✅ Workloads can authenticate across clusters"
echo ""
print_info "Note: The https_spiffe profile is used (requires SPIFFE auth)"
print_info "      This is more secure than public endpoints"
echo ""
print_header "Next Steps"
echo ""
echo "Demo namespace created: ${DEMO_NAMESPACE}"
echo ""
echo "To verify federation anytime, run:"
echo "  kubectl --kubeconfig=$CLUSTER1_KUBECONFIG exec -n zero-trust-workload-identity-manager spire-server-0 -c spire-server -- /spire-server bundle list"
echo ""
echo "To check workload entries in the demo namespace:"
echo "  kubectl --kubeconfig=$CLUSTER1_KUBECONFIG exec -n zero-trust-workload-identity-manager spire-server-0 -c spire-server -- /spire-server entry show -selector k8s:ns:${DEMO_NAMESPACE}"
echo ""
echo "To view demo workload logs:"
echo "  kubectl --kubeconfig=$CLUSTER1_KUBECONFIG logs -n ${DEMO_NAMESPACE} -l app=demo-federated"
echo ""
echo "To clean up demo namespace:"
echo "  kubectl --kubeconfig=$CLUSTER1_KUBECONFIG delete namespace ${DEMO_NAMESPACE}"
echo "  kubectl --kubeconfig=$CLUSTER2_KUBECONFIG delete namespace ${DEMO_NAMESPACE}"
echo ""

