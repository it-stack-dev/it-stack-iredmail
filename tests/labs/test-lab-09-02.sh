#!/usr/bin/env bash
# test-lab-09-02.sh — Lab 09-02: External Dependencies
# Module 09: iRedMail — OpenLDAP directory, mailhog SMTP relay, separate networks
set -euo pipefail

LAB_ID="09-02"
LAB_NAME="External Dependencies"
MODULE="iredmail"
COMPOSE_FILE="docker/docker-compose.lan.yml"
PASS=0
FAIL=0

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; NC='\033[0m'

pass() { echo -e "${GREEN}[PASS]${NC} $1"; ((PASS++)); }
fail() { echo -e "${RED}[FAIL]${NC} $1"; ((FAIL++)); }
info() { echo -e "${CYAN}[INFO]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }

echo -e "${CYAN}======================================${NC}"
echo -e "${CYAN} Lab ${LAB_ID}: ${LAB_NAME}${NC}"
echo -e "${CYAN} Module: ${MODULE}${NC}"
echo -e "${CYAN}======================================${NC}"
echo ""

# ── PHASE 1: Setup ────────────────────────────────────────────────────────────
info "Phase 1: Setup"
docker compose -f "${COMPOSE_FILE}" up -d
info "Waiting for OpenLDAP..."
timeout 60 bash -c 'until timeout 3 bash -c "echo > /dev/tcp/localhost/389" 2>/dev/null; do sleep 2; done'
info "Waiting for iRedMail webmail (first boot ~3-4 min)..."
timeout 360 bash -c 'until curl -sf http://localhost:9080/ | grep -qi "roundcube\|webmail\|login"; do sleep 10; done'

# ── PHASE 2: Health Checks ────────────────────────────────────────────────────
info "Phase 2: Health Checks"

for c in iredmail-lan-ldap iredmail-lan-smtp-relay iredmail-lan-app; do
  if docker ps --filter "name=^/${c}$" --filter "status=running" --format '{{.Names}}' | grep -q "${c}"; then
    pass "Container ${c} is running"
  else
    fail "Container ${c} is not running"
  fi
done

if timeout 5 bash -c 'echo > /dev/tcp/localhost/389' 2>/dev/null; then
  pass "LDAP: port 389 reachable"
else
  fail "LDAP: port 389 not reachable"
fi

if curl -sf http://localhost:8025/api/v2/messages > /dev/null 2>&1; then
  pass "Mailhog web UI: reachable (:8025)"
else
  fail "Mailhog web UI: not reachable"
fi

if curl -sf http://localhost:9080/ | grep -qi 'roundcube\|webmail\|login'; then
  pass "iRedMail webmail: HTTP :9080 OK"
else
  fail "iRedMail webmail: HTTP :9080 failed"
fi

# ── PHASE 3: Functional Tests ─────────────────────────────────────────────────
info "Phase 3: Functional Tests (Lab 02 — External Dependencies)"

# Key Lab 02 test: LDAP directory search
info "Querying LDAP directory..."
LDAP_RESULT=$(docker compose -f "${COMPOSE_FILE}" exec -T ldap \
  ldapsearch -x -H ldap://localhost \
  -D 'cn=admin,dc=lab,dc=local' -w 'Lab02Password!' \
  -b 'dc=lab,dc=local' '(objectClass=*)' dn 2>&1 | head -10 || echo "")
if echo "${LDAP_RESULT}" | grep -q 'result: 0\|dc=lab'; then
  pass "LDAP: search succeeded (base DN dc=lab,dc=local)"
else
  fail "LDAP: search failed"
fi

# LDAP readonly bind
LDAP_RO=$(docker compose -f "${COMPOSE_FILE}" exec -T ldap \
  ldapsearch -x -H ldap://localhost \
  -D 'cn=readonly,dc=lab,dc=local' -w 'Lab02Readonly!' \
  -b 'dc=lab,dc=local' '(objectClass=organizationalUnit)' dn 2>&1 | head -5 || echo "")
if echo "${LDAP_RO}" | grep -q 'result: 0\|dn:'; then
  pass "LDAP readonly bind: successful"
else
  warn "LDAP readonly bind: check if readonly user was initialized"
fi

if curl -sf http://localhost:9080/mail/ | grep -qi 'roundcube\|login'; then
  pass "Roundcube webmail: /mail/ accessible"
else
  fail "Roundcube webmail: /mail/ not accessible"
fi

SMTP_BANNER=$(timeout 5 bash -c 'echo QUIT | nc -w3 localhost 9025 2>/dev/null' | head -1 || echo "")
if echo "${SMTP_BANNER}" | grep -qi '220\|smtp\|esmtp\|postfix'; then
  pass "SMTP :9025 banner: ${SMTP_BANNER}"
else
  fail "SMTP :9025 banner: no response"
fi

IMAP_BANNER=$(timeout 5 bash -c 'echo LOGOUT | nc -w3 localhost 9143 2>/dev/null' | head -1 || echo "")
if echo "${IMAP_BANNER}" | grep -qi '\* OK\|dovecot\|imap'; then
  pass "IMAP :9143 banner: ${IMAP_BANNER}"
else
  fail "IMAP :9143 banner: no response"
fi

SUBM_BANNER=$(timeout 5 bash -c 'echo QUIT | nc -w3 localhost 9587 2>/dev/null' | head -1 || echo "")
if echo "${SUBM_BANNER}" | grep -qi '220\|smtp'; then
  pass "Submission :9587 banner: ${SUBM_BANNER}"
else
  warn "Submission :9587: banner not detected"
fi

if docker compose -f "${COMPOSE_FILE}" exec -T iredmail \
    postfix status 2>/dev/null | grep -qi 'running'; then
  pass "Postfix: service running"
else
  warn "Postfix: 'postfix status' inconclusive"
fi

if docker compose -f "${COMPOSE_FILE}" exec -T iredmail \
    sh -c 'pgrep -x dovecot > /dev/null 2>&1 && echo running' 2>/dev/null | grep -q running; then
  pass "Dovecot: process running"
else
  warn "Dovecot: pgrep check inconclusive"
fi

if curl -sf http://localhost:9080/iredadmin/ | grep -qi 'iredadmin\|login\|admin'; then
  pass "iRedAdmin: /iredadmin/ accessible"
else
  warn "iRedAdmin: not reachable at /iredadmin/"
fi

# ── PHASE 4: Cleanup ──────────────────────────────────────────────────────────
info "Phase 4: Cleanup"
docker compose -f "${COMPOSE_FILE}" down -v --remove-orphans
info "Cleanup complete"

# ── Results ───────────────────────────────────────────────────────────────────
echo ""
echo -e "${CYAN}======================================${NC}"
echo -e " Lab ${LAB_ID} Complete"
echo -e " ${GREEN}PASS: ${PASS}${NC} | ${RED}FAIL: ${FAIL}${NC}"
echo -e "${CYAN}======================================${NC}"

if [ "${FAIL}" -gt 0 ]; then
  exit 1
fi