#!/usr/bin/env bash
# Runs ON THE SERVER as root. setup-server.ps1 uploads it and calls it over SSH;
# it can also be run by hand. It prepares a fresh Linux server for the stack
# that deploy.ps1 ships, and it is safe to run again: every step first looks at
# what is already there.
#
#   bash server-setup.sh check      look only: the machine, what it can reach, what is installed
#   bash server-setup.sh install    Docker Engine + Compose, the firewall ports, swap, then check
#   bash server-setup.sh lock-ssh   allow SSH logins with a key only (no passwords)
#
# Settings (environment variables; setup-server.ps1 has a parameter for each):
#   TARK_DOCKER_REPO_BASE   where Docker's packages come from
#                           (default https://download.docker.com; a mirror with
#                           the same layout works where that host is refused)
#   TARK_DOCKER_MIRRORS     comma-separated registry mirrors for image pulls,
#                           e.g. https://mirror.example.com (default: none)
#   TARK_SWAP_MB            size of the swap file made when the server has no
#                           swap at all (default 2048; 0 makes none)
#   TARK_SMTP_CHECK         extra host:port to test, e.g. mail.example.com:587
#
# Supported: AlmaLinux, Rocky, CentOS Stream, RHEL, Fedora (dnf) and Ubuntu,
# Debian (apt).
set -euo pipefail

DOCKER_REPO_BASE=${TARK_DOCKER_REPO_BASE:-https://download.docker.com}
DOCKER_REPO_BASE=${DOCKER_REPO_BASE%/}
DOCKER_MIRRORS=${TARK_DOCKER_MIRRORS:-}
SWAP_MB=${TARK_SWAP_MB:-2048}
SMTP_CHECK=${TARK_SMTP_CHECK:-}

die() { echo "ERROR: $1" >&2; exit "${2:-1}"; }
step() { echo; echo "==> $1"; }
ok() { echo "    ok    $1"; }
warn() { echo "    WARN  $1"; WARNINGS=$((WARNINGS + 1)); }
WARNINGS=0

OS_ID=unknown
OS_VERSION=
OS_CODENAME=
if [ -r /etc/os-release ]; then
  # shellcheck disable=SC1091
  . /etc/os-release
  OS_ID=${ID:-unknown}
  OS_VERSION=${VERSION_ID:-}
  OS_CODENAME=${VERSION_CODENAME:-}
fi

# Which of Docker's package folders fits this system.
docker_family() {
  case "$OS_ID" in
    almalinux|rocky|centos) echo centos ;;
    rhel) echo rhel ;;
    fedora) echo fedora ;;
    ubuntu) echo ubuntu ;;
    debian) echo debian ;;
    *) echo unsupported ;;
  esac
}

need_root() { [ "$(id -u)" = 0 ] || die "Run this as root."; }

# http_code URL: the status the server gets, or 000 when it cannot connect.
http_code() { curl -s -o /dev/null -w '%{http_code}' --max-time 15 "$1" 2>/dev/null || true; }

# reach NAME URL WHY: any HTTP answer below 500 other than 403 counts as
# reachable (these endpoints answer 200, 401 or 404 to a bare request; 403 is
# what a host that refuses this server's country returns).
reach() {
  local name=$1 url=$2 why=$3 code
  code=$(http_code "$url")
  case "$code" in
    000|'') warn "$name: no answer from $url ($why)" ;;
    403|5??) warn "$name: $url answered $code ($why)" ;;
    *) ok "$name ($code)" ;;
  esac
}

port_open() {
  local host=${1%:*} port=${1##*:}
  timeout 8 bash -c "exec 3<>/dev/tcp/$host/$port" 2>/dev/null
}

reach_port() {
  local name=$1 hostport=$2 why=$3
  if port_open "$hostport"; then ok "$name ($hostport)"; else warn "$name: cannot connect to $hostport ($why)"; fi
}

check() {
  step "The machine"
  echo "    system   ${PRETTY_NAME:-$OS_ID $OS_VERSION} ($(uname -m), kernel $(uname -r))"
  echo "    cpus     $(nproc)"
  echo "    memory   $(awk '/^MemTotal:/ { printf "%d MB", $2 / 1024 }' /proc/meminfo), swap $(awk '/^SwapTotal:/ { printf "%d MB", $2 / 1024 }' /proc/meminfo)"
  echo "    disk /   $(df -h / | awk 'NR == 2 { print $4 " free of " $2 }')"
  echo "    time     $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
  [ "$(docker_family)" != unsupported ] || warn "$OS_ID is not a system this script can install Docker on"
  local free_mb
  free_mb=$(df -Pm / | awk 'NR == 2 { print $4 }')
  [ "${free_mb:-0}" -ge 5000 ] || warn "less than 5 GB free on /"
  if command -v timedatectl >/dev/null; then
    # Sign-in tokens carry times: a wrong clock makes valid ones look expired.
    if [ "$(timedatectl show -p NTPSynchronized --value 2>/dev/null)" = yes ]; then ok "clock is synchronised"; else warn "clock is not synchronised (timedatectl)"; fi
  fi
  if command -v chage >/dev/null; then
    # An expired root password also locks out key logins on some systems.
    local expires
    expires=$(chage -l root 2>/dev/null | awk -F': ' '/^Password expires/ { print $2 }')
    echo "    root password expires: ${expires:-unknown}"
  fi

  step "What the server can reach"
  reach "Google sign-in keys" https://www.googleapis.com/oauth2/v3/certs "Google sign-in cannot be verified without it"
  reach "Let's Encrypt" https://acme-v02.api.letsencrypt.org/directory "Caddy gets the HTTPS certificates there"
  reach "Cafe Bazaar API" https://pardakht.cafebazaar.ir/ "purchases are verified there"
  reach "Docker packages" "$DOCKER_REPO_BASE/linux/static/stable/" "needed once, to install Docker; a mirror can be given"
  reach "Docker Hub" https://registry-1.docker.io/v2/ "the PostgreSQL and Caddy images are pulled from it; a mirror can be given"
  reach_port "Gmail SMTP" smtp.gmail.com:587 "only matters if mail is sent through Gmail"
  [ -z "$SMTP_CHECK" ] || reach_port "Mail server" "$SMTP_CHECK" "sign-up and reset emails go through it"

  step "SSH logins"
  if command -v sshd >/dev/null && [ "$(id -u)" = 0 ]; then
    if sshd -T 2>/dev/null | grep -qi '^passwordauthentication no'; then
      ok "passwords are refused; only keys can log in"
    else
      warn "SSH still accepts passwords (run: bash server-setup.sh lock-ssh)"
    fi
  fi

  step "Docker"
  if command -v docker >/dev/null; then
    ok "$(docker --version)"
    if docker compose version >/dev/null 2>&1; then ok "$(docker compose version)"; else warn "the Compose plugin is missing"; fi
    if docker info >/dev/null 2>&1; then ok "the Docker service is running"; else warn "the Docker service is not running"; fi
    if command -v systemctl >/dev/null && [ "$(systemctl is-enabled docker 2>/dev/null)" != enabled ]; then warn "Docker does not start at boot"; fi
  else
    warn "Docker is not installed (run: bash server-setup.sh install)"
  fi

  step "Firewall on the server"
  if command -v firewall-cmd >/dev/null && firewall-cmd --state >/dev/null 2>&1; then
    local services ports
    services=" $(firewall-cmd --list-services) "
    ports=" $(firewall-cmd --list-ports) "
    for want in http https; do
      case "$services" in *" $want "*) ok "firewalld allows $want" ;; *) warn "firewalld does not allow $want" ;; esac
    done
    case "$ports" in *" 443/udp "*) ok "firewalld allows 443/udp (HTTP/3)" ;; *) warn "firewalld does not allow 443/udp (HTTP/3; optional)" ;; esac
  elif command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q '^Status: active'; then
    local port
    for port in 80 443; do
      if ufw status | grep -qE "^($port|$port/tcp)\s"; then ok "ufw allows $port"; else warn "ufw does not allow $port"; fi
    done
  else
    echo "    no firewall is active on the server itself (the provider's panel may still have one)"
  fi

  step "Who listens on 80 and 443"
  if command -v ss >/dev/null; then
    local listeners
    listeners=$(ss -ltnpH 2>/dev/null | awk '$4 ~ /:(80|443)$/' || true)
    if [ -n "$listeners" ]; then printf '%s\n' "$listeners" | awk '{ print "    " $0 }'; else echo "    nothing yet"; fi
  fi

  # A kernel update only takes effect after a restart.
  if command -v rpm >/dev/null; then
    local newest
    newest=$(rpm -q kernel-core --last 2>/dev/null | awk 'NR == 1 { sub(/^kernel-core-/, "", $1); print $1 }')
    if [ -n "$newest" ] && [ "$newest" != "$(uname -r)" ]; then
      step "Restart"
      warn "a newer kernel is installed ($newest); it is used after the next restart (reboot)"
    fi
  elif [ -f /var/run/reboot-required ]; then
    step "Restart"
    warn "the system asks for a restart to finish its updates (reboot)"
  fi

  echo
  if [ "$WARNINGS" -eq 0 ]; then echo "Everything checked is fine."; else echo "$WARNINGS warning(s) above."; fi
}

install_docker_dnf() {
  local family=$1
  dnf -y install dnf-plugins-core ca-certificates curl >/dev/null
  # Written here instead of downloaded, so a mirror only has to hold the packages.
  cat > /etc/yum.repos.d/docker-ce.repo <<EOF
[docker-ce-stable]
name=Docker CE Stable
baseurl=$DOCKER_REPO_BASE/linux/$family/\$releasever/\$basearch/stable
enabled=1
gpgcheck=1
gpgkey=$DOCKER_REPO_BASE/linux/$family/gpg
EOF
  dnf -y install docker-ce docker-ce-cli containerd.io docker-compose-plugin
}

install_docker_apt() {
  local family=$1
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -qq ca-certificates curl >/dev/null
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL --max-time 30 "$DOCKER_REPO_BASE/linux/$family/gpg" -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] $DOCKER_REPO_BASE/linux/$family $OS_CODENAME stable" > /etc/apt/sources.list.d/docker.list
  apt-get update -qq
  apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-compose-plugin
}

install_docker() {
  step "Docker Engine and the Compose plugin"
  if command -v docker >/dev/null && docker compose version >/dev/null 2>&1; then
    ok "already installed: $(docker --version)"
  else
    local family
    family=$(docker_family)
    case "$family" in
      centos|rhel|fedora) install_docker_dnf "$family" ;;
      ubuntu|debian) install_docker_apt "$family" ;;
      *) die "$OS_ID is not a system this script can install Docker on. Install Docker Engine with the Compose plugin by hand, then run this again." ;;
    esac || die "Docker could not be installed from $DOCKER_REPO_BASE. If that host refuses this server, give a mirror with the same layout (setup-server.ps1 -DockerRepoBase, or TARK_DOCKER_REPO_BASE)."
    ok "installed: $(docker --version)"
  fi
}

# Registry mirrors and log limits. Only written when it would change something,
# and an existing daemon.json that this script did not write is left alone.
# The label is how this script knows the file is its own; Docker only accepts
# labels of the form key=value.
configure_docker() {
  step "Docker settings"
  local file=/etc/docker/daemon.json marker='tark-managed' mirrors_json='' m want
  if [ -n "$DOCKER_MIRRORS" ]; then
    IFS=',' read -r -a list <<< "$DOCKER_MIRRORS"
    for m in "${list[@]}"; do
      m=$(echo "$m" | tr -d '[:space:]')
      [ -n "$m" ] || continue
      case "$m" in https://*|http://*) ;; *) die "A registry mirror must start with https:// (got $m)." ;; esac
      mirrors_json="$mirrors_json${mirrors_json:+, }\"$m\""
    done
  fi
  want=$(cat <<EOF
{
  "labels": ["$marker=true"],
  "log-driver": "json-file",
  "log-opts": { "max-size": "10m", "max-file": "5" },
  "registry-mirrors": [$mirrors_json]
}
EOF
)
  mkdir -p /etc/docker
  if [ -f "$file" ] && ! grep -q "$marker" "$file"; then
    warn "$file exists and was not written by this script; leaving it alone"
  elif [ -f "$file" ] && [ "$(cat "$file")" = "$want" ]; then
    ok "$file is up to date"
  else
    echo "$want" > "$file"
    DOCKER_RESTART=1
    ok "wrote $file"
  fi
  systemctl enable docker >/dev/null 2>&1 || true
  if [ "${DOCKER_RESTART:-0}" = 1 ] && systemctl is-active --quiet docker; then
    # Containers of a running stack come back by themselves (restart: unless-stopped).
    systemctl restart docker
  else
    # Clears "start limit hit" left by earlier failed starts.
    systemctl reset-failed docker >/dev/null 2>&1 || true
    systemctl start docker
  fi
  docker info >/dev/null 2>&1 || die "The Docker service did not start (journalctl -u docker)."
  ok "the Docker service is running and starts at boot"
}

# Opens the web ports in a firewall that is already on. One that is off is
# left off: switching it on over SSH can lock the server out.
open_ports() {
  step "Firewall ports 80 and 443"
  if command -v firewall-cmd >/dev/null && firewall-cmd --state >/dev/null 2>&1; then
    firewall-cmd --quiet --permanent --add-service=http
    firewall-cmd --quiet --permanent --add-service=https
    firewall-cmd --quiet --permanent --add-port=443/udp
    firewall-cmd --quiet --reload
    ok "firewalld allows http, https and 443/udp"
  elif command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q '^Status: active'; then
    ufw allow 80/tcp >/dev/null
    ufw allow 443/tcp >/dev/null
    ufw allow 443/udp >/dev/null
    ok "ufw allows 80, 443 and 443/udp"
  else
    ok "no firewall is active on the server; nothing to open"
  fi
}

# A small server runs out of memory while Docker loads an image next to a
# running database. A swap file turns that into a slow minute instead of a
# killed process. Skipped when the server already has swap of any kind.
make_swap() {
  step "Swap"
  local total file=/swapfile
  total=$(awk '/^SwapTotal:/ { print $2 }' /proc/meminfo)
  if [ "${total:-0}" -gt 0 ]; then ok "already has $((total / 1024)) MB"; return 0; fi
  if [ "$SWAP_MB" = 0 ]; then ok "none, as asked"; return 0; fi
  if [ ! -f "$file" ]; then
    # dd, not fallocate: a file with holes cannot be swap on every filesystem.
    dd if=/dev/zero of="$file" bs=1M count="$SWAP_MB" status=none || { rm -f "$file"; warn "could not create $file; continuing without swap"; return 0; }
    chmod 600 "$file"
    mkswap "$file" >/dev/null
  fi
  if swapon "$file" 2>/dev/null; then
    grep -q "^$file " /etc/fstab || echo "$file none swap sw 0 0" >> /etc/fstab
    ok "made a $SWAP_MB MB swap file"
  else
    warn "could not switch $file on (some virtual servers forbid swap); continuing without it"
  fi
}

# Passwords are what attackers guess at all day; a key cannot be guessed.
# Refuses to run unless a key is in place, checks the configuration before
# applying it, and leaves the running session alone. If the key is ever lost,
# the provider's console in its panel still gets in.
lock_ssh() {
  step "SSH: keys only"
  local keys=/root/.ssh/authorized_keys dropin=/etc/ssh/sshd_config.d/00-tark-keys-only.conf
  grep -qE '^(ssh-|ecdsa-|sk-)' "$keys" 2>/dev/null || die "No key is installed for root yet ($keys). Install one first (setup-server.ps1 -InstallKey), or this would lock everyone out."
  sshd -T 2>/dev/null | grep -qi '^pubkeyauthentication yes' || die "This server does not accept key logins; not turning passwords off."
  grep -qE '^\s*Include\s+/etc/ssh/sshd_config\.d/' /etc/ssh/sshd_config || die "/etc/ssh/sshd_config does not read /etc/ssh/sshd_config.d; set PasswordAuthentication no there by hand."
  # The first file that sets an option wins, so the name starts with 00.
  {
    echo "# Written by server-setup.sh lock-ssh. Delete this file and reload sshd to undo."
    echo "PasswordAuthentication no"
    echo "KbdInteractiveAuthentication no"
    echo "PermitRootLogin prohibit-password"
  } > "$dropin"
  chmod 600 "$dropin"
  if ! sshd -t; then rm -f "$dropin"; die "sshd rejected the new settings; nothing was changed."; fi
  if ! sshd -T 2>/dev/null | grep -qi '^passwordauthentication no'; then
    rm -f "$dropin"; die "Another file in /etc/ssh/sshd_config.d switches passwords on first; nothing was changed. Look at: grep -ri passwordauthentication /etc/ssh/"
  fi
  systemctl reload sshd 2>/dev/null || systemctl reload ssh
  ok "SSH now accepts keys only (undo: rm $dropin && systemctl reload sshd)"
}

case "${1:-}" in
  lock-ssh)
    need_root
    lock_ssh
    ;;
  check)
    check
    ;;
  install)
    need_root
    install_docker
    configure_docker
    open_ports
    make_swap
    check
    ;;
  *)
    die "usage: server-setup.sh check | install | lock-ssh"
    ;;
esac
