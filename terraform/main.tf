terraform {
  required_version = ">= 1.0"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.0"
    }
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
}

# VPC Network
resource "google_compute_network" "iii_vpc" {
  name                    = "iii-vpc"
  auto_create_subnetworks = false
  description             = "VPC for iii quickstart distributed deployment"
}

# Private Subnet
resource "google_compute_subnetwork" "iii_private_subnet" {
  name          = "iii-private-subnet"
  ip_cidr_range = var.subnet_cidr
  region        = var.region
  network       = google_compute_network.iii_vpc.id
  description   = "Private subnet for worker VMs"
}

# Cloud Router for NAT
resource "google_compute_router" "nat_router" {
  name    = "iii-nat-router"
  region  = var.region
  network = google_compute_network.iii_vpc.id
}

# Cloud NAT for internet access from private VMs
resource "google_compute_router_nat" "nat" {
  name                               = "iii-nat"
  router                             = google_compute_router.nat_router.name
  region                             = var.region
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"

  log_config {
    enable = true
    filter = "ERRORS_ONLY"
  }
}

# Firewall: Allow HTTP traffic to API gateway
resource "google_compute_firewall" "allow_api_http" {
  name    = "allow-api-http"
  network = google_compute_network.iii_vpc.name

  allow {
    protocol = "tcp"
    ports    = ["8080"]
  }

  source_ranges = ["0.0.0.0/0"]
  target_tags   = ["api-gateway"]
  description   = "Allow HTTP traffic on port 8080 to API gateway"
}

# Firewall: Allow internal WebSocket traffic to engine
resource "google_compute_firewall" "allow_engine_internal" {
  name    = "allow-engine-internal"
  network = google_compute_network.iii_vpc.name

  allow {
    protocol = "tcp"
    ports    = ["49134"]
  }

  source_ranges = [var.subnet_cidr]
  target_tags   = ["iii-engine"]
  description   = "Allow WebSocket traffic on port 49134 to iii engine from private subnet"
}

# Firewall: Allow SSH via Identity-Aware Proxy
resource "google_compute_firewall" "allow_ssh_iap" {
  name    = "allow-ssh-iap"
  network = google_compute_network.iii_vpc.name

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }

  source_ranges = ["35.235.240.0/20"]
  description   = "Allow SSH via IAP for debugging"
}

# Firewall: Allow internal communication between VMs
resource "google_compute_firewall" "allow_internal" {
  name    = "allow-internal"
  network = google_compute_network.iii_vpc.name

  allow {
    protocol = "tcp"
  }

  allow {
    protocol = "udp"
  }

  allow {
    protocol = "icmp"
  }

  source_ranges = [var.subnet_cidr]
  description   = "Allow all internal traffic within subnet"
}
