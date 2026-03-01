#!/usr/bin/env bash
# test-lab-09-05.sh -- Lab 05: iRedMail Advanced Integration
# Tests: OpenLDAP bind, Keycloak realm+LDAP-federation, iRedMail LDAP config, mailhog relay
#
# Usage: bash tests/labs/test-lab-09-05.sh [--no-cleanup]
set -euo pipefail

COMPOSE_FILE="docker/docker-compose.integration.yml"
KC_PORT=8108
MAIL_PORT=9180
LDAP_PORT=3892
MAILHOG_PORT=8025
KC_ADMIN=admin
KC_PASS="Lab05Admin!"
LDAP_ADMIN_DN="cn=admin,dc=lab,dc=local"
LDAP_PASS="LdapAdmin05!"
READONLY_DN="cn=readonly,dc=lab,dc=local"
READONLY_PASS="ReadOnly05!"
CLEANUP=true
[[ "${1:-}" == "--no-cleanup" ]] && CLEANUP=false

PASS=0; FAIL=0
pass() { echo "[PASS] $1"; ((PASS++)); }
fail() { echo "[FAIL] $1"; ((FAIL++)); }
section() { echo ""; echo "=== $1 ==="; }
cleanup() { $CLEANUP && docker compose -f "$COMPOSE_FILE" down -v 2>/dev/null || true; }
trap cleanup EXIT

section "Lab 09-05: iRedMail Advanced Integration"
echo "Compose file: $COMPOSE_FILE"

section "1. Start Containers"
docker compose -f "$COMPOSE_FILE" up -d
echo "Waiting for services to initialize..."
sleep 40

section "2. Keycloak Health"
for i in $(seq 1 24); do
  if curl -sf "http://localhost:${KC_PORT}/health/ready" | grep -q "UP"; then
    pass "Keycloak health/ready UP"
    break
  fi
  [[ $i -eq 24 ]] && fail "Keycloak did not become healthy" && exit 1
  sleep 10
done

section "3. OpenLDAP Connectivity"
for i in $(seq 1 12); do
  if docker exec iredmail-int-ldap ldapsearch -x -H ldap://localhost \
     -b "dc=lab,dc=local" -D "$LDAP_ADMIN_DN" -w "$LDAP_PASS" \
     -s base "(objectClass=*)" >/dev/null 2>&1; then
    pass "LDAP admin bind successful"
    break
  fi
  [[ $i -eq 12 ]] && fail "LDAP admin bind failed after 120s"
  sleep 10
done

# Readonly bind
if docker exec iredmail-int-ldap ldapsearch -x -H ldap://localhost \
   -b "dc=lab,dc=local" -D "$READONLY_DN" -w "$READONLY_PASS" \
   -s base "(objectClass=*)" >/dev/null 2>&1; then
  pass "LDAP readonly bind successful"
else
  fail "LDAP readonly bind failed"
fi

section "4. Keycloak Realm + LDAP Federation"
KC_TOKEN=$(curl -sf "http://localhost:${KC_PORT}/realms/master/protocol/openid-connect/token" \
  -d "client_id=admin-cli&grant_type=password&username=${KC_ADMIN}&password=${KC_PASS}" \
  | grep -o '"access_token":"[^"]*"' | cut -d'"' -f4)
[[ -n "$KC_TOKEN" ]] && pass "Keycloak admin token obtained" || { fail "Keycloak admin token failed"; exit 1; }

HTTP=$(curl -s -o /dev/null -w "%{http_code}" -X POST \
  "http://localhost:${KC_PORT}/admin/realms" \
  -H "Authorization: Bearer $KC_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"realm":"it-stack","enabled":true}')
[[ "$HTTP" =~ ^(201|409)$ ]] && pass "Realm it-stack created (HTTP $HTTP)" || fail "Realm creation failed (HTTP $HTTP)"

LDAP_FED_PAYLOAD='{"name":"ldap","providerId":"ldap","providerType":"org.keycloak.storage.UserStorageProvider","config":{"vendor":["other"],"connectionUrl":["ldap://iredmail-int-ldap:389"],"bindDn":["'"$LDAP_ADMIN_DN"'"],"bindCredential":["LdapAdmin05!"],"usersDn":["dc=lab,dc=local"],"usernameLDAPAttribute":["uid"],"rdnLDAPAttribute":["uid"],"uuidLDAPAttribute":["entryUUID"],"userObjectClasses":["inetOrgPerson"],"syncRegistrations":["false"],"enabled":["true"]}}'
HTTP=$(curl -s -o /dev/null -w "%{http_code}" -X POST \
  "http://localhost:${KC_PORT}/admin/realms/it-stack/components" \
  -H "Authorization: Bearer $KC_TOKEN" \
  -H "Content-Type: application/json" \
  -d "$LDAP_FED_PAYLOAD")
[[ "$HTTP" =~ ^(201|409)$ ]] && pass "Keycloak LDAP federation registered (HTTP $HTTP)" || fail "LDAP federation failed (HTTP $HTTP)"

section "5. iRedMail Environment"
APP_ENV=$(docker inspect iredmail-int-app --format '{{range .Config.Env}}{{.}} {{end}}')

echo "$APP_ENV" | grep -q "LDAP_SERVER_HOST=iredmail-int-ldap" \
  && pass "LDAP_SERVER_HOST=iredmail-int-ldap" \
  || fail "LDAP_SERVER_HOST missing"

echo "$APP_ENV" | grep -q "LDAP_BIND_DN=cn=readonly" \
  && pass "LDAP_BIND_DN uses readonly account" \
  || fail "LDAP_BIND_DN missing/wrong"

echo "$APP_ENV" | grep -q "LDAP_BASEDN=dc=lab,dc=local" \
  && pass "LDAP_BASEDN=dc=lab,dc=local" \
  || fail "LDAP_BASEDN missing"

echo "$APP_ENV" | grep -q "RELAY_HOST=iredmail-int-smtp-relay" \
  && pass "RELAY_HOST=iredmail-int-smtp-relay" \
  || fail "RELAY_HOST missing"

section "6. iRedMail HTTP Admin Panel"
for i in $(seq 1 20); do
  HTTP=$(curl -s -o /dev/null -w "%{http_code}" "http://localhost:${MAIL_PORT}/" 2>/dev/null || echo "000")
  if [[ "$HTTP" =~ ^(200|302|301)$ ]]; then
    pass "iRedMail HTTP admin panel responds (HTTP $HTTP)"
    break
  fi
  [[ $i -eq 20 ]] && fail "iRedMail admin panel did not become ready (last HTTP $HTTP)"
  sleep 15
done

section "7. Mailhog SMTP Relay"
HTTP=$(curl -s -o /dev/null -w "%{http_code}" "http://localhost:${MAILHOG_PORT}/" 2>/dev/null || echo "000")
[[ "$HTTP" =~ ^(200|302)$ ]] \
  && pass "Mailhog web UI accessible (HTTP $HTTP)" \
  || fail "Mailhog web UI unreachable (HTTP $HTTP)"

section "8. Keycloak LDAP Components Listed"
COMPONENTS=$(curl -sf "http://localhost:${KC_PORT}/admin/realms/it-stack/components?type=org.keycloak.storage.UserStorageProvider" \
  -H "Authorization: Bearer $KC_TOKEN" 2>/dev/null || echo "[]")
echo "$COMPONENTS" | grep -q "ldap" \
  && pass "Keycloak LDAP user storage provider listed" \
  || fail "Keycloak LDAP provider not found in components"

section "Summary"
echo "Passed: $PASS | Failed: $FAIL"
[[ $FAIL -eq 0 ]] && echo "Lab 09-05 PASSED" || { echo "Lab 09-05 FAILED"; exit 1; }