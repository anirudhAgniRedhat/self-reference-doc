# Federation Directory - File Index

This directory contains everything you need for end-to-end SPIRE federation setup between OpenShift clusters.

## 📁 Files

### 🚀 Main Setup Script
- **`setup-federation.sh`** ⭐ **START HERE**
  - Complete end-to-end federation setup
  - Takes 2 kubeconfig paths as input
  - Configures everything automatically
  - Deploys demo workloads
  - Shows verification results
  - **Runtime**: 3-5 minutes

### ✅ Verification Script  
- **`verify-federation.sh`**
  - Quick federation status check
  - Shows trust bundles on both clusters
  - Displays workload entries
  - Verifies demo workloads
  - **Runtime**: 30 seconds

### 📖 Documentation
- **`QUICKSTART.md`** - Quick start guide (read this first!)
- **`README.md`** - Complete detailed documentation
- **`INDEX.md`** - This file

## 🎯 Quick Start

```bash
# 1. Setup federation (one command!)
./setup-federation.sh <cluster1-kubeconfig> <cluster2-kubeconfig>

# 2. Verify it's working
./verify-federation.sh <cluster1-kubeconfig> <cluster2-kubeconfig>
```

## 📋 What the Setup Script Does

### Phase 1: Configuration (Steps 1-7)
1. Gather cluster information (names, trust domains, routes)
2. Update SPIRE Server ConfigMaps with federation config
3. Patch Services to expose port 8443
4. Patch StatefulSets to add federation port to pods
5. Wait for pods to restart

### Phase 2: Federation (Steps 8-13)
6. Create federation Routes on both clusters
7. Create ClusterFederatedTrustDomain resources
8. Bootstrap trust bundle exchange

### Phase 3: Workload Setup (Steps 14-15)
9. Create ClusterSPIFFEID resources with federatesWith
10. Deploy demo workloads in `federation-demo` namespace

### Phase 4: Verification
11. Show trust bundles on both clusters
12. Display workload entries with federation
13. Show demo workload status
14. Print complete summary

## ✨ Features

- ✅ **Fully Automated** - No manual steps required
- ✅ **Idempotent** - Safe to re-run multiple times
- ✅ **Colored Output** - Easy to follow progress
- ✅ **Error Handling** - Fails gracefully with clear messages
- ✅ **Complete Verification** - Shows everything is working
- ✅ **Production Ready** - Uses https_spiffe (secure by default)

## 📊 Output Format

The script uses colored output:
- 🔵 **Blue** - Headers and sections
- 🟢 **Green** - Success messages
- 🟡 **Yellow** - Information messages
- 🔴 **Red** - Errors (if any)
- 🟦 **Cyan** - Step progress

## 🎓 Example Session

```bash
$ ./setup-federation.sh cluster1.kubeconfig cluster2.kubeconfig

================================================
SPIRE Federation Setup
================================================

ℹ Cluster 1 kubeconfig: cluster1.kubeconfig
ℹ Cluster 2 kubeconfig: cluster2.kubeconfig

[STEP 1/15] Gathering cluster information
✓ Cluster 1: test01 (Trust Domain: apps.cluster1.example.com)
✓ Cluster 2: test02 (Trust Domain: apps.cluster2.example.com)

[STEP 2/15] Updating SPIRE Server ConfigMap on Cluster 1
✓ Cluster 1 ConfigMap updated

... (steps 3-15) ...

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

✅ Demo workloads deployed and running
✅ Workloads have access to SPIFFE Workload API
✅ Cross-cluster authentication is enabled
```

## 🔍 What Gets Created

### Cluster-Wide Resources (both clusters):
- `Route`: spire-server-federation (federation endpoint)
- `ClusterFederatedTrustDomain`: Trust relationship configuration
- `ClusterSPIFFEID`: federation-demo-workload (federated identity)

### Namespace Resources (both clusters):
- `Namespace`: federation-demo
- `ServiceAccount`: demo-workload
- `Deployment`: demo-workload (demo pod)

### Configuration Updates (both clusters):
- `ConfigMap`: spire-server (federation endpoint config)
- `Service`: spire-server (port 8443 added)
- `StatefulSet`: spire-server (container port 8443 added)

## 🔧 Requirements

- Two OpenShift clusters with Zero Trust Workload Identity Manager
- `kubectl` configured
- `jq` installed
- Cluster-admin access

## 📚 Learn More

- **Quick Start**: See `QUICKSTART.md`
- **Full Documentation**: See `README.md`
- **SPIRE Docs**: https://spiffe.io/docs/

## 🆘 Need Help?

1. **Check verification**:
   ```bash
   ./verify-federation.sh <cluster1> <cluster2>
   ```

2. **View trust bundles**:
   ```bash
   kubectl exec -n zero-trust-workload-identity-manager spire-server-0 -c spire-server -- \
     /spire-server bundle list
   ```

3. **Check workload entries**:
   ```bash
   kubectl exec -n zero-trust-workload-identity-manager spire-server-0 -c spire-server -- \
     /spire-server entry show
   ```

4. **View logs**:
   ```bash
   kubectl logs -n zero-trust-workload-identity-manager spire-server-0 -c spire-server
   ```

## 🎉 Success Indicators

Federation is working when you see:
- ✅ Trust bundles from both clusters in `bundle list`
- ✅ Workload entries with `FederatesWith` configuration
- ✅ Demo workloads running with SPIFFE Workload API access
- ✅ No errors in SPIRE server logs

## 🧹 Clean Up

To remove all federation components:

```bash
# On both clusters
kubectl delete namespace federation-demo
kubectl delete clusterspiffeid federation-demo-workload
kubectl delete clusterfederatedtrustdomain <federation-name>
kubectl delete route spire-server-federation -n zero-trust-workload-identity-manager
```

---

**Ready to start?** Run: `./setup-federation.sh <cluster1> <cluster2>` 🚀

