#!/usr/bin/env bash
#
# AdGuard Home installer / uninstaller (from source)
# Detects distro, installs Go + Node + build deps, clones AdGuardHome,
# builds with make, installs it, and creates a systemd service.
#
# Usage:
#   bash adguard-install.sh            # install
#   bash adguard-install.sh uninstall  # remove service, files, and optionally packages
#

set -euo pipefail

START_TIME=$(date +%s)
REPO_URL="https://github.com/AdguardTeam/AdGuardHome.git"
DEFAULT_DIR="/opt/adguardhome"
BUILD_DIR="/tmp/adguard-src"
SERVICE_NAME="adguardhome"
DEFAULT_WEB_PORT=3000
MIN_GO="1.25"
MIN_NODE="24"

# ── helpers (logs to stderr) ───────────────────────────────────────────────
die() { echo -e "\n\033[1;31mError:\033[0m $*" >&2; exit 1; }
info() { echo -e "\033[1;34m==>\033[0m $*" >&2; }
ok() { echo -e "\033[1;32m==>\033[0m $*" >&2; }
warn() { echo -e "\033[1;33m==>\033[0m $*" >&2; }
prompt() { local var="$1" msg="$2" default="$3"; read -rp "$msg [$default]: " input; printf -v "$var" '%s' "${input:-$default}"; }
ask_yn() { local msg="$1" default="${2:-n}"; local ans; read -rp "$msg [y/N]: " ans; ans="${ans:-$default}"; [[ "$ans" =~ ^[Yy] ]]; }

elapsed() {
  local end=$(date +%s)
  local secs=$((end - START_TIME))
  printf '%dm %ds' $((secs/60)) $((secs%60))
}

ver_ge() {
  # returns 0 if $1 >= $2
  printf '%s\n%s\n' "$2" "$1" | sort -V -C
}

# True for loopback / unset addresses that must never be an upstream.
is_loopback() {
  local ip="$1"
  [[ -z "$ip" || "$ip" == 127.* || "$ip" == "::1" || "$ip" == "0.0.0.0" || "$ip" == "::" || "$ip" == "127.0.0.53" ]]
}

# Detect a real upstream DNS. Never returns loopback.
# On a re-run the previous install may have pointed the system at 127.0.0.1;
# that is ignored so AdGuard is not told to query itself.
detect_router_dns() {
  local dns="" ip
  # 1) resolvectl
  if command -v resolvectl >/dev/null 2>&1; then
    while read -r ip; do
      if ! is_loopback "$ip"; then dns="$ip"; break; fi
    done < <(resolvectl dns 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' || true)
  fi
  # 2) resolv.conf
  if [[ -z "$dns" && -f /etc/resolv.conf ]]; then
    while read -r ip; do
      if ! is_loopback "$ip"; then dns="$ip"; break; fi
    done < <(awk '/^nameserver/ {print $2}' /etc/resolv.conf)
  fi
  # 3) default gateway
  if [[ -z "$dns" ]]; then
    ip=$(ip route show default 2>/dev/null | awk '/default/ {print $3; exit}' || true)
    if ! is_loopback "$ip"; then dns="$ip"; fi
  fi
  printf '%s' "$dns"
}

# ── distro detection ───────────────────────────────────────────────────────
detect_distro() {
  if [[ -f /etc/os-release ]]; then
    . /etc/os-release
    ID="${ID:-}"
    ID_LIKE="${ID_LIKE:-}"
  else
    die "Cannot detect distro (/etc/os-release missing)."
  fi

  case "$ID" in
    debian|ubuntu|linuxmint|pop|elementary|zorin) PKG="apt" ;;
    fedora|rhel|rocky|almalinux|centos|ol)         PKG="dnf" ;;
    arch|manjaro|endeavouros|garuda)               PKG="pacman" ;;
    opensuse*|sles)                                PKG="zypper" ;;
    alpine)                                        PKG="apk" ;;
    *)
      case "$ID_LIKE" in
        *debian*|*ubuntu*) PKG="apt" ;;
        *rhel*|*fedora*)   PKG="dnf" ;;
        *arch*)            PKG="pacman" ;;
        *suse*)            PKG="zypper" ;;
        *) die "Unsupported distro: $ID (ID_LIKE=$ID_LIKE). Supported: Debian/Ubuntu, Fedora/RHEL, Arch, openSUSE, Alpine." ;;
      esac
      ;;
  esac
  info "Detected: $ID ($PKG)"
}

# ── latest release check ───────────────────────────────────────────────────
check_latest() {
  info "Checking for latest release..."
  local api="https://api.github.com/repos/AdguardTeam/AdGuardHome/releases/latest"
  AGH_LATEST=$(curl -fsSL "$api" 2>/dev/null | grep -oE '"tag_name":[[:space:]]*"[^"]+"' | head -1 | cut -d'"' -f4 || true)
  if [[ -n "${AGH_LATEST:-}" ]]; then
    ok "Latest AdGuard Home: $AGH_LATEST"
  else
    warn "Could not query releases (will use master)"
    AGH_LATEST=""
  fi
  echo
}

# ── packages ───────────────────────────────────────────────────────────────
install_packages() {
  info "Installing build dependencies..."

  case "$PKG" in
    apt)
      sudo apt-get update -qq
      sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
        git make curl ca-certificates tar gcc g++ pkg-config nodejs npm golang
      ;;
    dnf)
      sudo dnf install -y \
        git make curl ca-certificates tar gcc gcc-c++ pkgconf-pkg-config nodejs npm golang
      ;;
    pacman)
      sudo pacman -Sy --noconfirm \
        git make curl ca-certificates tar gcc pkgconf nodejs npm go
      ;;
    zypper)
      sudo zypper --non-interactive install \
        git make curl ca-certificates tar gcc gcc-c++ pkg-config nodejs npm go
      ;;
    apk)
      sudo apk add --no-cache \
        git make curl ca-certificates tar gcc g++ pkgconf nodejs npm go
      ;;
  esac

  ok "Build packages ready."
}

ensure_go() {
  if command -v go >/dev/null 2>&1; then
    local ver
    ver=$(go version | grep -oE 'go[0-9]+\.[0-9]+' | sed 's/go//')
    if ver_ge "$ver" "$MIN_GO"; then
      ok "Go $ver is new enough"
      return 0
    fi
    warn "Go $ver is older than $MIN_GO — installing official tarball"
  else
    warn "Go not found — installing official tarball"
  fi

  local tarball="/tmp/go.tar.gz"
  local url="https://go.dev/dl/go1.25.3.linux-amd64.tar.gz"
  info "Downloading $url"
  curl -fsSL -o "$tarball" "$url" || die "Failed to download Go tarball"
  sudo rm -rf /usr/local/go
  sudo tar -C /usr/local -xzf "$tarball"
  rm -f "$tarball"
  export PATH="/usr/local/go/bin:$PATH"
  ok "Installed $(go version)"
}

ensure_node() {
  if command -v node >/dev/null 2>&1; then
    local ver
    ver=$(node -v | sed 's/v//' | cut -d. -f1)
    if [[ "$ver" -ge "$MIN_NODE" ]]; then
      ok "Node $(node -v) is new enough"
      return 0
    fi
    warn "Node $(node -v) is older than v$MIN_NODE"
  else
    warn "Node not found"
  fi

  info "Installing Node $MIN_NODE from NodeSource..."
  case "$PKG" in
    apt)
      curl -fsSL "https://deb.nodesource.com/setup_${MIN_NODE}.x" | sudo -E bash -
      sudo DEBIAN_FRONTEND=noninteractive apt-get install -y nodejs
      ;;
    dnf)
      curl -fsSL "https://rpm.nodesource.com/setup_${MIN_NODE}.x" | sudo bash -
      sudo dnf install -y nodejs
      ;;
    *)
      warn "Automatic Node upgrade not supported for $PKG. Install Node $MIN_NODE+ manually if the build fails."
      ;;
  esac

  if command -v node >/dev/null 2>&1; then
    ok "Node is now $(node -v)"
  fi
}

# ── build ──────────────────────────────────────────────────────────────────
build_adguard() {
  info "Cloning AdGuard Home..."
  rm -rf "$BUILD_DIR"
  # Full clone of the default branch so origin/master exists.
  # The Makefile's version.sh runs 'git rev-list origin/master..HEAD'
  # and fails on a shallow or tag-only clone.
  git clone "$REPO_URL" "$BUILD_DIR"
  cd "$BUILD_DIR"

  # Ensure origin/master exists for the version script
  git fetch origin master:refs/remotes/origin/master 2>/dev/null || true
  if ! git rev-parse --verify origin/master >/dev/null 2>&1; then
    # fallback: point origin/master at HEAD
    git update-ref refs/remotes/origin/master HEAD
  fi

  # Optional: check out the latest release tag if it exists and master is present
  if [[ -n "${AGH_LATEST:-}" ]]; then
    if git rev-parse --verify "refs/tags/$AGH_LATEST" >/dev/null 2>&1; then
      info "Checking out $AGH_LATEST (origin/master kept for build)"
      git checkout "$AGH_LATEST"
      # re-point origin/master so version.sh doesn't fail on detached HEAD
      git update-ref refs/remotes/origin/master HEAD
    fi
  fi

  git config advice.detachedHead false || true

  # make sure go is on PATH
  if [[ -d /usr/local/go/bin ]]; then
    export PATH="/usr/local/go/bin:$PATH"
  fi

  info "Building with make — this can take several minutes..."
  make
  [[ -x "$BUILD_DIR/AdGuardHome" ]] || die "Build finished but binary not found."
  info "Build complete."
}

# ── install ────────────────────────────────────────────────────────────────
install_files() {
  info "Installing to $INSTALL_DIR ..."
  sudo mkdir -p "$INSTALL_DIR"
  # Fedora SELinux blocks binaries in /opt. Put the binary in /usr/local/bin.
  sudo cp "$BUILD_DIR/AdGuardHome" /usr/local/bin/AdGuardHome
  sudo chmod +x /usr/local/bin/AdGuardHome
  if command -v getenforce >/dev/null 2>&1 && [[ "$(getenforce 2>/dev/null)" != "Disabled" ]]; then
    info "SELinux is enforcing — setting bin_t context"
    sudo chcon -t bin_t /usr/local/bin/AdGuardHome || true
  fi
  sudo chown -R "$USER:$USER" "$INSTALL_DIR" 2>/dev/null || true
  ok "Files installed."
}

free_port_53() {
  # systemd-resolved often holds 127.0.0.53:53 and makes AdGuard exit
  if systemctl is-active --quiet systemd-resolved 2>/dev/null; then
    info "systemd-resolved is active — disabling its DNS stub so AdGuard can bind port 53"
    sudo mkdir -p /etc/systemd/resolved.conf.d
    sudo tee /etc/systemd/resolved.conf.d/adguardhome.conf >/dev/null <<'RES'
[Resolve]
DNS=127.0.0.1
DNSStubListener=no
RES
    sudo systemctl restart systemd-resolved || true
    # point resolv.conf at the real resolved file if it's a stub
    if [[ -L /etc/resolv.conf ]] && [[ "$(readlink /etc/resolv.conf)" == *stub* ]]; then
      sudo ln -sf /run/systemd/resolve/resolv.conf /etc/resolv.conf || true
    fi
    ok "Port 53 freed."
  fi
}

write_config() {
  if [[ "${ENABLE_BLOCKING:-false}" != "true" ]]; then
    info "Skipping ad-blocking config (setup wizard will run on first visit)."
    return 0
  fi

  info "Writing config with AdGuard DNS filter enabled..."
  sudo tee "$INSTALL_DIR/AdGuardHome.yaml" >/dev/null <<YAML
http:
  pprof:
    port: 6060
    enabled: false
  address: 0.0.0.0:${WEB_PORT}
  session_ttl: 720h
users: []
auth_attempts: 5
block_auth_min: 15
http_proxy: ""
language: ""
theme: auto
dns:
  bind_hosts:
    - 0.0.0.0
  port: 53
  anonymize_client_ip: false
  ratelimit: 20
  ratelimit_subnet_len_ipv4: 24
  ratelimit_subnet_len_ipv6: 56
  ratelimit_whitelist: []
  refuse_any: true
  upstream_dns:
    - ${UPSTREAM_DNS:-https://dns10.quad9.net/dns-query}
    - https://dns.cloudflare.com/dns-query
  upstream_dns_file: ""
  bootstrap_dns:
    - 9.9.9.10
    - 149.112.112.10
    - 2620:fe::10
    - 2620:fe::fe:10
  fallback_dns: []
  all_servers: false
  fastest_addr: false
  fastest_timeout: 1s
  allowed_clients: []
  disallowed_clients: []
  blocked_hosts:
    - version.bind
    - id.server
    - hostname.bind
  trusted_proxies:
    - 127.0.0.0/8
    - ::1/128
  cache_size: 4194304
  cache_ttl_min: 0
  cache_ttl_max: 0
  cache_optimistic: false
  bogus_nxdomain: []
  aaaa_disabled: false
  enable_dnssec: false
  edns_client_subnet:
    custom_ip: ""
    enabled: false
    use_custom: false
  max_goroutines: 300
  handle_ddr: true
  ipset: []
  ipset_file: ""
  bootstrap_prefer_ipv6: false
  upstream_timeout: 10s
  private_networks: []
  use_private_ptr_resolvers: true
  local_ptr_upstreams: []
  use_dns64: false
  dns64_prefixes: []
  serve_http3: false
  use_http3_upstreams: false
  serve_plain_dns: true
  hostsfile_enabled: true
tls:
  enabled: false
  server_name: ""
  force_https: false
  port_https: 443
  port_dns_over_tls: 853
  port_dns_over_quic: 853
  port_dnscrypt: 0
  dnscrypt_config_file: ""
  allow_unencrypted_doh: false
  certificate_chain: ""
  private_key: ""
  certificate_path: ""
  private_key_path: ""
  strict_sni_check: false
querylog:
  dir_path: ""
  ignored: []
  interval: 2160h
  size_memory: 1000
  enabled: true
  file_enabled: true
statistics:
  dir_path: ""
  ignored: []
  interval: 24h
  enabled: true
filters:
  - enabled: true
    url: https://adguardteam.github.io/HostlistsRegistry/assets/filter_1.txt
    name: AdGuard DNS filter
    id: 1
whitelist_filters: []
user_rules:
  - "||ads.trafficjunky.net^"
  - "||pornhub.com^"
  - "||doubleclick.net^"
  - "||trafficjunky.net^"
dhcp:
  enabled: false
filtering:
  blocking_ipv4: ""
  blocking_ipv6: ""
  blocked_services:
    schedule:
      time_zone: Local
    ids: []
  protection_disabled_until: null
  safe_search:
    enabled: false
    bing: true
    duckduckgo: true
    ecosia: true
    google: true
    pixabay: true
    yandex: true
    youtube: true
  blocking_mode: default
  parental_block_host: family-block.dns.adguard.com
  safebrowsing_block_host: standard-block.dns.adguard.com
  rewrites: []
  safe_fs_patterns:
    - /opt/adguardhome/userfilters/*
  safebrowsing_cache_size: 1048576
  safesearch_cache_size: 1048576
  parental_cache_size: 1048576
  cache_time: 30
  filters_update_interval: 24
  blocked_response_ttl: 10
  filtering_enabled: true
  parental_enabled: false
  safebrowsing_enabled: false
  protection_enabled: true
clients:
  runtime_sources:
    whois: true
    arp: true
    rdns: true
    dhcp: true
    hosts: true
  persistent: []
log:
  enabled: true
  file: ""
  max_backups: 0
  max_size: 100
  max_age: 3
  compress: false
  local_time: false
  verbose: false
os:
  group: ""
  user: ""
  rlimit_nofile: 0
schema_version: 28
YAML
  sudo chown "$USER:$USER" "$INSTALL_DIR/AdGuardHome.yaml"
  ok "Config written. Ad blocking is enabled with the AdGuard DNS filter."
}

create_service() {
  free_port_53
  local bin="/usr/local/bin/AdGuardHome"
  [[ -x "$bin" ]] || die "AdGuardHome binary not found at $bin"

  if command -v systemctl >/dev/null 2>&1; then
    info "Creating systemd service..."
    sudo tee "/etc/systemd/system/${SERVICE_NAME}.service" >/dev/null <<UNIT
[Unit]
Description=AdGuard Home
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=$INSTALL_DIR
ExecStart=$bin -w $INSTALL_DIR --no-check-update
Restart=on-failure
RestartSec=5
AmbientCapabilities=CAP_NET_BIND_SERVICE

[Install]
WantedBy=multi-user.target
UNIT
    sudo systemctl daemon-reload
    sudo systemctl enable --now "$SERVICE_NAME"
    ok "systemd service enabled and started."

    # open firewall if firewalld is running
    if systemctl is-active --quiet firewalld 2>/dev/null; then
      info "Opening firewall ports 3000/tcp and 53/udp+tcp..."
      sudo firewall-cmd --permanent --add-port=${WEB_PORT}/tcp || true
      sudo firewall-cmd --permanent --add-port=53/tcp || true
      sudo firewall-cmd --permanent --add-port=53/udp || true
      sudo firewall-cmd --reload || true
      ok "Firewall updated."
    fi

    # verify it is actually listening
    sleep 2
    if ss -tlnp 2>/dev/null | grep -q ":${WEB_PORT} "; then
      ok "Web UI is listening on port ${WEB_PORT}"
    else
      warn "Web UI is not listening on port ${WEB_PORT}."
      warn "Last log lines:"
      sudo journalctl -u "$SERVICE_NAME" -n 20 --no-pager || true
    fi
  else
    warn "No systemd detected. Start manually with: $bin -w $INSTALL_DIR"
  fi
}

# ── uninstall ──────────────────────────────────────────────────────────────
remove_service() {
  info "Removing service..."
  if command -v systemctl >/dev/null 2>&1; then
    sudo systemctl stop "$SERVICE_NAME" 2>/dev/null || true
    sudo systemctl disable "$SERVICE_NAME" 2>/dev/null || true
    sudo rm -f "/etc/systemd/system/${SERVICE_NAME}.service"
    sudo systemctl daemon-reload
    ok "systemd service removed."
  fi
}

remove_files() {
  local dir="${1:-$DEFAULT_DIR}"
  sudo rm -f /usr/local/bin/AdGuardHome
  if [[ -d "$dir" ]]; then
    if ask_yn "Remove install directory $dir (includes config and query log)?"; then
      sudo rm -rf "$dir"
      ok "Directory removed."
    else
      info "Kept $dir"
    fi
  else
    warn "Install directory $dir not found."
  fi
}

remove_build_dir() {
  if [[ -d "$BUILD_DIR" ]]; then
    if ask_yn "Remove build directory $BUILD_DIR?"; then
      rm -rf "$BUILD_DIR"
      ok "Build directory removed."
    fi
  fi
}

remove_packages() {
  if ask_yn "Also remove Go tarball install (/usr/local/go)?"; then
    sudo rm -rf /usr/local/go
    ok "Go removed."
  fi
  if ask_yn "Also remove build packages (gcc, nodejs, etc.)? (may affect other software)"; then
    info "Removing packages..."
    case "$PKG" in
      apt)    sudo apt-get remove -y gcc g++ pkg-config nodejs npm golang || true ;;
      dnf)    sudo dnf remove -y gcc gcc-c++ pkgconf-pkg-config nodejs npm golang || true ;;
      pacman) sudo pacman -Rns --noconfirm gcc pkgconf nodejs npm go || true ;;
      zypper) sudo zypper --non-interactive remove gcc gcc-c++ pkg-config nodejs npm go || true ;;
      apk)    sudo apk del gcc g++ pkgconf nodejs npm go || true ;;
    esac
    ok "Package removal finished."
  else
    info "Packages kept."
  fi
}

uninstall() {
  echo "AdGuard Home uninstaller"
  echo "========================"
  detect_distro
  remove_service

  echo
  prompt INSTALL_DIR "Install directory to remove" "$DEFAULT_DIR"
  remove_files "$INSTALL_DIR"
  remove_build_dir
  remove_packages

  echo
  ok "Uninstall finished in $(elapsed)"
}

# ── main ───────────────────────────────────────────────────────────────────
main() {
  local mode="${1:-install}"

  case "$mode" in
    uninstall|remove|--uninstall|-u)
      uninstall
      ;;
    install|"")
      echo "AdGuard Home installer (from source)"
      echo "===================================="
      detect_distro
      check_latest
      install_packages
      ensure_go
      ensure_node

      echo
      prompt INSTALL_DIR "Install directory" "$DEFAULT_DIR"
      prompt WEB_PORT "Web UI port" "$DEFAULT_WEB_PORT"

      if ask_yn "Enable ad blocking now with the AdGuard DNS filter?" "y"; then
        ENABLE_BLOCKING="true"
      else
        ENABLE_BLOCKING="false"
      fi

      [[ "$WEB_PORT" =~ ^[0-9]+$ ]] || die "Port must be a number."

      # detect current router DNS for upstream (optional)
      DETECTED_DNS=$(detect_router_dns)
      UPSTREAM_DNS=""
      if is_loopback "$DETECTED_DNS"; then
        DETECTED_DNS=""
      fi
      if [[ -n "$DETECTED_DNS" ]]; then
        if ask_yn "Use detected router DNS ($DETECTED_DNS) as AdGuard upstream? (or set it later in the UI)"; then
          UPSTREAM_DNS="$DETECTED_DNS"
          ok "Will use $UPSTREAM_DNS as upstream"
        else
          info "Skipping — you can set upstream DNS later in the UI"
        fi
      else
        warn "No real upstream DNS detected (127.0.0.1 is ignored)."
        if ask_yn "Use 1.1.1.1 as upstream instead? (or set it later in the UI)"; then
          UPSTREAM_DNS="1.1.1.1"
          ok "Will use 1.1.1.1 as upstream"
        else
          info "Skipping — you can set upstream DNS later in the UI"
        fi
      fi

      build_adguard
      install_files
      write_config
      create_service

      local ip
      ip=$(hostname -I 2>/dev/null | awk '{print $1}') || ip="localhost"

      echo
      ok "Done in $(elapsed)"
      echo
      echo "  Open:  http://${ip:-localhost}:${WEB_PORT}"
      echo "  Files: $INSTALL_DIR"
      echo
      # flush local DNS cache so tests aren't served from old answers
      info "Flushing local DNS cache..."
      if command -v resolvectl >/dev/null 2>&1; then
        sudo resolvectl flush-caches 2>/dev/null || true
      fi
      if command -v nscd >/dev/null 2>&1; then
        sudo nscd -i hosts 2>/dev/null || true
      fi
      ok "DNS cache flushed."

      if [[ "${ENABLE_BLOCKING:-false}" == "true" ]]; then
        echo "Ad blocking is enabled with the AdGuard DNS filter."
        if [[ -n "${UPSTREAM_DNS:-}" ]]; then
          echo "Upstream DNS set to detected router DNS: $UPSTREAM_DNS"
        fi
        echo "Set your device or router DNS to ${ip:-localhost} to use it."
        echo
        # prove blocking with a direct DNS query
        echo "Proof check (querying AdGuard directly):"
        # Domains known to be in the AdGuard DNS filter.
        # doubleclick.net is not always blocked; these are.
        local domains=("ads.trafficjunky.net" "pornhub.com" "doubleclick.net")
        local domain result blocked=0 checked=0
        if ! command -v dig >/dev/null 2>&1 && ! command -v nslookup >/dev/null 2>&1; then
          warn "dig/nslookup not found — install bind-utils or dnsutils for the proof check"
        else
          for domain in "${domains[@]}"; do
            checked=$((checked+1))
            result=""
            if command -v dig >/dev/null 2>&1; then
              result=$(dig +short @127.0.0.1 "$domain" 2>/dev/null | head -1 || true)
            else
              result=$(nslookup "$domain" 127.0.0.1 2>/dev/null | awk '/^Address: / && !/127\.0\.0\.1/ {print $2; exit}' || true)
            fi
            echo "  $domain -> ${result:-<empty>}"
            if [[ -z "$result" || "$result" == "0.0.0.0" || "$result" == "::" ]]; then
              ok "BLOCKED — $domain"
              blocked=$((blocked+1))
            else
              warn "NOT BLOCKED — $domain resolved to $result"
            fi
          done
          echo
          if [[ "$blocked" -gt 0 ]]; then
            ok "Proof: $blocked of $checked test domains blocked"
          else
            warn "Proof failed: none of the test domains were blocked"
            warn "Check that this machine is using AdGuard (127.0.0.1) as its DNS."
          fi
        fi
        echo
        echo "Browser test (clear the page cache first, or use a private window):"
        echo "  https://d3ward.github.io/toolz/adblock.html"
        echo "  A high score means blocking is working."
        echo
        echo "Also check the Query Log in the UI for blocked requests."
      else
        echo "First visit runs the setup wizard."
      fi
      echo "DNS listens on port 53 — make sure nothing else is using it."
      echo
      echo "Service commands:"
      if command -v systemctl >/dev/null 2>&1; then
        echo "  sudo systemctl status $SERVICE_NAME"
        echo "  sudo systemctl restart $SERVICE_NAME"
      fi
      echo
      echo "To uninstall later: bash $0 uninstall"
      ;;
    *)
      die "Unknown option: $mode. Use: $0 [install|uninstall]"
      ;;
  esac
}

main "$@"
