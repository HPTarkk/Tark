#!/usr/bin/env bash
# Checks that the Caddyfile serves the website and the guest app the way the
# previous host did (website/_headers, website/_redirects, clean addresses,
# the guest app's single-page fallback). Runs a real Caddy on a local port
# against the repository's own website/ folder and a stand-in guest build.
#
#   bash backend/deploy/vps/test-sites.sh          (needs caddy and curl)
#   CADDY=/path/to/caddy bash backend/deploy/vps/test-sites.sh
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../../.." && pwd)
caddy=${CADDY:-caddy}
port=${PORT:-18473}
command -v "$caddy" >/dev/null || { echo "caddy not found (set CADDY=/path/to/caddy)" >&2; exit 2; }

work=$(mktemp -d)
pid=
cleanup() { [ -n "$pid" ] && kill "$pid" 2>/dev/null || true; rm -rf "$work"; }
trap cleanup EXIT

mkdir -p "$work/sites/guest/assets"
ln -s "$repo/website" "$work/sites/website"
echo '<!doctype html><title>guest</title>' > "$work/sites/guest/index.html"
echo 'console.log(1)' > "$work/sites/guest/main.dart.js"

TARK_DOMAIN="http://api.localhost:$port" \
TARK_ADMIN_DOMAIN="http://admin.localhost:$port" \
TARK_SITE_ADDRESS="http://site.localhost:$port" \
TARK_GUEST_ADDRESS="http://guest.localhost:$port" \
TARK_SITES_ROOT="$work/sites" \
XDG_DATA_HOME="$work/data" XDG_CONFIG_HOME="$work/config" \
  "$caddy" run --config "$here/Caddyfile" --adapter caddyfile >"$work/caddy.log" 2>&1 &
pid=$!

site() { curl -sS -o "$work/body" -D "$work/head" -H "Host: site.localhost:$port" "$@"; }
guest() { curl -sS -o "$work/body" -D "$work/head" -H "Host: guest.localhost:$port" "$@"; }
base="http://127.0.0.1:$port"
for _ in $(seq 1 50); do site "$base/" 2>/dev/null && break; sleep 0.2; done

fails=0
ok() { echo "  ok   $1"; }
bad() { echo "  FAIL $1"; fails=$((fails + 1)); }
status() { head -n1 "$work/head" | tr -d '\r' | cut -d' ' -f2; }
header() { grep -i "^$1:" "$work/head" | tail -n1 | tr -d '\r' | cut -d' ' -f2-; }
expect_status() { [ "$(status)" = "$2" ] && ok "$1 -> $2" || bad "$1: status $(status), want $2"; }
expect_header() { [ "$(header "$2")" = "$3" ] && ok "$1: $2" || bad "$1: $2 is '$(header "$2")', want '$3'"; }
expect_same() { cmp -s "$work/body" "$2" && ok "$1 is $(basename "$2")" || bad "$1 is not $2"; }

echo "website"
site "$base/";                  expect_status / 200; expect_same / "$repo/website/index.html"
                                expect_header / Cache-Control "public, max-age=0, must-revalidate"
site "$base/fa/";               expect_status /fa/ 200; expect_same /fa/ "$repo/website/fa/index.html"
site "$base/fa";                expect_status /fa 308; expect_header /fa Location /fa/
site "$base/privacy";           expect_status /privacy 200; expect_same /privacy "$repo/website/privacy.html"
site "$base/fa/privacy";        expect_status /fa/privacy 200; expect_same /fa/privacy "$repo/website/fa/privacy.html"
site "$base/privacy.html";      expect_status /privacy.html 307; expect_header /privacy.html Location /privacy
site "$base/index.html";        expect_status /index.html 307; expect_header /index.html Location /
site "$base/fa/index.html";     expect_status /fa/index.html 307; expect_header /fa/index.html Location /fa/
site "$base/delete-account";    expect_status /delete-account 200
site "$base/no-such-page";      expect_status /no-such-page 404
site "$base/_headers";          expect_status /_headers 404
site "$base/_redirects";        expect_status /_redirects 404
site "$base/styles.css";        expect_status /styles.css 200; expect_header /styles.css Content-Type "text/css; charset=utf-8"

site "$base/update.json?v=1";   expect_status /update.json 200; expect_same /update.json "$repo/website/update.json"
                                expect_header /update.json Cache-Control "no-cache, no-store, must-revalidate"
                                expect_header /update.json Access-Control-Allow-Origin "*"
site "$base/announcements.json"; expect_status /announcements.json 200
                                expect_header /announcements.json Cache-Control "no-cache, no-store, must-revalidate"
                                expect_header /announcements.json Access-Control-Allow-Origin "*"
site "$base/site-version.json"; expect_header /site-version.json Cache-Control "no-cache, no-store, must-revalidate"
site "$base/.well-known/assetlinks.json"
                                expect_status assetlinks 200; expect_same assetlinks "$repo/website/.well-known/assetlinks.json"
                                expect_header assetlinks Content-Type application/json
                                expect_header assetlinks Access-Control-Allow-Origin "*"
                                expect_header assetlinks Cache-Control "public, max-age=3600"

for p in /v/register /v/reset /v/email /v/register/ /v/ ; do
  site "$base$p";               expect_status "$p" 200; expect_same "$p" "$repo/website/v/index.html"
                                expect_header "$p" X-Robots-Tag "noindex, nofollow"
                                expect_header "$p" Referrer-Policy no-referrer
                                expect_header "$p" Cache-Control no-cache
  case "$(header Content-Security-Policy)" in "default-src 'none';"*"frame-ancestors 'none'") ok "$p: Content-Security-Policy" ;; *) bad "$p: Content-Security-Policy is '$(header Content-Security-Policy)'" ;; esac
done

echo "guest app"
guest "$base/";                 expect_status / 200; expect_same / "$work/sites/guest/index.html"
                                expect_header / Cache-Control "public, max-age=0, must-revalidate"
guest "$base/main.dart.js";     expect_status /main.dart.js 200; expect_same /main.dart.js "$work/sites/guest/main.dart.js"
guest "$base/room/ABC123";      expect_status "/room/ABC123 (in-app route)" 200; expect_same /room/ABC123 "$work/sites/guest/index.html"

echo "the two sites stay apart"
site "$base/main.dart.js";      expect_status "website /main.dart.js" 404
curl -sS -o "$work/body" -D "$work/head" -H "Host: unknown.localhost:$port" "$base/" || true
[ ! -s "$work/body" ] && ok "an unknown host name gets no content" || bad "an unknown host name was served content"

if [ "$fails" -gt 0 ]; then echo; echo "$fails check(s) failed. Caddy's log:"; tail -n 20 "$work/caddy.log"; exit 1; fi
echo; echo "All checks passed."
