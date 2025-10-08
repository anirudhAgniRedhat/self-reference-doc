# SPIRE Federation Setup Guide

This guide provides step-by-step instructions for completing the SPIRE federation setup between your two OpenShift clusters.

## Cluster Information

### Cluster 1 (test01)
- **Cluster Name**: test01
- **Trust Domain**: `apps.aagnihot-cluster-povc.devcluster.openshift.com`
- **Federation Endpoint**: `https://spire-federation-test01.apps.aagnihot-cluster-povc.devcluster.openshift.com`
- **SPIFFE ID**: `spiffe://apps.aagnihot-cluster-povc.devcluster.openshift.com/spire/server`

### Cluster 2 (test02)
- **Cluster Name**: test02
- **Trust Domain**: `apps.aagnihot-cluster-fdk.devcluster.openshift.com`
- **Federation Endpoint**: `https://spire-federation-test02.apps.aagnihot-cluster-fdk.devcluster.openshift.com`
- **SPIFFE ID**: `spiffe://apps.aagnihot-cluster-fdk.devcluster.openshift.com/spire/server`

## What Has Been Applied

✅ **Federation Routes** - Exposed SPIRE Server bundle endpoints on both clusters
✅ **ClusterFederatedTrustDomain** - Configured trust relationships on both clusters
✅ **ClusterSPIFFEID** - Configured workload identities with federation on both clusters

## Bootstrap Federation Trust Bundles

Since you're using the `https_spiffe` profile, both SPIRE instances need to have trust bundles from each other loaded manually for the initial bootstrap. After this, they will automatically refresh.

### Step 1: Export Trust Bundle from Cluster 1

```bash
# Set KUBECONFIG to Cluster 1
export KUBECONFIG=/home/aagnihot/workspace/test/installer/4.20-installer/aws/auth/kubeconfig

# Extract the trust bundle from Cluster 1
kubectl exec -it -n zero-trust-workload-identity-manager spire-server-0 -c spire-server -- \
  spire-server bundle show -format spiffe > /tmp/cluster1-test01-bundle.txt

# Verify the bundle was created
cat /tmp/cluster1-test01-bundle.txt
```

### Step 2: Export Trust Bundle from Cluster 2

```bash
# Set KUBECONFIG to Cluster 2
export KUBECONFIG=/home/aagnihot/workspace/test/installer/4.20-installer/aws1/auth/kubeconfig

# Extract the trust bundle from Cluster 2
kubectl exec -it -n zero-trust-workload-identity-manager spire-server-0 -c spire-server -- \
  spire-server bundle show -format spiffe > /tmp/cluster2-test02-bundle.txt

# Verify the bundle was created
cat /tmp/cluster2-test02-bundle.txt
```

### Step 3: Load Cluster 2's Bundle into Cluster 1

```bash
# Set KUBECONFIG to Cluster 1
export KUBECONFIG=/home/aagnihot/workspace/test/installer/4.20-installer/aws/auth/kubeconfig

# Import Cluster 2's bundle into Cluster 1
cat /tmp/cluster2-test02-bundle.txt | kubectl exec -i -n zero-trust-workload-identity-manager spire-server-0 -c spire-server -- \
  spire-server bundle set -format spiffe -id spiffe://apps.aagnihot-cluster-fdk.devcluster.openshift.com

echo "✅ Cluster 2's bundle loaded into Cluster 1"
```

### Step 4: Load Cluster 1's Bundle into Cluster 2

```bash
# Set KUBECONFIG to Cluster 2
export KUBECONFIG=/home/aagnihot/workspace/test/installer/4.20-installer/aws1/auth/kubeconfig

# Import Cluster 1's bundle into Cluster 2
cat /tmp/cluster1-test01-bundle.txt | kubectl exec -i -n zero-trust-workload-identity-manager spire-server-0 -c spire-server -- \
  spire-server bundle set -format spiffe -id spiffe://apps.aagnihot-cluster-povc.devcluster.openshift.com

echo "✅ Cluster 1's bundle loaded into Cluster 2"
```

## Verification

### Verify Federation on Cluster 1

```bash
export KUBECONFIG=/home/aagnihot/workspace/test/installer/4.20-installer/aws/auth/kubeconfig

# Check ClusterFederatedTrustDomain status
kubectl get clusterfederatedtrustdomain

# Check SPIRE server logs
kubectl logs -n zero-trust-workload-identity-manager spire-server-0 -c spire-server --tail=50

# Verify bundle list
kubectl exec -it -n zero-trust-workload-identity-manager spire-server-0 -c spire-server -- \
  spire-server bundle list
```

### Verify Federation on Cluster 2

```bash
export KUBECONFIG=/home/aagnihot/workspace/test/installer/4.20-installer/aws1/auth/kubeconfig

# Check ClusterFederatedTrustDomain status
kubectl get clusterfederatedtrustdomain

# Check SPIRE server logs
kubectl logs -n zero-trust-workload-identity-manager spire-server-0 -c spire-server --tail=50

# Verify bundle list
kubectl exec -it -n zero-trust-workload-identity-manager spire-server-0 -c spire-server -- \
  spire-server bundle list
```

### Expected Output

After successful federation, `spire-server bundle list` should show both bundles:

```
Found 2 bundles:

spiffe://apps.aagnihot-cluster-povc.devcluster.openshift.com (local)
	X.509 authorities: 1
	JWT authorities: 0
	Refresh hint: 300
	Sequence number: 1

spiffe://apps.aagnihot-cluster-fdk.devcluster.openshift.com (federated)
	X.509 authorities: 1
	JWT authorities: 0
	Refresh hint: 300
	Sequence number: 1
```

## Testing Federation

### Deploy Test Workloads

Create a test workload on each cluster and verify they can access federated identities:

```bash
# On Cluster 1
export KUBECONFIG=/home/aagnihot/workspace/test/installer/4.20-installer/aws/auth/kubeconfig
kubectl create namespace test-federation
kubectl run test-workload -n test-federation --image=ghcr.io/spiffe/spire-test-workload:latest --restart=Never

# On Cluster 2
export KUBECONFIG=/home/aagnihot/workspace/test/installer/4.20-installer/aws1/auth/kubeconfig
kubectl create namespace test-federation
kubectl run test-workload -n test-federation --image=ghcr.io/spiffe/spire-test-workload:latest --restart=Never
```

### Check Workload SVID

```bash
# On Cluster 1 - check the workload's SVID includes federated trust domains
export KUBECONFIG=/home/aagnihot/workspace/test/installer/4.20-installer/aws/auth/kubeconfig
kubectl exec -it -n zero-trust-workload-identity-manager spire-server-0 -c spire-server -- \
  spire-server entry show -selector k8s:ns:test-federation
```

## Troubleshooting

### Federation Route Not Working

Check if the routes are accessible:

```bash
# Test Cluster 1's federation endpoint
curl -vk https://spire-federation-test01.apps.aagnihot-cluster-povc.devcluster.openshift.com/.well-known/spiffe/bundle.json

# Test Cluster 2's federation endpoint
curl -vk https://spire-federation-test02.apps.aagnihot-cluster-fdk.devcluster.openshift.com/.well-known/spiffe/bundle.json
```

### Bundle Not Loading

If bundle loading fails, check:

1. **SPIRE Server Logs**:
   ```bash
   kubectl logs -n zero-trust-workload-identity-manager spire-server-0 -c spire-server
   ```

2. **ClusterFederatedTrustDomain Status**:
   ```bash
   kubectl get clusterfederatedtrustdomain -o yaml
   ```

3. **Network Connectivity**:
   - Ensure routes are accessible from within the cluster
   - Check firewall rules between clusters

### Controller Manager Issues

Check the SPIRE controller manager logs:

```bash
kubectl logs -n zero-trust-workload-identity-manager spire-server-0 -c spire-controller-manager
```

## Automatic Bundle Refresh

Once the initial trust bundles are loaded, the SPIRE Controller Manager will automatically:
- Refresh bundles from federated trust domains
- Update workload entries with federation information
- Handle bundle rotation

The default refresh interval is typically 5 minutes, but this is controlled by the SPIRE server configuration.

## References

- [SPIRE Federation Documentation](https://spiffe.io/docs/latest/spire-helm-charts-hardened-advanced/federation/)
- [SPIRE Server Configuration](https://spiffe.io/docs/latest/deploying/spire_server/)
- [ClusterFederatedTrustDomain API](https://github.com/spiffe/spire-controller-manager/blob/main/docs/clusterfederatedtrustdomain-crd.md)

## Summary

Federation has been successfully configured! You just need to complete the bundle bootstrapping steps above to establish the initial trust between the clusters.

