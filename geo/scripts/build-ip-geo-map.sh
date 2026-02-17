#!/usr/bin/env bash
set -euo pipefail

OUTPUT_PATH="${1:-geo/data/ip-geo-map.json}"
LEADER_IPS_PATH="${LEADER_IPS_PATH:-geo/data/leader-ips.json}"
LEADER_IPS=()

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "missing required command: $1" >&2
    exit 1
  fi
}

lookup_geo_from_ipinfo() {
  local ip="$1"
  local body

  body=$(curl -sS --max-time 5 "https://ipinfo.io/${ip}/json")

  # city/region/country are coarse and compact enough for bundled artifacts.
  local geo
  geo=$(jq -r '
    [(.city // ""), (.region // ""), (.country // "")]
    | map(select(length > 0))
    | if length == 0 then "" else join(", ") end
  ' <<<"$body")

  if [ -z "$geo" ]; then
    echo "missing geo data for IP: $ip" >&2
    exit 1
  fi

  echo "$geo"
}

require_cmd curl
require_cmd jq

mkdir -p "$(dirname "$OUTPUT_PATH")"

if [ ! -f "$LEADER_IPS_PATH" ]; then
  echo "missing leader IP list: $LEADER_IPS_PATH" >&2
  exit 1
fi

mapfile -t LEADER_IPS < <(
  jq -r '.[]' "$LEADER_IPS_PATH" \
    | awk 'NF' \
    | sort -u
)

if [ "${#LEADER_IPS[@]}" -eq 0 ]; then
  echo "leader IP list is empty: $LEADER_IPS_PATH" >&2
  exit 1
fi

ip_geo_lines=""
for ip in "${LEADER_IPS[@]}"; do
  geo=$(lookup_geo_from_ipinfo "$ip")
  ip_geo_lines+="${ip}\t${geo}\n"
done

ip_geo_map_json=$(printf "%b" "$ip_geo_lines" | jq -Rn '
  [inputs | select(length > 0) | split("\t") | { key: .[0], value: .[1] }]
  | from_entries
')

if [ "$(jq 'length' <<<"$ip_geo_map_json")" -eq 0 ]; then
  echo "generated empty IP geo map" >&2
  exit 1
fi

jq -n \
  --argjson ip_geo_map "$ip_geo_map_json" \
  '$ip_geo_map' > "$OUTPUT_PATH"

echo "Success: $OUTPUT_PATH"
