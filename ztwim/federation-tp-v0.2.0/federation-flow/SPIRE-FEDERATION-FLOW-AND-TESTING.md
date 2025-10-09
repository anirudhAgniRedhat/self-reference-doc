# SPIRE Federation Flow Diagrams and Testing Guide

## Table of Contents
1. [Federation Setup Flow](#federation-setup-flow)
2. [Bundle Exchange Flow](#bundle-exchange-flow)
3. [Workload Authentication Flow](#workload-authentication-flow)
4. [Kubernetes Federation Flow](#kubernetes-federation-flow)
5. [How to Test Federation](#how-to-test-federation)

---

## 1. Federation Setup Flow

```
┌─────────────────────────────────────────────────────────────────────────┐
│                         INITIAL SETUP PHASE                              │
└─────────────────────────────────────────────────────────────────────────┘

Trust Domain A (cluster1.example.com)          Trust Domain B (cluster2.example.com)
┌────────────────────────────┐                 ┌────────────────────────────┐
│   SPIRE Server A           │                 │   SPIRE Server B           │
│   ┌──────────────────┐     │                 │     ┌──────────────────┐   │
│   │  Generate CA     │     │                 │     │  Generate CA     │   │
│   │  & Trust Bundle  │     │                 │     │  & Trust Bundle  │   │
│   └────────┬─────────┘     │                 │     └────────┬─────────┘   │
│            │               │                 │              │             │
│            ▼               │                 │              ▼             │
│   ┌──────────────────┐     │                 │     ┌──────────────────┐   │
│   │ Start Bundle     │     │                 │     │ Start Bundle     │   │
│   │ Endpoint Server  │     │                 │     │ Endpoint Server  │   │
│   │ Port: 8443       │     │                 │     │ Port: 8443       │   │
│   └────────┬─────────┘     │                 │     └────────┬─────────┘   │
└────────────┼────────────────┘                 └──────────────┼─────────────┘
             │                                                 │
             │                                                 │
             └──────────────────┬──────────────────────────────┘
                                │
                                ▼
                   ┌────────────────────────────┐
                   │ Administrator Configures   │
                   │ Federation Relationships   │
                   │ in server.conf             │
                   └────────────────────────────┘
```

**Configuration:**

```hcl
# Server A Config
server {
    trust_domain = "cluster1.example.com"
    
    federation {
        bundle_endpoint {
            port = 8443
            profile "https_spiffe" {}
        }
        
        federates_with "cluster2.example.com" {
            bundle_endpoint_url = "https://spire-server-b:8443"
            bundle_endpoint_profile "https_spiffe" {
                endpoint_spiffe_id = "spiffe://cluster2.example.com/spire/server"
            }
        }
    }
}
```

---

## 2. Bundle Exchange Flow (Dynamic Updates)

```
┌─────────────────────────────────────────────────────────────────────────┐
│                    AUTOMATIC BUNDLE SYNCHRONIZATION                      │
└─────────────────────────────────────────────────────────────────────────┘

    SPIRE Server A                                      SPIRE Server B
    (cluster1.example.com)                              (cluster2.example.com)

┌──────────────────────┐                            ┌──────────────────────┐
│ Bundle Updater       │                            │ Bundle Endpoint      │
│ (runs periodically)  │                            │ (HTTPS Server)       │
└──────┬───────────────┘                            └──────────┬───────────┘
       │                                                       │
       │ 1. Initiate TLS Connection                           │
       │ ───────────────────────────────────────────────────> │
       │                                                       │
       │ 2. Authenticate using SPIFFE ID                      │
       │    (if https_spiffe profile)                         │
       │ <─────────────────────────────────────────────────── │
       │                                                       │
       │ 3. Request: GET /                                    │
       │ ───────────────────────────────────────────────────> │
       │                                                       │
       │                                           ┌───────────┴──────────┐
       │                                           │ Fetch current bundle │
       │                                           │ from datastore       │
       │                                           └───────────┬──────────┘
       │                                                       │
       │ 4. Response: Trust Bundle (JWKS format)              │
       │ <─────────────────────────────────────────────────── │
       │    {                                                 │
       │      "keys": [...],                                  │
       │      "spiffe_refresh_hint": 600                      │
       │    }                                                 │
       │                                                       │
┌──────┴───────────────┐                                      │
│ 5. Compare with      │                                      │
│    local cached      │                                      │
│    bundle            │                                      │
└──────┬───────────────┘                                      │
       │                                                       │
       │ If Different:                                         │
┌──────┴───────────────┐                                      │
│ 6. Store in          │                                      │
│    Datastore         │                                      │
│    (FederatedBundle) │                                      │
└──────┬───────────────┘                                      │
       │                                                       │
       │ 7. Wait for refresh_hint duration                     │
       │    (default: 5-10 minutes)                           │
       │                                                       │
       │ 8. Repeat from step 1                                │
       └──────────────────────────────────────────────────────┘
```

**Code Flow:**
- `pkg/server/bundle/client/updater.go` - Bundle fetching logic
- `pkg/server/endpoints/bundle/bundle.go` - Bundle endpoint server
- `pkg/server/datastore/` - Stores federated bundles

---

## 3. Workload Authentication Flow (Cross-Domain)

```
┌─────────────────────────────────────────────────────────────────────────┐
│              WORKLOAD-TO-WORKLOAD AUTHENTICATION                         │
│              (Across Federated Trust Domains)                            │
└─────────────────────────────────────────────────────────────────────────┘

Trust Domain A                                      Trust Domain B
┌────────────────────────┐                         ┌────────────────────────┐
│ Workload A             │                         │ Workload B             │
│ (Frontend Service)     │                         │ (Backend Service)      │
└──────┬─────────────────┘                         └──────┬─────────────────┘
       │                                                   │
       │ 1. Request SVID + Bundles                        │
       ▼                                                   ▼
┌────────────────────────┐                         ┌────────────────────────┐
│ SPIRE Agent A          │                         │ SPIRE Agent B          │
│ (Workload API)         │                         │ (Workload API)         │
└──────┬─────────────────┘                         └──────┬─────────────────┘
       │                                                   │
       │ 2. Fetch from Server                             │ 2. Fetch from Server
       ▼                                                   ▼
┌────────────────────────┐                         ┌────────────────────────┐
│ SPIRE Server A         │                         │ SPIRE Server B         │
│                        │                         │                        │
│ Datastore:             │                         │ Datastore:             │
│ ├─ Local Bundle (A)    │                         │ ├─ Local Bundle (B)    │
│ └─ Federated Bundle(B) │                         │ └─ Federated Bundle(A) │
└──────┬─────────────────┘                         └──────┬─────────────────┘
       │                                                   │
       │ 3. Returns:                                       │ 3. Returns:
       │    - X.509-SVID for Workload A                   │    - X.509-SVID for Workload B
       │    - Bundle A (local)                             │    - Bundle B (local)
       │    - Bundle B (federated)                         │    - Bundle A (federated)
       ▼                                                   ▼
┌────────────────────────┐                         ┌────────────────────────┐
│ Workload A             │                         │ Workload B             │
│                        │                         │                        │
│ Has:                   │                         │ Has:                   │
│ ├─ SVID-A              │                         │ ├─ SVID-B              │
│ ├─ Trust Bundle A      │                         │ ├─ Trust Bundle B      │
│ └─ Trust Bundle B      │                         │ └─ Trust Bundle A      │
└──────┬─────────────────┘                         └──────┬─────────────────┘
       │                                                   │
       │ 4. Establish mTLS Connection                     │
       │ ──────────────────────────────────────────────>  │
       │                                                   │
       │    Client Cert: SVID-A                           │
       │    (spiffe://cluster1.example.com/frontend)      │
       │                                                   │
       │                              5. Validate SVID-A   │
       │                                 using Bundle A ───┤
       │                                 (federated)       │
       │                                                   │
       │  <─────────────────────────────────────────────  │
       │    Server Cert: SVID-B                           │
       │    (spiffe://cluster2.example.com/backend)       │
       │                                                   │
       │ 6. Validate SVID-B                               │
       │    using Bundle B (federated)                    │
       │                                                   │
       │ 7. Mutual TLS Established!                       │
       │ <══════════════════════════════════════════════> │
       │           Secure Communication                    │
       └───────────────────────────────────────────────────┘
```

**Key Points:**
- Each workload gets BOTH local and federated trust bundles
- Validation uses the appropriate bundle based on SPIFFE ID trust domain
- No network routing required between SPIRE Servers during workload auth

---

## 4. Kubernetes Federation Flow

```
┌─────────────────────────────────────────────────────────────────────────┐
│                  KUBERNETES MULTI-CLUSTER FEDERATION                     │
└─────────────────────────────────────────────────────────────────────────┘

Cluster 1 (GKE - us-west)                      Cluster 2 (EKS - us-east)
Trust Domain: cluster1.example.com             Trust Domain: cluster2.example.com

┌───────────────────────────────┐              ┌───────────────────────────────┐
│  Namespace: spire              │              │  Namespace: spire              │
│  ┌─────────────────────────┐  │              │  ┌─────────────────────────┐  │
│  │ SPIRE Server Pod        │  │              │  │ SPIRE Server Pod        │  │
│  │                         │  │              │  │                         │  │
│  │ ┌─────────────────────┐ │  │              │  │ ┌─────────────────────┐ │  │
│  │ │ Bundle Endpoint     │ │  │              │  │ │ Bundle Endpoint     │ │  │
│  │ │ :8443               │ │  │              │  │ │ :8443               │ │  │
│  │ └──────────┬──────────┘ │  │              │  │ └──────────┬──────────┘ │  │
│  │            │            │  │              │  │            │            │  │
│  │ ┌──────────▼──────────┐ │  │              │  │ ┌──────────▼──────────┐ │  │
│  │ │ Bundle Publisher    │ │  │              │  │ │ Bundle Publisher    │ │  │
│  │ │ (k8s_configmap)     │ │  │              │  │ │ (k8s_configmap)     │ │  │
│  │ └──────────┬──────────┘ │  │              │  │ └──────────┬──────────┘ │  │
│  └────────────┼─────────────┘  │              │  └────────────┼─────────────┘  │
│               │                │              │               │                │
│               ▼                │              │               ▼                │
│  ┌────────────────────────┐   │              │  ┌────────────────────────┐   │
│  │ ConfigMap              │   │              │  │ ConfigMap              │   │
│  │ Name: spire-bundle     │   │              │  │ Name: spire-bundle     │   │
│  │ Data:                  │   │              │  │ Data:                  │   │
│  │   bundle: <JWKS>       │   │              │  │   bundle: <JWKS>       │   │
│  │   (Trust Bundle 1)     │   │              │  │   (Trust Bundle 2)     │   │
│  └────────────────────────┘   │              │  └────────────────────────┘   │
└──────────────┬────────────────┘              └──────────────┬────────────────┘
               │                                              │
               │                                              │
               │  ┌────────────────────────────────────────┐  │
               │  │  External Load Balancer / Ingress     │  │
               │  │  - TLS Termination                     │  │
               │  │  - DNS: spire-server-1.example.com    │  │
               │  │         spire-server-2.example.com    │  │
               │  └────────────────────────────────────────┘  │
               │                     ▲                        │
               └─────────────────────┼────────────────────────┘
                                     │
                          Bundle Exchange over HTTPS
                          
┌─────────────────────────────────────────────────────────────────────────┐
│                        AGENT & WORKLOAD LAYER                            │
└─────────────────────────────────────────────────────────────────────────┘

Cluster 1: Namespace: frontend                Cluster 2: Namespace: backend
┌─────────────────────────┐                   ┌─────────────────────────┐
│ ┌─────────────────────┐ │                   │ ┌─────────────────────┐ │
│ │ SPIRE Agent         │ │                   │ │ SPIRE Agent         │ │
│ │ (DaemonSet Pod)     │ │                   │ │ (DaemonSet Pod)     │ │
│ │                     │ │                   │ │                     │ │
│ │ Unix Socket:        │ │                   │ │ Unix Socket:        │ │
│ │ /run/spire/sockets/ │ │                   │ │ /run/spire/sockets/ │ │
│ │ agent.sock          │ │                   │ │ agent.sock          │ │
│ └──────────┬──────────┘ │                   │ └──────────┬──────────┘ │
│            │            │                   │            │            │
│            │ Mounted    │                   │            │ Mounted    │
│            ▼            │                   │            ▼            │
│ ┌─────────────────────┐ │                   │ ┌─────────────────────┐ │
│ │ Frontend Pod        │ │                   │ │ Backend Pod         │ │
│ │                     │ │                   │ │                     │ │
│ │ Selector:           │ │                   │ │ Selector:           │ │
│ │ k8s:ns:frontend     │ │                   │ │ k8s:ns:backend      │ │
│ │ k8s:sa:frontend-sa  │ │                   │ │ k8s:sa:backend-sa   │ │
│ │                     │ │                   │ │                     │ │
│ │ Gets SVID:          │ │                   │ │ Gets SVID:          │ │
│ │ cluster1.../frontend│ │                   │ │ cluster2.../backend │ │
│ │                     │ │                   │ │                     │ │
│ │ Gets Bundles:       │ │                   │ │ Gets Bundles:       │ │
│ │ ├─ Bundle 1 (local) │ │                   │ │ ├─ Bundle 2 (local) │ │
│ │ └─ Bundle 2 (fed)   │ │                   │ │ └─ Bundle 1 (fed)   │ │
│ └─────────────────────┘ │                   │ └─────────────────────┘ │
└─────────────────────────┘                   └─────────────────────────┘
         │                                                 │
         │         8. Cross-Cluster mTLS Connection       │
         └────────────────────────────────────────────────┘
```

**Registration Entries:**

```bash
# Cluster 1: Register frontend with federation
spire-server entry create \
  -spiffeID spiffe://cluster1.example.com/frontend \
  -parentID spiffe://cluster1.example.com/k8s-agent \
  -selector k8s:ns:frontend \
  -selector k8s:sa:frontend-sa \
  -federatesWith spiffe://cluster2.example.com

# Cluster 2: Register backend with federation
spire-server entry create \
  -spiffeID spiffe://cluster2.example.com/backend \
  -parentID spiffe://cluster2.example.com/k8s-agent \
  -selector k8s:ns:backend \
  -selector k8s:sa:backend-sa \
  -federatesWith spiffe://cluster1.example.com
```

---

## 5. How to Test Federation

### Option 1: Test Using Docker Compose (Fastest)

This uses the existing integration test suite in the SPIRE repository.

```bash
# Navigate to the federation test suite
cd test/integration/suites/ghostunnel-federation

# Run the complete federation test
./test.sh

# What this tests:
# - Two separate trust domains
# - Bundle endpoint setup
# - Dynamic bundle exchange
# - Cross-domain workload authentication
# - Server/Agent resilience
```

**Manual Step-by-Step Testing:**

```bash
# 1. Start the test environment
./00-setup
./01-start-servers

# 2. Check both servers are running
docker compose ps

# Expected output:
# - upstream-spire-server (running)
# - downstream-spire-server (running)

# 3. Bootstrap federation (exchange bundles)
./02-bootstrap-federation-and-agents

# 4. Verify bundle exchange
docker compose exec upstream-spire-server \
  /opt/spire/bin/spire-server bundle list

# Expected: Should see both upstream-domain.test and downstream-domain.test

docker compose exec downstream-spire-server \
  /opt/spire/bin/spire-server bundle list

# Expected: Should see both domains

# 5. Start agents and workloads
./03-start-remaining-containers

# 6. Create workload entries with federation
./04-create-workload-entries

# 7. Test cross-domain connectivity
./05-check-workload-connectivity

# This tests that workloads in different trust domains can communicate
```

---

### Option 2: Test in Kubernetes (Production-Like)

**Prerequisites:**
- Two Kubernetes clusters (can be separate namespaces in same cluster for testing)
- kubectl configured
- SPIRE Helm chart or manifests

#### Step 1: Deploy SPIRE in Cluster 1

```bash
# Create namespace
kubectl create namespace spire

# Create SPIRE Server ConfigMap
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: spire-server
  namespace: spire
data:
  server.conf: |
    server {
      bind_address = "0.0.0.0"
      bind_port = "8081"
      trust_domain = "cluster1.example.com"
      data_dir = "/run/spire/data"
      log_level = "DEBUG"
      
      federation {
        bundle_endpoint {
          address = "0.0.0.0"
          port = 8443
          profile "https_spiffe" {}
        }
        
        # Will add federates_with after cluster2 is ready
      }
    }
    
    plugins {
      DataStore "sql" {
        plugin_data {
          database_type = "sqlite3"
          connection_string = "/run/spire/data/datastore.sqlite3"
        }
      }
      
      KeyManager "memory" {
        plugin_data {}
      }
      
      NodeAttestor "k8s_psat" {
        plugin_data {
          clusters = {
            "cluster1" = {
              service_account_allow_list = ["spire:spire-agent"]
            }
          }
        }
      }
      
      BundlePublisher "k8s_configmap" {
        plugin_data {
          clusters = {
            "local" = {
              namespace = "spire"
              configmap_name = "spire-bundle"
              configmap_key = "bundle"
              format = "spiffe"
            }
          }
        }
      }
    }
EOF

# Deploy SPIRE Server
kubectl apply -f - <<EOF
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: spire-server
  namespace: spire
spec:
  serviceName: spire-server
  replicas: 1
  selector:
    matchLabels:
      app: spire-server
  template:
    metadata:
      labels:
        app: spire-server
    spec:
      serviceAccountName: spire-server
      containers:
      - name: spire-server
        image: ghcr.io/spiffe/spire-server:1.9.0
        args:
        - -config
        - /run/spire/config/server.conf
        ports:
        - containerPort: 8081
          name: grpc
        - containerPort: 8443
          name: federation
        volumeMounts:
        - name: spire-config
          mountPath: /run/spire/config
          readOnly: true
        - name: spire-data
          mountPath: /run/spire/data
      volumes:
      - name: spire-config
        configMap:
          name: spire-server
  volumeClaimTemplates:
  - metadata:
      name: spire-data
    spec:
      accessModes: ["ReadWriteOnce"]
      resources:
        requests:
          storage: 1Gi
---
apiVersion: v1
kind: Service
metadata:
  name: spire-server
  namespace: spire
spec:
  type: ClusterIP
  ports:
  - name: grpc
    port: 8081
    targetPort: 8081
  - name: federation
    port: 8443
    targetPort: 8443
  selector:
    app: spire-server
---
apiVersion: v1
kind: Service
metadata:
  name: spire-server-federation
  namespace: spire
spec:
  type: LoadBalancer  # or NodePort for testing
  ports:
  - name: federation
    port: 8443
    targetPort: 8443
  selector:
    app: spire-server
EOF

# Create RBAC for bundle publisher
kubectl apply -f - <<EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: spire-server
  namespace: spire
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: spire-server-role
  namespace: spire
rules:
- apiGroups: [""]
  resources: ["configmaps"]
  verbs: ["create", "get", "patch", "list", "watch"]
- apiGroups: [""]
  resources: ["pods", "nodes"]
  verbs: ["get", "list"]
- apiGroups: ["authentication.k8s.io"]
  resources: ["tokenreviews"]
  verbs: ["create"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: spire-server-binding
  namespace: spire
subjects:
- kind: ServiceAccount
  name: spire-server
  namespace: spire
roleRef:
  kind: Role
  name: spire-server-role
  apiGroup: rbac.authorization.k8s.io
EOF
```

#### Step 2: Deploy SPIRE in Cluster 2

Repeat the same steps in Cluster 2, but change:
- `trust_domain` to `cluster2.example.com`
- Service names if in same cluster (e.g., `spire-server-cluster2`)

#### Step 3: Configure Federation

```bash
# Get the external IP/hostname of cluster2's federation endpoint
CLUSTER2_ENDPOINT=$(kubectl get svc spire-server-federation -n spire -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')

echo "Cluster 2 Federation Endpoint: https://${CLUSTER2_ENDPOINT}:8443"

# Get Cluster 2's SPIRE Server SPIFFE ID
kubectl exec -n spire spire-server-0 -- \
  /opt/spire/bin/spire-server agent list

# Update Cluster 1 server config to add federates_with
kubectl edit configmap spire-server -n spire

# Add under federation section:
#   federates_with "cluster2.example.com" {
#     bundle_endpoint_url = "https://${CLUSTER2_ENDPOINT}:8443"
#     bundle_endpoint_profile "https_spiffe" {
#       endpoint_spiffe_id = "spiffe://cluster2.example.com/spire/server"
#     }
#   }

# Restart server to apply changes
kubectl rollout restart statefulset/spire-server -n spire

# Repeat for Cluster 2
```

#### Step 4: Verify Bundle Exchange

```bash
# Check bundles in Cluster 1
kubectl exec -n spire spire-server-0 -- \
  /opt/spire/bin/spire-server bundle list

# Expected output:
# spiffe://cluster1.example.com  (local)
# spiffe://cluster2.example.com  (federated)

# Check ConfigMap was created
kubectl get configmap spire-bundle -n spire -o yaml

# Verify bundle content
kubectl get configmap spire-bundle -n spire -o jsonpath='{.data.bundle}' | jq .
```

#### Step 5: Deploy Test Workloads

```bash
# Cluster 1: Deploy frontend
kubectl apply -f - <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: frontend
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: frontend-sa
  namespace: frontend
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: frontend
  namespace: frontend
spec:
  replicas: 1
  selector:
    matchLabels:
      app: frontend
  template:
    metadata:
      labels:
        app: frontend
    spec:
      serviceAccountName: frontend-sa
      containers:
      - name: frontend
        image: nginx:alpine
        volumeMounts:
        - name: spire-agent-socket
          mountPath: /run/spire/sockets
          readOnly: true
      volumes:
      - name: spire-agent-socket
        hostPath:
          path: /run/spire/sockets
          type: Directory
EOF

# Cluster 2: Deploy backend (similar)
```

#### Step 6: Create Registration Entries

```bash
# Cluster 1: Register frontend with federation
kubectl exec -n spire spire-server-0 -- \
  /opt/spire/bin/spire-server entry create \
  -spiffeID spiffe://cluster1.example.com/frontend \
  -parentID spiffe://cluster1.example.com/k8s-agent \
  -selector k8s:ns:frontend \
  -selector k8s:sa:frontend-sa \
  -federatesWith spiffe://cluster2.example.com

# Cluster 2: Register backend with federation
kubectl exec -n spire spire-server-0 -- \
  /opt/spire/bin/spire-server entry create \
  -spiffeID spiffe://cluster2.example.com/backend \
  -parentID spiffe://cluster2.example.com/k8s-agent \
  -selector k8s:ns:backend \
  -selector k8s:sa:backend-sa \
  -federatesWith spiffe://cluster1.example.com
```

#### Step 7: Test Federation

```bash
# Deploy a test tool (spiffe-helper or go-spiffe test client)
kubectl apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: federation-test
  namespace: frontend
spec:
  serviceAccountName: frontend-sa
  containers:
  - name: test
    image: ghcr.io/spiffe/spire-agent:1.9.0
    command: ["/bin/sh", "-c", "sleep 3600"]
    volumeMounts:
    - name: spire-agent-socket
      mountPath: /run/spire/sockets
      readOnly: true
  volumes:
  - name: spire-agent-socket
    hostPath:
      path: /run/spire/sockets
      type: Directory
EOF

# Check workload can fetch SVID and bundles
kubectl exec -n frontend federation-test -- \
  /opt/spire/bin/spire-agent api fetch x509 \
  -socketPath /run/spire/sockets/agent.sock

# Expected output should show:
# - SVID for cluster1.example.com/frontend
# - Bundle for cluster1.example.com (1 certificate)
# - Bundle for cluster2.example.com (1 certificate) <- FEDERATED!
```

---

### Option 3: Automated Testing Script

Create a test script to validate federation:

```bash
#!/bin/bash
# save as test-federation.sh

set -e

echo "=== SPIRE Federation Test Script ==="

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m' # No Color

test_passed() {
    echo -e "${GREEN}✓ $1${NC}"
}

test_failed() {
    echo -e "${RED}✗ $1${NC}"
    exit 1
}

# Test 1: Check both servers are running
echo "Test 1: Checking SPIRE Servers..."
kubectl get pods -n spire | grep spire-server | grep Running > /dev/null && \
    test_passed "SPIRE Servers are running" || \
    test_failed "SPIRE Servers not running"

# Test 2: Check bundle endpoints are accessible
echo "Test 2: Checking Bundle Endpoints..."
kubectl exec -n spire spire-server-0 -- \
    curl -k https://localhost:8443 > /dev/null 2>&1 && \
    test_passed "Bundle endpoint accessible" || \
    test_failed "Bundle endpoint not accessible"

# Test 3: Check federated bundles are present
echo "Test 3: Checking Federated Bundles..."
BUNDLES=$(kubectl exec -n spire spire-server-0 -- \
    /opt/spire/bin/spire-server bundle list)

echo "$BUNDLES" | grep "cluster1.example.com" > /dev/null && \
    test_passed "Local bundle present" || \
    test_failed "Local bundle missing"

echo "$BUNDLES" | grep "cluster2.example.com" > /dev/null && \
    test_passed "Federated bundle present" || \
    test_failed "Federated bundle missing"

# Test 4: Check ConfigMap bundle publisher
echo "Test 4: Checking Bundle Publisher..."
kubectl get configmap spire-bundle -n spire > /dev/null && \
    test_passed "Bundle ConfigMap exists" || \
    test_failed "Bundle ConfigMap missing"

BUNDLE_DATA=$(kubectl get configmap spire-bundle -n spire -o jsonpath='{.data.bundle}')
echo "$BUNDLE_DATA" | jq . > /dev/null 2>&1 && \
    test_passed "Bundle data is valid JSON" || \
    test_failed "Bundle data invalid"

# Test 5: Check workload registration
echo "Test 5: Checking Workload Registration..."
ENTRIES=$(kubectl exec -n spire spire-server-0 -- \
    /opt/spire/bin/spire-server entry show)

echo "$ENTRIES" | grep "federatesWith" > /dev/null && \
    test_passed "Federation entry exists" || \
    test_failed "No federation entries"

# Test 6: Test workload SVID fetch
echo "Test 6: Testing Workload SVID Fetch..."
if kubectl get pod federation-test -n frontend > /dev/null 2>&1; then
    SVID_OUTPUT=$(kubectl exec -n frontend federation-test -- \
        /opt/spire/bin/spire-agent api fetch x509 \
        -socketPath /run/spire/sockets/agent.sock 2>&1)
    
    echo "$SVID_OUTPUT" | grep "SPIFFE ID" > /dev/null && \
        test_passed "Workload can fetch SVID" || \
        test_failed "Workload cannot fetch SVID"
    
    BUNDLE_COUNT=$(echo "$SVID_OUTPUT" | grep -c "Trust domain:" || true)
    if [ "$BUNDLE_COUNT" -ge 2 ]; then
        test_passed "Workload has federated bundles (count: $BUNDLE_COUNT)"
    else
        test_failed "Workload missing federated bundles (count: $BUNDLE_COUNT)"
    fi
else
    echo "Skipping workload test (federation-test pod not found)"
fi

echo ""
echo "=== All Tests Passed ==="
```

Run it:
```bash
chmod +x test-federation.sh
./test-federation.sh
```

---

## Verification Checklist

- [ ] **Server Configuration**: Both servers have `federation` section configured
- [ ] **Bundle Endpoints**: Both servers expose port 8443
- [ ] **Network Connectivity**: Servers can reach each other's bundle endpoints
- [ ] **Bundle Exchange**: `spire-server bundle list` shows both local and federated bundles
- [ ] **Registration Entries**: Workloads have `-federatesWith` flag set
- [ ] **Workload API**: Workloads receive federated bundles via Workload API
- [ ] **mTLS Connection**: Workloads can establish cross-domain mTLS

---

## Troubleshooting

### Issue: Federated bundle not appearing

```bash
# Check server logs
kubectl logs -n spire spire-server-0 | grep -i federation

# Common issues:
# - Network connectivity between servers
# - Incorrect endpoint_spiffe_id
# - TLS/certificate issues
# - Firewall blocking port 8443
```

### Issue: Workload not getting federated bundle

```bash
# Check registration entry
kubectl exec -n spire spire-server-0 -- \
  /opt/spire/bin/spire-server entry show -spiffeID spiffe://cluster1.example.com/frontend

# Ensure it has: federatesWith: [cluster2.example.com]

# Check agent logs
kubectl logs -n spire -l app=spire-agent | grep -i bundle
```

### Issue: Bundle endpoint not accessible

```bash
# Test directly
kubectl exec -n spire spire-server-0 -- \
  curl -k https://spire-server:8443

# Should return JWKS bundle JSON

# Check service
kubectl get svc spire-server -n spire
kubectl describe svc spire-server -n spire
```

---

## Best Practices

1. **Use `https_spiffe` profile** in production for stronger security
2. **Monitor bundle refresh** - set appropriate `refresh_hint` values
3. **Automate bundle rotation** - ensure servers can always reach each other
4. **Use bundle publisher** in Kubernetes for easier distribution
5. **Test failover** - ensure workloads continue working during server downtime
6. **Implement monitoring** - alert on federation bundle fetch failures
7. **Document trust relationships** - maintain a registry of federated domains

---

## Quick Reference: Key Commands

```bash
# List all bundles (local + federated)
spire-server bundle list

# Show specific bundle
spire-server bundle show -format spiffe

# Create federation relationship via CLI
spire-server federation create \
  -trustDomain cluster2.example.com \
  -bundleEndpointURL https://spire-server-2:8443 \
  -bundleEndpointProfile https_spiffe \
  -endpointSPIFFEID spiffe://cluster2.example.com/spire/server

# List federation relationships
spire-server federation list

# Delete federation relationship
spire-server federation delete -id cluster2.example.com

# Fetch workload SVID (agent command)
spire-agent api fetch x509 -socketPath /run/spire/sockets/agent.sock
```



