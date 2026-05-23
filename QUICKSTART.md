# Quick Start Guide

If you want to **test locally first** before deploying to GCP, follow these steps.

## Local Testing (Optional)

### 1. Start the iii Engine
```bash
cd quickstart
export PATH="$HOME/.local/bin:$PATH"

# Start engine in background
iii engine start --host 0.0.0.0 --port 49134 &
```

### 2. Start Math Worker (Terminal 1)
```bash
cd quickstart/workers/math-worker
python3 -m venv venv
source venv/bin/activate
pip install -r requirements.txt

export III_URL="ws://localhost:49134"
python math_worker.py
```

### 3. Start Caller Worker (Terminal 2)
```bash
cd quickstart/workers/caller-worker
npm install

export III_URL="ws://localhost:49134"
npx tsx src/worker.ts
```

### 4. Test RPC Manually
```bash
# In a new terminal
export PATH="$HOME/.local/bin:$PATH"

# Trigger the caller worker function
iii rpc math::add_two_numbers '{"a": 5, "b": 3}'
```

**Expected output**:
```json
{
  "c": 8,
  "success": "You've connected two workers and they're interoperating seamlessly..."
}
```

---

## GCP Deployment (Production-like)

### Prerequisites Checklist
- [ ] GCP account created ([sign up](https://cloud.google.com/free))
- [ ] `gcloud` CLI installed ([install guide](https://cloud.google.com/sdk/docs/install))
- [ ] `terraform` installed ([download](https://developer.hashicorp.com/terraform/downloads))
- [ ] GCP project created (note the project ID)

### One-Command Deploy
```bash
./deploy.sh your-gcp-project-id
```

### Manual Deployment Steps

If you prefer to run each step manually:

#### 1. Authenticate
```bash
gcloud auth login
gcloud config set project YOUR_PROJECT_ID
gcloud auth application-default login
```

#### 2. Enable APIs
```bash
gcloud services enable compute.googleapis.com
gcloud services enable cloudresourcemanager.googleapis.com
```

#### 3. Initialize Terraform
```bash
cd terraform
terraform init
```

#### 4. Plan Deployment
```bash
terraform plan -var="project_id=YOUR_PROJECT_ID" -out=tfplan
```

Review the plan to see what will be created:
- 1 VPC network
- 1 subnet (10.0.1.0/24)
- 1 Cloud NAT + router
- 4 firewall rules
- 4 VM instances

#### 5. Apply Deployment
```bash
terraform apply tfplan
```

**Wait 5-7 minutes** for infrastructure creation and VM initialization.

#### 6. Get API Gateway IP
```bash
terraform output api_gateway_public_ip
```

#### 7. Test the API

**Wait an additional 2-3 minutes** for all services to start inside VMs, then:

```bash
API_IP=$(terraform output -raw api_gateway_public_ip)

curl -X POST http://$API_IP:8080/math/add \
  -H "Content-Type: application/json" \
  -d '{"a": 42, "b": 8}'
```

**Expected response**:
```json
{
  "c": 50,
  "success": "Workers are interoperating across VMs via RPC through the iii engine"
}
```

**If you get a connection error**: Services may still be starting. Wait 1-2 more minutes and retry.

---

## Debugging

### Check VM Status
```bash
gcloud compute instances list --filter="name~'iii-|math-|caller-|api-'"
```

All VMs should show `RUNNING` status.

### SSH into VMs
```bash
# iii engine
gcloud compute ssh iii-engine --zone=us-central1-a --tunnel-through-iap

# Inside VM, check service status
sudo systemctl status iii-engine.service
sudo journalctl -u iii-engine.service -f
```

### Check API Gateway Logs
```bash
gcloud compute ssh api-gateway --zone=us-central1-a --tunnel-through-iap

# Check service
sudo systemctl status api-gateway.service

# View logs
sudo journalctl -u api-gateway.service -n 50

# Check if it's listening
sudo netstat -tlnp | grep 8080
```

### Check Worker Connectivity
```bash
gcloud compute ssh math-worker --zone=us-central1-a --tunnel-through-iap

# Check service
sudo systemctl status math-worker.service

# Test connectivity to engine
ping 10.0.1.10

# Check if worker connected
sudo journalctl -u math-worker.service | grep "started"
```

### Common Issues

**Issue**: `curl: (7) Failed to connect to <IP>:8080`
- **Solution**: Wait longer (services take 3-5 min to start), or check firewall rule `allow-api-http`

**Issue**: API returns 500 error
- **Solution**: Check that all workers connected to engine. SSH into engine and check logs.

**Issue**: Cannot SSH into VM
- **Solution**: Use `--tunnel-through-iap` flag. Ensure firewall rule `allow-ssh-iap` exists.

**Issue**: VM stuck in provisioning
- **Solution**: Check startup script logs: `cat /var/log/startup.log`

---

## Teardown

### One-Command Destroy
```bash
./destroy.sh your-gcp-project-id
```

### Manual Teardown
```bash
cd terraform
terraform destroy -var="project_id=YOUR_PROJECT_ID"
```

Type `yes` when prompted.

**Verifies everything is deleted**:
```bash
gcloud compute instances list
gcloud compute networks list
```

---

## Cost Estimate

**Free Tier**:
- New GCP accounts get $300 in credits
- This deployment uses ~$25/month
- **Result**: Free for 12 months

**After Free Tier**:
- 4x e2-medium VMs: $24/month
- Networking: <$1/month
- **Total**: ~$25/month

**How to minimize costs**:
- Stop VMs when not in use: `gcloud compute instances stop --all`
- Use preemptible VMs (70% cheaper, but can be interrupted)
- Destroy infrastructure when done testing

---

## Next Steps

After successful deployment:

1. **Read** `ARCHITECTURE.md` - Understand the design
2. **Read** `PRODUCTION_HARDENING.md` - Learn what's needed for production
3. **Experiment**:
   - Modify the math operation in `math_worker.py`
   - Add a new worker
   - Add authentication to the API
   - Enable HTTPS with Let's Encrypt
4. **Extend**:
   - Add a second API endpoint (e.g., `/math/multiply`)
   - Integrate a real ML model (replace math operation)
   - Add monitoring dashboards

---

## Resources

- **iii Documentation**: https://iii.dev/docs/quickstart
- **GCP Compute Engine**: https://cloud.google.com/compute/docs
- **Terraform GCP Provider**: https://registry.terraform.io/providers/hashicorp/google/latest/docs
- **Cloud NAT**: https://cloud.google.com/nat/docs
- **Identity-Aware Proxy**: https://cloud.google.com/iap/docs
