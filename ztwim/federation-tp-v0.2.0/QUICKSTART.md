# SPIRE Federation - Quick Start Guide

## One-Command Setup

Set up complete SPIRE federation between two OpenShift clusters:

```bash
cd federation
./setup-federation.sh <cluster1-kubeconfig> <cluster2-kubeconfig>
```

### Example

```bash
./setup-federation.sh \
  /home/user/cluster1/auth/kubeconfig \
  /home/user/cluster2/auth/kubeconfig
```

## What You Get

After running the script, you'll have:

✅ **Complete Federation Setup**
- SPIRE servers configured with federation bundle endpoints
- OpenShift Routes exposing federation endpoints (port 8443)
- Trust bundles exchanged between clusters
- Automatic bundle refresh configured

✅ **Demo Workloads Running**
- Namespace: `federation-demo` on both clusters
- Workloads with SPIFFE identities
- Access to SPIFFE Workload API
- Cross-cluster authentication enabled

✅ **Full Verification**
- Trust bundles from both clusters visible
- Workload entries with `federatesWith` configuration
- Complete status report

## Quick Verification

Verify federation is working:

```bash
./verify-federation.sh <cluster1-kubeconfig> <cluster2-kubeconfig>
```

## Files in This Directory

- **setup-federation.sh** - Main setup script (does everything)
- **verify-federation.sh** - Quick verification script
- **README.md** - Detailed documentation
- **QUICKSTART.md** - This file

## Time to Complete

- Setup: ~3-5 minutes
- Verification: ~30 seconds

## What Gets Configured

### On Both Clusters:

1. **SPIRE Server**
   - ConfigMap updated with federation endpoint (port 8443)
   - Service patched to expose federation port
   - StatefulSet updated with federation port
   - Pods restarted with new configuration

2. **Federation**
   - Route created: `spire-federation-<cluster-name>.<apps-domain>`
   - ClusterFederatedTrustDomain created
   - Trust bundles bootstrapped
   - ClusterSPIFFEID with federatesWith created

3. **Demo Workloads**
   - Namespace: `federation-demo`
   - Deployment with SPIFFE Workload API access
   - Service Account for workload identity

## Output Example

```
================================================
SPIRE Federation Setup
================================================

[STEP 1/15] Gathering cluster information
✓ Cluster 1: test01 (Trust Domain: apps.cluster1.example.com)
✓ Cluster 2: test02 (Trust Domain: apps.cluster2.example.com)

[STEP 2/15] Updating SPIRE Server ConfigMap on Cluster 1
✓ Cluster 1 ConfigMap updated

...

================================================
✅ Federation Setup Complete!
================================================

Cluster 1 (test01)
  Trust Domain: apps.cluster1.example.com
  Federation URL: https://spire-federation-test01.apps.cluster1.example.com
  Federates With: apps.cluster2.example.com

Cluster 2 (test02)
  Trust Domain: apps.cluster2.example.com
  Federation URL: https://spire-federation-test02.apps.cluster2.example.com
  Federates With: apps.cluster1.example.com
```

## What's Next?

### Deploy Your Own Workloads

Create a ClusterSPIFFEID for your application:

```yaml
apiVersion: spire.spiffe.io/v1alpha1
kind: ClusterSPIFFEID
metadata:
  name: my-app
spec:
  spiffeIDTemplate: "spiffe://{{ .TrustDomain }}/app/my-app"
  namespaceSelector:
    matchLabels:
      app: my-app
  federatesWith:
    - apps.other-cluster.example.com  # Remote trust domain
  className: zero-trust-workload-identity-manager-spire
```

### Use SPIFFE in Your Application

Your application can access SPIFFE credentials via the Workload API:

1. **Mount the socket**:
   ```yaml
   volumeMounts:
   - name: spiffe-workload-api
     mountPath: /spiffe-workload-api
   volumes:
   - name: spiffe-workload-api
     csi:
       driver: csi.spiffe.io
   ```

2. **Use SPIFFE libraries**:
   - Go: [go-spiffe](https://github.com/spiffe/go-spiffe)
   - Java: [java-spiffe](https://github.com/spiffe/java-spiffe)
   - Python: [py-spiffe](https://github.com/spiffe/py-spiffe)

### Implement mTLS

Workloads can now establish mTLS connections across clusters:

```go
// Example with go-spiffe
source, err := workloadapi.NewX509Source(ctx)
svid, err := source.GetX509SVID()

// Use SVID for mTLS
tlsConfig := tlsconfig.MTLSClientConfig(source, source, tlsconfig.AuthorizeAny())
```

## Troubleshooting

### Script Fails

1. Check prerequisites:
   ```bash
   kubectl version
   jq --version
   ```

2. Verify cluster access:
   ```bash
   kubectl --kubeconfig=<path> get nodes
   ```

3. Check SPIRE installation:
   ```bash
   kubectl --kubeconfig=<path> get spireserver cluster
   ```

### Federation Not Working

Run verification script:
```bash
./verify-federation.sh <cluster1-kubeconfig> <cluster2-kubeconfig>
```

Check trust bundles:
```bash
kubectl exec -n zero-trust-workload-identity-manager spire-server-0 -c spire-server -- \
  /spire-server bundle list
```

### Need Help?

See detailed documentation in **README.md**

## Re-running the Script

Safe to re-run anytime - it's idempotent:
```bash
./setup-federation.sh <cluster1-kubeconfig> <cluster2-kubeconfig>
```

## Clean Up

Remove federation:
```bash
kubectl delete namespace federation-demo
kubectl delete clusterspiffeid federation-demo-workload
kubectl delete clusterfederatedtrustdomain <name>
kubectl delete route spire-server-federation -n zero-trust-workload-identity-manager
```

---

**That's it!** You now have full SPIRE federation between two OpenShift clusters. 🎉

