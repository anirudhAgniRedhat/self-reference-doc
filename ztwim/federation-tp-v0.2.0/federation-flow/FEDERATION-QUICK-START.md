# SPIRE Federation - Quick Start Guide

## 🎯 What is Federation?

Federation allows workloads in **different trust domains** to authenticate each other.

```
Trust Domain A          Federation          Trust Domain B
(cluster1)         <────────────────>      (cluster2)
   │                                           │
   ├─ Workload A                               ├─ Workload B
   │  Gets: SVID-A                             │  Gets: SVID-B
   │        Bundle-A (local)                   │        Bundle-B (local)
   │        Bundle-B (federated) ◄─────────────┤        Bundle-A (federated)
   │                                           │
   └─► Can authenticate Workload B! ◄─────────┘
```

## 🚀 Test Federation in 2 Minutes

### Using Docker Compose (Easiest)

```bash
# 1. Navigate to test suite
cd test/integration/suites/ghostunnel-federation

# 2. Run the complete test
bash -c '
  ./00-setup &&
  ./01-start-servers &&
  ./02-bootstrap-federation-and-agents &&
  ./03-start-remaining-containers &&
  ./04-create-workload-entries &&
  ./05-check-workload-connectivity
'

# 3. If successful, you'll see:
# ✓ Proxy OK
# This means workloads in different trust domains successfully communicated!
```

### What This Tests

```
┌─────────────────────────────────────────────────────────────────┐
│                     Test Architecture                            │
└─────────────────────────────────────────────────────────────────┘

  Upstream Domain                    Downstream Domain
  (upstream-domain.test)             (downstream-domain.test)
  
  ┌──────────────────┐              ┌──────────────────┐
  │ SPIRE Server     │◄────────────►│ SPIRE Server     │
  │ Port 8443        │  Federation  │ Port 8443        │
  └────────┬─────────┘              └────────┬─────────┘
           │                                 │
           │                                 │
  ┌────────▼─────────┐              ┌───────▼──────────┐
  │ SPIRE Agent      │              │ SPIRE Agent      │
  └────────┬─────────┘              └────────┬─────────┘
           │                                 │
           │                                 │
  ┌────────▼─────────┐              ┌───────▼──────────┐
  │ Ghostunnel       │              │ Ghostunnel       │
  │ (mTLS Proxy)     │              │ (mTLS Proxy)     │
  └────────┬─────────┘              └────────┬─────────┘
           │                                 │
           │    Encrypted Cross-Domain       │
           │         Connection              │
           └────────────────┬────────────────┘
                            │
                      ✓ SUCCESS!
```

## 📋 Step-by-Step Manual Testing

### Step 1: Setup and Start Servers
```bash
cd test/integration/suites/ghostunnel-federation

# Setup environment
./00-setup

# Start both SPIRE servers
./01-start-servers

# Verify servers are running
docker compose ps
# Expected: Both servers in "running" state
```

### Step 2: Bootstrap Federation
```bash
# This script:
# 1. Extracts bundle from each server
# 2. Configures each server to federate with the other
./02-bootstrap-federation-and-agents

# Verify bundle exchange worked
docker compose exec upstream-spire-server \
  /opt/spire/bin/spire-server bundle list

# Expected output:
# spiffe://upstream-domain.test     [local]
# spiffe://downstream-domain.test   [federated] ← This proves federation!
```

### Step 3: Start Workloads
```bash
# Start agents and workload containers
./03-start-remaining-containers

# Check all containers
docker compose ps
# Expected: 6 containers running
```

### Step 4: Create Workload Entries
```bash
# Register workloads with federation enabled
./04-create-workload-entries

# Verify entries (in upstream)
docker compose exec upstream-spire-server \
  /opt/spire/bin/spire-server entry show

# Look for: "Federates with: downstream-domain.test"
```

### Step 5: Test Cross-Domain Communication
```bash
# Test that workloads can communicate across trust domains
./05-check-workload-connectivity

# This test:
# 1. Downstream workload sends "HELLO" through Ghostunnel
# 2. Ghostunnel uses SPIFFE IDs for mTLS
# 3. Upstream workload receives message
# 4. Success = Federation works!
```

## 🔍 Verify Federation Manually

### Check Bundle Endpoint
```bash
# Test bundle endpoint is accessible
docker compose exec upstream-spire-server \
  curl -k https://localhost:8443

# Expected: JSON with trust bundle (JWKS format)
```

### Check Agent Has Federated Bundles
```bash
# Fetch SVID from agent
docker compose exec upstream-spire-agent \
  /opt/spire/bin/spire-agent api fetch x509 \
  -socketPath /run/spire/sockets/agent.sock

# Expected output should show:
# - SVID for workload
# - Bundle for upstream-domain.test (1 cert)
# - Bundle for downstream-domain.test (1 cert) ← Federated!
```

### View Server Logs
```bash
# Watch federation activity
docker compose logs -f upstream-spire-server | grep -i federation
docker compose logs -f downstream-spire-server | grep -i federation

# Look for:
# - "Bundle endpoint listening"
# - "Fetching bundle from endpoint"
# - "Bundle updated for trust domain"
```

## 🧪 Advanced: Test Bundle Rotation

Federation continues working even when CAs rotate:

```bash
# Force rotate upstream CA
docker compose exec upstream-spire-server \
  /opt/spire/bin/spire-server localauthority x509 prepare \
  -authorityID <authority-id>

docker compose exec upstream-spire-server \
  /opt/spire/bin/spire-server localauthority x509 activate \
  -authorityID <authority-id>

# Wait a few seconds for bundle propagation
sleep 10

# Test connectivity still works
./05-check-workload-connectivity

# ✓ Should still pass! Bundle was automatically updated via federation
```

## 🎯 Test Resilience

The test suite includes resilience tests:

```bash
# Test 1: Servers go down
./06-stop-servers
./07-check-workload-connectivity
# ✓ Still works! Cached bundles and SVIDs allow continued operation

# Test 2: Restart servers
./08-start-servers
./09-check-workload-connectivity
# ✓ Works! Federation re-established

# Test 3: Agents go down
./10-stop-agents
./11-check-workload-connectivity
# ✗ Expected to fail (agents needed for SVID renewal)

# Test 4: Restart agents
./12-start-agents
./13-check-workload-connectivity
# ✓ Works again!
```

## 📊 What Success Looks Like

### ✅ Successful Federation Indicators

1. **Bundle List Shows Both Domains**
   ```
   $ spire-server bundle list
   spiffe://upstream-domain.test
   spiffe://downstream-domain.test
   ```

2. **Workload Gets Federated Bundle**
   ```
   $ spire-agent api fetch x509
   SVID: spiffe://upstream-domain.test/workload
   Trust domains: 2
   ```

3. **Cross-Domain Communication Works**
   ```
   $ ./05-check-workload-connectivity
   ✓ Proxy OK
   ```

4. **Server Logs Show Bundle Sync**
   ```
   level=info msg="Bundle fetched successfully" trust_domain=downstream-domain.test
   ```

### ❌ Common Failures

| Symptom | Cause | Fix |
|---------|-------|-----|
| `bundle not found` | Bundle exchange not configured | Run `02-bootstrap-federation-and-agents` |
| `connection refused :8443` | Bundle endpoint not running | Check server config has `bundle_endpoint` |
| `certificate verify failed` | Wrong endpoint_spiffe_id | Check SPIFFE ID matches server's ID |
| `workload connectivity failed` | No federation in entry | Entry must have `-federatesWith` flag |

## 🔧 Cleanup

```bash
# Stop and remove all containers
docker compose down -v

# Or use the teardown script
./teardown
```

## 📚 Next Steps

1. **Read Full Guide**: See `SPIRE-FEDERATION-FLOW-AND-TESTING.md` for:
   - Detailed flow diagrams
   - Kubernetes deployment
   - Production configurations

2. **Explore Configs**: Check the test configs:
   ```bash
   cat conf/upstream/server/server.conf
   cat conf/downstream/server/server.conf
   ```

3. **Try Kubernetes**: Deploy federation in a real K8s cluster using the guide

## 🎓 Key Concepts Demonstrated

- ✅ **Bundle Endpoints** - HTTPS servers serving trust bundles
- ✅ **Dynamic Sync** - Automatic bundle updates
- ✅ **Cross-Domain mTLS** - Workloads authenticate across trust domains
- ✅ **Resilience** - Federation survives server/agent restarts
- ✅ **SPIFFE Auth** - Using `https_spiffe` profile for secure bundle exchange

---

**🚀 Ready to test? Run this one command:**

```bash
cd test/integration/suites/ghostunnel-federation && \
  ./00-setup && ./01-start-servers && ./02-bootstrap-federation-and-agents && \
  ./03-start-remaining-containers && ./04-create-workload-entries && \
  ./05-check-workload-connectivity && echo "✅ Federation works!"
```


