# iii Engine VM
resource "google_compute_instance" "iii_engine" {
  name         = "iii-engine"
  machine_type = var.machine_type
  zone         = var.zone

  tags = ["iii-engine"]

  boot_disk {
    initialize_params {
      image = "debian-cloud/debian-12"
      size  = 20
    }
  }

  network_interface {
    subnetwork = google_compute_subnetwork.iii_private_subnet.id
    network_ip = "10.0.1.10"
  }

  metadata = {
    startup-script = file("${path.module}/../scripts/engine-startup.sh")
  }

  service_account {
    scopes = ["cloud-platform"]
  }

  metadata_startup_script = file("${path.module}/../scripts/engine-startup.sh")
}

# Math Worker VM (Python)
resource "google_compute_instance" "math_worker" {
  name         = "math-worker"
  machine_type = var.machine_type
  zone         = var.zone

  tags = ["iii-worker"]

  boot_disk {
    initialize_params {
      image = "debian-cloud/debian-12"
      size  = 20
    }
  }

  network_interface {
    subnetwork = google_compute_subnetwork.iii_private_subnet.id
    network_ip = "10.0.1.11"
  }

  metadata = {
    startup-script = file("${path.module}/../scripts/math-worker-startup.sh")
    engine-ip      = google_compute_instance.iii_engine.network_interface[0].network_ip
  }

  service_account {
    scopes = ["cloud-platform"]
  }

  depends_on = [google_compute_instance.iii_engine]
}

# Caller Worker VM (TypeScript)
resource "google_compute_instance" "caller_worker" {
  name         = "caller-worker"
  machine_type = var.machine_type
  zone         = var.zone

  tags = ["iii-worker"]

  boot_disk {
    initialize_params {
      image = "debian-cloud/debian-12"
      size  = 20
    }
  }

  network_interface {
    subnetwork = google_compute_subnetwork.iii_private_subnet.id
    network_ip = "10.0.1.12"
  }

  metadata = {
    startup-script = file("${path.module}/../scripts/caller-worker-startup.sh")
    engine-ip      = google_compute_instance.iii_engine.network_interface[0].network_ip
  }

  service_account {
    scopes = ["cloud-platform"]
  }

  depends_on = [google_compute_instance.iii_engine]
}

# API Gateway VM
resource "google_compute_instance" "api_gateway" {
  name         = "api-gateway"
  machine_type = var.machine_type
  zone         = var.zone

  tags = ["api-gateway"]

  boot_disk {
    initialize_params {
      image = "debian-cloud/debian-12"
      size  = 20
    }
  }

  network_interface {
    subnetwork = google_compute_subnetwork.iii_private_subnet.id
    network_ip = "10.0.1.2"

    access_config {
      # Ephemeral public IP
    }
  }

  metadata = {
    startup-script = file("${path.module}/../scripts/api-gateway-startup.sh")
    engine-ip      = google_compute_instance.iii_engine.network_interface[0].network_ip
  }

  service_account {
    scopes = ["cloud-platform"]
  }

  depends_on = [
    google_compute_instance.iii_engine,
    google_compute_instance.caller_worker
  ]
}
