#!/usr/bin/env bash
# test-lab-09-06.sh — iRedMail Lab 06: Production Deployment
# Module 09 | Lab 06 | Tests: resource limits, restart=always, volumes, email stack, metrics
set -euo pipefail

COMPOSE_FILE="$(dirname "$0")/../docker/docker-compose.production.yml"
CLEANUP=true
for arg in "$@"; do [[ "$arg" == "--no-cleanup" ]] && CLEANUP=false; done

KC_PORT=8208
HTTP_PORT=9280
SMTP_PORT=9026
MAILHOG_PORT=8027
LDAP_PORT=3897
KC_ADMIN_PASS="Prod06Admin!"
LDAP_ADMIN_PASS="LdapProd06!"

PASS=0; FAIL=0
pass() { echo "[PASS] $1"; ((PASS++)) || true; }
fail() { echo "[FAIL] $1"; ((FAIL++)) || true; }
section() { echo ""; echo "=== $1 ==="; }

cleanup() {
  if [[ "$CLEANUP" == "true" ]]; then
    echo "Cleaning up..."
    docker compose -f "$COMPOSE_FILE" down -v --remove-orphans 2>/dev/null || true
  fi
}
trap cleanup EXIT

section "Starting Lab 06 Production Deployment"
docker compose -f "$COMPOSE_FILE" up -d
echo "Waiting for services to initialize..."

section "Health Checks"
for i in $(seq 1 60); do
  status=$(docker inspect iredmail-prod-keycloak --format '{{.State.Health.Status}}' 2>/dev/null || echo "waiting")
  [[ "$status" == "healthy" ]] && break; sleep 5
done
[[ "$(docker inspect iredmail-prod-keycloak --format '{{.State.Health.Status}}')" == "healthy" ]] && pass "Keycloak healthy" || fail "Keycloak not healthy"

for i in $(seq 1 30); do
  status=$(docker inspect iredmail-prod-ldap --format '{{.State.Health.Status}}' 2>/dev/null || echo "waiting")
  [[ "$status" == "healthy" ]] && break; sleep 3
done
[[ "$(docker inspect iredmail-prod-ldap --format '{{.State.Health.Status}}')" == "healthy" ]] && pass "LDAP healthy" || fail "LDAP not healthy"

for i in $(seq 1 30); do
  status=$(docker inspect iredmail-prod-db --format '{{.State.Health.Status}}' 2>/dev/null || echo "waiting")
  [[ "$status" == "healthy" ]] && break; sleep 3
done
[[ "$(docker inspect iredmail-prod-db --format '{{.State.Health.Status}}')" == "healthy" ]] && pass "MariaDB healthy" || fail "MariaDB not healthy"

for i in $(seq 1 90); do
  status=$(docker inspect iredmail-prod-app --format '{{.State.Health.Status}}' 2>/dev/null || echo "waiting")
  [[ "$status" == "healthy" ]] && break; sleep 5
done
[[ "$(docker inspect iredmail-prod-app --format '{{.State.Health.Status}}')" == "healthy" ]] && pass "iRedMail app healthy" || fail "iRedMail app not healthy"

section "Production Configuration Checks"
rp=$(docker inspect iredmail-prod-app --format '{{.HostConfig.RestartPolicy.Name}}')
[[ "$rp" == "always" ]] && pass "iRedMail restart=always" || fail "Restart policy is '$rp'"
rp_kc=$(docker inspect iredmail-prod-keycloak --format '{{.HostConfig.RestartPolicy.Name}}')
[[ "$rp_kc" == "always" ]] && pass "Keycloak restart=always" || fail "Keycloak restart policy is '$rp_kc'"

mem=$(docker inspect iredmail-prod-app --format '{{.HostConfig.Memory}}')
[[ "$mem" -gt 0 ]] && pass "iRedMail memory limit set ($mem bytes)" || fail "iRedMail memory limit not set"
mem_kc=$(docker inspect iredmail-prod-keycloak --format '{{.HostConfig.Memory}}')
[[ "$mem_kc" -gt 0 ]] && pass "Keycloak memory limit set" || fail "Keycloak memory limit not set"

for vol in iredmail-prod-ldap-data iredmail-prod-ldap-config iredmail-prod-db-data iredmail-prod-vmail iredmail-prod-backup; do
  docker volume ls | grep -q "$vol" && pass "Volume $vol exists" || fail "Volume $vol missing"
done

section "LDAP Verification"
ldap_bind=$(docker exec iredmail-prod-ldap ldapsearch -x -H ldap://localhost -b "dc=lab,dc=local" -D "cn=admin,dc=lab,dc=local" -w "$LDAP_ADMIN_PASS" "(objectClass=organizationalUnit)" dn 2>&1)
echo "$ldap_bind" | grep -q "dn:" && pass "LDAP bind and search OK" || fail "LDAP bind failed"

section "Keycloak API & Metrics"
TOKEN=$(curl -sf -X POST "http://localhost:${KC_PORT}/realms/master/protocol/openid-connect/token" \
  -d "client_id=admin-cli&grant_type=password&username=admin&password=${KC_ADMIN_PASS}" \
  | grep -o '"access_token":"[^"]*"' | cut -d'"' -f4)
[[ -n "$TOKEN" ]] && pass "Keycloak admin token obtained" || fail "Keycloak admin token failed"

REALM_EXISTS=$(curl -sf -H "Authorization: Bearer $TOKEN" "http://localhost:${KC_PORT}/admin/realms" | grep -o '"realm":"it-stack"' | wc -l || echo 0)
if [[ "$REALM_EXISTS" -gt 0 ]]; then
  pass "Realm it-stack exists"
else
  curl -sf -X POST "http://localhost:${KC_PORT}/admin/realms" \
    -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
    -d '{"realm":"it-stack","enabled":true,"displayName":"IT-Stack Production"}'
  pass "Realm it-stack created"
fi

CLIENT_EXISTS=$(curl -sf -H "Authorization: Bearer $TOKEN" "http://localhost:${KC_PORT}/admin/realms/it-stack/clients?clientId=iredmail-client" | grep -o '"clientId":"iredmail-client"' | wc -l || echo 0)
if [[ "$CLIENT_EXISTS" -gt 0 ]]; then
  pass "OIDC client iredmail-client exists"
else
  curl -sf -X POST "http://localhost:${KC_PORT}/admin/realms/it-stack/clients" \
    -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
    -d '{"clientId":"iredmail-client","enabled":true,"protocol":"openid-connect","secret":"iredmail-prod-06","redirectUris":["http://localhost:'"${HTTP_PORT}"'/*"]}'
  pass "OIDC client iredmail-client created"
fi

curl -sf "http://localhost:${KC_PORT}/metrics" | grep -q "keycloak" && pass "Keycloak /metrics endpoint returns data" || fail "Keycloak /metrics not responding"

section "iRedMail Web"
curl -sf "http://localhost:${HTTP_PORT}/" | grep -qi "iredmail\|SOGo\|roundcube\|webmail\|nginx" && pass "iRedMail web UI responding" || fail "iRedMail web not reachable"

section "SMTP Relay (Mailhog)"
curl -sf "http://localhost:${MAILHOG_PORT}/" | grep -qi "mailhog\|swaggerui" && pass "Mailhog UI responding" || fail "Mailhog UI not reachable"

section "Log Rotation Configuration"
log_driver=$(docker inspect iredmail-prod-app --format '{{.HostConfig.LogConfig.Type}}')
[[ "$log_driver" == "json-file" ]] && pass "Log driver is json-file" || fail "Log driver is '$log_driver'"

echo ""
echo "================================================"
echo "Lab 06 Results: ${PASS} passed, ${FAIL} failed"
echo "================================================"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1