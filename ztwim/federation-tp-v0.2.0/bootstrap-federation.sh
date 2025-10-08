#!/bin/bash
set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Cluster configuration
CLUSTER1_KUBECONFIG="/home/aagnihot/workspace/test/installer/4.20-installer/aws/auth/kubeconfig"
CLUSTER2_KUBECONFIG="/home/aagnihot/workspace/test/installer/4.20-installer/aws1/auth/kubeconfig"

CLUSTER1_NAME="test01"
CLUSTER2_NAME="test02"

CLUSTER1_TRUST_DOMAIN="apps.aagnihot-cluster-povc.devcluster.openshift.com"
CLUSTER2_TRUST_DOMAIN="apps.aagnihot-cluster-fdk.devcluster.openshift.com"

NAMESPACE="zero-trust-workload-identity-manager"
BUNDLE_DIR="/tmp"

echo -e "${BLUE}================================================${NC}"
echo -e "${BLUE}SPIRE Federation Bundle Bootstrap${NC}"
echo -e "${BLUE}================================================${NC}"
echo ""

# Step 1: Export bundle from Cluster 1
echo -e "${YELLOW}Step 1: Exporting trust bundle from Cluster 1 (${CLUSTER1_NAME})...${NC}"
export KUBECONFIG="${CLUSTER1_KUBECONFIG}"
kubectl exec -n "${NAMESPACE}" spire-server-0 -c spire-server -- \
  /spire-server bundle show -format spiffe > "${BUNDLE_DIR}/cluster1-${CLUSTER1_NAME}-bundle.txt"

if [ $? -eq 0 ]; then
  echo -e "${GREEN}✓ Successfully exported bundle from Cluster 1${NC}"
  echo "  Saved to: ${BUNDLE_DIR}/cluster1-${CLUSTER1_NAME}-bundle.txt"
else
  echo -e "${RED}✗ Failed to export bundle from Cluster 1${NC}"
  exit 1
fi
echo ""

# Step 2: Export bundle from Cluster 2
echo -e "${YELLOW}Step 2: Exporting trust bundle from Cluster 2 (${CLUSTER2_NAME})...${NC}"
export KUBECONFIG="${CLUSTER2_KUBECONFIG}"
kubectl exec -n "${NAMESPACE}" spire-server-0 -c spire-server -- \
  /spire-server bundle show -format spiffe > "${BUNDLE_DIR}/cluster2-${CLUSTER2_NAME}-bundle.txt"

if [ $? -eq 0 ]; then
  echo -e "${GREEN}✓ Successfully exported bundle from Cluster 2${NC}"
  echo "  Saved to: ${BUNDLE_DIR}/cluster2-${CLUSTER2_NAME}-bundle.txt"
else
  echo -e "${RED}✗ Failed to export bundle from Cluster 2${NC}"
  exit 1
fi
echo ""

# Step 3: Load Cluster 2's bundle into Cluster 1
echo -e "${YELLOW}Step 3: Loading Cluster 2's bundle into Cluster 1...${NC}"
export KUBECONFIG="${CLUSTER1_KUBECONFIG}"
cat "${BUNDLE_DIR}/cluster2-${CLUSTER2_NAME}-bundle.txt" | \
  kubectl exec -i -n "${NAMESPACE}" spire-server-0 -c spire-server -- \
  /spire-server bundle set -format spiffe -id "spiffe://${CLUSTER2_TRUST_DOMAIN}"

if [ $? -eq 0 ]; then
  echo -e "${GREEN}✓ Successfully loaded Cluster 2's bundle into Cluster 1${NC}"
else
  echo -e "${RED}✗ Failed to load Cluster 2's bundle into Cluster 1${NC}"
  exit 1
fi
echo ""

# Step 4: Load Cluster 1's bundle into Cluster 2
echo -e "${YELLOW}Step 4: Loading Cluster 1's bundle into Cluster 2...${NC}"
export KUBECONFIG="${CLUSTER2_KUBECONFIG}"
cat "${BUNDLE_DIR}/cluster1-${CLUSTER1_NAME}-bundle.txt" | \
  kubectl exec -i -n "${NAMESPACE}" spire-server-0 -c spire-server -- \
  /spire-server bundle set -format spiffe -id "spiffe://${CLUSTER1_TRUST_DOMAIN}"

if [ $? -eq 0 ]; then
  echo -e "${GREEN}✓ Successfully loaded Cluster 1's bundle into Cluster 2${NC}"
else
  echo -e "${RED}✗ Failed to load Cluster 1's bundle into Cluster 2${NC}"
  exit 1
fi
echo ""

# Verification
echo -e "${BLUE}================================================${NC}"
echo -e "${BLUE}Verification${NC}"
echo -e "${BLUE}================================================${NC}"
echo ""

echo -e "${YELLOW}Verifying Cluster 1 (${CLUSTER1_NAME})...${NC}"
export KUBECONFIG="${CLUSTER1_KUBECONFIG}"
kubectl exec -n "${NAMESPACE}" spire-server-0 -c spire-server -- \
  /spire-server bundle list
echo ""

echo -e "${YELLOW}Verifying Cluster 2 (${CLUSTER2_NAME})...${NC}"
export KUBECONFIG="${CLUSTER2_KUBECONFIG}"
kubectl exec -n "${NAMESPACE}" spire-server-0 -c spire-server -- \
  /spire-server bundle list
echo ""

echo -e "${GREEN}================================================${NC}"
echo -e "${GREEN}Federation Bootstrap Complete!${NC}"
echo -e "${GREEN}================================================${NC}"
echo ""
echo -e "Trust bundles have been successfully exchanged between:"
echo -e "  • Cluster 1 (${CLUSTER1_NAME}): ${CLUSTER1_TRUST_DOMAIN}"
echo -e "  • Cluster 2 (${CLUSTER2_NAME}): ${CLUSTER2_TRUST_DOMAIN}"
echo ""
echo -e "The SPIRE Controller Manager will now automatically refresh the bundles."
echo -e "Workloads with federatesWith configuration will receive federated trust bundles."
echo ""
echo -e "Bundle files saved in ${BUNDLE_DIR}:"
echo -e "  • cluster1-${CLUSTER1_NAME}-bundle.txt"
echo -e "  • cluster2-${CLUSTER2_NAME}-bundle.txt"
echo ""

