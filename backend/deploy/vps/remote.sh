#!/usr/bin/env bash
# Runs ON THE SERVER, inside the deployment directory. deploy.ps1 uploads it and
# calls it over SSH; you can also run it by hand:
#
#   bash remote.sh init  <image>    first time: create .env.production with generated secrets
#   bash remote.sh up    <image>    start or update the stack with <image>
#   bash remote.sh rollback         go back to the previous image
#   bash remote.sh status           show containers and recent API logs
set -euo pipefail
cd "$(dirname "$0")"

ENV_FILE=.env.production
COMPOSE=(docker compose --env-file "$ENV_FILE" -f docker-compose.prod.yml)

die() { echo "ERROR: $1" >&2; exit "${2:-1}"; }

# set_kv KEY VALUE: replace or append KEY=VALUE in the env file (values are
# written literally; awk is used instead of sed so / + = in a value are safe).
set_kv() {
  local key=$1 value=$2
  if grep -q "^${key}=" "$ENV_FILE"; then
    awk -v k="$key" -v v="$value" 'BEGIN { FS = OFS = "=" } $1 == k { print k "=" v; next } { print }' "$ENV_FILE" > "$ENV_FILE.tmp"
    mv "$ENV_FILE.tmp" "$ENV_FILE"
  else
    echo "${key}=${value}" >> "$ENV_FILE"
  fi
  chmod 600 "$ENV_FILE"
}

# fill_from_example KEY: take a public value (not a secret) from the example
# when the env file still has a placeholder, so a server set up before the value
# was known picks it up on its next deploy. A value someone set is kept.
fill_from_example() {
  local key=$1 example current
  example=$(grep -E "^${key}=" .env.production.example | head -n1 | cut -d= -f2- || true)
  current=$(grep -E "^${key}=" "$ENV_FILE" | head -n1 | cut -d= -f2- || true)
  case "$example" in ''|*CHANGE_ME*) return 0 ;; esac
  case "$current" in ''|*CHANGE_ME*) set_kv "$key" "$example"; echo "Set $key from .env.production.example." ;; esac
}

current_image() { grep -E '^TARK_IMAGE=' "$ENV_FILE" | head -n1 | cut -d= -f2-; }

need_docker() {
  command -v docker >/dev/null || die "Docker is not installed on this server. Install Docker Engine with the Compose plugin first: https://docs.docker.com/engine/install/"
  docker compose version >/dev/null 2>&1 || die "The Docker Compose plugin is missing (docker compose version failed)."
}

wait_healthy() {
  local cid status
  for _ in $(seq 1 60); do
    cid=$("${COMPOSE[@]}" ps -q api || true)
    if [ -n "$cid" ]; then
      status=$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$cid" 2>/dev/null || echo unknown)
      [ "$status" = healthy ] && return 0
    fi
    sleep 2
  done
  echo "The API did not become healthy within 2 minutes. Last log lines:" >&2
  "${COMPOSE[@]}" logs --tail 40 api >&2 || true
  return 1
}

cmd=${1:-}
case "$cmd" in
  init)
    image=${2:?usage: remote.sh init <image>}
    need_docker
    if [ -f "$ENV_FILE" ]; then echo "$ENV_FILE already exists; leaving it alone."; exit 0; fi
    umask 077
    cp .env.production.example "$ENV_FILE"
    keys=$(docker run --rm "$image" keygen)
    while IFS= read -r line; do
      case "$line" in TARK_*=*) set_kv "${line%%=*}" "${line#*=}" ;; esac
    done <<< "$keys"
    set_kv POSTGRES_PASSWORD "$(head -c 48 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 32)"
    echo
    echo "Created $PWD/$ENV_FILE with fresh secrets."
    echo "Public entitlement key for the app build (safe to publish):"
    echo "$keys" | grep '"TARK_ENTITLEMENT_KEYS"' || true
    echo
    echo "Now edit the CHANGE_ME values (domain, SMTP, Bazaar), then deploy again without -Init."
    ;;
  up)
    image=${2:?usage: remote.sh up <image>}
    need_docker
    [ -f "$ENV_FILE" ] || die "$ENV_FILE is missing. Run the first deploy with -Init." 2
    fill_from_example TARK_GOOGLE_CLIENT_IDS
    if grep -n 'CHANGE_ME' "$ENV_FILE" >&2; then die "Fill in the CHANGE_ME values above in $ENV_FILE first." 3; fi
    prev=$(current_image || true)
    if [ -n "$prev" ] && [ "$prev" != "$image" ]; then echo "$prev" >> .deploy-history; fi
    set_kv TARK_IMAGE "$image"
    "${COMPOSE[@]}" up -d --remove-orphans
    wait_healthy || die "Deploy of $image failed. 'bash remote.sh rollback' returns to the previous image." 4
    echo "Deployed $image and it is healthy."
    ;;
  rollback)
    need_docker
    [ -s .deploy-history ] || die "No previous image is recorded."
    prev=$(tail -n1 .deploy-history)
    sed -i '$d' .deploy-history
    echo "Rolling back from $(current_image) to $prev"
    set_kv TARK_IMAGE "$prev"
    "${COMPOSE[@]}" up -d --remove-orphans
    wait_healthy || die "The previous image did not become healthy either." 4
    echo "Rolled back to $prev. Database migrations are not undone, so check that the older image works with the current schema."
    ;;
  status)
    need_docker
    "${COMPOSE[@]}" ps
    "${COMPOSE[@]}" logs --tail 20 api
    ;;
  *)
    die "usage: remote.sh init <image> | up <image> | rollback | status"
    ;;
esac
