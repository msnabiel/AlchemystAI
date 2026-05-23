output "api_gateway_public_ip" {
  description = "Public IP of API Gateway"
  value       = google_compute_instance.api_gateway.network_interface[0].access_config[0].nat_ip
}

output "api_gateway_private_ip" {
  description = "Private IP of API Gateway"
  value       = google_compute_instance.api_gateway.network_interface[0].network_ip
}

output "iii_engine_private_ip" {
  description = "Private IP of iii Engine"
  value       = google_compute_instance.iii_engine.network_interface[0].network_ip
}

output "math_worker_private_ip" {
  description = "Private IP of Math Worker"
  value       = google_compute_instance.math_worker.network_interface[0].network_ip
}

output "caller_worker_private_ip" {
  description = "Private IP of Caller Worker"
  value       = google_compute_instance.caller_worker.network_interface[0].network_ip
}

output "curl_command" {
  description = "Example curl command to test the API"
  value       = <<-EOT
    curl -X POST http://${google_compute_instance.api_gateway.network_interface[0].access_config[0].nat_ip}:8080/math/add \
      -H "Content-Type: application/json" \
      -d '{"a": 5, "b": 3}'
  EOT
}
