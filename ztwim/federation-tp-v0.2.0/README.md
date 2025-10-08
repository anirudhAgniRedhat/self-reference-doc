# SPIRE Federation Setup - End-to-End Automation

This directory contains an automated script to set up complete SPIRE federation between two OpenShift clusters with Zero Trust Workload Identity Manager.

## What This Script Does

The `setup-federation.sh` script performs a **complete end-to-end federation setup**:

### Configuration
1. ✅ Updates SPIRE Server ConfigMaps with federation bundle endpoint
2. ✅ Patches Services to expose port 8443 for federation
3. ✅ Patches StatefulSets to add federation port to pods
4. ✅ Creates OpenShift Routes to expose federation endpoints

### Federation Setup
5. ✅ Creates ClusterFederatedTrustDomain resources on both clusters
6. ✅ Bootstraps trust bundle exchange between clusters
7. ✅ Creates federated ClusterSPIFFEID resources

### Demo Workloads
8. ✅ Deploys demo workloads on both clusters
9. ✅ Verifies SPIFFE Workload API access
10. ✅ Shows federation is working with real workloads

### Verification
11. ✅ Displays trust bundles on both clusters
12. ✅ Shows workload entries with federatesWith configuration
13. ✅ Provides complete status report

## Prerequisites

- Two OpenShift clusters with Zero Trust Workload Identity Manager installed
- `kubectl` configured to access both clusters
- `jq` installed for JSON processing
- Cluster-admin access to both clusters

## Usage

```bash
./setup-federation.sh <cluster1-kubeconfig> <cluster2-kubeconfig>
```

### Example

```bash
./setup-federation.sh \
  /home/user/cluster1/auth/kubeconfig \
  /home/user/cluster2/auth/kubeconfig
```

## What Gets Created

### On Both Clusters:

#### Configuration Updates
- **ConfigMap**: `spire-server` - Updated with federation configuration
- **Service**: `spire-server` - Port 8443 added for federation
- **StatefulSet**: `spire-server` - Container port 8443 added

#### Federation Resources
- **Route**: `spire-server-federation` - Exposes federation bundle endpoint
- **ClusterFederatedTrustDomain**: Configures trust relationship with remote cluster
- **ClusterSPIFFEID**: `federation-demo-workload` - Federated workload identity

#### Demo Workloads
- **Namespace**: `federation-demo` - Demo workload namespace
- **ServiceAccount**: `demo-workload` - Service account for demo pods
- **Deployment**: `demo-workload` - Alpine pod with SPIFFE Workload API access

## Output

The script provides colored output showing:
- 🔵 **Blue headers** - Major sections
- 🟢 **Green checkmarks** - Successful steps
- 🟡 **Yellow info** - Important information
- 🔴 **Red errors** - Failures (if any)
- 🟦 **Cyan** - Current step being executed

### Example Output

```
================================================
SPIRE Federation Setup
================================================

ℹ Cluster 1 kubeconfig: /path/to/cluster1/kubeconfig
ℹ Cluster 2 kubeconfig: /path/to/cluster2/kubeconfig

[STEP 1/15] Gathering cluster information
✓ Cluster 1: test01 (Trust Domain: apps.cluster1.example.com)
✓ Cluster 2: test02 (Trust Domain: apps.cluster2.example.com)

[STEP 2/15] Updating SPIRE Server ConfigMap on Cluster 1
✓ Cluster 1 ConfigMap updated

[STEP 3/15] Updating SPIRE Server ConfigMap on Cluster 2
✓ Cluster 2 ConfigMap updated

...

================================================
✅ Federation Setup Complete!
================================================
```

## Verification

After the script completes, you can verify federation:

### Check Trust Bundles

```bash
# Cluster 1
kubectl --kubeconfig=<cluster1-kubeconfig> exec -n zero-trust-workload-identity-manager spire-server-0 -c spire-server -- \
  /spire-server bundle list

# Cluster 2
kubectl --kubeconfig=<cluster2-kubeconfig> exec -n zero-trust-workload-identity-manager spire-server-0 -c spire-server -- \
  /spire-server bundle list
```

Both should show bundles from both trust domains.

### Check Workload Entries

```bash
# Cluster 1
kubectl --kubeconfig=<cluster1-kubeconfig> exec -n zero-trust-workload-identity-manager spire-server-0 -c spire-server -- \
  /spire-server entry show -selector k8s:ns:federation-demo

# Cluster 2
kubectl --kubeconfig=<cluster2-kubeconfig> exec -n zero-trust-workload-identity-manager spire-server-0 -c spire-server -- \
  /spire-server entry show -selector k8s:ns:federation-demo
```

Both should show `FederatesWith` configuration.

### Check Demo Workloads

```bash
# Cluster 1
kubectl --kubeconfig=<cluster1-kubeconfig> get pods -n federation-demo
kubectl --kubeconfig=<cluster1-kubeconfig> logs -n federation-demo -l app=demo-federated

# Cluster 2
kubectl --kubeconfig=<cluster2-kubeconfig> get pods -n federation-demo
kubectl --kubeconfig=<cluster2-kubeconfig> logs -n federation-demo -l app=demo-federated
```

Logs should show SPIFFE Workload API socket is available.

## Troubleshooting

### Script Fails at Step X

The script will show exactly which step failed. Common issues:

1. **ConfigMap update fails**: Check if SPIRE Server is installed
2. **Pod restart timeout**: Pods may take longer to restart, increase timeout in script
3. **Route creation fails**: Check if you have route permissions

### Workloads Not Getting SPIFFE Identities

1. Check if SPIRE Agent is running on nodes:
   ```bash
   kubectl get daemonset -n zero-trust-workload-identity-manager spire-agent
   ```

2. Check ClusterSPIFFEID status:
   ```bash
   kubectl get clusterspiffeid
   ```

3. Check SPIRE Controller Manager logs:
   ```bash
   kubectl logs -n zero-trust-workload-identity-manager spire-server-0 -c spire-controller-manager
   ```

### Federation Not Working

1. Check ClusterFederatedTrustDomain:
   ```bash
   kubectl get clusterfederatedtrustdomain
   ```

2. Check SPIRE Server logs:
   ```bash
   kubectl logs -n zero-trust-workload-identity-manager spire-server-0 -c spire-server | grep federation
   ```

3. Re-run bundle bootstrap manually:
   ```bash
   # Export bundles
   kubectl --kubeconfig=<cluster1> exec ... -- /spire-server bundle show -format spiffe > bundle1.txt
   kubectl --kubeconfig=<cluster2> exec ... -- /spire-server bundle show -format spiffe > bundle2.txt
   
   # Load bundles
   cat bundle2.txt | kubectl --kubeconfig=<cluster1> exec -i ... -- /spire-server bundle set ...
   cat bundle1.txt | kubectl --kubeconfig=<cluster2> exec -i ... -- /spire-server bundle set ...
   ```

## Re-running the Script

The script is idempotent - you can safely re-run it multiple times. It will:
- Update existing resources
- Skip resources that are already correctly configured
- Not fail if resources already exist

## Cleanup

To remove federation setup:

```bash
# On both clusters
kubectl delete namespace federation-demo
kubectl delete clusterspiffeid federation-demo-workload
kubectl delete clusterfederatedtrustdomain <federation-name>
kubectl delete route spire-server-federation -n zero-trust-workload-identity-manager
```

## Architecture

```
┌─────────────────────────────────────────┐
│         Cluster 1 (test01)              │
│                                          │
│  ┌──────────────┐    ┌───────────────┐ │
│  │ SPIRE Server │────│ Route (8443)  │─┼─┐
│  │ (Federation) │    └───────────────┘ │ │
│  └──────┬───────┘                       │ │
│         │ Trust Bundle                  │ │
│         │                               │ │
│  ┌──────▼───────┐                       │ │
│  │ Demo Workload│                       │ │
│  │ (Federated)  │                       │ │
│  └──────────────┘                       │ │
└─────────────────────────────────────────┘ │
                │                            │
                │ SPIFFE Auth (https_spiffe) │
                │                            │
┌───────────────▼─────────────────────────┐ │
│         Cluster 2 (test02)              │◄┘
│                                          │
│  ┌──────────────┐    ┌───────────────┐ │
│  │ SPIRE Server │────│ Route (8443)  │ │
│  │ (Federation) │    └───────────────┘ │
│  └──────┬───────┘                       │
│         │ Trust Bundle                  │
│         │                               │
│  ┌──────▼───────┐                       │
│  │ Demo Workload│                       │
│  │ (Federated)  │                       │
│  └──────────────┘                       │
└─────────────────────────────────────────┘
```

## Security

- Uses `https_spiffe` profile for federation (SPIFFE authentication)
- Trust bundles exchanged securely using SPIFFE identities
- No plaintext credentials or certificates exposed
- OpenShift Routes with TLS passthrough (end-to-end encryption)

## Support

For issues or questions:
- Check the verification section above
- Review SPIRE server logs
- Consult [SPIRE documentation](https://spiffe.io/docs/)

