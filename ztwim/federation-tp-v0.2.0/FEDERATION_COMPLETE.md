# ✅ SPIRE Federation Successfully Configured!

## Summary

SPIRE federation has been successfully set up between your two OpenShift clusters! The clusters can now establish mutual trust and workloads can securely communicate across cluster boundaries.

## Cluster Configuration

### Cluster 1 (test01)
- **Trust Domain**: `apps.aagnihot-cluster-povc.devcluster.openshift.com`
- **Federation Endpoint**: `https://spire-federation-test01.apps.aagnihot-cluster-povc.devcluster.openshift.com`
- **SPIFFE ID**: `spiffe://apps.aagnihot-cluster-povc.devcluster.openshift.com/spire/server`
- **Status**: ✅ Federated with Cluster 2

### Cluster 2 (test02)
- **Trust Domain**: `apps.aagnihot-cluster-fdk.devcluster.openshift.com`
- **Federation Endpoint**: `https://spire-federation-test02.apps.aagnihot-cluster-fdk.devcluster.openshift.com`
- **SPIFFE ID**: `spiffe://apps.aagnihot-cluster-fdk.devcluster.openshift.com/spire/server`
- **Status**: ✅ Federated with Cluster 1

## What Was Configured

### 1. Federation Routes ✅
Exposed SPIRE Server bundle endpoints on both clusters using OpenShift Routes with passthrough TLS termination.

**Files Created:**
- `federation-cluster1-route.yaml`
- `federation-cluster2-route.yaml`

### 2. ClusterFederatedTrustDomain Resources ✅
Configured trust relationships between the clusters using the `https_spiffe` profile for secure bundle exchange.

**Files Created:**
- `federation-cluster1-trustdomain.yaml` (Cluster 1 trusts Cluster 2)
- `federation-cluster2-trustdomain.yaml` (Cluster 2 trusts Cluster 1)

### 3. ClusterSPIFFEID Resources ✅
Configured workload identities with federation enabled, allowing workloads to receive federated trust bundles.

**Files Created:**
- `federation-cluster1-spiffeid.yaml`
- `federation-cluster2-spiffeid.yaml`

The `default-federated` ClusterSPIFFEID resources configure:
- Automatic SPIFFE ID assignment to workloads
- Federation with the remote cluster's trust domain
- Workload selectors based on namespace and service account
- DNS name templates for service discovery

### 4. Trust Bundle Bootstrap ✅
Successfully exchanged trust bundles between both clusters:
- Exported trust bundle from Cluster 1
- Exported trust bundle from Cluster 2
- Loaded Cluster 2's bundle into Cluster 1
- Loaded Cluster 1's bundle into Cluster 2

**Script Created:** `bootstrap-federation.sh`

## Current Status

```bash
# On Cluster 1
ClusterFederatedTrustDomain: test02-federation (Active)
ClusterSPIFFEID: default-federated (Active)

# On Cluster 2
ClusterFederatedTrustDomain: test01-federation (Active)
ClusterSPIFFEID: default-federated (Active)
```

## Verification Commands

### Check Federation Status

**On Cluster 1:**
```bash
export KUBECONFIG=/home/aagnihot/workspace/test/installer/4.20-installer/aws/auth/kubeconfig

# View federated trust domains
kubectl get clusterfederatedtrustdomain

# View trust bundles
kubectl exec -n zero-trust-workload-identity-manager spire-server-0 -c spire-server -- \
  /spire-server bundle list

# View workload identities
kubectl get clusterspiffeid
```

**On Cluster 2:**
```bash
export KUBECONFIG=/home/aagnihot/workspace/test/installer/4.20-installer/aws1/auth/kubeconfig

# View federated trust domains
kubectl get clusterfederatedtrustdomain

# View trust bundles
kubectl exec -n zero-trust-workload-identity-manager spire-server-0 -c spire-server -- \
  /spire-server bundle list

# View workload identities
kubectl get clusterspiffeid
```

### Monitor SPIRE Server Logs

**Cluster 1:**
```bash
export KUBECONFIG=/home/aagnihot/workspace/test/installer/4.20-installer/aws/auth/kubeconfig
kubectl logs -n zero-trust-workload-identity-manager spire-server-0 -c spire-server --tail=50 -f
```

**Cluster 2:**
```bash
export KUBECONFIG=/home/aagnihot/workspace/test/installer/4.20-installer/aws1/auth/kubeconfig
kubectl logs -n zero-trust-workload-identity-manager spire-server-0 -c spire-server --tail=50 -f
```

## How Federation Works

1. **Automatic Bundle Refresh**: The SPIRE Controller Manager automatically refreshes trust bundles from federated trust domains every few minutes.

2. **Workload Identity Assignment**: When a pod is created in a namespace (excluding system namespaces), it automatically receives:
   - A SPIFFE ID based on its namespace and service account
   - Trust bundles from both local and federated trust domains
   - X.509 SVIDs for mTLS authentication

3. **Cross-Cluster Trust**: Workloads in Cluster 1 can authenticate and trust workloads in Cluster 2, and vice versa, using their SPIFFE identities.

## Testing Federation

### Example: Deploy Test Workloads

Create test workloads on both clusters to verify federation:

```bash
# On Cluster 1
export KUBECONFIG=/home/aagnihot/workspace/test/installer/4.20-installer/aws/auth/kubeconfig
kubectl create namespace test-federation
kubectl run test-workload -n test-federation --image=alpine:latest --command -- sleep 3600

# On Cluster 2
export KUBECONFIG=/home/aagnihot/workspace/test/installer/4.20-installer/aws1/auth/kubeconfig
kubectl create namespace test-federation
kubectl run test-workload -n test-federation --image=alpine:latest --command -- sleep 3600
```

### Verify Workload SVID

Check that workloads receive federated trust bundles:

```bash
# On Cluster 1
export KUBECONFIG=/home/aagnihot/workspace/test/installer/4.20-installer/aws/auth/kubeconfig
kubectl exec -n zero-trust-workload-identity-manager spire-server-0 -c spire-server -- \
  /spire-server entry show -selector k8s:ns:test-federation
```

### Access SPIFFE Workload API

Workloads can access their SVID through the SPIFFE Workload API socket at:
`unix:///spiffe-workload-api/spire-agent.sock`

This requires mounting the SPIFFE CSI Driver volume. See the [SPIFFE CSI Driver documentation](https://github.com/spiffe/spiffe-csi) for details.

## Maintenance

### Bundle Rotation

Trust bundles are automatically rotated by SPIRE. The federation configuration ensures that:
- New certificates are automatically propagated between clusters
- Old certificates remain valid during the rotation period
- No manual intervention is required

### Monitoring Federation Health

Watch for these indicators of healthy federation:

1. **Bundle List Shows Both Domains**:
   ```bash
   kubectl exec -n zero-trust-workload-identity-manager spire-server-0 -c spire-server -- \
     /spire-server bundle list
   ```
   Should show both local and federated bundles.

2. **No Errors in Logs**:
   ```bash
   kubectl logs -n zero-trust-workload-identity-manager spire-server-0 -c spire-server | grep -i error
   ```

3. **ClusterFederatedTrustDomain Resources Exist**:
   ```bash
   kubectl get clusterfederatedtrustdomain
   ```

## Troubleshooting

If federation stops working:

1. **Check Route Accessibility**:
   ```bash
   curl -vk https://spire-federation-test01.apps.aagnihot-cluster-povc.devcluster.openshift.com/.well-known/spiffe/bundle.json
   curl -vk https://spire-federation-test02.apps.aagnihot-cluster-fdk.devcluster.openshift.com/.well-known/spiffe/bundle.json
   ```

2. **Re-run Bootstrap Script**:
   ```bash
   /home/aagnihot/workspace/downstream/openshift-zero-trust-workload-identity-manager/bootstrap-federation.sh
   ```

3. **Check Controller Manager**:
   ```bash
   kubectl logs -n zero-trust-workload-identity-manager spire-server-0 -c spire-controller-manager
   ```

## Files Reference

All federation configuration files are located in:
`/home/aagnihot/workspace/downstream/openshift-zero-trust-workload-identity-manager/`

- **federation-cluster1-route.yaml** - Route for Cluster 1's federation endpoint
- **federation-cluster2-route.yaml** - Route for Cluster 2's federation endpoint
- **federation-cluster1-trustdomain.yaml** - Trust domain config for Cluster 1
- **federation-cluster2-trustdomain.yaml** - Trust domain config for Cluster 2
- **federation-cluster1-spiffeid.yaml** - Workload identity config for Cluster 1
- **federation-cluster2-spiffeid.yaml** - Workload identity config for Cluster 2
- **bootstrap-federation.sh** - Script to bootstrap trust bundles
- **FEDERATION_SETUP.md** - Detailed setup guide
- **FEDERATION_COMPLETE.md** - This completion summary

## Next Steps

Now that federation is configured, you can:

1. **Deploy Multi-Cluster Applications**: Applications can now securely communicate across clusters using SPIFFE identities.

2. **Implement Service Mesh**: Use federation with service meshes like Istio or Linkerd for secure cross-cluster communication.

3. **Configure Workload-Specific Identities**: Create additional ClusterSPIFFEID resources for specific workloads with custom SPIFFE ID templates.

4. **Monitor and Audit**: Use SPIRE's telemetry and logging to monitor identity issuance and usage across clusters.

## References

- [SPIRE Federation Documentation](https://spiffe.io/docs/latest/spire-helm-charts-hardened-advanced/federation/)
- [SPIFFE Standard](https://github.com/spiffe/spiffe/blob/main/standards/SPIFFE.md)
- [SPIRE Architecture](https://spiffe.io/docs/latest/spire-about/spire-concepts/)
- [OpenShift Zero Trust Workload Identity Manager](https://github.com/openshift/zero-trust-workload-identity-manager)

## Support

For issues or questions:
- Check the SPIRE logs on both clusters
- Review the ClusterFederatedTrustDomain and ClusterSPIFFEID status
- Consult the SPIFFE/SPIRE community documentation

---

**🎉 Congratulations! Your SPIRE federation is now fully operational!**

