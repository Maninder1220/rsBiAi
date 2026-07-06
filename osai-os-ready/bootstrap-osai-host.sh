#!/usr/bin/env bash
set -Eeuo pipefail

APP_DIR="/opt/osai"
INSTALL_RUST="false"
INSTALL_SIGNOZ="false"
INSTALL_OTEL="true"
OPEN_LOCAL_FIREWALL="false"
ACTION="install"

log() { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }
warn() { printf '[WARN] %s\n' "$*" >&2; }
die() { printf '[ERROR] %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
OSAI host bootstrap for Ubuntu, Red Hat, and AlmaLinux.

Usage:
  sudo bash bootstrap-osai-host.sh install [options]
  sudo bash bootstrap-osai-host.sh status
  sudo bash bootstrap-osai-host.sh doctor

Options:
  --app-dir PATH          App base directory. Default: /opt/osai
  --with-rust            Install Rust using rustup for on-host builds.
  --with-signoz          Install SigNoz using Foundry if available.
  --without-otel         Do not create/start the local OpenTelemetry Collector.
  --open-local-firewall  Open local app ports on firewalld/ufw.
  -h, --help             Show help.

Default install prepares:
  - OS packages and developer tools
  - Docker Engine and Docker Compose v2
  - /opt/osai directory layout
  - .env template for OSAI services
  - optional local OTel Collector on 127.0.0.1:14317/14318

Default install does not:
  - download GGUF model files
  - expose SigNoz or model ports publicly
  - create cloud IAM, VM, NAT, or firewall resources
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    install|status|doctor)
      ACTION="$1"
      shift
      ;;
    --app-dir)
      APP_DIR="${2:?--app-dir requires a path}"
      shift 2
      ;;
    --with-rust)
      INSTALL_RUST="true"
      shift
      ;;
    --with-signoz)
      INSTALL_SIGNOZ="true"
      INSTALL_OTEL="true"
      shift
      ;;
    --without-otel)
      INSTALL_OTEL="false"
      shift
      ;;
    --open-local-firewall)
      OPEN_LOCAL_FIREWALL="true"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "Unknown argument: $1"
      ;;
  esac
done

require_root_for_install() {
  if [[ "$ACTION" == "install" && "${EUID}" -ne 0 ]]; then
    die "Run install with sudo/root."
  fi
}

detect_os() {
  [[ -r /etc/os-release ]] || die "/etc/os-release not found."
  # shellcheck disable=SC1091
  source /etc/os-release
  OS_ID="${ID,,}"
  OS_LIKE="${ID_LIKE:-}"
  OS_VERSION="${VERSION_ID:-unknown}"

  if [[ "$OS_ID" == "ubuntu" || "$OS_ID" == "debian" ]]; then
    OS_FAMILY="debian"
  elif [[ "$OS_ID" =~ ^(rhel|almalinux|rocky|centos|fedora)$ || "$OS_LIKE" =~ (rhel|fedora|centos) ]]; then
    OS_FAMILY="rhel"
  else
    die "Unsupported OS: ${PRETTY_NAME:-$OS_ID}. Supported: Ubuntu, Red Hat, AlmaLinux."
  fi
}

run() {
  log "+ $*"
  "$@"
}

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

has_systemd() {
  [[ -d /run/systemd/system ]] && command_exists systemctl
}

service_active() {
  local service_name="$1"
  if has_systemd; then
    systemctl is-active --quiet "$service_name"
  elif command_exists service; then
    service "$service_name" status >/dev/null 2>&1
  else
    return 1
  fi
}

install_base_packages_debian() {
  export DEBIAN_FRONTEND=noninteractive
  run apt-get update
  run apt-get install -y \
    ca-certificates curl gnupg lsb-release git unzip tar jq \
    build-essential pkg-config openssl libssl-dev \
    iproute2 procps lsof net-tools ufw
}

install_base_packages_rhel() {
  if command_exists dnf; then
    PKG="dnf"
  elif command_exists yum; then
    PKG="yum"
  else
    die "Neither dnf nor yum found."
  fi

  run "$PKG" -y install \
    ca-certificates curl git unzip tar jq \
    gcc gcc-c++ make pkgconf-pkg-config openssl-devel \
    iproute procps-ng lsof net-tools firewalld

  if has_systemd; then
    systemctl enable --now firewalld >/dev/null 2>&1 || true
  fi
}

install_docker_debian() {
  if command_exists docker && docker compose version >/dev/null 2>&1; then
    log "Docker and Compose v2 already installed."
  else
    install -m 0755 -d /etc/apt/keyrings
    if [[ ! -s /etc/apt/keyrings/docker.gpg ]]; then
      curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
      chmod a+r /etc/apt/keyrings/docker.gpg
    fi

    . /etc/os-release
    CODENAME="${VERSION_CODENAME:-$(lsb_release -cs)}"
    cat >/etc/apt/sources.list.d/docker.list <<EOF
deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu ${CODENAME} stable
EOF
    run apt-get update
    run apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  fi
  if has_systemd; then
    systemctl enable --now docker
  else
    service docker start || true
  fi
}

install_docker_rhel() {
  if command_exists docker && docker compose version >/dev/null 2>&1; then
    log "Docker and Compose v2 already installed."
  else
    if command_exists dnf; then
      PKG="dnf"
      run dnf -y install dnf-plugins-core || true
      run dnf config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
    else
      PKG="yum"
      run yum -y install yum-utils || true
      run yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
    fi
    run "$PKG" -y install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  fi
  if has_systemd; then
    systemctl enable --now docker
  else
    service docker start || true
  fi
}

create_osai_layout() {
  log "Creating OSAI directory layout in ${APP_DIR}"
  install -d -m 0755 \
    "${APP_DIR}" \
    "${APP_DIR}/app" \
    "${APP_DIR}/config" \
    "${APP_DIR}/data" \
    "${APP_DIR}/logs" \
    "${APP_DIR}/models" \
    "${APP_DIR}/otel" \
    "${APP_DIR}/signoz"

  if [[ ! -f "${APP_DIR}/config/osai.env" ]]; then
    cat >"${APP_DIR}/config/osai.env" <<'EOF'
# OSAI runtime endpoints.
OSAI_APP_BIND=127.0.0.1:8000
OSAI_POSTGRES_URL=postgres://postgres:postgres_admin_password@127.0.0.1:5432/osai
OSAI_OBJECT_ENDPOINT=http://127.0.0.1:9000
OSAI_OBJECT_ACCESS_KEY=rustfsadmin
OSAI_OBJECT_SECRET_KEY=rustfsadmin
OSAI_COGNEE_ENDPOINT=http://127.0.0.1:8001
OSAI_LLM_ENDPOINT=http://127.0.0.1:8080/v1

# OpenTelemetry. Send app telemetry to the local collector, not directly outside.
OTEL_SERVICE_NAME=osai-agent
OTEL_EXPORTER_OTLP_PROTOCOL=http/protobuf
OTEL_EXPORTER_OTLP_ENDPOINT=http://127.0.0.1:14318
EOF
    chmod 0640 "${APP_DIR}/config/osai.env"
  fi
}

write_otel_files() {
  [[ "$INSTALL_OTEL" == "true" ]] || return 0

  cat >"${APP_DIR}/otel/config.yaml" <<'EOF'
receivers:
  otlp:
    protocols:
      grpc:
        endpoint: 127.0.0.1:14317
      http:
        endpoint: 127.0.0.1:14318
  hostmetrics:
    root_path: /hostfs
    collection_interval: 30s
    scrapers:
      cpu: {}
      memory: {}
      disk: {}
      filesystem: {}
      load: {}
      network: {}

processors:
  batch: {}

exporters:
  otlp:
    endpoint: 127.0.0.1:4317
    tls:
      insecure: true
  debug:
    verbosity: basic

extensions:
  health_check:
    endpoint: 127.0.0.1:13133

service:
  extensions: [health_check]
  pipelines:
    traces:
      receivers: [otlp]
      processors: [batch]
      exporters: [otlp, debug]
    metrics:
      receivers: [otlp, hostmetrics]
      processors: [batch]
      exporters: [otlp, debug]
    logs:
      receivers: [otlp]
      processors: [batch]
      exporters: [otlp, debug]
EOF

  cat >"${APP_DIR}/otel/compose.yaml" <<'EOF'
services:
  otel-lite:
    image: otel/opentelemetry-collector-contrib:0.104.0
    container_name: osai-otel-lite
    network_mode: host
    command: ["--config=/etc/otelcol/config.yaml"]
    volumes:
      - ./config.yaml:/etc/otelcol/config.yaml:ro
      - /:/hostfs:ro
    restart: unless-stopped
EOF

  if has_systemd; then
    cat >/etc/systemd/system/osai-otel-lite.service <<EOF
[Unit]
Description=OSAI local OpenTelemetry Collector Lite
Requires=docker.service
After=docker.service network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=${APP_DIR}/otel
ExecStart=/usr/bin/docker compose -f ${APP_DIR}/otel/compose.yaml up -d
ExecStop=/usr/bin/docker compose -f ${APP_DIR}/otel/compose.yaml down
TimeoutStartSec=0

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable --now osai-otel-lite.service
  else
    docker compose -f "${APP_DIR}/otel/compose.yaml" up -d
  fi
}

install_rust() {
  [[ "$INSTALL_RUST" == "true" ]] || return 0
  if command_exists rustc && command_exists cargo; then
    log "Rust already installed: $(rustc --version)"
    return 0
  fi
  log "Installing Rust using rustup."
  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
  cat >/etc/profile.d/rustup.sh <<'EOF'
export PATH="$HOME/.cargo/bin:$PATH"
EOF
}

install_signoz() {
  [[ "$INSTALL_SIGNOZ" == "true" ]] || return 0
  log "Installing SigNoz with Foundry."
  cat >"${APP_DIR}/signoz/casting.yaml" <<'EOF'
apiVersion: v1alpha1
kind: Installation
metadata:
  name: signoz
spec:
  deployment:
    flavor: compose
    mode: docker
EOF

  if ! command_exists foundryctl; then
    curl -fsSL https://signoz.io/foundry.sh | bash
    if [[ -x /root/.foundry/bin/foundryctl ]]; then
      ln -sf /root/.foundry/bin/foundryctl /usr/local/bin/foundryctl
    fi
  fi

  export PATH="/usr/local/bin:/root/.foundry/bin:${PATH}"
  cd "${APP_DIR}/signoz"
  foundryctl gauge -f casting.yaml
  foundryctl cast -f casting.yaml
}

configure_firewall() {
  [[ "$OPEN_LOCAL_FIREWALL" == "true" ]] || {
    log "Firewall kept conservative. No app ports opened by this script."
    return 0
  }

  if command_exists firewall-cmd && service_active firewalld; then
    firewall-cmd --permanent --add-port=8000/tcp || true
    firewall-cmd --permanent --add-port=8080/tcp || true
    firewall-cmd --permanent --add-port=9000-9001/tcp || true
    firewall-cmd --permanent --add-port=8001/tcp || true
    firewall-cmd --reload || true
  elif command_exists ufw; then
    ufw allow 8000/tcp || true
    ufw allow 8080/tcp || true
    ufw allow 9000:9001/tcp || true
    ufw allow 8001/tcp || true
  else
    warn "No supported firewall tool found."
  fi
}

print_status_line() {
  local label="$1"
  shift
  if "$@" >/dev/null 2>&1; then
    printf 'OK   %s\n' "$label"
  else
    printf 'MISS %s\n' "$label"
  fi
}

status() {
  detect_os
  printf 'OS: %s %s (%s)\n' "${PRETTY_NAME:-$OS_ID}" "$OS_VERSION" "$OS_FAMILY"
  printf 'App dir: %s\n\n' "$APP_DIR"

  print_status_line "curl installed" command_exists curl
  print_status_line "git installed" command_exists git
  print_status_line "jq installed" command_exists jq
  print_status_line "Docker CLI installed" command_exists docker
  print_status_line "Docker service active" service_active docker
  print_status_line "Docker Compose v2 available" bash -c 'docker compose version'
  print_status_line "OSAI env exists" test -f "${APP_DIR}/config/osai.env"
  print_status_line "OSAI model directory exists" test -d "${APP_DIR}/models"
  print_status_line "Rust installed" command_exists rustc
  print_status_line "Cargo installed" command_exists cargo
  print_status_line "OTel compose exists" test -f "${APP_DIR}/otel/compose.yaml"
  print_status_line "OTel service active" service_active osai-otel-lite.service

  printf '\nListening ports of interest:\n'
  ss -lntp 2>/dev/null | grep -E ':(8000|8001|8080|9000|9001|4317|4318|14317|14318|13133)\b' || true

  printf '\nDocker containers of interest:\n'
  if command_exists docker; then
    docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}' 2>/dev/null | grep -E 'NAMES|osai|signoz|otel|postgres|rustfs|llama|cognee' || true
  fi
}

doctor() {
  status
  printf '\nSuggested next checks:\n'
  cat <<EOF
1. App health:
   curl -sf http://127.0.0.1:8000/api/health || true

2. llama.cpp health:
   curl -sf http://127.0.0.1:8080/health || true

3. Cognee docs/API:
   curl -I http://127.0.0.1:8001/docs || true

4. RustFS/S3 endpoint:
   curl -I http://127.0.0.1:9000 || true

5. OTel Collector health:
   curl -sf http://127.0.0.1:13133 || true

6. Logs:
   journalctl -u docker -u osai-otel-lite -n 120 --no-pager
   docker logs osai-otel-lite --tail 80
EOF
}

install_all() {
  require_root_for_install
  detect_os
  log "Detected ${PRETTY_NAME:-$OS_ID} (${OS_FAMILY})."

  if [[ "$OS_FAMILY" == "debian" ]]; then
    install_base_packages_debian
    install_docker_debian
  else
    install_base_packages_rhel
    install_docker_rhel
  fi

  create_osai_layout
  install_rust
  install_signoz
  write_otel_files
  configure_firewall

  log "Install phase finished."
  status
}

case "$ACTION" in
  install) install_all ;;
  status) status ;;
  doctor) doctor ;;
  *) die "Unknown action: $ACTION" ;;
esac
