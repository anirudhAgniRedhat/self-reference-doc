# OpenShift Default Ingress Certificate Replacement - Red Hat Approach

## Overview

This document shows how to implement the **Red Hat recommended approach** for using trusted certificates with OpenShift routes by replacing the **default ingress certificate** at the cluster level. This approach follows the [Red Hat OpenShift documentation](https://docs.redhat.com/en/documentation/openshift_container_platform/4.11/html/security_and_compliance/configuring-certificates#replacing-default-ingress) exactly.

## Key Benefits

- ✅ **Cluster-wide**: All applications under `.apps` subdomain get trusted certificates automatically
- ✅ **Simple Routes**: No need to specify certificates in individual routes
- ✅ **Red Hat Official**: Follows official OpenShift documentation precisely
- ✅ **Maintainable**: Single point of certificate management
- ✅ **Automatic**: New routes automatically inherit trusted certificates

## Architecture

```
Client → HAProxy Router → Backend Service
   ↓           ↓              ↓
[HTTPS]   [Default Ingress]  [Service CA TLS]
          [Let's Encrypt]    [Auto-trusted]
          [✅ CLUSTER-WIDE]  [✅ RE-ENCRYPT]
```

## Prerequisites

- OpenShift cluster with cert-manager
- Let's Encrypt certificate for your domain
- Administrative access to the cluster

## Implementation Steps

### Step 1: Extract Root CA from Let's Encrypt Certificate

```bash
# Get the full certificate chain
kubectl get secret oidc-discovery-letsencrypt-tls -n zero-trust-workload-identity-manager -o jsonpath='{.data.tls\.crt}' | base64 -d > /tmp/letsencrypt-full-chain.crt

# Extract the root CA certificate (last certificate in the chain)
awk '/-----BEGIN CERTIFICATE-----/{cert++} cert==2{print}' /tmp/letsencrypt-full-chain.crt > /tmp/letsencrypt-root-ca.crt

# Verify the root CA
openssl x509 -in /tmp/letsencrypt-root-ca.crt -text -noout | grep "Issuer:"
```

Expected output:
```
Issuer: C=US, O=Internet Security Research Group, CN=ISRG Root X1
```

### Step 2: Create ConfigMap with Root CA Certificate

Following Red Hat documentation exactly:

```bash
oc create configmap custom-ca \
     --from-file=ca-bundle.crt=/tmp/letsencrypt-root-ca.crt \
     -n openshift-config
```

### Step 3: Update Cluster-wide Proxy Configuration

```bash
oc patch proxy/cluster \
     --type=merge \
     --patch='{"spec":{"trustedCA":{"name":"custom-ca"}}}'
```

### Step 4: Create Secret with Wildcard Certificate

```bash
# Extract the private key
kubectl get secret oidc-discovery-letsencrypt-tls -n zero-trust-workload-identity-manager -o jsonpath='{.data.tls\.key}' | base64 -d > /tmp/letsencrypt.key

# Create the TLS secret in openshift-ingress namespace
oc create secret tls letsencrypt-wildcard \
     --cert=/tmp/letsencrypt-full-chain.crt \
     --key=/tmp/letsencrypt.key \
     -n openshift-ingress
```

### Step 5: Update Ingress Controller Configuration

```bash
oc patch ingresscontroller.operator default \
     --type=merge -p \
     '{"spec":{"defaultCertificate": {"name": "letsencrypt-wildcard"}}}' \
     -n openshift-ingress-operator
```

### Step 6: Create Simple Re-encrypt Route

Now you can create extremely simple routes without any certificate configuration:

```bash
oc create route reencrypt oidc-simple \
  --service=spire-spiffe-oidc-discovery-provider \
  --port=https \
  --hostname=oidc-discovery.apps.aagnihot-custer-kdbs.devcluster.openshift.com \
  -n zero-trust-workload-identity-manager
```

## Verification

### Test the Endpoint
```bash
curl https://oidc-discovery.apps.aagnihot-custer-kdbs.devcluster.openshift.com/.well-known/openid-configuration
```

### Verify Certificate Chain
```bash
openssl s_client -connect oidc-discovery.apps.aagnihot-custer-kdbs.devcluster.openshift.com:443 -servername oidc-discovery.apps.aagnihot-custer-kdbs.devcluster.openshift.com < /dev/null 2>&1 | grep -A 3 "Certificate chain"
```

Expected output:
```
Certificate chain
 0 s:
   i:C=US, O=Let's Encrypt, CN=R10
   a:PKEY: rsaEncryption, 2048 (bit); sigalg: RSA-SHA256
```

### Check Route Configuration
```bash
kubectl get route oidc-simple -n zero-trust-workload-identity-manager -o yaml
```

Notice how simple the route is - **no certificate configuration needed**:

```yaml
spec:
  host: oidc-discovery.apps.aagnihot-custer-kdbs.devcluster.openshift.com
  port:
    targetPort: https
  tls:
    termination: reencrypt  # No certificate, key, or destinationCACertificate needed!
  to:
    kind: Service
    name: spire-spiffe-oidc-discovery-provider
    weight: 100
```

## Key Differences from Previous Approaches

| Aspect | Individual Route Certs | destinationCACertificate | **Default Ingress (Red Hat)** |
|--------|----------------------|------------------------|------------------------------|
| **Configuration** | Per-route certificate | Per-route + destination CA | **Cluster-wide default** |
| **Maintenance** | Multiple certificates | Multiple configurations | **Single point of management** |
| **New Routes** | Manual certificate setup | Manual certificate setup | **Automatic inheritance** |
| **Documentation** | Custom approach | Partial Red Hat approach | **Full Red Hat compliance** |
| **Complexity** | High | Medium | **Low** |

## Benefits of This Approach

### ✅ **Cluster-wide Coverage**
- **All applications** under `.apps` subdomain automatically get trusted certificates
- **Web console and CLI** also benefit from the trusted certificate
- **New applications** automatically inherit the certificate

### ✅ **Simplified Route Management**
- **No certificate configuration** needed in individual routes
- **Clean YAML** with minimal configuration
- **Easy to maintain** and audit

### ✅ **Red Hat Official Approach**
- **Follows documentation exactly** - no custom interpretations
- **Supported configuration** with official backing
- **Production-ready** and tested approach

### ✅ **Operational Benefits**
- **Single certificate renewal** affects entire cluster
- **Centralized certificate management**
- **Reduced configuration drift**

## Certificate Management

### Automatic Renewal
The cert-manager will continue to renew the Let's Encrypt certificate automatically. When renewed:

1. **Update the secret** in `openshift-ingress` namespace:
```bash
# Get new certificate
kubectl get secret oidc-discovery-letsencrypt-tls -n zero-trust-workload-identity-manager -o jsonpath='{.data.tls\.crt}' | base64 -d > /tmp/new-cert.crt
kubectl get secret oidc-discovery-letsencrypt-tls -n zero-trust-workload-identity-manager -o jsonpath='{.data.tls\.key}' | base64 -d > /tmp/new-key.key

# Update the ingress secret
oc create secret tls letsencrypt-wildcard \
     --cert=/tmp/new-cert.crt \
     --key=/tmp/new-key.key \
     -n openshift-ingress \
     --dry-run=client -o yaml | oc replace -f -
```

2. **Ingress controller automatically reloads** the new certificate

### Rollback Procedure
If needed, you can rollback to OpenShift's default certificates:

```bash
# Remove the default certificate configuration
oc patch ingresscontroller.operator default \
     --type=json \
     -p='[{"op": "remove", "path": "/spec/defaultCertificate"}]' \
     -n openshift-ingress-operator

# Remove the custom CA from proxy
oc patch proxy/cluster \
     --type=json \
     -p='[{"op": "remove", "path": "/spec/trustedCA"}]'
```

## Troubleshooting

### Certificate Not Applied
If routes don't show the new certificate:

1. **Check ingress controller status**:
```bash
oc get ingresscontroller default -n openshift-ingress-operator -o yaml
```

2. **Verify secret exists**:
```bash
oc get secret letsencrypt-wildcard -n openshift-ingress
```

3. **Check router pods**:
```bash
oc get pods -n openshift-ingress
oc logs -n openshift-ingress deployment/router-default
```

### Router Not Reloading
Force router reload:

```bash
oc rollout restart deployment/router-default -n openshift-ingress
```

## Security Considerations

### Certificate Scope
- **Wildcard certificate** covers all subdomains under `.apps`
- **Root CA trust** is added cluster-wide
- **All applications** inherit the certificate automatically

### Access Control
- **Secret in openshift-ingress** namespace requires cluster-admin access
- **Ingress controller configuration** requires elevated privileges
- **Certificate rotation** should be automated to reduce manual access

## Complete Example Script

```bash
#!/bin/bash
# Complete script to replace default ingress certificate with Let's Encrypt

set -e

NAMESPACE="zero-trust-workload-identity-manager"
SECRET_NAME="oidc-discovery-letsencrypt-tls"

echo "Step 1: Extract certificates..."
kubectl get secret $SECRET_NAME -n $NAMESPACE -o jsonpath='{.data.tls\.crt}' | base64 -d > /tmp/letsencrypt-full-chain.crt
kubectl get secret $SECRET_NAME -n $NAMESPACE -o jsonpath='{.data.tls\.key}' | base64 -d > /tmp/letsencrypt.key
awk '/-----BEGIN CERTIFICATE-----/{cert++} cert==2{print}' /tmp/letsencrypt-full-chain.crt > /tmp/letsencrypt-root-ca.crt

echo "Step 2: Create custom CA configmap..."
oc create configmap custom-ca \
     --from-file=ca-bundle.crt=/tmp/letsencrypt-root-ca.crt \
     -n openshift-config --dry-run=client -o yaml | oc apply -f -

echo "Step 3: Update proxy configuration..."
oc patch proxy/cluster \
     --type=merge \
     --patch='{"spec":{"trustedCA":{"name":"custom-ca"}}}'

echo "Step 4: Create ingress secret..."
oc create secret tls letsencrypt-wildcard \
     --cert=/tmp/letsencrypt-full-chain.crt \
     --key=/tmp/letsencrypt.key \
     -n openshift-ingress --dry-run=client -o yaml | oc apply -f -

echo "Step 5: Update ingress controller..."
oc patch ingresscontroller.operator default \
     --type=merge -p \
     '{"spec":{"defaultCertificate": {"name": "letsencrypt-wildcard"}}}' \
     -n openshift-ingress-operator

echo "Step 6: Cleanup..."
rm -f /tmp/letsencrypt*.crt /tmp/letsencrypt*.key

echo "✅ Default ingress certificate replaced successfully!"
echo "All routes under .apps subdomain now use Let's Encrypt certificates automatically."
```

## Conclusion

This approach represents the **cleanest and most maintainable** way to use trusted certificates in OpenShift:

- ✅ **Follows Red Hat documentation exactly**
- ✅ **Minimal route configuration required**
- ✅ **Cluster-wide certificate management**
- ✅ **Automatic certificate inheritance**
- ✅ **Production-ready and supported**

By replacing the default ingress certificate, you get **trusted Let's Encrypt certificates** for all applications automatically, with **simple re-encrypt routes** that require no certificate configuration at all.

---

**References:**
- [Red Hat OpenShift Documentation - Replacing Default Ingress Certificate](https://docs.redhat.com/en/documentation/openshift_container_platform/4.11/html/security_and_compliance/configuring-certificates#replacing-default-ingress)
- [OpenShift Ingress Controller Configuration](https://docs.openshift.com/container-platform/4.11/networking/ingress-operator.html) 