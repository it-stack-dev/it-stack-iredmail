#!/usr/bin/env bash
# test-lab-09-03.sh — Lab 09-03: iRedMail Advanced Features
# Tests: DKIM config, resource limits, STARTTLS, LDAP auth
set -euo pipefail
COMPOSE_FILE="docker/docker-compose.advanced.yml"
PASS=0; FAIL=0
pass() { echo "  [PASS] $1"; PASS=$((PASS+1)); }
fail() { echo "  [FAIL] $1"; FAIL=$((FAIL+1)); }
section() { echo; echo "=== $1 ==="; }

section "Container health"
for c in iredmail-adv-ldap iredmail-adv-smtp-relay iredmail-adv-app; do
  if docker inspect --format '{{.State.Running}}' "$c" 2>/dev/null | grep -q true; then
    pass "Container $c is running"
  else
    fail "Container $c is not running"
  fi
done

section "LDAP connectivity"
if timeout 5 bash -c 'echo > /dev/tcp/localhost/389' 2>/dev/null; then
  pass "OpenLDAP :389 reachable"
else
  fail "OpenLDAP :389 not reachable"
fi
LDAP_SEARCH=$(ldapsearch -x -H ldap://localhost:389 \
  -b "dc=lab,dc=local" \
  -D "cn=admin,dc=lab,dc=local" \
  -w Lab03Password! \
  -LLL -z 1 dn 2>/dev/null | head -3) || LDAP_SEARCH=""
if echo "$LDAP_SEARCH" | grep -q "dn:"; then
  pass "LDAP admin bind and search successful"
else
  fail "LDAP admin bind failed"
fi

section "LDAP read-only bind"
LDAP_RO=$(ldapsearch -x -H ldap://localhost:389 \
  -b "dc=lab,dc=local" \
  -D "cn=readonly,dc=lab,dc=local" \
  -w ReadOnlyPass03! \
  -LLL -z 1 dn 2>/dev/null | head -3) || LDAP_RO=""
if echo "$LDAP_RO" | grep -q "dn:"; then
  pass "LDAP readonly bind successful"
else
  fail "LDAP readonly bind failed"
fi

section "Mailhog SMTP relay"
if timeout 5 bash -c 'echo > /dev/tcp/localhost/8025' 2>/dev/null; then
  pass "Mailhog UI :8025 reachable"
else
  fail "Mailhog :8025 not reachable"
fi

section "Roundcube webmail"
HTTP_CODE=$(curl -sw '%{http_code}' -o /dev/null http://localhost:9080/mail/ 2>/dev/null) || HTTP_CODE="000"
if echo "$HTTP_CODE" | grep -qE "^(200|301|302)"; then
  pass "Roundcube /mail/ HTTP $HTTP_CODE"
else
  fail "Roundcube /mail/ returned $HTTP_CODE"
fi

section "DKIM configuration in container env"
IM_ENV=$(docker inspect iredmail-adv-app --format '{{json .Config.Env}}' 2>/dev/null) || IM_ENV="[]"
if echo "$IM_ENV" | grep -q '"ENABLE_DKIM=1"'; then
  pass "ENABLE_DKIM=1 set in iredmail-adv-app"
else
  fail "ENABLE_DKIM=1 not found in container env"
fi
if echo "$IM_ENV" | grep -q '"DKIM_SELECTOR=lab"'; then
  pass "DKIM_SELECTOR=lab set in iredmail-adv-app"
else
  fail "DKIM_SELECTOR=lab not found in container env"
fi

section "DKIM keys in container"
DKIM_FILES=$(docker exec iredmail-adv-app ls /opt/dkim/ 2>/dev/null) || DKIM_FILES=""
if [ -n "$DKIM_FILES" ]; then
  pass "DKIM keys directory /opt/dkim/ has content: $DKIM_FILES"
else
  DKIM_FILES2=$(docker exec iredmail-adv-app ls /etc/opendkim/keys/ 2>/dev/null) || DKIM_FILES2=""
  if [ -n "$DKIM_FILES2" ]; then
    pass "DKIM keys found at /etc/opendkim/keys/: $DKIM_FILES2"
  else
    fail "No DKIM keys found in /opt/dkim/ or /etc/opendkim/keys/"
  fi
fi

section "SMTP banner"
SMTP_BANNER=$(echo "QUIT" | timeout 5 nc localhost 9025 2>/dev/null | head -1) || SMTP_BANNER=""
if echo "$SMTP_BANNER" | grep -q "220"; then
  pass "SMTP :9025 banner: $SMTP_BANNER"
else
  fail "SMTP :9025 banner failed: '$SMTP_BANNER'"
fi

section "SMTP STARTTLS available"
EHLO_RESP=$(printf "EHLO test\nQUIT\n" | timeout 5 nc localhost 9025 2>/dev/null) || EHLO_RESP=""
if echo "$EHLO_RESP" | grep -q "STARTTLS"; then
  pass "SMTP EHLO advertises STARTTLS"
else
  fail "SMTP EHLO does not advertise STARTTLS"
fi

section "IMAP port"
IMAP_BANNER=$(echo "" | timeout 5 nc localhost 9143 2>/dev/null | head -1) || IMAP_BANNER=""
if echo "$IMAP_BANNER" | grep -q "OK"; then
  pass "IMAP :9143 banner OK"
else
  fail "IMAP :9143 banner failed"
fi

section "Resource limits check"
IM_MEM=$(docker inspect iredmail-adv-app --format '{{.HostConfig.Memory}}' 2>/dev/null) || IM_MEM="0"
if [ "$IM_MEM" = "1073741824" ]; then
  pass "iredmail-adv-app memory limit = 1G (1073741824 bytes)"
else
  fail "iredmail-adv-app memory limit: expected 1073741824, got $IM_MEM"
fi

echo
echo "====================================="
echo "  iRedMail Lab 09-03 Results"
echo "  PASS: $PASS  FAIL: $FAIL"
echo "====================================="
[ "$FAIL" -eq 0 ] && exit 0 || exit 1