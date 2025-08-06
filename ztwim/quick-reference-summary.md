# SPIRE OIDC & OpenShift Certificate Management - Quick Reference

## 🎯 **Final Solution Summary**

**Problem**: SPIRE OIDC Discovery Provider with trusted certificates in OpenShift  
**Solution**: Red Hat's Default Ingress Certificate Replacement approach

### **Key Commands (Production-Ready)**

#### 1. Fix OIDC Provider Pod (if stuck)
```bash
# Create SPIFFE workload entry
spire-server entry create \
  -spiffeID spiffe://example.org/ns/zero-trust-workload-identity-manager/sa/spire-spiffe-oidc-discovery-provider \
  -parentID spiffe://example.org/spire/agent/k8s_psat/demo-cluster/NODE_ID \
  -selector k8s:ns:zero-trust-workload-identity-manager \
  -selector k8s:sa:spire-spiffe-oidc-discovery-provider
```

#### 2. Configure OIDC Provider for Service CA
```bash
# Patch ConfigMap to use Service CA certificates
kubectl patch configmap spire-spiffe-oidc-discovery-provider \
  -n zero-trust-workload-identity-manager --type='json' \
  -p='[{"op": "replace", "path": "/data/oidc-discovery-provider.conf", "value": "trust_domain = \"example.org\"\n\nserving_cert_file = {\n  addr = \":8443\"\n  cert_file_path = \"/etc/oidc/tls/tls.crt\"\n  key_file_path = \"/etc/oidc/tls/tls.key\"\n}\n\nworkload_api = {\n  socket_path = \"/run/spire/oidc-sockets/spire-agent.sock\"\n}\n\ndomains = [\"oidc-discovery.apps.YOUR-CLUSTER.com\"]"}]'

# Add Service CA annotation
kubectl annotate service spire-spiffe-oidc-discovery-provider \
  -n zero-trust-workload-identity-manager \
  service.beta.openshift.io/serving-cert-secret-name=oidc-tls
```

#### 3. Setup cert-manager with Let's Encrypt
```bash
# Create production ClusterIssuer
oc apply -f letsencrypt-clusterissuer.yaml

# Request certificate
oc apply -f oidc-letsencrypt-certificate.yaml
```

#### 4. Replace Default Ingress Certificate (🏆 **BEST APPROACH**)
```bash
# Extract certificates
kubectl get secret oidc-discovery-letsencrypt-tls -n zero-trust-workload-identity-manager -o jsonpath='{.data.tls\.crt}' | base64 -d > /tmp/letsencrypt-full-chain.crt
kubectl get secret oidc-discovery-letsencrypt-tls -n zero-trust-workload-identity-manager -o jsonpath='{.data.tls\.key}' | base64 -d > /tmp/letsencrypt.key
awk '/-----BEGIN CERTIFICATE-----/{cert++} cert==2{print}' /tmp/letsencrypt-full-chain.crt > /tmp/letsencrypt-root-ca.crt

# Create custom CA configmap
oc create configmap custom-ca \
     --from-file=ca-bundle.crt=/tmp/letsencrypt-root-ca.crt \
     -n openshift-config

# Update proxy configuration
oc patch proxy/cluster \
     --type=merge \
     --patch='{"spec":{"trustedCA":{"name":"custom-ca"}}}'

# Create ingress secret
oc create secret tls letsencrypt-wildcard \
     --cert=/tmp/letsencrypt-full-chain.crt \
     --key=/tmp/letsencrypt.key \
     -n openshift-ingress

# Update ingress controller
oc patch ingresscontroller.operator default \
     --type=merge -p \
     '{"spec":{"defaultCertificate": {"name": "letsencrypt-wildcard"}}}' \
     -n openshift-ingress-operator

# Cleanup
rm -f /tmp/letsencrypt*.crt /tmp/letsencrypt*.key
```

#### 5. Create Ultra-Simple Route
```bash
# No certificates needed - inherits from default ingress!
oc create route reencrypt oidc-simple \
  --service=spire-spiffe-oidc-discovery-provider \
  --port=https \
  --hostname=oidc-discovery.apps.YOUR-CLUSTER.com \
  -n zero-trust-workload-identity-manager
```

### **Verification Commands**
```bash
# Test OIDC endpoint
curl https://oidc-discovery.apps.YOUR-CLUSTER.com/.well-known/openid-configuration

# Verify certificate
openssl s_client -connect oidc-discovery.apps.YOUR-CLUSTER.com:443 -servername oidc-discovery.apps.YOUR-CLUSTER.com < /dev/null 2>&1 | grep "Certificate chain"

# Check route (notice how simple it is!)
kubectl get route oidc-simple -n zero-trust-workload-identity-manager -o yaml
```

---

## 🚀 **Why This Approach Wins**

| Aspect | Manual Route Certs | destinationCACertificate | **Default Ingress (Winner)** |
|--------|-------------------|------------------------|------------------------------|
| **Complexity** | High | Medium | **🏆 Low** |
| **Maintenance** | Per-route | Per-route | **🏆 Cluster-wide** |
| **New Apps** | Manual setup | Manual setup | **🏆 Automatic** |
| **Red Hat Support** | ❌ Custom | 🟡 Partial | **🏆 Full Official** |
| **Route Config** | Complex YAML | Medium YAML | **🏆 Minimal** |

### **Final Route Configuration (Ultra-Simple!)**
```yaml
spec:
  host: oidc-discovery.apps.cluster.com
  tls:
    termination: reencrypt  # That's it! No certificates!
  to:
    kind: Service
    name: spire-spiffe-oidc-discovery-provider
```

---

## 🔧 **Troubleshooting Quick Fixes**

### Pod Stuck in Init
```bash
# Missing workload entry - create one
spire-server entry create -spiffeID spiffe://DOMAIN/ns/NS/sa/SA -parentID spiffe://DOMAIN/spire/agent/k8s_psat/CLUSTER/NODE -selector k8s:ns:NS -selector k8s:sa:SA
```

### TLS Handshake Errors
```bash
# Switch to Service CA certificates (not SPIFFE certs) for re-encrypt routes
kubectl annotate service SERVICE_NAME service.beta.openshift.io/serving-cert-secret-name=tls-secret
```

### Certificate Not Applied
```bash
# Force router reload
oc rollout restart deployment/router-default -n openshift-ingress
```

### ACME Failures
```bash
# Use valid email (not @example.com)
oc patch clusterissuer letsencrypt-prod --type='json' -p='[{"op": "replace", "path": "/spec/acme/email", "value": "real@email.com"}]'
```

---

## 📋 **Journey Evolution**

1. **Problem**: Pod stuck → Fixed with SPIFFE workload entry
2. **Challenge**: Re-encrypt not working → Discovered OpenShift router trust model
3. **Workaround**: Passthrough worked → But bypassed certificate management
4. **Solution**: Service CA integration → Re-encrypt worked with implicit trust
5. **Enhancement**: cert-manager + Let's Encrypt → Trusted certificates
6. **Optimization**: Per-route certificate management → Complex and unmaintainable
7. **🏆 Final**: Default ingress replacement → **Red Hat official, simple, scalable**

---

## 🎯 **Key Insights Learned**

### **OpenShift Router Trust**
- **Service CA certificates** → Automatically trusted for re-encrypt
- **SPIFFE certificates** → Work with passthrough only
- **Default ingress certificate** → Inherited by all routes automatically

### **Certificate Management Evolution**
- **Individual route certs** → ❌ High complexity
- **destinationCACertificate** → 🟡 Better but still per-route
- **Default ingress replacement** → ✅ **Enterprise-grade solution**

### **Red Hat Documentation**
- **Following official docs** → Most maintainable approach
- **Custom solutions** → May work but lack support
- **Platform-level capabilities** → Always preferred over app-level hacks

---

## 📖 **Complete Documentation**
See `complete-spire-oidc-openshift-guide.md` for the full 800+ line comprehensive guide covering every step of our journey.

---

**🚀 Result**: Production-ready SPIRE OIDC Discovery Provider with trusted Let's Encrypt certificates, using Red Hat's official approach with ultra-simple route configuration! 