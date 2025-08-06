# OpenShift Re-encrypt Routes: Service CA Integration Analysis

## Overview

This document explains how OpenShift re-encrypt routes work without explicit `destinationCACertificate` configuration when backend services use OpenShift Service CA certificates.

## Problem Statement

**Question**: How does an OpenShift re-encrypt route work when no `destinationCACertificate` is specified in the route configuration?

**Context**: A SPIRE OIDC Discovery Provider was failing with re-encrypt termination but working with passthrough termination. After switching the backend from SPIFFE certificates to Service CA certificates, re-encrypt suddenly worked without any explicit destination CA configuration.

## Technical Analysis

### Architecture Overview

```
Client → HAProxy Router → Backend Service
   ↓           ↓              ↓
[TLS 1]   [Terminates]   [TLS 2 with Service CA]
          [Re-encrypts]   [Auto-trusted by router]
```

### Key Components

1. **OpenShift Service CA Operator**: Automatically provisions TLS certificates for internal services
2. **HAProxy Router**: OpenShift's ingress controller with built-in Service CA trust
3. **Service CA Bundle**: Automatically distributed to router pods for certificate validation

## Evidence and Proof

### 1. HAProxy Router Environment Configuration

The router deployment includes a critical environment variable:

```bash
DEFAULT_DESTINATION_CA_PATH: /var/run/configmaps/service-ca/service-ca.crt
```

This tells HAProxy where to find the default CA certificate for validating backend connections.

### 2. Service CA Bundle Mount

The router pod mounts the Service CA bundle:

```yaml
volumes:
  - name: service-ca-bundle
    configMap:
      name: service-ca-bundle
```

Mounted at:
```bash
/var/run/configmaps/service-ca from service-ca-bundle (ro)
```

### 3. Service CA Certificate Details

**Service CA Certificate**:
```
Issuer: CN=openshift-service-serving-signer@1754458045
Subject: CN=openshift-service-serving-signer@1754458045
Validity: 2025-08-06 to 2027-10-05
```

**Backend Service Certificate** (auto-generated):
```
Issuer: CN=openshift-service-serving-signer@1754458045
Subject: CN=spire-spiffe-oidc-discovery-provider.zero-trust-workload-identity-manager.svc
```

**Certificate Chain**: ✅ Both certificates share the same issuer, creating a valid trust chain.

### 4. HAProxy Configuration Evidence

HAProxy automatically configures backend connections with Service CA validation:

```bash
backend be_secure:zero-trust-workload-identity-manager:oidc
  server pod:spire-spiffe-oidc-discovery-provider-59d66cf95b-s6jj5:spire-spiffe-oidc-discovery-provider:https:10.131.0.25:8443 
  ssl verifyhost spire-spiffe-oidc-discovery-provider.zero-trust-workload-identity-manager.svc 
  verify required ca-file /var/run/configmaps/service-ca/service-ca.crt
```

**Key Parameters**:
- `ssl`: Enables TLS to backend
- `verify required`: Enforces certificate validation
- `ca-file /var/run/configmaps/service-ca/service-ca.crt`: Uses Service CA for validation

## How Re-encrypt Works Without Explicit destinationCACertificate

### Default Behavior

When a re-encrypt route **does not** specify `destinationCACertificate`:

1. **HAProxy uses the default CA path**: `/var/run/configmaps/service-ca/service-ca.crt`
2. **Service CA certificates are automatically trusted**
3. **Certificate validation succeeds** if backend uses Service CA certificates
4. **TLS handshake completes successfully**

### Configuration Comparison

**Route without destinationCACertificate**:
```yaml
spec:
  tls:
    termination: reencrypt
    # No destinationCACertificate specified
```

**HAProxy behavior**: Uses `DEFAULT_DESTINATION_CA_PATH` automatically.

**Route with explicit destinationCACertificate**:
```yaml
spec:
  tls:
    termination: reencrypt
    destinationCACertificate: |
      -----BEGIN CERTIFICATE-----
      [Custom CA Certificate]
      -----END CERTIFICATE-----
```

**HAProxy behavior**: Uses the specified CA certificate instead of the default.

## Case Study: SPIRE OIDC Discovery Provider

### Initial Failure with SPIFFE Certificates

**Configuration**:
```json
"serving_cert_file": {
  "cert_file_path": "/run/spire/oidc-sockets/tls.crt",  // SPIFFE certificate
  "key_file_path": "/run/spire/oidc-sockets/tls.key"
}
```

**Result**: 
- ❌ Re-encrypt failed with "TLS handshake error: bad record MAC"
- ✅ Passthrough worked (no certificate validation by router)

**Root Cause**: SPIFFE certificates were issued by SPIRE's internal CA, which HAProxy didn't trust.

### Solution: Switch to Service CA Certificates

**Configuration Change**:
```json
"serving_cert_file": {
  "cert_file_path": "/etc/oidc/tls/tls.crt",  // Service CA certificate
  "key_file_path": "/etc/oidc/tls/tls.key"
}
```

**Service Configuration**:
```yaml
metadata:
  annotations:
    service.beta.openshift.io/serving-cert-secret-name: oidc-serving-cert
```

**Result**:
- ✅ Re-encrypt works perfectly
- ✅ Automatic certificate validation
- ✅ No explicit destinationCACertificate needed

## Best Practices

### For Service CA Integration

1. **Use Service CA Annotation**:
   ```yaml
   metadata:
     annotations:
       service.beta.openshift.io/serving-cert-secret-name: <secret-name>
   ```

2. **Mount Service CA Certificate**:
   ```yaml
   volumes:
   - name: tls-certs
     secret:
       secretName: <secret-name>
   ```

3. **Configure Application**:
   - Point to Service CA certificate paths
   - Use standard TLS configuration

### For Custom CA Integration

1. **Specify destinationCACertificate**:
   ```yaml
   spec:
     tls:
       termination: reencrypt
       destinationCACertificate: |
         -----BEGIN CERTIFICATE-----
         [Your Custom CA Certificate]
         -----END CERTIFICATE-----
   ```

2. **Ensure Certificate Chain**:
   - Backend certificate must be issued by the specified CA
   - CA certificate must be valid and not expired

## Security Implications

### Service CA Trust Model

- **Scope**: Service CA is trusted only within the OpenShift cluster
- **Automatic Rotation**: Service CA certificates are automatically rotated
- **Namespace Isolation**: Service names include namespace for verification

### Certificate Validation

HAProxy performs:
- **Certificate Chain Validation**: Verifies issuer trust chain
- **Hostname Verification**: Matches certificate CN/SAN to service FQDN
- **Expiration Checking**: Ensures certificates are not expired

## Troubleshooting

### Common Issues

1. **"TLS handshake error: bad record MAC"**
   - **Cause**: Certificate issued by untrusted CA
   - **Solution**: Use Service CA or specify destinationCACertificate

2. **"certificate verify failed"**
   - **Cause**: Certificate chain broken or CA not trusted
   - **Solution**: Check certificate issuer and CA configuration

3. **"hostname verification failed"**
   - **Cause**: Certificate CN/SAN doesn't match service FQDN
   - **Solution**: Ensure certificate includes correct service name

### Debugging Commands

```bash
# Check Service CA certificate
oc get configmap service-ca-bundle -n openshift-ingress -o yaml

# Examine backend certificate
kubectl get secret <cert-secret> -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -text -noout

# View HAProxy configuration
oc exec <router-pod> -n openshift-ingress -- grep -A 10 "backend be_secure:<namespace>:<route-name>"

# Check route configuration
oc get route <route-name> -o yaml
```

## Conclusion

OpenShift HAProxy routers have **built-in Service CA trust** that enables re-encrypt routes to work without explicit `destinationCACertificate` configuration when backend services use Service CA certificates. This automatic trust relationship:

- ✅ Simplifies route configuration
- ✅ Maintains end-to-end encryption
- ✅ Provides automatic certificate validation
- ✅ Integrates seamlessly with OpenShift's certificate management

The key insight is that **certificate compatibility**, not just TLS termination type, determines whether re-encrypt routes work successfully.

---

**Document Version**: 1.0  
**Date**: August 6, 2025  
**Author**: Technical Analysis based on OpenShift 4.20 cluster investigation 