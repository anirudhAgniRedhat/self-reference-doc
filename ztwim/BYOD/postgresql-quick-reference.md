# PostgreSQL Integration - Quick Reference

## 🚀 Quick Start

### Deploy PostgreSQL
```bash
export KUBECONFIG=/path/to/kubeconfig

# Create namespace
oc create namespace postgresql

# Deploy PostgreSQL
oc new-app postgresql-persistent -n postgresql \
  -p POSTGRESQL_USER=admin \
  -p POSTGRESQL_PASSWORD=redhat123 \
  -p POSTGRESQL_DATABASE=sampledb \
  -p VOLUME_CAPACITY=10Gi
```

### Configure SPIRE Server
```bash
# Patch SpireServer CR
oc patch spireserver cluster --type='merge' -p '{
  "spec": {
    "datastore": {
      "databaseType": "postgres",
      "connectionString": "postgresql://admin:redhat123@postgresql.postgresql.svc.cluster.local:5432/sampledb?sslmode=disable",
      "maxOpenConns": 100,
      "maxIdleConns": 2,
      "connMaxLifetime": 3600
    }
  }
}'

# If needed, force configmap recreation
oc delete configmap -n zero-trust-workload-identity-manager spire-server

# Restart SPIRE server
oc delete pod -n zero-trust-workload-identity-manager spire-server-0

# Restart agents (if certificate errors)
oc delete pods -n zero-trust-workload-identity-manager -l app.kubernetes.io/name=spire-agent
```

## 📊 Connection Details

| Parameter | Value |
|-----------|-------|
| Service (FQDN) | `postgresql.postgresql.svc.cluster.local` |
| Port | `5432` |
| Database | `sampledb` |
| Username | `admin` |
| Password | `redhat123` |
| Storage | `10Gi` (gp3-csi) |

## 🔍 Common Queries

### Set Variables
```bash
export KUBECONFIG=/path/to/kubeconfig
PGPOD=$(oc get pods -n postgresql -l name=postgresql -o name)
```

### View Tables
```bash
oc exec -n postgresql $PGPOD -- psql -U admin -d sampledb -c "\dt"
```

### View Registered Agents
```bash
oc exec -n postgresql $PGPOD -- psql -U admin -d sampledb -c "
SELECT id, spiffe_id, expires_at 
FROM attested_node_entries;"
```

### View Registered Workloads
```bash
oc exec -n postgresql $PGPOD -- psql -U admin -d sampledb -c "
SELECT entry_id, spiffe_id 
FROM registered_entries;"
```

### View Row Counts
```bash
oc exec -n postgresql $PGPOD -- psql -U admin -d sampledb -c "
SELECT relname AS table_name, n_live_tup AS row_count 
FROM pg_stat_user_tables 
ORDER BY n_live_tup DESC;"
```

## ⚠️ Common Issues

### Issue 1: SSL Error
**Error:** `pq: SSL is not enabled on the server`

**Solution:** Add `?sslmode=disable` to connection string
```bash
oc patch spireserver cluster --type='merge' -p '{
  "spec": {
    "datastore": {
      "connectionString": "postgresql://admin:redhat123@postgresql.postgresql.svc.cluster.local:5432/sampledb?sslmode=disable"
    }
  }
}'
```

### Issue 2: Certificate Verification Error
**Error:** `x509: certificate signed by unknown authority`

**Solution:** Restart agents to pick up new CA
```bash
oc delete pods -n zero-trust-workload-identity-manager -l app.kubernetes.io/name=spire-agent
```

## ✅ Verification

### Check SPIRE Server
```bash
# Pod status
oc get pods -n zero-trust-workload-identity-manager spire-server-0

# Should show: 2/2 Running

# Check logs for success
oc logs -n zero-trust-workload-identity-manager spire-server-0 -c spire-server --tail=20 | grep "Connected to SQL"

# Expected: "Connected to SQL database" with type=postgres
```

### Check SPIRE Agents
```bash
# Pod status
oc get pods -n zero-trust-workload-identity-manager -l app.kubernetes.io/name=spire-agent

# Should show: X/X Running (all ready)

# Check logs for success
oc logs -n zero-trust-workload-identity-manager -l app.kubernetes.io/name=spire-agent --tail=10 | grep "successful"

# Expected: "Node attestation was successful"
```

### Check Database
```bash
# Verify tables created
oc exec -n postgresql $PGPOD -- psql -U admin -d sampledb -c "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='public';"

# Should show: 13 tables

# Verify agents registered
oc exec -n postgresql $PGPOD -- psql -U admin -d sampledb -c "SELECT COUNT(*) FROM attested_node_entries;"

# Should show: number of nodes in cluster
```

## 📚 Documentation

For complete documentation with detailed explanations, see:
- **[PostgreSQL Integration Guide](./postgresql-integration-guide.md)** - Full guide with troubleshooting

## 🔐 Production Notes

For production deployments:
1. ✅ Use SSL/TLS: `sslmode=require` or `sslmode=verify-full`
2. ✅ Store passwords in Kubernetes Secrets
3. ✅ Configure PostgreSQL with replication for HA
4. ✅ Implement regular database backups
5. ✅ Use Network Policies to restrict database access
6. ✅ Monitor database connections and performance

## 🛠️ Maintenance

### Backup Database
```bash
oc exec -n postgresql $PGPOD -- pg_dump -U admin -d sampledb -F c > spire-backup-$(date +%Y%m%d).dump
```

### Check Database Size
```bash
oc exec -n postgresql $PGPOD -- psql -U admin -d sampledb -c "
SELECT pg_size_pretty(pg_database_size('sampledb')) AS size;"
```

### Monitor Active Connections
```bash
oc exec -n postgresql $PGPOD -- psql -U admin -d sampledb -c "
SELECT count(*) FROM pg_stat_activity WHERE datname='sampledb';"
```

## 🎯 Connection String Formats

### Format 1: URI (Recommended)
```
postgresql://username:password@host:port/database?sslmode=disable
```

### Format 2: Key-Value
```
host=hostname port=5432 user=username password=password dbname=database sslmode=disable
```

### SSL Modes
| Mode | Security | Description |
|------|----------|-------------|
| `disable` | ⚠️ Low | No encryption (dev only) |
| `require` | ✅ Good | SSL required, no cert check |
| `verify-ca` | ✅ Better | SSL + verify server cert |
| `verify-full` | ✅✅ Best | SSL + verify cert + hostname |

---

**Quick Reference Version:** 1.0  
**Last Updated:** 2025-10-30

