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

compute_closest_region_from_loc() {
  local loc="$1"
  local closest_region

  closest_region=$(jq -rn --arg loc "$loc" '
    def regions: [
      {name: "Frankfurt", lat: 50.1109, lon: 8.6821},
      {name: "Dubai", lat: 25.2048, lon: 55.2708},
      {name: "NewYork", lat: 40.7128, lon: -74.0060},
      {name: "Tokyo", lat: 35.6762, lon: 139.6503}
    ];
    def sqr($x): $x * $x;
    ($loc | split(",")) as $parts
    | if ($parts | length) != 2 then error("invalid loc format") else . end
    | ($parts[0] | tonumber) as $lat
    | ($parts[1] | tonumber) as $lon
    | regions
    | map({name, d2: (sqr($lat - .lat) + sqr($lon - .lon))})
    | sort_by(.d2)
    | .[0].name
  ' 2>/dev/null || true)

  if [ -z "$closest_region" ]; then
    return 1
  fi

  echo "$closest_region"
}

build_info_json() {
  local loc="$1"
  local geo="$2"
  local closest_region

  if [ -z "$loc" ] || [ -z "$geo" ]; then
    return 1
  fi

  closest_region=$(compute_closest_region_from_loc "$loc") || return 1

  jq -cn \
    --arg geo "$geo" \
    --arg closest_region "$closest_region" \
    '{geo: $geo, closest_region: $closest_region}'
}

lookup_geo_info_from_ipinfo() {
  local ip="$1"
  local body
  local loc
  local geo

  body=$(curl -sS --max-time 5 "https://ipinfo.io/${ip}/json")
  [ -n "$body" ] || return 1

  loc=$(jq -r '.loc // ""' <<<"$body")
  geo=$(jq -r '
    [(.city // ""), (.region // ""), (.country // "")]
    | map(select(length > 0))
    | if length == 0 then "" else join(", ") end
  ' <<<"$body")

  build_info_json "$loc" "$geo"
}

lookup_geo_info_from_ipapi() {
  local ip="$1"
  local body
  local lat
  local lon
  local loc
  local geo

  body=$(curl -sS --max-time 5 "https://ipapi.co/${ip}/json/")
  [ -n "$body" ] || return 1

  if [ "$(jq -r '.error // false' <<<"$body")" = "true" ]; then
    return 1
  fi

  lat=$(jq -r '.latitude // empty' <<<"$body")
  lon=$(jq -r '.longitude // empty' <<<"$body")
  if [ -n "$lat" ] && [ -n "$lon" ]; then
    loc="${lat},${lon}"
  else
    loc=""
  fi

  geo=$(jq -r '
    [(.city // ""), (.region // ""), (.country_code // "")]
    | map(select(length > 0))
    | if length == 0 then "" else join(", ") end
  ' <<<"$body")

  build_info_json "$loc" "$geo"
}

lookup_geo_info_from_ipwhois() {
  local ip="$1"
  local body
  local lat
  local lon
  local loc
  local geo

  body=$(curl -sS --max-time 5 "https://ipwho.is/${ip}")
  [ -n "$body" ] || return 1

  if [ "$(jq -r '.success // false' <<<"$body")" != "true" ]; then
    return 1
  fi

  lat=$(jq -r '.latitude // empty' <<<"$body")
  lon=$(jq -r '.longitude // empty' <<<"$body")
  if [ -n "$lat" ] && [ -n "$lon" ]; then
    loc="${lat},${lon}"
  else
    loc=""
  fi

  geo=$(jq -r '
    [(.city // ""), (.region // ""), (.country_code // "")]
    | map(select(length > 0))
    | if length == 0 then "" else join(", ") end
  ' <<<"$body")

  build_info_json "$loc" "$geo"
}

lookup_geo_info() {
  local ip="$1"
  local info_json

  if info_json=$(lookup_geo_info_from_ipinfo "$ip"); then
    echo "IP ${ip}: geolocated with provider ipinfo" >&2
    echo "$info_json"
    return 0
  fi

  if info_json=$(lookup_geo_info_from_ipapi "$ip"); then
    echo "IP ${ip}: geolocated with provider ipapi" >&2
    echo "$info_json"
    return 0
  fi

  if info_json=$(lookup_geo_info_from_ipwhois "$ip"); then
    echo "IP ${ip}: geolocated with provider ipwhois" >&2
    echo "$info_json"
    return 0
  fi

  echo "failed to geolocate IP ${ip} with providers: ipinfo, ipapi, ipwhois" >&2
  return 1
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
  info_json=$(lookup_geo_info "$ip")
  ip_geo_lines+="${ip}\t${info_json}\n"
done

ip_geo_map_json=$(printf "%b" "$ip_geo_lines" | jq -Rn '
  [inputs | select(length > 0) | split("\t") | { key: .[0], value: (.[1] | fromjson) }]
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
