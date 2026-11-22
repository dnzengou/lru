#!/usr/bin/env bash
# Inter-Universe Communication Protocol v0.7.0
# ==============================================
# Implements inter-universe messaging with:
#   - Broadcast mode: one universe sends to all
#   - Multicast mode: send to specific universes by ID
#   - Message format: {from, to, type, payload, phi_weight, ttl}
#   - TTL-based routing (messages expire after N hops)
#   - Logs to dao/comms/ directory
#
# Usage:
#   sh comms_protocol.sh broadcast <message> [phi_weight]
#   sh comms_protocol.sh multicast <to_hash> <message> [phi_weight]
#   sh comms_protocol.sh unicast <to_hash> <message> [phi_weight]
#   sh comms_protocol.sh inbox [filter_universe]
#   sh comms_protocol.sh outbox
#   sh comms_protocol.sh status
#   sh comms_protocol.sh cleanup [max_age_seconds]
#   sh comms_protocol.sh route <message_id> <target_hash>
#
# Dependencies: awk, sha256sum, bc

set -e

BASE_DIR="${LRU_BASE_DIR:-$(cd "$(dirname "$0")/.." && pwd)}"
DAO_DIR="${BASE_DIR}/dao"
COMMS_DIR="${DAO_DIR}/comms"
STATE_FILE="${BASE_DIR}/universe_state_v7.json"
COMMS_HISTORY="${DAO_DIR}/comms_history_v7.txt"
COMMS_INDEX="${DAO_DIR}/comms_index_v7.json"

mkdir -p "$COMMS_DIR"

# ─── Parameters ──────────────────────────────────────────────────────────────

DEFAULT_TTL=3600          # Default TTL in seconds
MAX_HOPS=10               # Maximum routing hops
BROADCAST_CHANNEL="broadcast"
PHI_WEIGHT_DEFAULT=0.1    # Default phi weight for messages

# ─── Help ─────────────────────────────────────────────────────────────────────

usage() {
  echo "Inter-Universe Communication Protocol v0.7.0"
  echo ""
  echo "Usage:"
  echo "  $0 broadcast <message> [phi_weight]       Send to all universes"
  echo "  $0 multicast <to_hash> <message> [phi]    Send to specific universe"
  echo "  $0 unicast <to_hash> <message> [phi]      Send to one universe"
  echo "  $0 inbox [filter]                          Read received messages"
  echo "  $0 outbox                                  Show sent messages"
  echo "  $0 status                                  Comms network status"
  echo "  $0 cleanup [max_age_sec]                   Clean expired messages"
  echo "  $0 route <msg_id> <target_hash>            Forward message"
  exit 0
}

# ─── JSON Helper ─────────────────────────────────────────────────────────────

json_get() {
  file="$1" key="$2"
  awk -v k="$key" '{
    if ($0 ~ "\"" k "\"") {
      gsub(/.*"'"$key"'": *"?/, "")
      gsub(/[",}].*/, "")
      print
      exit
    }
  }' "$file"
}

# ─── Get current universe hash ──────────────────────────────────────────────

get_my_hash() {
  if [ -f "$STATE_FILE" ]; then
    json_get "$STATE_FILE" "hash"
  else
    echo "unknown_v7"
  fi
}

# ─── Get phi weight ─────────────────────────────────────────────────────────

get_phi() {
  if [ -f "$STATE_FILE" ]; then
    phi=$(json_get "$STATE_FILE" "phi")
    [ -z "$phi" ] && phi=$PHI_WEIGHT_DEFAULT
    [ "$(echo "$phi <= 0" | bc -l 2>/dev/null)" = "1" ] && phi=$PHI_WEIGHT_DEFAULT
    echo "$phi"
  else
    echo "$PHI_WEIGHT_DEFAULT"
  fi
}

# ─── Generate message ID ────────────────────────────────────────────────────

generate_msg_id() {
  from="$1" to="$2" msg="$3" ts="$4"
  echo "$from $to $msg $ts $RANDOM" | sha256sum | cut -c1-16
}

# ─── Send a message ─────────────────────────────────────────────────────────

send_message() {
  to="$1" message="$2" phi_weight="${3:-$(get_phi)}"
  from=$(get_my_hash)
  ts=$(date +%s)
  msg_id=$(generate_msg_id "$from" "$to" "$message" "$ts")
  payload_hash=$(echo "$from $to $message $ts $phi_weight" | sha256sum | cut -c1-32)

  # Create message file
  cat > "${COMMS_DIR}/${msg_id}.json" << EOF
{
  "id": "${msg_id}",
  "from": "${from}",
  "to": "${to}",
  "type": "$([ "$to" = "$BROADCAST_CHANNEL" ] && echo "broadcast" || echo "direct")",
  "payload": "${message}",
  "payload_hash": "${payload_hash}",
  "phi_weight": ${phi_weight},
  "timestamp": ${ts},
  "ttl": ${DEFAULT_TTL},
  "hops": 0,
  "max_hops": ${MAX_HOPS},
  "signature": "${payload_hash}",
  "status": "sent",
  "routed_by": []
}
EOF

  # Log to history
  type_label="BROADCAST"
  [ "$to" != "$BROADCAST_CHANNEL" ] && type_label="UNICAST"
  echo "${type_label}|${msg_id}|${from}→${to}|${message}|${ts}|phi=${phi_weight}" >> "$COMMS_HISTORY"

  echo "  📨 Message sent"
  echo "     ID:   ${msg_id}"
  echo "     From: ${from}"
  echo "     To:   ${to}"
  echo "     Type: ${type_label}"
  echo "     Phi:  ${phi_weight}"
  echo "     TTL:  ${DEFAULT_TTL}s"
  echo "     Hash: ${payload_hash}"

  # Update comms_sent counter in state
  if [ -f "$STATE_FILE" ]; then
    current_sent=$(json_get "$STATE_FILE" "comms_sent")
    [ -z "$current_sent" ] && current_sent=0
    current_sent=$((current_sent + 1))
    sed -i "s/\"comms_sent\": [0-9]*/\"comms_sent\": $current_sent/" "$STATE_FILE"
  fi
}

# ─── Read inbox ─────────────────────────────────────────────────────────────

cmd_inbox() {
  filter="${1:-}"

  echo ""
  echo "  ╔══════════════════════════════════════════════╗"
  echo "  ║     INTER-UNIVERSE INBOX                     ║"
  echo "  ╚══════════════════════════════════════════════╝"
  echo ""

  my_hash=$(get_my_hash)
  count=0
  now=$(date +%s)
  expired=0

  for f in "$COMMS_DIR"/*.json; do
    [ ! -f "$f" ] && continue
    id=$(json_get "$f" "id")
    from=$(json_get "$f" "from")
    to=$(json_get "$f" "to")
    msg_type=$(json_get "$f" "type")
    payload=$(json_get "$f" "payload")
    phi=$(json_get "$f" "phi_weight")
    ts=$(json_get "$f" "timestamp")
    ttl=$(json_get "$f" "ttl")
    hops=$(json_get "$f" "hops")
    status=$(json_get "$f" "status")

    # Check if message is for us
    is_for_me=false
    [ "$to" = "$BROADCAST_CHANNEL" ] && is_for_me=true
    [ "$to" = "$my_hash" ] && is_for_me=true

    # Apply filter
    if [ -n "$filter" ]; then
      [ "$from" != "$filter" ] && [ "$to" != "$filter" ] && continue
    fi

    # Check TTL
    age=$((now - ts))
    if [ "$age" -gt "$ttl" ]; then
      expired=$((expired + 1))
      continue
    fi

    $is_for_me || continue

    count=$((count + 1))
    time_ago=""
    [ "$age" -lt 60 ] && time_ago="${age}s ago"
    [ "$age" -ge 60 ] && time_ago="$((age / 60))m ago"
    [ "$age" -ge 3600 ] && time_ago="$((age / 3600))h ago"

    printf "  [%s]\n" "$id"
    printf "  %s → %s" "$from" "$to"
    [ "$msg_type" = "broadcast" ] && printf " (BROADCAST)"
    printf "\n"
    printf "  \"%s\"\n" "$payload"
    printf "  phi=%.4f | hops=%d/%d | %s | %s\n" "$phi" "$hops" "$MAX_HOPS" "$time_ago" "$status"
    echo ""
  done

  [ "$count" -eq 0 ] && echo "  (no messages)"
  echo "  Total: $count active, $expired expired"
  echo ""
}

# ─── Show outbox (sent messages) ────────────────────────────────────────────

cmd_outbox() {
  my_hash=$(get_my_hash)

  echo ""
  echo "  ╔══════════════════════════════════════════════╗"
  echo "  ║     OUTBOX (Sent Messages)                   ║"
  echo "  ╚══════════════════════════════════════════════╝"
  echo ""

  count=0
  now=$(date +%s)

  for f in "$COMMS_DIR"/*.json; do
    [ ! -f "$f" ] && continue
    from=$(json_get "$f" "from")
    [ "$from" != "$my_hash" ] && continue

    count=$((count + 1))
    id=$(json_get "$f" "id")
    to=$(json_get "$f" "to")
    payload=$(json_get "$f" "payload")
    ts=$(json_get "$f" "timestamp")
    status=$(json_get "$f" "status")
    age=$((now - ts))

    time_ago=""
    [ "$age" -lt 60 ] && time_ago="${age}s ago"
    [ "$age" -ge 60 ] && time_ago="$((age / 60))m ago"

    printf "  [%s] %s → %s (%s) [%s]\n" "$id" "$from" "$to" "$time_ago" "$status"
    printf "    \"%s\"\n" "$payload"
    echo ""
  done

  [ "$count" -eq 0 ] && echo "  (no sent messages)"
  echo "  Total: $count"
  echo ""
}

# ─── Route a message (forward to another universe) ─────────────────────────

cmd_route() {
  msg_id="$1" target_hash="$2"
  [ -z "$msg_id" ] && { echo "Usage: $0 route <msg_id> <target_hash>"; exit 1; }
  [ -z "$target_hash" ] && { echo "Usage: $0 route <msg_id> <target_hash>"; exit 1; }

  msg_file="${COMMS_DIR}/${msg_id}.json"
  [ ! -f "$msg_file" ] && { echo "Message not found: $msg_id"; exit 1; }

  hops=$(json_get "$msg_file" "hops")
  hops=$((hops + 1))

  if [ "$hops" -gt "$MAX_HOPS" ]; then
    echo "  ❌ Max hops exceeded ($hops > $MAX_HOPS). Message dropped."
    sed -i 's/"status": "[^"]*"/"status": "dropped"/' "$msg_file"
    sed -i 's/"reason": "[^"]*"/"reason": "max_hops_exceeded"/' "$msg_file"
    exit 1
  fi

  # Update message
  sed -i "s/\"hops\": [0-9]*/\"hops\": $hops/" "$msg_file"
  sed -i "s/\"to\": \"[^\"]*\"/\"to\": \"$target_hash\"/" "$msg_file"
  sed -i 's/"status": "[^"]*"/"status": "routed"/' "$msg_file"

  # Add to routed_by
  router_hash=$(get_my_hash)
  current_routes=$(json_get "$msg_file" "routed_by")
  # Simple append
  sed -i "s/\"routed_by\": \[[^\]]*\]/\"routed_by\": [\"$router_hash\"]/" "$msg_file"

  echo "  🔀 Message $msg_id routed to $target_hash (hop $hops/$MAX_HOPS)"

  # Log
  echo "ROUTE|${msg_id}|${router_hash}→${target_hash}|hop=${hops}|$(date +%s)" >> "$COMMS_HISTORY"
}

# ─── Cleanup expired messages ──────────────────────────────────────────────

cmd_cleanup() {
  max_age="${1:-$DEFAULT_TTL}"
  now=$(date +%s)
  cleaned=0

  echo ""
  echo "  Cleaning messages older than ${max_age}s..."
  echo ""

  for f in "$COMMS_DIR"/*.json; do
    [ ! -f "$f" ] && continue
    ts=$(json_get "$f" "timestamp")
    age=$((now - ts))
    if [ "$age" -gt "$max_age" ]; then
      rm -f "$f"
      cleaned=$((cleaned + 1))
    fi
  done

  echo "  Cleaned $cleaned expired messages"
  echo "  Remaining: $(ls "$COMMS_DIR"/*.json 2>/dev/null | wc -l)"
  echo ""
}

# ─── Comms status ──────────────────────────────────────────────────────────

cmd_status() {
  my_hash=$(get_my_hash)
  total=$(ls "$COMMS_DIR"/*.json 2>/dev/null | wc -l)
  now=$(date +%s)
  active=0
  expired=0
  broadcasts=0
  directs=0

  for f in "$COMMS_DIR"/*.json; do
    [ ! -f "$f" ] && continue
    ts=$(json_get "$f" "timestamp")
    age=$((now - ts))
    ttl=$(json_get "$f" "ttl")
    msg_type=$(json_get "$f" "type")
    [ "$age" -gt "$ttl" ] && expired=$((expired + 1)) || active=$((active + 1))
    [ "$msg_type" = "broadcast" ] && broadcasts=$((broadcasts + 1))
    [ "$msg_type" = "direct" ] && directs=$((directs + 1))
  done

  echo ""
  echo "  ╔══════════════════════════════════════════════╗"
  echo "  ║     COMMUNICATIONS NETWORK STATUS            ║"
  echo "  ╚══════════════════════════════════════════════╝"
  echo ""
  printf "  Universe:          %s\n" "$my_hash"
  printf "  Total messages:    %d\n" "$total"
  printf "  Active:            %d\n" "$active"
  printf "  Expired:           %d\n" "$expired"
  printf "  Broadcasts:        %d\n" "$broadcasts"
  printf "  Direct:            %d\n" "$directs"
  printf "  Max hops:          %d\n" "$MAX_HOPS"
  printf "  Default TTL:       %ds\n" "$DEFAULT_TTL"
  echo ""

  # Phi influence
  phi=$(get_phi)
  printf "  Local phi:         %.4f\n" "$phi"
  printf "  Phi influence:     %.2f%%\n" "$(echo "scale=2; $phi * 100" | bc 2>/dev/null || echo "10")"

  # Outgoing vs incoming
  sent=0
  received=0
  for f in "$COMMS_DIR"/*.json; do
    [ ! -f "$f" ] && continue
    from=$(json_get "$f" "from")
    to=$(json_get "$f" "to")
    [ "$from" = "$my_hash" ] && sent=$((sent + 1))
    [ "$to" = "$my_hash" ] || [ "$to" = "$BROADCAST_CHANNEL" ] && received=$((received + 1))
  done
  printf "  Sent:              %d\n" "$sent"
  printf "  Received:          %d\n" "$received"
  echo ""
}

# ─── Main ─────────────────────────────────────────────────────────────────────

[ $# -eq 0 ] && { usage; exit 0; }

case "$1" in
  broadcast)
    shift
    msg="$1"
    phi="${2:-$(get_phi)}"
    [ -z "$msg" ] && { echo "Usage: $0 broadcast <message> [phi_weight]"; exit 1; }
    send_message "$BROADCAST_CHANNEL" "$msg" "$phi"
    ;;
  multicast)
    shift
    to_hash="$1"
    msg="$2"
    phi="${3:-$(get_phi)}"
    [ -z "$to_hash" ] && { echo "Usage: $0 multicast <to_hash> <message> [phi_weight]"; exit 1; }
    [ -z "$msg" ] && { echo "Usage: $0 multicast <to_hash> <message> [phi_weight]"; exit 1; }
    send_message "$to_hash" "$msg" "$phi"
    ;;
  unicast)
    shift
    to_hash="$1"
    msg="$2"
    phi="${3:-$(get_phi)}"
    [ -z "$to_hash" ] && { echo "Usage: $0 unicast <to_hash> <message> [phi_weight]"; exit 1; }
    [ -z "$msg" ] && { echo "Usage: $0 unicast <to_hash> <message> [phi_weight]"; exit 1; }
    send_message "$to_hash" "$msg" "$phi"
    ;;
  inbox)
    shift
    cmd_inbox "$1"
    ;;
  outbox)
    cmd_outbox
    ;;
  status)
    cmd_status
    ;;
  cleanup)
    shift
    cmd_cleanup "$1"
    ;;
  route)
    shift
    cmd_route "$1" "$2"
    ;;
  --help|-h)
    usage
    ;;
  *)
    echo "Unknown: $1"
    usage
    ;;
esac
