# Create-Only Mode for Zero Trust Workload Identity Manager

## Overview

The Zero Trust Workload Identity Manager (ZTWIM) supports a **create-only mode** that allows users to make manual configurations to resources managed by the operator without having those changes overwritten during Day 2 operations. This feature is implemented through the `ztwim.openshift.io/create-only` annotation.

## Use Case

This feature addresses scenarios where:

- **Manual Customization Required**: Users need to customize operator-managed resources (ConfigMaps, Deployments, DaemonSets, etc.) with specific configurations that differ from the operator's defaults
- **Day 2 Operations**: After initial deployment, users want to prevent the operator from overwriting their manual changes during subsequent reconciliation cycles
- **Configuration Drift Prevention**: Users want to maintain control over certain resource configurations while still benefiting from the operator's lifecycle management

## How It Works

### Annotation-Based Control

The create-only mode is controlled by adding the following annotation to any ZTWIM custom resource:

```yaml
metadata:
  annotations:
    ztwim.openshift.io/create-only: "true"
```

### Behavior

When create-only mode is enabled:

1. **Resource Creation**: The operator will create resources if they don't exist
2. **Update Skipping**: The operator will skip updates to existing resources and log the skip action
3. **Status Reporting**: The operator reports the create-only mode status in the resource's condition status


## Supported Resources

The create-only mode is supported across all ZTWIM controllers and affects the following resource types:

### Static Resources (ZeroTrustWorkloadIdentityManager)
- **RBAC Resources**: ClusterRoles, ClusterRoleBindings, Roles, RoleBindings
- **Service Accounts**: All operator-managed service accounts
- **Services**: Kubernetes services for SPIRE components

### SPIRE Server (SpireServer)
- **ConfigMaps**: SPIRE server configuration and controller manager configuration
- **StatefulSets**: SPIRE server StatefulSet deployments

### SPIRE Agent (SpireAgent)  
- **ConfigMaps**: SPIRE agent configuration
- **DaemonSets**: SPIRE agent DaemonSet deployments

### SPIFFE CSI Driver (SpiffeCSIDriver)
- **DaemonSets**: SPIFFE CSI driver DaemonSet deployments

### SPIRE OIDC Discovery Provider (SpireOIDCDiscoveryProvider)
- **ConfigMaps**: OIDC discovery provider configuration
- **Deployments**: OIDC discovery provider deployments

## Usage Examples

### Basic Usage

Enable create-only mode on a ZeroTrustWorkloadIdentityManager:

```yaml
apiVersion: operator.openshift.io/v1alpha1
kind: ZeroTrustWorkloadIdentityManager
metadata:
  name: cluster
  annotations:
    ztwim.openshift.io/create-only: "true"
spec: {}
```

### SPIRE Server with Create-Only Mode

```yaml
apiVersion: operator.openshift.io/v1alpha1
kind: SpireServer
metadata:
  name: cluster
  annotations:
    ztwim.openshift.io/create-only: "true"
spec:
    .
    .
    .
```

### SPIRE Agent with Create-Only Mode

```yaml
apiVersion: operator.openshift.io/v1alpha1
kind: SpireAgent
metadata:
  name: cluster
  annotations:
    ztwim.openshift.io/create-only: "true"
spec:
    .
    .
```

### SPIFFE CSI with Create-Only Mode

```yaml
apiVersion: operator.openshift.io/v1alpha1
kind: SpiffeCSIDriver
metadata:
  name: cluster
  annotations:
    ztwim.openshift.io/create-only: "true"
spec:
    .
    .
```

### SPIRE OIDC Discovery Provider with Create-Only Mode

```yaml
apiVersion: operator.openshift.io/v1alpha1
kind: SpireOIDCDiscoveryProvider
metadata:
  name: cluster
  annotations:
    ztwim.openshift.io/create-only: "true"
spec:
    .
    .
```

## Status Monitoring

The create-only mode status is reflected in the resource's condition status:

### When Enabled

```yaml
status:
  conditions:
  - type: CreateOnlyMode
    status: "True"
    reason: CreateOnlyModeEnabled
    message: "Create-only mode is enabled via ztwim.openshift.io/create-only annotation"
    lastTransitionTime: "2024-01-15T10:30:00Z"
```

### When Disabled

```yaml
status:
  conditions:
  - type: CreateOnlyMode
    status: "False" 
    reason: CreateOnlyModeDisabled
    message: "Create-only mode is disabled"
    lastTransitionTime: "2024-01-15T10:35:00Z"
```

## Implementation Details

The create-only mode evaluation follows this logic:

Check if the current resource has the annotation set to `"true"`
This ensures that once create-only mode is enabled, it persists until the operator pod restarts, even if the annotation is removed.
In order to go back to the non create-only mode user may need to remove/unset the annotation and restart the operator pod.


### When to Use Create-Only Mode

1. **Initial Deployment Customization**: When you need to customize resources immediately after operator deployment
2. **Configuration Drift Management**: When you have specific configuration requirements that differ from operator defaults
3. **Testing and Development**: When experimenting with different configurations without operator interference


