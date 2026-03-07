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

cmd_set_agent() {
  local did="${1:-}" agent="${2:-}"
  if [ -z "$did" ] || [ -z "$agent" ]; then
    err "Usage: manage.sh set-agent <did> <agent-id>"
    exit 1
  fi
  did="$(echo "$did" | sed 's/[^0-9]//g')"

  backup_config
  local tmp; tmp="$(mktemp)"
  jq --arg did "$did" --arg agent "$agent" '
    .plugins.entries["voipms-sms"].config.dids[$did].agent = $agent |
    .bindings = [(.bindings // [])[] | select(.match.channel != "voipms" or .match.accountId != $did)] +
                [{ agentId: $agent, match: { channel: "voipms", accountId: $did } }]
  ' "$CONFIG" > "$tmp" && mv "$tmp" "$CONFIG"
  info "DID $did: agent = $agent (binding updated)"
}

cmd_set_label() {
  local did="${1:-}" label="${2:-}"
  if [ -z "$did" ] || [ -z "$label" ]; then
    err "Usage: manage.sh set-label <did> <label>"
    exit 1
  fi
  did="$(echo "$did" | sed 's/[^0-9]//g')"

  backup_config
  local tmp; tmp="$(mktemp)"
  jq --arg did "$did" --arg label "$label" '
    .plugins.entries["voipms-sms"].config.dids[$did].label = $label
  ' "$CONFIG" > "$tmp" && mv "$tmp" "$CONFIG"
  info "DID $did: label = $label"
}

cmd_set_inbound() {
  local did="${1:-}" value="${2:-}"
  if [ -z "$did" ] || [ -z "$value" ]; then
    err "Usage: manage.sh set-inbound <did> <true|false>"
    exit 1
  fi
  did="$(echo "$did" | sed 's/[^0-9]//g')"

  backup_config
  local tmp; tmp="$(mktemp)"
  jq --arg did "$did" --argjson val "$value" '
    .plugins.entries["voipms-sms"].config.dids[$did].inbound = $val
  ' "$CONFIG" > "$tmp" && mv "$tmp" "$CONFIG"
  info "DID $did: inbound = $value"
}

cmd_set_outbound() {
  local did="${1:-}" value="${2:-}"
  if [ -z "$did" ] || [ -z "$value" ]; then
    err "Usage: manage.sh set-outbound <did> <true|false>"
    exit 1
  fi
  did="$(echo "$did" | sed 's/[^0-9]//g')"

  backup_config
  local tmp; tmp="$(mktemp)"
  jq --arg did "$did" --argjson val "$value" '
    .plugins.entries["voipms-sms"].config.dids[$did].outbound = $val
  ' "$CONFIG" > "$tmp" && mv "$tmp" "$CONFIG"
  info "DID $did: outbound = $value"
}

cmd_set_contact_lookup() {
  local did="${1:-}" table="${2:-}" phone_col="${3:-phone}"
  if [ -z "$did" ] || [ -z "$table" ]; then
    err "Usage: manage.sh set-contact-lookup <did> <table> [phone-column]"
    exit 1
  fi
  did="$(echo "$did" | sed 's/[^0-9]//g')"

  backup_config
  local tmp; tmp="$(mktemp)"
  jq --arg did "$did" --arg table "$table" --arg col "$phone_col" '
    .plugins.entries["voipms-sms"].config.dids[$did].contactLookup = {
      table: $table,
      phoneColumn: $col
    }
  ' "$CONFIG" > "$tmp" && mv "$tmp" "$CONFIG"
  info "DID $did: contactLookup = $table (phone column: $phone_col)"
}

cmd_set_suppression() {
  local did="${1:-}" mode="${2:-}" action="${3:-silent}"
  if [ -z "$did" ] || [ -z "$mode" ]; then
    err "Usage: manage.sh set-suppression <did> <allow|suppress> [silent|reply]"
    exit 1
  fi
  did="$(echo "$did" | sed 's/[^0-9]//g')"

  backup_config
  local tmp; tmp="$(mktemp)"
  jq --arg did "$did" --arg mode "$mode" --arg action "$action" '
    .plugins.entries["voipms-sms"].config.dids[$did].suppression = {
      unknownContact: $mode,
      unknownContactAction: $action
    }
  ' "$CONFIG" > "$tmp" && mv "$tmp" "$CONFIG"
  info "DID $did: suppression = $mode (action: $action)"
}

cmd_set_webhook_port() {
  local port="${1:-}"
  if [ -z "$port" ]; then
    err "Usage: manage.sh set-webhook-port <port>"
    exit 1
  fi

  backup_config
  local tmp; tmp="$(mktemp)"
  jq --argjson port "$port" '
    .plugins.entries["voipms-sms"].config.webhookPort = $port
  ' "$CONFIG" > "$tmp" && mv "$tmp" "$CONFIG"
  info "Webhook port = $port"
}

cmd_set_db_path() {
  local path="${1:-}"
  if [ -z "$path" ]; then
    err "Usage: manage.sh set-db-path <path>"
    exit 1
  fi

  backup_config
  local tmp; tmp="$(mktemp)"
  jq --arg path "$path" '
    .plugins.entries["voipms-sms"].config.dbPath = $path
  ' "$CONFIG" > "$tmp" && mv "$tmp" "$CONFIG"
  info "Database path = $path"
}

cmd_list_bindings() {
  echo -e "${BOLD}voipms Bindings:${NC}"
  echo ""
  jq -r '
    .bindings // [] | map(select(.match.channel == "voipms")) |
    if length == 0 then "  (none)"
    else .[] | "  DID \(.match.accountId) → agent \(.agentId)"
    end
  ' "$CONFIG"
}

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

# ── Interactive UI Helpers ────────────────────────────────────────────────────

menu_header() {
  clear
  local title="$1"
  local w=$(( ${#title} + 4 ))
  local border; border="$(printf '═%.0s' $(seq 1 "$w"))"
  echo -e "${CYAN}╔${border}╗${NC}"
  echo -e "${CYAN}║${NC}  ${BOLD}${title}${NC}  ${CYAN}║${NC}"
  echo -e "${CYAN}╚${border}╝${NC}"
  echo ""
}

pick_option() {
  local prompt="${1:-Choice}"
  shift
  local options=("$@")
  local i=1
  for opt in "${options[@]}"; do
    echo -e "  ${BOLD}${i})${NC} ${opt}" >&2
    i=$((i + 1))
  done
  echo "" >&2
  local choice
  read -rp "  ${prompt} [1-${#options[@]}, q=back]: " choice </dev/tty
  echo "$choice"
}

pick_did() {
  local dids; dids="$(jq -r '.plugins.entries["voipms-sms"].config.dids // {} | keys[]' "$CONFIG" 2>/dev/null)"
  if [ -z "$dids" ]; then
    warn "No DIDs configured"
    return 1
  fi

  local arr=()
  while IFS= read -r d; do arr+=("$d"); done <<< "$dids"

  if [ "${#arr[@]}" -eq 1 ]; then
    echo "${arr[0]}"
    return 0
  fi

  echo "" >&2
  echo -e "  ${BOLD}Select a DID:${NC}" >&2
  local i=1
  for d in "${arr[@]}"; do
    local label; label="$(jq -r --arg d "$d" '.plugins.entries["voipms-sms"].config.dids[$d].label // $d' "$CONFIG")"
    local agent; agent="$(jq -r --arg d "$d" '.plugins.entries["voipms-sms"].config.dids[$d].agent // "?"' "$CONFIG")"
    echo -e "  ${BOLD}${i})${NC} ${d}  (${label}, agent: ${agent})" >&2
    i=$((i + 1))
  done
  echo "" >&2
  local choice
  read -rp "  DID [1-${#arr[@]}]: " choice </dev/tty
  if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#arr[@]}" ]; then
    echo "${arr[$((choice - 1))]}"
    return 0
  fi
  return 1
}

prompt_input() {
  local label="$1" default="${2:-}"
  local val
  if [ -n "$default" ]; then
    read -rp "  ${label} [${default}]: " val </dev/tty
    echo "${val:-$default}"
  else
    read -rp "  ${label}: " val </dev/tty
    echo "$val"
  fi
}

prompt_yn() {
  local msg="$1" default="${2:-y}"
  local val
  if [ "$default" = "y" ]; then
    read -rp "  ${msg} [Y/n]: " val </dev/tty
    [[ "${val,,}" != "n" ]]
  else
    read -rp "  ${msg} [y/N]: " val </dev/tty
    [[ "${val,,}" == "y" ]]
  fi
}

press_enter() {
  echo ""
  read -rp "  Press Enter to continue..." _ </dev/tty
}

# ── Interactive Wrappers ─────────────────────────────────────────────────────

interactive_add_did() {
  echo ""
  local did; did="$(prompt_input "DID number (digits only)")"
  if [ -z "$did" ]; then warn "Cancelled"; return; fi
  local agent; agent="$(prompt_input "Agent ID")"
  if [ -z "$agent" ]; then warn "Cancelled"; return; fi
  local label; label="$(prompt_input "Label (optional)" "$did")"

  local args=("$did" "$agent" "--label" "$label")
  if ! prompt_yn "Enable inbound?" "y"; then args+=("--no-inbound"); fi
  if ! prompt_yn "Enable outbound?" "y"; then args+=("--no-outbound"); fi

  echo ""
  cmd_add_did "${args[@]}"
}

interactive_remove_did() {
  local did; did="$(pick_did)"
  if [ -z "$did" ]; then return; fi
  echo ""
  if prompt_yn "Remove DID ${did}?" "n"; then
    cmd_remove_did "$did"
  else
    warn "Cancelled"
  fi
}

interactive_show_did_config() {
  local did; did="$(pick_did)"
  if [ -z "$did" ]; then return; fi
  echo ""
  cmd_show_config "$did"
}

interactive_add_contact() {
  local did="$1"
  echo ""
  local phone; phone="$(prompt_input "Phone number (digits only)")"
  if [ -z "$phone" ]; then warn "Cancelled"; return; fi

  local extra_args=("$did" "$phone")
  echo -e "  ${DIM}Enter column=value pairs (blank line to finish):${NC}"
  while true; do
    local kv; kv="$(prompt_input "  col=value (or blank)")"
    if [ -z "$kv" ]; then break; fi
    extra_args+=("$kv")
  done

  echo ""
  cmd_add_contact "${extra_args[@]}"
}

interactive_remove_contact() {
  local did="$1"
  echo ""
  local phone; phone="$(prompt_input "Phone number to remove")"
  if [ -z "$phone" ]; then warn "Cancelled"; return; fi
  if prompt_yn "Remove contact ${phone}?" "n"; then
    cmd_remove_contact "$did" "$phone"
  else
    warn "Cancelled"
  fi
}

interactive_set_access() {
  local did="$1"
  echo ""
  local modes=("allow-all" "block-all" "whitelist" "blacklist")
  echo -e "  ${BOLD}Access control modes:${NC}"
  local i=1
  for m in "${modes[@]}"; do
    echo -e "  ${BOLD}${i})${NC} ${m}"
    i=$((i + 1))
  done
  echo ""
  local choice
  read -rp "  Mode [1-4]: " choice
  if [[ "$choice" =~ ^[1-4]$ ]]; then
    cmd_set_access "$did" "${modes[$((choice - 1))]}"
  else
    warn "Invalid choice"
  fi
}

interactive_add_phone() {
  local did="$1"
  echo ""
  local phone; phone="$(prompt_input "Phone number to add")"
  if [ -z "$phone" ]; then warn "Cancelled"; return; fi
  cmd_add_allowed "$did" "$phone"
}

interactive_remove_phone() {
  local did="$1"
  echo ""
  local phone; phone="$(prompt_input "Phone number to remove")"
  if [ -z "$phone" ]; then warn "Cancelled"; return; fi
  if prompt_yn "Remove ${phone} from list?" "n"; then
    cmd_remove_allowed "$did" "$phone"
  else
    warn "Cancelled"
  fi
}

interactive_toggle_feature() {
  local did="$1" feature="$2"
  local current; current="$(jq -r --arg d "$did" --arg f "$feature" \
    '.plugins.entries["voipms-sms"].config.dids[$d].features[$f] // false' "$CONFIG")"
  if [ "$current" = "true" ]; then
    cmd_set_feature "$did" "$feature" "false"
  else
    cmd_set_feature "$did" "$feature" "true"
  fi
}

# New interactive wrappers for DID editing

interactive_set_agent() {
  local did="$1"
  echo ""
  local agent; agent="$(prompt_input "New agent ID")"
  if [ -z "$agent" ]; then warn "Cancelled"; return; fi
  cmd_set_agent "$did" "$agent"
}

interactive_set_label() {
  local did="$1"
  echo ""
  local label; label="$(prompt_input "New label")"
  if [ -z "$label" ]; then warn "Cancelled"; return; fi
  cmd_set_label "$did" "$label"
}

interactive_toggle_inbound() {
  local did="$1"
  local current; current="$(jq -r --arg d "$did" \
    '.plugins.entries["voipms-sms"].config.dids[$d].inbound // true' "$CONFIG")"
  if [ "$current" = "true" ]; then
    cmd_set_inbound "$did" "false"
  else
    cmd_set_inbound "$did" "true"
  fi
}

interactive_toggle_outbound() {
  local did="$1"
  local current; current="$(jq -r --arg d "$did" \
    '.plugins.entries["voipms-sms"].config.dids[$d].outbound // true' "$CONFIG")"
  if [ "$current" = "true" ]; then
    cmd_set_outbound "$did" "false"
  else
    cmd_set_outbound "$did" "true"
  fi
}

interactive_set_suppression() {
  local did="$1"
  echo ""
  local modes=("allow" "suppress")
  echo -e "  ${BOLD}Unknown contact behavior:${NC}"
  echo -e "  ${BOLD}1)${NC} allow   — dispatch to agent anyway"
  echo -e "  ${BOLD}2)${NC} suppress — block unknown contacts"
  echo ""
  local choice
  read -rp "  Mode [1-2]: " choice
  local mode=""
  case "$choice" in
    1) mode="allow" ;;
    2) mode="suppress" ;;
    *) warn "Invalid choice"; return ;;
  esac

  local action="silent"
  if [ "$mode" = "suppress" ]; then
    echo ""
    echo -e "  ${BOLD}Suppression action:${NC}"
    echo -e "  ${BOLD}1)${NC} silent — drop silently"
    echo -e "  ${BOLD}2)${NC} reply  — send auto-reply"
    echo ""
    read -rp "  Action [1-2]: " choice
    case "$choice" in
      1) action="silent" ;;
      2) action="reply" ;;
      *) warn "Invalid choice"; return ;;
    esac
  fi
  cmd_set_suppression "$did" "$mode" "$action"
}

interactive_set_contact_lookup() {
  local did="$1"
  echo ""
  local current_table; current_table="$(jq -r --arg d "$did" \
    '.plugins.entries["voipms-sms"].config.dids[$d].contactLookup.table // "(none)"' "$CONFIG")"
  local current_col; current_col="$(jq -r --arg d "$did" \
    '.plugins.entries["voipms-sms"].config.dids[$d].contactLookup.phoneColumn // "phone"' "$CONFIG")"
  echo -e "  Current: table=${BOLD}${current_table}${NC}  phoneColumn=${BOLD}${current_col}${NC}"
  echo ""
  local table; table="$(prompt_input "Table name")"
  if [ -z "$table" ]; then warn "Cancelled"; return; fi
  local col; col="$(prompt_input "Phone column" "$current_col")"
  cmd_set_contact_lookup "$did" "$table" "$col"
}

interactive_set_webhook_port() {
  echo ""
  local current; current="$(jq -r '.plugins.entries["voipms-sms"].config.webhookPort // 8089' "$CONFIG")"
  local port; port="$(prompt_input "Webhook port" "$current")"
  if [ -z "$port" ]; then warn "Cancelled"; return; fi
  cmd_set_webhook_port "$port"
}

interactive_set_db_path() {
  echo ""
  local current; current="$(get_db_path)"
  local path; path="$(prompt_input "Database path" "$current")"
  if [ -z "$path" ]; then warn "Cancelled"; return; fi
  cmd_set_db_path "$path"
}

# ── Menus ────────────────────────────────────────────────────────────────────

menu_dids() {
  while true; do
    menu_header "DID Management"
    cmd_list_dids 2>/dev/null || echo -e "  ${DIM}(no DIDs configured)${NC}"
    echo ""
    local choice; choice="$(pick_option "Action" "Add DID" "Edit DID" "Remove DID" "Show DID Config" "Back")"
    case "$choice" in
      1) interactive_add_did; press_enter ;;
      2) menu_edit_did ;;
      3) interactive_remove_did; press_enter ;;
      4) interactive_show_did_config; press_enter ;;
      5|q|Q) return ;;
      *) ;;
    esac
  done
}

menu_edit_did() {
  local did; did="$(pick_did)" || { press_enter; return; }
  while true; do
    menu_header "Edit DID ${did}"
    local agent; agent="$(jq -r --arg d "$did" '.plugins.entries["voipms-sms"].config.dids[$d].agent // "?"' "$CONFIG")"
    local label; label="$(jq -r --arg d "$did" '.plugins.entries["voipms-sms"].config.dids[$d].label // $d' "$CONFIG")"
    local inb; inb="$(jq -r --arg d "$did" '.plugins.entries["voipms-sms"].config.dids[$d].inbound // true' "$CONFIG")"
    local outb; outb="$(jq -r --arg d "$did" '.plugins.entries["voipms-sms"].config.dids[$d].outbound // true' "$CONFIG")"
    local supp_mode; supp_mode="$(jq -r --arg d "$did" '.plugins.entries["voipms-sms"].config.dids[$d].suppression.unknownContact // "allow"' "$CONFIG")"
    local supp_action; supp_action="$(jq -r --arg d "$did" '.plugins.entries["voipms-sms"].config.dids[$d].suppression.unknownContactAction // "silent"' "$CONFIG")"
    local ct_table; ct_table="$(jq -r --arg d "$did" '.plugins.entries["voipms-sms"].config.dids[$d].contactLookup.table // "(none)"' "$CONFIG")"

    local inb_tag; if [ "$inb" = "true" ]; then inb_tag="${GREEN}ON${NC}"; else inb_tag="${RED}OFF${NC}"; fi
    local outb_tag; if [ "$outb" = "true" ]; then outb_tag="${GREEN}ON${NC}"; else outb_tag="${RED}OFF${NC}"; fi

    echo -e "  Agent:        ${BOLD}${agent}${NC}"
    echo -e "  Label:        ${label}"
    echo -e "  Inbound:      ${inb_tag}"
    echo -e "  Outbound:     ${outb_tag}"
    echo -e "  Suppression:  ${supp_mode} (${supp_action})"
    echo -e "  Contact table: ${ct_table}"
    echo ""

    local choice; choice="$(pick_option "Edit" \
      "Change Agent" \
      "Change Label" \
      "Toggle Inbound" \
      "Toggle Outbound" \
      "Suppression Settings" \
      "Contact Lookup" \
      "Back")"
    case "$choice" in
      1) interactive_set_agent "$did"; press_enter ;;
      2) interactive_set_label "$did"; press_enter ;;
      3) interactive_toggle_inbound "$did" ;;
      4) interactive_toggle_outbound "$did" ;;
      5) interactive_set_suppression "$did"; press_enter ;;
      6) interactive_set_contact_lookup "$did"; press_enter ;;
      7|q|Q) return ;;
      *) ;;
    esac
  done
}

menu_contacts() {
  local did; did="$(pick_did)" || { press_enter; return; }
  while true; do
    menu_header "Contact Management — DID ${did}"
    local ct_table; ct_table="$(jq -r --arg d "$did" \
      '.plugins.entries["voipms-sms"].config.dids[$d].contactLookup.table // "(not configured)"' "$CONFIG")"
    echo -e "  ${DIM}Contact table: ${ct_table}${NC}"
    echo ""
    local choice; choice="$(pick_option "Action" "List Contacts" "Add Contact" "Remove Contact" "Configure Contact Lookup" "Back")"
    case "$choice" in
      1) echo ""; cmd_list_contacts "$did" 2>/dev/null || warn "Could not list contacts"; press_enter ;;
      2) interactive_add_contact "$did"; press_enter ;;
      3) interactive_remove_contact "$did"; press_enter ;;
      4) interactive_set_contact_lookup "$did"; press_enter ;;
      5|q|Q) return ;;
      *) ;;
    esac
  done
}

menu_access() {
  local did; did="$(pick_did)" || { press_enter; return; }
  while true; do
    menu_header "Access Control — DID ${did}"
    local mode; mode="$(jq -r --arg d "$did" \
      '.plugins.entries["voipms-sms"].config.dids[$d].accessControl.mode // "allow-all"' "$CONFIG")"
    local list; list="$(jq -r --arg d "$did" \
      '.plugins.entries["voipms-sms"].config.dids[$d].accessControl.list // [] | join(", ")' "$CONFIG")"
    local supp; supp="$(jq -r --arg d "$did" \
      '.plugins.entries["voipms-sms"].config.dids[$d].suppression.unknownContact // "allow"' "$CONFIG")"
    echo -e "  Access mode:  ${BOLD}${mode}${NC}"
    [ -n "$list" ] && echo -e "  Phone list:   ${list}"
    echo -e "  Suppression:  ${supp}"
    echo ""
    local choice; choice="$(pick_option "Action" "Set Access Mode" "Add Phone to List" "Remove Phone from List" "Suppression Settings" "Back")"
    case "$choice" in
      1) interactive_set_access "$did"; press_enter ;;
      2) interactive_add_phone "$did"; press_enter ;;
      3) interactive_remove_phone "$did"; press_enter ;;
      4) interactive_set_suppression "$did"; press_enter ;;
      5|q|Q) return ;;
      *) ;;
    esac
  done
}

menu_features() {
  local did; did="$(pick_did)" || { press_enter; return; }
  local features=("smsThreadLogging" "languagePreferences" "smsStitching" "agentThreadAccess" "agentCanAddContacts")
  while true; do
    menu_header "Features — DID ${did}"
    local i=1
    for f in "${features[@]}"; do
      local val; val="$(jq -r --arg d "$did" --arg f "$f" \
        '.plugins.entries["voipms-sms"].config.dids[$d].features[$f] // false' "$CONFIG")"
      local tag
      if [ "$val" = "true" ]; then tag="${GREEN}[ON]${NC}"; else tag="${RED}[OFF]${NC}"; fi
      echo -e "  ${BOLD}${i})${NC} ${f}  ${tag}"
      i=$((i + 1))
    done
    echo ""
    echo -e "  ${BOLD}0)${NC} Back"
    echo ""
    local choice
    read -rp "  Toggle [0-5]: " choice
    case "$choice" in
      0|q|Q) return ;;
      [1-5])
        interactive_toggle_feature "$did" "${features[$((choice - 1))]}"
        ;;
      *) ;;
    esac
  done
}

menu_diagnostics() {
  while true; do
    menu_header "Diagnostics"
    local choice; choice="$(pick_option "Action" "Check Health" "Test Webhook" "Back")"
    case "$choice" in
      1) echo ""; cmd_check_health; press_enter ;;
      2) echo ""; cmd_test_webhook; press_enter ;;
      3|q|Q) return ;;
      *) ;;
    esac
  done
}

menu_settings() {
  while true; do
    menu_header "Settings"
    local port; port="$(jq -r '.plugins.entries["voipms-sms"].config.webhookPort // 8089' "$CONFIG")"
    local db; db="$(get_db_path)"
    local user; user="$(jq -r '.plugins.entries["voipms-sms"].config.apiUsername // "(not set)"' "$CONFIG")"
    echo -e "  Webhook port: ${BOLD}${port}${NC}"
    echo -e "  Database:     ${BOLD}${db:-"(not set)"}${NC}"
    echo -e "  API username: ${BOLD}${user}${NC}"
    echo ""
    local choice; choice="$(pick_option "Action" "Set Webhook Port" "Set Database Path" "List Bindings" "Show Full Config" "Back")"
    case "$choice" in
      1) interactive_set_webhook_port; press_enter ;;
      2) interactive_set_db_path; press_enter ;;
      3) echo ""; cmd_list_bindings; press_enter ;;
      4) menu_header "Full Config"; cmd_show_config; press_enter ;;
      5|q|Q) return ;;
      *) ;;
    esac
  done
}

menu_main() {
  while true; do
    menu_header "voipms-sms Management Console"
    local choice; choice="$(pick_option "Menu" "DID Management" "Contact Management" "Access Control" "Features" "Diagnostics" "Settings" "Show Full Config")"
    case "$choice" in
      1) menu_dids ;;
      2) menu_contacts ;;
      3) menu_access ;;
      4) menu_features ;;
      5) menu_diagnostics ;;
      6) menu_settings ;;
      7) menu_header "Full Config"; cmd_show_config; press_enter ;;
      q|Q) echo ""; echo "Bye."; exit 0 ;;
      *) ;;
    esac
  done
}

# ── Usage ─────────────────────────────────────────────────────────────────────

usage() {
  cat <<'EOF'
voipms-sms Plugin Manager

Usage: ./manage.sh [--config <path>] <command> [args...]
       ./manage.sh                     Interactive mode (when run in a terminal)

DID Management:
  list-dids                          List all configured DIDs
  add-did <did> <agent> [options]    Add a new DID configuration
    --label <label>                    Human-readable label
    --no-inbound                       Disable inbound SMS
    --no-outbound                      Disable outbound SMS
  remove-did <did>                   Remove a DID configuration
  set-agent <did> <agent>            Change the agent for a DID (updates binding)
  set-label <did> <label>            Change the label for a DID
  set-inbound <did> <true|false>     Enable/disable inbound for a DID
  set-outbound <did> <true|false>    Enable/disable outbound for a DID
  show-config [did]                  Display config for a DID or all
  list-bindings                      List all voipms agent bindings

Contact Management:
  list-contacts <did>                List contacts for a DID
  add-contact <did> <phone> [k=v]   Add a contact (e.g. name="John Doe")
  remove-contact <did> <phone>       Remove a contact
  set-contact-lookup <did> <table> [col]  Set contact lookup table/column

Access Control:
  set-access <did> <mode>            Set access mode (allow-all/block-all/whitelist/blacklist)
  add-allowed <did> <phone>          Add phone to whitelist/blacklist
  remove-allowed <did> <phone>       Remove phone from whitelist/blacklist
  add-blocked <did> <phone>          Alias for add-allowed
  remove-blocked <did> <phone>       Alias for remove-allowed
  set-suppression <did> <mode> [act] Set suppression (allow|suppress) [silent|reply]

Features:
  set-feature <did> <feature> <bool> Enable/disable a feature for a DID
    Features: smsThreadLogging, languagePreferences, smsStitching,
              agentThreadAccess, agentCanAddContacts

Settings:
  set-webhook-port <port>            Set webhook listener port
  set-db-path <path>                 Set database file path

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

# If no command given and stdin is a terminal → interactive mode
if [ -z "$COMMAND" ] && [ -t 0 ]; then
  resolve_config
  menu_main
  exit 0
fi

if [ -z "$COMMAND" ]; then
  usage
  exit 0
fi

resolve_config

case "$COMMAND" in
  list-dids)          cmd_list_dids ;;
  add-did)            cmd_add_did "${ARGS[@]}" ;;
  remove-did)         cmd_remove_did "${ARGS[@]}" ;;
  set-agent)          cmd_set_agent "${ARGS[@]}" ;;
  set-label)          cmd_set_label "${ARGS[@]}" ;;
  set-inbound)        cmd_set_inbound "${ARGS[@]}" ;;
  set-outbound)       cmd_set_outbound "${ARGS[@]}" ;;
  show-config)        cmd_show_config "${ARGS[@]:-}" ;;
  list-bindings)      cmd_list_bindings ;;
  set-feature)        cmd_set_feature "${ARGS[@]}" ;;
  set-access)         cmd_set_access "${ARGS[@]}" ;;
  add-allowed)        cmd_add_allowed "${ARGS[@]}" ;;
  remove-allowed)     cmd_remove_allowed "${ARGS[@]}" ;;
  add-blocked)        cmd_add_blocked "${ARGS[@]}" ;;
  remove-blocked)     cmd_remove_blocked "${ARGS[@]}" ;;
  set-suppression)    cmd_set_suppression "${ARGS[@]}" ;;
  list-contacts)      cmd_list_contacts "${ARGS[@]}" ;;
  add-contact)        cmd_add_contact "${ARGS[@]}" ;;
  remove-contact)     cmd_remove_contact "${ARGS[@]}" ;;
  set-contact-lookup) cmd_set_contact_lookup "${ARGS[@]}" ;;
  set-webhook-port)   cmd_set_webhook_port "${ARGS[@]}" ;;
  set-db-path)        cmd_set_db_path "${ARGS[@]}" ;;
  test-webhook)       cmd_test_webhook ;;
  check-health)       cmd_check_health ;;
  *)                  err "Unknown command: $COMMAND"; echo ""; usage; exit 1 ;;
esac
