#!/bin/bash
set -e

# GCP teardown script for iii quickstart distributed system
# Usage: ./destroy.sh <project-id>

if [ -z "$1" ]; then
  echo "Error: GCP Project ID required"
  echo "Usage: ./destroy.sh <project-id>"
  exit 1
fi

PROJECT_ID=$1

echo "========================================="
echo "Destroying iii quickstart infrastructure"
echo "Project ID: $PROJECT_ID"
echo "========================================="

# Warning
echo ""
echo "WARNING: This will destroy all infrastructure created by Terraform."
read -p "Are you sure you want to continue? (yes/no): " confirm
if [ "$confirm" != "yes" ]; then
  echo "Destruction cancelled"
  exit 0
fi

# Set project
gcloud config set project $PROJECT_ID

# Destroy with Terraform
echo ""
echo "Destroying infrastructure..."
cd terraform
terraform destroy -var="project_id=$PROJECT_ID"

echo ""
echo "========================================="
echo "Infrastructure destroyed successfully"
echo "========================================="
