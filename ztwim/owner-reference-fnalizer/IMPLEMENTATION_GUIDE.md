# Implementation Guide: Step-by-Step Execution

This document provides concrete implementation steps for moving common configurations to the ZTWIM parent CR.

---

## Phase 1: API Definition Changes

### 1.1 Update ZTWIM Spec

**File:** `api/v1alpha1/zero_trust_workload_identity_manager_types.go`

```go
// Add these new struct definitions at the top of the file

// BundleConfigReference references the SPIFFE bundle ConfigMap
type BundleConfigReference struct {
    // name is the ConfigMap name
    // +kubebuilder:validation:Required
    // +kubebuilder:validation:MinLength=1
    Name string `json:"name"`
    
    // namespace is the ConfigMap namespace
    // +kubebuilder:validation:Required
    // +kubebuilder:validation:MinLength=1
    Namespace string `json:"namespace"`
}

// Update ZeroTrustWorkloadIdentityManagerSpec
type ZeroTrustWorkloadIdentityManagerSpec struct {
    // namespace to install the deployments and other resources managed by
    // zero-trust-workload-identity-manager.
    // +kubebuilder:validation:Optional
    // +kubebuilder:default:="zero-trust-workload-identity-manager"
    Namespace string `json:"namespace,omitempty"`

    // trustDomain is the SPIFFE trust domain for all operands.
    // This is the authoritative source of truth for the trust domain.
    // +kubebuilder:validation:Required
    // +kubebuilder:validation:MinLength=1
    // +kubebuilder:validation:MaxLength=255
    // +kubebuilder:validation:Pattern=`^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)*$`
    TrustDomain string `json:"trustDomain"`

    // clusterName is the cluster name for all operands.
    // Used for SPIRE agent registration and identification.
    // +kubebuilder:validation:Required
    // +kubebuilder:validation:MinLength=1
    // +kubebuilder:validation:MaxLength=255
    // +kubebuilder:validation:Pattern=`^[a-z0-9]([a-z0-9-]*[a-z0-9])?$`
    ClusterName string `json:"clusterName"`

    // bundleConfig is the reference to the SPIFFE bundle ConfigMap.
    // +kubebuilder:validation:Required
    BundleConfig BundleConfigReference `json:"bundleConfig"`

    CommonConfig `json:",inline"`
}
```

### 1.2 Mark Operand Fields as Deprecated

**File:** `api/v1alpha1/spire_server_config_types.go`

Replace the field definitions with deprecated versions:

```go
// SpireServerSpec - update comment and fields
type SpireServerSpec struct {
    // logLevel sets the logging level for the operand.
    // Valid values are: debug, info, warn, error.
    // +kubebuilder:validation:Optional
    // +kubebuilder:validation:Enum=debug;info;warn;error
    // +kubebuilder:default:="info"
    LogLevel string `json:"logLevel,omitempty"`

    // logFormat sets the logging format for the operand.
    // Valid values are: text, json.
    // +kubebuilder:validation:Optional
    // +kubebuilder:validation:Enum=text;json
    // +kubebuilder:default:="text"
    LogFormat string `json:"logFormat,omitempty"`

    // DEPRECATED: trustDomain is deprecated and will be removed in v1beta1.
    // Use ZeroTrustWorkloadIdentityManager.spec.trustDomain instead.
    // This value is automatically inherited from the parent ZTWIM CR.
    // If set, it must match the parent CR's value.
    // +kubebuilder:validation:Optional
    // +kubebuilder:deprecatedversion:description="Use ZeroTrustWorkloadIdentityManager.spec.trustDomain"
    TrustDomain string `json:"trustDomain,omitempty"`

    // DEPRECATED: clusterName is deprecated and will be removed in v1beta1.
    // Use ZeroTrustWorkloadIdentityManager.spec.clusterName instead.
    // This value is automatically inherited from the parent ZTWIM CR.
    // +kubebuilder:validation:Optional
    // +kubebuilder:deprecatedversion:description="Use ZeroTrustWorkloadIdentityManager.spec.clusterName"
    ClusterName string `json:"clusterName,omitempty"`

    // DEPRECATED: bundleConfigMap is deprecated and will be removed in v1beta1.
    // Use ZeroTrustWorkloadIdentityManager.spec.bundleConfig instead.
    // This value is automatically inherited from the parent ZTWIM CR.
    // +kubebuilder:validation:Optional
    // +kubebuilder:deprecatedversion:description="Use ZeroTrustWorkloadIdentityManager.spec.bundleConfig"
    BundleConfigMap string `json:"bundleConfigMap,omitempty"`

    // jwtIssuer is the JWT issuer url.
    // +kubebuilder:validation:Required
    JwtIssuer string `json:"jwtIssuer"`

    // ... rest of SpireServerSpec
}
```

**Repeat for:**
- `api/v1alpha1/spire_agent_config_types.go`
- `api/v1alpha1/spire_oidc_discovery_provider_types.go`

### 1.3 Regenerate DeepCopy

```bash
cd /home/manpilla/Documents/pillaimanish/zero-trust-workload-identity-manager
go generate ./api/...
```

This regenerates `zz_generated.deepcopy.go` with the new fields.

### 1.4 Generate CRDs

```bash
cd /home/manpilla/Documents/pillaimanish/zero-trust-workload-identity-manager
make manifests
```

This updates YAML files in `config/crd/bases/`.

---

## Phase 2: Webhook Implementation

### 2.1 Create Validating Webhook Package

**File:** `pkg/webhooks/common.go`

```go
package webhooks

import (
    "fmt"
    "regexp"
    
    v1alpha1 "github.com/openshift/zero-trust-workload-identity-manager/api/v1alpha1"
)

const (
    // ValidateTrustDomainPattern is the regex pattern for valid trust domains
    ValidateTrustDomainPattern = `^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)*$`
    
    // ValidateClusterNamePattern is the regex pattern for valid cluster names
    ValidateClusterNamePattern = `^[a-z0-9]([a-z0-9-]*[a-z0-9])?$`
)

// ValidateTrustDomain validates the trust domain format
func ValidateTrustDomain(domain string) error {
    if domain == "" {
        return fmt.Errorf("trustDomain cannot be empty")
    }
    
    pattern := regexp.MustCompile(ValidateTrustDomainPattern)
    if !pattern.MatchString(domain) {
        return fmt.Errorf("trustDomain %q is not a valid DNS domain", domain)
    }
    
    return nil
}

// ValidateClusterName validates the cluster name format
func ValidateClusterName(name string) error {
    if name == "" {
        return fmt.Errorf("clusterName cannot be empty")
    }
    
    pattern := regexp.MustCompile(ValidateClusterNamePattern)
    if !pattern.MatchString(name) {
        return fmt.Errorf("clusterName %q must be alphanumeric with hyphens only", name)
    }
    
    return nil
}

// ConfigConflict represents a conflict between parent and child config
type ConfigConflict struct {
    Field    string // e.g., "trustDomain"
    Parent   string // Value in ZTWIM
    Child    string // Value in operand
    ParentCR string // "ZeroTrustWorkloadIdentityManager"
    ChildCR  string // "SpireServer", etc.
}

// CheckConfigConflict checks if parent and child values conflict
func CheckConfigConflict(parentVal, childVal string) (conflict bool, msg string) {
    if childVal == "" {
        // Child is empty, no conflict
        return false, ""
    }
    
    if parentVal == "" {
        // Parent is empty but child has value
        // This is OK during bootstrap
        return false, ""
    }
    
    if parentVal != childVal {
        return true, fmt.Sprintf("value mismatch: parent has %q, child has %q", parentVal, childVal)
    }
    
    return false, ""
}
```

### 2.2 Create ZTWIM Webhook

**File:** `pkg/webhooks/ztwim_validator.go`

```go
package webhooks

import (
    "fmt"
    
    admissionv1 "k8s.io/api/admission/v1"
    "k8s.io/apimachinery/pkg/runtime"
    ctrl "sigs.k8s.io/controller-runtime"
    logf "sigs.k8s.io/controller-runtime/pkg/log"
    "sigs.k8s.io/controller-runtime/pkg/webhook"
    "sigs.k8s.io/controller-runtime/pkg/webhook/admission"
    
    v1alpha1 "github.com/openshift/zero-trust-workload-identity-manager/api/v1alpha1"
)

var ztwimlog = logf.Log.WithName("ztwim-webhook")

// +kubebuilder:webhook:path=/validate-operator-openshift-io-v1alpha1-zerotrustworkloadidentitymanager,mutating=false,failurePolicy=fail,sideEffects=None,admissionReviewVersions={v1},resources=zerotrustworkloadidentitymanagers,verbs=create;update,name=vztwim.operator.openshift.io,clientConfig={service:{name:webhook-service,namespace:system}}

type ZTWIMValidator struct {
}

func (v *ZTWIMValidator) ValidateCreate(obj runtime.Object) (admission.Warnings, error) {
    ztwim, ok := obj.(*v1alpha1.ZeroTrustWorkloadIdentityManager)
    if !ok {
        return nil, fmt.Errorf("expected ZeroTrustWorkloadIdentityManager, got %T", obj)
    }
    
    var warnings admission.Warnings
    
    ztwimlog.Info("Validating ZTWIM creation", "name", ztwim.Name)
    
    // Singleton check
    if ztwim.Name != "cluster" {
        return warnings, fmt.Errorf("ZeroTrustWorkloadIdentityManager must be named 'cluster', got %q", ztwim.Name)
    }
    
    // Validate trustDomain
    if err := ValidateTrustDomain(ztwim.Spec.TrustDomain); err != nil {
        return warnings, err
    }
    
    // Validate clusterName
    if err := ValidateClusterName(ztwim.Spec.ClusterName); err != nil {
        return warnings, err
    }
    
    // Validate bundleConfig
    if ztwim.Spec.BundleConfig.Name == "" {
        return warnings, fmt.Errorf("bundleConfig.name cannot be empty")
    }
    if ztwim.Spec.BundleConfig.Namespace == "" {
        return warnings, fmt.Errorf("bundleConfig.namespace cannot be empty")
    }
    
    return warnings, nil
}

func (v *ZTWIMValidator) ValidateUpdate(oldObj, newObj runtime.Object) (admission.Warnings, error) {
    oldZtwim, ok := oldObj.(*v1alpha1.ZeroTrustWorkloadIdentityManager)
    if !ok {
        return nil, fmt.Errorf("expected ZeroTrustWorkloadIdentityManager, got %T", oldObj)
    }
    
    newZtwim, ok := newObj.(*v1alpha1.ZeroTrustWorkloadIdentityManager)
    if !ok {
        return nil, fmt.Errorf("expected ZeroTrustWorkloadIdentityManager, got %T", newObj)
    }
    
    var warnings admission.Warnings
    
    ztwimlog.Info("Validating ZTWIM update", "name", newZtwim.Name)
    
    // Validate new trustDomain
    if newZtwim.Spec.TrustDomain != oldZtwim.Spec.TrustDomain {
        if err := ValidateTrustDomain(newZtwim.Spec.TrustDomain); err != nil {
            return warnings, err
        }
        
        warnings = append(warnings, 
            fmt.Sprintf("trustDomain changed from %q to %q - all operands will be updated", 
                oldZtwim.Spec.TrustDomain, newZtwim.Spec.TrustDomain))
    }
    
    // Validate new clusterName
    if newZtwim.Spec.ClusterName != oldZtwim.Spec.ClusterName {
        if err := ValidateClusterName(newZtwim.Spec.ClusterName); err != nil {
            return warnings, err
        }
        
        warnings = append(warnings,
            fmt.Sprintf("clusterName changed from %q to %q - all operands will be updated",
                oldZtwim.Spec.ClusterName, newZtwim.Spec.ClusterName))
    }
    
    return warnings, nil
}

func (v *ZTWIMValidator) ValidateDelete(obj runtime.Object) (admission.Warnings, error) {
    // Allow deletion
    return nil, nil
}

// SetupWebhookWithManager sets up the webhook with the manager
func SetupZTWIMWebhook(mgr ctrl.Manager) error {
    return ctrl.NewWebhookManagedBy(mgr).
        For(&v1alpha1.ZeroTrustWorkloadIdentityManager{}).
        WithValidator(&ZTWIMValidator{}).
        Complete()
}
```

### 2.3 Create Operand Webhook

**File:** `pkg/webhooks/operand_validator.go`

```go
package webhooks

import (
    "context"
    "fmt"
    
    "k8s.io/apimachinery/pkg/runtime"
    "k8s.io/apimachinery/pkg/types"
    ctrl "sigs.k8s.io/controller-runtime"
    "sigs.k8s.io/controller-runtime/pkg/client"
    logf "sigs.k8s.io/controller-runtime/pkg/log"
    "sigs.k8s.io/controller-runtime/pkg/webhook/admission"
    
    v1alpha1 "github.com/openshift/zero-trust-workload-identity-manager/api/v1alpha1"
)

var operandlog = logf.Log.WithName("operand-webhook")

type OperandValidator struct {
    client client.Client
}

// ValidateOperandCreate validates operand creation against parent ZTWIM
func (v *OperandValidator) ValidateOperandCreate(ctx context.Context, obj client.Object, parentCR string) (admission.Warnings, error) {
    var warnings admission.Warnings
    
    operandlog.Info("Validating operand creation", 
        "kind", obj.GetObjectKind().GroupVersionKind().Kind,
        "name", obj.GetName())
    
    // Only operand resources named "cluster" are allowed
    if obj.GetName() != "cluster" {
        return warnings, fmt.Errorf("%s must be named 'cluster', got %q", 
            obj.GetObjectKind().GroupVersionKind().Kind, obj.GetName())
    }
    
    // Fetch parent ZTWIM
    ztwim := &v1alpha1.ZeroTrustWorkloadIdentityManager{}
    if err := v.client.Get(ctx, types.NamespacedName{Name: "cluster"}, ztwim); err != nil {
        // During bootstrap, ZTWIM might not exist yet
        operandlog.Info("ZTWIM not found during operand creation - bootstrap mode", 
            "operand", obj.GetName())
        return warnings, nil
    }
    
    // Validate operand values match ZTWIM
    operandSpec := obj.(*v1alpha1.SpireServer).Spec // This is simplified for example
    
    if conflict, msg := CheckConfigConflict(ztwim.Spec.TrustDomain, operandSpec.TrustDomain); conflict {
        return warnings, fmt.Errorf("trustDomain conflict: %s", msg)
    }
    
    if conflict, msg := CheckConfigConflict(ztwim.Spec.ClusterName, operandSpec.ClusterName); conflict {
        return warnings, fmt.Errorf("clusterName conflict: %s", msg)
    }
    
    return warnings, nil
}

// ValidateOperandUpdate validates operand update
func (v *OperandValidator) ValidateOperandUpdate(ctx context.Context, oldObj, newObj client.Object) (admission.Warnings, error) {
    var warnings admission.Warnings
    
    operandlog.Info("Validating operand update",
        "kind", newObj.GetObjectKind().GroupVersionKind().Kind,
        "name", newObj.GetName())
    
    // Fetch parent ZTWIM
    ztwim := &v1alpha1.ZeroTrustWorkloadIdentityManager{}
    if err := v.client.Get(ctx, types.NamespacedName{Name: "cluster"}, ztwim); err != nil {
        operandlog.Error(err, "Failed to fetch ZTWIM during operand update")
        return warnings, err
    }
    
    // Simplified validation - repeat for each operand type
    oldSpec := oldObj.(*v1alpha1.SpireServer).Spec
    newSpec := newObj.(*v1alpha1.SpireServer).Spec
    
    // Check if operand is trying to set different trustDomain than parent
    if newSpec.TrustDomain != "" && newSpec.TrustDomain != ztwim.Spec.TrustDomain {
        return warnings, fmt.Errorf("operand trustDomain %q conflicts with ZTWIM trustDomain %q",
            newSpec.TrustDomain, ztwim.Spec.TrustDomain)
    }
    
    return warnings, nil
}

// SetupOperandWebhook sets up the webhook for all operand types
func SetupOperandWebhooks(mgr ctrl.Manager) error {
    validator := &OperandValidator{client: mgr.GetClient()}
    
    // Setup for SpireServer
    if err := ctrl.NewWebhookManagedBy(mgr).
        For(&v1alpha1.SpireServer{}).
        WithValidator(&SpireServerOperandValidator{parent: validator}).
        Complete(); err != nil {
        return err
    }
    
    // Repeat for other operand types...
    return nil
}

// SpireServerOperandValidator implements validator for SpireServer
type SpireServerOperandValidator struct {
    parent *OperandValidator
}

func (v *SpireServerOperandValidator) ValidateCreate(obj runtime.Object) (admission.Warnings, error) {
    ctx := context.Background() // Use proper context from caller
    return v.parent.ValidateOperandCreate(ctx, obj.(client.Object), "SpireServer")
}

func (v *SpireServerOperandValidator) ValidateUpdate(oldObj, newObj runtime.Object) (admission.Warnings, error) {
    ctx := context.Background() // Use proper context from caller
    return v.parent.ValidateOperandUpdate(ctx, oldObj.(client.Object), newObj.(client.Object))
}

func (v *SpireServerOperandValidator) ValidateDelete(obj runtime.Object) (admission.Warnings, error) {
    return nil, nil
}
```

---

## Phase 3: Finalizer & Owner Reference Implementation

### 3.1 Update ZTWIM Controller

**File:** `pkg/controller/zero-trust-workload-identity-manager/controller.go` (Add to existing file)

```go
package zero_trust_workload_identity_manager

import (
    "context"
    "fmt"
    "time"
    
    "k8s.io/apimachinery/pkg/api/errors"
    metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
    "sigs.k8s.io/controller-runtime/pkg/controller/controllerutil"
    
    v1alpha1 "github.com/openshift/zero-trust-workload-identity-manager/api/v1alpha1"
)

const (
    // ZTWIMFinalizerName is the finalizer name for ZTWIM CR
    ZTWIMFinalizerName = "ztwim.io/operand-lifecycle"
    
    // DeletionGracePeriod is the grace period for operand cleanup
    DeletionGracePeriod = 30 * time.Second
    
    // DeletionTimeout is the maximum time to wait for operand cleanup
    DeletionTimeout = 2 * time.Minute
)

// handleZTWIMDeletion handles the deletion of ZTWIM CR
func (r *ZeroTrustWorkloadIdentityManagerReconciler) handleZTWIMDeletion(
    ctx context.Context,
    ztwim *v1alpha1.ZeroTrustWorkloadIdentityManager,
) error {
    r.log.Info("Handling ZTWIM deletion", "name", ztwim.Name)
    
    if !controllerutil.ContainsFinalizer(ztwim, ZTWIMFinalizerName) {
        return nil
    }
    
    // Execute PreDeleteHook
    if err := r.preDeleteHook(ctx, ztwim); err != nil {
        r.log.Error(err, "PreDeleteHook failed", "name", ztwim.Name)
        // Continue anyway, we'll try to clean up
    }
    
    // Remove finalizer to allow deletion
    controllerutil.RemoveFinalizer(ztwim, ZTWIMFinalizerName)
    if err := r.Update(ctx, ztwim); err != nil {
        return fmt.Errorf("failed to remove finalizer: %w", err)
    }
    
    r.log.Info("Successfully removed finalizer from ZTWIM", "name", ztwim.Name)
    return nil
}

// preDeleteHook executes cleanup before ZTWIM deletion
func (r *ZeroTrustWorkloadIdentityManagerReconciler) preDeleteHook(
    ctx context.Context,
    ztwim *v1alpha1.ZeroTrustWorkloadIdentityManager,
) error {
    r.log.Info("Executing preDeleteHook for ZTWIM", "name", ztwim.Name)
    
    // Set deletion grace period for operands
    operandGracePeriod := int64(DeletionGracePeriod.Seconds())
    
    operands := []v1alpha1.ZeroTrustWorkloadIdentityManager{
        &v1alpha1.SpireServer{},
        &v1alpha1.SpireAgent{},
        &v1alpha1.SpiffeCSIDriver{},
        &v1alpha1.SpireOIDCDiscoveryProvider{},
    }
    
    // Wait for operand cleanup with timeout
    timeoutCtx, cancel := context.WithTimeout(ctx, DeletionTimeout)
    defer cancel()
    
    // Poll for operand finalizer completion
    operandsCleaned := false
    checkTicker := time.NewTicker(1 * time.Second)
    defer checkTicker.Stop()
    
    for {
        select {
        case <-timeoutCtx.Done():
            r.log.Warn("Timeout waiting for operand cleanup", "name", ztwim.Name)
            operandsCleaned = true // Force proceed after timeout
        case <-checkTicker.C:
            if r.areOperandFinalizersRemoved(ctx, ztwim) {
                operandsCleaned = true
            }
        }
        
        if operandsCleaned {
            break
        }
    }
    
    return nil
}

// areOperandFinalizersRemoved checks if all operand finalizers are removed
func (r *ZeroTrustWorkloadIdentityManagerReconciler) areOperandFinalizersRemoved(
    ctx context.Context,
    ztwim *v1alpha1.ZeroTrustWorkloadIdentityManager,
) bool {
    // Check each operand type
    spireServer := &v1alpha1.SpireServer{}
    if err := r.ctrlClient.Get(ctx, client.ObjectKey{Name: "cluster"}, spireServer); err == nil {
        if len(spireServer.GetFinalizers()) > 0 {
            return false
        }
    }
    
    // Repeat for other operands...
    return true
}

// ensureOwnerReferences adds ZTWIM as owner of operands
func (r *ZeroTrustWorkloadIdentityManagerReconciler) ensureOwnerReferences(
    ctx context.Context,
    ztwim *v1alpha1.ZeroTrustWorkloadIdentityManager,
) error {
    r.log.Info("Ensuring owner references on operands", "ztwim", ztwim.Name)
    
    operandsList := []client.Object{
        &v1alpha1.SpireServer{},
        &v1alpha1.SpireAgent{},
        &v1alpha1.SpiffeCSIDriver{},
        &v1alpha1.SpireOIDCDiscoveryProvider{},
    }
    
    for _, obj := range operandsList {
        obj := obj
        
        // Fetch operand CR
        key := client.ObjectKey{Name: "cluster"}
        if err := r.ctrlClient.Get(ctx, key, obj); err != nil {
            if errors.IsNotFound(err) {
                // Operand doesn't exist yet, skip
                continue
            }
            r.log.Error(err, "Failed to fetch operand")
            continue
        }
        
        // Update OwnerReference
        ownerRef := metav1.OwnerReference{
            APIVersion:         v1alpha1.GroupVersion.String(),
            Kind:               "ZeroTrustWorkloadIdentityManager",
            Name:               ztwim.Name,
            UID:                ztwim.UID,
            Controller:         boolPtr(true),
            BlockOwnerDeletion: boolPtr(true),
        }
        
        ownerRefs := obj.GetOwnerReferences()
        
        // Check if already present
        found := false
        for i, ref := range ownerRefs {
            if ref.Kind == ownerRef.Kind && ref.Name == ownerRef.Name {
                ownerRefs[i] = ownerRef
                found = true
                break
            }
        }
        
        if !found {
            ownerRefs = append(ownerRefs, ownerRef)
        }
        
        obj.SetOwnerReferences(ownerRefs)
        
        // Update operand CR
        if err := r.ctrlClient.Update(ctx, obj); err != nil {
            r.log.Error(err, "Failed to update operand with owner reference",
                "operand", obj.GetName())
            continue
        }
        
        r.log.Info("Added owner reference to operand",
            "operand", fmt.Sprintf("%s/%s", obj.GetObjectKind(), obj.GetName()))
    }
    
    return nil
}

// boolPtr returns a pointer to a bool value
func boolPtr(b bool) *bool {
    return &b
}

// In Reconcile method, add finalizer and owner references:
func (r *ZeroTrustWorkloadIdentityManagerReconciler) Reconcile(
    ctx context.Context,
    req ctrl.Request,
) (ctrl.Result, error) {
    // ... existing code ...
    
    // Check for deletion
    if !ztwim.ObjectMeta.DeletionTimestamp.IsZero() {
        if err := r.handleZTWIMDeletion(ctx, ztwim); err != nil {
            return ctrl.Result{}, err
        }
        return ctrl.Result{}, nil
    }
    
    // Add finalizer if not present
    if !controllerutil.ContainsFinalizer(ztwim, ZTWIMFinalizerName) {
        controllerutil.AddFinalizer(ztwim, ZTWIMFinalizerName)
        if err := r.Update(ctx, ztwim); err != nil {
            return ctrl.Result{}, err
        }
    }
    
    // Ensure owner references
    if err := r.ensureOwnerReferences(ctx, ztwim); err != nil {
        r.log.Error(err, "Failed to ensure owner references")
    }
    
    // ... rest of reconciliation ...
}
```

### 3.2 Update Operand Controllers with Cleanup Finalizers

**File:** `pkg/controller/spire-server/controller.go` (Example for SpireServer)

```go
package spire_server

import (
    "context"
    "fmt"
    
    ctrl "sigs.k8s.io/controller-runtime"
    "sigs.k8s.io/controller-runtime/pkg/controller/controllerutil"
    
    v1alpha1 "github.com/openshift/zero-trust-workload-identity-manager/api/v1alpha1"
)

const (
    SpireServerFinalizerName = "ztwim.io/spire-server-cleanup"
)

// handleSpireServerDeletion handles cleanup before SpireServer deletion
func (r *SpireServerReconciler) handleSpireServerDeletion(
    ctx context.Context,
    server *v1alpha1.SpireServer,
) error {
    r.log.Info("Handling SpireServer deletion cleanup", "name", server.Name)
    
    if !controllerutil.ContainsFinalizer(server, SpireServerFinalizerName) {
        return nil
    }
    
    // Execute cleanup operations
    if err := r.gracefulShutdown(ctx, server); err != nil {
        r.log.Error(err, "Graceful shutdown failed", "name", server.Name)
        // Don't fail - continue with cleanup
    }
    
    if err := r.backupDatastore(ctx, server); err != nil {
        r.log.Error(err, "Datastore backup failed", "name", server.Name)
        // Don't fail - continue with cleanup
    }
    
    if err := r.releaseResources(ctx, server); err != nil {
        r.log.Error(err, "Resource release failed", "name", server.Name)
    }
    
    // Remove finalizer to allow deletion
    controllerutil.RemoveFinalizer(server, SpireServerFinalizerName)
    if err := r.Update(ctx, server); err != nil {
        return fmt.Errorf("failed to remove finalizer: %w", err)
    }
    
    r.log.Info("Successfully cleaned up and removed finalizer from SpireServer", "name", server.Name)
    return nil
}

// gracefulShutdown gracefully shuts down the SPIRE server
func (r *SpireServerReconciler) gracefulShutdown(
    ctx context.Context,
    server *v1alpha1.SpireServer,
) error {
    r.log.Info("Initiating graceful shutdown", "server", server.Name)
    
    // Drain active connections
    // This would typically involve:
    // 1. Stopping accepting new connections
    // 2. Waiting for active connections to complete (with timeout)
    // 3. Closing listening sockets
    
    return nil // Simplified for example
}

// backupDatastore backs up the SPIRE server datastore
func (r *SpireServerReconciler) backupDatastore(
    ctx context.Context,
    server *v1alpha1.SpireServer,
) error {
    r.log.Info("Backing up datastore", "server", server.Name)
    
    // Implementation would:
    // 1. Locate PVC/volume
    // 2. Create snapshot/backup
    // 3. Store backup in retention location
    
    return nil // Simplified for example
}

// releaseResources releases associated resources
func (r *SpireServerReconciler) releaseResources(
    ctx context.Context,
    server *v1alpha1.SpireServer,
) error {
    r.log.Info("Releasing resources", "server", server.Name)
    
    // Implementation would:
    // 1. Release PVC
    // 2. Clean up ConfigMaps
    // 3. Remove certificates
    
    return nil // Simplified for example
}

// In Reconcile method, add finalizer and handle deletion:
func (r *SpireServerReconciler) Reconcile(
    ctx context.Context,
    req ctrl.Request,
) (ctrl.Result, error) {
    server := &v1alpha1.SpireServer{}
    // ... fetch server ...
    
    // Check for deletion
    if !server.ObjectMeta.DeletionTimestamp.IsZero() {
        return ctrl.Result{}, r.handleSpireServerDeletion(ctx, server)
    }
    
    // Add finalizer if not present
    if !controllerutil.ContainsFinalizer(server, SpireServerFinalizerName) {
        controllerutil.AddFinalizer(server, SpireServerFinalizerName)
        if err := r.Update(ctx, server); err != nil {
            return ctrl.Result{}, err
        }
        return ctrl.Result{Requeue: true}, nil
    }
    
    // ... rest of reconciliation ...
}
```

---

## Phase 4: Config Injection

### 4.1 Config Resolver Helper

**File:** `pkg/controller/utils/config_resolver.go`

```go
package utils

import (
    "context"
    "fmt"
    
    "k8s.io/apimachinery/pkg/types"
    "sigs.k8s.io/controller-runtime/pkg/client"
    
    v1alpha1 "github.com/openshift/zero-trust-workload-identity-manager/api/v1alpha1"
)

// ConfigResolver resolves configuration from ZTWIM parent CR
type ConfigResolver struct {
    client client.Client
}

// NewConfigResolver creates a new ConfigResolver
func NewConfigResolver(c client.Client) *ConfigResolver {
    return &ConfigResolver{client: c}
}

// ResolveTrustDomain resolves trustDomain from ZTWIM or operand
func (cr *ConfigResolver) ResolveTrustDomain(
    ctx context.Context,
    operandValue string,
) (string, error) {
    // Fetch ZTWIM CR
    ztwim := &v1alpha1.ZeroTrustWorkloadIdentityManager{}
    if err := cr.client.Get(ctx, types.NamespacedName{Name: "cluster"}, ztwim); err != nil {
        return "", fmt.Errorf("failed to fetch ZTWIM: %w", err)
    }
    
    // ZTWIM value takes precedence
    if ztwim.Spec.TrustDomain != "" {
        return ztwim.Spec.TrustDomain, nil
    }
    
    // Fall back to operand value
    if operandValue != "" {
        return operandValue, nil
    }
    
    return "", fmt.Errorf("trustDomain not found in ZTWIM or operand")
}

// ResolveClusterName resolves clusterName from ZTWIM or operand
func (cr *ConfigResolver) ResolveClusterName(
    ctx context.Context,
    operandValue string,
) (string, error) {
    // Similar to ResolveTrustDomain
    ztwim := &v1alpha1.ZeroTrustWorkloadIdentityManager{}
    if err := cr.client.Get(ctx, types.NamespacedName{Name: "cluster"}, ztwim); err != nil {
        return "", fmt.Errorf("failed to fetch ZTWIM: %w", err)
    }
    
    if ztwim.Spec.ClusterName != "" {
        return ztwim.Spec.ClusterName, nil
    }
    
    if operandValue != "" {
        return operandValue, nil
    }
    
    return "", fmt.Errorf("clusterName not found in ZTWIM or operand")
}

// ResolveBundleConfigMap resolves bundle ConfigMap name from ZTWIM
func (cr *ConfigResolver) ResolveBundleConfigMap(
    ctx context.Context,
    operandValue string,
) (string, error) {
    // Fetch ZTWIM CR
    ztwim := &v1alpha1.ZeroTrustWorkloadIdentityManager{}
    if err := cr.client.Get(ctx, types.NamespacedName{Name: "cluster"}, ztwim); err != nil {
        return "", fmt.Errorf("failed to fetch ZTWIM: %w", err)
    }
    
    if ztwim.Spec.BundleConfig.Name != "" {
        return ztwim.Spec.BundleConfig.Name, nil
    }
    
    if operandValue != "" {
        return operandValue, nil
    }
    
    return "", fmt.Errorf("bundleConfigMap not found in ZTWIM or operand")
}
```

### 4.2 Use Config Resolver in Operand Controller

**File:** `pkg/controller/spire-server/controller.go` (Update)

```go
// In the Reconcile method of SpireServerReconciler:

// Resolve config from ZTWIM parent
configResolver := utils.NewConfigResolver(r.Client)

trustDomain, err := configResolver.ResolveTrustDomain(ctx, server.Spec.TrustDomain)
if err != nil {
    return ctrl.Result{}, fmt.Errorf("failed to resolve trustDomain: %w", err)
}

clusterName, err := configResolver.ResolveClusterName(ctx, server.Spec.ClusterName)
if err != nil {
    return ctrl.Result{}, fmt.Errorf("failed to resolve clusterName: %w", err)
}

bundleConfigMap, err := configResolver.ResolveBundleConfigMap(ctx, server.Spec.BundleConfigMap)
if err != nil {
    return ctrl.Result{}, fmt.Errorf("failed to resolve bundleConfigMap: %w", err)
}

// Now use these resolved values in config generation
// ...
```

---

## Phase 5: Testing Checklist

### Unit Tests

- [ ] Test `CheckConfigConflict` function
- [ ] Test `ValidateTrustDomain` validation
- [ ] Test `ValidateClusterName` validation
- [ ] Test ZTWIM webhook validation rules
- [ ] Test operand webhook validation rules
- [ ] Test config resolver priority
- [ ] Test finalizer addition/removal
- [ ] Test owner reference creation

### E2E Tests

- [ ] Create ZTWIM, verify operands created with OwnerReferences
- [ ] Delete ZTWIM, verify operands cleaned up gracefully
- [ ] Update ZTWIM trustDomain, verify all operands updated
- [ ] Test timeout during operand cleanup
- [ ] Test orphaned operand detection
- [ ] Test webhook conflict rejection
- [ ] Test backward compatibility migration

---

## Migration Command Reference

```bash
# Generate manifests after API changes
make manifests

# Run controllers locally for testing
make run

# Run E2E tests
make test-e2e

# Build and push image
make docker-build docker-push IMG=<your-registry>

# Deploy to cluster
kubectl apply -k config/default
```

---

## Troubleshooting Common Issues

### Issue 1: "TrustDomain not found"
**Cause:** ZTWIM CR doesn't have trustDomain set  
**Solution:** Ensure ZTWIM.spec.trustDomain is configured before creating operands

### Issue 2: "Webhook failed to parse"
**Cause:** Webhook not properly registered  
**Solution:** Verify webhook configuration in `config/webhook/` and manager setup

### Issue 3: "Finalizer timeout"
**Cause:** Operand cleanup taking longer than expected  
**Solution:** Check operand pod logs for issues, increase timeout if needed

### Issue 4: "OwnerReference mismatch"
**Cause:** Operand has different UID for owner  
**Solution:** Delete and recreate operand - ZTWIM controller will set correct reference

---

**Implementation Status Tracker:**

Use this to track progress:

```
Phase 1: API Changes
  - [ ] ZTWIM spec updated
  - [ ] Operand fields deprecated
  - [ ] DeepCopy regenerated
  - [ ] CRDs generated
  
Phase 2: Webhooks
  - [ ] Common validation functions
  - [ ] ZTWIM webhook implemented
  - [ ] Operand webhooks implemented
  - [ ] Webhook tests written
  
Phase 3: Lifecycle
  - [ ] ZTWIM finalizer logic
  - [ ] Operand finalizers
  - [ ] Owner reference logic
  - [ ] Deletion flow tests
  
Phase 4: Config Injection
  - [ ] Config resolver
  - [ ] Operand controllers updated
  - [ ] Config cascade tests
  
Phase 5: Testing
  - [ ] Unit test suite
  - [ ] E2E test suite
  - [ ] Migration tests
  - [ ] Documentation updated
```


