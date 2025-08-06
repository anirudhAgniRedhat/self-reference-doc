# SPIRE OIDC Discovery Provider - Let's Encrypt Re-encrypt Route Quick Reference

## Overview
Set up trusted Let's Encrypt certificates for SPIRE OIDC Discovery Provider using OpenShift re-encrypt routes.

## Quick Setup Commands

### 1. Create Let's Encrypt ClusterIssuers
```bash
cat << 'EOF' | kubectl apply -f -
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: your-email@domain.com  # Replace with your email
    privateKeySecretRef:
      name: letsencrypt-prod
    solvers:
    - http01:
        ingress:
          class: openshift-default
---
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-staging
spec:
  acme:
    server: https://acme-staging-v02.api.letsencrypt.org/directory
    email: your-email@domain.com  # Replace with your email
    privateKeySecretRef:
      name: letsencrypt-staging
    solvers:
    - http01:
        ingress:
          class: openshift-default
EOF
```

### 2. Create Certificate Resource
```bash
cat << 'EOF' | kubectl apply -f -
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: oidc-discovery-letsencrypt
  namespace: zero-trust-workload-identity-manager
spec:
  secretName: oidc-discovery-letsencrypt-tls
  issuerRef:
    name: letsencrypt-prod
    kind: ClusterIssuer
    group: cert-manager.io
  dnsNames:
  - your-domain.apps.cluster.com  # Replace with your domain
  usages:
  - digital signature
  - key encipherment
EOF
```

### 3. Create Re-encrypt Route
```bash
oc create route reencrypt oidc-letsencrypt \
  --service=spire-spiffe-oidc-discovery-provider \
  --port=https \
  --hostname=your-domain.apps.cluster.com \
  -n zero-trust-workload-identity-manager
```

### 4. Add Let's Encrypt Certificate to Route
```bash
# Get certificate data
CERT_B64=$(kubectl get secret oidc-discovery-letsencrypt-tls -n zero-trust-workload-identity-manager -o jsonpath='{.data.tls\.crt}')
KEY_B64=$(kubectl get secret oidc-discovery-letsencrypt-tls -n zero-trust-workload-identity-manager -o jsonpath='{.data.tls\.key}')

# Add to route
kubectl patch route oidc-letsencrypt -n zero-trust-workload-identity-manager --type='json' -p="[{\"op\": \"add\", \"path\": \"/spec/tls/certificate\", \"value\": \"$(echo $CERT_B64 | base64 -d | awk '{printf "%s\\n", $0}')\"}]"
kubectl patch route oidc-letsencrypt -n zero-trust-workload-identity-manager --type='json' -p="[{\"op\": \"add\", \"path\": \"/spec/tls/key\", \"value\": \"$(echo $KEY_B64 | base64 -d | awk '{printf "%s\\n", $0}')\"}]"
```

## Verification Commands

### Test Endpoints
```bash
# OIDC Discovery
curl https://your-domain.apps.cluster.com/.well-known/openid-configuration

# JWKS
curl https://your-domain.apps.cluster.com/keys
```

### Verify Re-encryption
```bash
# Check route type
kubectl get route oidc-letsencrypt -n zero-trust-workload-identity-manager -o jsonpath='{.spec.tls.termination}'

# Check client certificate (Let's Encrypt)
openssl s_client -connect your-domain.apps.cluster.com:443 -servername your-domain.apps.cluster.com < /dev/null 2>&1 | grep -A 3 "Certificate chain"

# Check backend certificate (Service CA)
kubectl get secret oidc-serving-cert -n zero-trust-workload-identity-manager -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -text -noout | grep "Issuer:"
```

## Troubleshooting

### Switch from Staging to Production
```bash
kubectl patch certificate oidc-discovery-letsencrypt -n zero-trust-workload-identity-manager --type='merge' -p='{"spec":{"issuerRef":{"name":"letsencrypt-prod"}}}'

# Wait for certificate to be ready
kubectl get certificate oidc-discovery-letsencrypt -n zero-trust-workload-identity-manager -w

# Update route with new certificate
CERT_B64=$(kubectl get secret oidc-discovery-letsencrypt-tls -n zero-trust-workload-identity-manager -o jsonpath='{.data.tls\.crt}')
kubectl patch route oidc-letsencrypt -n zero-trust-workload-identity-manager --type='json' -p="[{\"op\": \"replace\", \"path\": \"/spec/tls/certificate\", \"value\": \"$(echo $CERT_B64 | base64 -d | awk '{printf "%s\\n", $0}')\"}]"
```

### Check Certificate Status
```bash
kubectl get certificate -n zero-trust-workload-identity-manager
kubectl describe certificate oidc-discovery-letsencrypt -n zero-trust-workload-identity-manager
```

### Force Certificate Renewal
```bash
kubectl delete secret oidc-discovery-letsencrypt-tls -n zero-trust-workload-identity-manager
```

## Key Benefits
- ✅ Trusted Let's Encrypt certificates for clients
- ✅ Service CA certificates for backend (OpenShift native)
- ✅ End-to-end encryption maintained
- ✅ Automatic certificate renewal
- ✅ No backend application changes required 