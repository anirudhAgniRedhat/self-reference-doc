# Dependency Map: Config Centralization & Lifecycle Management

## Quick Reference: Finalizer Placement

```
┌─────────────────────────────────────────────────────────────────────────┐
│                       FINALIZER RESPONSIBILITY MATRIX                   │
└─────────────────────────────────────────────────────────────────────────┘

Component                    | Finalizer Name                | Cleanup Responsibility
─────────────────────────────┼───────────────────────────────┼──────────────────────────────────────
ZTWIM "cluster"              | ztwim.io/operand-lifecycle   | • Coordinate operand cleanup
                             |                               | • Wait for all children to finish
                             |                               | • Clean shared resources
─────────────────────────────┼───────────────────────────────┼──────────────────────────────────────
SpireServer "cluster"        | ztwim.io/spire-server-cleanup| • Drain in-flight connections
                             |                               | • Backup datastore
                             |                               | • Release persistent storage
─────────────────────────────┼───────────────────────────────┼──────────────────────────────────────
SpireAgent "cluster"         | ztwim.io/spire-agent-cleanup | • Disconnect workload API clients
                             |                               | • Clean temp files
                             |                               | • Revoke certs
─────────────────────────────┼───────────────────────────────┼──────────────────────────────────────
SpiffeCSIDriver "cluster"    | ztwim.io/spiffe-csi-cleanup  | • Unmount CSI volumes
                             |                               | • Clean sockets
─────────────────────────────┼───────────────────────────────┼──────────────────────────────────────
SpireOIDCProvider "cluster"  | ztwim.io/oidc-cleanup        | • Drain request handlers
                             |                               | • Remove routes
```

## Quick Reference: Owner Reference Placement

```
┌──────────────────────────────────────────────────────────────────────────┐
│                     OWNER REFERENCE CONFIGURATION                        │
└──────────────────────────────────────────────────────────────────────────┘

Parent: ZeroTrustWorkloadIdentityManager "cluster" (UID: <ZTWIM-UID>)
  │
  └─ Children OwnerReferences:
     
     apiVersion: operator.openshift.io/v1alpha1
     kind: ZeroTrustWorkloadIdentityManager
     name: cluster
     uid: <ZTWIM-UID>
     controller: true              ← This is the controlling owner
     blockOwnerDeletion: true       ← ZTWIM deletion blocked until cleanup complete
```

## Deletion Sequence Diagram

```
Step 1: User Action
┌────────────────────────────────────────────────────────────┐
│ $ kubectl delete ztwim cluster                             │
└────────────────────────────────────────────────────────────┘
                          ↓

Step 2: Kubernetes Marks for Deletion
┌────────────────────────────────────────────────────────────┐
│ ZTWIM.metadata.deletionTimestamp = now                    │
│ ZTWIM.metadata.finalizers += "ztwim.io/operand-lifecycle" │
└────────────────────────────────────────────────────────────┘
                          ↓

Step 3: ZTWIM Controller Runs
┌────────────────────────────────────────────────────────────┐
│ Detects: deletionTimestamp is set                         │
│ Action: Execute PreDeleteHook()                           │
│  ├─ Set operand grace period: 30s                         │
│  └─ Wait for operand cleanup with timeout (2 minutes)     │
└────────────────────────────────────────────────────────────┘
                          ↓

Step 4: Operand Controllers Run (Parallel)
┌─────────────────────────────────────────┬─────────────────────────────────┐
│ SpireServer Cleanup                     │ SpireAgent Cleanup              │
├─────────────────────────────────────────┼─────────────────────────────────┤
│ • Drain active connections    (5s)      │ • Disconnect clients  (3s)      │
│ • Backup datastore           (10s)      │ • Clean files         (2s)      │
│ • Release PVC                (5s)       │ • Revoke certs        (2s)      │
│ Total: ≈20s                             │ Total: ≈7s                      │
│                                         │                                 │
│ Remove finalizer from CR                │ Remove finalizer from CR        │
└─────────────────────────────────────────┴─────────────────────────────────┘
       ↓                                            ↓
┌─────────────────────────────────────────┬─────────────────────────────────┐
│ SpiffeCSIDriver Cleanup                 │ SpireOIDCProvider Cleanup       │
├─────────────────────────────────────────┼─────────────────────────────────┤
│ • Unmount volumes             (5s)      │ • Drain requests      (3s)      │
│ • Clean sockets               (2s)      │ • Remove routes       (3s)      │
│ Total: ≈7s                              │ Total: ≈6s                      │
│                                         │                                 │
│ Remove finalizer from CR                │ Remove finalizer from CR        │
└─────────────────────────────────────────┴─────────────────────────────────┘
                          ↓

Step 5: Kubernetes Checks Finalizers
┌────────────────────────────────────────────────────────────┐
│ All operands finalizer lists are now empty ✓               │
│ Kubernetes cascade-deletes all operands                    │
└────────────────────────────────────────────────────────────┘
                          ↓

Step 6: ZTWIM Controller Cleans Up
┌────────────────────────────────────────────────────────────┐
│ All operands are gone                                      │
│ Remove finalizer from ZTWIM CR:                            │
│  ZTWIM.metadata.finalizers.remove("ztwim.io/operand-lifecycle")
└────────────────────────────────────────────────────────────┘
                          ↓

Step 7: Kubernetes Deletes ZTWIM
┌────────────────────────────────────────────────────────────┐
│ ZTWIM CR is fully deleted ✓                                │
│ All child resources cleaned up ✓                           │
│ No orphaned operands ✓                                     │
└────────────────────────────────────────────────────────────┘

Total Cleanup Time: ~35-45 seconds (plus grace period)
```

## Config Update Cascade Diagram

```
User modifies ZTWIM config:
┌─────────────────────────────────────────────────────────────┐
│ ZTWIM "cluster"                                             │
│ spec.trustDomain: "old.io" → "new.io"                      │
└───────────────┬─────────────────────────────────────────────┘
                │
                ▼ ZTWIM Controller detects change
        ┌───────────────────────────────────────┐
        │ Update all child operands with new   │
        │ trustDomain value                    │
        └───────────┬───────────────────────────┘
                    │
        ┌───────────┴───────────┬──────────────┬─────────────┐
        │                       │              │             │
        ▼                       ▼              ▼             ▼
    SpireServer           SpireAgent    SpiffeCSIDriver   OIDC
    Updated                Updated        Updated       Updated
        │                   │              │             │
        ├─ Detect change    ├─ Detect     ├─ Detect    ├─ Detect
        │                   │   change    │  change    │  change
        │                   │             │            │
        ▼                   ▼             ▼            ▼
    Regenerate          Regenerate   Regenerate    Regenerate
    Config              Config       Config        Config
        │                   │             │            │
        ├─ Update Pod    ├─ Roll out   ├─ Roll out  ├─ Roll out
        │   (1 replica)  │   DaemonSet │ DaemonSet  │ Deployment
        │                │   (N pods)  │ (N pods)   │ (Y replicas)
        │                │             │            │
        ▼                ▼             ▼            ▼
    Pod running      Pods running   Pods running  Pods running
    with new         with new       with new      with new
    trustDomain      trustDomain    trustDomain   trustDomain

Cascade complete → All workloads now use new trustDomain
```

## State Transitions for Operand CRs

```
Normal Operation:
┌──────────────┐
│   ACTIVE     │ ← Operand is running normally
└──────┬───────┘
       │
       │ User initiates deletion
       ▼
┌──────────────┐
│ TERMINATING  │ ← deletionTimestamp set, running cleanup
└──────┬───────┘
       │
       │ Cleanup completes, finalizer removed
       ▼
┌──────────────┐
│   DELETED    │ ← Operand CRs and Pods terminated
└──────────────┘

With Finalizers:
┌──────────────────────────────────────────────────────┐
│                                                      │
│ ZTWIM.metadata.finalizers.contains(               │
│   "ztwim.io/operand-lifecycle"                    │
│ ) = true                                            │
│                                                      │
│ SpireServer.metadata.finalizers.contains(          │
│   "ztwim.io/spire-server-cleanup"                │
│ ) = true                                            │
│                                                      │
└──────────────────────────────────────────────────────┘
                     ↓
            Blocking ZTWIM deletion
            until all finalizers
            execute and remove themselves
```

## Critical Paths & Timeouts

```
Critical Path 1: SpireServer Startup
┌────────────────┐
│  SpireServer   │  ← Starts up
│  Pod created   │ 
└────────┬───────┘
         │ (Startup time: ~5s)
         ▼
┌────────────────┐
│  SPIFFE Bundle │  ← Created, certs issued
│  ConfigMap     │
│  populated     │ 
└────────┬───────┘
         │ (Bundle ready: ~10s from pod start)
         ▼
┌────────────────┐
│ SpireAgent can │  ← Can now connect to server
│ connect        │ 
└────────────────┘
Total: ~15 seconds before agents can proceed

Critical Path 2: Graceful Shutdown
┌────────────────┐
│ Deletion signal│  ← SigTerm sent to pods
│ received       │ 
└────────┬───────┘
         │ (Grace period: 30s)
         ▼
┌────────────────┐
│ Cleanup logic  │  ← Drain connections, backup data
│ executes       │ 
└────────┬───────┘
         │ (Cleanup time: ~20-25s for server)
         ▼
┌────────────────┐
│ Process ends   │  ← Finalizer removed, pod terminated
│ cleanly        │ 
└────────────────┘
Total: <30s (within grace period)
```

## Conflict Detection Matrix

```
┌─────────────────────────────────────────────────────────────────────┐
│                     CONFLICT SCENARIOS                              │
└─────────────────────────────────────────────────────────────────────┘

Scenario: User updates ZTWIM.spec.trustDomain

┌─────────────────────────────────────┬──────────────────┐
│ Configuration State                 │ Webhook Action   │
├─────────────────────────────────────┼──────────────────┤
│ ZTWIM: "new.io"                     │                  │
│ SpireServer: "new.io"               │ ✓ ALLOW          │
│ (values match)                      │                  │
├─────────────────────────────────────┼──────────────────┤
│ ZTWIM: "new.io"                     │                  │
│ SpireServer: "old.io"               │ ✗ REJECT         │
│ (conflict detected)                 │ Message: Config  │
│                                     │ conflict with    │
│                                     │ ZTWIM parent     │
├─────────────────────────────────────┼──────────────────┤
│ ZTWIM: "new.io"                     │                  │
│ SpireServer: (empty)                │ ✓ AUTO-POPULATE  │
│ (operand inherits from parent)      │ SpireServer.spec │
│                                     │ .trustDomain ←   │
│                                     │ "new.io"         │
└─────────────────────────────────────┴──────────────────┘

During ZTWIM creation (bootstrap scenario):

┌─────────────────────────────────────┬──────────────────┐
│ Configuration State                 │ Webhook Action   │
├─────────────────────────────────────┼──────────────────┤
│ ZTWIM: (empty)                      │                  │
│ SpireServer: "existing.io"          │ ✓ INIT ZTWIM     │
│ (pre-existing operand)              │ Copy trustDomain │
│                                     │ from operand to  │
│                                     │ ZTWIM (one-time) │
├─────────────────────────────────────┼──────────────────┤
│ ZTWIM: (empty)                      │                  │
│ SpireServer: (empty)                │ ✗ REJECT         │
│ (no config anywhere)                │ Message: Must    │
│                                     │ specify trust    │
│                                     │ domain           │
└─────────────────────────────────────┴──────────────────┘
```

## Controller Reconciliation Triggers

```
ZTWIM Controller Reconciliation Triggers:
┌─────────────────────────────────────────────────────────┐
│ 1. ZTWIM CR created/updated                             │
│    └─ Full reconciliation, update operands             │
│                                                         │
│ 2. ZTWIM CR deleted                                     │
│    └─ Run PreDeleteHook, wait for operand cleanup      │
│                                                         │
│ 3. SpireServer status changes                           │
│    └─ Aggregate operand status into ZTWIM              │
│                                                         │
│ 4. SpireAgent status changes                            │
│    └─ Aggregate operand status into ZTWIM              │
│                                                         │
│ 5. SpiffeCSIDriver status changes                       │
│    └─ Aggregate operand status into ZTWIM              │
│                                                         │
│ 6. SpireOIDCDiscoveryProvider status changes            │
│    └─ Aggregate operand status into ZTWIM              │
│                                                         │
│ Note: Operand reconciliation is triggered by            │
│       their own spec changes                            │
└─────────────────────────────────────────────────────────┘

Operand Controller Reconciliation Triggers:
┌─────────────────────────────────────────────────────────┐
│ SpireServer Controller:                                  │
│ • SpireServer CR spec changed                           │
│ • SpireServer Pod created/deleted                       │
│ • Bundle ConfigMap changed                              │
│                                                         │
│ SpireAgent Controller:                                   │
│ • SpireAgent CR spec changed                            │
│ • SpireAgent DaemonSet changed                          │
│ • Agent socket availability changed                     │
│                                                         │
│ SpiffeCSIDriver Controller:                              │
│ • SpiffeCSIDriver CR spec changed                       │
│ • CSI DaemonSet changed                                 │
│                                                         │
│ SpireOIDCDiscoveryProvider Controller:                   │
│ • SpireOIDCDiscoveryProvider CR spec changed            │
│ • OIDC Deployment changed                               │
│ • Route created/deleted                                 │
└─────────────────────────────────────────────────────────┘
```

## Phase Dependencies

```
Implementation Phases with Dependencies:

Phase 1: API Changes (Week 1-2)
└─ Outputs: Updated CRD schemas
   └─ Used by: Phase 2, 3, 4

Phase 2: Validation & Webhooks (Week 2-3)
└─ Depends on: Phase 1
└─ Outputs: Validating webhooks
   └─ Used by: Phase 3, 4, 5

Phase 3: Owner References & Finalizers (Week 3-4)
└─ Depends on: Phase 1, 2
└─ Outputs: Lifecycle management logic
   └─ Used by: Phase 4, 5, 6

Phase 4: Config Injection (Week 4-5)
└─ Depends on: Phase 1, 3
└─ Outputs: Config inheritance logic
   └─ Used by: Phase 5, 6

Phase 5: Migration & Backward Compatibility (Week 5-6)
└─ Depends on: Phase 1, 2, 3, 4
└─ Outputs: Migration controller
   └─ Used by: Phase 6, 7

Phase 6: Testing & Documentation (Week 6-7)
└─ Depends on: All previous phases
└─ Outputs: Test suite, docs, ADRs

Phase 7: Release & Monitoring (Week 7-8)
└─ Depends on: Phase 6
└─ Outputs: Release notes, monitoring, runbooks

Critical Path: Phase 1 → Phase 2 → Phase 3 → Phase 4 → Phase 5 → Phase 6 → Phase 7
```

## Error Scenarios & Recovery

```
Scenario 1: Operand Finalizer Timeout
┌─────────────────────────────────────────────┐
│ Operand cleanup exceeds 30s grace period    │
└─────────────┬───────────────────────────────┘
              │
              ▼
    ┌─────────────────────────┐
    │ Action: Log warning     │
    │ "Finalizer timeout"     │
    └─────────────────────────┘
              │
              ▼
    ┌─────────────────────────┐
    │ Option 1: Wait longer   │
    │ (extend timeout)        │
    │                         │
    │ Option 2: Force remove  │
    │ finalizer (risk: leak)  │
    │                         │
    │ Option 3: Operator      │
    │ manual intervention     │
    └─────────────────────────┘

Scenario 2: ZTWIM Deletion Blocked
┌─────────────────────────────────────────────┐
│ kubectl delete ztwim cluster                │
│ → Stuck in "Terminating" state              │
└─────────────┬───────────────────────────────┘
              │
              ▼
    ┌─────────────────────────────┐
    │ Check operand status:       │
    │ kubectl get operands        │
    └──────────┬──────────────────┘
               │
    ┌──────────┴────────────┬──────────────┐
    │                       │              │
    ▼                       ▼              ▼
   Has finalizers      Missing finalizer  All empty
   (normal)            (stuck)            (ready)
    │                       │              │
    ▼                       ▼              ▼
   Wait/Check          Force remove    Remove ZTWIM
   operand logs        finalizer       finalizer

Scenario 3: Config Conflict During Update
┌─────────────────────────────────────────────┐
│ User tries to update SpireServer with       │
│ trustDomain different from ZTWIM            │
└─────────────┬───────────────────────────────┘
              │
              ▼
    ┌─────────────────────────────┐
    │ Webhook blocks update       │
    │ Error: "Conflict with       │
    │ ZTWIM parent config"        │
    └──────────┬──────────────────┘
               │
               ▼
    ┌──────────────────────────┐
    │ Options:                 │
    │ 1. Update ZTWIM, not     │
    │    operand               │
    │ 2. Keep values in sync   │
    │ 3. Revert operand change │
    └──────────────────────────┘
```

## Resource Quotas & Limits

```
Expected Resource Usage:

ZTWIM CR:
├─ Size: ~1KB (spec) + ~500B (status)
└─ Storage: Negligible

SpireServer CR:
├─ Size: ~2KB
└─ Updates per day: 0 (unless user changes)

SpireAgent CR:
├─ Size: ~1KB
└─ Updates per day: 0 (unless user changes)

SpiffeCSIDriver CR:
├─ Size: ~500B
└─ Updates per day: 0 (unless user changes)

SpireOIDCDiscoveryProvider CR:
├─ Size: ~1KB
└─ Updates per day: 0 (unless user changes)

Bundle ConfigMap:
├─ Size: ~2-5KB
└─ Updates per hour: Depends on cert rotation

Recommended Resource Allocation:
├─ Finalizer timeout: 30s (per operand)
├─ ZTWIM deletion timeout: 2 minutes (total)
├─ Status update interval: 5s
└─ Reconciliation backoff: Exponential (1s → 1000s)
```

---

**Quick Decision Tree for Finalizer Placement:**

1. Is it a parent-level resource (ZTWIM)?
   - YES → `ztwim.io/operand-lifecycle`
   - NO → Go to 2

2. Is it a pod/deployment that needs graceful shutdown?
   - YES → `ztwim.io/{component}-cleanup`
   - NO → No finalizer needed

3. Must other resources wait for this one's cleanup?
   - YES → `ztwim.io/{component}-cleanup`
   - NO → No finalizer needed

