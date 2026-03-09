# VoIP.ms SMS

**OpenClaw Channel Plugin** | v2.1.1 | SQLite

SMS channel plugin for voip.ms with per-DID routing, access control, contact enrichment, SMS stitching, thread logging, language preference tracking, and feature toggles.

---

## Features

- **Per-DID routing** — each phone number maps to a specific agent
- **Access control** — allow-all, block-all, whitelist, or blacklist per DID
- **Contact enrichment** — lookup contacts from any SQLite table with configurable columns
- **SMS stitching** — reassemble multi-segment messages via voip.ms API
- **Thread logging** — full inbound/outbound SMS history in SQLite
- **Language preferences** — track per-contact language from contact records
- **Unknown contact suppression** — allow, suppress (with optional logging)
- **Feature toggles** — enable/disable capabilities per DID independently
- **Agent tools** — optional `sms_read_threads` and `sms_add_contact` tools per DID
- **Auto SMS/MMS** — messages >160 chars automatically sent as MMS

---

## Architecture

```
voipms-sms/
├── index.js              # Plugin entry: all SMS logic
├── openclaw.plugin.json  # Manifest & config schema
├── package.json          # sqlite3 dependency
├── remote-install.sh     # curl-based remote installer/upgrader
├── install.sh            # Interactive local installer
├── manage.sh             # Management CLI (40+ commands, TUI menu)
└── TOOLS.md              # Agent tool documentation
```

---

## Installation

### Remote Install (recommended)

```bash
curl -fsSL https://raw.githubusercontent.com/DJTSmith18/openclaw-voipms-sms/main/remote-install.sh | bash
```

This clones the repo into `~/.openclaw/extensions/voipms-sms`, installs dependencies, and verifies the plugin. Run the same command again to upgrade to the latest version.

Options:

```bash
# Custom install directory
curl -fsSL ... | bash -s -- --dir /custom/path

# Specific branch
curl -fsSL ... | bash -s -- --branch develop
```

### Local Install

```bash
cd ~/.openclaw/extensions/voipms-sms
bash install.sh
```

The interactive installer walks through:
1. Prerequisites check (Node.js 18+, npm, sqlite3, jq)
2. npm install
3. SQLite database setup (WAL mode, foreign keys)
4. Optional contact table creation with custom columns
5. voip.ms API credentials
6. Webhook port (default 8089)
7. Timezone (default America/New_York)
8. Per-DID configuration loop (agent, features, access control, contact lookup)
9. Plugin registration in `openclaw.json` with agent bindings

---

## Configuration

```json
{
  "dbPath": "/path/to/sms.db",
  "webhookPort": 8089,
  "apiUsername": "user@email.com",
  "apiPassword": "api-password",
  "timezone": "America/New_York",
  "dids": {
    "5551234567": {
      "label": "Main Line",
      "agent": "receptionist",
      "inbound": true,
      "outbound": true,
      "features": {
        "smsThreadLogging": true,
        "languagePreferences": true,
        "smsStitching": true,
        "agentThreadAccess": false,
        "agentCanAddContacts": false,
        "includeLastMessage": false
      },
      "accessControl": {
        "mode": "allow-all",
        "list": []
      },
      "contactLookup": {
        "table": "contacts",
        "phoneColumn": "phone",
        "phoneMatch": "like",
        "selectColumns": ["name", "email", "notes"],
        "displayName": "name",
        "bodyFields": {
          "Email": "email",
          "Role": "'customer'",
          "License": ["license_number", "license_state"]
        },
        "languageColumn": "preferred_language"
      },
      "suppression": {
        "unknownContact": "allow",
        "unknownContactAction": "silent"
      }
    }
  }
}
```

---

## Inbound SMS Flow

1. **Webhook receives SMS** on port 8089 (GET or POST from voip.ms)
2. **Access control** — check whitelist/blacklist before any processing
3. **Deduplication** — skip already-processed SMS IDs
4. **SMS stitching** (if enabled) — call voip.ms API to reassemble multi-segment messages within 180-second window (up to 3 segments)
5. **Contact enrichment** (if configured) — lookup contact in SQLite table, extract display name, language, custom fields
6. **Unknown contact check** — suppress or allow based on config
7. **Language preference** (if enabled) — upsert to `sms_language_preferences` table
8. **Thread logging** (if enabled) — insert to `sms_threads` table
9. **Per-contact serialization** — lock by `did:phone` to prevent race conditions
10. **Agent dispatch** — build message context, deliver to assigned agent

### Agent Message Format

```
SMS from John Smith (5551234567)
Email: john@example.com | Role: customer
Current Date and Time: 03/07/2026 14:30
Last message (Agent): Sure, I can help with that!
Message: Hello, I need help with...
```

The `Last message` line only appears when `includeLastMessage` is enabled and there is a previous message in the thread.

---

## Outbound SMS

- Messages ≤160 chars → SMS (`sendSMS` method)
- Messages >160 chars → MMS (`sendMMS` method)
- Thread logged if `smsThreadLogging` enabled
- Respects per-DID `outbound` toggle

---

## Agent Tools

### `sms_read_threads`
*Available when `agentThreadAccess: true`*

Read SMS thread history for a phone number on a specific DID.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `did` | string | yes | DID number to read threads for |
| `phone` | string | no | Phone number (defaults to current session) |
| `limit` | number | no | Max messages (default 20, max 100) |

### `sms_add_contact`
*Available when `agentCanAddContacts: true` AND `contactLookup` configured*

Add or update a contact in the lookup table.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `did` | string | yes | DID whose contact table to modify |
| `phone` | string | yes | Phone number |
| *columns* | string | no | Any column from `selectColumns` |

Uses INSERT OR REPLACE (upsert on phone number).

---

## Feature Toggles (per DID)

| Feature | Default | Description |
|---------|---------|-------------|
| `smsThreadLogging` | true | Log all inbound/outbound to `sms_threads` table |
| `languagePreferences` | true | Track per-contact language in `sms_language_preferences` |
| `smsStitching` | true | Reassemble multi-segment SMS via voip.ms API |
| `agentThreadAccess` | false | Enable `sms_read_threads` tool for agent |
| `agentCanAddContacts` | false | Enable `sms_add_contact` tool for agent |
| `includeLastMessage` | false | Include previous message in inbound SMS context (requires `smsThreadLogging`) |

---

## Access Control Modes

| Mode | Behavior |
|------|----------|
| `allow-all` | All phone numbers accepted |
| `block-all` | All phone numbers blocked |
| `whitelist` | Only numbers in list accepted |
| `blacklist` | All except numbers in list accepted |

Phone numbers normalized to last 10 digits for matching.

---

## Contact Enrichment

### bodyFields Format

```json
{
  "Email": "email",                        // Column reference
  "Role": "'customer'",                    // Literal string (single quotes)
  "License": ["license_number", "state"]   // Array of columns joined with space
}
```

### phoneMatch Modes

- `"like"` (default) — substring match (`LIKE %phone%`)
- `"exact"` — exact match

---

## Database Tables (auto-created)

### `sms_threads`
```sql
id           INTEGER PRIMARY KEY AUTOINCREMENT
phone_number TEXT NOT NULL
did          TEXT NOT NULL
agent        TEXT NOT NULL
direction    TEXT NOT NULL      -- 'inbound' or 'outbound'
message      TEXT NOT NULL
context      TEXT
created_at   TEXT DEFAULT (datetime('now'))
```

### `sms_language_preferences`
```sql
phone_number       TEXT PRIMARY KEY
preferred_language TEXT NOT NULL
updated_at         TEXT NOT NULL
```

---

## Management CLI

Interactive TUI menu when run without arguments, or CLI mode:

```bash
# DID Management
./manage.sh list-dids
./manage.sh add-did <did> <agent> [--label <label>] [--no-inbound] [--no-outbound]
./manage.sh remove-did <did>
./manage.sh set-agent <did> <agent>
./manage.sh set-inbound <did> true|false
./manage.sh set-outbound <did> true|false

# Contact Management
./manage.sh list-contacts <did>
./manage.sh add-contact <did> <phone> [key=value ...]
./manage.sh remove-contact <did> <phone>

# Access Control
./manage.sh set-access <did> allow-all|block-all|whitelist|blacklist
./manage.sh add-allowed <did> <phone>
./manage.sh remove-allowed <did> <phone>
./manage.sh set-suppression <did> allow|suppress [silent|log]

# Features
./manage.sh set-feature <did> <feature> true|false

# Settings
./manage.sh set-webhook-port <port>
./manage.sh set-db-path <path>

# Diagnostics
./manage.sh test-webhook
./manage.sh check-health
./manage.sh show-config [did]
./manage.sh list-bindings
```

---

## Requirements

- Node.js 18+
- npm
- sqlite3
- jq (for installer)
- voip.ms account with API access (for outbound/stitching)
