#!/usr/bin/env bash
set -Eeuo pipefail
set +x

GRAFANA_URL="${GRAFANA_URL:-http://127.0.0.1:30300}"
REPORT_DIR="${GRAFANA_REPORT_DIR:-reports/phase-29-grafana}"

mkdir -p "${REPORT_DIR}"

echo '=================================================='
echo 'GRAFANA MONITORING VERIFICATION'
echo '=================================================='

command -v curl >/dev/null 2>&1
command -v jq >/dev/null 2>&1

: "${GRAFANA_USER:?GRAFANA_USER is required}"
: "${GRAFANA_PASSWORD:?GRAFANA_PASSWORD is required}"

echo
echo '========== 1. GRAFANA HEALTH =========='

HEALTH_HTTP="$(
  curl \
    --silent \
    --show-error \
    --connect-timeout 5 \
    --max-time 30 \
    --output "${REPORT_DIR}/health.json" \
    --write-out '%{http_code}' \
    "${GRAFANA_URL}/api/health"
)"

echo "GrafanaHealthHTTP=${HEALTH_HTTP}"

if [ "${HEALTH_HTTP}" != '200' ]; then
  echo 'FAIL: Grafana health endpoint is unavailable'
  exit 1
fi

jq . "${REPORT_DIR}/health.json"

DATABASE_STATUS="$(
  jq -r '.database // "unknown"' \
    "${REPORT_DIR}/health.json"
)"

echo "GrafanaDatabase=${DATABASE_STATUS}"

if [ "${DATABASE_STATUS}" != 'ok' ]; then
  echo 'FAIL: Grafana database health is not OK'
  exit 1
fi

echo
echo '========== 2. PROMETHEUS DATASOURCE =========='

DATASOURCE_HTTP="$(
  curl \
    --silent \
    --show-error \
    --user "${GRAFANA_USER}:${GRAFANA_PASSWORD}" \
    --connect-timeout 5 \
    --max-time 30 \
    --output "${REPORT_DIR}/datasource.json" \
    --write-out '%{http_code}' \
    "${GRAFANA_URL}/api/datasources/uid/prometheus"
)"

echo "GrafanaDatasourceHTTP=${DATASOURCE_HTTP}"

if [ "${DATASOURCE_HTTP}" != '200' ]; then
  echo 'FAIL: Prometheus datasource not found in Grafana'
  exit 1
fi

jq '
  {
    name,
    uid,
    type,
    url,
    isDefault
  }
' "${REPORT_DIR}/datasource.json"

DATASOURCE_TYPE="$(
  jq -r '.type' \
    "${REPORT_DIR}/datasource.json"
)"

DATASOURCE_URL="$(
  jq -r '.url' \
    "${REPORT_DIR}/datasource.json"
)"

DATASOURCE_DEFAULT="$(
  jq -r '.isDefault' \
    "${REPORT_DIR}/datasource.json"
)"

echo
echo "GrafanaDatasourceType=${DATASOURCE_TYPE}"
echo "GrafanaDatasourceURL=${DATASOURCE_URL}"
echo "GrafanaDatasourceDefault=${DATASOURCE_DEFAULT}"

test "${DATASOURCE_TYPE}" = 'prometheus'
test "${DATASOURCE_URL}" = 'http://prometheus:9090'
test "${DATASOURCE_DEFAULT}" = 'true'

echo
echo '========== 3. DATASOURCE HEALTH =========='

DS_HEALTH_HTTP="$(
  curl \
    --silent \
    --show-error \
    --user "${GRAFANA_USER}:${GRAFANA_PASSWORD}" \
    --connect-timeout 5 \
    --max-time 30 \
    --output "${REPORT_DIR}/datasource-health.json" \
    --write-out '%{http_code}' \
    "${GRAFANA_URL}/api/datasources/uid/prometheus/health"
)"

echo "GrafanaDatasourceHealthHTTP=${DS_HEALTH_HTTP}"

if [ "${DS_HEALTH_HTTP}" != '200' ]; then
  echo 'FAIL: Grafana cannot reach Prometheus datasource'
  cat "${REPORT_DIR}/datasource-health.json"
  exit 1
fi

jq . "${REPORT_DIR}/datasource-health.json"

echo
echo '========== 4. VAULT BANK DASHBOARD =========='

curl \
  --silent \
  --show-error \
  --fail \
  --user "${GRAFANA_USER}:${GRAFANA_PASSWORD}" \
  --get \
  --data-urlencode 'type=dash-db' \
  "${GRAFANA_URL}/api/search" \
  > "${REPORT_DIR}/dashboards.json"

jq -r '
  .[]
  |
  [
    .title,
    .uid,
    .url
  ]
  | @tsv
' "${REPORT_DIR}/dashboards.json" |
tee "${REPORT_DIR}/dashboards.txt"

DASHBOARD_COUNT="$(
  jq 'length' \
    "${REPORT_DIR}/dashboards.json"
)"

EXPECTED_TITLE=''

if [ -f observability/grafana/vaultbank-dashboard.json ]; then
  EXPECTED_TITLE="$(
    jq -r '.title // empty' \
      observability/grafana/vaultbank-dashboard.json
  )"
fi

echo
echo "GrafanaDashboardCount=${DASHBOARD_COUNT}"
echo "ExpectedDashboardTitle=${EXPECTED_TITLE}"

if [ "${DASHBOARD_COUNT}" -lt 1 ]; then
  echo 'FAIL: no Grafana dashboards loaded'
  exit 1
fi

if [ -n "${EXPECTED_TITLE}" ]; then

  EXPECTED_COUNT="$(
    jq \
      --arg title "${EXPECTED_TITLE}" '
        [
          .[]
          | select(.title == $title)
        ]
        | length
      ' "${REPORT_DIR}/dashboards.json"
  )"

  echo "ExpectedDashboardFound=${EXPECTED_COUNT}"

  if [ "${EXPECTED_COUNT}" -lt 1 ]; then
    echo "FAIL: expected dashboard '${EXPECTED_TITLE}' is not loaded"
    exit 1
  fi
fi

echo
echo '========== 5. QUERY PROMETHEUS THROUGH GRAFANA =========='

curl \
  --silent \
  --show-error \
  --fail \
  --user "${GRAFANA_USER}:${GRAFANA_PASSWORD}" \
  --get \
  --data-urlencode 'query=up{job="vaultbank-services"}' \
  "${GRAFANA_URL}/api/datasources/proxy/uid/prometheus/api/v1/query" \
  > "${REPORT_DIR}/grafana-prometheus-query.json"

jq -e \
  '.status == "success"' \
  "${REPORT_DIR}/grafana-prometheus-query.json" \
  >/dev/null

jq -r '
  .data.result[]
  |
  [
    (.metric.service // "unknown"),
    (.metric.namespace // "unknown"),
    .value[1]
  ]
  | @tsv
' "${REPORT_DIR}/grafana-prometheus-query.json" |
tee "${REPORT_DIR}/vaultbank-targets.txt"

TOTAL="$(
  jq '
    .data.result
    | length
  ' "${REPORT_DIR}/grafana-prometheus-query.json"
)"

UP="$(
  jq '
    [
      .data.result[]
      | select(.value[1] == "1")
    ]
    | length
  ' "${REPORT_DIR}/grafana-prometheus-query.json"
)"

echo
echo "GrafanaVaultBankTargets=${TOTAL}"
echo "GrafanaVaultBankTargetsUp=${UP}"

if [ "${TOTAL}" -ne 10 ]; then
  echo "FAIL: Grafana returned ${TOTAL} Vault Bank targets; expected 10"
  exit 1
fi

if [ "${UP}" -ne 10 ]; then
  echo "FAIL: only ${UP}/5 Vault Bank targets are UP through Grafana"
  exit 1
fi

cat > "${REPORT_DIR}/summary.txt" <<SUMMARY
GrafanaHealthHTTP=${HEALTH_HTTP}
GrafanaDatabase=${DATABASE_STATUS}
GrafanaDatasourceHTTP=${DATASOURCE_HTTP}
GrafanaDatasourceHealthHTTP=${DS_HEALTH_HTTP}
GrafanaDatasourceType=${DATASOURCE_TYPE}
GrafanaDatasourceURL=${DATASOURCE_URL}
GrafanaDashboardCount=${DASHBOARD_COUNT}
GrafanaVaultBankTargets=${TOTAL}
GrafanaVaultBankTargetsUp=${UP}
GrafanaReady=true
GrafanaPrometheusConnected=true
GrafanaDashboardLoaded=true
GrafanaVerificationPassed=true
SUMMARY

echo
echo '========== GRAFANA SUMMARY =========='

cat "${REPORT_DIR}/summary.txt"

echo
echo 'PASS: Grafana monitoring verification completed'
