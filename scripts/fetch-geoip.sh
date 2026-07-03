#!/usr/bin/env bash
#
# fetch-geoip.sh — download the free DB-IP Lite ASN + Country databases so
# surveyor can name who owns each remote (V1 S1 identity).
#
#   ./scripts/fetch-geoip.sh              fetch into ~/.local/share/cartograph/geoip/
#   ./scripts/fetch-geoip.sh <dir>        fetch into <dir> (pass the same dir via --geoip)
#
# DB-IP Lite is CC-BY 4.0, no account needed (that's why it is the default over
# MaxMind GeoLite2, which wants a signup). Attribution — this product includes
# IP geolocation data by DB-IP (https://db-ip.com). Data lives OUTSIDE the repo:
# licensing + size + privacy (STATE.md posture — never commit it).

set -euo pipefail

DEST="${1:-${XDG_DATA_HOME:-$HOME/.local/share}/cartograph/geoip}"
mkdir -p "$DEST"

bold=$'\e[1m'; green=$'\e[32m'; dim=$'\e[2m'; red=$'\e[31m'; rst=$'\e[0m'

# DB-IP publishes month-stamped files on the 1st; if this month's isn't up yet
# (or the clock is ahead), fall back to last month's.
this_month="$(date +%Y-%m)"
last_month="$(date -d "$(date +%Y-%m-01) -1 day" +%Y-%m)"

fetch() { # fetch <kind> <outfile>   kind: asn | country
    local kind="$1" out="$2" month url
    for month in "$this_month" "$last_month"; do
        url="https://download.db-ip.com/free/dbip-${kind}-lite-${month}.mmdb.gz"
        echo "${dim}→ $url${rst}"
        if curl -fsSL "$url" -o "$out.gz.tmp"; then
            gunzip -c "$out.gz.tmp" > "$out.tmp"
            rm -f "$out.gz.tmp"
            mv "$out.tmp" "$out"
            echo "${green}✓${rst} $out ($(du -h "$out" | cut -f1))"
            return 0
        fi
    done
    echo "${red}✗ could not fetch dbip-${kind}-lite (this and last month)${rst}" >&2
    return 1
}

echo "${bold}cartograph · fetch-geoip${rst} → $DEST"
fetch asn "$DEST/asn.mmdb"
fetch country "$DEST/country.mmdb"

echo
echo "IP geolocation by DB-IP (https://db-ip.com) · CC-BY 4.0"
echo "surveyor picks these up automatically; --geoip $DEST overrides."
