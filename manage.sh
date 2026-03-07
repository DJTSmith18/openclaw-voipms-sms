#!/usr/bin/env bash
set -euo pipefail

# ── voipms-sms Plugin Management Tool ────────────────────────────────────────
# CLI for managing DIDs, contacts, access control, and features.
# Reads/writes openclaw.json via jq and the SQLite database directly.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BOLD='\033[1m'
DIM='\033[2m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m'

info()  { echo -e "${GREEN}✓${NC} $*"; }
warn()  { echo -e "${YELLOW}!${NC} $*"; }
err()   { echo -e "${RED}✗${NC} $*" >&2; }

# ── Config path resolution ────────────────────────────────────────────────────

CONFIG="${OPENCLAW_CONFIG:-${1:-}}"
shift 2>/dev/null || true

resolve_config() {
  if [ -n "$CONFIG" ] && [ -f "$CONFIG" ]; then return; fi
  # Try common locations
  for candidate in "$HOME/.openclaw/openclaw.json" "./openclaw.json"; do
    if [ -f "$candidate" ]; then
      CONFIG="$candidate"
      return
    fi
  done
  err "Cannot find openclaw.json. Use --config <path> or set OPENCLAW_CONFIG."
  exit 1
}

# Get plugin config from openclaw.json
get_plugin_config() {
  jq -r '.plugins.entries["voipms-sms"].config // empty' "$CONFIG"
}

get_db_path() {
  jq -r '.plugins.entries["voipms-sms"].config.dbPath // empty' "$CONFIG"
}

get_did_config() {
  local did="$1"
  jq -r --arg d "$did" '.plugins.entries["voipms-sms"].config.dids[$d] // empty' "$CONFIG"
}

backup_config() {
  cp "$CONFIG" "${CONFIG}.bak"
}

# ── Commands ──────────────────────────────────────────────────────────────────

cmd_list_dids() {
  echo -e "${BOLD}Configured DIDs:${NC}"
  echo ""
  jq -r '
    .plugins.entries["voipms-sms"].config.dids // {} |
    to_entries[] |
    "  \(.key)  agent=\(.value.agent)  label=\"\(.value.label // .key)\"  in=\(.value.inbound // true)  out=\(.value.outbound // true)  access=\(.value.accessControl.mode // "allow-all")"
  ' "$CONFIG"
}

cmd_add_did() {
  local did="${1:-}"
  local agent="${2:-}"
  if [ -z "$did" ] || [ -z "$agent" ]; then
    err "Usage: manage.sh add-did <did> <agent-id> [--label <label>] [--no-inbound] [--no-outbound]"
    exit 1
  fi
  did="$(echo "$did" | sed 's/[^0-9]//g')"
  shift 2

  local label="$did" inbound="true" outbound="true"
  while [ $# -gt 0 ]; do
    case "$1" in
      --label)      label="$2"; shift 2 ;;
      --no-inbound) inbound="false"; shift ;;
      --no-outbound) outbound="false"; shift ;;
      *) shift ;;
    esac
  done

  backup_config
  local tmp; tmp="$(mktemp)"
  jq --arg did "$did" --arg agent "$agent" --arg label "$label" \
     --argjson inbound "$inbound" --argjson outbound "$outbound" '
    .plugins.entries["voipms-sms"].config.dids[$did] = {
      label: $label,
      agent: $agent,
      inbound: $inbound,
      outbound: $outbound,
      features: {
        smsThreadLogging: true,
        languagePreferences: true,
        smsStitching: true,
        agentThreadAccess: false,
        agentCanAddContacts: false
      },
      accessControl: { mode: "allow-all", list: [] },
      contactLookup: null,
      suppression: { unknownContact: "allow", unknownContactAction: "silent" }
    } |
    # Add binding
    .bindings = [(.bindings // [])[] | select(.match.channel != "voipms" or .match.accountId != $did)] +
                [{ agentId: $agent, match: { channel: "voipms", accountId: $did } }]
  ' "$CONFIG" > "$tmp" && mv "$tmp" "$CONFIG"
  info "DID $did added (agent: $agent)"
}

cmd_remove_did() {
  local did="${1:-}"
  if [ -z "$did" ]; then
    err "Usage: manage.sh remove-did <did>"
    exit 1
  fi
  did="$(echo "$did" | sed 's/[^0-9]//g')"

  backup_config
  local tmp; tmp="$(mktemp)"
  jq --arg did "$did" '
    del(.plugins.entries["voipms-sms"].config.dids[$did]) |
    .bindings = [(.bindings // [])[] | select(.match.channel != "voipms" or .match.accountId != $did)]
  ' "$CONFIG" > "$tmp" && mv "$tmp" "$CONFIG"
  info "DID $did removed"
}

cmd_show_config() {
  local did="${1:-}"
  if [ -n "$did" ]; then
    did="$(echo "$did" | sed 's/[^0-9]//g')"
    echo -e "${BOLD}Config for DID $did:${NC}"
    get_did_config "$did" | jq .
  else
    echo -e "${BOLD}Full plugin config:${NC}"
    get_plugin_config | jq .
  fi
}

cmd_set_feature() {
  local did="${1:-}" feature="${2:-}" value="${3:-}"
  if [ -z "$did" ] || [ -z "$feature" ] || [ -z "$value" ]; then
    err "Usage: manage.sh set-feature <did> <feature> <true|false>"
    err "Features: smsThreadLogging, languagePreferences, smsStitching, agentThreadAccess, agentCanAddContacts"
    exit 1
  fi
  did="$(echo "$did" | sed 's/[^0-9]//g')"

  backup_config
  local tmp; tmp="$(mktemp)"
  jq --arg did "$did" --arg feat "$feature" --argjson val "$value" '
    .plugins.entries["voipms-sms"].config.dids[$did].features[$feat] = $val
  ' "$CONFIG" > "$tmp" && mv "$tmp" "$CONFIG"
  info "DID $did: $feature = $value"
}

cmd_set_access() {
  local did="${1:-}" mode="${2:-}"
  if [ -z "$did" ] || [ -z "$mode" ]; then
    err "Usage: manage.sh set-access <did> <allow-all|block-all|whitelist|blacklist>"
    exit 1
  fi
  did="$(echo "$did" | sed 's/[^0-9]//g')"

  backup_config
  local tmp; tmp="$(mktemp)"
  jq --arg did "$did" --arg mode "$mode" '
    .plugins.entries["voipms-sms"].config.dids[$did].accessControl.mode = $mode
  ' "$CONFIG" > "$tmp" && mv "$tmp" "$CONFIG"
  info "DID $did: access control mode = $mode"
}

cmd_add_allowed() {
  local did="${1:-}" phone="${2:-}"
  if [ -z "$did" ] || [ -z "$phone" ]; then
    err "Usage: manage.sh add-allowed <did> <phone>"
    exit 1
  fi
  did="$(echo "$did" | sed 's/[^0-9]//g')"
  phone="$(echo "$phone" | sed 's/[^0-9]//g')"

  backup_config
  local tmp; tmp="$(mktemp)"
  jq --arg did "$did" --arg phone "$phone" '
    .plugins.entries["voipms-sms"].config.dids[$did].accessControl.list += [$phone] |
    .plugins.entries["voipms-sms"].config.dids[$did].accessControl.list |= unique
  ' "$CONFIG" > "$tmp" && mv "$tmp" "$CONFIG"
  info "DID $did: added $phone to access list"
}

cmd_remove_allowed() {
  local did="${1:-}" phone="${2:-}"
  if [ -z "$did" ] || [ -z "$phone" ]; then
    err "Usage: manage.sh remove-allowed <did> <phone>"
    exit 1
  fi
  did="$(echo "$did" | sed 's/[^0-9]//g')"
  phone="$(echo "$phone" | sed 's/[^0-9]//g')"

  backup_config
  local tmp; tmp="$(mktemp)"
  jq --arg did "$did" --arg phone "$phone" '
    .plugins.entries["voipms-sms"].config.dids[$did].accessControl.list -= [$phone]
  ' "$CONFIG" > "$tmp" && mv "$tmp" "$CONFIG"
  info "DID $did: removed $phone from access list"
}

# Alias commands for blacklist operations
cmd_add_blocked()    { cmd_add_allowed "$@"; }
cmd_remove_blocked() { cmd_remove_allowed "$@"; }

cmd_list_contacts() {
  local did="${1:-}"
  if [ -z "$did" ]; then
    err "Usage: manage.sh list-contacts <did>"
    exit 1
  fi
  did="$(echo "$did" | sed 's/[^0-9]//g')"

  local db_path; db_path="$(get_db_path)"
  if [ -z "$db_path" ]; then
    err "No database path configured"
    exit 1
  fi

  local did_cfg; did_cfg="$(get_did_config "$did")"
  if [ -z "$did_cfg" ]; then
    err "DID $did not configured"
    exit 1
  fi

  local table; table="$(echo "$did_cfg" | jq -r '.contactLookup.table // empty')"
  if [ -z "$table" ]; then
    err "No contact lookup table configured for DID $did"
    exit 1
  fi

  echo -e "${BOLD}Contacts in table '$table':${NC}"
  sqlite3 -header -column "$db_path" "SELECT * FROM $table ORDER BY 1;"
}

cmd_add_contact() {
  local did="${1:-}" phone="${2:-}"
  if [ -z "$did" ] || [ -z "$phone" ]; then
    err "Usage: manage.sh add-contact <did> <phone> [col=value ...]"
    exit 1
  fi
  did="$(echo "$did" | sed 's/[^0-9]//g')"
  phone="$(echo "$phone" | sed 's/[^0-9]//g')"
  shift 2

  local db_path; db_path="$(get_db_path)"
  local did_cfg; did_cfg="$(get_did_config "$did")"
  local table; table="$(echo "$did_cfg" | jq -r '.contactLookup.table // empty')"
  local phone_col; phone_col="$(echo "$did_cfg" | jq -r '.contactLookup.phoneColumn // "phone"')"

  if [ -z "$table" ]; then
    err "No contact lookup table configured for DID $did"
    exit 1
  fi

  local cols="$phone_col"
  local vals="'$phone'"

  for arg in "$@"; do
    local key="${arg%%=*}"
    local val="${arg#*=}"
    # Validate column name
    if [[ ! "$key" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]]; then
      err "Invalid column name: $key"
      exit 1
    fi
    cols="$cols, $key"
    vals="$vals, '$(echo "$val" | sed "s/'/''/g")'"
  done

  sqlite3 "$db_path" "INSERT OR REPLACE INTO $table ($cols) VALUES ($vals);"
  info "Contact $phone added to $table"
}

cmd_remove_contact() {
  local did="${1:-}" phone="${2:-}"
  if [ -z "$did" ] || [ -z "$phone" ]; then
    err "Usage: manage.sh remove-contact <did> <phone>"
    exit 1
  fi
  did="$(echo "$did" | sed 's/[^0-9]//g')"
  phone="$(echo "$phone" | sed 's/[^0-9]//g')"

  local db_path; db_path="$(get_db_path)"
  local did_cfg; did_cfg="$(get_did_config "$did")"
  local table; table="$(echo "$did_cfg" | jq -r '.contactLookup.table // empty')"
  local phone_col; phone_col="$(echo "$did_cfg" | jq -r '.contactLookup.phoneColumn // "phone"')"

  if [ -z "$table" ]; then
    err "No contact lookup table configured for DID $did"
    exit 1
  fi

  sqlite3 "$db_path" "DELETE FROM $table WHERE $phone_col = '$phone';"
  info "Contact $phone removed from $table"
}

cmd_test_webhook() {
  local port
  port="$(jq -r '.plugins.entries["voipms-sms"].config.webhookPort // 8089' "$CONFIG")"

  echo "Testing webhook on port $port..."
  local resp
  resp="$(curl -s -o /dev/null -w "%{http_code}" "http://localhost:$port/health" 2>/dev/null || echo "000")"

  if [ "$resp" = "200" ]; then
    info "Webhook is running (port $port, health check returned 200)"
  else
    err "Webhook not responding on port $port (HTTP $resp)"
  fi
}

cmd_check_health() {
  echo -e "${BOLD}Plugin Health Check${NC}"
  echo ""

  # Config
  local cfg; cfg="$(get_plugin_config)"
  if [ -z "$cfg" ]; then
    err "Plugin not configured in openclaw.json"
    return
  fi
  info "Plugin config found"

  # DB
  local db_path; db_path="$(get_db_path)"
  if [ -z "$db_path" ]; then
    err "No dbPath configured"
  elif [ ! -f "$db_path" ]; then
    err "Database not found: $db_path"
  else
    if sqlite3 "$db_path" "SELECT 1;" &>/dev/null; then
      info "Database accessible: $db_path"
    else
      err "Database not readable: $db_path"
    fi
  fi

  # API creds
  local user; user="$(echo "$cfg" | jq -r '.apiUsername // empty')"
  local pass; pass="$(echo "$cfg" | jq -r '.apiPassword // empty')"
  if [ -n "$user" ] && [ -n "$pass" ]; then
    info "API credentials configured"
  else
    warn "API credentials missing (check apiUsername/apiPassword or env vars)"
  fi

  # DIDs
  local did_count; did_count="$(echo "$cfg" | jq '.dids | length')"
  info "$did_count DID(s) configured"

  # Webhook
  local port; port="$(echo "$cfg" | jq -r '.webhookPort // 8089')"
  local resp
  resp="$(curl -s -o /dev/null -w "%{http_code}" "http://localhost:$port/health" 2>/dev/null || echo "000")"
  if [ "$resp" = "200" ]; then
    info "Webhook responding on port $port"
  else
    warn "Webhook not responding on port $port"
  fi

  # Bindings
  echo ""
  echo -e "${BOLD}Bindings:${NC}"
  jq -r '
    .bindings // [] | map(select(.match.channel == "voipms")) |
    .[] | "  DID \(.match.accountId) → agent \(.agentId)"
  ' "$CONFIG"
}

# ── Usage ─────────────────────────────────────────────────────────────────────

usage() {
  cat <<'EOF'
voipms-sms Plugin Manager

Usage: ./manage.sh [--config <path>] <command> [args...]

DID Management:
  list-dids                          List all configured DIDs
  add-did <did> <agent> [options]    Add a new DID configuration
    --label <label>                    Human-readable label
    --no-inbound                       Disable inbound SMS
    --no-outbound                      Disable outbound SMS
  remove-did <did>                   Remove a DID configuration
  show-config [did]                  Display config for a DID or all

Contact Management:
  list-contacts <did>                List contacts for a DID
  add-contact <did> <phone> [k=v]   Add a contact (e.g. name="John Doe")
  remove-contact <did> <phone>       Remove a contact

Access Control:
  set-access <did> <mode>            Set access mode (allow-all/block-all/whitelist/blacklist)
  add-allowed <did> <phone>          Add phone to whitelist/blacklist
  remove-allowed <did> <phone>       Remove phone from whitelist/blacklist
  add-blocked <did> <phone>          Alias for add-allowed
  remove-blocked <did> <phone>       Alias for remove-allowed

Features:
  set-feature <did> <feature> <bool> Enable/disable a feature for a DID
    Features: smsThreadLogging, languagePreferences, smsStitching,
              agentThreadAccess, agentCanAddContacts

Diagnostics:
  test-webhook                       Send a test request to the webhook
  check-health                       Check plugin health

Environment:
  OPENCLAW_CONFIG    Path to openclaw.json (or use --config)
EOF
}

# ── Main ──────────────────────────────────────────────────────────────────────

# Parse --config flag
COMMAND=""
ARGS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --config) CONFIG="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *)
      if [ -z "$COMMAND" ]; then
        COMMAND="$1"
      else
        ARGS+=("$1")
      fi
      shift
      ;;
  esac
done

if [ -z "$COMMAND" ]; then
  usage
  exit 0
fi

resolve_config

case "$COMMAND" in
  list-dids)       cmd_list_dids ;;
  add-did)         cmd_add_did "${ARGS[@]}" ;;
  remove-did)      cmd_remove_did "${ARGS[@]}" ;;
  show-config)     cmd_show_config "${ARGS[@]:-}" ;;
  set-feature)     cmd_set_feature "${ARGS[@]}" ;;
  set-access)      cmd_set_access "${ARGS[@]}" ;;
  add-allowed)     cmd_add_allowed "${ARGS[@]}" ;;
  remove-allowed)  cmd_remove_allowed "${ARGS[@]}" ;;
  add-blocked)     cmd_add_blocked "${ARGS[@]}" ;;
  remove-blocked)  cmd_remove_blocked "${ARGS[@]}" ;;
  list-contacts)   cmd_list_contacts "${ARGS[@]}" ;;
  add-contact)     cmd_add_contact "${ARGS[@]}" ;;
  remove-contact)  cmd_remove_contact "${ARGS[@]}" ;;
  test-webhook)    cmd_test_webhook ;;
  check-health)    cmd_check_health ;;
  *)               err "Unknown command: $COMMAND"; echo ""; usage; exit 1 ;;
esac
