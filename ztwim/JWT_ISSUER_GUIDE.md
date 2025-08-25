# SPIRE JWT Issuer Complete Guide

A comprehensive guide to understanding and implementing JWT Issuer functionality in SPIRE (SPIFFE Runtime Environment).

## Table of Contents

1. [Overview](#overview)
2. [Architecture & Flow](#architecture--flow)
3. [JWT Issuer vs Domain Relationship](#jwt-issuer-vs-domain-relationship)
4. [Configuration](#configuration)
5. [Use Cases](#use-cases)
6. [Examples](#examples)
7. [Security Considerations](#security-considerations)
8. [Troubleshooting](#troubleshooting)

## Overview

JWT Issuer in SPIRE serves multiple critical functions in the identity and authentication ecosystem:

### What is JWT Issuer?

The **JWT Issuer** (`iss` claim) is an optional but important field in JWT-SVIDs (JWT-based SPIFFE Verifiable Identity Documents) that:

- **Identifies the token issuer**: Specifies which entity created and signed the JWT
- **Enables OIDC integration**: Provides compatibility with standard OIDC/OAuth2 flows
- **Supports federation**: Helps distinguish tokens across multiple SPIRE deployments
- **Enhances auditability**: Improves logging and debugging capabilities

### Key Components

1. **SPIRE Server**: Mints JWT-SVIDs with issuer claims
2. **OIDC Discovery Provider**: Serves OIDC discovery documents
3. **Workload API**: Provides JWT-SVIDs to workloads
4. **Trust Domains**: Define security boundaries (separate from domain fields)

## Architecture & Flow

### Complete JWT-SVID Lifecycle

```mermaid
sequenceDiagram
    participant W as Workload
    participant A as SPIRE Agent
    participant S as SPIRE Server
    participant O as OIDC Provider
    participant E as External Service

    Note over W,E: 1. JWT-SVID Request Flow
    
    W->>A: Request JWT-SVID (Workload API)
    A->>A: Attest workload identity
    A->>S: Request JWT-SVID signing
    Note over S: Apply JWT issuer from config
    S->>S: Build claims with iss field
    S->>S: Sign with JWT CA key
    S->>A: Return signed JWT-SVID
    A->>W: Deliver JWT-SVID

    Note over W,E: 2. OIDC Discovery Flow
    
    E->>O: GET /.well-known/openid-configuration
    Note over O: Check domain allowlist
    O->>O: Build discovery document
    Note over O: Use jwt_issuer or derive from request
    O->>E: Return discovery document with issuer URL

    Note over W,E: 3. JWT Validation Flow
    
    W->>E: Present JWT-SVID to external service
    E->>O: Fetch JWKS from keys endpoint
    E->>E: Validate JWT signature & claims
    Note over E: Check issuer matches expected value
    E->>W: Grant/deny access based on validation
```

### JWT-SVID Creation Process

```mermaid
flowchart TD
    A[Workload Request] --> B[Agent Attestation]
    B --> C[Server Authorization]
    C --> D{JWT Issuer Configured?}
    
    D -->|Yes| E[Add iss claim to JWT]
    D -->|No| F[Create JWT without iss claim]
    
    E --> G[Build JWT Claims]
    F --> G
    
    G --> H[Sign with JWT CA Key]
    H --> I[Validate JWT-SVID]
    I --> J[Return to Workload]
    
    subgraph "JWT Claims Structure"
        K["sub: spiffe://trust.domain/workload<br/>
           aud: [audience1, audience2]<br/>
           exp: expiration_timestamp<br/>
           iat: issued_at_timestamp<br/>
           iss: configured_issuer (optional)"]
    end
    
    G -.-> K
```

### Trust Domain vs Domain Field Architecture

```mermaid
graph TB
    subgraph "SPIRE Core (Trust Domain: example.org)"
        TD[Trust Domain: example.org]
        S[SPIRE Server]
        A[SPIRE Agent]
        
        S --> TD
        A --> TD
    end
    
    subgraph "OIDC Discovery Provider (Domain Fields)"
        O[OIDC Provider]
        D1[spire.example.com]
        D2[auth.example.com]
        D3[oidc.example.com]
        
        O --> D1
        O --> D2
        O --> D3
    end
    
    subgraph "JWT Issuer Configuration"
        JI[jwt_issuer: https://auth.example.com]
    end
    
    S -.->|Mints JWT-SVIDs with issuer| JI
    O -.->|Domain access control| D1
    O -.->|Fixed issuer URL| JI
    
    style TD fill:#e1f5fe
    style JI fill:#fff3e0
    style D1 fill:#f3e5f5
```

## JWT Issuer vs Domain Relationship

### Conceptual Differences

| Aspect | Trust Domain | Domain Field (OIDC) | JWT Issuer |
|--------|--------------|-------------------|------------|
| **Purpose** | SPIFFE identity boundary | Access control | Token identification |
| **Scope** | Entire SPIRE deployment | OIDC endpoints only | JWT claims only |
| **Example** | `example.org` | `["spire.example.com"]` | `https://auth.example.com` |
| **Security Role** | Identity namespace | Request filtering | Token authenticity |

### Interaction Scenarios

#### Scenario 1: Default Dynamic Issuer
```hcl
# OIDC Discovery Provider
domains = ["spire.example.com", "auth.example.com"]
# jwt_issuer not set - derived from request Host header
```

**Result**: 
- Request to `spire.example.com` → Issuer: `https://spire.example.com`
- Request to `auth.example.com` → Issuer: `https://auth.example.com`

#### Scenario 2: Fixed Issuer Override
```hcl
# OIDC Discovery Provider  
domains = ["spire.example.com", "auth.example.com"]
jwt_issuer = "https://identity.example.com"
```

**Result**:
- All requests → Issuer: `https://identity.example.com` (regardless of request domain)
- Better for OIDC client consistency
- Requires careful domain/issuer coordination

#### Scenario 3: Multi-Domain Federation
```hcl
# OIDC Discovery Provider
domains = ["spire.us-east.com", "spire.us-west.com", "spire.eu.com"]
jwt_issuer = "https://global-identity.example.com"
```

**Result**:
- Multiple regions can access OIDC endpoints
- Single consistent issuer for all federated services
- Complex but highly flexible setup

## Configuration

### SPIRE Server Configuration

```hcl
server {
    trust_domain = "example.org"
    
    # JWT Issuer for all minted JWT-SVIDs
    jwt_issuer = "https://identity.example.com"
    
    # JWT key configuration
    jwt_key_type = "ec-p256"
    default_jwt_svid_ttl = "5m"
}
```

### OIDC Discovery Provider Configuration

```hcl
# Basic Configuration
domains = ["spire.example.com"]
jwt_issuer = "https://identity.example.com"

# Server API source
server_api {
    address = "unix:///tmp/spire-server/private/api.sock"
}

# HTTPS with ACME (Let's Encrypt)
acme {
    cache_dir = "/var/lib/spire/oidc-cache"
    email = "admin@example.com"
    tos_accepted = true
}
```

### Advanced Multi-Domain Configuration

```hcl
# Production setup with multiple domains
domains = [
    "spire.production.com",
    "auth.production.com", 
    "identity.internal.com"
]

# Fixed issuer for consistency
jwt_issuer = "https://identity.production.com/spire"

# Custom JWKS URI for load balancing
jwks_uri = "https://keys.production.com/.well-known/jwks.json"

# Path prefix for reverse proxy
server_path_prefix = "/auth/v1"

# Health checks
health_checks {
    bind_port = 8080
    ready_path = "/ready"
    live_path = "/live"
}
```

## Use Cases

### 1. Internal Service-to-Service Authentication

**Scenario**: Microservices within the same trust domain communicating securely.

```mermaid
sequenceDiagram
    participant S1 as Service A
    participant S2 as Service B
    participant SA as SPIRE Agent
    
    S1->>SA: Request JWT-SVID (audience: service-b)
    SA->>S1: Return JWT-SVID (no issuer needed)
    S1->>S2: API call with JWT-SVID
    S2->>SA: Validate JWT-SVID
    SA->>S2: Validation result + claims
    S2->>S1: Process request
```

**Configuration**:
```hcl
# SPIRE Server - no jwt_issuer needed
server {
    trust_domain = "internal.company.com"
    default_jwt_svid_ttl = "5m"
}
```

### 2. External OIDC Integration

**Scenario**: Integrating with external identity providers and OIDC clients.

```mermaid
sequenceDiagram
    participant C as OIDC Client
    participant O as OIDC Provider
    participant S as SPIRE Server
    participant W as Workload
    
    C->>O: GET /.well-known/openid-configuration
    O->>C: Return discovery document with issuer
    C->>O: GET /keys (JWKS)
    O->>C: Return public keys
    
    W->>S: Request JWT-SVID
    S->>W: Return JWT with issuer claim
    W->>C: Present JWT token
    C->>C: Validate JWT with OIDC provider keys
```

**Configuration**:
```hcl
# SPIRE Server
server {
    trust_domain = "company.com"
    jwt_issuer = "https://auth.company.com"
}

# OIDC Discovery Provider
domains = ["auth.company.com"]
jwt_issuer = "https://auth.company.com"
server_api {
    address = "unix:///tmp/spire-server/private/api.sock"
}
```

### 3. Multi-Cloud Federation

**Scenario**: Services across different cloud providers and regions.

```mermaid
graph TB
    subgraph "AWS US-East"
        AE[SPIRE Server]
        WE[Workloads]
        AE --> WE
    end
    
    subgraph "GCP US-West"  
        GW[SPIRE Server]
        WW[Workloads]
        GW --> WW
    end
    
    subgraph "Azure EU"
        AZ[SPIRE Server]
        WZ[Workloads]
        AZ --> WZ
    end
    
    subgraph "Global OIDC"
        OG[OIDC Provider]
        IG[Issuer: https://global.company.com]
        OG --> IG
    end
    
    AE -.->|Federation| GW
    GW -.->|Federation| AZ
    AZ -.->|Federation| AE
    
    AE --> OG
    GW --> OG
    AZ --> OG
```

**Configuration**:
```hcl
# Each SPIRE Server
server {
    trust_domain = "region.company.com"  # Different per region
    jwt_issuer = "https://global.company.com"  # Same global issuer
}

# Global OIDC Provider
domains = [
    "spire-aws.company.com",
    "spire-gcp.company.com", 
    "spire-azure.company.com"
]
jwt_issuer = "https://global.company.com"
```

### 4. API Gateway Integration

**Scenario**: Using JWT-SVIDs with API gateways for request authentication.

```mermaid
sequenceDiagram
    participant C as Client App
    participant G as API Gateway
    participant O as OIDC Provider
    participant A as Backend API
    participant S as SPIRE
    
    Note over C,S: Setup Phase
    C->>O: Discover OIDC configuration
    G->>O: Configure JWT validation
    
    Note over C,S: Runtime Phase
    A->>S: Get JWT-SVID for client access
    S->>A: Return JWT with issuer
    A->>C: Provide JWT token
    
    C->>G: API request with JWT
    G->>G: Validate JWT using OIDC config
    G->>A: Forward validated request
    A->>C: Return API response
```

### 5. Kubernetes Service Mesh

**Scenario**: SPIRE with Istio/Envoy for service mesh authentication.

```mermaid
graph LR
    subgraph "Kubernetes Cluster"
        subgraph "Namespace: production"
            P1[Pod 1 + Envoy]
            P2[Pod 2 + Envoy]
        end
        
        subgraph "SPIRE Infrastructure"
            SS[SPIRE Server]
            SA[SPIRE Agent DaemonSet]
        end
        
        subgraph "Service Mesh"
            I[Istio Control Plane]
            O[OIDC Provider]
        end
    end
    
    SA --> P1
    SA --> P2
    SS --> SA
    
    P1 -.->|mTLS + JWT| P2
    I --> O
    O --> SS
```

## Examples

### Example 1: Simple Internal Setup

```hcl
# spire-server.conf
server {
    bind_address = "0.0.0.0"
    bind_port = "8081"
    trust_domain = "internal.company.com"
    data_dir = "/opt/spire/data/server"
    
    # No JWT issuer - for internal use only
    default_jwt_svid_ttl = "5m"
}

plugins {
    DataStore "sql" {
        plugin_data {
            database_type = "sqlite3"
            connection_string = "/opt/spire/data/server/datastore.sqlite3"
        }
    }
    
    KeyManager "disk" {
        plugin_data {
            keys_path = "/opt/spire/data/server/keys.json"
        }
    }
    
    NodeAttestor "join_token" {
        plugin_data {}
    }
}
```

### Example 2: OIDC Integration Setup

```hcl
# spire-server.conf
server {
    bind_address = "0.0.0.0"
    bind_port = "8081"
    trust_domain = "company.com"
    data_dir = "/opt/spire/data/server"
    
    # JWT issuer for OIDC integration
    jwt_issuer = "https://auth.company.com"
    default_jwt_svid_ttl = "15m"
    jwt_key_type = "ec-p256"
}

# ... plugins config ...
```

```hcl
# oidc-discovery-provider.conf
domains = ["auth.company.com"]
jwt_issuer = "https://auth.company.com"

server_api {
    address = "unix:///opt/spire/sockets/api.sock"
}

acme {
    cache_dir = "/opt/spire/oidc-cache"
    email = "admin@company.com"
    tos_accepted = true
}

health_checks {
    bind_port = 8080
    ready_path = "/ready"
    live_path = "/live"
}
```

### Example 3: Multi-Domain Production Setup

```hcl
# oidc-discovery-provider.conf
log_level = "INFO"
log_format = "json"

# Multiple domains for different access patterns
domains = [
    "auth.company.com",      # Main authentication endpoint
    "spire.internal.com",    # Internal access
    "identity.api.com"       # API gateway integration
]

# Fixed issuer for consistency across all domains
jwt_issuer = "https://identity.company.com"

# Custom JWKS URI for CDN/load balancer
jwks_uri = "https://cdn.company.com/auth/keys"

# Path prefix for reverse proxy setup
server_path_prefix = "/spire/v1"

# Production server API
server_api {
    address = "unix:///var/run/spire/sockets/api.sock"
    poll_interval = "5s"
}

# HTTPS with custom certificates
serving_cert_file {
    cert_file_path = "/etc/ssl/certs/spire.crt"
    key_file_path = "/etc/ssl/private/spire.key"
}

# Comprehensive health checks
health_checks {
    bind_port = 8080
    ready_path = "/health/ready"
    live_path = "/health/live"
}
```

### Example 4: Federation Configuration

```hcl
# Primary trust domain server
server {
    trust_domain = "company.com"
    jwt_issuer = "https://global-auth.company.com"
    
    federation {
        bundle_endpoint {
            address = "0.0.0.0"
            port = 8443
        }
        
        federates_with "partner.com" {
            bundle_endpoint_url = "https://spire.partner.com:8443"
            bundle_endpoint_profile "https_web"
        }
    }
}
```

### Example 5: Development/Testing Setup

```hcl
# Development OIDC provider (insecure)
domains = ["localhost"]
insecure_addr = ":8080"
allow_insecure_scheme = true

# No JWT issuer - will use request host
server_api {
    address = "unix:///tmp/spire-server/private/api.sock"
}

log_level = "DEBUG"
log_requests = true
```

## Security Considerations

### 1. Issuer Validation
- **Always validate issuer claims** in consuming applications
- **Use HTTPS for issuer URLs** to prevent man-in-the-middle attacks
- **Implement issuer allowlists** in client applications

### 2. Domain Security
```hcl
# Good: Specific domain allowlist
domains = ["auth.company.com", "spire.company.com"]

# Avoid: Overly broad domains
# domains = ["*.company.com"]  # Not supported and risky
```

### 3. Key Management
- **Rotate JWT signing keys regularly**
- **Use hardware security modules (HSM)** for production
- **Monitor key usage and expiration**

### 4. Network Security
```hcl
# Production: Always use HTTPS
acme {
    cache_dir = "/secure/cache"
    email = "security@company.com"
    tos_accepted = true
}

# Development only: HTTP allowed
insecure_addr = ":8080"
allow_insecure_scheme = true  # NEVER in production
```

### 5. Audit and Monitoring

```hcl
server {
    audit_log_enabled = true
    log_level = "INFO"
    log_format = "json"  # Better for log aggregation
}
```

## Troubleshooting

### Common Issues

#### 1. Domain Verification Fails
```
Error: domain "wrong.domain.com" is not allowed
```

**Solution**: Add domain to allowlist or fix client request headers:
```hcl
domains = ["correct.domain.com", "wrong.domain.com"]
```

#### 2. Issuer Mismatch
```
Error: token issuer "https://old.issuer.com" doesn't match expected "https://new.issuer.com"
```

**Solution**: Update client configuration or use domain-based issuer:
```hcl
# Remove fixed issuer to use dynamic domain-based issuer
# jwt_issuer = "https://old.issuer.com"
```

#### 3. JWT Validation Fails
```
Error: failed to validate JWT: token has expired
```

**Solution**: Check TTL configuration and time synchronization:
```hcl
server {
    default_jwt_svid_ttl = "15m"  # Increase if needed
}
```

#### 4. OIDC Discovery Not Working
```
Error: 404 Not Found on /.well-known/openid-configuration
```

**Solution**: Verify OIDC provider configuration and paths:
```hcl
server_path_prefix = ""  # Remove if causing path issues
```

#### 5. Key Not Found
```
Error: public key "kid-123" not found in trust domain "company.com"
```

**Solution**: Check key rotation and JWKS endpoint:
- Ensure SPIRE server is running
- Verify OIDC provider can access SPIRE server API
- Check key rotation hasn't invalidated old keys

### Debugging Commands

```bash
# Check JWT-SVID content
echo $JWT_SVID | base64 -d | jq .

# Test OIDC discovery
curl https://auth.company.com/.well-known/openid-configuration

# Fetch JWKS
curl https://auth.company.com/keys

# Check SPIRE server logs
journalctl -u spire-server -f

# Validate JWT manually
curl -X POST https://auth.company.com/validate \
  -H "Content-Type: application/json" \
  -d '{"token": "'$JWT_SVID'", "audience": "my-service"}'
```

### Performance Tuning

```hcl
server {
    # Adjust TTLs based on security vs performance needs
    default_jwt_svid_ttl = "15m"  # Longer = fewer renewals
    
    # Rate limiting
    ratelimit {
        attestation = true
        signing = true  # Limits JWT signing requests
    }
}

# OIDC provider caching
server_api {
    poll_interval = "10s"  # Balance freshness vs load
}
```

---

## Conclusion

JWT Issuer in SPIRE provides powerful capabilities for:
- **Identity integration** with existing OIDC/OAuth2 systems
- **Multi-domain deployments** with consistent token identification  
- **Federation scenarios** across trust boundaries
- **Enhanced security** through proper token attribution

The key to successful implementation is understanding the relationship between trust domains (SPIRE's security boundary), domain fields (access control), and JWT issuers (token identification), then configuring them appropriately for your use case.

For production deployments, always prioritize security through proper domain allowlists, HTTPS enforcement, key rotation, and comprehensive monitoring. 