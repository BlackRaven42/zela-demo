#!/usr/bin/env bash
set -euo pipefail

# Build a deduplicated list of current-epoch leader endpoint IPs from Solana RPC.

RPC_URL="${RPC_URL:-https://api.mainnet-beta.solana.com}"
OUTPUT_PATH="${1:-geo/data/leader-ips.json}"

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "missing required command: $1" >&2
    exit 1
  fi
}

rpc_call() {
  local method="$1"
  local params="$2"
  curl -sS "$RPC_URL" \
    -H 'Content-Type: application/json' \
    --data "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"${method}\",\"params\":${params}}"
}

require_cmd curl
require_cmd jq

mkdir -p "$(dirname "$OUTPUT_PATH")"

slot_json="$(rpc_call getSlot '[]')"
slot="$(jq -r '.result' <<<"$slot_json")"
if [ -z "$slot" ] || [ "$slot" = "null" ]; then
  echo "failed to fetch slot from RPC: $slot_json" >&2
  exit 1
fi

leader_schedule_json="$(rpc_call getLeaderSchedule "[${slot}]")"
cluster_nodes_json="$(rpc_call getClusterNodes '[]')"

leader_schedule_file="$(mktemp)"
cluster_nodes_file="$(mktemp)"
trap 'rm -f "$leader_schedule_file" "$cluster_nodes_file"' EXIT

jq '.result // {}' <<<"$leader_schedule_json" > "$leader_schedule_file"
jq '.result // []' <<<"$cluster_nodes_json" > "$cluster_nodes_file"

jq -n \
  --slurpfile leader_schedule "$leader_schedule_file" \
  --slurpfile cluster_nodes "$cluster_nodes_file" \
  '
  ($leader_schedule[0]) as $leader_schedule
  | ($cluster_nodes[0]) as $cluster_nodes
  |
  def endpoint_to_ip:
    if . == null then null
    elif startswith("[") then (capture("^\\[(?<ip>[^\\]]+)\\]:").ip? // null)
    else (split(":")[0] // null)
    end;

  def preferred_ip:
    [ .gossip, .tpu, .rpc, .tvu ]
    | map(select(. != null))
    | (.[0] // null)
    | endpoint_to_ip;

  ($cluster_nodes
    | map({key: .pubkey, value: preferred_ip})
    | from_entries) as $ip_by_pubkey

  | ($leader_schedule | keys) as $leaders

  | [ $leaders[] | $ip_by_pubkey[.] ]
  | map(select(. != null and . != ""))
  | unique
  ' > "$OUTPUT_PATH"

echo "Success: $OUTPUT_PATH"
