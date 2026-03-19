# ZTWIM Operator: SPIRE UpstreamAuthority Plugin Integration — Design Document

**Scope:** cert-manager, vault, spire UpstreamAuthority plugins only  

---

## 1. Feasibility Check

### 1.1 Upstream SPIRE Configuration Summary

| Plugin        | Config Keys (plugin_data) | Secrets / External Data | RBAC / Network |
|---------------|----------------------------|-------------------------|----------------|
| **cert-manager** | `namespace`, `issuer_name`, `issuer_kind`, `issuer_group`, optional `kube_config_file` | None when using in-cluster config | Create/list/get/delete `certificaterequests` in `cert-manager.io` in the configured namespace |
| **vault**     | `vault_addr`, `pki_mount_point`, optional `ca_cert_path`, `insecure_skip_verify`, `namespace`; exactly one of: `token_auth`, `cert_auth`, `approle_auth`, `k8s_auth` | Env vars: `VAULT_TOKEN`, `VAULT_ADDR`, `VAULT_APPROLE_ID`, `VAULT_APPROLE_SECRET_ID`; file mounts: client cert/key (cert_auth), CA cert, K8s SA token (k8s_auth) | Network egress to Vault. Empty struct pattern in config; secrets via env vars from K8s Secrets |
| **spire**     | `server_address`, `server_port`, `workload_api_socket` | None in config; requires Workload API socket from upstream SPIRE | Network to upstream SPIRE; socket mount for Workload API; upstream endpoint exposed via passthrough Route or LoadBalancer |

**Source references:**  
- cert-manager: `spire/pkg/server/plugin/upstreamauthority/certmanager/certmanager.go` (Configuration struct, defaults IssuerKind=`Issuer`, IssuerGroup=`cert-manager.io`)  
- vault: `spire/pkg/server/plugin/upstreamauthority/vault/vault.go` (Configuration, TokenAuth/CertAuth/AppRoleAuth/K8sAuthConfig; supports env var fallback for sensitive fields — [upstream docs](https://github.com/spiffe/spire/blob/main/doc/plugin_server_upstreamauthority_vault.md))  
- spire: `spire/pkg/server/plugin/upstreamauthority/spire/spire.go` (Configuration: ServerAddr, ServerPort, WorkloadAPISocket)

### 1.2 Nested SPIRE vs Federation

The `spire` UpstreamAuthority plugin implements **nested SPIRE**, which is fundamentally different from **SPIRE federation** (already supported via ZTWIM's `Federation` config). The operator and its documentation must clearly distinguish these two concepts:

| | Nested SPIRE (UpstreamAuthority `spire`) | Federation |
|--|------------------------------------------|------------|
| **Trust domain** | **Same** across all servers in the hierarchy | **Different** trust domains |
| **CA relationship** | Root → Intermediate chain (upstream signs downstream's CA) | Independent CAs; bundle exchange for cross-validation |
| **SVID validation** | Any agent validates any SVID (same root CA in chain) | Requires explicit federation config + bundle exchange |
| **Use case** | Scale within one organization (multi-cluster, multi-cloud) | Cross-organization trust, different admin boundaries |
| **SPIRE config** | `UpstreamAuthority "spire" { ... }` | `Federation { ... }` |

**Critical constraint:** When using the `spire` UpstreamAuthority plugin, the upstream and downstream SPIRE servers **must share the same trust domain**. The upstream SPIRE server signs an intermediate CA for the downstream, and this only works within a single trust domain's chain of trust. The operator **must validate** that `spec.trustDomain` on the downstream matches the upstream's trust domain, and reject configurations where they differ.

> Reference: [SPIFFE Nested SPIRE Architecture](https://spiffe.io/docs/latest/architecture/nested/readme/) — *"Nested SPIRE allows SPIRE Servers to be chained together, and for all SPIRE Servers to issue identities in the same trust domain."*

### 1.3 Blockers

- **None identified** for the three plugins within the stated scope.  
- **Preconditions:**  
  - **cert-manager:** cert-manager installed; Issuer/ClusterIssuer and (if used) namespace must exist.  
  - **vault:** Vault reachable from cluster; PKI mount and auth method configured.  
  - **spire:** Upstream SPIRE server reachable and configured with the **same trust domain**; Workload API socket must be provided (e.g., via volume mount when running in same cluster or over network with appropriate socket path). **Upstream SPIRE endpoint exposure:** The upstream SPIRE server's gRPC API must be accessible from the downstream cluster. The recommended approach on OpenShift is a **passthrough Route** (see section 3.2.1).

### 1.4 RBAC Needs

- **cert-manager:**  
  - Add a **Role** in the namespace specified in `UpstreamAuthority.certManager.namespace` (or operator namespace if same):  
    - API group `cert-manager.io`, resource `certificaterequests`, verbs `get`, `list`, `create`, `delete`.  
  - **RoleBinding** from the existing SPIRE server ServiceAccount to this Role.  
  - Follow existing pattern: operator uses asset-based or generated Role/RoleBinding (e.g. like `SpireBundleRole` / `SpireBundleRoleBinding`), with namespace and labels from SpireServer spec.

- **vault:** No additional RBAC. Optional: if using K8s auth, Vault must be configured to accept the SPIRE server ServiceAccount (e.g. in operator namespace).

- **spire:** No additional RBAC.

### 1.5 Secret Management Strategy

- **cert-manager:** No secrets required for plugin config when using in-cluster client ([upstream docs](https://github.com/spiffe/spire/blob/main/doc/plugin_server_upstreamauthority_cert_manager.md)). The plugin uses the pod's in-cluster Kubernetes client (via the ServiceAccount token) to create `CertificateRequest` resources. The `kube_config_file` field is optional and only needed for cross-cluster cert-manager access (out of initial scope). The operator must ensure the SPIRE server ServiceAccount has RBAC permissions to create/get/list/delete `certificaterequests.cert-manager.io` in the configured namespace.

- **vault:**  
  The upstream SPIRE Vault plugin natively supports **environment variable fallbacks** for all sensitive fields ([source](https://github.com/spiffe/spire/blob/main/doc/plugin_server_upstreamauthority_vault.md)). The operator **must** use env var injection from Kubernetes Secrets as the primary strategy. This keeps the ConfigMap (`server.conf`) completely free of secrets and aligns with the upstream-documented "empty struct" pattern.

  | Auth Method | Sensitive Field | Env Variable | Empty Struct in Config |
  |---|---|---|---|
  | **Token** | `token` | `VAULT_TOKEN` | `token_auth {}` |
  | **AppRole** | `approle_id` | `VAULT_APPROLE_ID` | `approle_auth {}` or `approle_auth { approle_auth_mount_point = "..." }` |
  | **AppRole** | `approle_secret_id` | `VAULT_APPROLE_SECRET_ID` | (same struct) |
  | **Cert** | `client_cert_path` | `VAULT_CLIENT_CERT` | `cert_auth {}` or `cert_auth { cert_auth_mount_point = "..." }` |
  | **Cert** | `client_key_path` | `VAULT_CLIENT_KEY` | (same struct) |
  | **Global** | `vault_addr` | `VAULT_ADDR` | Omit from config |
  | **Global** | `ca_cert_path` | `VAULT_CACERT` | Omit from config |

  **Strategy per auth method:**
  - **Token auth:** Operator injects `VAULT_TOKEN` env var from `tokenSecretRef` via `valueFrom.secretKeyRef`. Config uses `token_auth {}` (empty struct). No file mount needed.
  - **Cert auth:** Operator mounts client cert + key Secret as files at fixed paths (e.g., `/run/spire/vault/tls.crt`, `/run/spire/vault/tls.key`) and sets those paths in `cert_auth { client_cert_path = "...", client_key_path = "..." }`. File mount is required here because cert/key must be PEM files on disk.
  - **AppRole auth:** Operator injects `VAULT_APPROLE_ID` and `VAULT_APPROLE_SECRET_ID` env vars from the AppRole Secret via `valueFrom.secretKeyRef`. Config uses `approle_auth {}` (empty struct, or with just `approle_auth_mount_point` if non-default). No file mount needed.
  - **K8s auth:** Uses a projected ServiceAccount token at a known path. Config sets `k8s_auth { k8s_auth_role_name = "...", token_path = "/var/run/secrets/tokens/vault" }`. The `token_path` references a projected volume (not a Secret), so no Secret mount needed.
  - **CA cert:** If `caCertSecretRef` is set, mount the Secret as a file at `/run/spire/vault/ca.crt` and set `ca_cert_path` in config. Alternatively, inject `VAULT_CACERT` env var pointing to the mount path.
  - **vault_addr:** Set as `VAULT_ADDR` env var on the container (non-sensitive, can also remain in ConfigMap). Having it as env var allows the operator to omit it from `server.conf` entirely.

  **Result:** The `server.conf` ConfigMap for a Vault token auth setup contains only:
  ```json
  "UpstreamAuthority": [{"vault": {"plugin_data": {"pki_mount_point": "pki", "token_auth": {}}}}]
  ```
  All sensitive values (`VAULT_ADDR`, `VAULT_TOKEN`) come from env vars injected by the operator from Kubernetes Secrets. The ConfigMap is safe to view, export, or commit to Git.

- **spire:** No secrets for plugin_data. Workload API socket is provided by mounting a volume (e.g. from another deployment or hostPath) at the path specified in `workload_api_socket`.

### 1.6 Security Considerations

- **Secrets in CR:** Do not add fields for raw tokens, AppRole secret_id, or private keys in the SpireServer CR. Use Secret references only (e.g. `secretRef.name` + optional `secretRef.key`).  
- **ConfigMap:** Generated `server.conf` must not contain tokens or private keys. Only paths, URLs, and non-sensitive plugin_data belong in the ConfigMap.  
- **Least privilege:** cert-manager Role scoped to the single namespace and only `certificaterequests`.  
- **Vault:** Prefer short-lived tokens or K8s auth over long-lived static tokens. Document that users are responsible for Vault policy and token lifecycle.  
- **Immutability:** Consider treating `spec.upstreamAuthority` as immutable (or with strict validation on change) to avoid accidental CA/trust changes; align with existing patterns (e.g. federation or persistence immutability).
- **Trust domain consistency (nested SPIRE):** The `spire` UpstreamAuthority plugin requires that upstream and downstream servers share the **same trust domain**. A trust domain mismatch results in the upstream rejecting the downstream's CA signing request. The operator webhook should reject configurations where a trust domain mismatch is detectable, and documentation should clearly state this requirement. This is distinct from federation, where different trust domains are expected.

---

## 2. API Changes

### 2.1 Design Principles (Existing Patterns)

- Optional feature structs are pointer types (e.g. `Federation *FederationConfig`).  
- Nested configs use explicit structs with `+kubebuilder:validation:*` and `+optional` where appropriate.  
- Sensitive data: Secret references (e.g. `TLSSecretName`, `ExternalSecretRef`) not inline values.  
- Immutability enforced via CRD `+kubebuilder:validation:XValidation` where required.

### 2.2 New Types in `SpireServerSpec`

Add to `SpireServerSpec` (in `api/v1alpha1/spire_server_config_types.go`):

```go
// UpstreamAuthority configures the SPIRE server to use an upstream CA (cert-manager, Vault, or SPIRE).
// Exactly one of CertManager, Vault, or Spire must be set.
// +kubebuilder:validation:Optional
UpstreamAuthority *UpstreamAuthorityConfig `json:"upstreamAuthority,omitempty"`
```

New structs (same file or adjacent):

```go
// UpstreamAuthorityConfig holds configuration for one of the supported UpstreamAuthority plugins.
// +kubebuilder:validation:XValidation:rule="(has(self.certManager) && !has(self.vault) && !has(self.spire)) || (!has(self.certManager) && has(self.vault) && !has(self.spire)) || (!has(self.certManager) && !has(self.vault) && has(self.spire))",message="exactly one of certManager, vault, or spire must be set"
type UpstreamAuthorityConfig struct {
    CertManager *UpstreamAuthorityCertManager `json:"certManager,omitempty"`
    Vault       *UpstreamAuthorityVault       `json:"vault,omitempty"`
    Spire       *UpstreamAuthoritySpire       `json:"spire,omitempty"`
}

// UpstreamAuthorityCertManager configures the cert-manager UpstreamAuthority plugin.
type UpstreamAuthorityCertManager struct {
    // Namespace where CertificateRequest resources are created.
    // +kubebuilder:validation:Required
    // +kubebuilder:validation:MinLength=1
    // +kubebuilder:validation:MaxLength=63
    Namespace string `json:"namespace"`

    // IssuerName is the name of the cert-manager Issuer or ClusterIssuer.
    // +kubebuilder:validation:Required
    // +kubebuilder:validation:MinLength=1
    // +kubebuilder:validation:MaxLength=253
    IssuerName string `json:"issuerName"`

    // IssuerKind is the kind of the issuer (e.g. "Issuer", "ClusterIssuer").
    // +kubebuilder:validation:Optional
    // +kubebuilder:validation:Enum=Issuer;ClusterIssuer
    // +kubebuilder:default:=Issuer
    IssuerKind string `json:"issuerKind,omitempty"`

    // IssuerGroup is the API group of the issuer (e.g. "cert-manager.io").
    // +kubebuilder:validation:Optional
    // +kubebuilder:validation:MaxLength=253
    // +kubebuilder:default:=cert-manager.io
    IssuerGroup string `json:"issuerGroup,omitempty"`
}

// UpstreamAuthorityVault configures the Vault UpstreamAuthority plugin.
// Exactly one of TokenAuth, CertAuth, AppRoleAuth, or K8sAuth must be set.
// +kubebuilder:validation:XValidation:rule="(has(self.tokenAuth) && !has(self.certAuth) && !has(self.appRoleAuth) && !has(self.k8sAuth)) || (!has(self.tokenAuth) && has(self.certAuth) && !has(self.appRoleAuth) && !has(self.k8sAuth)) || (!has(self.tokenAuth) && !has(self.certAuth) && has(self.appRoleAuth) && !has(self.k8sAuth)) || (!has(self.tokenAuth) && !has(self.certAuth) && !has(self.appRoleAuth) && has(self.k8sAuth))",message="exactly one of tokenAuth, certAuth, approleAuth, or k8sAuth must be set"
type UpstreamAuthorityVault struct {
    // VaultAddr is the Vault server URL (e.g. https://vault.example.com:8200/).
    // +kubebuilder:validation:Required
    // +kubebuilder:validation:Pattern=`^https?://.+`
    VaultAddr string `json:"vaultAddr"`

    // PKIMountPoint is the mount path of the Vault PKI secrets engine (e.g. pki_int).
    // +kubebuilder:validation:Optional
    // +kubebuilder:validation:MaxLength=255
    PKIMountPoint string `json:"pkiMountPoint,omitempty"`

    // CACertSecretRef references a Secret containing the CA certificate for Vault TLS verification.
    // Secret key defaults to "ca.crt"; mount path in pod is fixed (e.g. /run/spire/vault/ca.crt).
    // +kubebuilder:validation:Optional
    CACertSecretRef *SecretKeyReference `json:"caCertSecretRef,omitempty"`

    // InsecureSkipVerify disables TLS verification for Vault (not recommended for production).
    // +kubebuilder:validation:Optional
    // +kubebuilder:default:=false
    InsecureSkipVerify bool `json:"insecureSkipVerify,omitempty"`

    // VaultNamespace is the Vault enterprise namespace.
    // +kubebuilder:validation:Optional
    // +kubebuilder:validation:MaxLength=255
    VaultNamespace string `json:"vaultNamespace,omitempty"`

    TokenAuth   *VaultTokenAuthConfig   `json:"tokenAuth,omitempty"`
    CertAuth    *VaultCertAuthConfig    `json:"certAuth,omitempty"`
    AppRoleAuth *VaultAppRoleAuthConfig `json:"appRoleAuth,omitempty"`
    K8sAuth     *VaultK8sAuthConfig     `json:"k8sAuth,omitempty"`
}

// SecretKeyReference references a key in a Secret in the same namespace as the operator/operands.
type SecretKeyReference struct {
    Name string `json:"name"`
    // +kubebuilder:validation:Optional
    // +kubebuilder:default:=ca.crt
    Key string `json:"key,omitempty"`
}

// VaultTokenAuthConfig configures Vault token authentication.
// The token is injected as the VAULT_TOKEN environment variable from the referenced Secret.
// The ConfigMap uses the empty struct pattern: token_auth {} — SPIRE reads VAULT_TOKEN at runtime.
// Reference: https://github.com/spiffe/spire/blob/main/doc/plugin_server_upstreamauthority_vault.md#token-authentication
type VaultTokenAuthConfig struct {
    // TokenSecretRef references a Secret containing the Vault token.
    // The operator injects the value as the VAULT_TOKEN env var on the spire-server container.
    // +kubebuilder:validation:Required
    TokenSecretRef SecretKeyReference `json:"tokenSecretRef"`
}

// VaultCertAuthConfig configures Vault client certificate authentication.
// Client cert and key must be PEM files on disk — the operator mounts them from the referenced Secret
// at fixed paths (/run/spire/vault/tls.crt, /run/spire/vault/tls.key) and sets those paths in plugin_data.
// Reference: https://github.com/spiffe/spire/blob/main/doc/plugin_server_upstreamauthority_vault.md#client-certificate-authentication
type VaultCertAuthConfig struct {
    // CertAuthMountPoint is the Vault auth mount point (defaults to "cert" per upstream).
    // +kubebuilder:validation:Optional
    CertAuthMountPoint string `json:"certAuthMountPoint,omitempty"`
    // CertAuthRoleName is the Vault role name for cert auth.
    // +kubebuilder:validation:Optional
    CertAuthRoleName string `json:"certAuthRoleName,omitempty"`
    // ClientCertSecretRef references a Secret containing the client certificate PEM (e.g. key "tls.crt").
    // Mounted at /run/spire/vault/tls.crt; path set in plugin_data.client_cert_path.
    // +kubebuilder:validation:Required
    ClientCertSecretRef SecretKeyReference `json:"clientCertSecretRef"`
    // ClientKeySecretRef references a Secret containing the client private key PEM (e.g. key "tls.key").
    // Mounted at /run/spire/vault/tls.key; path set in plugin_data.client_key_path.
    // +kubebuilder:validation:Required
    ClientKeySecretRef  SecretKeyReference `json:"clientKeySecretRef"`
}

// VaultAppRoleAuthConfig configures Vault AppRole authentication.
// The operator injects VAULT_APPROLE_ID and VAULT_APPROLE_SECRET_ID env vars from the referenced Secret.
// The ConfigMap uses the empty struct pattern: approle_auth {} (or with just approle_auth_mount_point).
// Reference: https://github.com/spiffe/spire/blob/main/doc/plugin_server_upstreamauthority_vault.md#approle-authentication
type VaultAppRoleAuthConfig struct {
    // AppRoleMountPoint is the Vault auth mount point (defaults to "approle" per upstream).
    // +kubebuilder:validation:Optional
    AppRoleMountPoint string `json:"appRoleMountPoint,omitempty"`
    // AppRoleSecretRef references a Secret containing role_id and secret_id.
    // The operator injects these as VAULT_APPROLE_ID and VAULT_APPROLE_SECRET_ID env vars.
    // +kubebuilder:validation:Required
    AppRoleSecretRef VaultAppRoleSecretRef `json:"appRoleSecretRef"`
}

// VaultAppRoleSecretRef references a Secret with AppRole credentials (role_id and secret_id).
type VaultAppRoleSecretRef struct {
    // Name is the Secret name in the operator namespace.
    Name string `json:"name"`
    // RoleIDKey is the Secret key for the AppRole role_id. Injected as VAULT_APPROLE_ID env var.
    // +kubebuilder:validation:Optional
    // +kubebuilder:default:=role_id
    RoleIDKey   string `json:"roleIDKey,omitempty"`
    // SecretIDKey is the Secret key for the AppRole secret_id. Injected as VAULT_APPROLE_SECRET_ID env var.
    // +kubebuilder:validation:Optional
    // +kubebuilder:default:=secret_id
    SecretIDKey string `json:"secretIDKey,omitempty"`
}

// VaultK8sAuthConfig configures Vault Kubernetes authentication.
// Uses a projected ServiceAccount token at a known path — no Secret mount needed.
// The operator adds a projected volume with the Vault audience and sets token_path in plugin_data.
// Reference: https://github.com/spiffe/spire/blob/main/doc/plugin_server_upstreamauthority_vault.md#kubernetes-authentication
type VaultK8sAuthConfig struct {
    // K8sAuthMountPoint is the Vault auth mount point (defaults to "kubernetes" per upstream).
    // +kubebuilder:validation:Optional
    K8sAuthMountPoint string `json:"k8sAuthMountPoint,omitempty"`
    // K8sAuthRoleName is the Vault role name. Required per upstream docs.
    // +kubebuilder:validation:Required
    K8sAuthRoleName string `json:"k8sAuthRoleName"`
    // TokenPath is the path to the projected Kubernetes SA token.
    // The operator provisions a projected volume at this path with the appropriate audience.
    // +kubebuilder:validation:Optional
    // +kubebuilder:default:=/var/run/secrets/tokens/vault
    TokenPath string `json:"tokenPath,omitempty"`
}

// UpstreamAuthoritySpire configures the SPIRE UpstreamAuthority plugin (nested/hierarchical SPIRE).
//
// Architecture: The downstream SPIRE server connects to an upstream SPIRE server for CA signing.
// An upstream-agent sidecar (running in the downstream's StatefulSet) attests to the upstream
// and provides a Workload API socket. The downstream SPIRE server uses this socket to authenticate
// and request CA signing from the upstream.
//
// The upstream SPIRE server endpoint is exposed via a passthrough Route (recommended on OpenShift)
// or a LoadBalancer Service. When using a Route, the agent connects on port 443.
type UpstreamAuthoritySpire struct {
    // ServerAddress is the hostname of the upstream SPIRE server endpoint.
    // For passthrough Route: the Route hostname (e.g. spire-server-<ns>.apps.<cluster-domain>).
    // For LoadBalancer: the LB hostname or IP.
    // +kubebuilder:validation:Required
    // +kubebuilder:validation:MinLength=1
    // +kubebuilder:validation:MaxLength=253
    ServerAddress string `json:"serverAddress"`

    // ServerPort is the port of the upstream SPIRE server endpoint.
    // Use "443" when connecting through an OpenShift passthrough Route.
    // Use "8081" when connecting through a LoadBalancer or ClusterIP Service directly.
    // +kubebuilder:validation:Required
    // +kubebuilder:validation:MinLength=1
    // +kubebuilder:validation:MaxLength=5
    // +kubebuilder:validation:Pattern=`^[0-9]+$`
    ServerPort string `json:"serverPort"`

    // WorkloadAPISocket is the path to the upstream Workload API socket in the pod
    // (e.g. /run/spire/upstream-agent/spire-agent.sock).
    // The operator provisions an upstream-agent sidecar that writes this socket to a
    // shared emptyDir volume, which is also mounted by the SPIRE server container.
    // +kubebuilder:validation:Required
    // +kubebuilder:validation:MinLength=1
    // +kubebuilder:validation:MaxLength=1024
    WorkloadAPISocket string `json:"workloadAPISocket"`

    // UpstreamBundle is a reference to a ConfigMap containing the upstream SPIRE server's
    // trust bundle (key: "bundle.crt") for bootstrapping the upstream-agent sidecar.
    // +kubebuilder:validation:Optional
    UpstreamBundleConfigMapRef *string `json:"upstreamBundleConfigMapRef,omitempty"`

    // UpstreamClusterName is the cluster name used for k8s_psat attestation to the upstream.
    // Must match the cluster name configured in the upstream SPIRE server's NodeAttestor.
    // +kubebuilder:validation:Optional
    // +kubebuilder:validation:MaxLength=253
    UpstreamClusterName string `json:"upstreamClusterName,omitempty"`

    // ExportRoute controls whether the operator creates a passthrough Route to expose
    // this SPIRE server's gRPC API for cross-cluster nested SPIRE.
    // When true, the operator creates a passthrough Route on port 443 targeting the
    // SPIRE server's gRPC port (8081).
    // +kubebuilder:validation:Optional
    // +kubebuilder:default:=false
    ExportRoute bool `json:"exportRoute,omitempty"`
}
```

**Note on Vault secret injection strategy:** The operator uses the upstream-documented environment variable fallback mechanism for all Vault auth methods where applicable. Per the [upstream Vault plugin documentation](https://github.com/spiffe/spire/blob/main/doc/plugin_server_upstreamauthority_vault.md):
- `token_auth {}` (empty struct) → SPIRE reads `VAULT_TOKEN` from environment
- `approle_auth {}` (empty struct) → SPIRE reads `VAULT_APPROLE_ID` and `VAULT_APPROLE_SECRET_ID` from environment
- `cert_auth {}` (empty struct) → SPIRE reads `VAULT_CLIENT_CERT` and `VAULT_CLIENT_KEY` from environment (but these are file paths, so the operator still mounts the actual PEM files and sets the paths explicitly)

This ensures the ConfigMap (`server.conf`) contains **zero sensitive values** — all secrets are injected at runtime via Kubernetes Secret → env var mapping.

### 2.3 CRD YAML Snippet (Structural)

```yaml
# Under spec of SpireServer
upstreamAuthority:
  type: object
  description: "Configures upstream CA (cert-manager, Vault, or SPIRE). Exactly one of certManager, vault, spire must be set."
  x-kubernetes-validation-rules:
    - rule: "(has(self.certManager) && !has(self.vault) && !has(self.spire)) || (!has(self.certManager) && has(self.vault) && !has(self.spire)) || (!has(self.certManager) && !has(self.vault) && has(self.spire))"
      message: "exactly one of certManager, vault, or spire must be set"
  properties:
    certManager:
      type: object
      required: [ "namespace", "issuerName" ]
      properties:
        namespace:    { type: string, minLength: 1, maxLength: 63 }
        issuerName:   { type: string, minLength: 1, maxLength: 253 }
        issuerKind:   { type: string, enum: [ "Issuer", "ClusterIssuer" ], default: "Issuer" }
        issuerGroup:  { type: string, maxLength: 253, default: "cert-manager.io" }
    vault:
      type: object
      required: [ "vaultAddr" ]
      properties:
        vaultAddr:           { type: string, pattern: "^https?://.+" }
        pkiMountPoint:       { type: string, maxLength: 255 }
        caCertSecretRef:     { $ref: "#/components/schemas/SecretKeyReference" }
        insecureSkipVerify:  { type: boolean, default: false }
        vaultNamespace:     { type: string, maxLength: 255 }
        tokenAuth:   { $ref: "#/components/schemas/VaultTokenAuthConfig" }
        certAuth:    { $ref: "#/components/schemas/VaultCertAuthConfig" }
        approleAuth: { $ref: "#/components/schemas/VaultAppRoleAuthConfig" }
        k8sAuth:     { $ref: "#/components/schemas/VaultK8sAuthConfig" }
      # one-of: tokenAuth, certAuth, approleAuth, k8sAuth (enforced by x-kubernetes-validation-rules)
    spire:
      type: object
      required: [ "serverAddress", "serverPort", "workloadAPISocket" ]
      properties:
        serverAddress:              { type: string, minLength: 1, maxLength: 253 }
        serverPort:                 { type: string, minLength: 1, maxLength: 5, pattern: "^[0-9]+$" }
        workloadAPISocket:          { type: string, minLength: 1, maxLength: 1024 }
        upstreamBundleConfigMapRef: { type: string, description: "ConfigMap name containing upstream trust bundle (key: bundle.crt)" }
        upstreamClusterName:        { type: string, maxLength: 253, description: "Cluster name for k8s_psat attestation to upstream" }
        exportRoute:                { type: boolean, default: false, description: "Create a passthrough Route to expose this server's gRPC API" }
  optional: [ "certManager", "vault", "spire" ]
```

### 2.4 Backward Compatibility

- `UpstreamAuthority` is optional. When omitted, server config is unchanged (no `UpstreamAuthority` block); behavior remains self-signed/on-disk CA as today.

---

## 3. Reconciliation Design

### 3.1 Step-by-Step Reconciliation Loop

1. **Read SpireServer and ZTWIM** (unchanged).

2. **Validate configuration (extend existing `validateConfiguration`):**
   - If `spec.upstreamAuthority != nil`:
     - Call `validateUpstreamAuthorityConfig(spec.UpstreamAuthority)`:
       - Exactly one of `certManager`, `vault`, `spire` set.
       - **cert-manager:** `namespace`, `issuerName` non-empty; namespace format valid.
       - **vault:** `vaultAddr` non-empty; exactly one of token/cert/approle/k8s auth; for token/cert/approle, referenced Secret must exist (optional check; or fail at config-generation time).
       - **spire:** `serverAddress`, `serverPort`, `workloadAPISocket` non-empty. **Trust domain check:** The downstream's `spec.trustDomain` must match the upstream's trust domain (nested SPIRE requires the same trust domain; see section 1.2). If the operator can discover the upstream's trust domain (e.g., via a status field or user-provided config), validate at admission time.
     - On failure: set `ConfigurationValid` condition False, return (no further reconciliation of server resources).

3. **Reconcile ServiceAccount / Services / RBAC (existing order):**
   - **If UpstreamAuthority is cert-manager:** After existing RBAC, reconcile **cert-manager Role + RoleBinding** in the namespace specified in `spec.upstreamAuthority.certManager.namespace` (or operator namespace):
     - Role: `certificaterequests` in `cert-manager.io`, verbs `get`, `list`, `create`, `delete`.
     - RoleBinding: subject = SPIRE server ServiceAccount (operator namespace), roleRef = new Role.
     - Use same create/update pattern and controller reference as existing Roles (e.g. SpireBundleRole).

4. **Reconcile ConfigMaps:**
   - **Spire Server ConfigMap:** In `generateServerConfMap` (or equivalent), when building `plugins`:
     - If `spec.upstreamAuthority == nil`: do not add `UpstreamAuthority` to plugins (current behavior).
     - If `spec.upstreamAuthority != nil`:
       - Build a single `UpstreamAuthority` entry with plugin name `"cert-manager"`, `"vault"`, or `"spire"` and `plugin_data` as below.
       - **cert-manager:** `plugin_data`: `namespace`, `issuer_name`, `issuer_kind`, `issuer_group` from spec; omit `kube_config_file` (uses in-cluster Kubernetes client per [upstream docs](https://github.com/spiffe/spire/blob/main/doc/plugin_server_upstreamauthority_cert_manager.md)). No secrets, no env vars, no file mounts needed — the cleanest plugin from a secret management perspective.
       - **vault:** `plugin_data` uses the **empty struct pattern** for auth methods that support env vars. The operator generates minimal config and injects sensitive values via environment variables from Kubernetes Secrets:
         - `pki_mount_point` (from spec, or default `"pki"`), `insecure_skip_verify` (if true), `namespace` (vaultNamespace, if set), `ca_cert_path` (if `caCertSecretRef` set, path `/run/spire/vault/ca.crt`).
         - `vault_addr` is omitted from config — injected as `VAULT_ADDR` env var.
         - **token_auth:** Config contains `"token_auth": {}` (empty). Operator injects `VAULT_TOKEN` env var from `tokenSecretRef` via `valueFrom.secretKeyRef`. No file mount.
         - **approle_auth:** Config contains `"approle_auth": {}` (or `{"approle_auth_mount_point": "..."}` if non-default). Operator injects `VAULT_APPROLE_ID` and `VAULT_APPROLE_SECRET_ID` env vars from `appRoleSecretRef` via `valueFrom.secretKeyRef`. No file mount.
         - **cert_auth:** Config contains `"cert_auth": {"client_cert_path": "/run/spire/vault/tls.crt", "client_key_path": "/run/spire/vault/tls.key"}` (and optionally `cert_auth_mount_point`, `cert_auth_role_name`). File mount required — operator mounts the cert/key Secret at the fixed paths.
         - **k8s_auth:** Config contains `"k8s_auth": {"k8s_auth_role_name": "...", "token_path": "/var/run/secrets/tokens/vault"}` (and optionally `k8s_auth_mount_point`). Operator adds a projected SA token volume.
       - **spire:** `plugin_data`: `server_address`, `server_port`, `workload_api_socket` from spec.
     - Config hash must include the full server config (including UpstreamAuthority) so ConfigMap changes trigger rollout.

5. **Reconcile StatefulSet (extend `GenerateSpireServerStatefulSet`):**
   - **Environment variables for spire-server container (Vault auth — primary strategy):**
     The operator injects sensitive values as env vars from Kubernetes Secrets using `valueFrom.secretKeyRef`. This keeps the ConfigMap free of secrets and uses the upstream-documented env var fallback pattern.

     - **Vault token auth:** Inject `VAULT_TOKEN` env var from `tokenAuth.tokenSecretRef`:
       ```yaml
       env:
       - name: VAULT_ADDR
         value: "<spec.vault.vaultAddr>"
       - name: VAULT_TOKEN
         valueFrom:
           secretKeyRef:
             name: "<tokenSecretRef.name>"
             key: "<tokenSecretRef.key>"    # default: "token"
       ```
     - **Vault AppRole auth:** Inject `VAULT_APPROLE_ID` and `VAULT_APPROLE_SECRET_ID` from `appRoleAuth.appRoleSecretRef`:
       ```yaml
       env:
       - name: VAULT_ADDR
         value: "<spec.vault.vaultAddr>"
       - name: VAULT_APPROLE_ID
         valueFrom:
           secretKeyRef:
             name: "<appRoleSecretRef.name>"
             key: "<appRoleSecretRef.roleIDKey>"     # default: "role_id"
       - name: VAULT_APPROLE_SECRET_ID
         valueFrom:
           secretKeyRef:
             name: "<appRoleSecretRef.name>"
             key: "<appRoleSecretRef.secretIDKey>"   # default: "secret_id"
       ```

   - **Volumes / volumeMounts for spire-server container (file mounts — only when required):**
     - **Vault CA cert:** If `spec.upstreamAuthority.vault.caCertSecretRef != nil`: add Volume from that Secret, mount at `/run/spire/vault/ca.crt`. Set `ca_cert_path` in plugin_data to this path.
     - **Vault cert auth:** If `spec.upstreamAuthority.vault.certAuth != nil`: add Volume(s) from `clientCertSecretRef` and `clientKeySecretRef`, mount at `/run/spire/vault/tls.crt` and `/run/spire/vault/tls.key`. Set `client_cert_path` and `client_key_path` in plugin_data. File mount is required here because SPIRE reads PEM files from disk.
     - **Vault K8s auth:** Add a projected SA token volume with the Vault audience at the path specified in `tokenPath` (default `/var/run/secrets/tokens/vault`).
     - **Spire upstream:** If `spec.upstreamAuthority.spire != nil`: inject the upstream-agent **sidecar container** and its associated volumes into the StatefulSet (see section 3.2.2). Add: `emptyDir` for the shared Workload API socket, upstream bundle ConfigMap volume, agent config ConfigMap volume, projected SA token volume, and agent data `emptyDir`. The operator generates the `upstream-agent-config` ConfigMap from the `spire` spec fields.
   - **Config hash:** Already included in pod template annotations; no change to hash logic except that server.conf now includes UpstreamAuthority, so hash changes when UpstreamAuthority changes.

6. **Reconcile StatefulSet (create/update):** Unchanged flow; use existing `needsUpdate` and create-only mode behavior. Pod template annotation has config hash; when ConfigMap or UpstreamAuthority-related volumes change, hash changes and rollout is triggered.

7. **Reconcile Route / Controller Manager / Bundle:**
   - **If `spec.upstreamAuthority.spire.exportRoute == true`:** Reconcile the `spire-server-external` ClusterIP Service and `spire-server` passthrough Route (see section 3.2.1). Set owner references so they are garbage-collected if the SpireServer CR is deleted.
   - **If `exportRoute == false` or not set:** Ensure no orphaned Route/Service exist (delete if previously created).
   - Controller Manager and Bundle reconciliation unchanged.

### 3.2 Nested SPIRE Reconciliation

When `spec.upstreamAuthority.spire` is configured, the operator must provision additional resources. The requirements fall into two categories:

**Core requirements (always needed):**
- A SPIRE agent co-located with the downstream SPIRE server, attested to the **upstream** server
- A shared Workload API socket between the agent and the downstream server
- A registered entry on the upstream for the downstream server (with `-downstream` flag)
- The **same trust domain** on both upstream and downstream

> Reference: [SPIFFE Nested SPIRE](https://spiffe.io/docs/latest/architecture/nested/readme/) — *"Nested topologies work by co-locating a SPIRE Agent with every downstream SPIRE Server being chained. The downstream SPIRE Server obtains credentials over the Workload API that it uses to directly authenticate with the upstream SPIRE Server to obtain an intermediate CA."*

On Kubernetes, "co-located" can be achieved in two ways (see section 3.2.2 for the full comparison):

1. **DaemonSet + CSI driver (upstream Helm chart approach):** A separate `upstream-spire-agent` DaemonSet runs on every node, and a separate `upstream-spiffe-csi-driver` DaemonSet exposes the agent's socket as a CSI volume. The downstream SPIRE server StatefulSet mounts this CSI volume. This is the approach used by the [official SPIRE Helm chart](https://github.com/spiffe/helm-charts-hardened/tree/main/charts/spire-nested).

2. **Sidecar container (tested alternative):** An upstream-agent container is injected directly into the downstream SPIRE server's StatefulSet pod, sharing the socket via an `emptyDir` volume. This was the approach used during E2E testing (see test report).

**Cross-cluster extras (only when upstream and downstream are on different clusters):**
- Passthrough Route or LoadBalancer to expose the upstream SPIRE server's gRPC API
- Cross-cluster PSAT validation via kubeconfig Secret (section 3.2.3)
- Remote cluster RBAC (`system:auth-delegator`, pod/node read)

**OpenShift-specific considerations:**
- `hostPID` is restricted — the upstream Docker Compose tutorial uses `pid: "host"` but this is not available under OpenShift's default SCCs
- If using the sidecar approach: `unix` WorkloadAttestor must be used instead of `k8s` (kubelet API at `127.0.0.1:10250` is not accessible from within a non-hostNetwork pod)
- If using the DaemonSet approach: the upstream agent DaemonSet may require `hostPath` volumes and elevated SCCs similar to the existing `SpireAgent` operand

#### 3.2.1 Upstream SPIRE Server Endpoint Exposure (Route)

When the SpireServer is acting as an **upstream** (i.e., `spec.upstreamAuthority.spire.exportRoute == true`), the operator creates:

1. **ClusterIP Service** (`spire-server-external`) targeting the SPIRE server's gRPC port (8081):

```yaml
apiVersion: v1
kind: Service
metadata:
  name: spire-server-external
  namespace: <operator-namespace>
  labels:
    app.kubernetes.io/managed-by: ztwim-operator
spec:
  selector:
    app.kubernetes.io/name: spire-server
    app.kubernetes.io/instance: <instance>
  ports:
  - name: grpc
    port: 8081
    targetPort: 8081
```

2. **Passthrough Route** (`spire-server`) forwarding TLS/gRPC traffic without termination:

```yaml
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: spire-server
  namespace: <operator-namespace>
  labels:
    app.kubernetes.io/managed-by: ztwim-operator
spec:
  port:
    targetPort: grpc
  tls:
    termination: passthrough
  to:
    kind: Service
    name: spire-server-external
```

**Why passthrough?** SPIRE uses gRPC over mTLS. The passthrough Route forwards raw TCP so the SPIRE mTLS handshake happens end-to-end between the agent and server. Edge or reencrypt termination would break mTLS.

**Advantages over LoadBalancer:**
- Cloud-agnostic (works on any OpenShift: AWS, GCP, bare-metal, on-prem)
- Route hostname available immediately (no DNS propagation delay)
- No security group configuration required
- Native OpenShift approach

**Port mapping:** Clients connect to port **443** (the OpenShift router's HTTPS port). The router forwards to the Service on port 8081. The downstream's `serverPort` must be set to `"443"` when using a Route.

The Route hostname is deterministic: `spire-server-<namespace>.apps.<cluster-domain>`. The operator should expose this in the SpireServer's `.status` for the downstream to consume.

#### 3.2.2 Upstream Agent Co-location — Approach Comparison

The downstream SPIRE server needs access to an upstream-attested agent's Workload API socket. There are two approaches to achieve this on Kubernetes:

##### Option A: DaemonSet + CSI Driver (Upstream Helm Chart Approach)

This is the approach used by the [official SPIRE Helm chart (`spire-nested`)](https://github.com/spiffe/helm-charts-hardened/tree/main/charts/spire-nested):

| Component | Kind | Configuration |
|---|---|---|
| `upstream-spire-agent` | **DaemonSet** | Separate SPIRE agent instance connecting to the upstream/root server. Socket at `/run/spire/agent-sockets-upstream/spire-agent.sock`. Own health check port (9981), telemetry port (9989), ServiceAccount (`spire-agent-upstream`). |
| `upstream-spiffe-csi-driver` | **DaemonSet** | Separate CSI driver (plugin name `upstream.csi.spiffe.io`) that exposes the upstream agent's socket as a CSI volume. |
| Downstream SPIRE server | **StatefulSet** | Mounts the upstream agent socket via CSI volume (`upstreamDriver: upstream.csi.spiffe.io`). |

**How it works:** The upstream agent DaemonSet runs on every node. When the downstream SPIRE server pod is scheduled on a node, the CSI driver provides the upstream agent's socket to the server pod as a volume mount. The server's `UpstreamAuthority "spire"` plugin uses this socket to authenticate and obtain an intermediate CA.

**Advantages:**
- Standard upstream pattern — directly matches the official Helm chart
- The agent DaemonSet runs on every node, so the server pod can be scheduled anywhere
- Uses `k8s_psat` NodeAttestor and standard `k8s` WorkloadAttestor (no `unix` attestor needed)
- Agent lifecycle is independent of the server pod
- CSI driver handles socket path mapping cleanly

**Considerations for ZTWIM:**
- Requires the operator to manage two additional DaemonSets (agent + CSI driver) per cluster when nested SPIRE is enabled
- The upstream agent DaemonSet needs similar SCCs/permissions as the existing `SpireAgent` operand (`hostPath`, `hostPID`, `hostNetwork` for `k8s` attestor with kubelet CA access)
- The CSI driver DaemonSet also needs elevated permissions (similar to existing `SpiffeCSIDriver` operand)

**OpenShift-Specific Constraint (E2E validated 2026-03-06):**

The CSI-based socket mounting **does not work on OpenShift** due to SELinux MCS (Multi-Category Security) enforcement:
- The upstream agent DaemonSet runs as a privileged container (root user, `s0` SELinux context)
- The downstream SPIRE server runs as a restricted container with MCS labels (`s0:cX,cY`)
- The SPIFFE CSI driver creates a bind mount from the agent's hostPath socket to the CSI volume target, which retains the original `s0` SELinux context
- The server container cannot access the socket because `container_t` with MCS labels cannot connect to a socket labeled `container_var_run_t:s0` (no matching MCS categories)
- Setting `seLinuxMount: true` on the CSIDriver spec did not fix the issue (the bind mount retains the source labels)

**Workaround (validated):** Use a direct `hostPath` volume mount instead of CSI, with a custom SCC that sets `seLinuxContext: RunAsAny` and applies `seLinuxOptions: {type: spc_t, level: s0}` in the pod spec. This allows the server container to access the hostPath-mounted socket.

**Implication for the operator:** On OpenShift, the upstream CSI driver DaemonSet is **not required** for the downstream SPIRE server to access the upstream agent socket. The operator should use hostPath for the server pod's upstream agent socket mount. The CSI driver DaemonSet may still be useful if other workloads need to access the upstream agent's Workload API.

##### Option B: Sidecar Container (E2E Test Approach)

This is the approach that was used during the E2E testing for this design:

| Component | Kind | Configuration |
|---|---|---|
| `upstream-agent` | **Sidecar container** in downstream StatefulSet | Agent container injected into the downstream SPIRE server pod, sharing an `emptyDir` for the Workload API socket. |

**How it works:** The operator adds an upstream-agent container to the downstream SPIRE server's StatefulSet pod spec. Both containers share an `emptyDir` volume — the agent writes the socket, and the server reads it. No additional DaemonSets or CSI drivers needed.

**Sidecar container details:**

| Property | Value |
|----------|-------|
| Name | `upstream-agent` |
| Image | Same SPIRE agent image as `SpireAgent` operand |
| Config | From ConfigMap `upstream-agent-config` (generated by operator) |
| Socket path | `spec.upstreamAuthority.spire.workloadAPISocket` (written to shared emptyDir) |
| Trust bundle | Mounted from ConfigMap referenced by `upstreamBundleConfigMapRef` |
| SA token | Projected volume at `/var/run/secrets/tokens/spire-agent` (audience: `spire-server`) |

**Agent config generation (sidecar):**

```json
{
  "agent": {
    "data_dir": "/run/spire/data",
    "log_level": "INFO",
    "server_address": "<spec.upstreamAuthority.spire.serverAddress>",
    "server_port": "<spec.upstreamAuthority.spire.serverPort>",
    "socket_path": "<spec.upstreamAuthority.spire.workloadAPISocket>",
    "trust_domain": "<spec.trustDomain>",
    "trust_bundle_path": "/run/spire/bundle/bundle.crt"
  },
  "plugins": {
    "NodeAttestor": [{"k8s_psat": {"plugin_data": {"cluster": "<upstreamClusterName>"}}}],
    "KeyManager": [{"memory": {"plugin_data": {}}}],
    "WorkloadAttestor": [{"unix": {"plugin_data": {}}}]
  }
}
```

**Shared volumes added to StatefulSet:**

| Volume | Type | Purpose |
|--------|------|---------|
| `upstream-agent-socket` | `emptyDir` | Shared Workload API socket between sidecar and SPIRE server |
| `upstream-agent-config` | `ConfigMap` | Agent configuration |
| `upstream-bundle` | `ConfigMap` | Upstream trust bundle for bootstrap |
| `upstream-agent-data` | `emptyDir` | Agent runtime data |
| `upstream-agent-token` | `projected` (SA token) | PSAT attestation token |

**Advantages:**
- Simpler — no additional DaemonSets or CSI drivers to deploy and manage
- Self-contained — all nested SPIRE resources are in the server's StatefulSet
- Fewer SCCs needed — the sidecar runs in the same security context as the SPIRE server

**Limitations (discovered during E2E testing):**
- Requires `unix` WorkloadAttestor instead of `k8s` — the kubelet API at `127.0.0.1:10250` is not accessible from within a non-hostNetwork pod. The `unix` attestor matches by UID, which works because all containers in the pod share the same OpenShift-assigned UID.
- Agent lifecycle is tied to the server pod — if the sidecar crashes, it affects the server pod
- Not the upstream-documented pattern — may diverge from future upstream improvements

##### Recommendation

**Option A (DaemonSet + hostPath)** is the recommended approach for the operator because:
1. It follows the official SPIRE Helm chart DaemonSet pattern (with hostPath adaptation for OpenShift)
2. ZTWIM already manages `SpireAgent` (DaemonSet) and `SpiffeCSIDriver` (DaemonSet) operands, so the operator already has reconciliation logic for these resource types
3. No `unix` attestor workaround needed — uses standard `k8s_psat` + `k8s` attestors
4. Agent and server lifecycles are decoupled

**Important:** On OpenShift, the operator must use **hostPath** (not CSI) for mounting the upstream agent socket into the downstream server pod due to the SELinux MCS constraint documented above. The operator must also provision a custom SCC for the downstream server pod that allows `spc_t` SELinux type.

The operator would provision the upstream agent DaemonSet (with distinct name, socket path, and ports) when `spec.upstreamAuthority.spire` is configured on the downstream. The upstream CSI driver DaemonSet is optional — it is only needed if other workloads (besides the SPIRE server) need CSI-based access to the upstream agent's Workload API.

**Option B (sidecar)** remains a viable alternative and is simpler from an SCC perspective because `emptyDir` volumes avoid the SELinux issue entirely. It was validated end-to-end during testing (see Test Report Section 5). Choose the sidecar approach when:
- Resource-constrained environments where additional DaemonSets are undesirable
- Simpler security posture is preferred (no `spc_t` SELinux type needed)
- The `unix:uid` selector for entry registration is acceptable

#### 3.2.3 Cross-Cluster PSAT Validation

For the upstream SPIRE server to validate tokens from agents on a different cluster, it needs:

1. **Kubeconfig Secret** — containing the downstream cluster's API URL, CA cert, and a ServiceAccount token with `system:auth-delegator` permissions
2. **Mounted in upstream StatefulSet** — at a fixed path (e.g., `/run/spire/remote-cluster-creds/`)
3. **Referenced in upstream's k8s_psat config** — the `kube_config_file` field points to the mounted kubeconfig

The operator on the upstream cluster should:
- Accept a Secret reference for remote cluster credentials
- Mount it into the SPIRE server pod
- Add the remote cluster entry to the `k8s_psat` NodeAttestor `clusters` configuration

#### 3.2.4 Downstream Entry Registration

The upstream SPIRE server must have a registered entry for the downstream SPIRE server:
- **SPIFFE ID:** `spiffe://<trust-domain>/downstream/spire-server`
- **Parent ID:** The upstream agent's SPIFFE ID
- **Selector:**
  - Option A (DaemonSet): `k8s:pod-label:app.kubernetes.io/name:spire-server` or similar Kubernetes-native selectors (the `k8s` WorkloadAttestor is available since the DaemonSet agent has kubelet access)
  - Option B (sidecar): `unix:uid:<pod-uid>` (matching the UID assigned by OpenShift's restricted SCC, since the `k8s` attestor is not available)
- **Downstream flag:** `true` (grants CA signing authority)

This entry can be registered via:
- ClusterSPIFFEID / ClusterStaticEntry CRD (if using SPIRE controller manager — recommended for Option A)
- Manual `spire-server entry create` command
- Operator automation (future scope)

### 3.3 Parsing and Config Generation

- **Parsing:** Controller reads `server.Spec.UpstreamAuthority` (typed structs). No HCL/JSON parsing of user-provided strings; all structured.
- **Secrets:** Resolve Secret references in the operator namespace (or a designated namespace). The operator **never reads secret values into the ConfigMap or CR status**. Instead:
  - For Vault `token_auth` and `approle_auth`: inject as env vars (`VAULT_TOKEN`, `VAULT_APPROLE_ID`, `VAULT_APPROLE_SECRET_ID`) via `valueFrom.secretKeyRef`. The ConfigMap uses the upstream "empty struct" pattern (e.g., `token_auth {}`).
  - For Vault `cert_auth`: mount cert/key as files at fixed paths; set those paths in plugin_data.
  - For Vault `k8s_auth`: use projected ServiceAccount token volume.
  - For cert-manager: no secrets needed (in-cluster Kubernetes client).
  - If a referenced Secret is missing, set condition `ConfigurationValid=False` and do not generate config until Secret exists.
- **Rollout:** ConfigMap and optional volumes are part of desired StatefulSet. Hash change triggers rolling update. Single-replica StatefulSet: one pod replaced; ensure SPIRE server can restart and reconnect to upstream (cert-manager/vault/spire) without requiring manual intervention. No special “downtime” handling beyond normal rolling update.

### 3.3 Rollout Without Downtime

- Same as current: update ConfigMap and StatefulSet template; kubelet restarts the pod. For single-replica server there will be a short unavailability during restart. No in-place config reload for SPIRE server in this design. Document that changing UpstreamAuthority or its secrets causes a restart.

---

## 4. Test Cases

### 4.1 Unit Tests

**Config generation (generateServerConfMap / plugin_data):**

| ID    | Description | Input | Expected |
|-------|-------------|--------|----------|
| U-CM-1 | cert-manager plugin_data when all fields set | UpstreamAuthority.certManager with namespace, issuerName, issuerKind Issuer, issuerGroup cert-manager.io | plugins.UpstreamAuthority has name "cert-manager", plugin_data has namespace, issuer_name, issuer_kind, issuer_group |
| U-CM-2 | cert-manager defaults | Only namespace and issuerName set | issuer_kind=Issuer, issuer_group=cert-manager.io |
| U-V-1  | vault token_auth plugin_data (env var) | Vault with tokenAuth and TokenSecretRef | plugin_data has `token_auth: {}` (empty struct); `VAULT_TOKEN` env var set from Secret; no inline token or token_path in config |
| U-V-1b | vault token_auth env injection | Vault with tokenAuth | StatefulSet has `VAULT_ADDR` and `VAULT_TOKEN` env vars with `valueFrom.secretKeyRef` |
| U-V-2  | vault k8s_auth plugin_data | Vault with k8sAuth (roleName, tokenPath) | plugin_data has k8s_auth_mount_point (or default), k8s_auth_role_name, token_path; projected SA token volume added |
| U-V-2b | vault approle_auth plugin_data (env var) | Vault with appRoleAuth and AppRoleSecretRef | plugin_data has `approle_auth: {}` (empty struct); `VAULT_APPROLE_ID` and `VAULT_APPROLE_SECRET_ID` env vars set from Secret |
| U-V-3  | vault with caCertSecretRef | CACertSecretRef set | plugin_data has ca_cert_path set to fixed mount path |
| U-S-1  | spire plugin_data | Spire with serverAddress, serverPort, workloadAPISocket | plugin_data has server_address, server_port, workload_api_socket |
| U-S-2  | spire plugin_data with Route port | Spire with serverPort "443" (Route) | plugin_data has server_port "443" |
| U-S-3  | upstream-agent config generation | Spire with upstreamClusterName, serverAddress | Generated agent ConfigMap has correct cluster name, server_address, unix WorkloadAttestor |
| U-N-1  | no UpstreamAuthority | spec.upstreamAuthority nil | plugins has no UpstreamAuthority key |
| U-N-2  | empty plugins when no upstream | — | KeyManager, DataStore, NodeAttestor, Notifier present; UpstreamAuthority absent |

**Validation (validateUpstreamAuthorityConfig):**

| ID    | Description | Input | Expected |
|-------|-------------|--------|----------|
| U-VL-1 | exactly one plugin | certManager and vault both set | error |
| U-VL-2 | none set | UpstreamAuthority non-nil but all three nil | error |
| U-VL-3 | cert-manager missing namespace | certManager with empty namespace | error |
| U-VL-4 | cert-manager missing issuerName | certManager with empty issuerName | error |
| U-VL-5 | vault missing vaultAddr | vault with empty vaultAddr | error |
| U-VL-6 | vault multiple auth | tokenAuth and k8sAuth both set | error |
| U-VL-7 | vault no auth | vault with no auth method | error |
| U-VL-8 | spire missing serverAddress | spire with empty serverAddress | error |
| U-VL-9 | spire missing workloadAPISocket | spire with empty workloadAPISocket | error |
| U-VL-10 | valid cert-manager | full certManager | nil error |
| U-VL-11 | valid vault tokenAuth | vault + tokenAuth + TokenSecretRef | nil error |
| U-VL-12 | valid spire | full spire | nil error |

**RBAC (cert-manager Role/RoleBinding):**

| ID    | Description | Expected |
|-------|-------------|----------|
| U-RB-1 | Role has certificaterequests get/list/create/delete in cert-manager.io | Rule present |
| U-RB-2 | Role namespace equals spec.upstreamAuthority.certManager.namespace | Match |
| U-RB-3 | RoleBinding subject is spire-server SA in operator namespace | Match |

**StatefulSet volumes/mounts:**

| ID    | Description | Expected |
|-------|-------------|----------|
| U-ST-1 | Vault token auth: Secret volume and mount for token | Volume from TokenSecretRef; mount to fixed path |
| U-ST-2 | Vault caCertSecretRef: Secret volume and mount | Volume and mount for CA cert |
| U-ST-3 | Spire: sidecar container injected | upstream-agent container present in StatefulSet when spire plugin configured |
| U-ST-4 | Spire: shared emptyDir for socket | `upstream-agent-socket` emptyDir volume mounted in both spire-server and upstream-agent containers |
| U-ST-5 | Spire: upstream bundle ConfigMap volume | `upstream-bundle` ConfigMap volume mounted in upstream-agent container |
| U-ST-6 | Spire: projected SA token volume | `upstream-agent-token` projected volume with audience `spire-server` |
| U-ST-7 | No extra volumes when UpstreamAuthority nil | No vault/spire/cert-manager specific volumes; no sidecar container |

### 4.2 Integration Tests

| ID     | Description | Steps | Expected |
|--------|-------------|--------|----------|
| I-1    | Create SpireServer with cert-manager UpstreamAuthority | Create CR with certManager; ensure cert-manager and Issuer exist | ConfigMap has UpstreamAuthority "cert-manager"; Role/RoleBinding in namespace; server pod runs |
| I-2    | Create SpireServer with vault token auth (env var) | Create CR with vault + tokenAuth + Secret; Vault available | ConfigMap has `token_auth: {}` (empty struct, no secrets); `VAULT_TOKEN` + `VAULT_ADDR` env vars injected from Secret; pod runs and connects to Vault |
| I-3    | Create SpireServer with spire UpstreamAuthority | Create CR with spire + workloadAPISocket + upstreamBundleConfigMapRef | ConfigMap has spire plugin_data; upstream-agent sidecar injected; shared emptyDir for socket; upstream-agent-config ConfigMap generated; server starts |
| I-3a   | Spire exportRoute creates passthrough Route | Create SpireServer with spire.exportRoute=true | ClusterIP Service `spire-server-external` and passthrough Route `spire-server` created |
| I-3b   | Spire exportRoute=false removes Route | Set exportRoute=false after it was true | Route and external Service are deleted |
| I-4    | Switch from no upstream to cert-manager | Update CR from no upstreamAuthority to certManager | ConfigMap and Role created; StatefulSet updated; pod restarts |
| I-5    | Remove UpstreamAuthority | Remove spec.upstreamAuthority from CR | ConfigMap no longer has UpstreamAuthority; cert-manager Role/RoleBinding removed if present; pod restarts |
| I-6    | Missing Secret for vault token | CR with tokenAuth but Secret missing | Condition indicates config/secret invalid; no token in ConfigMap; optional: no new pod or pod fails with clear reason |
| I-7    | Invalid cert-manager namespace | CR with certManager.namespace = non-existent namespace | Validation or status reflects error; optional: Role not created or created in that namespace per design |

### 4.3 E2E Tests

| ID   | Description | Steps | Expected |
|------|-------------|--------|----------|
| E-1  | cert-manager issues CA | Install cert-manager; create Issuer; create SpireServer with certManager; wait for ready | SPIRE server running; server obtains CA from cert-manager; agents can attest |
| E-2  | Vault issues CA (token) | Deploy Vault; create token and PKI; create Secret with token; create SpireServer with vault tokenAuth | SPIRE server running; CA from Vault; workload SVIDs valid |
| E-3  | Nested SPIRE via Route (cross-cluster) | Deploy upstream SPIRE with exportRoute=true on cluster A; deploy downstream SpireServer with spire UA pointing to Route hostname (port 443) on cluster B | Upstream Route created; upstream-agent sidecar attests via Route; downstream CA signed by upstream; bundle contains upstream Root CA only |
| E-3a | Nested SPIRE (same-cluster) | Deploy upstream SPIRE in separate namespace; deploy downstream with spire UA pointing to ClusterIP Service (port 8081) | Sidecar attests; downstream CA signed by upstream |
| E-4  | Change vault token (secret update) | Update Secret with new token; trigger rollout or wait for next reconcile | Server picks new token (after restart if file-based); no permanent failure |
| E-5  | Invalid vault addr | SpireServer with vault pointing to unreachable URL | Server pod may fail; status/conditions indicate problem |
| E-6  | cert-manager Issuer not ready | SpireServer with certManager referencing Issuer that does not exist or not ready | CertificateRequest may stay pending; status/events indicate issuer/config issue |

### 4.4 Edge Cases and Failure Scenarios

| ID   | Scenario | Expected behavior |
|------|----------|--------------------|
| EC-1 | Both certManager and vault set in spec | Validation error; ConfigurationValid False |
| EC-2 | vault.tokenAuth with empty TokenSecretRef.name | Validation error |
| EC-3 | CACertSecretRef points to non-existent Secret | Condition set; config generation fails or Secret not found handled |
| EC-4 | cert-manager namespace = "" | Validation error |
| EC-5 | spire.serverPort non-numeric | Validation error (pattern or enum) |
| EC-6 | Create-only mode: change UpstreamAuthority | ConfigMap/StatefulSet update skipped; condition or log indicates create-only |
| EC-7 | Immutability: change UpstreamAuthority type (certManager → vault) | If design makes upstreamAuthority immutable: admission or validation rejects |
| EC-8 | Vault unreachable at runtime | Server log/health may fail; no operator crash; status can reflect degraded |
| EC-9 | cert-manager CR creation fails (e.g. RBAC) | Server may fail to mint CA; operator does not crash; RBAC/events show cause |
| EC-10 | Spire upstream socket path not mounted | Server fails to start or plugin fails; events/status indicate mount or config issue |
| EC-11 | Spire upstream-agent can't reach Route | Agent retries with backoff; server starts but UpstreamAuthority logs connection errors; health may degrade |
| EC-12 | Spire upstream-agent SA not in allowed list | Agent attestation fails; logs show "not an allowed service account"; operator should document required upstream config |
| EC-13 | Spire exportRoute on non-OpenShift cluster | Route API not available; operator should fail gracefully with condition/event |
| EC-14 | Spire upstreamBundleConfigMapRef missing | upstream-agent sidecar can't start (volume mount fails); pod events indicate missing ConfigMap |
| EC-15 | Spire downstream trust domain differs from upstream | Validation error at admission (if trust domain is known); at runtime, upstream rejects CA signing — downstream logs "trust domain mismatch"; ConfigurationValid set to False. Nested SPIRE requires the same trust domain (see section 1.2) |
| EC-16 | Spire plugin configured but user intends federation (different trust domains) | Documentation and validation errors should guide user toward the Federation config instead of UpstreamAuthority |

---

## 5. Summary

- **Feasibility:** Integration of cert-manager, vault, and spire UpstreamAuthority plugins is feasible with the described RBAC (cert-manager only), secret handling (vault), and upstream agent + Route (spire) strategies. All three plugins are built-in to the ZTWIM SPIRE server image and verified working via E2E testing.
- **Nested SPIRE vs Federation:** Nested SPIRE (UpstreamAuthority `spire` plugin) operates within a **single trust domain** — the upstream signs intermediate CAs for the downstream. This is distinct from Federation, which connects **different trust domains** via bundle exchange. The operator must validate trust domain consistency and clearly surface this distinction to users (see section 1.2).
- **API:** Add optional `UpstreamAuthority` to `SpireServerSpec` with one-of `certManager` / `vault` / `spire`; vault uses Secret references only. The `spire` plugin adds `exportRoute`, `upstreamBundleConfigMapRef`, and `upstreamClusterName` fields.
- **Reconciliation:** Validate one-of and required fields; add cert-manager Role/RoleBinding when needed; generate UpstreamAuthority block and plugin_data in server ConfigMap; add volumes/mounts for vault secrets; provision upstream agent and Route for spire; config hash drives rollout; no in-place reload.
- **Route-based connectivity:** The operator creates a passthrough Route (`tls.termination: passthrough`) to expose the upstream SPIRE server's gRPC API on port 443. This is cloud-agnostic, requires no special annotations, and the hostname is available immediately. The downstream agent connects via port 443.
- **Upstream agent co-location (two options):**
  - **Option A (recommended):** DaemonSet + CSI driver — matches the [official SPIRE Helm chart](https://github.com/spiffe/helm-charts-hardened/tree/main/charts/spire-nested). A separate `upstream-spire-agent` DaemonSet and `upstream-spiffe-csi-driver` DaemonSet provide the Workload API socket to the downstream server via CSI volume. Uses standard `k8s_psat` + `k8s` attestors. ZTWIM already manages DaemonSet operands (SpireAgent, SpiffeCSIDriver), so this fits existing patterns.
  - **Option B (tested alternative):** Sidecar container in the downstream StatefulSet, sharing an `emptyDir` volume. Simpler (no extra DaemonSets), but requires `unix` WorkloadAttestor and is not the upstream-documented pattern.
- **Tests:** Unit (config generation, validation, RBAC, volumes, agent provisioning), integration (create/update/remove, missing secret, Route lifecycle), E2E (full CA issuance for each plugin including cross-cluster nested SPIRE via Route), and edge/failure cases as above.

This design aligns with existing ZTWIM API and reconciliation patterns and stays within the scope of the three plugins only.

---

## 6. Upstream Documentation References

This section collects the official upstream SPIFFE/SPIRE documentation that supports the architectural decisions in this design, particularly for the nested SPIRE (`spire` UpstreamAuthority) plugin.

### 6.1 Core Architecture — Co-located Agent and Same Trust Domain

**Source:** [Deploying a Nested SPIRE Architecture](https://spiffe.io/docs/latest/architecture/nested/readme/)

Key excerpts:

> *"Nested SPIRE allows SPIRE Servers to be 'chained' together, and for all SPIRE Servers to issue identities in the **same trust domain**, meaning all workloads identified in the same trust domain are issued identity documents that can be verified against the root keys of the trust domain."*

> *"Nested topologies work by **co-locating a SPIRE Agent** with every downstream SPIRE Server being 'chained'. The downstream SPIRE Server obtains credentials over the Workload API that it uses to directly authenticate with the upstream SPIRE Server to obtain an intermediate CA."*

This establishes two fundamental requirements:
1. **Same trust domain** — nested SPIRE is not federation; upstream and downstream must share a trust domain (see section 1.2).
2. **Co-located agent** — every downstream SPIRE server needs a co-located agent attested to the upstream, providing a Workload API socket. On Kubernetes, this translates to a **sidecar container** sharing an `emptyDir` volume (see section 3.2.2).

### 6.2 UpstreamAuthority "spire" Plugin

**Source:** [plugin_server_upstreamauthority_spire.md](https://github.com/spiffe/spire/blob/main/doc/plugin_server_upstreamauthority_spire.md)

Key excerpt:

> *"The `spire` plugin uses credentials fetched from the Workload API to call an upstream SPIRE server **in the same trust domain**, requesting an intermediate signing certificate to use as the server's X.509 signing authority."*

Plugin configuration requires three fields — `server_address`, `server_port`, `workload_api_socket` — which map directly to our `UpstreamAuthoritySpire` struct fields in section 2.3.

Sample configuration from upstream:

```hcl
UpstreamAuthority "spire" {
    plugin_data {
        server_address = "upstream-spire-server",
        server_port = "8081",
        workload_api_socket = "/tmp/spire-agent/public/api.sock"
    }
}
```

### 6.3 Docker Compose Tutorial — Shared Socket Pattern

**Source:** [spire-tutorials/docker-compose/nested-spire](https://github.com/spiffe/spire-tutorials/blob/main/docker-compose/nested-spire/docker-compose.yaml)

The upstream tutorial demonstrates the shared socket pattern using Docker Compose volumes:

- The `root-agent` writes its Workload API socket to a shared directory (`sharedRootSocket`).
- The `nestedA-server` mounts that same directory, giving it access to the root agent's socket.
- The nested server's `UpstreamAuthority "spire"` plugin references this socket path.

```yaml
# root-agent exposes socket
root-agent:
  pid: "host"
  volumes:
    - ./sharedRootSocket:/opt/spire/sockets

# nestedA-server consumes socket
nestedA-server:
  pid: "host"
  volumes:
    - ./sharedRootSocket:/opt/spire/sockets
```

**Translation to Kubernetes/OpenShift:** Docker's shared volumes and `pid: "host"` don't apply in Kubernetes. Instead:
- Shared volume → `emptyDir` volume mounted in both the sidecar agent and the SPIRE server container
- `pid: "host"` → Not available under OpenShift restricted SCC; use `unix` WorkloadAttestor (matching by UID) instead of `docker` attestor
- Downstream registration entry: `-downstream` flag + `unix:uid:<pod-uid>` selector (replaces `docker:label:` selector)

### 6.4 SPIRE Helm Charts Hardened — Production Kubernetes Nested SPIRE

**Source:** [spire-nested Helm chart](https://github.com/spiffe/helm-charts-hardened/tree/main/charts/spire-nested) and [Nested SPIRE documentation](https://spiffe.io/docs/latest/spire-helm-charts-hardened-advanced/nested-spire/)

The official SPIRE Helm chart for Kubernetes implements nested SPIRE using the **DaemonSet + CSI driver** approach (Option A in section 3.2.2):

| Helm chart component | Kind | Configuration |
|---|---|---|
| `upstream-spire-agent` | **DaemonSet** | Separate SPIRE agent connecting to root server. Socket at `/run/spire/agent-sockets-upstream/spire-agent.sock`, health port `9981`, telemetry port `9989`, SA: `spire-agent-upstream` |
| `upstream-spiffe-csi-driver` | **DaemonSet** | Separate CSI driver (`upstream.csi.spiffe.io`) exposing the upstream agent socket as a CSI volume |
| `internal-spire-server` | **StatefulSet** | Downstream server. Config: `upstreamAuthority.spire.enabled: true`, `upstreamDriver: upstream.csi.spiffe.io` — mounts the upstream agent socket via CSI |
| `external-spire-server` | **StatefulSet** | Root server exposed via Ingress for cross-cluster child access |
| `root-spire-server` | **StatefulSet** | Root server for same-cluster nested topology |

**Important:** The Helm chart does **not** use a sidecar. The `upstream-spire-agent` is a full DaemonSet running on every node. The CSI driver bridges the socket from the DaemonSet agent to the downstream server pod. This is the standard upstream Kubernetes pattern for nested SPIRE.

From the Helm chart `values.yaml`:

```yaml
upstream-spire-agent:
  upstream: true
  nameOverride: agent-upstream
  bundleConfigMap: spire-bundle-upstream
  socketPath: /run/spire/agent-sockets-upstream/spire-agent.sock
  serviceAccount:
    name: spire-agent-upstream

upstream-spiffe-csi-driver:
  fullnameOverride: spiffe-csi-driver-upstream
  pluginName: upstream.csi.spiffe.io
  agentSocketPath: /run/spire/agent-sockets-upstream/spire-agent.sock

internal-spire-server:
  upstreamAuthority:
    spire:
      enabled: true
      upstreamDriver: upstream.csi.spiffe.io
```

Key observations:
1. The `upstream-spire-agent` is a **separate agent instance** (its own socket path, health port, telemetry port) — confirming that a dedicated agent co-located with the downstream server is the standard approach, not an optional enhancement.
2. Socket sharing is via **CSI driver**, not sidecar `emptyDir` — the `upstream-spiffe-csi-driver` DaemonSet exposes the agent socket as a mountable volume for the downstream server StatefulSet.
3. Cross-cluster requires **Ingress** to expose the root server and **kubeconfigs** for child clusters mounted into the root server (`kubeConfigs.<child>.kubeConfigBase64`).
4. The chart has **dedicated tags** (`nestedRoot`, `nestedChildFull`, `nestedChildSecurity`) showing nested is a first-class deployment model.

Our E2E testing used a sidecar (Option B) as a simplification, but the **recommended production approach is Option A (DaemonSet + CSI)** to align with the upstream Helm chart (see section 3.2.2).

### 6.5 Downstream Registration Entry

**Source:** [Nested SPIRE tutorial — Create Downstream Registration Entry](https://spiffe.io/docs/latest/architecture/nested/readme/)

> ```
> spire-server entry create \
>     -parentID "spiffe://example.org/spire/agent/x509pop/<fingerprint>" \
>     -spiffeID "spiffe://example.org/nestedA" \
>     -selector "docker:label:org.example.name:nestedA-server" \
>     -downstream
> ```
>
> *"The `-downstream` option, when set, indicates that the entry describes a downstream SPIRE Server."*

In our Kubernetes adaptation (section 3.2.4), the selector changes from `docker:label:` to `unix:uid:<pod-uid>` (matching the OpenShift-assigned UID), and the parent ID is the upstream agent's SPIFFE ID (from `k8s_psat` attestation rather than `x509pop`).

### 6.6 Summary of Upstream Validation

| Design decision | Upstream source | Notes |
|---|---|---|
| Same trust domain required | Plugin docs + nested tutorial | Core requirement |
| Co-located agent with downstream server | Nested tutorial + Helm chart (`upstream-spire-agent` DaemonSet) | Core requirement |
| Shared Workload API socket | Nested tutorial (Docker volume) + Helm chart (CSI driver: `upstream.csi.spiffe.io`) | Helm chart uses DaemonSet + CSI; our E2E test used sidecar + emptyDir |
| `-downstream` entry registration | Nested tutorial | Core requirement |
| Cross-cluster endpoint exposure | Helm chart (`external-spire-server.ingress`) | Helm uses Ingress; our design uses passthrough Route (OpenShift equivalent) |
| Kubeconfig for cross-cluster PSAT | Helm chart (`kubeConfigs.<child>.kubeConfigBase64`) | Core requirement for cross-cluster |

**Where our design deviates from upstream Helm chart:**

| Our deviation | Upstream approach | Reason |
|---|---|---|
| Passthrough Route (vs Ingress) | `external-spire-server.ingress` | Route is the native OpenShift equivalent of Ingress |
| E2E tested sidecar + emptyDir (Option B) | DaemonSet + CSI driver (Option A) | Simplification for testing; **Option A is recommended for production** (see section 3.2.2) |
| `unix` attestor (sidecar only) | `k8s` attestor (DaemonSet has kubelet access) | Only needed if using sidecar approach (Option B); not needed with DaemonSet (Option A) |

The recommended production approach (Option A: DaemonSet + CSI) aligns directly with the upstream Helm chart. The sidecar approach (Option B) was validated during E2E testing as a viable alternative.
