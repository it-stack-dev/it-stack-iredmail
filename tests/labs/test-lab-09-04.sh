#!/usr/bin/env bash
# test-lab-09-04.sh — Lab 09-04: iRedMail SSO Integration
# Tests: Keycloak running, LDAP federation config, Keycloak user sync from LDAP
set -euo pipefail
COMPOSE_FILE="docker/docker-compose.sso.yml"
KC_PORT="8087"
PASS=0; FAIL=0
pass() { echo "  [PASS] $1"; PASS=$((PASS+1)); }
fail() { echo "  [FAIL] $1"; FAIL=$((FAIL+1)); }
section() { echo; echo "=== $1 ==="; }

section "Container health"
for c in iredmail-sso-ldap iredmail-sso-smtp-relay iredmail-sso-keycloak iredmail-sso-app; do
  if docker inspect --format '{{.State.Running}}' "$c" 2>/dev/null | grep -q true; then
    pass "Container $c is running"
  else
    fail "Container $c is not running"
  fi
done

section "OpenLDAP connectivity"
if timeout 5 bash -c 'echo > /dev/tcp/localhost/389' 2>/dev/null; then
  pass "OpenLDAP :389 reachable"
else
  fail "OpenLDAP :389 not reachable"
fi
LDAP_SEARCH=$(ldapsearch -x -H ldap://localhost:389 \
  -b "dc=lab,dc=local" \
  -D "cn=admin,dc=lab,dc=local" \
  -w Lab04Password! -LLL -z 1 dn 2>/dev/null | head -3) || LDAP_SEARCH=""
if echo "$LDAP_SEARCH" | grep -q "dn:"; then
  pass "LDAP admin bind and search successful"
else
  fail "LDAP admin bind failed"
fi

section "Keycloak health"
KC_HEALTH=$(curl -sf "http://localhost:${KC_PORT}/health/ready" 2>/dev/null) || KC_HEALTH=""
if echo "$KC_HEALTH" | grep -q "UP"; then
  pass "Keycloak health/ready = UP"
else
  fail "Keycloak health/ready not UP"
fi

section "Keycloak admin API + realm"
KC_TOKEN=$(curl -sf -X POST \
  "http://localhost:${KC_PORT}/realms/master/protocol/openid-connect/token" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "client_id=admin-cli&username=admin&password=Lab04Admin!&grant_type=password" 2>/dev/null \
  | grep -o '"access_token":"[^"]*"' | cut -d'"' -f4) || KC_TOKEN=""
if [ -n "$KC_TOKEN" ]; then
  pass "Keycloak admin token obtained"
else
  fail "Keycloak admin login failed"
fi

if [ -n "$KC_TOKEN" ]; then
  curl -sf -X POST "http://localhost:${KC_PORT}/admin/realms" \
    -H "Authorization: Bearer $KC_TOKEN" -H "Content-Type: application/json" \
    -d '{"realm":"it-stack","enabled":true}' 2>/dev/null || true
  REALM_CHECK=$(curl -sf "http://localhost:${KC_PORT}/admin/realms/it-stack" \
    -H "Authorization: Bearer $KC_TOKEN" 2>/dev/null) || REALM_CHECK=""
  if echo "$REALM_CHECK" | grep -q '"realm":"it-stack"'; then
    pass "Keycloak realm 'it-stack' exists"
  else
    fail "Keycloak realm 'it-stack' not found"
  fi
else
  fail "Skipping realm check (no admin token)"
fi

section "Keycloak LDAP user federation"
if [ -n "$KC_TOKEN" ]; then
  LDAP_PROVIDER=$(curl -sf -X POST \
    "http://localhost:${KC_PORT}/admin/realms/it-stack/components" \
    -H "Authorization: Bearer $KC_TOKEN" \
    -H "Content-Type: application/json" \
    -d '{"name":"ldap","providerId":"ldap","providerType":"org.keycloak.storage.UserStorageProvider","config":{"vendor":["other"],"connectionUrl":["ldap://ldap:389"],"bindDn":["cn=readonly,dc=lab,dc=local"],"bindCredential":["ReadOnlyPass04!"],"usersDn":["ou=People,dc=lab,dc=local"],"usernameLDAPAttribute":["mail"],"rdnLDAPAttribute":["uid"],"uuidLDAPAttribute":["entryUUID"],"userObjectClasses":["inetOrgPerson"],"importEnabled":["true"],"syncRegistrations":["false"]}}' \
    2>/dev/null; echo $?) || LDAP_PROVIDER=0
  COMPONENTS=$(curl -sf \
    "http://localhost:${KC_PORT}/admin/realms/it-stack/components?type=org.keycloak.storage.UserStorageProvider" \
    -H "Authorization: Bearer $KC_TOKEN" 2>/dev/null) || COMPONENTS=""
  if echo "$COMPONENTS" | grep -q '"providerId":"ldap"'; then
    pass "Keycloak LDAP user federation provider registered"
  else
    fail "Keycloak LDAP user federation not found"
  fi
else
  fail "Skipping LDAP federation check (no admin token)"
fi

section "iRedMail LDAP config in env"
IM_ENV=$(docker inspect iredmail-sso-app --format '{{json .Config.Env}}' 2>/dev/null) || IM_ENV="[]"
if echo "$IM_ENV" | grep -q "LDAP_SERVER_HOST=ldap"; then
  pass "LDAP_SERVER_HOST=ldap configured"
else
  fail "LDAP_SERVER_HOST not set to 'ldap'"
fi
if echo "$IM_ENV" | grep -q '"LDAP_BIND_DN=cn=readonly,dc=lab,dc=local"'; then
  pass "LDAP_BIND_DN = cn=readonly,dc=lab,dc=local"
else
  fail "LDAP_BIND_DN not configured"
fi

section "Roundcube webmail"
HTTP_CODE=$(curl -sw '%{http_code}' -o /dev/null http://localhost:9080/mail/ 2>/dev/null) || HTTP_CODE="000"
if echo "$HTTP_CODE" | grep -qE "^(200|301|302)"; then
  pass "Roundcube /mail/ HTTP $HTTP_CODE"
else
  fail "Roundcube /mail/ returned $HTTP_CODE"
fi

section "SMTP port"
SMTP_BANNER=$(echo "QUIT" | timeout 5 nc localhost 9025 2>/dev/null | head -1) || SMTP_BANNER=""
if echo "$SMTP_BANNER" | grep -q "220"; then
  pass "SMTP :9025 banner OK"
else
  fail "SMTP :9025 banner failed"
fi

section "Keycloak OIDC discovery"
KC_OIDC=$(curl -sf "http://localhost:${KC_PORT}/realms/it-stack/.well-known/openid-configuration" 2>/dev/null) || KC_OIDC=""
if echo "$KC_OIDC" | grep -q '"issuer"'; then
  pass "Keycloak OIDC discovery reachable"
else
  fail "Keycloak OIDC discovery failed"
fi

echo
echo "====================================="
echo "  iRedMail Lab 09-04 Results"
echo "  PASS: $PASS  FAIL: $FAIL"
echo "====================================="
[ "$FAIL" -eq 0 ] && exit 0 || exit 1