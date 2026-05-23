#!/bin/bash
set -e

# GCP deployment script for iii quickstart distributed system
# Usage: ./deploy.sh <project-id>

if [ -z "$1" ]; then
  echo "Error: GCP Project ID required"
  echo "Usage: ./deploy.sh <project-id>"
  exit 1
fi

PROJECT_ID=$1

echo "========================================="
echo "Deploying iii quickstart to GCP"
echo "Project ID: $PROJECT_ID"
echo "========================================="

# Check for required tools
command -v terraform >/dev/null 2>&1 || { echo "Error: terraform not installed"; exit 1; }
command -v gcloud >/dev/null 2>&1 || { echo "Error: gcloud CLI not installed"; exit 1; }

# Authenticate with GCP
echo ""
echo "Step 1: Authenticating with GCP..."
gcloud auth login
gcloud config set project $PROJECT_ID

# Enable required APIs
echo ""
echo "Step 2: Enabling required GCP APIs..."
gcloud services enable compute.googleapis.com
gcloud services enable cloudresourcemanager.googleapis.com

# Get application default credentials for Terraform
echo ""
echo "Step 3: Setting up application default credentials..."
gcloud auth application-default login

# Initialize Terraform
echo ""
echo "Step 4: Initializing Terraform..."
cd terraform
terraform init

# Plan deployment
echo ""
echo "Step 5: Planning Terraform deployment..."
terraform plan -var="project_id=$PROJECT_ID" -out=tfplan

# Apply deployment
echo ""
echo "Step 6: Deploying infrastructure..."
read -p "Proceed with deployment? (yes/no): " confirm
if [ "$confirm" != "yes" ]; then
  echo "Deployment cancelled"
  exit 0
fi

terraform apply tfplan

# Get outputs
echo ""
echo "========================================="
echo "Deployment complete!"
echo "========================================="
terraform output

echo ""
echo "Waiting 60 seconds for VMs to initialize..."
sleep 60

# Test the API
API_IP=$(terraform output -raw api_gateway_public_ip)
echo ""
echo "Testing API endpoint..."
echo "Running: curl -X POST http://$API_IP:8080/math/add -H 'Content-Type: application/json' -d '{\"a\": 5, \"b\": 3}'"
echo ""

curl -X POST "http://$API_IP:8080/math/add" \
  -H "Content-Type: application/json" \
  -d '{"a": 5, "b": 3}' \
  -w "\n" || echo "Note: API may still be starting up. Wait a few more minutes and try again."

echo ""
echo "========================================="
echo "Deployment complete!"
echo "API Gateway IP: $API_IP"
echo ""
echo "Test command:"
echo "curl -X POST http://$API_IP:8080/math/add -H 'Content-Type: application/json' -d '{\"a\": 5, \"b\": 3}'"
echo "========================================="
