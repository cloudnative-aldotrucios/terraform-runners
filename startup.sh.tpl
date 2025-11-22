#!/bin/bash
set -euxo pipefail

GITHUB_URL="${github_url}"
RUNNER_VERSION="${runner_version}"
RUNNER_LABELS="${runner_labels}"
GITHUB_TOKEN="${github_token}"

apt-get update -y
apt-get install -y curl tar

useradd -m -d /home/github-runner -s /bin/bash github-runner || true

sudo -u github-runner bash -lc "
  mkdir -p ~/actions-runner
  cd ~/actions-runner

  curl -Ls -o actions-runner.tar.gz \
    \"https://github.com/actions/runner/releases/download/v${runner_version}/actions-runner-linux-x64-${runner_version}.tar.gz\"

  tar xzf actions-runner.tar.gz

  ./config.sh --unattended \
    --url \"${GITHUB_URL}\" \
    --token \"${GITHUB_TOKEN}\" \
    --labels \"${RUNNER_LABELS}\" \
    --name \"gcp-\$(hostname)\" \
    --work \"_work\"

  ./svc.sh install
  ./svc.sh start
"
