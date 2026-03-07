#!/usr/bin/env bash
set -euo pipefail

# ── voipms-sms Plugin Installer ──────────────────────────────────────────────
# Interactive setup for the voipms-sms OpenClaw channel plugin.
# Edits openclaw.json directly via jq. Backs up before any write.

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
err()   { echo -e "${RED}✗${NC} $*"; }
ask()   { echo -en "${CYAN}?${NC} $* "; }
header(){ echo -e "\n${BOLD}── $* ──${NC}\n"; }

# Collect config as we go
PLUGIN_PATH="$SCRIPT_DIR"
DB_PATH=""
WEBHOOK_PORT="8089"
API_USERNAME=""
API_PASSWORD=""
TIMEZONE="America/New_York"
OPENCLAW_JSON=""
CONTACT_TABLE=""
CONTACT_PHONE_COL="phone"
CONTACT_COLS=()
declare -A DIDS_JSON  # did → JSON object

# ── Prerequisites ─────────────────────────────────────────────────────────────

header "voipms-sms Plugin Installer"
echo "This installer will configure the voipms-sms plugin for OpenClaw."
echo ""

header "Step 1: Check Prerequisites"

# Node.js
if command -v node &>/dev/null; then
  NODE_VER="$(node --version)"
  NODE_MAJOR="$(echo "$NODE_VER" | sed 's/v//' | cut -d. -f1)"
  if [ "$NODE_MAJOR" -ge 18 ]; then
    info "Node.js $NODE_VER detected"
  else
    err "Node.js >= 18 required (found $NODE_VER)"
    exit 1
  fi
else
  err "Node.js not found. Please install Node.js >= 18."
  exit 1
fi

# npm
if command -v npm &>/dev/null; then
  info "npm $(npm --version) detected"
else
  err "npm not found. Please install npm."
  exit 1
fi

# SQLite3
if command -v sqlite3 &>/dev/null; then
  info "sqlite3 detected"
else
  warn "sqlite3 not found."
  ask "Install sqlite3? [Y/n]"
  read -r ans
  if [[ "${ans,,}" != "n" ]]; then
    if command -v apt-get &>/dev/null; then
      sudo apt-get install -y sqlite3
    elif command -v brew &>/dev/null; then
      brew install sqlite3
    elif command -v yum &>/dev/null; then
      sudo yum install -y sqlite
    else
      err "Cannot auto-install sqlite3. Please install manually."
      exit 1
    fi
    info "sqlite3 installed"
  else
    err "sqlite3 is required. Exiting."
    exit 1
  fi
fi

# jq
if command -v jq &>/dev/null; then
  info "jq detected"
else
  warn "jq not found."
  ask "Install jq? [Y/n]"
  read -r ans
  if [[ "${ans,,}" != "n" ]]; then
    if command -v apt-get &>/dev/null; then
      sudo apt-get install -y jq
    elif command -v brew &>/dev/null; then
      brew install jq
    elif command -v yum &>/dev/null; then
      sudo yum install -y jq
    else
      err "Cannot auto-install jq. Please install manually."
      exit 1
    fi
    info "jq installed"
  else
    err "jq is required. Exiting."
    exit 1
  fi
fi

# ── npm install ───────────────────────────────────────────────────────────────

header "Step 2: Install npm Dependencies"
echo "Running npm install in $PLUGIN_PATH ..."
(cd "$PLUGIN_PATH" && npm install --production)
info "npm dependencies installed"

# ── Database Setup ────────────────────────────────────────────────────────────

header "Step 3: Database Setup"
echo "The plugin needs a SQLite database to store SMS threads and contacts."
echo ""
ask "Full path to database FILE (e.g. ~/.openclaw/shared/sms.db):"
read -r DB_PATH

if [ -z "$DB_PATH" ]; then
  err "Database path is required. Exiting."
  exit 1
fi

# Expand ~ if present
DB_PATH="${DB_PATH/#\~/$HOME}"

# Must end in a filename, not a bare directory
if [ -d "$DB_PATH" ]; then
  err "That path is an existing directory. Please provide a file path (e.g. ${DB_PATH}/sms.db)."
  exit 1
fi

# Warn if path has no file extension (likely a mistake)
if [[ "$(basename "$DB_PATH")" != *.* ]]; then
  warn "Path has no file extension — did you mean ${DB_PATH}.db or ${DB_PATH}/sms.db?"
  ask "Continue with '$DB_PATH' as a file? [y/N]"
  read -r ans
  if [[ "${ans,,}" != "y" ]]; then
    err "Aborted. Re-run and provide a path ending in .db (e.g. ~/.openclaw/shared/sms.db)."
    exit 1
  fi
fi

if [ -f "$DB_PATH" ]; then
  info "Using existing database: $DB_PATH"
else
  ask "Database does not exist. Create it? [Y/n]"
  read -r ans
  if [[ "${ans,,}" != "n" ]]; then
    mkdir -p "$(dirname "$DB_PATH")"
    sqlite3 "$DB_PATH" "PRAGMA journal_mode=WAL; SELECT 1;" >/dev/null
    info "Created database: $DB_PATH"
  else
    err "Database is required. Exiting."
    exit 1
  fi
fi

# ── Contact Table Setup ──────────────────────────────────────────────────────

header "Step 4: Contact Table Setup (Optional)"
ask "Set up a contact lookup table? [y/N]"
read -r ans

if [[ "${ans,,}" == "y" ]]; then
  ask "Table name [contacts]:"
  read -r CONTACT_TABLE
  CONTACT_TABLE="${CONTACT_TABLE:-contacts}"

  ask "Phone column name [phone]:"
  read -r CONTACT_PHONE_COL
  CONTACT_PHONE_COL="${CONTACT_PHONE_COL:-phone}"

  echo "Enter additional columns (comma-separated, e.g. name,email,notes):"
  ask "Columns [name]:"
  read -r cols_input
  cols_input="${cols_input:-name}"
  IFS=',' read -ra CONTACT_COLS <<< "$cols_input"

  # Build CREATE TABLE SQL
  col_defs="$CONTACT_PHONE_COL TEXT PRIMARY KEY"
  for col in "${CONTACT_COLS[@]}"; do
    col="$(echo "$col" | xargs)"  # trim whitespace
    col_defs="$col_defs, $col TEXT"
  done

  # Check if table already exists
  existing="$(sqlite3 "$DB_PATH" "SELECT name FROM sqlite_master WHERE type='table' AND name='$CONTACT_TABLE';" 2>/dev/null || true)"
  if [ -n "$existing" ]; then
    info "Table '$CONTACT_TABLE' already exists — skipping creation"
  else
    sqlite3 "$DB_PATH" "CREATE TABLE $CONTACT_TABLE ($col_defs);"
    info "Created table '$CONTACT_TABLE' with columns: $CONTACT_PHONE_COL, ${CONTACT_COLS[*]}"
  fi

  # Optionally add contacts
  while true; do
    ask "Add a contact now? [y/N]"
    read -r ans
    [[ "${ans,,}" != "y" ]] && break

    ask "Phone number (10 digits):"
    read -r c_phone
    c_phone="$(echo "$c_phone" | sed 's/[^0-9]//g')"

    col_names="$CONTACT_PHONE_COL"
    col_vals="'$c_phone'"
    for col in "${CONTACT_COLS[@]}"; do
      col="$(echo "$col" | xargs)"
      ask "$col:"
      read -r c_val
      col_names="$col_names, $col"
      col_vals="$col_vals, '$(echo "$c_val" | sed "s/'/''/g")'"
    done

    sqlite3 "$DB_PATH" "INSERT OR REPLACE INTO $CONTACT_TABLE ($col_names) VALUES ($col_vals);"
    info "Added contact: $c_phone"
  done
fi

# ── voip.ms API Credentials ──────────────────────────────────────────────────

header "Step 5: voip.ms API Credentials"

ask "API username (email):"
read -r API_USERNAME

ask "API password:"
read -rs API_PASSWORD
echo ""

if [ -n "$API_USERNAME" ] && [ -n "$API_PASSWORD" ]; then
  info "API credentials recorded"
else
  warn "API credentials empty — outbound SMS and stitching will not work until configured"
fi

# ── Webhook Port ──────────────────────────────────────────────────────────────

ask "Webhook port [8089]:"
read -r port_input
WEBHOOK_PORT="${port_input:-8089}"

# ── Timezone ──────────────────────────────────────────────────────────────────

ask "Timezone (IANA format) [America/New_York]:"
read -r tz_input
TIMEZONE="${tz_input:-America/New_York}"

# ── DID Configuration ────────────────────────────────────────────────────────

header "Step 6: DID Configuration"
echo "Configure the DIDs (phone numbers) this plugin will handle."
echo ""

DID_COUNT=0
declare -A DID_AGENTS

while true; do
  ask "Add a DID? [Y/n]"
  read -r ans
  [[ "${ans,,}" == "n" ]] && break

  ask "DID phone number (10 digits):"
  read -r did_num
  did_num="$(echo "$did_num" | sed 's/[^0-9]//g')"
  if [ "${#did_num}" -ne 10 ]; then
    err "DID must be exactly 10 digits. Skipping."
    continue
  fi

  ask "Label [${did_num}]:"
  read -r did_label
  did_label="${did_label:-$did_num}"

  ask "Agent ID (e.g. support-agent):"
  read -r did_agent
  if [ -z "$did_agent" ]; then
    err "Agent ID is required. Skipping this DID."
    continue
  fi
  DID_AGENTS["$did_num"]="$did_agent"

  ask "Accept inbound SMS? [Y/n]:"
  read -r did_inbound
  [[ "${did_inbound,,}" == "n" ]] && did_inbound="false" || did_inbound="true"

  ask "Allow outbound SMS? [Y/n]:"
  read -r did_outbound
  [[ "${did_outbound,,}" == "n" ]] && did_outbound="false" || did_outbound="true"

  # Access control
  echo "  Access control modes: allow-all, block-all, whitelist, blacklist"
  ask "Access control mode [allow-all]:"
  read -r ac_mode
  ac_mode="${ac_mode:-allow-all}"

  ac_list="[]"
  if [[ "$ac_mode" == "whitelist" || "$ac_mode" == "blacklist" ]]; then
    echo "  Enter phone numbers (comma-separated):"
    ask "Phone numbers:"
    read -r ac_phones
    ac_list="$(echo "$ac_phones" | jq -R 'split(",") | map(gsub("[^0-9]";"") | select(length > 0))')"
  fi

  # Contact lookup
  cl_json="null"
  if [ -n "$CONTACT_TABLE" ]; then
    ask "Use contact table '$CONTACT_TABLE' for this DID? [Y/n]:"
    read -r use_cl
    if [[ "${use_cl,,}" != "n" ]]; then
      # Build selectColumns
      select_cols="$(printf '%s\n' "${CONTACT_COLS[@]}" | jq -R . | jq -s .)"

      ask "Display name column [name]:"
      read -r display_name
      display_name="${display_name:-name}"

      ask "Language column (leave empty for none):"
      read -r lang_col

      cl_json="$(jq -n \
        --arg table "$CONTACT_TABLE" \
        --arg phoneCol "$CONTACT_PHONE_COL" \
        --argjson selectCols "$select_cols" \
        --arg displayName "$display_name" \
        --arg langCol "$lang_col" \
        '{
          table: $table,
          phoneColumn: $phoneCol,
          phoneMatch: "like",
          selectColumns: $selectCols,
          displayName: $displayName
        } + (if $langCol != "" then { languageColumn: $langCol } else {} end)'
      )"
    fi
  fi

  # Features
  echo "  Features (press Enter for default):"

  ask "SMS thread logging? [Y/n]:"
  read -r f_thread
  [[ "${f_thread,,}" == "n" ]] && f_thread="false" || f_thread="true"

  ask "Language preferences? [Y/n]:"
  read -r f_lang
  [[ "${f_lang,,}" == "n" ]] && f_lang="false" || f_lang="true"

  ask "SMS stitching? [Y/n]:"
  read -r f_stitch
  [[ "${f_stitch,,}" == "n" ]] && f_stitch="false" || f_stitch="true"

  ask "Agent thread access? [y/N]:"
  read -r f_threadaccess
  [[ "${f_threadaccess,,}" == "y" ]] && f_threadaccess="true" || f_threadaccess="false"

  ask "Agent can add contacts? [y/N]:"
  read -r f_addcontact
  [[ "${f_addcontact,,}" == "y" ]] && f_addcontact="true" || f_addcontact="false"

  # Suppression
  ask "Suppress unknown contacts? [y/N]:"
  read -r supp_unknown
  if [[ "${supp_unknown,,}" == "y" ]]; then
    supp_unknown="suppress"
    ask "Log suppressed messages? [y/N]:"
    read -r supp_log
    [[ "${supp_log,,}" == "y" ]] && supp_action="log" || supp_action="silent"
  else
    supp_unknown="allow"
    supp_action="silent"
  fi

  # Build DID JSON
  did_json="$(jq -n \
    --arg label "$did_label" \
    --arg agent "$did_agent" \
    --argjson inbound "$did_inbound" \
    --argjson outbound "$did_outbound" \
    --arg acMode "$ac_mode" \
    --argjson acList "$ac_list" \
    --argjson contactLookup "$cl_json" \
    --argjson threadLog "$f_thread" \
    --argjson langPref "$f_lang" \
    --argjson stitch "$f_stitch" \
    --argjson threadAccess "$f_threadaccess" \
    --argjson addContact "$f_addcontact" \
    --arg suppUnknown "$supp_unknown" \
    --arg suppAction "$supp_action" \
    '{
      label: $label,
      agent: $agent,
      inbound: $inbound,
      outbound: $outbound,
      features: {
        smsThreadLogging: $threadLog,
        languagePreferences: $langPref,
        smsStitching: $stitch,
        agentThreadAccess: $threadAccess,
        agentCanAddContacts: $addContact
      },
      accessControl: {
        mode: $acMode,
        list: $acList
      },
      contactLookup: $contactLookup,
      suppression: {
        unknownContact: $suppUnknown,
        unknownContactAction: $suppAction
      }
    }'
  )"

  DIDS_JSON["$did_num"]="$did_json"
  DID_COUNT=$((DID_COUNT + 1))
  info "DID $did_num configured (agent: $did_agent)"
  echo ""
done

if [ "$DID_COUNT" -eq 0 ]; then
  err "At least one DID is required. Exiting."
  exit 1
fi

# ── Build full dids config object ─────────────────────────────────────────────
DIDS_OBJ="{}"
for did_num in "${!DIDS_JSON[@]}"; do
  DIDS_OBJ="$(echo "$DIDS_OBJ" | jq --arg did "$did_num" --argjson cfg "${DIDS_JSON[$did_num]}" '. + {($did): $cfg}')"
done

# ── Write to openclaw.json ───────────────────────────────────────────────────

header "Step 7: Update openclaw.json"

ask "Path to openclaw.json [~/.openclaw/openclaw.json]:"
read -r oc_path
OPENCLAW_JSON="${oc_path:-$HOME/.openclaw/openclaw.json}"
OPENCLAW_JSON="${OPENCLAW_JSON/#\~/$HOME}"

if [ ! -f "$OPENCLAW_JSON" ]; then
  err "openclaw.json not found at $OPENCLAW_JSON. Exiting."
  exit 1
fi

# Backup
cp "$OPENCLAW_JSON" "${OPENCLAW_JSON}.bak"
info "Backed up to ${OPENCLAW_JSON}.bak"

# Build plugin config
PLUGIN_CONFIG="$(jq -n \
  --arg dbPath "$DB_PATH" \
  --argjson port "$WEBHOOK_PORT" \
  --arg apiUsername "$API_USERNAME" \
  --arg apiPassword "$API_PASSWORD" \
  --arg timezone "$TIMEZONE" \
  --argjson dids "$DIDS_OBJ" \
  '{
    dbPath: $dbPath,
    webhookPort: $port,
    apiUsername: $apiUsername,
    apiPassword: $apiPassword,
    timezone: $timezone,
    dids: $dids
  }'
)"

# Update openclaw.json
TMPFILE="$(mktemp)"

jq --arg pluginPath "$PLUGIN_PATH" \
   --argjson pluginConfig "$PLUGIN_CONFIG" \
   '
  # Ensure plugins structure exists
  .plugins //= {} |
  .plugins.allow //= [] |
  .plugins.load //= {} |
  .plugins.load.paths //= [] |
  .plugins.entries //= {} |

  # Add to allow list if not present
  (if (.plugins.allow | index("voipms-sms")) then . else .plugins.allow += ["voipms-sms"] end) |

  # Add plugin path if not present
  (if (.plugins.load.paths | index($pluginPath)) then . else .plugins.load.paths += [$pluginPath] end) |

  # Set plugin config
  .plugins.entries["voipms-sms"] = {
    enabled: true,
    config: $pluginConfig
  }
' "$OPENCLAW_JSON" > "$TMPFILE" && mv "$TMPFILE" "$OPENCLAW_JSON"

info "Plugin config written to openclaw.json"

# Add bindings for each DID
for did_num in "${!DID_AGENTS[@]}"; do
  agent="${DID_AGENTS[$did_num]}"

  TMPFILE="$(mktemp)"
  jq --arg agent "$agent" --arg did "$did_num" '
    .bindings //= [] |
    # Remove any existing binding for this channel+accountId
    .bindings = [.bindings[] | select(.match.channel != "voipms" or .match.accountId != $did)] |
    # Add the new binding
    .bindings += [{ agentId: $agent, match: { channel: "voipms", accountId: $did } }]
  ' "$OPENCLAW_JSON" > "$TMPFILE" && mv "$TMPFILE" "$OPENCLAW_JSON"
  info "Binding added: DID $did_num → agent $agent"
done

# Add session reset config
TMPFILE="$(mktemp)"
jq '
  .session //= {} |
  .session.resetByChannel //= {} |
  .session.resetByChannel["voipms-sms"] //= { mode: "idle", idleMinutes: 30 }
' "$OPENCLAW_JSON" > "$TMPFILE" && mv "$TMPFILE" "$OPENCLAW_JSON"

info "Session reset config added"

# ── Webhook URL ──────────────────────────────────────────────────────────────

header "Step 8: voip.ms Webhook URL"
echo ""
echo -e "  Configure this URL in your voip.ms control panel:"
echo ""
HOSTNAME="$(hostname -I 2>/dev/null | awk '{print $1}' || echo '<your-server-ip>')"
echo -e "  ${BOLD}http://${HOSTNAME}:${WEBHOOK_PORT}/${NC}"
echo ""
echo "  (voip.ms → Main Menu → DID Numbers → Manage DIDs → Edit → SMS/MMS URL)"
echo ""

# ── Generate TOOLS.md patches ────────────────────────────────────────────────

header "Step 9: Agent TOOLS.md Sections"
echo ""

TOOLS_GEN="$PLUGIN_PATH/TOOLS.md.generated"
> "$TOOLS_GEN"

for did_num in "${!DID_AGENTS[@]}"; do
  agent="${DID_AGENTS[$did_num]}"
  did_label="$(echo "${DIDS_JSON[$did_num]}" | jq -r '.label')"

  cat >> "$TOOLS_GEN" <<TOOLSEOF

## Agent: ${agent} — DID ${did_num} (${did_label})

### SMS (voipms-sms plugin)

This agent handles SMS messages on DID ${did_num} (${did_label}) via the voipms-sms plugin.

**Sending SMS:**
- To reply to the current contact: use \`message(action="send")\` with no target
- To message a new contact: use \`message(action="send", target="PHONE_NUMBER")\` with a 10-digit phone number
- Messages ≤160 chars are sent as SMS; longer messages are sent as MMS automatically

TOOLSEOF

  info "TOOLS.md section generated for agent $agent (DID $did_num)"
done

echo ""
echo "  Generated TOOLS.md sections saved to:"
echo "  $TOOLS_GEN"
echo ""
echo "  Copy the relevant section into each agent's workspace TOOLS.md file."

# ── Done ──────────────────────────────────────────────────────────────────────

header "Installation Complete"
echo ""
info "Plugin path: $PLUGIN_PATH"
info "Database: $DB_PATH"
info "Webhook port: $WEBHOOK_PORT"
info "DIDs configured: $DID_COUNT"
echo ""
echo "  Restart OpenClaw to activate the plugin."
echo ""
