# Quick Reference Card

**Keep this handy during implementation and troubleshooting**

---

## 🎯 Core Concept

```
ONE ZTWIM CR = Single source of truth for:
  • trustDomain
  • clusterName  
  • bundleConfig
  • (all owned by parent)

FOUR Operand CRs = Children inherit config from ZTWIM
  • SpireServer "cluster"
  • SpireAgent "cluster"
  • SpiffeCSIDriver "cluster"
  • SpireOIDCDiscoveryProvider "cluster"
```

---

## 🔐 Finalizers Cheat Sheet

```
┌─────────────────────────────────────────┐
│         FINALIZER NAMES & ORDER         │
├─────────────────────────────────────────┤
│ Parent Level:                           │
│  ztwim.io/operand-lifecycle             │
│                                         │
│ Child Level (execute in parallel):      │
│  ztwim.io/spire-server-cleanup          │
│  ztwim.io/spire-agent-cleanup           │
│  ztwim.io/spiffe-csi-cleanup            │
│  ztwim.io/oidc-cleanup                  │
│                                         │
│ Timeout: 30s each, 2 min total          │
└─────────────────────────────────────────┘
```

**When to add finalizers:**
```go
// In Reconcile():
if !controllerutil.ContainsFinalizer(obj, finalizerName) {
    controllerutil.AddFinalizer(obj, finalizerName)
    r.Update(ctx, obj)
    return ctrl.Result{Requeue: true}, nil
}

// In deletion handling:
if !obj.ObjectMeta.DeletionTimestamp.IsZero() {
    // Do cleanup...
    controllerutil.RemoveFinalizer(obj, finalizerName)
    r.Update(ctx, obj)
}
```

---

## 👨‍👩‍👧‍👦 Owner References Cheat Sheet

```go
// Set OwnerReference structure
ownerRef := metav1.OwnerReference{
    APIVersion:         v1alpha1.GroupVersion.String(),
    Kind:               "ZeroTrustWorkloadIdentityManager",
    Name:               ztwim.Name,
    UID:                ztwim.UID,
    Controller:         boolPtr(true),      // ← Important
    BlockOwnerDeletion: boolPtr(true),      // ← CRITICAL
}

// Add to operand
operand.SetOwnerReferences([]metav1.OwnerReference{ownerRef})
r.Update(ctx, operand)
```

**Effect:**
- ✅ Kubernetes knows ZTWIM owns operand
- ✅ Cascade delete removes operand when ZTWIM deleted
- ✅ ZTWIM deletion blocked while operand exists (BlockOwnerDeletion)

---

## ⚠️ Deletion Sequence (5 Steps)

```
1. kubectl delete ztwim cluster
           ↓
2. ZTWIM gets deletionTimestamp + finalizer added
           ↓
3. ZTWIM Controller runs PreDeleteHook
   └─ Sets grace period on operands (30s each)
   └─ Waits for operand cleanup (2 min timeout)
           ↓
4. Operand Controllers run cleanup handlers
   └─ Remove finalizers (triggers deletion)
   └─ All operands can now be deleted
           ↓
5. Kubernetes cascade-deletes operands
   └─ Once all operands gone
   └─ ZTWIM Controller removes finalizer
   └─ ZTWIM CR is deleted
           ↓
   ✅ Complete
```

---

## 🛑 Blocking Relationships

```
What blocks what?

ZTWIM deletion  ← BLOCKED BY ← Operand finalizers still present
                ← BLOCKED BY ← Any child OwnerReference exists

Operand deletion ← NOT blocked (finalizer removes self)

Pod creation ← NOT directly blocked
              (but waits for dependencies via spec)
```

---

## 🚫 Conflict Detection Logic

```
User sets SpireServer.spec.trustDomain = "new.io"
ZTWIM.spec.trustDomain = "old.io"

Webhook check:
    if spireServer.trustDomain != "" &&
       spireServer.trustDomain != ztwim.trustDomain {
        return ERROR("Conflict detected")
    }

Result: ❌ UPDATE REJECTED
Message: "operand trustDomain conflicts with ZTWIM parent"
```

**Priority Rules:**
1. ✅ ZTWIM value = source of truth
2. ✅ Operand empty = auto-populate from ZTWIM
3. ✅ Both same = allowed
4. ❌ Values differ = REJECT

---

## 📋 Deletion Troubleshooting

```
Symptom: kubectl delete ztwim stuck in "Terminating"

Diagnosis:
  kubectl describe ztwim cluster
  └─ Check: finalizers present?
  └─ Check: OwnerReferences present?
  
  kubectl get pod -A | grep spire
  └─ Are operand pods still running?
  
  kubectl get spireserver cluster
  └─ Check: finalizers present?

Common causes & fixes:

1. Operand cleanup hanging
   └─ Check operand pod logs
   └─ Force remove finalizer (last resort):
      kubectl patch spireserver cluster --type merge \
        -p '{"metadata":{"finalizers":[]}}'

2. ZTWIM finalizer won't remove
   └─ Check operands are deleted first
   └─ Then force remove:
      kubectl patch ztwim cluster --type merge \
        -p '{"metadata":{"finalizers":[]}}'

3. Timeout exceeded
   └─ PreDeleteHook has 2-minute timeout
   └─ After timeout, deletion proceeds anyway
   └─ Check logs for "timeout" keyword
```

---

## 🔍 Config Resolution Priority

```
For each config field (trustDomain, clusterName, etc):

1. Check ZTWIM.spec.<field>
   └─ If not empty: USE THIS ✅
   
2. Check Operand.spec.<field>
   └─ If not empty: USE THIS (backward compat) ✅
   
3. Both empty
   └─ ERROR: Config required ❌

Example:
ZTWIM.trustDomain = "example.io"
SpireServer.trustDomain = ""
Result: SpireServer uses "example.io" from parent
```

---

## 📊 Status & Conditions

```
ZTWIM Status:
├─ conditions[]
│  ├─ Ready: true/false (all operands ready?)
│  └─ OperandsAvailable: true/false
└─ operands[]
   ├─ [0] SpireServer "cluster" → ready: true/false
   ├─ [1] SpireAgent "cluster" → ready: true/false  
   ├─ [2] SpiffeCSIDriver "cluster" → ready: true/false
   └─ [3] SpireOIDCProvider "cluster" → ready: true/false

Query example:
  kubectl get ztwim cluster -o jsonpath='{.status.operands[*].ready}'
  Output: true true false true
  Meaning: 1 operand not ready
```

---

## 🧪 Quick Test Commands

```bash
# Create ZTWIM with config
kubectl apply -f config/samples/ztwim-with-config.yaml

# Verify operands created with OwnerReferences
kubectl get spireserver cluster -o json | grep ownerReferences

# Verify finalizers present
kubectl get ztwim cluster -o jsonpath='{.metadata.finalizers}'

# Trigger deletion and watch cleanup
kubectl delete ztwim cluster --watch

# Check operand cleanup logs
kubectl logs -f deployment/spire-server-controller-manager

# Simulate webhook validation
kubectl apply -f - <<EOF
apiVersion: operator.openshift.io/v1alpha1
kind: SpireServer
metadata:
  name: cluster
spec:
  trustDomain: "conflicts-with-ztwim.io"  # Different from ZTWIM
EOF
# Expected: REJECTED by webhook ❌

# Check if migration ran
kubectl get configmap spire-bundle -o json | grep trustDomain
```

---

## ⏱️ Timeout Values Reference

```
Graceful termination grace period:    30 seconds (per operand)
ZTWIM deletion timeout:                2 minutes (total)
Config update propagation time:        < 5 seconds
Pod restart time:                      10-30 seconds
Status update interval:                5 seconds
Webhook timeout:                       10 seconds
```

---

## 🔄 Config Cascade Example

```
User Action:
$ kubectl patch ztwim cluster --type merge \
    -p '{"spec":{"trustDomain":"new-domain.io"}}'

Timeline:
T+0s    → ZTWIM updated with new value
T+1s    → ZTWIM Controller detects change
T+2s    → SpireServer CR updated
T+3s    → SpireAgent CR updated
T+4s    → SpireOIDC CR updated
T+5s    → Operand controllers detect changes
T+6-15s → Config files regenerated
T+16s   → Pods restart with new config
T+20s   → All pods running with new trustDomain ✅

Verification:
$ kubectl exec spire-server-pod -- \
    cat /etc/spire/server/server.conf | grep trust_domain
```

---

## 🎓 Decision Tree: Should I Add a Finalizer?

```
START
  │
  ├─ Does this resource need cleanup when deleted?
  │  ├─ NO  → Don't add finalizer, end
  │  └─ YES → Continue
  │
  ├─ Is this cleanup quick (< 1 second)?
  │  ├─ YES → Don't need finalizer (let Kubernetes handle)
  │  └─ NO  → Continue
  │
  ├─ Do other resources depend on this cleanup?
  │  ├─ YES → Add finalizer
  │  │        Name: ztwim.io/{component}-cleanup
  │  │        Max timeout: 30 seconds
  │  └─ NO  → Continue
  │
  ├─ Is this the parent CR (ZTWIM)?
  │  ├─ YES → Add finalizer
  │  │        Name: ztwim.io/operand-lifecycle
  │  │        Responsibility: Wait for all children
  │  └─ NO  → Continue
  │
  └─ Don't add finalizer
     (Nothing depends on you)
```

---

## 📱 Webhook Validation Checklist

```
☐ Validate trustDomain format (DNS domain)
☐ Validate clusterName format (alphanumeric + hyphens)
☐ Check for conflicts between ZTWIM and operands
☐ Auto-populate operands when values in ZTWIM
☐ Reject incompatible values
☐ Handle bootstrap scenario (ZTWIM not yet created)
☐ Warn on config changes (via admission.Warnings)
☐ Test with invalid inputs
☐ Test with edge cases (empty strings, special chars)
```

---

## 💾 API Change Checklist

```
☐ Add fields to ZeroTrustWorkloadIdentityManagerSpec:
    - TrustDomain string
    - ClusterName string
    - BundleConfig BundleConfigReference
    
☐ Mark as deprecated in operand specs:
    - Add +kubebuilder:deprecatedversion comment
    - Keep field for backward compatibility
    - Document migration path
    
☐ Regenerate:
    - Run: go generate ./api/...
    - Run: make manifests
    
☐ Verify:
    - CRD YAML updated in config/crd/bases/
    - zz_generated.deepcopy.go updated
    - No conflicts in generated code
```

---

## 🧠 Remember

```
Owner References = HOW operands are owned
Finalizers = WHEN cleanup happens
Webhooks = HOW conflicts are prevented
Config Inheritance = WHERE values come from
BlockOwnerDeletion = WHY deletion blocks

All five work together to make it work!
```

---

## 📞 Quick Help

| Issue | Solution |
|-------|----------|
| Operand not inheriting config | Check ConfigResolver uses ZTWIM value |
| Webhook not firing | Verify webhook registered in manager |
| Deletion stuck | Check operand finalizers, use force-remove |
| Conflict not detected | Verify webhook validation rules |
| Config not updating | Check ZTWIM update triggered reconciliation |
| Operand orphaned | Check OwnerReference, cascade delete |
| Test failing | See error message, check DEPENDENCY_MAP.md |

---

**Print this page for your desk! 📌**

**Last updated:** [Current Date]  
**Valid for:** Architecture Roadmap v1.0

