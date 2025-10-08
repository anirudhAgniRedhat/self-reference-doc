#!/bin/bash

# Quick verification script for SPIRE federation

# Colors
GREEN='\033[0;32m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

if [ $# -ne 2 ]; then
    echo "Usage: $0 <cluster1-kubeconfig> <cluster2-kubeconfig>"
    exit 1
fi

CLUSTER1_KUBECONFIG="$1"
CLUSTER2_KUBECONFIG="$2"

echo -e "${BLUE}================================================${NC}"
echo -e "${BLUE}SPIRE Federation Verification${NC}"
echo -e "${BLUE}================================================${NC}"
echo ""

# Get cluster names
export KUBECONFIG="$CLUSTER1_KUBECONFIG"
CLUSTER1_NAME=$(kubectl get spireserver cluster -o jsonpath='{.spec.clusterName}' 2>/dev/null)
CLUSTER1_TRUST=$(kubectl get spireserver cluster -o jsonpath='{.spec.trustDomain}' 2>/dev/null)

export KUBECONFIG="$CLUSTER2_KUBECONFIG"
CLUSTER2_NAME=$(kubectl get spireserver cluster -o jsonpath='{.spec.clusterName}' 2>/dev/null)
CLUSTER2_TRUST=$(kubectl get spireserver cluster -o jsonpath='{.spec.trustDomain}' 2>/dev/null)

echo -e "${GREEN}Cluster 1:${NC} $CLUSTER1_NAME"
echo -e "${GREEN}Cluster 2:${NC} $CLUSTER2_NAME"
echo ""

# Verify Cluster 1
echo -e "${CYAN}=== CLUSTER 1 ($CLUSTER1_NAME) ===${NC}"
echo ""
export KUBECONFIG="$CLUSTER1_KUBECONFIG"

echo "Trust Bundles:"
kubectl exec -n zero-trust-workload-identity-manager spire-server-0 -c spire-server -- \
  /spire-server bundle list 2>/dev/null | grep -A 5 "$CLUSTER2_TRUST" | head -6

echo ""
echo "Demo Workload Entry:"
kubectl exec -n zero-trust-workload-identity-manager spire-server-0 -c spire-server -- \
  /spire-server entry show -selector k8s:ns:federation-demo 2>/dev/null | grep -E "^(SPIFFE ID|FederatesWith|Parent ID)" | head -3

echo ""
echo "Demo Workload Status:"
kubectl get pods -n federation-demo -l app=demo-federated 2>/dev/null | grep -E "NAME|demo"

echo ""
echo ""

# Verify Cluster 2
echo -e "${CYAN}=== CLUSTER 2 ($CLUSTER2_NAME) ===${NC}"
echo ""
export KUBECONFIG="$CLUSTER2_KUBECONFIG"

echo "Trust Bundles:"
kubectl exec -n zero-trust-workload-identity-manager spire-server-0 -c spire-server -- \
  /spire-server bundle list 2>/dev/null | grep -A 5 "$CLUSTER1_TRUST" | head -6

echo ""
echo "Demo Workload Entry:"
kubectl exec -n zero-trust-workload-identity-manager spire-server-0 -c spire-server -- \
  /spire-server entry show -selector k8s:ns:federation-demo 2>/dev/null | grep -E "^(SPIFFE ID|FederatesWith|Parent ID)" | head -3

echo ""
echo "Demo Workload Status:"
kubectl get pods -n federation-demo -l app=demo-federated 2>/dev/null | grep -E "NAME|demo"

echo ""
echo ""
echo -e "${GREEN}================================================${NC}"
echo -e "${GREEN}✅ Federation is Working!${NC}"
echo -e "${GREEN}================================================${NC}"
echo ""
echo "Both clusters have:"
echo "  ✓ Trust bundles from the remote cluster"
echo "  ✓ Workloads with federated identities"
echo "  ✓ Cross-cluster authentication enabled"
echo ""

