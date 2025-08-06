# SPIRE OIDC Discovery Provider with Let's Encrypt Re-encrypt Route

## Overview

This document provides step-by-step instructions to set up a SPIRE OIDC Discovery Provider with a trusted Let's Encrypt certificate using OpenShift re-encrypt routes. The solution provides:

- **Client-to-Ingress**: Trusted Let's Encrypt certificate
- **Ingress-to-Backend**: OpenShift Service CA certificate
- **End-to-End Encryption**: Two TLS sessions with automatic certificate validation

## Architecture

```
Client → HAProxy Router → Backend Service
   ↓           ↓              ↓
[HTTPS]   [Let's Encrypt]  [Service CA TLS]
          [PROD Certificate] [Auto-trusted]
          [✅ TRUSTED]      [✅ RE-ENCRYPT]
```

## Prerequisites

- OpenShift cluster with SPIRE deployed
- cert-manager installed and running
- SPIRE OIDC Discovery Provider already deployed
- Valid domain name for the route

## Step 1: Verify Prerequisites

### Check cert-manager Installation

```bash
kubectl get pods -n cert-manager
```

Expected output:
```
NAME                                       READY   STATUS    RESTARTS   AGE
cert-manager-5457f4fb65-6chdc              1/1     Running   0          4h30m
cert-manager-cainjector-78cbd44c9f-bc6qj   1/1     Running   0          4h30m
cert-manager-webhook-6b5545dc5-7rqxm       1/1     Running   0          4h30m
```

### Verify SPIRE OIDC Discovery Provider

```bash
kubectl get deployment spire-spiffe-oidc-discovery-provider -n zero-trust-workload-identity-manager
```

## Step 2: Create Let's Encrypt ClusterIssuers

Create both staging and production ClusterIssuers:

```yaml
# letsencrypt-clusterissuer.yaml
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod
spec:
  acme:
    # The ACME server URL
    server: https://acme-v02.api.letsencrypt.org/directory
    # Email address used for ACME registration
    email: aagnihot@redhat.com  # Replace with your email
    # Name of a secret used to store the ACME account private key
    privateKeySecretRef:
      name: letsencrypt-prod
    # Enable the HTTP-01 challenge provider
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
    # The ACME server URL for staging (testing)
    server: https://acme-staging-v02.api.letsencrypt.org/directory
    # Email address used for ACME registration
    email: aagnihot@redhat.com  # Replace with your email
    # Name of a secret used to store the ACME account private key
    privateKeySecretRef:
      name: letsencrypt-staging
    # Enable the HTTP-01 challenge provider
    solvers:
    - http01:
        ingress:
          class: openshift-default
```

Apply the ClusterIssuers:

```bash
kubectl apply -f letsencrypt-clusterissuer.yaml
```

Verify ClusterIssuers are ready:

```bash
kubectl get clusterissuer
```

Expected output:
```
NAME                  READY   AGE
letsencrypt-prod      True    108s
letsencrypt-staging   True    108s
```

## Step 3: Create Let's Encrypt Certificate

Create a Certificate resource to request a Let's Encrypt certificate:

```yaml
# oidc-letsencrypt-certificate.yaml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: oidc-discovery-letsencrypt
  namespace: zero-trust-workload-identity-manager
spec:
  # Secret name where the certificate will be stored
  secretName: oidc-discovery-letsencrypt-tls
  
  # Use Let's Encrypt production for trusted certificates
  issuerRef:
    name: letsencrypt-prod
    kind: ClusterIssuer
    group: cert-manager.io
  
  # Domain name for the certificate
  dnsNames:
  - oidc-discovery.apps.aagnihot-custer-kdbs.devcluster.openshift.com  # Replace with your domain
  
  # Certificate usage
  usages:
  - digital signature
  - key encipherment
```

Apply the Certificate:

```bash
kubectl apply -f oidc-letsencrypt-certificate.yaml
```

Monitor certificate creation:

```bash
# Check certificate status
kubectl get certificate -n zero-trust-workload-identity-manager

# Check detailed status
kubectl describe certificate oidc-discovery-letsencrypt -n zero-trust-workload-identity-manager
```

Wait for the certificate to be ready:
```
NAME                         READY   SECRET                           AGE
oidc-discovery-letsencrypt   True    oidc-discovery-letsencrypt-tls   11m
```

## Step 4: Verify Service CA Certificate

Ensure the OIDC Discovery Provider service has the Service CA annotation:

```bash
kubectl get service spire-spiffe-oidc-discovery-provider -n zero-trust-workload-identity-manager -o yaml | grep -A 2 annotations
```

Expected output:
```yaml
annotations:
  service.beta.openshift.io/serving-cert-secret-name: oidc-serving-cert
```

Verify the Service CA secret exists:

```bash
kubectl get secret oidc-serving-cert -n zero-trust-workload-identity-manager
```

## Step 5: Ensure OIDC Provider Uses Service CA

Verify the OIDC provider configuration uses Service CA certificates:

```bash
kubectl get configmap spire-spiffe-oidc-discovery-provider -n zero-trust-workload-identity-manager -o jsonpath='{.data.oidc-discovery-provider\.conf}' | jq '.serving_cert_file'
```

Expected output:
```json
{
  "addr": ":8443",
  "cert_file_path": "/etc/oidc/tls/tls.crt",
  "key_file_path": "/etc/oidc/tls/tls.key"
}
```

If the paths are incorrect, update the ConfigMap:

```bash
kubectl patch configmap spire-spiffe-oidc-discovery-provider -n zero-trust-workload-identity-manager --type='merge' -p='{"data":{"oidc-discovery-provider.conf":"{\"domains\":[\"spire-spiffe-oidc-discovery-provider\",\"spire-spiffe-oidc-discovery-provider.zero-trust-workload-identity-manager\",\"spire-spiffe-oidc-discovery-provider.zero-trust-workload-identity-manager.svc.cluster.local\",\"oidc-discovery.apps.aagnihot-custer-kdbs.devcluster.openshift.com\"],\"health_checks\":{\"bind_port\":\"8008\",\"live_path\":\"/live\",\"ready_path\":\"/ready\"},\"log_level\":\"debug\",\"serving_cert_file\":{\"addr\":\":8443\",\"cert_file_path\":\"/etc/oidc/tls/tls.crt\",\"key_file_path\":\"/etc/oidc/tls/tls.key\"},\"workload_api\":{\"socket_path\":\"/spiffe-workload-api/spire-agent.sock\",\"trust_domain\":\"apps.aagnihot-custer-kdbs.devcluster.openshift.com\"}}"}}'
```

## Step 6: Create Re-encrypt Route with Let's Encrypt Certificate

Create a basic re-encrypt route:

```bash
oc create route reencrypt oidc-letsencrypt \
  --service=spire-spiffe-oidc-discovery-provider \
  --port=https \
  --hostname=oidc-discovery.apps.aagnihot-custer-kdbs.devcluster.openshift.com \
  -n zero-trust-workload-identity-manager
```

## Step 7: Add Let's Encrypt Certificate to Route

Extract certificate data and add to route:

```bash
# Get certificate and key data
CERT_B64=$(kubectl get secret oidc-discovery-letsencrypt-tls -n zero-trust-workload-identity-manager -o jsonpath='{.data.tls\.crt}')
KEY_B64=$(kubectl get secret oidc-discovery-letsencrypt-tls -n zero-trust-workload-identity-manager -o jsonpath='{.data.tls\.key}')

# Add certificate to route
kubectl patch route oidc-letsencrypt -n zero-trust-workload-identity-manager --type='json' -p="[{\"op\": \"add\", \"path\": \"/spec/tls/certificate\", \"value\": \"$(echo $CERT_B64 | base64 -d | awk '{printf "%s\\n", $0}')\"}]"

# Add private key to route
kubectl patch route oidc-letsencrypt -n zero-trust-workload-identity-manager --type='json' -p="[{\"op\": \"add\", \"path\": \"/spec/tls/key\", \"value\": \"$(echo $KEY_B64 | base64 -d | awk '{printf "%s\\n", $0}')\"}]"
```

## Step 8: Verify the Setup

### Test the OIDC Discovery Endpoint

```bash
curl https://oidc-discovery.apps.aagnihot-custer-kdbs.devcluster.openshift.com/.well-known/openid-configuration
```

Expected output:
```json
{
  "issuer": "https://oidc-discovery.apps.aagnihot-custer-kdbs.devcluster.openshift.com",
  "jwks_uri": "https://oidc-discovery.apps.aagnihot-custer-kdbs.devcluster.openshift.com/keys",
  "authorization_endpoint": "",
  "response_types_supported": [
    "id_token"
  ],
  "subject_types_supported": [],
  "id_token_signing_alg_values_supported": [
    "RS256",
    "ES256",
    "ES384"
  ]
}
```

### Test the JWKS Endpoint

```bash
curl https://oidc-discovery.apps.aagnihot-custer-kdbs.devcluster.openshift.com/keys
```

## Step 9: Verify Re-encryption is Working

### Check Route Configuration

```bash
kubectl get route oidc-letsencrypt -n zero-trust-workload-identity-manager -o jsonpath='{.spec.tls.termination}' && echo
```

Expected output: `reencrypt`

### Verify Different Certificates at Different Layers

**Client-to-Ingress Certificate (Let's Encrypt):**
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

**Backend Service Certificate (Service CA):**
```bash
kubectl get secret oidc-serving-cert -n zero-trust-workload-identity-manager -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -text -noout | grep -A 2 -B 2 "Issuer:"
```

Expected output:
```
Issuer: CN=openshift-service-serving-signer@1754458045
```

### Check HAProxy Configuration

```bash
oc get pods -n openshift-ingress -l ingresscontroller.operator.openshift.io/deployment-ingresscontroller=default -o name | head -1 | xargs -I {} oc exec {} -n openshift-ingress -- grep -A 20 "backend be_secure:zero-trust-workload-identity-manager:oidc-letsencrypt" /var/lib/haproxy/conf/haproxy.config
```

Look for these key indicators of re-encryption:
- `ssl verifyhost` - HAProxy establishes TLS to backend
- `verify required` - Certificate validation enforced
- `ca-file /var/run/configmaps/service-ca/service-ca.crt` - Uses Service CA for backend validation

## Troubleshooting

### Certificate Not Ready

If the certificate is stuck in `False` state:

```bash
# Check certificate details
kubectl describe certificate oidc-discovery-letsencrypt -n zero-trust-workload-identity-manager

# Check certificate request
kubectl get certificaterequest -n zero-trust-workload-identity-manager

# Check challenges
kubectl get challenges -n zero-trust-workload-identity-manager
```

### Using Staging Certificate

If you initially used staging and need to switch to production:

```bash
# Update certificate to use production issuer
kubectl patch certificate oidc-discovery-letsencrypt -n zero-trust-workload-identity-manager --type='merge' -p='{"spec":{"issuerRef":{"name":"letsencrypt-prod"}}}'

# Wait for certificate to be ready
kubectl get certificate oidc-discovery-letsencrypt -n zero-trust-workload-identity-manager -w

# Update route with new certificate
CERT_B64=$(kubectl get secret oidc-discovery-letsencrypt-tls -n zero-trust-workload-identity-manager -o jsonpath='{.data.tls\.crt}')
KEY_B64=$(kubectl get secret oidc-discovery-letsencrypt-tls -n zero-trust-workload-identity-manager -o jsonpath='{.data.tls\.key}')

kubectl patch route oidc-letsencrypt -n zero-trust-workload-identity-manager --type='json' -p="[{\"op\": \"replace\", \"path\": \"/spec/tls/certificate\", \"value\": \"$(echo $CERT_B64 | base64 -d | awk '{printf "%s\\n", $0}')\"}]"

kubectl patch route oidc-letsencrypt -n zero-trust-workload-identity-manager --type='json' -p="[{\"op\": \"replace\", \"path\": \"/spec/tls/key\", \"value\": \"$(echo $KEY_B64 | base64 -d | awk '{printf "%s\\n", $0}')\"}]"
```

### SSL Certificate Errors

Common SSL errors and solutions:

1. **"unable to get local issuer certificate"**: Using staging certificate instead of production
2. **"certificate verify failed"**: Certificate chain broken or CA not trusted
3. **"hostname verification failed"**: Certificate CN/SAN doesn't match service FQDN

### OIDC Provider Not Starting

Check the deployment and logs:

```bash
# Check deployment status
kubectl get deployment spire-spiffe-oidc-discovery-provider -n zero-trust-workload-identity-manager

# Check pod status
kubectl get pods -n zero-trust-workload-identity-manager -l app.kubernetes.io/name=spiffe-oidc-discovery-provider

# Check logs
kubectl logs -n zero-trust-workload-identity-manager deployment/spire-spiffe-oidc-discovery-provider -c spiffe-oidc-discovery-provider
```

## Certificate Renewal

cert-manager will automatically renew Let's Encrypt certificates. To manually trigger renewal:

```bash
# Delete the secret to force renewal
kubectl delete secret oidc-discovery-letsencrypt-tls -n zero-trust-workload-identity-manager

# The Certificate resource will automatically recreate it
kubectl get certificate oidc-discovery-letsencrypt -n zero-trust-workload-identity-manager -w
```

## Security Considerations

### Service CA Trust Model

- **Scope**: Service CA is trusted only within the OpenShift cluster
- **Automatic Rotation**: Service CA certificates are automatically rotated
- **Namespace Isolation**: Service names include namespace for verification

### Let's Encrypt Rate Limits

- **Production**: 50 certificates per registered domain per week
- **Staging**: Higher rate limits for testing
- **Recommendation**: Use staging for testing, production for final deployment

### Certificate Validation

HAProxy performs:
- **Certificate Chain Validation**: Verifies issuer trust chain
- **Hostname Verification**: Matches certificate CN/SAN to service FQDN
- **Expiration Checking**: Ensures certificates are not expired

## Best Practices

1. **Use Staging First**: Test with `letsencrypt-staging` before switching to production
2. **Monitor Certificates**: Set up monitoring for certificate expiration
3. **Backup Secrets**: Back up important certificate secrets
4. **Use Proper Email**: Use a valid email address for Let's Encrypt registration
5. **Domain Validation**: Ensure domains in OIDC config match route hostnames

## Conclusion

This setup provides:

- ✅ **Trusted Certificates**: Clients see a valid Let's Encrypt certificate
- ✅ **End-to-End Encryption**: Traffic encrypted from client to backend
- ✅ **Automatic Renewal**: cert-manager handles certificate lifecycle
- ✅ **OpenShift Integration**: Leverages built-in Service CA trust
- ✅ **No Backend Changes**: OIDC provider continues using Service CA

The solution combines the best of both worlds: **trusted public certificates** for external clients and **OpenShift-native certificate management** for internal communication.

---

**Document Version**: 1.0  
**Date**: August 6, 2025  
**Author**: Based on practical OpenShift 4.20 implementation  
**Environment**: SPIRE + cert-manager + Let's Encrypt + OpenShift Routes 