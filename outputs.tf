output "runner_internal_ip" {
  description = "IP interna del runner"
  value       = google_compute_instance.runner.network_interface[0].network_ip
}
