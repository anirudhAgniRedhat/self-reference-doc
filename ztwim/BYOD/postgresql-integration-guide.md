# PostgreSQL Integration Guide for SPIRE Server on OpenShift

## Table of Contents
1. [Overview](#overview)
2. [Prerequisites](#prerequisites)
3. [Deploying PostgreSQL](#deploying-postgresql)
4. [Configuring SPIRE Server](#configuring-spire-server)
5. [Troubleshooting](#troubleshooting)
6. [Database Exploration](#database-exploration)
7. [Production Considerations](#production-considerations)

---

## Overview

This guide walks through the complete process of deploying PostgreSQL on OpenShift and configuring SPIRE Server to use it as a datastore instead of the default SQLite. PostgreSQL provides better performance, scalability, and reliability for production environments.

### Why PostgreSQL over SQLite?

| Feature | SQLite | PostgreSQL |
|---------|--------|------------|
| **Concurrent Access** | Limited | Excellent |
| **Scalability** | Small-scale | Enterprise-scale |
| **Performance** | Good for single server | Better for high load |
| **Backup/Restore** | File-based | Advanced tools available |
| **High Availability** | Not supported | Replication supported |

### Architecture

```
┌─────────────────────────────────────────────────────────────┐
│ OpenShift Cluster                                            │
│                                                              │
│  ┌────────────────────────┐    ┌──────────────────────┐    │
│  │ SPIRE Server           │    │ PostgreSQL           │    │
│  │ Namespace: zero-trust- │───▶│ Namespace: postgresql│    │
│  │ workload-identity-mgr  │    │ Service: postgresql  │    │
│  │                        │    │ Port: 5432           │    │
│  │ Connection String:     │    │ Storage: 10Gi PVC    │    │
│  │ postgresql://admin:... │    │                      │    │
│  └────────────────────────┘    └──────────────────────┘    │
│           │                                                  │
│           ▼                                                  │
│  ┌─────────────────────┐                                    │
│  │ SPIRE Agents        │                                    │
│  │ (DaemonSet)         │                                    │
│  └─────────────────────┘                                    │
└─────────────────────────────────────────────────────────────┘
```

---

## Prerequisites

### Required Tools
- `oc` (OpenShift CLI) installed and configured
- Access to an OpenShift cluster with cluster-admin privileges
- SPIRE Operator already deployed

### Environment Setup

```bash
export KUBECONFIG=/home/aagnihot/workspace/test/installer/4.20-installer/aws/auth/kubeconfig
oc whoami
```

**Expected Output:**
```
system:admin
```

---

## Deploying PostgreSQL

### Step 1: Create PostgreSQL Namespace

Create a dedicated namespace for PostgreSQL to isolate it from other workloads.

```bash
oc create namespace postgresql
```

**Output:**
```
namespace/postgresql created
```

### Step 2: Check Available PostgreSQL Templates

OpenShift provides pre-configured templates for PostgreSQL deployment.

```bash
oc get templates -n openshift | grep postgresql
```

**Output:**
```
postgresql-ephemeral        PostgreSQL database service, without persistent storage...
postgresql-persistent       PostgreSQL database service, with persistent storage...
```

### Step 3: Deploy PostgreSQL

Deploy PostgreSQL using the persistent storage template with custom credentials.

```bash
oc new-app postgresql-persistent -n postgresql \
  -p POSTGRESQL_USER=admin \
  -p POSTGRESQL_PASSWORD=redhat123 \
  -p POSTGRESQL_DATABASE=sampledb \
  -p VOLUME_CAPACITY=10Gi
```

**Output:**
```
--> Deploying template "postgresql/postgresql-persistent" to project postgresql

     PostgreSQL
     ---------
     PostgreSQL database service, with persistent storage.

     The following service(s) have been created in your project: postgresql.
     
            Username: admin
            Password: redhat123
       Database Name: sampledb
      Connection URL: postgresql://postgresql:5432/
     
     * With parameters:
        * Memory Limit=512Mi
        * Namespace=openshift
        * Database Service Name=postgresql
        * PostgreSQL Connection Username=admin
        * PostgreSQL Connection Password=redhat123
        * PostgreSQL Database Name=sampledb
        * Volume Capacity=10Gi
        * Version of PostgreSQL Image=10-el8

--> Creating resources ...
    secret "postgresql" created
    service "postgresql" created
    persistentvolumeclaim "postgresql" created
    deploymentconfig.apps.openshift.io "postgresql" created
--> Success
```

### Step 4: Verify PostgreSQL Deployment

Wait for PostgreSQL to be fully deployed and running.

```bash
oc get all -n postgresql
```

**Output:**
```
NAME                      READY   STATUS    RESTARTS   AGE
pod/postgresql-1-wkzgm    1/1     Running   0          54s

NAME                                 DESIRED   CURRENT   READY   AGE
replicationcontroller/postgresql-1   1         1         1       57s

NAME                 TYPE        CLUSTER-IP       EXTERNAL-IP   PORT(S)    AGE
service/postgresql   ClusterIP   172.30.239.227   <none>        5432/TCP   59s
```

### Step 5: Verify Persistent Storage

Confirm that persistent storage has been provisioned.

```bash
oc get pvc -n postgresql
```

**Output:**
```
NAME         STATUS   VOLUME                                     CAPACITY   ACCESS MODES   STORAGECLASS
postgresql   Bound    pvc-6b5e0bb9-9a00-44d1-a96e-04f27757c306   10Gi       RWO            gp3-csi
```

### PostgreSQL Connection Details

| Parameter | Value |
|-----------|-------|
| **Service Name (within postgresql namespace)** | `postgresql` |
| **Service Name (FQDN)** | `postgresql.postgresql.svc.cluster.local` |
| **Port** | `5432` |
| **Username** | `admin` |
| **Password** | `redhat123` |
| **Database** | `sampledb` |
| **Cluster IP** | `172.30.239.227` |

---

## Configuring SPIRE Server

### SPIRE SQL DataStore Plugin

SPIRE Server uses the SQL plugin to connect to PostgreSQL. The plugin supports multiple connection string formats based on the [SPIRE SQL DataStore Plugin documentation](https://github.com/spiffe/spire/blob/main/doc/plugin_server_datastore_sql.md).

### Connection String Formats

SPIRE supports two PostgreSQL connection string formats:

#### 1. URI Format (Recommended)
```
postgresql://username:password@host:port/database?sslmode=disable
```

#### 2. Key-Value Format
```
host=hostname port=5432 user=username password=password dbname=database sslmode=disable
```

### Step 1: Check Current SPIRE Server Configuration

First, examine the existing SPIRE Server configuration.

```bash
oc get spireserver cluster -o yaml | head -50
```

**Output:**
```yaml
apiVersion: operator.openshift.io/v1alpha1
kind: SpireServer
metadata:
  name: cluster
spec:
  datastore:
    databaseType: sqlite3
    connectionString: /run/spire/data/datastore.sqlite3
    maxOpenConns: 100
    maxIdleConns: 2
    connMaxLifetime: 3600
  trustDomain: apps.aagnihot-cluster-dfdsa.devcluster.openshift.com
  clusterName: test01
  # ... other configuration
```

### Step 2: Patch SPIRE Server to Use PostgreSQL

Update the SpireServer custom resource to use PostgreSQL.

```bash
oc patch spireserver cluster --type='merge' -p '{
  "spec": {
    "datastore": {
      "databaseType": "postgres",
      "connectionString": "postgresql://admin:redhat123@postgresql.postgresql.svc.cluster.local:5432/sampledb?sslmode=disable",
      "maxOpenConns": 100,
      "maxIdleConns": 2,
      "connMaxLifetime": 3600,
      "disableMigration": "false"
    }
  }
}'
```

**Output:**
```
spireserver.operator.openshift.io/cluster patched
```

### Step 3: Verify Configuration Update

Confirm the datastore configuration has been updated.

```bash
oc get spireserver cluster -o jsonpath='{.spec.datastore}' | jq
```

**Output:**
```json
{
  "connMaxLifetime": 3600,
  "connectionString": "postgresql://admin:redhat123@postgresql.postgresql.svc.cluster.local:5432/sampledb?sslmode=disable",
  "databaseType": "postgres",
  "disableMigration": "false",
  "maxIdleConns": 2,
  "maxOpenConns": 100,
  "options": [],
  "rootCAPath": ""
}
```

### Configuration Parameters Explained

Based on the code implementation in `pkg/controller/spire-server/configmap.go`:

```go
dataStorePluginData := config.DataStorePluginData{
    DatabaseType:     spec.Datastore.DatabaseType,      // "postgres"
    ConnectionString: spec.Datastore.ConnectionString,  // Full connection URL
    MaxOpenConns:     spec.Datastore.MaxOpenConns,      // 100
    MaxIdleConns:     spec.Datastore.MaxIdleConns,      // 2
    DisableMigration: utils.StringToBool(spec.Datastore.DisableMigration), // false
}

// Add conn_max_lifetime with seconds unit if provided
if spec.Datastore.ConnMaxLifetime > 0 {
    dataStorePluginData.ConnMaxLifetime = fmt.Sprintf("%ds", spec.Datastore.ConnMaxLifetime)
}
```

| Parameter | Type | Description | Example Value |
|-----------|------|-------------|---------------|
| `databaseType` | string | Database type (postgres, mysql, sqlite3) | `postgres` |
| `connectionString` | string | Full database connection URL | `postgresql://admin:redhat123@...` |
| `maxOpenConns` | int | Maximum open database connections | `100` |
| `maxIdleConns` | int | Maximum idle connections in pool | `2` |
| `connMaxLifetime` | int | Connection lifetime in seconds (converted to "3600s") | `3600` |
| `disableMigration` | string | Disable automatic schema migration | `"false"` |
| `options` | []string | Additional database driver options | `["sslmode=disable"]` |
| `rootCAPath` | string | Path to CA certificate for TLS | (empty for no SSL) |
| `clientCertPath` | string | Path to client certificate for mTLS | (optional) |
| `clientKeyPath` | string | Path to client private key for mTLS | (optional) |

---

## Troubleshooting

### Issue 1: SSL Connection Error ❌

#### Problem
After patching the SpireServer, the server pod enters CrashLoopBackOff state.

```bash
oc logs spire-server-0 -c spire-server
```

**Error Output:**
```
time="2025-10-30T12:25:51.356776181Z" level=info msg="Opening SQL database" db_type=postgres subsystem_name=sql
time="2025-10-30T12:25:51.364554196Z" level=error msg="Fatal run error" error="datastore-sql: pq: SSL is not enabled on the server"
time="2025-10-30T12:25:51.36457724Z" level=error msg="Server crashed" error="datastore-sql: pq: SSL is not enabled on the server"
```

#### Root Cause
PostgreSQL drivers default to requiring SSL connections, but the PostgreSQL instance deployed doesn't have SSL enabled.

#### Solution
Add `?sslmode=disable` to the connection string.

```bash
oc patch spireserver cluster --type='merge' -p '{
  "spec": {
    "datastore": {
      "connectionString": "postgresql://admin:redhat123@postgresql.postgresql.svc.cluster.local:5432/sampledb?sslmode=disable"
    }
  }
}'
```

#### Verification
The operator should automatically update the ConfigMap, but you may need to force a reconciliation:

```bash
# Delete the configmap to force operator reconciliation
oc delete configmap -n zero-trust-workload-identity-manager spire-server

# Wait and verify the configmap is recreated with updated connection string
oc get configmap -n zero-trust-workload-identity-manager spire-server -o jsonpath='{.data.server\.conf}' | jq '.plugins.DataStore[0].sql.plugin_data'
```

**Expected Output:**
```json
{
  "database_type": "postgres",
  "connection_string": "postgresql://admin:redhat123@postgresql.postgresql.svc.cluster.local:5432/sampledb?sslmode=disable",
  "max_open_conns": 100,
  "max_idle_conns": 2,
  "conn_max_lifetime": "3600s"
}
```

#### Restart SPIRE Server

```bash
oc delete pod -n zero-trust-workload-identity-manager spire-server-0
```

Wait for the pod to restart and verify:

```bash
oc get pods -n zero-trust-workload-identity-manager spire-server-0
```

**Expected Output:**
```
NAME             READY   STATUS    RESTARTS      AGE
spire-server-0   2/2     Running   1 (10s ago)   21s
```

#### Success Logs

```bash
oc logs -n zero-trust-workload-identity-manager spire-server-0 -c spire-server --tail=30
```

**Expected Output:**
```
time="2025-10-30T12:28:20.156710547Z" level=info msg="Opening SQL database" db_type=postgres subsystem_name=sql
time="2025-10-30T12:28:20.167869509Z" level=info msg="Initializing new database" subsystem_name=sql
time="2025-10-30T12:28:20.292403855Z" level=info msg="Connected to SQL database" read_only=false subsystem_name=sql type=postgres version=10.23
time="2025-10-30T12:28:20.315128792Z" level=info msg="X509 CA prepared" expiration="2025-10-31 12:28:20 +0000 UTC"
time="2025-10-30T12:28:20.315430873Z" level=info msg="X509 CA activated"
time="2025-10-30T12:28:20.335101291Z" level=info msg="Starting Server APIs" address="[::]:8081"
```

✅ **Success Indicators:**
- `Connected to SQL database`
- `X509 CA prepared` and `X509 CA activated`
- `Starting Server APIs`

---

### Issue 2: SPIRE Agents Failing ❌

#### Problem
After SPIRE Server successfully connects to PostgreSQL, the agents start failing.

```bash
oc get pods -n zero-trust-workload-identity-manager | grep spire-agent
```

**Output:**
```
spire-agent-hc8hs   0/1   Running   4 (53s ago)   10m
spire-agent-qj26n   0/1   Running   4 (54s ago)   10m
spire-agent-xp9cj   0/1   Running   4 (54s ago)   10m
```

#### Check Agent Logs

```bash
oc logs -n zero-trust-workload-identity-manager spire-agent-hc8hs --tail=20
```

**Error Output:**
```
time="2025-10-30T12:32:03.371613869Z" level=warning msg="Failed to retrieve attestation result" 
error="could not open attestation stream to SPIRE server: rpc error: code = Unavailable 
desc = connection error: desc = \"transport: authentication handshake failed: 
x509svid: could not verify leaf certificate: x509: certificate signed by unknown authority\"" 
retry_interval=4.8981368s
```

#### Root Cause
When switching from SQLite to PostgreSQL, SPIRE Server created a **new CA certificate** because the PostgreSQL database was empty. The agents still have the **old CA certificate** cached in their persistent storage.

**Timeline of Events:**
1. SPIRE Server was using SQLite with CA certificate "A"
2. Agents were attested and have CA certificate "A" cached
3. Switched to PostgreSQL (empty database)
4. SPIRE Server generated new CA certificate "B"
5. Agents try to connect but still trust only CA certificate "A"
6. Certificate verification fails: "certificate signed by unknown authority"

#### Solution
Restart all SPIRE agent pods to force them to:
1. Clear cached SVID and keys
2. Reload the trust bundle from the ConfigMap
3. Perform fresh node attestation with the new CA

```bash
oc delete pods -n zero-trust-workload-identity-manager -l app.kubernetes.io/name=spire-agent
```

**Output:**
```
pod "spire-agent-hc8hs" deleted
pod "spire-agent-qj26n" deleted
pod "spire-agent-xp9cj" deleted
```

#### Verify Agents Restart Successfully

```bash
oc get pods -n zero-trust-workload-identity-manager -l app.kubernetes.io/name=spire-agent
```

**Expected Output:**
```
NAME                READY   STATUS    RESTARTS   AGE
spire-agent-6dhxl   1/1     Running   0          49s
spire-agent-7n8v9   1/1     Running   0          49s
spire-agent-lvrb9   1/1     Running   0          49s
```

#### Verify Agent Logs

```bash
oc logs -n zero-trust-workload-identity-manager spire-agent-6dhxl --tail=15
```

**Success Output:**
```
time="2025-10-30T12:32:56.833203532Z" level=info msg="Bundle loaded" 
subsystem_name=attestor trust_domain_id="spiffe://apps.aagnihot-cluster-dfdsa.devcluster.openshift.com"
time="2025-10-30T12:32:56.83358938Z" level=info msg="SVID is not found. Starting node attestation" 
subsystem_name=attestor trust_domain_id="spiffe://apps.aagnihot-cluster-dfdsa.devcluster.openshift.com"
time="2025-10-30T12:32:56.871110577Z" level=info msg="Node attestation was successful" 
reattestable=true spiffe_id="spiffe://apps.aagnihot-cluster-dfdsa.devcluster.openshift.com/spire/agent/k8s_psat/test01/72e5526a-51ba-413c-a9e5-5d45c01d6589" 
subsystem_name=attestor
time="2025-10-30T12:32:56.89814381Z" level=info msg="Starting Workload and SDS APIs" 
address=/tmp/spire-agent/public/spire-agent.sock
```

✅ **Success Indicators:**
- `Bundle loaded`
- `Node attestation was successful`
- `Starting Workload and SDS APIs`

---

## Database Exploration

### Verify SPIRE Database Schema

Once SPIRE Server successfully connects, it automatically creates the database schema.

```bash
PGPOD=$(oc get pods -n postgresql -l name=postgresql -o name)
oc exec -n postgresql $PGPOD -- psql -U admin -d sampledb -c "\dt"
```

**Output:**
```
                    List of relations
 Schema |              Name              | Type  | Owner 
--------+--------------------------------+-------+-------
 public | attested_node_entries          | table | admin
 public | attested_node_entries_events   | table | admin
 public | bundles                        | table | admin
 public | ca_journals                    | table | admin
 public | dns_names                      | table | admin
 public | federated_registration_entries | table | admin
 public | federated_trust_domains        | table | admin
 public | join_tokens                    | table | admin
 public | migrations                     | table | admin
 public | node_resolver_map_entries      | table | admin
 public | registered_entries             | table | admin
 public | registered_entries_events      | table | admin
 public | selectors                      | table | admin
(13 rows)
```

### SPIRE Database Tables Explained

| Table Name | Purpose | Example Data |
|------------|---------|--------------|
| `attested_node_entries` | Stores registered SPIRE agents | Agent SPIFFE IDs, expiration times |
| `attested_node_entries_events` | Audit log of agent attestation events | Attestation timestamps, changes |
| `bundles` | Trust domain bundle (root certificates) | X.509 and JWT signing keys |
| `ca_journals` | Tracks active CA certificates | Current X.509 and JWT CA IDs |
| `dns_names` | DNS SANs for workload SVIDs | DNS names for workload identities |
| `federated_registration_entries` | Cross-domain workload registrations | Federated trust relationships |
| `federated_trust_domains` | Federated trust domain configurations | External trust domains |
| `join_tokens` | One-time tokens for manual agent registration | Token strings, expiration |
| `migrations` | Database schema version tracking | Migration version numbers |
| `node_resolver_map_entries` | Node metadata (labels, annotations) | Kubernetes node information |
| `registered_entries` | Workload identity registrations | Workload SPIFFE IDs |
| `registered_entries_events` | Audit log of workload registration events | Registration changes |
| `selectors` | Workload selection criteria | Pod UID, namespace, SA selectors |

### View Registered SPIRE Agents

```bash
oc exec -n postgresql $PGPOD -- psql -U admin -d sampledb -c "
SELECT id, spiffe_id, data_type, expires_at, can_reattest 
FROM attested_node_entries;"
```

**Output:**
```
 id | spiffe_id                                                           | data_type | expires_at          | can_reattest
----+---------------------------------------------------------------------+-----------+---------------------+-------------
  1 | spiffe://.../spire/agent/k8s_psat/test01/62a3c24a-02f2-45bd-9c7e... | k8s_psat  | 2025-10-30 13:32:56 | t
  2 | spiffe://.../spire/agent/k8s_psat/test01/72e5526a-51ba-413c-a9e5... | k8s_psat  | 2025-10-30 13:32:56 | t
  3 | spiffe://.../spire/agent/k8s_psat/test01/323e3f37-84b2-4300-8c9a... | k8s_psat  | 2025-10-30 13:32:57 | t
(3 rows)
```

**Interpretation:**
- **3 SPIRE agents** are registered (one per Kubernetes node)
- **data_type: k8s_psat** - Kubernetes Projected Service Account Token attestation
- **can_reattest: t** - Agents can re-attest when needed
- **expires_at** - SVID expiration time (agents will automatically renew)

### View Registered Workloads

```bash
oc exec -n postgresql $PGPOD -- psql -U admin -d sampledb -c "
SELECT entry_id, spiffe_id, parent_id, ttl 
FROM registered_entries;"
```

**Output:**
```
                  entry_id                   |                      spiffe_id                          |                parent_id                    | ttl
---------------------------------------------+---------------------------------------------------------+---------------------------------------------+-----
 test01.4dea34be-4cf3-4bc9-8cde-537d98334ef5 | spiffe://.../ns/zero-trust.../sa/spire-spiffe-oidc-...  | spiffe://.../agent/k8s_psat/test01/62a3c... |   0
 test01.e352821a-52cb-4166-a716-312491dc7cfe | spiffe://.../ns/postgresql/sa/deployer                  | spiffe://.../agent/k8s_psat/test01/62a3c... |   0
 test01.0a543a34-af2c-4c67-a2ea-b12c72fb44a9 | spiffe://.../ns/postgresql/sa/default                   | spiffe://.../agent/k8s_psat/test01/323e3... |   0
(3 rows)
```

**Interpretation:**
- **3 workload identities** registered:
  1. SPIRE OIDC Discovery Provider service account
  2. PostgreSQL deployer service account  
  3. PostgreSQL default service account
- **parent_id** - Links to the SPIRE agent managing this workload
- **ttl: 0** - Use server default TTL

### View Workload Selectors

Selectors define how workloads are identified and matched.

```bash
oc exec -n postgresql $PGPOD -- psql -U admin -d sampledb -c "
SELECT r.spiffe_id, s.type, s.value 
FROM registered_entries r 
JOIN selectors s ON r.id = s.registered_entry_id 
ORDER BY r.id;"
```

**Output:**
```
                      spiffe_id                          | type |                 value                    
---------------------------------------------------------+------+------------------------------------------
 spiffe://.../sa/spire-spiffe-oidc-discovery-provider    | k8s  | pod-uid:b771e647-97eb-4099-a5a7-742740cc0886
 spiffe://.../ns/postgresql/sa/deployer                  | k8s  | pod-uid:659219d7-07aa-4227-83d3-793b95e53307
 spiffe://.../ns/postgresql/sa/default                   | k8s  | pod-uid:c4260c3c-560b-4c75-9776-a4cd4f0533eb
(3 rows)
```

**Interpretation:**
- Workloads are selected by **pod UID**
- The k8s workload attestor verifies the pod's identity

### View Certificate Authority Information

```bash
oc exec -n postgresql $PGPOD -- psql -U admin -d sampledb -c "
SELECT id, created_at, active_x509_authority_id 
FROM ca_journals;"
```

**Output:**
```
 id |          created_at           |         active_x509_authority_id         
----+-------------------------------+------------------------------------------
  1 | 2025-10-30 12:28:20.315563+00 | c48461ade043bc3c62d51daf5615f0f67b117ecf
(1 row)
```

**Interpretation:**
- **New CA generated** when PostgreSQL database was initialized
- This is the CA that signs all X.509 SVIDs
- Stored as hex-encoded SHA-256 hash

### View Row Counts

```bash
oc exec -n postgresql $PGPOD -- psql -U admin -d sampledb -c "
SELECT relname AS table_name, n_live_tup AS row_count 
FROM pg_stat_user_tables 
ORDER BY n_live_tup DESC;"
```

**Output:**
```
           table_name           | row_count 
--------------------------------+-----------
 node_resolver_map_entries      |        24
 attested_node_entries_events   |         6
 dns_names                      |         5
 registered_entries_events      |         5
 selectors                      |         3
 registered_entries             |         3
 attested_node_entries          |         3
 migrations                     |         1
 ca_journals                    |         1
 bundles                        |         1
 federated_registration_entries |         0
 join_tokens                    |         0
 federated_trust_domains        |         0
(13 rows)
```

### Useful Database Queries

#### Check Database Size
```bash
oc exec -n postgresql $PGPOD -- psql -U admin -d sampledb -c "
SELECT pg_size_pretty(pg_database_size('sampledb')) AS database_size;"
```

#### View Active Connections
```bash
oc exec -n postgresql $PGPOD -- psql -U admin -d sampledb -c "
SELECT 
    pid,
    usename,
    application_name,
    state,
    query_start
FROM pg_stat_activity 
WHERE datname = 'sampledb' AND state = 'active';"
```

#### View Schema Version
```bash
oc exec -n postgresql $PGPOD -- psql -U admin -d sampledb -c "
SELECT * FROM migrations ORDER BY version DESC LIMIT 1;"
```

---

## Production Considerations

### Security Best Practices

#### 1. Enable SSL/TLS

For production deployments, always enable SSL encryption between SPIRE Server and PostgreSQL.

**Deploy PostgreSQL with SSL:**
```bash
# Create SSL certificates (example using OpenSSL)
openssl req -new -x509 -days 365 -nodes -text \
  -out server.crt -keyout server.key \
  -subj "/CN=postgresql.postgresql.svc.cluster.local"

# Create secret with certificates
oc create secret generic postgresql-ssl-certs \
  -n postgresql \
  --from-file=server.crt=server.crt \
  --from-file=server.key=server.key
```

**Update Connection String:**
```bash
oc patch spireserver cluster --type='merge' -p '{
  "spec": {
    "datastore": {
      "connectionString": "postgresql://admin:password@postgresql.postgresql.svc.cluster.local:5432/sampledb?sslmode=require",
      "options": ["sslmode=require"]
    }
  }
}'
```

**SSL Mode Options:**

| SSL Mode | Description | Security Level |
|----------|-------------|----------------|
| `disable` | No SSL (dev only) | ⚠️ Low |
| `allow` | Try SSL, fallback to non-SSL | ⚠️ Low |
| `prefer` | Prefer SSL, fallback allowed | ⚠️ Medium |
| `require` | Require SSL, no cert verification | ✅ Good |
| `verify-ca` | Require SSL + verify server cert | ✅ Better |
| `verify-full` | Require SSL + verify cert + hostname | ✅✅ Best |

#### 2. Use Kubernetes Secrets for Credentials

Never hardcode passwords in the connection string.

```bash
# Create secret with database credentials
oc create secret generic spire-postgres-credentials \
  -n zero-trust-workload-identity-manager \
  --from-literal=username=admin \
  --from-literal=password=secure-random-password-here

# Reference in SpireServer CR (requires operator support)
```

#### 3. Implement Network Policies

Restrict network access to PostgreSQL.

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: postgresql-allow-spire-only
  namespace: postgresql
spec:
  podSelector:
    matchLabels:
      name: postgresql
  policyTypes:
  - Ingress
  ingress:
  - from:
    - namespaceSelector:
        matchLabels:
          name: zero-trust-workload-identity-manager
    ports:
    - protocol: TCP
      port: 5432
```

### High Availability

#### PostgreSQL Replication

For production, consider:
- **Primary-Standby Replication**: Automatic failover
- **Patroni**: HA PostgreSQL cluster manager
- **Crunchy PostgreSQL Operator**: OpenShift-native PostgreSQL HA

#### Connection Pooling

Configure appropriate connection pool settings:

```yaml
spec:
  datastore:
    maxOpenConns: 100      # Max concurrent connections
    maxIdleConns: 10       # Keep idle connections for reuse
    connMaxLifetime: 3600  # Rotate connections every hour
```

**Recommendations by Load:**

| Workload | maxOpenConns | maxIdleConns |
|----------|--------------|--------------|
| Small (< 100 workloads) | 50 | 5 |
| Medium (100-1000 workloads) | 100 | 10 |
| Large (> 1000 workloads) | 200 | 20 |

### Backup and Recovery

#### Database Backup

```bash
# Create backup
oc exec -n postgresql $(oc get pods -n postgresql -l name=postgresql -o name) -- \
  pg_dump -U admin -d sampledb -F c -f /tmp/spire-backup.dump

# Copy backup from pod
oc cp postgresql/$(oc get pods -n postgresql -l name=postgresql -o jsonpath='{.items[0].metadata.name}'):/tmp/spire-backup.dump \
  ./spire-backup-$(date +%Y%m%d).dump
```

#### Automated Backup Schedule

```yaml
apiVersion: batch/v1
kind: CronJob
metadata:
  name: postgresql-backup
  namespace: postgresql
spec:
  schedule: "0 2 * * *"  # 2 AM daily
  jobTemplate:
    spec:
      template:
        spec:
          containers:
          - name: backup
            image: registry.redhat.io/rhel8/postgresql-10:latest
            command:
            - /bin/sh
            - -c
            - pg_dump -U admin -h postgresql -d sampledb -F c > /backups/spire-$(date +\%Y\%m\%d).dump
            env:
            - name: PGPASSWORD
              valueFrom:
                secretKeyRef:
                  name: postgresql
                  key: database-password
            volumeMounts:
            - name: backups
              mountPath: /backups
          volumes:
          - name: backups
            persistentVolumeClaim:
              claimName: postgresql-backups
          restartPolicy: OnFailure
```

### Monitoring

#### Database Connection Monitoring

```bash
# Monitor SPIRE server logs for database errors
oc logs -n zero-trust-workload-identity-manager spire-server-0 -c spire-server -f | grep -i "sql\|database"

# Check active connections
oc exec -n postgresql $(oc get pods -n postgresql -l name=postgresql -o name) -- \
  psql -U admin -d sampledb -c "SELECT count(*) FROM pg_stat_activity WHERE datname='sampledb';"
```

#### Prometheus Metrics

SPIRE Server exposes Prometheus metrics on port 9402:

```bash
# Port-forward to access metrics
oc port-forward -n zero-trust-workload-identity-manager spire-server-0 9402:9402

# Query metrics
curl http://localhost:9402/metrics | grep -E "(spire_server_datastore|database)"
```

**Key Metrics:**
- `spire_server_datastore_query_duration_seconds` - Query latency
- `spire_server_datastore_connections_open` - Open connections
- `spire_server_datastore_query_errors_total` - Query errors

### Migration from SQLite to PostgreSQL

If you have existing data in SQLite that needs to be migrated:

#### Option 1: Export and Import (Small Datasets)

```bash
# Export from SQLite (on old server)
sqlite3 /run/spire/data/datastore.sqlite3 .dump > spire-data.sql

# Convert to PostgreSQL format (requires pgloader)
pgloader spire-data.sql postgresql://admin:password@postgresql/sampledb
```

#### Option 2: Use SPIRE Server API (Recommended)

1. Deploy new SPIRE Server with PostgreSQL
2. Use SPIRE Server API to fetch entries from old server
3. Register entries in new server using API or declarative configs
4. Update agents to point to new server

---

## Verification and Testing

### Complete System Health Check

```bash
# Check all SPIRE components
oc get pods -n zero-trust-workload-identity-manager

# Expected output:
# spire-server-0                                         2/2     Running
# spire-agent-xxxxx                                      1/1     Running
# spire-agent-yyyyy                                      1/1     Running
# spire-agent-zzzzz                                      1/1     Running
# spire-spiffe-csi-driver-xxxxx                          2/2     Running
# spire-spiffe-oidc-discovery-provider-xxxxx             1/1     Running

# Check PostgreSQL
oc get pods -n postgresql

# Expected output:
# postgresql-1-xxxxx   1/1     Running
```

### Test Workload Identity

Deploy a test workload to verify SPIRE is functioning:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: test-workload
  namespace: default
spec:
  serviceAccountName: default
  containers:
  - name: app
    image: registry.access.redhat.com/ubi8/ubi-minimal:latest
    command: ["/bin/sh", "-c", "sleep 3600"]
    volumeMounts:
    - name: spiffe-workload-api
      mountPath: /spiffe-workload-api
      readOnly: true
  volumes:
  - name: spiffe-workload-api
    csi:
      driver: csi.spiffe.io
      readOnly: true
```

```bash
# Deploy test pod
oc apply -f test-workload.yaml

# Check if workload received SPIFFE identity
oc exec test-workload -- ls -la /spiffe-workload-api/
```

---

## Summary

### What We Accomplished

✅ **Deployed PostgreSQL** on OpenShift with persistent storage (10Gi)  
✅ **Configured SPIRE Server** to use PostgreSQL as datastore  
✅ **Resolved SSL connection issues** by configuring appropriate SSL mode  
✅ **Fixed agent certificate problems** after CA regeneration  
✅ **Verified database schema** with 13 SPIRE tables created  
✅ **Confirmed 3 agents registered** and attesting successfully  
✅ **Validated workload registrations** are stored in PostgreSQL

### Final Architecture

```
┌─────────────────────────────────────────────────────────────┐
│ OpenShift Cluster                                            │
│                                                              │
│  ┌────────────────────────────┐    ┌──────────────────────┐│
│  │ SPIRE Server (StatefulSet) │───▶│ PostgreSQL           ││
│  │ Status: 2/2 Running        │    │ Status: 1/1 Running  ││
│  │ ConfigMap: Updated ✅      │    │ PVC: 10Gi Bound ✅   ││
│  │ DataStore: postgres ✅     │    │ Tables: 13 ✅        ││
│  └────────────────────────────┘    └──────────────────────┘│
│           │                                                  │
│           ├──────────────────────────────────────┐          │
│           ▼                  ▼                   ▼          │
│  ┌─────────────┐    ┌─────────────┐    ┌─────────────┐    │
│  │ Agent 1 ✅  │    │ Agent 2 ✅  │    │ Agent 3 ✅  │    │
│  │ Attested    │    │ Attested    │    │ Attested    │    │
│  └─────────────┘    └─────────────┘    └─────────────┘    │
│                                                              │
│  Workloads Registered: 3 ✅                                 │
│  Trust Domain: apps.aagnihot-cluster-dfdsa.devcluster...    │
└─────────────────────────────────────────────────────────────┘
```

### Key Configuration

```yaml
apiVersion: operator.openshift.io/v1alpha1
kind: SpireServer
metadata:
  name: cluster
spec:
  datastore:
    databaseType: postgres
    connectionString: postgresql://admin:redhat123@postgresql.postgresql.svc.cluster.local:5432/sampledb?sslmode=disable
    maxOpenConns: 100
    maxIdleConns: 2
    connMaxLifetime: 3600
    disableMigration: "false"
```

### Connection Details

| Component | Value |
|-----------|-------|
| **PostgreSQL Service** | `postgresql.postgresql.svc.cluster.local:5432` |
| **Database** | `sampledb` |
| **Username** | `admin` |
| **Tables** | 13 SPIRE tables |
| **Storage** | 10Gi persistent volume (gp3-csi) |
| **SSL Mode** | Disabled (sslmode=disable) |

---

## References

- [SPIRE SQL DataStore Plugin Documentation](https://github.com/spiffe/spire/blob/main/doc/plugin_server_datastore_sql.md)
- [PostgreSQL Connection Strings](https://www.postgresql.org/docs/current/libpq-connect.html#LIBPQ-CONNSTRING)
- [OpenShift Templates](https://docs.openshift.com/container-platform/latest/openshift_images/using-templates.html)
- [SPIFFE/SPIRE Documentation](https://spiffe.io/docs/)

---

## Appendix: Quick Reference Commands

### PostgreSQL Management
```bash
# Access PostgreSQL pod
PGPOD=$(oc get pods -n postgresql -l name=postgresql -o name)

# Execute SQL query
oc exec -n postgresql $PGPOD -- psql -U admin -d sampledb -c "SELECT * FROM bundles;"

# List all tables
oc exec -n postgresql $PGPOD -- psql -U admin -d sampledb -c "\dt"

# Check database size
oc exec -n postgresql $PGPOD -- psql -U admin -d sampledb -c "SELECT pg_size_pretty(pg_database_size('sampledb'));"
```

### SPIRE Management
```bash
# Check SPIRE Server status
oc get pods -n zero-trust-workload-identity-manager -l app=spire-server

# View SPIRE Server logs
oc logs -n zero-trust-workload-identity-manager spire-server-0 -c spire-server

# Check SPIRE Server configuration
oc get spireserver cluster -o yaml

# View datastore configuration
oc get configmap -n zero-trust-workload-identity-manager spire-server -o jsonpath='{.data.server\.conf}' | jq '.plugins.DataStore'

# Restart SPIRE Server
oc delete pod -n zero-trust-workload-identity-manager spire-server-0

# Restart all SPIRE Agents
oc delete pods -n zero-trust-workload-identity-manager -l app.kubernetes.io/name=spire-agent
```

### Troubleshooting
```bash
# Check for SSL errors
oc logs -n zero-trust-workload-identity-manager spire-server-0 -c spire-server | grep -i ssl

# Check for certificate errors
oc logs -n zero-trust-workload-identity-manager -l app.kubernetes.io/name=spire-agent | grep -i "certificate\|x509"

# Force configmap reconciliation
oc delete configmap -n zero-trust-workload-identity-manager spire-server

# Check operator logs (if issues persist)
oc logs -n zero-trust-workload-identity-manager -l app.kubernetes.io/name=zero-trust-workload-identity-manager
```

---

**Document Version:** 1.0  
**Last Updated:** 2025-10-30  
**Tested On:** OpenShift 4.20, SPIRE 1.12.4, PostgreSQL 10

