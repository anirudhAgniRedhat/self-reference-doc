# OpenShift Re-encrypt Route - Red Hat Documentation Approach

## Overview

This document shows how to properly configure re-encrypt routes in OpenShift following [Red Hat's official documentation](https://docs.redhat.com/en/documentation/openshift_container_platform/4.11/html/security_and_compliance/configuring-certificates#replacing-default-ingress) for certificate management.

## Key Concept: destinationCACertificate

According to Red Hat documentation, re-encrypt routes should use the `destinationCACertificate` field to explicitly specify which CA certificate to use for validating the backend service certificate.

## Architecture

```
Client → HAProxy Router → Backend Service
   ↓           ↓              ↓
[HTTPS]   [Let's Encrypt]  [Service CA TLS]
          [Client Cert]    [Explicit CA Validation]
          [✅ TRUSTED]     [✅ destinationCACertificate]
```

## Implementation Steps

### Step 1: Create Basic Re-encrypt Route

```bash
oc create route reencrypt oidc-letsencrypt-proper \
  --service=spire-spiffe-oidc-discovery-provider \
  --port=https \
  --hostname=oidc-discovery.apps.aagnihot-custer-kdbs.devcluster.openshift.com \
  -n zero-trust-workload-identity-manager
```

### Step 2: Add Client-Facing Certificates (Let's Encrypt)

```bash
# Get Let's Encrypt certificate data
CERT_B64=$(kubectl get secret oidc-discovery-letsencrypt-tls -n zero-trust-workload-identity-manager -o jsonpath='{.data.tls\.crt}')
KEY_B64=$(kubectl get secret oidc-discovery-letsencrypt-tls -n zero-trust-workload-identity-manager -o jsonpath='{.data.tls\.key}')

# Add to route
kubectl patch route oidc-letsencrypt-proper -n zero-trust-workload-identity-manager --type='json' -p="[
  {\"op\": \"add\", \"path\": \"/spec/tls/certificate\", \"value\": \"$(echo $CERT_B64 | base64 -d | awk '{printf "%s\\n", $0}')\"},
  {\"op\": \"add\", \"path\": \"/spec/tls/key\", \"value\": \"$(echo $KEY_B64 | base64 -d | awk '{printf "%s\\n", $0}')\"}
]"
```

### Step 3: Add Destination CA Certificate (Service CA)

Following Red Hat documentation, explicitly specify the CA certificate for backend validation:

```bash
# Get OpenShift Service CA certificate
kubectl get configmap openshift-service-ca.crt -n openshift-service-ca -o jsonpath='{.data.service-ca\.crt}' > /tmp/service-ca.crt

# Add destination CA certificate to route
SERVICE_CA=$(cat /tmp/service-ca.crt | awk '{printf "%s\\n", $0}')
kubectl patch route oidc-letsencrypt-proper -n zero-trust-workload-identity-manager --type='json' -p="[
  {\"op\": \"add\", \"path\": \"/spec/tls/destinationCACertificate\", \"value\": \"$SERVICE_CA\"}
]"

# Clean up
rm /tmp/service-ca.crt
```

## Verification

### Test the Endpoint
```bash
curl https://oidc-discovery.apps.aagnihot-custer-kdbs.devcluster.openshift.com/.well-known/openid-configuration
```

### Verify Route Configuration
```bash
kubectl get route oidc-letsencrypt-proper -n zero-trust-workload-identity-manager -o yaml | grep -A 5 -B 5 "destinationCACertificate"
```

### Check HAProxy Configuration
```bash
oc get pods -n openshift-ingress -l ingresscontroller.operator.openshift.io/deployment-ingresscontroller=default -o name | head -1 | xargs -I {} oc exec {} -n openshift-ingress -- grep -A 5 -B 5 "oidc-letsencrypt-proper" /var/lib/haproxy/conf/haproxy.config
```

**Expected HAProxy Output:**
```
server pod:spire-spiffe-oidc-discovery-provider-656b766644-42mg5:spire-spiffe-oidc-discovery-provider:https:10.131.0.26:8443 
ssl verify required ca-file /var/lib/haproxy/router/cacerts/zero-trust-workload-identity-manager:oidc-letsencrypt-proper.pem
```

**Key Difference:** HAProxy now uses a **specific CA file** (`/var/lib/haproxy/router/cacerts/...`) instead of the default Service CA path.

## Complete YAML Example

```yaml
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: oidc-letsencrypt-proper
  namespace: zero-trust-workload-identity-manager
spec:
  host: oidc-discovery.apps.aagnihot-custer-kdbs.devcluster.openshift.com
  to:
    kind: Service
    name: spire-spiffe-oidc-discovery-provider
    weight: 100
  port:
    targetPort: https
  tls:
    termination: reencrypt
    insecureEdgeTerminationPolicy: Redirect
    # Client-facing certificate (Let's Encrypt)
    certificate: |
      -----BEGIN CERTIFICATE-----
      [Let's Encrypt Certificate]
      -----END CERTIFICATE-----
    key: |
      -----BEGIN RSA PRIVATE KEY-----
      [Let's Encrypt Private Key]
      -----END RSA PRIVATE KEY-----
    # Backend CA certificate (Service CA) - Following Red Hat Documentation
    destinationCACertificate: |
      -----BEGIN CERTIFICATE-----
      [OpenShift Service CA Certificate]
      -----END CERTIFICATE-----
  wildcardPolicy: None
```

## Benefits of This Approach

### ✅ **Red Hat Documentation Compliant**
- Follows official OpenShift certificate management guidelines
- Uses recommended `destinationCACertificate` field

### ✅ **Explicit Security Model**
- Route explicitly defines trusted CA for backend validation
- No reliance on default Service CA behavior

### ✅ **Production Ready**
- Clear certificate separation and management
- Maintainable and auditable configuration

### ✅ **HAProxy Integration**
- Creates dedicated CA file for route-specific validation
- Better isolation between different routes

## Comparison with Previous Approach

| Aspect | Previous (Implicit) | New (Red Hat Documentation) |
|--------|-------------------|---------------------------|
| **Backend CA** | Default Service CA path | Explicit `destinationCACertificate` |
| **HAProxy Config** | `ca-file /var/run/configmaps/service-ca/service-ca.crt` | `ca-file /var/lib/haproxy/router/cacerts/...` |
| **Documentation** | Custom approach | Red Hat official guidance |
| **Maintainability** | Relies on defaults | Explicit configuration |
| **Security** | Implicit trust | Explicit trust definition |

## Certificate Management

### Automatic Rotation
- **Let's Encrypt**: Managed by cert-manager
- **Service CA**: Managed by OpenShift Service CA Operator

### Manual Rotation
Following Red Hat documentation for manual Service CA rotation:

```bash
# Check Service CA expiration
oc get secrets/signing-key -n openshift-service-ca \
  -o template='{{index .data "tls.crt"}}' \
  | base64 --decode \
  | openssl x509 -noout -enddate

# Manually rotate Service CA (if needed)
oc delete secret/signing-key -n openshift-service-ca
```

## Conclusion

This approach follows Red Hat's official documentation for OpenShift certificate management, providing:

- ✅ **Compliance** with Red Hat best practices
- ✅ **Explicit security** configuration
- ✅ **Production-ready** certificate management
- ✅ **Maintainable** and **auditable** setup

The key insight is using `destinationCACertificate` to explicitly define backend certificate validation, rather than relying on OpenShift's default Service CA behavior.

---

**References:**
- [Red Hat OpenShift Documentation - Configuring Certificates](https://docs.redhat.com/en/documentation/openshift_container_platform/4.11/html/security_and_compliance/configuring-certificates#replacing-default-ingress)
- [OpenShift Service Serving Certificate Secrets](https://docs.redhat.com/en/documentation/openshift_container_platform/4.11/html/security_and_compliance/configuring-certificates#add-service-serving) 