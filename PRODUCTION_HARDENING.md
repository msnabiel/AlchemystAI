# Production Hardening Analysis

This document outlines what would need to change before deploying this system to production, and how to scale for significantly larger models.

---

## Current State: Prototype Deployment

The current implementation is a **proof-of-concept** suitable for:
- Development/testing environments
- Technical demonstrations
- Educational purposes
- Free-tier experimentation

**Not suitable for production** due to:
- No authentication/authorization
- No TLS encryption
- No monitoring or alerting
- No high availability
- No rate limiting
- Hardcoded configurations
- Single points of failure

---

## Production Readiness Checklist

### 1. Security Hardening

#### 1.1 TLS/HTTPS Everywhere
**Current**: Plain HTTP on port 8080, unencrypted WebSocket connections

**Production**:
```
┌─ Add nginx reverse proxy on API Gateway VM:
│
├─ Install: apt-get install nginx certbot python3-certbot-nginx
├─ Configure nginx:
│   location /math/add {
│     proxy_pass http://localhost:8080;
│     proxy_http_version 1.1;
│     proxy_set_header Upgrade $http_upgrade;
│     proxy_set_header Connection 'upgrade';
│   }
├─ Obtain certificate: certbot --nginx -d api.yourdomain.com
└─ Auto-renewal: systemctl enable certbot.timer

Result: https://api.yourdomain.com/math/add
```

**For engine/worker communication**:
- Upgrade to `wss://` (WebSocket Secure)
- Use self-signed certificates for internal traffic (or private CA)
- Mount certificates via GCP Secret Manager

#### 1.2 Authentication & Authorization
**Current**: Anyone can call the API

**Production options**:

**Option A: API Keys**
```typescript
// In api-gateway/src/server.ts
const API_KEYS = new Set(process.env.API_KEYS?.split(',') || []);

function validateApiKey(req: http.IncomingMessage): boolean {
  const apiKey = req.headers['x-api-key'];
  return apiKey && API_KEYS.has(apiKey as string);
}

// In request handler:
if (!validateApiKey(req)) {
  res.writeHead(401, { 'Content-Type': 'application/json' });
  res.end(JSON.stringify({ error: 'Unauthorized' }));
  return;
}
```

**Option B: JWT Tokens**
```bash
npm install jsonwebtoken
```
```typescript
import jwt from 'jsonwebtoken';

function validateJWT(token: string): boolean {
  try {
    jwt.verify(token, process.env.JWT_SECRET!);
    return true;
  } catch {
    return false;
  }
}
```

**Option C: OAuth 2.0 / Identity-Aware Proxy**
- Use GCP IAP (Identity-Aware Proxy) in front of load balancer
- Integrate with Google, GitHub, or corporate SSO
- No code changes needed, handled at infrastructure layer

#### 1.3 Rate Limiting
**Current**: No protection against abuse

**Production**:

**Option A: nginx rate limiting**
```nginx
# /etc/nginx/nginx.conf
http {
  limit_req_zone $binary_remote_addr zone=api_limit:10m rate=10r/s;

  server {
    location /math/add {
      limit_req zone=api_limit burst=20 nodelay;
      limit_req_status 429;
      # ... proxy_pass ...
    }
  }
}
```

**Option B: Application-level (Redis)**
```typescript
import { createClient } from 'redis';

const redis = createClient({ url: 'redis://10.0.1.20:6379' });

async function checkRateLimit(ip: string): Promise<boolean> {
  const key = `ratelimit:${ip}`;
  const count = await redis.incr(key);
  if (count === 1) {
    await redis.expire(key, 60); // 1 minute window
  }
  return count <= 100; // 100 requests per minute
}
```

**Option C: Cloud Armor**
- Deploy HTTP(S) Load Balancer in front of API Gateway
- Configure Cloud Armor security policy:
  - Rate limiting: 100 req/min per IP
  - DDoS protection
  - Geographic restrictions
  - OWASP top 10 protection

#### 1.4 Secrets Management
**Current**: Secrets could be hardcoded or in environment variables

**Production**:
```bash
# Create secret in GCP
gcloud secrets create api-keys --data-file=./api-keys.txt

# Grant VM access
gcloud secrets add-iam-policy-binding api-keys \
  --member=serviceAccount:api-gateway@project.iam.gserviceaccount.com \
  --role=roles/secretmanager.secretAccessor

# Fetch in startup script
API_KEYS=$(gcloud secrets versions access latest --secret=api-keys)
```

In systemd service:
```ini
[Service]
ExecStartPre=/usr/local/bin/fetch-secrets.sh
EnvironmentFile=/run/secrets/api-gateway.env
```

#### 1.5 Network Isolation
**Current**: VMs can communicate freely within subnet

**Production**:
- **Micro-segmentation**: Each worker type gets its own subnet
- **Firewall rules**: Deny all by default, allow only necessary paths
- **Service accounts**: Separate SA per VM with minimal IAM permissions
- **VPC Service Controls**: Restrict API access to specific perimeters

Example:
```
10.0.1.0/26  → API Gateway subnet
10.0.2.0/26  → Engine subnet
10.0.3.0/26  → Math Worker subnet
10.0.4.0/26  → Caller Worker subnet

Firewall:
- api-gateway → engine:49134 only
- workers → engine:49134 only
- Deny all other paths
```

---

### 2. Reliability & High Availability

#### 2.1 Eliminate Single Points of Failure

**Current**: Each component is a single VM. If any dies, system fails.

**Production**:

**Engine HA**:
- Deploy 3 engine instances behind internal TCP load balancer
- Use etcd/Consul for leader election and state coordination
- Workers connect to load balancer VIP (e.g., `ws://10.0.1.100:49134`)

**Worker HA**:
- Use Managed Instance Groups (MIGs) with min 2 instances per worker type
- Engine distributes load across available workers
- Auto-healing: unhealthy instances replaced automatically

**API Gateway HA**:
- MIG with 2+ instances behind HTTP(S) Load Balancer
- Health checks on `/health` endpoint
- Anycast IP for global availability

#### 2.2 Health Checks & Auto-Healing

**Add health endpoints**:
```typescript
// In each worker
worker.registerFunction('health::check', async () => {
  const engineConnected = worker.isConnected(); // hypothetical
  return {
    status: engineConnected ? 'healthy' : 'unhealthy',
    timestamp: Date.now(),
  };
});
```

**MIG health checks**:
```hcl
resource "google_compute_health_check" "api_gateway" {
  name = "api-gateway-health"
  http_health_check {
    port         = 8080
    request_path = "/health"
  }
  check_interval_sec  = 10
  timeout_sec         = 5
  healthy_threshold   = 2
  unhealthy_threshold = 3
}

resource "google_compute_instance_group_manager" "api_gateway" {
  name               = "api-gateway-mig"
  base_instance_name = "api-gateway"
  target_size        = 2

  auto_healing_policies {
    health_check      = google_compute_health_check.api_gateway.id
    initial_delay_sec = 300
  }
}
```

#### 2.3 Data Persistence & State Management

**Current**: No persistent state (stateless workers)

**Production** (if state needed):
- Use Cloud SQL (PostgreSQL) for structured data
- Use Firestore/Datastore for NoSQL
- Use Cloud Memorystore (Redis) for session state
- Implement `iii-state` worker backed by persistent storage

#### 2.4 Graceful Shutdown & Zero-Downtime Deploys

**Add to workers**:
```typescript
let isShuttingDown = false;

process.on('SIGTERM', async () => {
  console.log('Received SIGTERM, draining requests...');
  isShuttingDown = true;

  // Stop accepting new work
  worker.pause();

  // Wait for in-flight requests to complete (max 30s)
  await new Promise(resolve => setTimeout(resolve, 30000));

  // Disconnect gracefully
  await worker.disconnect();
  process.exit(0);
});
```

**In systemd**:
```ini
[Service]
KillMode=mixed
KillSignal=SIGTERM
TimeoutStopSec=60
```

**Rolling updates**:
```bash
# Update MIG with new instance template (zero downtime)
gcloud compute instance-groups managed rolling-action start-update \
  math-worker-mig \
  --version template=math-worker-template-v2 \
  --max-surge=1 \
  --max-unavailable=0
```

---

### 3. Monitoring & Observability

#### 3.1 Metrics Collection

**Instrument workers**:
```typescript
import { Metrics } from 'iii-sdk';

const metrics = new Metrics();

worker.registerFunction('math::add_two_numbers', async (payload) => {
  const startTime = Date.now();

  try {
    const result = await worker.trigger({ function_id: 'math::add', payload });

    metrics.recordLatency('math::add_two_numbers', Date.now() - startTime);
    metrics.increment('requests_success');

    return result;
  } catch (error) {
    metrics.increment('requests_failed');
    throw error;
  }
});
```

**Enable iii-observability worker** (already in config.yaml):
- Exports to Cloud Monitoring
- Traces RPC calls across workers
- Records span durations, error rates

**Custom dashboards**:
```bash
# Cloud Monitoring dashboard for:
- Request rate (req/s)
- Latency (p50, p95, p99)
- Error rate (5xx/total)
- VM CPU/memory utilization
- WebSocket connection count
```

#### 3.2 Centralized Logging

**Structured logging**:
```typescript
logger.info('Processing request', {
  function_id: 'math::add_two_numbers',
  payload,
  correlation_id: req.headers['x-correlation-id'],
  timestamp: new Date().toISOString(),
});
```

**Ship logs to Cloud Logging**:
```bash
# Install Ops Agent on VMs
curl -sSO https://dl.google.com/cloudagents/add-google-cloud-ops-agent-repo.sh
sudo bash add-google-cloud-ops-agent-repo.sh --also-install

# Configure to tail systemd logs
sudo tee /etc/google-cloud-ops-agent/config.yaml <<EOF
logging:
  receivers:
    syslog:
      type: systemd_journald
  service:
    pipelines:
      default_pipeline:
        receivers: [syslog]
EOF
sudo systemctl restart google-cloud-ops-agent
```

**Log querying**:
```sql
-- Cloud Logging query for errors
resource.type="gce_instance"
jsonPayload.level="error"
timestamp>="2026-05-23T00:00:00Z"
```

#### 3.3 Alerting

**Create alert policies**:
```yaml
# Cloud Monitoring alert: High error rate
Condition:
  Metric: custom.googleapis.com/worker/requests_failed
  Threshold: > 10 errors/min
  Duration: 5 minutes

Notification:
  Email: oncall@yourcompany.com
  PagerDuty: devops-team
  Slack: #alerts

# Alert: API Gateway down
Condition:
  Metric: compute.googleapis.com/instance/uptime
  Threshold: uptime < 60 seconds
  Instance: api-gateway-*
```

#### 3.4 Distributed Tracing

**Enable OpenTelemetry**:
```typescript
import { trace } from '@opentelemetry/api';

const tracer = trace.getTracer('api-gateway');

// In request handler
const span = tracer.startSpan('POST /math/add');
span.setAttribute('http.method', 'POST');
span.setAttribute('payload.a', payload.a);

try {
  const result = await worker.trigger({ ... });
  span.setStatus({ code: SpanStatusCode.OK });
  return result;
} catch (error) {
  span.recordException(error);
  span.setStatus({ code: SpanStatusCode.ERROR });
  throw error;
} finally {
  span.end();
}
```

**View traces in Cloud Trace**:
- See full request path: API Gateway → Engine → Caller Worker → Engine → Math Worker
- Identify bottlenecks (which hop is slow?)
- Correlate errors across services

---

### 4. Performance & Scalability

#### 4.1 Autoscaling

**Horizontal Pod Autoscaler (if using GKE)**:
```yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: math-worker-hpa
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: math-worker
  minReplicas: 2
  maxReplicas: 20
  metrics:
  - type: Resource
    resource:
      name: cpu
      target:
        type: Utilization
        averageUtilization: 70
  - type: Pods
    pods:
      metric:
        name: rpc_queue_depth
      target:
        type: AverageValue
        averageValue: "10"
```

**MIG autoscaling (current GCE setup)**:
```hcl
resource "google_compute_autoscaler" "math_worker" {
  name   = "math-worker-autoscaler"
  target = google_compute_instance_group_manager.math_worker.id

  autoscaling_policy {
    min_replicas    = 2
    max_replicas    = 10
    cooldown_period = 60

    cpu_utilization {
      target = 0.7
    }

    metric {
      name   = "custom.googleapis.com/worker/queue_depth"
      target = 10
      type   = "GAUGE"
    }
  }
}
```

#### 4.2 Connection Pooling & Keep-Alive

**For WebSocket connections**:
```typescript
// Engine maintains connection pool to workers
const connectionPool = new Map<string, WebSocket>();

// Reuse connections instead of creating new ones
// Implement heartbeat to keep connections alive
setInterval(() => {
  connectionPool.forEach((ws, workerId) => {
    ws.ping();
  });
}, 30000);
```

#### 4.3 Caching

**For repeated computations**:
```typescript
import { createClient } from 'redis';

const redis = createClient({ url: 'redis://10.0.1.20:6379' });

worker.registerFunction('math::add', async (payload) => {
  const cacheKey = `add:${payload.a}:${payload.b}`;

  // Check cache
  const cached = await redis.get(cacheKey);
  if (cached) {
    return JSON.parse(cached);
  }

  // Compute
  const result = { c: payload.a + payload.b };

  // Cache for 1 hour
  await redis.setex(cacheKey, 3600, JSON.stringify(result));

  return result;
});
```

---

### 5. Disaster Recovery & Business Continuity

#### 5.1 Backups

**VM snapshots**:
```bash
# Automated daily snapshots
gcloud compute disks snapshot iii-engine-disk \
  --snapshot-names=iii-engine-snapshot-$(date +%Y%m%d) \
  --zone=us-central1-a

# Retention: 7 daily, 4 weekly, 12 monthly
```

**Infrastructure state**:
```bash
# Store Terraform state in GCS with versioning
terraform {
  backend "gcs" {
    bucket = "mycompany-terraform-state"
    prefix = "iii-prod"
  }
}
```

#### 5.2 Multi-Region Deployment

**Current**: Single region (us-central1)

**Production**:
```
┌─ Primary: us-central1
│  ├─ Full deployment (engine + workers + API)
│  └─ Serves US traffic
│
├─ Secondary: europe-west1
│  ├─ Full deployment (engine + workers + API)
│  └─ Serves EU traffic
│
└─ Global Load Balancer
   ├─ Routes traffic to nearest region
   ├─ Failover to secondary if primary unhealthy
   └─ Anycast IP: 35.190.x.x
```

#### 5.3 Runbooks & Incident Response

**Document procedures**:
```markdown
# Runbook: API Gateway Down

## Symptoms
- Health check failing
- 503 errors from load balancer
- CloudWatch alert: "API Gateway instance unhealthy"

## Diagnosis
1. Check VM status: `gcloud compute instances list --filter="name:api-gateway-*"`
2. SSH and check service: `sudo systemctl status api-gateway.service`
3. Review logs: `sudo journalctl -u api-gateway.service -n 100`

## Remediation
1. Restart service: `sudo systemctl restart api-gateway.service`
2. If startup script failed, check `/var/log/startup.log`
3. If persistent failure, delete instance (MIG will recreate)
4. Escalate to on-call engineer if issue persists >15 min

## Postmortem
- Root cause analysis
- Update monitoring/alerting
- Improve automation
```

---

## Scaling for 100x Larger Model

### Scenario: Current model is 50MB, new model is 5GB (100x)

Current bottlenecks that break at scale:
1. **Model loading time**: 5GB takes minutes to load into memory
2. **Memory constraints**: e2-medium (4GB RAM) cannot hold model
3. **Inference latency**: Large models need GPU, not CPU
4. **Throughput**: Single worker can't handle production traffic

---

### Architecture Redesign

#### Before (Current):
```
API Gateway → Engine → Worker VM (CPU, 4GB RAM, model in-memory)
                         └─ 50MB model
                         └─ 100ms inference
                         └─ 10 req/s throughput
```

#### After (100x Model):
```
                    API Gateway (unchanged)
                           |
                           v
                    Cloud Tasks Queue ─────┐
                           |                │
                           v                │ (polling)
                  Internal Load Balancer   │
                           |                │
        ┌──────────────────┼────────────────┼───────┐
        v                  v                v       v
   GPU VM Pool          GPU VM           GPU VM   GPU VM
   (n1-highmem-8      (preemptible)                (MIG)
    + T4 GPU)
        |
        v
   Model Storage ──────── Redis Cache
   (Cloud Storage         (embeddings,
    5GB model weights)    frequent queries)
```

---

### Implementation Changes

#### 1. Switch to GPU VMs

**Terraform changes**:
```hcl
resource "google_compute_instance_template" "math_worker_gpu" {
  machine_type = "n1-highmem-8"  # 52GB RAM

  # Attach T4 GPU (or V100/A100 for larger models)
  guest_accelerator {
    type  = "nvidia-tesla-t4"
    count = 1
  }

  boot_disk {
    initialize_params {
      # Use Deep Learning VM image (pre-installed CUDA/cuDNN)
      image = "deeplearning-platform-release/pytorch-latest-gpu"
      size  = 100  # Need space for model + dependencies
    }
  }

  # GPU scheduling (only run when needed to save cost)
  scheduling {
    preemptible       = true  # 60-70% cheaper
    automatic_restart = false
    on_host_maintenance = "TERMINATE"
  }
}
```

#### 2. Use Model Serving Framework

**Replace custom Python worker with TorchServe**:

```bash
# Install TorchServe
pip install torchserve torch-model-archiver

# Create model archive
torch-model-archiver \
  --model-name math_model \
  --version 1.0 \
  --model-file model.py \
  --serialized-file model.pth \
  --handler custom_handler.py

# Start TorchServe
torchserve \
  --start \
  --model-store /models \
  --models math_model=math_model.mar \
  --ts-config config.properties
```

**TorchServe config**:
```properties
# config.properties
inference_address=http://0.0.0.0:8080
management_address=http://0.0.0.0:8081
number_of_gpu=1
batch_size=32
max_batch_delay=50  # Wait 50ms to accumulate batch
```

**Benefits**:
- Built-in batching (process 32 requests at once)
- GPU utilization optimization
- Metrics/monitoring out of the box
- gRPC support (faster than HTTP)

#### 3. Implement Request Queue

**Why**: Large model inference takes 5-10 seconds. Can't block HTTP request.

**Solution**: Async processing

**API Gateway changes**:
```typescript
import { CloudTasksClient } from '@google-cloud/tasks';

const tasksClient = new CloudTasksClient();

app.post('/math/add', async (req, res) => {
  const jobId = uuidv4();

  // Create Cloud Task
  await tasksClient.createTask({
    parent: 'projects/PROJECT/locations/us-central1/queues/inference',
    task: {
      httpRequest: {
        url: 'http://10.0.1.100:8080/infer',  // Internal LB
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: Buffer.from(JSON.stringify({ jobId, payload: req.body })),
      },
    },
  });

  // Return job ID immediately
  res.json({
    jobId,
    status: 'pending',
    estimatedTime: '5-10 seconds',
  });
});

// Poll endpoint
app.get('/jobs/:jobId', async (req, res) => {
  const result = await redis.get(`job:${req.params.jobId}`);
  if (result) {
    res.json({ status: 'completed', result: JSON.parse(result) });
  } else {
    res.json({ status: 'pending' });
  }
});
```

**Worker changes**:
```python
# Receive task, run inference, store result in Redis
@app.route('/infer', methods=['POST'])
def infer():
    data = request.json
    job_id = data['jobId']
    payload = data['payload']

    # Run inference (5-10 seconds)
    result = model.infer(payload['a'], payload['b'])

    # Store in Redis
    redis.setex(f'job:{job_id}', 3600, json.dumps(result))

    return {'status': 'ok'}
```

#### 4. Model Storage & Lazy Loading

**Problem**: 5GB model takes too long to load on VM startup

**Solution A: Persistent SSD**
```hcl
resource "google_compute_disk" "model_storage" {
  name = "math-model-disk"
  type = "pd-ssd"
  size = 10  # GB
  zone = "us-central1-a"
}

# Attach to all worker VMs
resource "google_compute_instance" "math_worker" {
  attached_disk {
    source = google_compute_disk.model_storage.id
  }
}
```

**Solution B: Cloud Storage + FUSE**
```bash
# Mount GCS bucket as filesystem
gcsfuse model-weights-bucket /models

# Model loads from /models/large_model.pth (streamed from GCS)
```

**Solution C: Model Sharding**
```python
# Split model across multiple GPUs/VMs
from torch.nn.parallel import DistributedDataParallel

model = LargeModel().cuda()
model = DistributedDataParallel(model, device_ids=[0, 1, 2, 3])

# Each GPU handles part of the model
```

#### 5. Intelligent Batching

**Problem**: GPU is most efficient processing batches, not single requests

**Solution**: Accumulate requests before inference

```python
import asyncio
from collections import deque

class BatchInferenceEngine:
    def __init__(self, max_batch_size=32, max_wait_ms=50):
        self.queue = deque()
        self.max_batch_size = max_batch_size
        self.max_wait_ms = max_wait_ms

    async def infer(self, payload):
        # Add to queue
        future = asyncio.Future()
        self.queue.append((payload, future))

        # Trigger batch processing
        if len(self.queue) >= self.max_batch_size:
            await self._process_batch()

        return await future

    async def _process_batch(self):
        batch = []
        futures = []

        # Drain queue
        while self.queue and len(batch) < self.max_batch_size:
            payload, future = self.queue.popleft()
            batch.append(payload)
            futures.append(future)

        # Run batched inference (much faster than individual calls)
        results = model.infer_batch(batch)

        # Resolve futures
        for future, result in zip(futures, results):
            future.set_result(result)
```

**Result**: 10x throughput improvement (100 req/s → 1000 req/s)

#### 6. Caching Layer

**For large models, same inputs often produce same outputs**:

```python
import hashlib
import redis

redis_client = redis.Redis(host='10.0.1.20', port=6379)

def infer_with_cache(payload):
    # Generate cache key
    cache_key = hashlib.sha256(
        json.dumps(payload, sort_keys=True).encode()
    ).hexdigest()

    # Check cache
    cached = redis_client.get(f'infer:{cache_key}')
    if cached:
        return json.loads(cached)

    # Run inference
    result = model.infer(payload)

    # Cache for 24 hours
    redis_client.setex(
        f'infer:{cache_key}',
        86400,
        json.dumps(result)
    )

    return result
```

**Result**: 80% cache hit rate → 5x cost savings

#### 7. Autoscaling Based on Queue Depth

**Problem**: Fixed number of GPUs wastes money during low traffic

**Solution**: Scale workers based on queue depth

```hcl
resource "google_compute_autoscaler" "math_worker_gpu" {
  autoscaling_policy {
    min_replicas    = 1   # Always 1 warm instance
    max_replicas    = 20  # Up to 20 during peak

    metric {
      name   = "pubsub.googleapis.com/subscription/num_undelivered_messages"
      target = 10  # Scale up if >10 pending tasks
    }
  }
}
```

**Cost savings**:
- Off-peak (night): 1 GPU = $200/month
- Peak (day): 5 GPUs average = $1000/month
- vs. always-on 20 GPUs = $4000/month
- **Savings: 75%**

---

### Performance Comparison

| Metric                | Current (50MB) | 100x Model (5GB) Naive | 100x Optimized       |
|-----------------------|----------------|------------------------|----------------------|
| VM Type               | e2-medium (CPU)| n1-highmem-8 (GPU)     | n1-highmem-8 (GPU)   |
| Model Load Time       | 2 seconds      | 5 minutes              | 10 seconds (cached)  |
| Inference Latency     | 100ms          | 10 seconds             | 2 seconds (batched)  |
| Throughput (single VM)| 10 req/s       | 0.1 req/s              | 50 req/s (batching)  |
| Cost per VM           | $24/month      | $500/month             | $150/month (preempt) |
| Total Cost (peak)     | $100/month     | $10,000/month          | $1,500/month         |

**Optimization techniques applied**:
- Batching: 10x throughput
- Caching: 80% requests skip inference
- Preemptible VMs: 70% cost reduction
- Autoscaling: 75% reduction in average VMs needed

---

## Summary

### Production Hardening Priorities

1. **Security** (Week 1):
   - TLS/HTTPS
   - API authentication
   - Rate limiting
   - Secrets management

2. **Reliability** (Week 2):
   - Health checks
   - Auto-healing MIGs
   - Multi-region deployment
   - Graceful shutdown

3. **Observability** (Week 3):
   - Metrics dashboards
   - Centralized logging
   - Alerting
   - Distributed tracing

4. **Performance** (Week 4):
   - Autoscaling
   - Connection pooling
   - Caching
   - Load testing

### 100x Model Scaling Strategy

1. **Infrastructure**: GPU VMs (T4/V100/A100) with persistent model storage
2. **Architecture**: Queue-based async processing instead of synchronous RPC
3. **Framework**: TorchServe/Triton instead of custom worker
4. **Optimization**: Batching + caching + autoscaling
5. **Cost**: Preemptible GPUs + scale-to-zero during off-hours

**Timeline**: 4-6 weeks for production hardening + 2-3 weeks for model scaling migration

**ROI**:
- Security hardening: Avoids breach (avg cost: $4M)
- HA/reliability: 99.9% → 99.99% uptime (9x fewer outages)
- Autoscaling: 70% cost reduction vs. always-on
- Batching/caching: 10x throughput per GPU

---

**Author**: AlchemystAI DevOps Internship Submission
**Date**: May 23, 2026
