terraform {
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
  zone    = var.zone
}

# ---------------------------
# Networking
# ---------------------------

resource "google_compute_network" "runner_vpc" {
  name                    = "github-runner-vpc"
  auto_create_subnetworks = false
}

resource "google_compute_subnetwork" "runner_subnet" {
  name                     = "github-runner-subnet"
  ip_cidr_range            = var.vpc_cidr
  region                   = var.region
  network                  = google_compute_network.runner_vpc.id
  private_ip_google_access = true
}

# ---------------------------
# Service Accounts
# ---------------------------

resource "google_service_account" "proxy_sa" {
  account_id   = "github-proxy-sa"
  display_name = "Service account para proxy Squid"
}

resource "google_service_account" "runner_sa" {
  account_id   = "github-runner-sa"
  display_name = "Service account para GitHub runner"
}

# ---------------------------
# Ubuntu GCP Image
# ---------------------------

data "google_compute_image" "ubuntu" {
  family  = "ubuntu-2404-lts-amd64"
  project = "ubuntu-os-cloud"
}

# ---------------------------
# Squid Proxy
# ---------------------------

resource "google_compute_instance" "proxy" {
  name         = "github-proxy"
  machine_type = var.proxy_machine_type
  zone         = var.zone

  tags = ["github-proxy"]

  boot_disk {
    initialize_params {
      image = data.google_compute_image.ubuntu.self_link
      size  = 20
      type  = "pd-balanced"
    }
  }

  network_interface {
    subnetwork = google_compute_subnetwork.runner_subnet.id
    access_config {}
  }

  service_account {
    email  = google_service_account.proxy_sa.email
    scopes = [
      "https://www.googleapis.com/auth/logging.write",
      "https://www.googleapis.com/auth/monitoring.write"
    ]
  }

  metadata_startup_script = <<EOF
#!/bin/bash
set -eux

apt-get update -y
apt-get install -y squid

cat << 'EOT' > /etc/squid/squid.conf
http_port 3128

acl localnet src ${var.vpc_cidr}

acl github_domains dstdomain \
    github.com \
    .github.com \
    .githubusercontent.com \
    .actions.githubusercontent.com \
    ghcr.io \
    api.github.com \
    objects.githubusercontent.com \
    pkg-containers.githubusercontent.com

http_access allow localnet github_domains
http_access deny all

access_log stdio:/var/log/squid/access.log
cache_log stdio:/var/log/squid/cache.log
EOT

systemctl restart squid
systemctl enable squid
EOF
}

# ---------------------------
# GitHub Actions Runner VM
# ---------------------------

resource "google_compute_instance" "runner" {
  name         = "github-actions-runner"
  machine_type = var.runner_machine_type
  zone         = var.zone

  tags = ["github-runner"]

  boot_disk {
    initialize_params {
      image = data.google_compute_image.ubuntu.self_link
      size  = 50
      type  = "pd-balanced"
    }
  }

  network_interface {
    subnetwork = google_compute_subnetwork.runner_subnet.id
  }

  service_account {
    email  = google_service_account.runner_sa.email
    scopes = [
      "https://www.googleapis.com/auth/logging.write",
      "https://www.googleapis.com/auth/monitoring.write"
    ]
  }

  metadata_startup_script = <<EOF
#!/bin/bash
set -eux

RUNNER_VERSION="${var.runner_version}"
GITHUB_URL="${var.github_repo_url}"
RUNNER_TOKEN="${var.github_registration_token}"
RUNNER_LABELS="${var.runner_labels}"
PROXY_IP="${google_compute_instance.proxy.network_interface.0.network_ip}"
PROXY_PORT="3128"

echo "HTTP_PROXY=http://$PROXY_IP:$PROXY_PORT" >> /etc/environment
echo "HTTPS_PROXY=http://$PROXY_IP:$PROXY_PORT" >> /etc/environment
echo "NO_PROXY=169.254.169.254,metadata.google.internal,localhost,127.0.0.1" >> /etc/environment

export HTTP_PROXY=http://$PROXY_IP:$PROXY_PORT
export HTTPS_PROXY=http://$PROXY_IP:$PROXY_PORT
export NO_PROXY=169.254.169.254,metadata.google.internal,localhost,127.0.0.1

apt-get update -y
apt-get install -y curl tar

id runner || useradd -m -s /bin/bash runner

mkdir -p /opt/actions-runner
chown runner:runner /opt/actions-runner
cd /opt/actions-runner

sudo -u runner bash <<EOT
curl -o actions-runner.tar.gz -L https://github.com/actions/runner/releases/download/v$RUNNER_VERSION/actions-runner-linux-x64-$RUNNER_VERSION.tar.gz
tar xzf actions-runner.tar.gz

./config.sh --unattended \
  --url "$GITHUB_URL" \
  --token "$GITHUB_TOKEN" \
  --labels "$RUNNER_LABELS" \
  --name "gcp-$(hostname)" \
  --work "_work"
EOT

./svc.sh install
./svc.sh start
EOF
}

# ---------------------------
# Firewall Rules
# ---------------------------

# Runner → Proxy (3128)
resource "google_compute_firewall" "runner_to_proxy" {
  name      = "runner-to-proxy"
  network   = google_compute_network.runner_vpc.id
  direction = "EGRESS"

  allow {
    protocol = "tcp"
    ports    = ["3128"]
  }

  destination_ranges = [
    google_compute_instance.proxy.network_interface.0.network_ip
  ]

  target_tags = ["github-runner"]
}

# Deny all other egress from runner
resource "google_compute_firewall" "runner_deny_egress" {
  name      = "runner-deny-egress"
  network   = google_compute_network.runner_vpc.id
  direction = "EGRESS"
  priority  = 2000

  deny {
    protocol = "all"
  }

  destination_ranges = ["0.0.0.0/0"]
  target_tags        = ["github-runner"]
}

# IAP SSH → runner
resource "google_compute_firewall" "iap_runner_ssh" {
  name      = "iap-runner-ssh"
  network   = google_compute_network.runner_vpc.id
  direction = "INGRESS"

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }

  source_ranges = ["35.235.240.0/20"]
  target_tags   = ["github-runner"]
}

# IAP SSH → proxy
resource "google_compute_firewall" "iap_proxy_ssh" {
  name      = "iap-proxy-ssh"
  network   = google_compute_network.runner_vpc.id
  direction = "INGRESS"

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }

  source_ranges = ["35.235.240.0/20"]
  target_tags   = ["github-proxy"]
}

# Proxy to Internet (80/443)
resource "google_compute_firewall" "proxy_to_internet" {
  name      = "proxy-egress-internet"
  network   = google_compute_network.runner_vpc.id
  direction = "EGRESS"

  allow {
    protocol = "tcp"
    ports    = ["80", "443"]
  }

  destination_ranges = ["0.0.0.0/0"]
  target_tags        = ["github-proxy"]
}