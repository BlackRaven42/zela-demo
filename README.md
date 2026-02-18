# Leader Routing Procedure (a.k.a. Geo)

## Overview
The procedure returns which server region should handle the request to be closest (coarse geo) to the current Solana leader.

## Input
The procedure does not take any input.

## Output
The output is a JSON object containing:
- `slot`
- `leader`
- `leader_geo`
- `closest_region` (`Frankfurt` | `Dubai` | `NewYork` | `Tokyo`)

## How it works
1. Get current slot from Solana.
2. Get leader schedule and resolve leader for that slot.
3. Resolve leader pubkey to endpoint IP from `getClusterNodes`.
4. Use bundled offline map `geo/data/ip-geo-map.json` (`ip -> {geo, closest_region}`).
5. If IP is missing from map:
- return `leader_geo = "UNKNOWN"`
- pick fallback region deterministically using a hash function.
6. If no endpoint IP is available:
- return `leader_geo = "UNKNOWN"`
- fallback `closest_region = Tokyo`.

## Deterministic mapping rule
- Known IPs: region is precomputed offline by nearest of:
  - Frankfurt `(50.1109, 8.6821)`
  - Dubai `(25.2048, 55.2708)`
  - NewYork `(40.7128, -74.0060)`
  - Tokyo `(35.6762, 139.6503)`
- Unknown IPs: deterministic hash fallback from IP string.

## Runtime constraints and stability
- No external geo HTTP calls at runtime.
- Geo map is bundled into the artifact.
- Cluster node endpoint map is cached for 60s to reduce RPC load.
- Unknown-IP fallback is deterministic, so repeated calls for the same unknown IP do not flap.

## Build
Prerequisites:
- Rust toolchain
- Target `wasm32-wasip2`
- `curl`, `jq` (for scripts and runner)

Commands:
```bash
rustup target add wasm32-wasip2
cargo test -p geo
cargo build -p geo --release --target wasm32-wasip2
```

## Reproducible offline map generation
Inputs:
- Geo providers used: `ipinfo`, `ipapi` and `ipwhois`

Steps:
```bash
./geo/scripts/dump-leader-ips.sh
./geo/scripts/build-ip-geo-map.sh
```

Outputs:
- `geo/data/leader-ips.json`
- `geo/data/ip-geo-map.json`

Notes:
- Script fails fast if IP list is missing/empty or if all providers fail for any IP. This is intentional, since we want to know that the existing providers do not cover all IPs and we should find an alternative and update the script.
- Current bundled map size is small (about 76 KB), well below ~10 MB target.

## Example call
Fill `.env` (or copy `.env.template`) with:
- `ZELA_PROJECT_KEY_ID`
- `ZELA_PROJECT_KEY_SECRET`
- `ZELA_PROCEDURE`
- `ZELA_PARAMS='{}'`

Run:
```bash
./run-procedure.sh
```

## Sample response
```json
{
  "slot": 400976911,
  "leader": "ChaossRPGKnsVhX1GfPC78yq5Sqju4cMThcAsKZNz5d6",
  "leader_geo": "Offenbach, Hesse, DE",
  "closest_region": "Frankfurt"
}
```

## Assumptions, failure modes, and flapping
Assumption: leader endpoint IP from Solana cluster data is a useful proxy for coarse leader location. Main failure modes are Solana RPC failures, missing leader endpoint IP, and stale/incomplete offline geo map. Flapping is reduced by deterministic behavior: known IPs use a fixed precomputed map, and unknown IPs use deterministic hash-based region fallback.

## Short feedback about Zela
Overall, really intuitive system: integration with GitHub and onboarding to Zela were smooth. Within minutes you know how everything works here. Hints are timely, UI/UX is well thought out.

Minor things:
- Working with two separate calls - one for JWT token retrieval and one for RPC - can be cumbersome, and that's why `run-procedure.sh` is more convenient. I suggest you use a similar "combined" command in your UI as well.
- The instructions for those JWT and RPC calls are shown only for the first 1-2 deployments, and then they disappear. Probably better to keep them handy always.
- One small but eye-catching typo:  
  "Clicking on a row will give you **it's** detail."  
  should be:  
  "Clicking on a row will give you **its** detail**s**."
