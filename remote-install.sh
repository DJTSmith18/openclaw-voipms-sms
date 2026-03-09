#!/usr/bin/env bash
set -euo pipefail

# ── voipms-sms Remote Installer / Upgrader ────────────────────────────────────
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/DJTSmith18/openclaw-voipms-sms/main/remote-install.sh | bash
#   curl -fsSL ... | bash -s -- --dir /custom/path
#   curl -fsSL ... | bash -s -- --branch develop

REPO="https://github.com/DJTSmith18/openclaw-voipms-sms.git"
DEFAULT_DIR="${HOME}/.openclaw/extensions/voipms-sms"

BOLD='\033[1m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m'

info()  { echo -e "${GREEN}✓${NC} $*"; }
warn()  { echo -e "${YELLOW}!${NC} $*"; }
err()   { echo -e "${RED}✗${NC} $*" >&2; }
step()  { echo -e "${CYAN}→${NC} $*"; }

# ── Parse arguments ───────────────────────────────────────────────────────────
INSTALL_DIR="$DEFAULT_DIR"
BRANCH="main"

while [ $# -gt 0 ]; do
  case "$1" in
    --dir)    INSTALL_DIR="$2"; shift 2 ;;
    --branch) BRANCH="$2"; shift 2 ;;
    --help|-h)
      cat <<'EOF'
voipms-sms Plugin Installer

Usage: curl -fsSL <url> | bash [-s -- OPTIONS]

Options:
  --dir <path>      Install directory (default: ~/.openclaw/extensions/voipms-sms)
  --branch <name>   Git branch to use (default: main)
  --help            Show this help
EOF
      exit 0
      ;;
    *) err "Unknown option: $1"; exit 1 ;;
  esac
done

# ── Dependency checks ─────────────────────────────────────────────────────────
check_dep() {
  if ! command -v "$1" &>/dev/null; then
    err "Required dependency not found: $1"
    exit 1
  fi
}

check_dep git
check_dep node
check_dep npm

NODE_VERSION="$(node -v 2>/dev/null | sed 's/^v//' | cut -d. -f1)"
if [ "${NODE_VERSION:-0}" -lt 18 ]; then
  err "Node.js >= 18 required (found: $(node -v 2>/dev/null || echo 'none'))"
  exit 1
fi

# ── Header ────────────────────────────────────────────────────────────────────
echo ""
echo -e "${CYAN}╔══════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║${NC}  ${BOLD}voipms-sms Plugin Installer${NC}             ${CYAN}║${NC}"
echo -e "${CYAN}╚══════════════════════════════════════════╝${NC}"
echo ""

# ── Install or upgrade ────────────────────────────────────────────────────────
if [ -d "$INSTALL_DIR/.git" ]; then
  # Existing install — upgrade
  step "Existing installation found at ${BOLD}${INSTALL_DIR}${NC}"

  cd "$INSTALL_DIR"
  CURRENT_VERSION="$(node -p "require('./openclaw.plugin.json').version" 2>/dev/null || echo 'unknown')"
  step "Current version: ${BOLD}v${CURRENT_VERSION}${NC}"

  step "Pulling latest from ${BOLD}${BRANCH}${NC}..."
  git fetch origin "$BRANCH" --quiet
  git checkout "$BRANCH" --quiet 2>/dev/null || true
  git reset --hard "origin/$BRANCH" --quiet

  NEW_VERSION="$(node -p "require('./openclaw.plugin.json').version" 2>/dev/null || echo 'unknown')"

  if [ "$CURRENT_VERSION" = "$NEW_VERSION" ]; then
    info "Already up to date (v${NEW_VERSION})"
  else
    info "Upgraded: v${CURRENT_VERSION} → v${NEW_VERSION}"
  fi
else
  # Fresh install
  step "Installing to ${BOLD}${INSTALL_DIR}${NC}"

  mkdir -p "$(dirname "$INSTALL_DIR")"
  git clone --branch "$BRANCH" --depth 1 --quiet "$REPO" "$INSTALL_DIR"
  cd "$INSTALL_DIR"

  NEW_VERSION="$(node -p "require('./openclaw.plugin.json').version" 2>/dev/null || echo 'unknown')"
  info "Cloned v${NEW_VERSION}"
fi

# ── Install dependencies ──────────────────────────────────────────────────────
if [ -f "package.json" ]; then
  step "Installing dependencies..."
  npm install --production --quiet 2>/dev/null
  info "Dependencies installed"
fi

# ── Verify ────────────────────────────────────────────────────────────────────
step "Verifying installation..."
PLUGIN_ID="$(node -p "require('./openclaw.plugin.json').id" 2>/dev/null || echo '')"
if [ "$PLUGIN_ID" = "voipms-sms" ]; then
  info "Plugin verified: ${BOLD}${PLUGIN_ID}${NC}"
else
  err "Verification failed — openclaw.plugin.json not valid"
  exit 1
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
info "Installation complete!"
echo ""
echo -e "  ${BOLD}Location:${NC}  ${INSTALL_DIR}"
echo -e "  ${BOLD}Version:${NC}   v${NEW_VERSION}"
echo ""
echo -e "  ${BOLD}Next steps:${NC}"
echo -e "  1. Add the plugin to your openclaw.json:"
echo ""
echo -e "     ${CYAN}\"plugins\": {"
echo -e "       \"entries\": {"
echo -e "         \"voipms-sms\": {"
echo -e "           \"module\": \"${INSTALL_DIR}\","
echo -e "           \"config\": {"
echo -e "             \"dbPath\": \"/path/to/your/database.db\","
echo -e "             \"dids\": {}"
echo -e "           }"
echo -e "         }"
echo -e "       }"
echo -e "     }${NC}"
echo ""
echo -e "  2. Configure DIDs with ${BOLD}./manage.sh${NC}"
echo -e "  3. Set API credentials (apiUsername/apiPassword or env vars)"
echo ""
