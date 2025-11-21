variable "project_id" {
  description = "ID del proyecto de GCP"
  type        = string
}

variable "region" {
  description = "Región en la que se crea la red"
  type        = string
  default     = "us-central1"
}

variable "zone" {
  description = "Zona de la VM"
  type        = string
  default     = "us-central1-a"
}

variable "network_cidr" {
  description = "CIDR de la subnet"
  type        = string
  default     = "10.10.0.0/24"
}

variable "runner_machine_type" {
  description = "Tipo de máquina para el runner"
  type        = string
  default     = "e2-medium"
}

variable "github_url" {
  description = "URL de la org o repo donde se registrará el runner"
  type        = string
}

variable "github_token" {
  description = "Registration token de GitHub (caduca rápido)"
  type        = string
  sensitive   = true
}

variable "runner_labels" {
  description = "Etiquetas del runner"
  type        = string
  default     = "gcp,self-hosted"
}

variable "runner_version" {
  description = "Versión del GitHub Actions runner"
  type        = string
  default     = "2.329.0"
}
