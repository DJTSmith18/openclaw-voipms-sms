'use strict';

const sqlite3 = require('sqlite3').verbose();
const https   = require('https');
const http    = require('http');

// ── Task system integration (optional — graceful degradation if not installed) ──
function httpGetJson(url, headers, timeoutMs) {
  return new Promise((resolve, reject) => {
    const req = http.get(url, { headers, timeout: timeoutMs }, (res) => {
      let data = '';
      res.on('data', chunk => { data += chunk; });
      res.on('end', () => {
        try { resolve(JSON.parse(data)); } catch { reject(new Error('Invalid JSON')); }
      });
    });
    req.on('error', reject);
    req.on('timeout', () => { req.destroy(); reject(new Error('Timeout')); });
  });
}

function createTaskClient(apiConfig) {
  const taskCfg = apiConfig?.plugins?.entries?.['task-system']?.config?.webUI;
  if (!taskCfg || taskCfg.enabled === false) return null;
  const port = taskCfg.port || 18790;
  const token = taskCfg.authToken || '';
  let available = null; // null=untested, true/false=tested

  return {
    async getPendingResponses(phone10) {
      if (available === false) return [];
      try {
        const headers = token ? { Authorization: `Bearer ${token}` } : {};
        const result = await httpGetJson(
          `http://127.0.0.1:${port}/dashboard/api/tasks/pending-responses?contact=${encodeURIComponent(phone10)}`,
          headers, 3000
        );
        available = true;
        return result?.tasks || [];
      } catch {
        if (available === null) available = false;
        return [];
      }
    }
  };
}

// ── Module-scope singletons (shared across multiple startAccount calls per DID) ──
let _httpServer   = null;
let _httpRefCount = 0;
const _didHandlers    = new Map(); // did → async ({ fromPhone, message, contact }) => void
const _dedupIds       = new Set(); // voip.ms SMS IDs already dispatched (prevents double-dispatch)
const _processingLock = new Map(); // `${did}:${phone}` → Promise chain (serializes per-contact)

// Serialize async work per contact — replicates Python HTTPServer single-thread behaviour.
function withContactLock(key, fn) {
  const prev = _processingLock.get(key) || Promise.resolve();
  let resolve;
  const next = new Promise((r) => { resolve = r; });
  _processingLock.set(key, next);
  return prev.then(() => fn()).finally(() => {
    resolve();
    if (_processingLock.get(key) === next) _processingLock.delete(key);
  });
}

// Validate SQL identifier (table/column name) — alphanumeric + underscore only
function isSafeSqlIdent(name) {
  return /^[a-zA-Z_][a-zA-Z0-9_]*$/.test(name);
}

// ── Plugin export (SDK-native shape) ─────────────────────────────────────────
module.exports = {
  id:          'voipms-sms',
  name:        'VoIP.ms SMS',
  description: 'SMS channel plugin for voip.ms — per-DID routing, access control, contact enrichment, and feature toggles.',

  register(api) {

    // ── Config ──────────────────────────────────────────────────────────────
    const pluginCfg = api.config?.plugins?.entries?.['voipms-sms']?.config || {};

    const DB_PATH = pluginCfg.dbPath;
    if (!DB_PATH) {
      api.logger.error('[voipms] FATAL: dbPath is required in plugin config — plugin disabled');
      return;
    }

    const DIDS = pluginCfg.dids;
    if (!DIDS || typeof DIDS !== 'object' || Object.keys(DIDS).length === 0) {
      api.logger.error('[voipms] FATAL: dids config is required and must contain at least one DID — plugin disabled');
      return;
    }

    const VOIPMS_USER  = pluginCfg.apiUsername || process.env.VOIPMS_API_USERNAME;
    const VOIPMS_PASS  = pluginCfg.apiPassword || process.env.VOIPMS_API_PASSWORD;
    const WEBHOOK_PORT = Number(pluginCfg.webhookPort) || Number(process.env.VOIPMS_WEBHOOK_PORT) || 8089;
    const TIMEZONE     = pluginCfg.timezone || 'America/New_York';

    // ── Task system client (optional cross-plugin integration) ──
    const taskClient = createTaskClient(api.config);
    if (taskClient) api.logger.info('[voipms] task-system detected — pending-response injection enabled');

    // Apply per-DID defaults
    for (const [did, cfg] of Object.entries(DIDS)) {
      cfg.label    = cfg.label || did;
      cfg.inbound  = cfg.inbound !== false;
      cfg.outbound = cfg.outbound !== false;

      cfg.features = cfg.features || {};
      cfg.features.smsThreadLogging   = cfg.features.smsThreadLogging !== false;
      cfg.features.languagePreferences = cfg.features.languagePreferences !== false;
      cfg.features.smsStitching       = cfg.features.smsStitching !== false;
      cfg.features.agentThreadAccess  = cfg.features.agentThreadAccess === true;
      cfg.features.agentCanAddContacts = cfg.features.agentCanAddContacts === true;
      cfg.features.includeLastMessage  = cfg.features.includeLastMessage === true;

      cfg.accessControl      = cfg.accessControl || {};
      cfg.accessControl.mode = cfg.accessControl.mode || 'allow-all';
      cfg.accessControl.list = cfg.accessControl.list || [];

      cfg.suppression                    = cfg.suppression || {};
      cfg.suppression.unknownContact     = cfg.suppression.unknownContact || 'allow';
      cfg.suppression.unknownContactAction = cfg.suppression.unknownContactAction || 'silent';

      // Validate contactLookup SQL identifiers
      if (cfg.contactLookup) {
        const cl = cfg.contactLookup;
        if (!isSafeSqlIdent(cl.table)) {
          api.logger.error(`[voipms] DID ${did}: contactLookup.table "${cl.table}" is not a safe SQL identifier — disabling lookup`);
          cfg.contactLookup = null;
        } else if (!isSafeSqlIdent(cl.phoneColumn)) {
          api.logger.error(`[voipms] DID ${did}: contactLookup.phoneColumn "${cl.phoneColumn}" is not a safe SQL identifier — disabling lookup`);
          cfg.contactLookup = null;
        } else if (cl.selectColumns) {
          for (const col of cl.selectColumns) {
            if (!isSafeSqlIdent(col)) {
              api.logger.error(`[voipms] DID ${did}: contactLookup.selectColumns contains unsafe identifier "${col}" — disabling lookup`);
              cfg.contactLookup = null;
              break;
            }
          }
          if (cfg.contactLookup && cl.languageColumn && !isSafeSqlIdent(cl.languageColumn)) {
            api.logger.error(`[voipms] DID ${did}: contactLookup.languageColumn "${cl.languageColumn}" is not a safe SQL identifier — ignoring`);
            delete cl.languageColumn;
          }
          if (cfg.contactLookup && cl.displayName && !isSafeSqlIdent(cl.displayName)) {
            api.logger.error(`[voipms] DID ${did}: contactLookup.displayName "${cl.displayName}" is not a safe SQL identifier — ignoring`);
            delete cl.displayName;
          }
        }
      }
    }

    // ── DB ──────────────────────────────────────────────────────────────────
    const db = new sqlite3.Database(DB_PATH, (err) => {
      if (err) { api.logger.error('[voipms] Cannot open DB:', err.message); return; }
      db.run('PRAGMA journal_mode=WAL;');
      db.run('PRAGMA busy_timeout=10000;');
      db.run('PRAGMA foreign_keys=ON;');

      // Auto-create sms_threads if ANY DID has smsThreadLogging enabled
      const anyThreadLogging = Object.values(DIDS).some(d => d.features.smsThreadLogging);
      if (anyThreadLogging) {
        db.run(`
          CREATE TABLE IF NOT EXISTS sms_threads (
            id           INTEGER PRIMARY KEY AUTOINCREMENT,
            phone_number TEXT NOT NULL,
            did          TEXT NOT NULL,
            agent        TEXT NOT NULL,
            direction    TEXT NOT NULL,
            message      TEXT NOT NULL,
            context      TEXT,
            created_at   TEXT DEFAULT (datetime('now'))
          )
        `);
      }

      // Auto-create sms_language_preferences if ANY DID has languagePreferences enabled
      const anyLangPrefs = Object.values(DIDS).some(d => d.features.languagePreferences);
      if (anyLangPrefs) {
        db.run(`
          CREATE TABLE IF NOT EXISTS sms_language_preferences (
            phone_number       TEXT PRIMARY KEY,
            preferred_language TEXT NOT NULL,
            updated_at         TEXT NOT NULL
          )
        `);
      }

      api.logger.info('[voipms] DB ready:', DB_PATH);
    });

    const dbRun = (sql, params = []) =>
      new Promise((res, rej) => db.run(sql, params, function (err) { err ? rej(err) : res(this); }));
    const dbGet = (sql, params = []) =>
      new Promise((res, rej) => db.get(sql, params, (err, row) => err ? rej(err) : res(row)));
    const dbAll = (sql, params = []) =>
      new Promise((res, rej) => db.all(sql, params, (err, rows) => err ? rej(err) : res(rows)));

    // ── Core helpers ──────────────────────────────────────────────────────────

    function normalizePhone(phone) {
      return String(phone || '').replace(/\D/g, '').slice(-10);
    }

    function defaultSessionKey(did, phone, agentId) {
      const norm = (s) =>
        String(s).toLowerCase().replace(/[^a-z0-9-]/g, '-').replace(/^-+|-+$/g, '').slice(0, 64) || 'x';
      return `agent:${norm(agentId)}:voipms:group:${did}:${normalizePhone(phone)}`;
    }

    // ── Access Control ────────────────────────────────────────────────────────
    function checkAccess(fromPhone, didCfg) {
      const phone = normalizePhone(fromPhone);
      const mode  = didCfg.accessControl.mode;
      const list  = didCfg.accessControl.list.map(normalizePhone);

      switch (mode) {
        case 'allow-all':
          return { allowed: true, reason: 'allow-all' };
        case 'block-all':
          return { allowed: false, reason: 'block-all' };
        case 'whitelist':
          return list.includes(phone)
            ? { allowed: true, reason: 'whitelisted' }
            : { allowed: false, reason: 'not on whitelist' };
        case 'blacklist':
          return list.includes(phone)
            ? { allowed: false, reason: 'blacklisted' }
            : { allowed: true, reason: 'not on blacklist' };
        default:
          return { allowed: true, reason: 'unknown mode — defaulting to allow' };
      }
    }

    // ── voip.ms REST API helper ───────────────────────────────────────────────
    function voipmsApiCall(params) {
      return new Promise((resolve, reject) => {
        const qs = new URLSearchParams({
          api_username: VOIPMS_USER,
          api_password: VOIPMS_PASS,
          ...params,
        }).toString();
        const req = https.get(
          `https://voip.ms/api/v1/rest.php?${qs}`,
          { timeout: 15000 },
          (res) => {
            let data = '';
            res.on('data', (c) => { data += c; });
            res.on('end', () => {
              try { resolve(JSON.parse(data)); }
              catch (e) { reject(new Error(`voip.ms bad JSON: ${data.slice(0, 200)}`)); }
            });
          }
        );
        req.on('error', reject);
        req.on('timeout', () => { req.destroy(); reject(new Error('voip.ms API timeout')); });
      });
    }

    async function sendVoipms(did, to, content) {
      if (!VOIPMS_USER || !VOIPMS_PASS) throw new Error('voip.ms credentials not configured');
      const method = content.length <= 160 ? 'sendSMS' : 'sendMMS';
      const result = await voipmsApiCall({ method, did, dst: to, message: content });
      if (result.status !== 'success') throw new Error(`voip.ms ${method} failed: ${result.status}`);
      return { type: method === 'sendSMS' ? 'sms' : 'mms', sms_id: result.sms };
    }

    // ── Feature-gated functions ───────────────────────────────────────────────

    async function logThread(phone, did, agent, direction, message) {
      const didCfg = DIDS[did];
      if (!didCfg || !didCfg.features.smsThreadLogging) return;
      try {
        await dbRun(
          `INSERT INTO sms_threads (phone_number, did, agent, direction, message, context) VALUES (?,?,?,?,?,?)`,
          [phone, did, agent, direction, message, `voipms-channel-${direction}`]
        );
      } catch (e) { api.logger.warn('[voipms] sms_threads log error:', e.message); }
    }

    async function saveLanguagePref(phone, language, did) {
      if (!language) return;
      const didCfg = DIDS[did];
      if (!didCfg || !didCfg.features.languagePreferences) return;
      try {
        await dbRun(
          `INSERT INTO sms_language_preferences (phone_number, preferred_language, updated_at)
           VALUES (?, ?, datetime('now'))
           ON CONFLICT(phone_number) DO UPDATE SET
             preferred_language = excluded.preferred_language,
             updated_at         = excluded.updated_at`,
          [normalizePhone(phone), language]
        );
      } catch (e) { api.logger.warn('[voipms] language pref save error:', e.message); }
    }

    // ── Fetch previous last message (for includeLastMessage feature) ─────────
    async function fetchLastMessage(phone, did) {
      const didCfg = DIDS[did];
      if (!didCfg || !didCfg.features.includeLastMessage) return null;
      if (!didCfg.features.smsThreadLogging) return null; // requires thread logging
      try {
        const row = await dbGet(
          `SELECT direction, message, created_at FROM sms_threads
           WHERE did = ? AND phone_number = ?
           ORDER BY created_at DESC LIMIT 1`,
          [did, phone]
        );
        return row || null;
      } catch (e) {
        api.logger.warn('[voipms] fetchLastMessage error:', e.message);
        return null;
      }
    }

    // ── SMS stitching ─────────────────────────────────────────────────────────
    async function stitchSms(smsId, dateStr, fromPhone, did) {
      const didCfg = DIDS[did];
      if (!didCfg || !didCfg.features.smsStitching) return null;
      if (!VOIPMS_USER || !VOIPMS_PASS) return null;
      try {
        const dateOnly = (dateStr || '').slice(0, 10);
        if (dateOnly.length !== 10) return null;

        const fetchDay = async (date) => voipmsApiCall({
          method: 'getSMS', did,
          contact: normalizePhone(fromPhone),
          from: date, to: date,
          type: '1', limit: '3',
        });

        let data = await fetchDay(dateOnly);
        if (data.status === 'no_sms') {
          const prevDate = new Date(dateOnly + 'T12:00:00Z');
          prevDate.setDate(prevDate.getDate() - 1);
          const prevDay = prevDate.toISOString().slice(0, 10);
          api.logger.debug(`[voipms] stitch no_sms for ${dateOnly}, retrying ${prevDay}`);
          data = await fetchDay(prevDay);
        }
        if (data.status !== 'success') return null;

        const smsList  = data.sms || [];
        if (!smsList.length) return null;

        const smsIdStr = String(smsId);

        let currentUtc = null, apiUtcOffset = null;
        try {
          currentUtc = new Date(dateStr);
          for (const sms of smsList) {
            if (String(sms.id) === smsIdStr && sms.date) {
              const apiDt = new Date(sms.date.replace(' ', 'T') + 'Z');
              apiUtcOffset = (apiDt - currentUtc) / 1000;
              api.logger.debug(`[voipms] API UTC offset=${apiUtcOffset.toFixed(0)}s`);
              break;
            }
          }
        } catch (_) { currentUtc = null; }

        const MAX_SEGMENT_AGE = 180;
        const toStitch = [];
        for (const sms of smsList) {
          const sid = String(sms.id || '');
          if (sid === smsIdStr) {
            toStitch.push(sms);
            continue;
          }
          if (_dedupIds.has(sid)) continue;
          let include = true;
          if (currentUtc !== null && apiUtcOffset !== null && sms.date) {
            try {
              const apiDt    = new Date(sms.date.replace(' ', 'T') + 'Z');
              const apiDtUtc = new Date(apiDt - apiUtcOffset * 1000);
              if (Math.abs((apiDtUtc - currentUtc) / 1000) > MAX_SEGMENT_AGE) include = false;
            } catch (_) {}
          }
          if (include) toStitch.push(sms);
        }
        if (!toStitch.length) return null;

        toStitch.sort((a, b) => Number(a.id) - Number(b.id));
        const stitchedIds = toStitch.map((s) => String(s.id));

        for (const sid of stitchedIds) _dedupIds.add(sid);

        const stitched = toStitch.map((s) => s.message || '').join('');
        if (toStitch.length > 1) {
          api.logger.info(`[voipms] stitched ${toStitch.length} segments (${stitchedIds.join(',')}) → ${stitched.length} chars`);
        }
        return stitched || null;
      } catch (e) {
        api.logger.warn('[voipms] stitchSms error:', e.message);
        return null;
      }
    }

    // ── Contact enrichment (generic, config-driven) ───────────────────────────
    async function enrichContact(fromPhone, didCfg) {
      const phone10 = normalizePhone(fromPhone);
      const cl = didCfg.contactLookup;

      // No contact lookup configured — accept with no enrichment
      if (!cl) {
        return { found: true, contact: { name: null } };
      }

      try {
        // Build SELECT columns
        const cols = cl.selectColumns && cl.selectColumns.length > 0
          ? cl.selectColumns.join(', ')
          : '*';

        // Build WHERE clause based on phoneMatch mode
        let whereClause, whereParam;
        if (cl.phoneMatch === 'exact') {
          whereClause = `${cl.phoneColumn} = ?`;
          whereParam  = phone10;
        } else {
          // Default: 'like' — substring match
          whereClause = `${cl.phoneColumn} LIKE ?`;
          whereParam  = `%${phone10}%`;
        }

        const sql = `SELECT ${cols} FROM ${cl.table} WHERE ${whereClause} LIMIT 1`;
        const row = await dbGet(sql, [whereParam]);

        if (!row) return { found: false };

        const contact = {};
        // Copy all selected columns to contact object
        for (const [key, val] of Object.entries(row)) {
          contact[key] = val;
        }
        // Set display name
        if (cl.displayName && row[cl.displayName] !== undefined) {
          contact.name = row[cl.displayName];
        }
        // Set preferred_language from languageColumn
        if (cl.languageColumn && row[cl.languageColumn] !== undefined) {
          contact.preferred_language = row[cl.languageColumn];
        }

        return { found: true, contact };
      } catch (e) {
        api.logger.warn(`[voipms] contact lookup error (${cl.table}):`, e.message);
        return { found: false };
      }
    }

    // ── Build agent body (generic, config-driven) ─────────────────────────────
    function buildAgentBody({ fromPhone, message, contact, didCfg, lastMessage, pendingTasks }) {
      const cl  = didCfg.contactLookup;
      const who = contact?.name || fromPhone;

      const lines = [`SMS from ${who} (${fromPhone})`];

      if (contact && cl) {
        const meta = [];
        if (cl.bodyFields) {
          // Explicit field mapping
          for (const [label, spec] of Object.entries(cl.bodyFields)) {
            if (typeof spec === 'string') {
              const litMatch = spec.match(/^'(.+)'$/);
              if (litMatch) {
                meta.push(`${label}: ${litMatch[1]}`);
              } else if (contact[spec] !== undefined && contact[spec] !== null) {
                meta.push(`${label}: ${contact[spec]}`);
              }
            } else if (Array.isArray(spec)) {
              const vals = spec.map(col => contact[col]).filter(v => v !== undefined && v !== null);
              if (vals.length) meta.push(`${label}: ${vals.join(' ')}`);
            }
          }
        } else {
          // No bodyFields configured — auto-show all non-null contact fields
          for (const [key, val] of Object.entries(contact)) {
            if (key === 'name') continue; // already shown in header
            if (val !== undefined && val !== null && val !== '') {
              meta.push(`${key}: ${val}`);
            }
          }
        }
        if (meta.length) lines.push(meta.join(' | '));
      }

      // Language warning
      if (cl && cl.languageColumn && contact) {
        if (!contact.preferred_language && !contact[cl.languageColumn]) {
          lines.push('Language unknown — ask preference on first reply');
        } else {
          const lang = contact.preferred_language || contact[cl.languageColumn];
          if (lang) lines.push(`Language: ${lang}`);
        }
      }

      // Timestamp
      try {
        const _d   = new Date(new Date().toLocaleString('en-US', { timeZone: TIMEZONE }));
        const _fmt = (n) => String(n).padStart(2, '0');
        lines.push(`Current Date and Time: ${_fmt(_d.getMonth()+1)}/${_fmt(_d.getDate())}/${_d.getFullYear()} ${_fmt(_d.getHours())}:${_fmt(_d.getMinutes())}`);
      } catch (_) {
        lines.push(`Current Date and Time: ${new Date().toISOString()}`);
      }

      // Previous message context (includeLastMessage feature)
      if (lastMessage) {
        const sender = lastMessage.direction === 'inbound' ? (contact?.name || fromPhone) : 'Agent';
        lines.push(`Last message (${sender}): ${lastMessage.message}`);
      }

      // Pending task context (injected by task-system integration)
      if (pendingTasks && pendingTasks.length > 0) {
        lines.push('--- PENDING TASK CONTEXT ---');
        for (const t of pendingTasks) {
          const pri = { 1: 'URGENT', 2: 'HIGH', 3: 'NORMAL', 4: 'LOW' }[t.priority] || '';
          lines.push(`Task #${t.id} [${t.status}] ${pri}: "${t.title}"`);
          if (t.blocked_note) lines.push(`  Note: ${t.blocked_note}`);
        }
        lines.push('ACTION REQUIRED: This message may be a response to one of the above tasks.');
        lines.push('If it is: 1) call task_comment with the response, 2) call task_status to update (→ in_progress or done), 3) clear awaiting_response_from in metadata.');
        lines.push('---');
      }

      lines.push(`Message: ${message}`);
      return lines.join('\n');
    }

    // ── Inbound dispatch ──────────────────────────────────────────────────────
    async function handleInbound({ myDid, didCfg, fromPhone, message, contact, lastMessage, cfg, runtime }) {
      const agentId    = didCfg.agent;
      const phone      = normalizePhone(fromPhone);
      const sessionKey = defaultSessionKey(myDid, phone, agentId);

      // Query task system for pending responses from this phone number
      let pendingTasks = [];
      if (taskClient) {
        try { pendingTasks = await taskClient.getPendingResponses(phone); }
        catch { /* non-fatal */ }
      }

      const body       = buildAgentBody({ fromPhone: phone, message, contact, didCfg, lastMessage, pendingTasks });

      const ctx = {
        Body: body, BodyForAgent: body, SessionKey: sessionKey,
        From: phone,
        To: phone,
        AccountId: myDid, Provider: 'voipms',
        ChatType: 'direct', Timestamp: Date.now(),
      };

      const finalized = runtime.channel.reply.finalizeInboundContext(ctx);
      const { dispatcher, replyOptions } = runtime.channel.reply.createReplyDispatcherWithTyping({
        deliver: async (payload, info) => {
          if (!payload.text || info?.kind !== 'final') return;
          try {
            await sendVoipms(myDid, phone, payload.text);
            await logThread(phone, myDid, agentId, 'outbound', payload.text);
            api.logger.info(`[voipms] reply sent ${myDid} → ${phone} (${payload.text.length} chars)`);
          } catch (e) {
            api.logger.error('[voipms] deliver failed:', e.message);
          }
        },
        onError: (e) => api.logger.error('[voipms] reply error:', String(e)),
      });

      const accountCfg = { ...cfg, accountId: myDid };
      runtime.channel.reply.withReplyDispatcher({
        dispatcher,
        run: () => runtime.channel.reply.dispatchReplyFromConfig({
          ctx: finalized, cfg: accountCfg, dispatcher, replyOptions,
        }),
      }).catch((e) => api.logger.error('[voipms] dispatch failed:', e.message));

      api.logger.info(`[voipms] dispatched from=${phone} → ${sessionKey}`);
    }

    // ── Shared webhook HTTP server (singleton) ────────────────────────────────
    function startSharedServer(port, logger) {
      if (_httpServer) { _httpRefCount++; return; }

      _httpServer = http.createServer(async (req, res) => {
        const u = new URL(req.url, 'http://x');

        // Health endpoint
        if (u.pathname === '/health') {
          res.writeHead(200, { 'Content-Type': 'text/plain' });
          res.end('ok');
          return;
        }

        // Parse SMS params — GET (voip.ms callback URL) or POST (JSON/form webhook)
        let to = '', from = '', message = '', smsId = '', dateStr = '';

        if (req.method !== 'POST') {
          to      = u.searchParams.get('to')      || '';
          from    = u.searchParams.get('from')    || '';
          message = u.searchParams.get('message') || '';
          smsId   = u.searchParams.get('id')      || '';
          dateStr = u.searchParams.get('date')    || '';
        } else {
          const body = await new Promise((resolve) => {
            let buf = '';
            req.on('data', (c) => { buf += c; });
            req.on('end', () => resolve(buf));
          });
          logger?.debug('[voipms] POST body:', body.slice(0, 500));
          let parsed = false;
          if (body.trim().startsWith('{')) {
            try {
              const data    = JSON.parse(body);
              const payload = data?.data?.payload || data?.data || data;
              if (payload && typeof payload === 'object') {
                const fromObj = payload.from || {};
                const toList  = Array.isArray(payload.to) ? payload.to : [];
                to      = String(toList[0]?.phone_number || payload.did || data.to || '');
                from    = String((typeof fromObj === 'object' ? fromObj.phone_number : fromObj) || data.from || '');
                message = String(payload.text || payload.message || data.message || '');
                smsId   = String(data?.data?.id || payload.id || data.id || '');
                dateStr = String(payload.received_at || payload.date || data.date || '');
                parsed  = true;
              }
            } catch (_) {}
          }
          if (!parsed) {
            const params = new URLSearchParams(body);
            to      = params.get('to')      || params.get('did')     || '';
            from    = params.get('from')    || params.get('contact') || '';
            message = params.get('message') || params.get('text')    || '';
            smsId   = params.get('id')      || '';
            dateStr = params.get('date')    || '';
          }
        }

        const did       = to.replace(/\D/g, '').slice(-10);
        const fromPhone = from.replace(/\D/g, '').slice(-10);
        const didCfg    = DIDS[did] || null;

        logger?.debug(`[voipms] webhook: did=${did} from=${fromPhone} id=${smsId} handler=${_didHandlers.has(did)}`);

        // Respond immediately — voip.ms expects a fast 200 ack
        res.writeHead(200, { 'Content-Type': 'text/plain' });
        res.end('ok');

        if (!didCfg || !_didHandlers.has(did) || !fromPhone || !message) return;

        // Check inbound enabled
        if (!didCfg.inbound) {
          logger?.debug(`[voipms] DID ${did} has inbound disabled — ignoring`);
          return;
        }

        // Access control — check FIRST before any processing
        const access = checkAccess(fromPhone, didCfg);
        if (!access.allowed) {
          logger?.info(`[voipms] access denied for ${fromPhone} on DID ${did}: ${access.reason}`);
          return;
        }

        // Serialize per-contact
        const lockKey = `${did}:${fromPhone}`;
        withContactLock(lockKey, async () => {
          try {
            // Dedup inside lock
            if (smsId && _dedupIds.has(String(smsId))) {
              logger?.debug(`[voipms] dedup skip sms_id=${smsId}`);
              return;
            }

            // Stitch multi-segment SMS (feature-gated inside stitchSms)
            let finalMessage = message;
            if (smsId) {
              const stitched = await stitchSms(smsId, dateStr, fromPhone, did);
              if (stitched) finalMessage = stitched;
              _dedupIds.add(String(smsId));
            }

            // Contact enrichment
            const enriched = await enrichContact(fromPhone, didCfg);

            // Suppression: unknown contact handling
            if (!enriched.found) {
              const supp = didCfg.suppression;
              if (supp.unknownContact === 'suppress') {
                logger?.info(`[voipms] unknown contact ${fromPhone} on DID ${did} — suppressed`);
                if (supp.unknownContactAction === 'log') {
                  await logThread(fromPhone, did, didCfg.agent, 'inbound', finalMessage);
                }
                return;
              }
              // If unknownContact === 'allow', fall through with no contact data
            }

            // Save language preference (feature-gated inside saveLanguagePref)
            await saveLanguagePref(fromPhone, enriched.contact?.preferred_language, did);

            // Fetch previous last message BEFORE logging current (feature-gated inside fetchLastMessage)
            const lastMsg = await fetchLastMessage(fromPhone, did);

            // Log inbound thread (feature-gated inside logThread)
            await logThread(fromPhone, did, didCfg.agent, 'inbound', finalMessage);

            const handler = _didHandlers.get(did);
            if (handler) await handler({ fromPhone, message: finalMessage, contact: enriched.contact, lastMessage: lastMsg });
          } catch (e) {
            logger?.error('[voipms] webhook processing error:', e.message);
          }
        }).catch((e) => logger?.error('[voipms] lock error:', e.message));
      });

      _httpServer.on('error', (e) => logger?.error('[voipms] HTTP server error:', e.message));
      _httpServer.listen(port, () => logger?.info(`[voipms] webhook HTTP server listening on port ${port}`));
      _httpRefCount = 1;
    }

    function stopSharedServer(logger) {
      _httpRefCount = Math.max(0, _httpRefCount - 1);
      if (_httpRefCount === 0 && _httpServer) {
        _httpServer.close(() => logger?.info('[voipms] HTTP server closed'));
        _httpServer = null;
      }
    }

    // ── Agent tools registration ──────────────────────────────────────────────

    // Register sms_read_threads tool for DIDs with agentThreadAccess
    const anyThreadAccess = Object.values(DIDS).some(d => d.features.agentThreadAccess);
    if (anyThreadAccess) {
      api.registerTool({
        id: 'sms_read_threads',
        name: 'sms_read_threads',
        description: 'Read SMS thread history for a phone number on a specific DID.',
        parameters: {
          type: 'object',
          properties: {
            did: {
              type: 'string',
              description: 'The DID number to read threads for',
            },
            phone: {
              type: 'string',
              description: 'Phone number to read threads for (defaults to current session contact)',
            },
            limit: {
              type: 'number',
              description: 'Maximum number of messages to return (default 20)',
            },
          },
          required: ['did'],
        },
        execute: async (params, context) => {
          const did = normalizePhone(params.did);
          const didCfg = DIDS[did];
          if (!didCfg) return { error: `DID ${did} not configured` };
          if (!didCfg.features.agentThreadAccess) return { error: `Thread access not enabled for DID ${did}` };

          const phone = params.phone ? normalizePhone(params.phone) : null;
          const limit = Math.min(Math.max(Number(params.limit) || 20, 1), 100);

          try {
            let sql, sqlParams;
            if (phone) {
              sql = `SELECT phone_number, did, agent, direction, message, context, created_at
                     FROM sms_threads WHERE did = ? AND phone_number = ?
                     ORDER BY created_at DESC LIMIT ?`;
              sqlParams = [did, phone, limit];
            } else {
              sql = `SELECT phone_number, did, agent, direction, message, context, created_at
                     FROM sms_threads WHERE did = ?
                     ORDER BY created_at DESC LIMIT ?`;
              sqlParams = [did, limit];
            }
            const rows = await dbAll(sql, sqlParams);
            return { threads: rows.reverse(), count: rows.length };
          } catch (e) {
            return { error: `Failed to read threads: ${e.message}` };
          }
        },
      });
    }

    // Register sms_add_contact tool for DIDs with agentCanAddContacts AND contactLookup
    const didsWithAddContact = Object.entries(DIDS).filter(
      ([, d]) => d.features.agentCanAddContacts && d.contactLookup
    );
    if (didsWithAddContact.length > 0) {
      // Collect all writable columns across all DIDs with this feature
      const allWritableColumns = new Set();
      for (const [, d] of didsWithAddContact) {
        const cl = d.contactLookup;
        if (cl.selectColumns) {
          for (const col of cl.selectColumns) allWritableColumns.add(col);
        }
        allWritableColumns.add(cl.phoneColumn);
      }

      const colProperties = {};
      for (const col of allWritableColumns) {
        colProperties[col] = { type: 'string', description: `Value for column '${col}'` };
      }

      api.registerTool({
        id: 'sms_add_contact',
        name: 'sms_add_contact',
        description: 'Add or update a contact in the contact lookup table for a specific DID.',
        parameters: {
          type: 'object',
          properties: {
            did: {
              type: 'string',
              description: 'The DID number whose contact table to modify',
            },
            phone: {
              type: 'string',
              description: 'Phone number for the contact (required)',
            },
            ...colProperties,
          },
          required: ['did', 'phone'],
        },
        execute: async (params, context) => {
          const did = normalizePhone(params.did);
          const didCfg = DIDS[did];
          if (!didCfg) return { error: `DID ${did} not configured` };
          if (!didCfg.features.agentCanAddContacts) return { error: `Add contacts not enabled for DID ${did}` };
          if (!didCfg.contactLookup) return { error: `No contact lookup table configured for DID ${did}` };

          const cl = didCfg.contactLookup;
          const phone = normalizePhone(params.phone);
          if (!phone) return { error: 'Phone number is required' };

          // Only allow columns from selectColumns + phoneColumn
          const allowedCols = new Set(cl.selectColumns || []);
          allowedCols.add(cl.phoneColumn);

          const columns = [cl.phoneColumn];
          const values  = [phone];
          const updateParts = [];

          for (const [key, val] of Object.entries(params)) {
            if (key === 'did' || key === 'phone') continue;
            if (!allowedCols.has(key)) continue;
            if (!isSafeSqlIdent(key)) continue;
            if (key === cl.phoneColumn) continue; // already added
            columns.push(key);
            values.push(val);
            updateParts.push(`${key} = excluded.${key}`);
          }

          try {
            const placeholders = columns.map(() => '?').join(', ');
            const colList      = columns.join(', ');
            let sql;
            if (updateParts.length > 0) {
              sql = `INSERT INTO ${cl.table} (${colList}) VALUES (${placeholders})
                     ON CONFLICT(${cl.phoneColumn}) DO UPDATE SET ${updateParts.join(', ')}`;
            } else {
              sql = `INSERT OR IGNORE INTO ${cl.table} (${colList}) VALUES (${placeholders})`;
            }
            await dbRun(sql, values);
            return { success: true, phone, table: cl.table };
          } catch (e) {
            return { error: `Failed to add contact: ${e.message}` };
          }
        },
      });
    }

    // ── Channel plugin object ─────────────────────────────────────────────────
    const voipmsPlugin = {
      id:   'voipms',
      meta: {
        id: 'voipms', label: 'VoIP.ms SMS', selectionLabel: 'VoIP.ms SMS',
        docsPath: 'voipms', blurb: 'SMS via voip.ms',
      },
      capabilities: { chatTypes: ['dm'] },

      config: {
        listAccountIds: () => Object.keys(DIDS),
        resolveAccount:  (accountId) => ({ enabled: !!DIDS[accountId] }),
        isEnabled:    () => true,
        isConfigured: () => !!(VOIPMS_USER && VOIPMS_PASS),
      },

      agentPrompt: {
        messageToolHints: () => [
          '- AUTO-REPLY MODE: When you receive an inbound SMS, you are in auto-reply mode. Your response text IS the SMS reply — it is sent directly to the contact. Do NOT use the message tool to reply. Do NOT think out loud, reason, or narrate your thought process. Just respond with the plain text reply.',
          '- IMPORTANT: SMS does not support markdown. Use plain text and emojis only. No bold, italic, links, headers, lists, or code blocks.',
          '- For cold outbound to a new contact, use the message tool with `target` set to the 10-digit phone number.',
          '- ≤160 chars → SMS; >160 chars → MMS (automatic).',
        ],
      },

      messaging: {
        normalizeTarget: (raw) => String(raw || '').replace(/^group:/i, ''),
      },

      heartbeat: {
        checkReady: async () => {
          try { await dbGet('SELECT 1'); return { ok: true, reason: 'db ready' }; }
          catch (e) { return { ok: false, reason: e.message }; }
        },
      },

      gateway: {
        startAccount: async (ctx) => {
          const myDid      = ctx.accountId;
          const didCfg     = DIDS[myDid];
          const logger     = ctx.log ?? api.logger;
          const abortSignal = ctx.abortSignal;

          if (!didCfg) {
            logger.error(`[voipms] no config for accountId="${myDid}" — check dids config`);
            return;
          }
          logger.info(`[voipms] gateway started — DID ${myDid} (${didCfg.label}) → agent:${didCfg.agent}`);

          // Register this DID's inbound handler
          _didHandlers.set(myDid, async (data) => {
            await handleInbound({
              myDid, didCfg,
              fromPhone:   data.fromPhone,
              message:     data.message,
              contact:     data.contact,
              lastMessage: data.lastMessage,
              cfg:         ctx.cfg,
              runtime:     api.runtime,
            });
          });

          startSharedServer(WEBHOOK_PORT, logger);

          // Hold open until OpenClaw stops this account
          await new Promise((resolve) => {
            if (abortSignal?.aborted) { resolve(); return; }
            abortSignal?.addEventListener('abort', resolve, { once: true });
          });

          // Cleanup on stop
          _didHandlers.delete(myDid);
          stopSharedServer(logger);
          logger.info(`[voipms] gateway stopped — DID ${myDid}`);
        },
      },

      outbound: {
        deliveryMode: 'direct',
        sendMedia: async () => { throw new Error('SMS does not support media'); },
        sendText: async ({ to, text, accountId }) => {
          const rawTo = String(to || '').replace(/^group:/i, '');

          let did, phone;
          if (accountId) {
            did   = accountId;
            phone = normalizePhone(rawTo);
          } else if (rawTo.includes(':')) {
            const idx = rawTo.indexOf(':');
            did   = rawTo.slice(0, idx);
            phone = normalizePhone(rawTo.slice(idx + 1));
          } else {
            phone = normalizePhone(rawTo);
            did   = Object.keys(DIDS)[0];
          }

          const didCfg = DIDS[did];
          if (!didCfg) throw new Error(`DID ${did} not configured`);
          if (!didCfg.outbound) throw new Error(`Outbound SMS disabled for DID ${did} (${didCfg.label})`);

          api.logger.debug(`[voipms] sendText did=${did} to=${phone} len=${text.length}`);
          try {
            await sendVoipms(did, phone, text);
            await logThread(phone, did, didCfg.agent, 'outbound', text);
            api.logger.info(`[voipms] sent ${text.length <= 160 ? 'SMS' : 'MMS'} via ${did} → ${phone}`);
            return { channel: 'voipms', messageId: `voipms-${Date.now()}` };
          } catch (e) {
            api.logger.error('[voipms] sendText failed:', e.message);
            throw e;
          }
        },
      },
    };

    api.registerChannel({ plugin: voipmsPlugin });
  },
};
