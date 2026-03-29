# Zero-Trust Workload Identity Manager: Common Config Centralization Roadmap

**Objective:** Move duplicated configuration (TrustDomain, ClusterName, BundleConfigMap) from operand CRs to the main `ZeroTrustWorkloadIdentityManager` CR to eliminate duplication while maintaining consistency and compatibility.

**Owner References & Finalizers Strategy:** Detailed dependency mapping for ensuring safe lifecycle management of operands.

---

## 1. CURRENT STATE ANALYSIS

### 1.1 Duplicated Fields Across Operand CRs

| Field | SpireServer | SpireAgent | SpireOIDC | SpiffeCSI | ZTWIM |
|-------|-------------|------------|-----------|-----------|-------|
| TrustDomain | ✓ (Required) | ✓ (Required) | ✓ (Required) | ✗ | ✗ |
| ClusterName | ✓ (Required) | ✓ (Required) | ✗ | ✗ | ✗ |
| BundleConfigMap | ✓ (Optional) | ✓ (Optional) | ✗ | ✗ | ✗ |
| Labels (CommonConfig) | ✓ | ✓ | ✓ | ✓ | ✓ |
| Resources | ✓ | ✓ | ✓ | ✓ | ✓ |
| Affinity | ✓ | ✓ | ✓ | ✓ | ✓ |
| Tolerations | ✓ | ✓ | ✓ | ✓ | ✓ |
| NodeSelector | ✓ | ✓ | ✓ | ✓ | ✓ |

### 1.2 Current Dependency Structure

```
ZeroTrustWorkloadIdentityManager (ZTWIM) - Singleton: "cluster"
│
├── Status Aggregator (reads-only)
│   ├── SpireServer "cluster" 
│   ├── SpireAgent "cluster"
│   ├── SpiffeCSIDriver "cluster"
│   └── SpireOIDCDiscoveryProvider "cluster"
│
└── Currently: No ownership relationship
```

**Current Issues:**
- **Duplication Risk:** Inconsistencies when updating TrustDomain across all operands
- **No Enforcement:** Nothing prevents conflicting values in operand CRs
- **Manual Synchronization:** Operators must manually keep values in sync
- **Migration Risk:** No dependency tracking when adding/removing operands

### 1.3 Current Deployment Topology

```
Namespace: zero-trust-workload-identity-manager

Resources Created:
├── ServiceAccounts
├── ClusterRoles & ClusterRoleBindings
├── ConfigMaps (including spire-bundle)
├── Deployments
│   ├── spire-server (singleton)
│   ├── spire-agent (DaemonSet)
│   ├── spire-oidc-discovery-provider
│   └── spiffe-csi-driver
├── Services
├── Routes (OpenShift)
└── PersistentVolumeClaims
```

---

## 2. PROPOSED ARCHITECTURE

### 2.1 New Configuration Hierarchy

```
ZeroTrustWorkloadIdentityManager (ZTWIM) - Singleton: "cluster"
│
├── Spec.CommonConfig (existing - for all resources)
│
├── NEW: Spec.TrustDomain (global)
├── NEW: Spec.ClusterName (global)
├── NEW: Spec.BundleConfig (global)
│
└── Status:
    └── Operands[] (aggregated status)
        ├── SpireServer "cluster"
        ├── SpireAgent "cluster"
        ├── SpiffeCSIDriver "cluster"
        └── SpireOIDCDiscoveryProvider "cluster"
```

### 2.2 Operand CR Changes

**Before:**
```go
type SpireServerSpec struct {
    TrustDomain    string     // Duplicated ❌
    ClusterName    string     // Duplicated ❌
    BundleConfigMap string    // Duplicated ❌
    // ... operand-specific configs
    CommonConfig
}
```

**After:**
```go
type SpireServerSpec struct {
    // Removed: TrustDomain, ClusterName, BundleConfigMap
    // These now come from ZTWIM parent CR
    
    // Operand-specific configs only
    LogLevel       string
    LogFormat      string
    JwtIssuer      string      // SpireServer-specific
    CAValidity     Duration
    Datastore      *DataStore
    // ...
    CommonConfig
}
```

### 2.3 Owner Reference & Finalizer Strategy

```
ZTWIM "cluster" (Parent)
  │
  ├── OwnerReference: ztwim "cluster"
  ├── Finalizer: "ztwim.io/operand-lifecycle"
  │
  ├─→ SpireServer "cluster" (Child)
  │   ├── OwnerReferences: [ZTWIM]
  │   ├── Finalizers: [ztwim.io/spire-server-cleanup]
  │   └── Blocked on: ZTWIM
  │
  ├─→ SpireAgent "cluster" (Child)
  │   ├── OwnerReferences: [ZTWIM]
  │   ├── Finalizers: [ztwim.io/spire-agent-cleanup]
  │   └── Blocked on: ZTWIM
  │
  ├─→ SpiffeCSIDriver "cluster" (Child)
  │   ├── OwnerReferences: [ZTWIM]
  │   ├── Finalizers: [ztwim.io/spiffe-csi-cleanup]
  │   └── Blocked on: ZTWIM
  │
  └─→ SpireOIDCDiscoveryProvider "cluster" (Child)
      ├── OwnerReferences: [ZTWIM]
      ├── Finalizers: [ztwim.io/oidc-cleanup]
      └── Blocked on: ZTWIM
```

---

## 3. DEPENDENCY MAPPING & LIFECYCLE MANAGEMENT

### 3.1 Dependency Graph

```
┌─────────────────────────────────────────────────────────────┐
│                    ZTWIM "cluster"                          │
│  Owner of: TrustDomain, ClusterName, BundleConfig, Labels  │
│  Finalizer: ztwim.io/operand-lifecycle                     │
└────────────┬────────────────────────────────────────────────┘
             │
             ├─ MUST EXIST BEFORE ──────┬──────────────────────────┐
             │                           │                          │
             ▼                           ▼                          ▼
    ┌─────────────────┐        ┌─────────────────┐      ┌─────────────────┐
    │  SpireServer    │        │   SpireAgent    │      │  SpireOIDCDisc  │
    │   "cluster"     │        │   "cluster"     │      │    "cluster"    │
    │                 │        │                 │      │                 │
    │ OwnerRef: ZTWIM │        │ OwnerRef: ZTWIM │      │ OwnerRef: ZTWIM │
    │ Finalizer:      │        │ Finalizer:      │      │ Finalizer:      │
    │ server-cleanup  │        │ agent-cleanup   │      │ oidc-cleanup    │
    └────────┬────────┘        └────────┬────────┘      └────────┬────────┘
             │                          │                         │
             ├─ CREATES ────────────────┼─────────────────────────┤
             │                          │                         │
             ▼                          ▼                         ▼
      ┌──────────────┐          ┌──────────────┐         ┌──────────────┐
      │ Deployment   │          │  DaemonSet   │         │ Deployment   │
      │ (1 replica)  │          │ (N nodes)    │         │ (replicas)   │
      └──────┬───────┘          └──────┬───────┘         └──────┬───────┘
             │                         │                        │
             ├──────────────┬──────────┤                        │
             ▼              ▼          ▼                        │
        ┌───────────────────────────────────────┐             │
        │         Bundle ConfigMap              │◄────────────┤
        │ (Created by SpireServer/Updated by    │             │
        │  Agent, read by OIDC)                 │             │
        └───────────────────────────────────────┘             │
                     △                                        │
                     │                                        │
        ┌────────────┴────────────────────────────────────────┤
        │                                                     │
        ▼                                                     ▼
    ┌──────────────┐                                   ┌──────────────┐
    │ Pod:         │                                   │ Pod:         │
    │ spire-server │                                   │ oidc-provider│
    └──────────────┘                                   └──────────────┘
```

### 3.2 Blocking & Dependencies

| Component | Blocked By | Must Block | Cleanup Order |
|-----------|-----------|-----------|----------------|
| ZTWIM | None | All operands | Last |
| SpireServer | ZTWIM exists | Bundle creation | 2nd |
| SpireAgent | ZTWIM + SpireServer | Pod deployment | 3rd |
| SpiffeCSIDriver | ZTWIM | CSI plugin | 4th |
| SpireOIDCDiscoveryProvider | ZTWIM + SpireServer | OIDC route | 5th |

### 3.3 Data Flow for Shared Configuration

```
User Updates ZTWIM.spec.trustDomain
           │
           ▼
┌─────────────────────────────────────┐
│ ZTWIM Controller Reconciles         │
│ - Detects trustDomain change        │
│ - Updates all child operands        │
└──────────┬──────────────────────────┘
           │
           ├─→ SpireServer.spec.trustDomain ← INHERITED from ZTWIM
           │   (Operand controller detects change)
           │   └─→ Regenerates config
           │       └─→ Pod restart (rolling update)
           │
           ├─→ SpireAgent.spec.trustDomain ← INHERITED from ZTWIM
           │   (Agent controller detects change)
           │   └─→ Regenerates config
           │       └─→ DaemonSet update
           │
           └─→ SpireOIDCDiscoveryProvider.spec.trustDomain ← INHERITED
               (OIDC controller detects change)
               └─→ Regenerates config
                   └─→ Deployment rollout
```

---

## 4. FINALIZER STRATEGY

### 4.1 Finalizer Placement & Responsibility

#### **Level 1: ZTWIM Finalizer**
```go
// ztwim.io/operand-lifecycle
// Responsibility: Coordinate operand cleanup
// - Wait for all operand finalizers to complete
// - Ensure no orphaned operands exist
// - Clean up shared resources (ConfigMaps, etc.)
```

#### **Level 2: Operand Finalizers**
```go
// ztwim.io/spire-server-cleanup
// Responsibility: Graceful spire-server shutdown
// - Drain in-flight requests
// - Backup datastore if needed
// - Release persistent storage
// - Remove SPIFFE bundles from ConfigMaps

// ztwim.io/spire-agent-cleanup  
// Responsibility: Graceful agent shutdown
// - Disconnect active workload API connections
// - Clean up temporary files
// - Revoke local certs

// ztwim.io/spiffe-csi-cleanup
// Responsibility: CSI cleanup
// - Unmount volumes
// - Remove sockets

// ztwim.io/oidc-cleanup
// Responsibility: OIDC provider cleanup
// - Drain request pool
// - Remove routes
```

### 4.2 Deletion Flow

**Scenario: User deletes ZTWIM "cluster" CR**

```
User: kubectl delete ztwim cluster
           │
           ▼
     Kubernetes adds deletion timestamp
     Kubernetes adds ztwim.io/operand-lifecycle finalizer
           │
           ▼
ZTWIM Controller:
  ├─ Detects deletion timestamp
  ├─ Calls PreDeleteHook()
  │  └─ Sets operands.metadata.deletionGracePeriodSeconds
  │  └─ Initiates graceful shutdown (requests cleanup operations)
  ├─ Waits for all operand finalizers to complete
  │  └─ Polls operand.metadata.finalizers for completion
  ├─ Removes shared resources
  └─ Removes ztwim.io/operand-lifecycle finalizer
           │
           ▼
Kubernetes checks operands (via OwnerReference)
           │
           ├─ SpireServer finalizer: ztwim.io/spire-server-cleanup
           │  ├─ Drains connections
           │  ├─ Backs up data
           │  └─ Removes finalizer
           │
           ├─ SpireAgent finalizer: ztwim.io/spire-agent-cleanup
           │  ├─ Disconnects workload API clients
           │  └─ Removes finalizer
           │
           ├─ SpiffeCSIDriver finalizer: ztwim.io/spiffe-csi-cleanup
           │  ├─ Unmounts CSI volumes
           │  └─ Removes finalizer
           │
           └─ SpireOIDCDiscoveryProvider finalizer: ztwim.io/oidc-cleanup
              ├─ Drains connections
              └─ Removes finalizer
           │
           ▼
Kubernetes garbage collects all operands
(via OwnerReference cascade delete)
           │
           ▼
ZTWIM CR is fully deleted
```

### 4.3 Failure Handling

**If operand cleanup times out:**

```go
// Implementation pattern:
PreDeleteHook():
  ├─ Set operand.metadata.deletionGracePeriodSeconds = 30s
  ├─ After 25s:
  │  └─ If finalizer still present:
  │     ├─ Log warning: "Operand finalizer timeout"
  │     ├─ Force remove finalizer (DANGEROUS - only as last resort)
  │     └─ Update ZTWIM status with warning
  └─ Continue deletion

ReconciliationLoop():
  ├─ If ZTWIM.metadata.deletionTimestamp exists
  │  ├─ But finalizer not in list:
  │  │  └─ This is an orphan state (shouldn't happen)
  │  └─ Cleanup and remove ZTWIM finalizer
```

---

## 5. OWNER REFERENCE STRATEGY

### 5.1 Owner Reference Structure

```go
// ZTWIM sets OwnerReference on all operand CRs
type OwnerReference struct {
    APIVersion: "operator.openshift.io/v1alpha1"
    Kind: "ZeroTrustWorkloadIdentityManager"
    Name: "cluster"
    UID: <ZTWIM-UID>
    Controller: true           // ZTWIM is the controller
    BlockOwnerDeletion: true   // Operand deletion blocks ZTWIM deletion
}
```

### 5.2 Cascade Deletion Behavior

```
When ZTWIM is deleted:

1. ZTWIM marked with deletion timestamp
2. Kubernetes checks OwnerReferences on operands
3. BlockOwnerDeletion: true means:
   - Operands are NOT automatically deleted
   - ZTWIM deletion is blocked until finalizers complete
4. Operand finalizers execute cleanup
5. Once finalizers removed, operands are deleted
6. ZTWIM finalizer can then be removed
```

**Result:** Safe, controlled deletion with cleanup operations executed.

---

## 6. VALIDATION & CONFLICT RESOLUTION

### 6.1 Validation Rules

#### **In Operand CRs (New Validation):**

```yaml
# SpireServer, SpireAgent, SpireOIDCDiscoveryProvider
apiVersion: operator.openshift.io/v1alpha1
kind: SpireServer
metadata:
  name: cluster
spec:
  # These fields are now DEPRECATED (but kept for compatibility)
  # They are inherited from ZTWIM and will be validated/overridden
  
  # NEW validation rule:
  # If both ZTWIM and operand have values, they MUST match
  # If only operand has value, use it (for backward compatibility)
  # If only ZTWIM has value, use it (preferred)
  trustDomain: "example.io"  # DEPRECATED: use ZTWIM.spec.trustDomain
  clusterName: "my-cluster"   # DEPRECATED: use ZTWIM.spec.clusterName
  bundleConfigMap: "spire-bundle"  # DEPRECATED: use ZTWIM.spec.bundleConfig
```

#### **In ZTWIM CR (Validation):**

```yaml
apiVersion: operator.openshift.io/v1alpha1
kind: ZeroTrustWorkloadIdentityManager
metadata:
  name: cluster
spec:
  trustDomain: "example.io"
    # Must be a valid DNS domain name
    # Pattern: ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)*$
    
  clusterName: "my-cluster"
    # Must be alphanumeric + hyphens
    # Pattern: ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$
    
  bundleConfig:
    name: "spire-bundle"
    namespace: "zero-trust-workload-identity-manager"
    # Must be a valid ConfigMap name
```

### 6.2 Conflict Resolution Logic

**Priority when resolving configuration:**

```
1. Check ZTWIM for trustDomain/clusterName
2. If ZTWIM has value:
   a. Use it as source of truth
   b. Validate operand doesn't have conflicting value
      - If conflict: raise webhook error, reject change
      - If empty: populate operand (for UI/status clarity)
      - If match: allow
3. If ZTWIM doesn't have value:
   a. Check if any operand has value
      - If yes: use first operand's value (migration mode)
      - Log warning: "Consider moving to ZTWIM"
   b. If none have value:
      - Raise error: "TrustDomain required in ZTWIM"
```

### 6.3 Validation Webhook Rules

```go
// MutatingWebhook: ztwim-validator
// Rules to enforce:

1. ZTWIM Creation:
   ├─ trustDomain must be set
   ├─ clusterName must be set (for SpireServer/Agent)
   └─ bundleConfig.name must be valid

2. ZTWIM Update:
   ├─ If trustDomain changes:
   │  ├─ All existing operands must be updated
   │  └─ Validate no operands have conflicting values
   ├─ If clusterName changes:
   │  ├─ Same validation as trustDomain
   │  └─ Update all operands
   └─ If bundleConfig changes:
      └─ Validate ConfigMap path exists

3. Operand Creation (SpireServer, SpireAgent, etc.):
   ├─ If trustDomain not in ZTWIM yet:
   │  ├─ COPY it from operand to ZTWIM (if not present)
   │  └─ Log: "Initializing ZTWIM from operand config"
   ├─ If trustDomain in ZTWIM:
   │  ├─ If operand.trustDomain is set:
   │  │  └─ Must match ZTWIM.spec.trustDomain (REJECT if not)
   │  └─ If operand.trustDomain is empty:
   │     └─ Auto-populate with ZTWIM value
   └─ Set OwnerReference to ZTWIM "cluster"

4. Operand Update (SpireServer, SpireAgent, etc.):
   ├─ If trustDomain changes:
   │  ├─ Must match ZTWIM.spec.trustDomain (REJECT if not)
   │  └─ Trigger ZTWIM reconciliation
   └─ Must maintain OwnerReference
```

---

## 7. IMPLEMENTATION PHASES

### Phase 1: API Changes (Weeks 1-2)

**Goal:** Update CRD schemas to support new fields

**Tasks:**
- [ ] Add `TrustDomain`, `ClusterName`, `BundleConfig` to `ZeroTrustWorkloadIdentityManagerSpec`
- [ ] Mark as deprecated (but keep): `TrustDomain`, `ClusterName`, `BundleConfigMap` in operand specs
- [ ] Add kubebuilder validation rules for new fields
- [ ] Update deepcopy generators
- [ ] Generate new CRDs

**Deliverables:**
- Updated API types in `api/v1alpha1/`
- Updated CRD YAML in `config/crd/bases/`
- Deprecation notices in code comments

### Phase 2: Validation & Webhooks (Weeks 2-3)

**Goal:** Implement conflict detection and auto-correction

**Tasks:**
- [ ] Create validating webhook for ZTWIM
- [ ] Create validating webhook for operands
- [ ] Implement conflict resolution logic
- [ ] Add tests for webhook rules
- [ ] Document webhook behavior

**Deliverables:**
- `pkg/webhooks/ztwim_validator.go`
- `pkg/webhooks/operand_validator.go`
- Webhook configuration in `config/`
- Comprehensive webhook tests

### Phase 3: Owner References & Finalizers (Weeks 3-4)

**Goal:** Establish parent-child relationships and graceful shutdown

**Tasks:**
- [ ] Implement ZTWIM controller to set OwnerReferences on operands
- [ ] Add ZTWIM finalizer: `ztwim.io/operand-lifecycle`
- [ ] Add operand finalizers: 
  - `ztwim.io/spire-server-cleanup`
  - `ztwim.io/spire-agent-cleanup`
  - `ztwim.io/spiffe-csi-cleanup`
  - `ztwim.io/oidc-cleanup`
- [ ] Implement PreDeleteHook in ZTWIM controller
- [ ] Implement cleanup logic in each operand controller
- [ ] Test deletion scenarios

**Deliverables:**
- Updated controller code with finalizer logic
- PreDeleteHook implementation
- Cleanup operation handlers
- Deletion scenario tests

### Phase 4: Config Injection (Weeks 4-5)

**Goal:** Operand controllers read from ZTWIM instead of their own fields

**Tasks:**
- [ ] Update SpireServer controller to read trustDomain from ZTWIM if not in CR
- [ ] Update SpireAgent controller similarly
- [ ] Update SpireOIDCDiscoveryProvider controller similarly
- [ ] Update ConfigMap/secret generation to use values from ZTWIM
- [ ] Implement change detection for ZTWIM config updates
- [ ] Add reconciliation triggers when ZTWIM config changes

**Deliverables:**
- Updated operand controllers
- Config merge/override logic
- Change detection tests

### Phase 5: Migration & Backward Compatibility (Weeks 5-6)

**Goal:** Support existing installations without manual intervention

**Tasks:**
- [ ] Create migration logic to populate ZTWIM from existing operands
- [ ] Add migration controller that runs on upgrade
- [ ] Implement dry-run detection for migration
- [ ] Create backup mechanism before migration
- [ ] Add rollback capability
- [ ] Document migration process

**Deliverables:**
- Migration controller: `pkg/migration/config_migration.go`
- Migration tests
- Upgrade documentation
- Rollback procedures

### Phase 6: Testing & Documentation (Weeks 6-7)

**Goal:** Comprehensive testing and clear documentation

**Tasks:**
- [ ] E2E tests for common scenarios
- [ ] E2E tests for deletion scenarios
- [ ] E2E tests for config updates
- [ ] E2E tests for conflict detection
- [ ] Documentation updates
- [ ] Design decision records

**Deliverables:**
- E2E test suite in `test/e2e/`
- Updated README and OWNERS docs
- ADR (Architecture Decision Record) documents

### Phase 7: Release & Monitoring (Week 7-8)

**Goal:** Safe production rollout

**Tasks:**
- [ ] Create release notes
- [ ] Add observability/metrics for finalizers
- [ ] Create alerts for cleanup timeouts
- [ ] Run smoke tests
- [ ] Document known limitations
- [ ] Create incident response runbook

**Deliverables:**
- Release notes
- Monitoring configuration
- Incident response guide

---

## 8. DETAILED DEPENDENCY MAP

### 8.1 Blocking Relationships (What prevents deletion)

```
ZTWIM Deletion Process:
├─ Step 1: User requests ZTWIM deletion
│  └─ ZTWIM gets deletion timestamp
│
├─ Step 2: Check BlockOwnerDeletion on operands
│  ├─ SpireServer.metadata.ownerReferences[0].blockOwnerDeletion = true
│  ├─ SpireAgent.metadata.ownerReferences[0].blockOwnerDeletion = true
│  ├─ SpiffeCSIDriver.metadata.ownerReferences[0].blockOwnerDeletion = true
│  └─ SpireOIDCDiscoveryProvider.metadata.ownerReferences[0].blockOwnerDeletion = true
│
├─ Step 3: Kubernetes blocks ZTWIM deletion (wait for operands cleanup)
│
├─ Step 4: Operand controllers execute cleanup
│  ├─ SpireServer removes: ztwim.io/spire-server-cleanup
│  ├─ SpireAgent removes: ztwim.io/spire-agent-cleanup  
│  ├─ SpiffeCSIDriver removes: ztwim.io/spiffe-csi-cleanup
│  └─ SpireOIDCDiscoveryProvider removes: ztwim.io/oidc-cleanup
│
├─ Step 5: Once all operands have no finalizers
│  └─ Kubernetes deletes operands (cascade delete)
│
└─ Step 6: ZTWIM controller removes finalizer
   └─ ZTWIM is deleted
```

### 8.2 Runtime Blocking (Pod/Deployment Dependencies)

```
Pod Startup Conditions:

SpireServer Pod:
├─ Requires: spire-bundle ConfigMap exists
├─ Creates: Certificates in bundle
└─ Blocks: SpireAgent from connecting (until certs available)

SpireAgent DaemonSet:
├─ Requires: SpireServer Pod running and responding on service
├─ Requires: spire-bundle ConfigMap available
├─ Creates: Workload API socket at /run/spire/agent-sockets/spire-agent.sock
└─ Blocks: SpiffeCSIDriver, SpireOIDCDiscoveryProvider from starting

SpiffeCSIDriver DaemonSet:
├─ Requires: SpireAgent socket available
├─ Requires: Node has kubelet running
└─ Blocks: Workloads from using SPIFFE identities

SpireOIDCDiscoveryProvider Deployment:
├─ Requires: SpireAgent for SVID fetching
├─ Requires: jwtIssuer URL configured
└─ Blocks: Nothing (non-critical component)
```

### 8.3 Cascading Updates

```
User changes ZTWIM.spec.trustDomain: "example.io" → "newdomain.io"

Cascade:
1. ZTWIM Controller detects change
   └─ Updates all child operands with new trustDomain

2. SpireServer detects change
   ├─ Regenerates config with new trustDomain
   ├─ Creates new CA for new trustDomain
   ├─ Pod restarts (rolling update)
   └─ Updates bundle ConfigMap

3. SpireAgent detects change
   ├─ Waits for new bundle from SpireServer
   ├─ Regenerates config
   ├─ DaemonSet rolls out on all nodes
   └─ Workload API socket reset

4. SpireOIDCDiscoveryProvider detects change
   ├─ Regenerates config
   ├─ Deployment rolls out
   └─ Updates discovery endpoints

5. SpiffeCSIDriver detects change
   ├─ Regenerates config
   ├─ DaemonSet rolls out on all nodes
   └─ Workloads now use new trustDomain identities
```

---

## 9. DATA FLOW DIAGRAMS

### 9.1 ZTWIM → Operand Config Flow

```
┌──────────────────────────────────┐
│ ZTWIM "cluster"                  │
│ spec:                            │
│   trustDomain: "example.io"      │
│   clusterName: "prod-us-west"    │
│   bundleConfig:                  │
│     name: "spire-bundle"         │
└────────┬─────────────────────────┘
         │
         │ ZTWIM Controller watches for changes
         │ and updates operands
         │
         ├─→ SpireServer "cluster" ────────┐
         │   spec.trustDomain ← value      │
         │   spec.clusterName ← value      │ Config sources
         │   spec.bundleConfigMap ← value  │ (merged/inherited)
         │                                 │
         ├─→ SpireAgent "cluster"          │
         │   spec.trustDomain ← value      │
         │   spec.clusterName ← value      │
         │   spec.bundleConfigMap ← value  │
         │                                 │
         ├─→ SpireOIDCProvider "cluster"   │
         │   spec.trustDomain ← value      │
         │   spec.jwtIssuer ← value        │
         │                                 │
         └─→ SpiffeCSIDriver "cluster"     │
             (no changes needed)           │
             OwnerRef maintains chain      │
             └─────────────────────────────┘
```

### 9.2 Status Aggregation Flow

```
Operand Controllers:
├─ SpireServer Controller
│  └─ Updates SpireServer.status.conditions
│
├─ SpireAgent Controller
│  └─ Updates SpireAgent.status.conditions
│
├─ SpiffeCSIDriver Controller
│  └─ Updates SpiffeCSIDriver.status.conditions
│
└─ SpireOIDCProvider Controller
   └─ Updates SpireOIDCProvider.status.conditions

                         ↓

ZTWIM Controller watches operands:
├─ Detects status changes (via operandStatusChangedPredicate)
├─ Queries all operand CRs
├─ Aggregates conditions into OperandStatus array
└─ Updates ZTWIM.status.operands[]

Result in ZTWIM.status:
├─ operands[0]: SpireServer "cluster" status
├─ operands[1]: SpireAgent "cluster" status
├─ operands[2]: SpiffeCSIDriver "cluster" status
└─ operands[3]: SpireOIDCProvider "cluster" status

User views: kubectl get ztwim cluster -o yaml
Shows comprehensive health of all operands
```

---

## 10. IMPLEMENTATION CHECKLIST

### API & CRD Changes
- [ ] Add fields to `ZeroTrustWorkloadIdentityManagerSpec`
  - [ ] `TrustDomain string`
  - [ ] `ClusterName string`
  - [ ] `BundleConfig BundleConfigReference`
- [ ] Mark operand CR fields as deprecated
- [ ] Update `zz_generated.deepcopy.go`
- [ ] Generate new CRD YAML
- [ ] Add validation rules to CRDs

### Webhook Implementation
- [ ] Create validating webhook for ZTWIM
- [ ] Create validating webhook for operands
- [ ] Implement conflict resolution logic
- [ ] Register webhooks with manager
- [ ] Add webhook configuration to config/

### Controller Enhancements
- [ ] Update ZTWIM controller:
  - [ ] Add method to set OwnerReferences on operands
  - [ ] Add PreDeleteHook for graceful shutdown
  - [ ] Add config injection logic
  - [ ] Add finalizer: `ztwim.io/operand-lifecycle`
- [ ] Update SpireServer controller:
  - [ ] Add finalizer: `ztwim.io/spire-server-cleanup`
  - [ ] Implement cleanup handler
  - [ ] Add config inheritance from ZTWIM
- [ ] Update SpireAgent controller:
  - [ ] Add finalizer: `ztwim.io/spire-agent-cleanup`
  - [ ] Implement cleanup handler
  - [ ] Add config inheritance from ZTWIM
- [ ] Update SpiffeCSIDriver controller:
  - [ ] Add finalizer: `ztwim.io/spiffe-csi-cleanup`
  - [ ] Implement cleanup handler
- [ ] Update SpireOIDC controller:
  - [ ] Add finalizer: `ztwim.io/oidc-cleanup`
  - [ ] Implement cleanup handler
  - [ ] Add config inheritance from ZTWIM

### Testing
- [ ] Unit tests for conflict resolution
- [ ] Unit tests for finalizer logic
- [ ] E2E tests for config inheritance
- [ ] E2E tests for ZTWIM deletion flow
- [ ] E2E tests for operand cleanup
- [ ] E2E tests for config updates cascading
- [ ] Migration tests

### Documentation
- [ ] Update README with new config structure
- [ ] Create migration guide
- [ ] Create architecture decision record (ADR)
- [ ] Document webhook rules
- [ ] Document finalizer behavior
- [ ] Add examples in `config/samples/`

---

## 11. RISK ANALYSIS & MITIGATION

### Risk 1: Config Conflicts During Migration
**Risk:** Existing operands have different values for trustDomain

**Mitigation:**
- Pre-migration validation checks for conflicts
- Migration in dry-run mode first
- Backup existing CRs
- Rollback capability (revert to individual CR values)

### Risk 2: Finalizer Deadlock
**Risk:** Finalizer cleanup hangs, blocking all deletions

**Mitigation:**
- Implement timeout logic (30s default)
- Force-remove finalizer as last resort (with warning)
- Add metrics to monitor finalizer duration
- Create runbook for manual intervention

### Risk 3: Operand Pod Starvation
**Risk:** Operand pods not starting due to missing ZTWIM values

**Mitigation:**
- Validate ZTWIM exists before creating operands
- Add admission webhook to reject operand creation if ZTWIM missing
- Clear error messages in pod events

### Risk 4: Backward Compatibility
**Risk:** Old operands created without OwnerReferences won't be tracked

**Mitigation:**
- Migration controller adds OwnerReferences to existing operands
- Validation webhook ensures new operands have OwnerReferences
- Support both modes during transition period

### Risk 5: Config Update Storm
**Risk:** Many operand pod restarts if config changes frequently

**Mitigation:**
- Batch config changes in ZTWIM
- Implement pod disruption budget (PDB)
- Use rolling update strategy
- Monitor pod restart rates

---

## 12. SUCCESS METRICS

### Qualitative Metrics
- ✅ Configuration is defined once (ZTWIM) instead of 4 times (operands)
- ✅ Conflicts are prevented by validation webhooks
- ✅ Deletion is safe and graceful with finalizers
- ✅ Existing deployments upgrade without manual intervention
- ✅ No breaking changes to operand API (only deprecation)

### Quantitative Metrics
- ✅ 100% of operand CRs have OwnerReference to ZTWIM
- ✅ Configuration sync time < 5s (from ZTWIM change to operand update)
- ✅ ZTWIM deletion time: < 2 minutes (includes graceful cleanup)
- ✅ Finalizer cleanup time: < 30s per operand
- ✅ Zero orphaned operands after ZTWIM deletion

---

## 13. APPENDIX: CODE EXAMPLES

### Example 1: ZTWIM with Centralized Config

```yaml
apiVersion: operator.openshift.io/v1alpha1
kind: ZeroTrustWorkloadIdentityManager
metadata:
  name: cluster
spec:
  namespace: zero-trust-workload-identity-manager
  
  # NEW: Centralized configuration
  trustDomain: "example.io"
  clusterName: "prod-us-west"
  bundleConfig:
    name: "spire-bundle"
    namespace: "zero-trust-workload-identity-manager"
  
  # Existing: Common pod configs
  resources:
    requests:
      cpu: 100m
      memory: 128Mi
  
  labels:
    app: spire
    managed-by: ztwim

status:
  conditions:
    - type: Ready
      status: "True"
  operands:
    - name: cluster
      kind: SpireServer
      ready: "true"
    - name: cluster
      kind: SpireAgent
      ready: "true"
    - name: cluster
      kind: SpiffeCSIDriver
      ready: "true"
    - name: cluster
      kind: SpireOIDCDiscoveryProvider
      ready: "true"
```

### Example 2: Operand with Inherited Config

```yaml
apiVersion: operator.openshift.io/v1alpha1
kind: SpireServer
metadata:
  name: cluster
  ownerReferences:
    - apiVersion: operator.openshift.io/v1alpha1
      kind: ZeroTrustWorkloadIdentityManager
      name: cluster
      uid: <ZTWIM-UID>
      controller: true
      blockOwnerDeletion: true
  finalizers:
    - ztwim.io/spire-server-cleanup

spec:
  # DEPRECATED (kept for compatibility, overridden by ZTWIM):
  # trustDomain: "example.io"  # ← From ZTWIM.spec.trustDomain
  # clusterName: "prod-us-west"  # ← From ZTWIM.spec.clusterName
  # bundleConfigMap: "spire-bundle"  # ← From ZTWIM.spec.bundleConfig.name
  
  # Operand-specific configs only:
  logLevel: debug
  jwtIssuer: https://oidc-provider.example.io
  datastore:
    databaseType: sqlite3
  
  # Inherited from ZTWIM:
  resources:
    requests:
      cpu: 100m
```

### Example 3: Deletion Flow Code

```go
// In ZTWIM Controller
func (r *ZeroTrustWorkloadIdentityManagerReconciler) PreDeleteHook(
    ctx context.Context,
    ztwim *v1alpha1.ZeroTrustWorkloadIdentityManager,
) error {
    r.log.Info("Executing pre-delete hook", "name", ztwim.Name)
    
    // Set graceful termination period for operands
    operands := []runtime.Object{
        &v1alpha1.SpireServer{},
        &v1alpha1.SpireAgent{},
        &v1alpha1.SpiffeCSIDriver{},
        &v1alpha1.SpireOIDCDiscoveryProvider{},
    }
    
    for _, obj := range operands {
        if err := r.setDeletionGracePeriod(ctx, obj, 30*time.Second); err != nil {
            r.log.Error(err, "failed to set deletion grace period")
        }
    }
    
    // Wait for operand cleanup (with timeout)
    ctx, cancel := context.WithTimeout(ctx, 2*time.Minute)
    defer cancel()
    
    if err := r.waitForOperandCleanup(ctx, ztwim); err != nil {
        r.log.Error(err, "operand cleanup timeout")
        // Note: We continue anyway, allowing Kubernetes to proceed
    }
    
    return nil
}

// Operand controller cleanup
func (r *SpireServerReconciler) handleDeletion(
    ctx context.Context,
    server *v1alpha1.SpireServer,
) error {
    if !controllerutil.ContainsFinalizer(server, SpireServerFinalizerName) {
        return nil
    }
    
    // Execute cleanup operations
    r.log.Info("Cleaning up spire-server", "name", server.Name)
    
    if err := r.gracefulShutdown(ctx, server); err != nil {
        r.log.Error(err, "graceful shutdown failed")
        return err
    }
    
    if err := r.backupDatastore(ctx, server); err != nil {
        r.log.Error(err, "datastore backup failed")
        return err
    }
    
    // Remove finalizer to allow deletion
    controllerutil.RemoveFinalizer(server, SpireServerFinalizerName)
    if err := r.Update(ctx, server); err != nil {
        return fmt.Errorf("failed to remove finalizer: %w", err)
    }
    
    return nil
}
```

---

## 14. REFERENCES & RELATED DOCS

- [Kubernetes Finalizers](https://kubernetes.io/docs/concepts/overview/working-with-objects/finalizers/)
- [Kubernetes Owner References](https://kubernetes.io/docs/concepts/overview/working-with-objects/owners-dependents/)
- [Controller-runtime Finalizers](https://pkg.go.dev/sigs.k8s.io/controller-runtime/pkg/controller/controllerutil)
- [Kubebuilder Validation Rules](https://book.kubebuilder.io/reference/markers/crd-validation.html)
- [SPIRE Architecture](https://spiffe.io/docs/latest/spire-about/spire-concepts/)

---

**Document Version:** 1.0
**Created:** [Current Date]
**Last Updated:** [Current Date]
**Status:** Ready for Implementation

