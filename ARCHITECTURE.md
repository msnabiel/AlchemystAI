# Architecture Design

## Overview
Multi-VM deployment of iii quickstart project with workers distributed across private subnet VMs, coordinated via RPC through central engine, exposed via HTTP JSON API.

## Component Layout

```
                    Internet
                       |
                       v
                [API Gateway VM]  (public IP: 0.0.0.0/0 → :8080)
                       |
                       | (private subnet 10.0.1.0/24)
                       |
      +----------------+------------------+
      |                |                  |
      v                v                  v
[iii-engine VM]  [math-worker VM]  [caller-worker VM]
10.0.1.10        10.0.1.11          10.0.1.12
:49134           (connects to       (connects to
                  engine WS)         engine WS)
```

## VMs and Roles

| VM Name           | Private IP | Public IP | Services                          | Firewall Rules                    |
|-------------------|------------|-----------|-----------------------------------|-----------------------------------|
| `api-gateway`     | 10.0.1.2   | Yes       | HTTP API server (port 8080)       | Allow 0.0.0.0/0:8080 ingress      |
| `iii-engine`      | 10.0.1.10  | No        | iii engine WebSocket (port 49134) | Allow 10.0.1.0/24:49134 ingress   |
| `math-worker`     | 10.0.1.11  | No        | Python worker (connects to engine)| Allow egress to engine            |
| `caller-worker`   | 10.0.1.12  | No        | TypeScript worker (connects)      | Allow egress to engine            |

## RPC Flow

1. **HTTP Request** → API Gateway (`:8080/math/add` with `{"a": 5, "b": 3}`)
2. **API Gateway** → Triggers `math::add_two_numbers` on engine via WS
3. **Engine** → Routes to `caller-worker` VM
4. **caller-worker** → Calls `math::add` via engine
5. **Engine** → Routes to `math-worker` VM
6. **math-worker** → Returns `{"c": 8}` via engine
7. **caller-worker** → Receives result, returns via engine
8. **API Gateway** → Receives final result, returns HTTP JSON response

## Network Design

- **VPC**: `iii-vpc` (10.0.0.0/16)
- **Subnet**: `iii-private-subnet` (10.0.1.0/24) - us-central1
- **Firewall Rules**:
  - `allow-api-http`: 0.0.0.0/0 → api-gateway:8080 (TCP)
  - `allow-engine-internal`: 10.0.1.0/24 → iii-engine:49134 (TCP)
  - `allow-egress`: All VMs can reach internet for package installs (via Cloud NAT)
  - `allow-ssh-iap`: Allow SSH via IAP for debugging (35.235.240.0/20)

## Cloud NAT
Private VMs need internet access for:
- Installing packages (`apt`, `npm install`, `pip install`)
- Pulling Docker images (if containerized)

Cloud NAT router attached to subnet enables egress-only internet access.

## API Schema

### Request
```bash
curl -X POST http://<API_GATEWAY_IP>:8080/math/add \
  -H "Content-Type: application/json" \
  -d '{"a": 5, "b": 3}'
```

### Response
```json
{
  "c": 8,
  "success": "You've connected two workers and they're interoperating seamlessly..."
}
```

## Deployment Strategy

1. **Terraform** provisions VPC, subnet, firewall rules, VMs with startup scripts
2. **Startup scripts** install dependencies, clone worker code, configure systemd services
3. **systemd units** manage iii engine and worker processes
4. **API Gateway** runs Node.js HTTP server that bridges HTTP → iii engine WebSocket

## Production Hardening Needed

- **TLS/HTTPS** on API gateway (Let's Encrypt + nginx reverse proxy)
- **Authentication** on API (JWT, API keys, OAuth)
- **Rate limiting** on API endpoint
- **Secrets management** (GCP Secret Manager for any credentials)
- **Monitoring** (Cloud Monitoring, Logging, Alerting)
- **Auto-scaling** (MIG for workers if load increases)
- **Health checks** (HTTP health endpoint, automatic VM replacement)
- **Network security** (VPC Service Controls, private Google Access)
- **Container orchestration** (GKE instead of raw VMs for easier scaling)

## Scaling for 100x Larger Model

If model requires GPU and significant resources:

- **GPU VMs** (e.g., `n1-standard-8` + NVIDIA T4/V100/A100)
- **Model serving frameworks** (TensorFlow Serving, TorchServe, Triton)
- **Horizontal scaling** with load balancer distributing to worker pool
- **Model parallelism** (split model across multiple GPUs/VMs)
- **Batch inference** (queue requests, process in batches)
- **Caching layer** (Redis for frequent queries)
- **Async processing** (Cloud Tasks/Pub/Sub for long-running jobs)
- **Autoscaling** based on queue depth or GPU utilization
- **Cost optimization** (preemptible VMs for batch workloads, spot instances)
