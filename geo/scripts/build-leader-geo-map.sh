#!/usr/bin/env bash
set -euo pipefail

OUTPUT_PATH="${1:-geo/data/leader-geo-map.json}"
UNKNOWN_GEO="UNKNOWN"

LEADER_IPS=("176.114.240.49" "64.130.43.204")

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "missing required command: $1" >&2
    exit 1
  fi
}

lookup_geo_from_ipinfo() {
  local ip="$1"
  local body

  if ! body=$(curl -sS --max-time 5 "https://ipinfo.io/${ip}/json" 2>/dev/null); then
    echo "$UNKNOWN_GEO"
    return
  fi

  # city/region/country are coarse and compact enough for bundled artifacts.
  local geo
  geo=$(jq -r '
    [(.city // ""), (.region // ""), (.country // "")]
    | map(select(length > 0))
    | if length == 0 then "" else join(", ") end
  ' <<<"$body")

  if [ -z "$geo" ]; then
    echo "$UNKNOWN_GEO"
  else
    echo "$geo"
  fi
}

require_cmd curl
require_cmd jq

mkdir -p "$(dirname "$OUTPUT_PATH")"

ip_geo_lines=""
for ip in "${LEADER_IPS[@]}"; do
  geo=$(lookup_geo_from_ipinfo "$ip")
  ip_geo_lines+="${ip}\t${geo}\n"
done

ip_geo_map_json=$(printf "%b" "$ip_geo_lines" | jq -Rn '
  [inputs | select(length > 0) | split("\t") | { key: .[0], value: .[1] }]
  | from_entries
')

jq -n \
  --argjson ip_geo_map "$ip_geo_map_json" \
  '$ip_geo_map' > "$OUTPUT_PATH"

echo "Success: $OUTPUT_PATH"
