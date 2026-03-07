# voipms-sms — OpenClaw Channel Plugin

SMS channel plugin for [voip.ms](https://voip.ms) — per-DID routing, access control, contact enrichment, and feature toggles.

## Installation

### Quick Start

```bash
cd /path/to/extensions/voipms-sms
./install.sh
```

The interactive installer will:
1. Check prerequisites (Node.js >= 18, sqlite3, npm, jq)
2. Install npm dependencies
3. Set up or connect to a SQLite database
4. Configure DIDs and features
5. Write config to your `openclaw.json`

### Manual Setup

1. Install dependencies:
   ```bash
   cd /path/to/extensions/voipms-sms
   npm install --production
   ```

2. Add the plugin to your `openclaw.json` (see Configuration below)

3. Restart OpenClaw

---

## Configuration

The plugin is configured in three places within `openclaw.json`:

### A. Plugin Registration

```json
{
  "plugins": {
    "allow": ["voipms-sms"],
    "load": {
      "paths": ["/path/to/extensions/voipms-sms"]
    },
    "entries": {
      "voipms-sms": {
        "enabled": true,
        "config": {
          "dbPath": "/path/to/sms.db",
          "webhookPort": 8089,
          "apiUsername": "user@example.com",
          "apiPassword": "your-api-password",
          "timezone": "America/New_York",
          "dids": { ... }
        }
      }
    }
  }
}
```

### B. Agent Bindings (one per DID)

```json
{
  "bindings": [
    { "agentId": "support-agent", "match": { "channel": "voipms", "accountId": "5551234567" } },
    { "agentId": "vip-handler",   "match": { "channel": "voipms", "accountId": "5559876543" } }
  ]
}
```

### C. Session Reset (optional)

```json
{
  "session": {
    "resetByChannel": {
      "voipms-sms": { "mode": "idle", "idleMinutes": 30 }
    }
  }
}
```

---

## DID Configuration

Each DID is configured as a key in `plugins.entries.voipms-sms.config.dids`:

### Minimal Example

```json
{
  "dids": {
    "5551234567": {
      "agent": "support-agent"
    }
  }
}
```

All other fields use sensible defaults (inbound: true, outbound: true, allow-all access, etc).

### Full-Featured Example

```json
{
  "dids": {
    "5551234567": {
      "label": "Support Line",
      "agent": "support-agent",
      "inbound": true,
      "outbound": true,

      "features": {
        "smsThreadLogging": true,
        "languagePreferences": true,
        "smsStitching": true,
        "agentThreadAccess": true,
        "agentCanAddContacts": true
      },

      "accessControl": {
        "mode": "allow-all",
        "list": []
      },

      "contactLookup": {
        "table": "contacts",
        "phoneColumn": "phone",
        "phoneMatch": "like",
        "selectColumns": ["id", "name", "email"],
        "displayName": "name",
        "bodyFields": {
          "Role": "'customer'",
          "Email": "email"
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

### Per-DID Fields

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `label` | string | DID number | Human-readable name |
| `agent` | string | **required** | Agent ID that handles this DID |
| `inbound` | bool | `true` | Accept inbound SMS |
| `outbound` | bool | `true` | Allow outbound SMS |
| `features.smsThreadLogging` | bool | `true` | Log messages to `sms_threads` table |
| `features.languagePreferences` | bool | `true` | Save/track language preferences |
| `features.smsStitching` | bool | `true` | Stitch multi-segment SMS via API |
| `features.agentThreadAccess` | bool | `false` | Agent can read SMS thread history via tool |
| `features.agentCanAddContacts` | bool | `false` | Agent can add/update contacts via tool |
| `accessControl.mode` | string | `allow-all` | `allow-all`, `block-all`, `whitelist`, `blacklist` |
| `accessControl.list` | string[] | `[]` | Phone numbers for whitelist/blacklist mode |
| `contactLookup` | object/null | `null` | Contact enrichment config (null = skip lookup) |
| `suppression.unknownContact` | string | `allow` | `allow` or `suppress` when contact not in DB |
| `suppression.unknownContactAction` | string | `silent` | `silent` or `log` for suppressed messages |

### Access Control Modes

- **`allow-all`** — All numbers can SMS this DID (default)
- **`block-all`** — No numbers can SMS this DID (useful for outbound-only DIDs)
- **`whitelist`** — Block all EXCEPT numbers in `list`
- **`blacklist`** — Allow all EXCEPT numbers in `list`

### Contact Lookup

The `contactLookup` object configures how the plugin enriches inbound messages with contact data from the database:

| Field | Type | Description |
|-------|------|-------------|
| `table` | string | Database table to query |
| `phoneColumn` | string | Column containing phone numbers |
| `phoneMatch` | string | `"exact"` or `"like"` (substring match, default) |
| `selectColumns` | string[] | Columns to SELECT |
| `displayName` | string | Column to use as display name in agent messages |
| `bodyFields` | object | Metadata to include in agent message body (see below) |
| `languageColumn` | string | Column containing preferred language code |

#### bodyFields Format

The `bodyFields` map supports three value formats:

- **Column reference**: `"Email": "email"` — uses the value from the `email` column
- **Literal string**: `"Role": "'customer'"` — uses the literal string `customer`
- **Array of columns**: `"License": ["license_number", "license_state"]` — joins non-null values with a space

---

## Agent Tools

The plugin registers tools that agents can invoke, gated by per-DID feature flags:

### `sms_read_threads` (when `features.agentThreadAccess` is true)

Read SMS thread history for a phone number.

Parameters:
- `did` (required) — The DID number
- `phone` (optional) — Phone number (defaults to current session)
- `limit` (optional) — Max messages to return (default 20, max 100)

### `sms_add_contact` (when `features.agentCanAddContacts` is true AND `contactLookup` is configured)

Add or update a contact in the DID's contact lookup table.

Parameters:
- `did` (required) — The DID number
- `phone` (required) — Contact phone number
- Plus any columns from `contactLookup.selectColumns`

---

## Per-Agent TOOLS.md Section

Copy the following into each agent's workspace `TOOLS.md` file, customizing the DID number and label:

```markdown
### SMS (voipms-sms plugin)

This agent handles SMS messages on DID {DID_NUMBER} ({LABEL}) via the voipms-sms plugin.

**Sending SMS:**
- To reply to the current contact: use `message(action="send")` with no target
- To message a new contact: use `message(action="send", target="PHONE_NUMBER")` with a 10-digit phone number
- Messages ≤160 chars are sent as SMS; longer messages are sent as MMS automatically
```

---

## Database Schema

### Auto-created Tables

These tables are automatically created by the plugin when the corresponding features are enabled on any DID:

#### `sms_threads` (when `smsThreadLogging` is enabled)

```sql
CREATE TABLE IF NOT EXISTS sms_threads (
  id           INTEGER PRIMARY KEY AUTOINCREMENT,
  phone_number TEXT NOT NULL,
  did          TEXT NOT NULL,
  agent        TEXT NOT NULL,
  direction    TEXT NOT NULL,      -- 'inbound' or 'outbound'
  message      TEXT NOT NULL,
  context      TEXT,
  created_at   TEXT DEFAULT (datetime('now'))
);
```

#### `sms_language_preferences` (when `languagePreferences` is enabled)

```sql
CREATE TABLE IF NOT EXISTS sms_language_preferences (
  phone_number       TEXT PRIMARY KEY,
  preferred_language TEXT NOT NULL,
  updated_at         TEXT NOT NULL
);
```

### Contact Tables

Contact tables are user-defined — you create them during installation or manually. The plugin queries them via the `contactLookup` configuration. Example:

```sql
CREATE TABLE contacts (
  phone TEXT PRIMARY KEY,
  name  TEXT,
  email TEXT,
  preferred_language TEXT
);
```

---

## Management CLI

Use `manage.sh` to manage the plugin without editing JSON manually:

```bash
# List configured DIDs
./manage.sh list-dids

# Add a new DID
./manage.sh add-did 5551234567 support-agent --label "Support Line"

# Remove a DID
./manage.sh remove-did 5551234567

# Show config
./manage.sh show-config              # all config
./manage.sh show-config 5551234567   # single DID

# Access control
./manage.sh set-access 5551234567 whitelist
./manage.sh add-allowed 5551234567 5559876543
./manage.sh remove-allowed 5551234567 5559876543

# Features
./manage.sh set-feature 5551234567 agentThreadAccess true
./manage.sh set-feature 5551234567 smsStitching false

# Contacts
./manage.sh list-contacts 5551234567
./manage.sh add-contact 5551234567 5559876543 name="Jane Doe" email="jane@example.com"
./manage.sh remove-contact 5551234567 5559876543

# Diagnostics
./manage.sh test-webhook
./manage.sh check-health
```

Set the config path via `--config` flag or `OPENCLAW_CONFIG` environment variable.

---

## voip.ms Webhook Setup

Configure the webhook URL in your voip.ms control panel:

1. Log in to voip.ms
2. Go to: **Main Menu → DID Numbers → Manage DIDs → Edit your DID**
3. Set the **SMS/MMS URL** to: `http://<your-server-ip>:<webhook-port>/`
4. Example: `http://10.0.20.41:8089/`

The plugin supports both GET (voip.ms callback URL format) and POST (JSON or form-encoded) webhooks.

### Health Check

`GET /health` returns `200 ok` — use this to verify the webhook is running.

---

## Troubleshooting

### Plugin not loading
- Verify `plugins.allow` includes `"voipms-sms"`
- Verify `plugins.load.paths` includes the plugin directory path
- Check that `dbPath` and `dids` are set in the config

### No inbound messages
- Check that the DID's `inbound` is `true`
- Check `accessControl.mode` — whitelist mode requires the sender to be in the list
- Check `suppression.unknownContact` — if set to `suppress`, only known contacts get through
- Verify the webhook URL is correctly configured in voip.ms
- Run `./manage.sh test-webhook` to verify the webhook listener is running

### Outbound not working
- Check that the DID's `outbound` is `true`
- Verify `apiUsername` and `apiPassword` are set
- Messages ≤160 chars use SMS; longer messages use MMS automatically

### Database errors
- Ensure the database file exists and is writable
- The plugin sets `PRAGMA busy_timeout=10000` for concurrent access
- Check that table/column names in `contactLookup` match your actual schema

### Multi-segment SMS arriving as separate messages
- Ensure `features.smsStitching` is `true` for the DID
- Ensure API credentials are configured (stitching requires the getSMS API)
