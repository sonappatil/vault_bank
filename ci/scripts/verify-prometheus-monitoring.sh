#!/usr/bin/env bash
set -Eeuo pipefail

PROMETHEUS_URL="${PROMETHEUS_URL:-http://127.0.0.1:30900}"

REPORT_DIR="${REPORT_DIR:-reports/phase-27-prometheus}"

EXPECTED_SERVICES=(
  account-service
  auth-service
  notification-service
  payment-service
  transaction-service
)

mkdir -p "${REPORT_DIR}"


fail()
{
    echo "FAIL: $*" >&2
    exit 1
}


echo '=================================================='
echo 'PROMETHEUS MONITORING VERIFICATION'
echo '=================================================='


command -v curl >/dev/null
command -v jq >/dev/null


echo
echo '========== 1. PROMETHEUS READINESS =========='

READY_HTTP="$(
    curl \
      --silent \
      --show-error \
      --retry 5 \
      --retry-delay 2 \
      --retry-connrefused \
      --connect-timeout 5 \
      --max-time 30 \
      --output "${REPORT_DIR}/prometheus-ready.txt" \
      --write-out '%{http_code}' \
      "${PROMETHEUS_URL}/-/ready"
)"

echo "PrometheusReadyHTTP=${READY_HTTP}"

if [ "${READY_HTTP}" != '200' ]; then
    fail \
      "Prometheus readiness returned HTTP ${READY_HTTP}"
fi

cat "${REPORT_DIR}/prometheus-ready.txt"

echo 'PrometheusReady=true'


echo
echo '========== 2. PROMETHEUS TARGETS =========='

TARGET_HTTP="$(
    curl \
      --silent \
      --show-error \
      --retry 5 \
      --retry-delay 2 \
      --retry-connrefused \
      --connect-timeout 5 \
      --max-time 30 \
      --output "${REPORT_DIR}/prometheus-targets.json" \
      --write-out '%{http_code}' \
      "${PROMETHEUS_URL}/api/v1/targets"
)"

echo "PrometheusTargetsHTTP=${TARGET_HTTP}"

if [ "${TARGET_HTTP}" != '200' ]; then
    fail \
      "Prometheus targets returned HTTP ${TARGET_HTTP}"
fi

jq -e \
  '.status == "success"' \
  "${REPORT_DIR}/prometheus-targets.json" \
  >/dev/null


jq -r '
  .data.activeTargets[]
  |
  select(
    .labels.job == "vaultbank-services"
  )
  |
  [
    (.labels.namespace // "unknown"),
    (.labels.service // "unknown"),
    .health,
    (.lastError // "")
  ]
  |
  @tsv
' "${REPORT_DIR}/prometheus-targets.json" |
sort |
tee "${REPORT_DIR}/vaultbank-targets.txt"


echo
echo '========== 3. TARGET COUNTS =========='

TOTAL="$(
    jq '
      [
        .data.activeTargets[]
        |
        select(
          .labels.job == "vaultbank-services"
        )
      ]
      |
      length
    ' "${REPORT_DIR}/prometheus-targets.json"
)"

UP="$(
    jq '
      [
        .data.activeTargets[]
        |
        select(
          .labels.job == "vaultbank-services"
          and
          .health == "up"
        )
      ]
      |
      length
    ' "${REPORT_DIR}/prometheus-targets.json"
)"

STAGING_TOTAL="$(
    jq '
      [
        .data.activeTargets[]
        |
        select(
          .labels.job == "vaultbank-services"
          and
          .labels.namespace == "vault-bank-staging"
        )
      ]
      |
      length
    ' "${REPORT_DIR}/prometheus-targets.json"
)"

STAGING_UP="$(
    jq '
      [
        .data.activeTargets[]
        |
        select(
          .labels.job == "vaultbank-services"
          and
          .labels.namespace == "vault-bank-staging"
          and
          .health == "up"
        )
      ]
      |
      length
    ' "${REPORT_DIR}/prometheus-targets.json"
)"

PRODUCTION_TOTAL="$(
    jq '
      [
        .data.activeTargets[]
        |
        select(
          .labels.job == "vaultbank-services"
          and
          .labels.namespace == "vault-bank-prod"
        )
      ]
      |
      length
    ' "${REPORT_DIR}/prometheus-targets.json"
)"

PRODUCTION_UP="$(
    jq '
      [
        .data.activeTargets[]
        |
        select(
          .labels.job == "vaultbank-services"
          and
          .labels.namespace == "vault-bank-prod"
          and
          .health == "up"
        )
      ]
      |
      length
    ' "${REPORT_DIR}/prometheus-targets.json"
)"


echo "StagingTargets=${STAGING_TOTAL}"
echo "StagingTargetsUp=${STAGING_UP}"
echo "ProductionTargets=${PRODUCTION_TOTAL}"
echo "ProductionTargetsUp=${PRODUCTION_UP}"
echo "VaultBankTargets=${TOTAL}"
echo "VaultBankTargetsUp=${UP}"


[ "${STAGING_TOTAL}" -eq 5 ] ||
    fail \
      "expected 5 staging targets, found ${STAGING_TOTAL}"

[ "${STAGING_UP}" -eq 5 ] ||
    fail \
      "expected 5 healthy staging targets, found ${STAGING_UP}"

[ "${PRODUCTION_TOTAL}" -eq 5 ] ||
    fail \
      "expected 5 production targets, found ${PRODUCTION_TOTAL}"

[ "${PRODUCTION_UP}" -eq 5 ] ||
    fail \
      "expected 5 healthy production targets, found ${PRODUCTION_UP}"

[ "${TOTAL}" -eq 10 ] ||
    fail \
      "expected 10 Vault Bank targets, found ${TOTAL}"

[ "${UP}" -eq 10 ] ||
    fail \
      "expected 10 healthy Vault Bank targets, found ${UP}"


echo
echo '========== 4. EXACT SERVICE MATRIX =========='

EXPECTED="$(
    printf '%s\n' \
      "${EXPECTED_SERVICES[@]}" |
    sort
)"

for NAMESPACE in \
  vault-bank-staging \
  vault-bank-prod
do

    ACTUAL="$(
        jq -r \
          --arg NS "${NAMESPACE}" '
          .data.activeTargets[]
          |
          select(
            .labels.job == "vaultbank-services"
            and
            .labels.namespace == $NS
            and
            .health == "up"
          )
          |
          .labels.service
        ' "${REPORT_DIR}/prometheus-targets.json" |
        sort -u
    )"

    echo
    echo "Namespace=${NAMESPACE}"

    printf '%s\n' "${ACTUAL}"

    if [ "${ACTUAL}" != "${EXPECTED}" ]; then
        fail \
          "service matrix mismatch for ${NAMESPACE}"
    fi
done

echo 'StagingServiceSet=5/5'
echo 'ProductionServiceSet=5/5'


echo
echo '========== 5. PROMETHEUS UP QUERY =========='

curl \
  --silent \
  --show-error \
  --fail \
  --retry 5 \
  --retry-delay 2 \
  --get \
  --data-urlencode \
  'query=up{job="vaultbank-services"}' \
  "${PROMETHEUS_URL}/api/v1/query" \
  >"${REPORT_DIR}/prometheus-up-query.json"


jq -e \
  '.status == "success"' \
  "${REPORT_DIR}/prometheus-up-query.json" \
  >/dev/null


jq -r '
  .data.result[]
  |
  [
    (.metric.service // "unknown"),
    (.metric.namespace // "unknown"),
    .value[1]
  ]
  |
  @tsv
' "${REPORT_DIR}/prometheus-up-query.json" |
sort |
tee "${REPORT_DIR}/prometheus-up.txt"


METRIC_SERIES="$(
    jq '
      .data.result
      |
      length
    ' "${REPORT_DIR}/prometheus-up-query.json"
)"

HEALTHY_SERIES="$(
    jq '
      [
        .data.result[]
        |
        select(
          .value[1] == "1"
        )
      ]
      |
      length
    ' "${REPORT_DIR}/prometheus-up-query.json"
)"


echo "MetricSeries=${METRIC_SERIES}"
echo "HealthyMetricSeries=${HEALTHY_SERIES}"


[ "${METRIC_SERIES}" -eq 10 ] ||
    fail \
      "expected 10 up metric series, found ${METRIC_SERIES}"

[ "${HEALTHY_SERIES}" -eq 10 ] ||
    fail \
      "expected 10 healthy metric series, found ${HEALTHY_SERIES}"


echo
echo '========== 6. SERVICE INFO METRIC =========='

curl \
  --silent \
  --show-error \
  --fail \
  --retry 5 \
  --retry-delay 2 \
  --get \
  --data-urlencode \
  'query=vaultbank_service_info{job="vaultbank-services"}' \
  "${PROMETHEUS_URL}/api/v1/query" \
  >"${REPORT_DIR}/service-info-query.json"


jq -e \
  '.status == "success"' \
  "${REPORT_DIR}/service-info-query.json" \
  >/dev/null


jq -r '
  .data.result[]
  |
  [
    (.metric.namespace // "unknown"),
    (.metric.service // "unknown"),
    .value[1]
  ]
  |
  @tsv
' "${REPORT_DIR}/service-info-query.json" |
sort |
tee "${REPORT_DIR}/service-info.txt"


SERVICE_INFO_TOTAL="$(
    jq '
      .data.result
      |
      length
    ' "${REPORT_DIR}/service-info-query.json"
)"

SERVICE_INFO_HEALTHY="$(
    jq '
      [
        .data.result[]
        |
        select(
          .value[1] == "1"
        )
      ]
      |
      length
    ' "${REPORT_DIR}/service-info-query.json"
)"


echo "ServiceInfoSeries=${SERVICE_INFO_TOTAL}"
echo "ServiceInfoHealthy=${SERVICE_INFO_HEALTHY}"


[ "${SERVICE_INFO_TOTAL}" -eq 10 ] ||
    fail \
      "expected 10 service-info series, found ${SERVICE_INFO_TOTAL}"

[ "${SERVICE_INFO_HEALTHY}" -eq 10 ] ||
    fail \
      "expected 10 healthy service-info series, found ${SERVICE_INFO_HEALTHY}"


echo
echo '========== 7. NAMESPACE METRIC MATRIX =========='

for NAMESPACE in \
  vault-bank-staging \
  vault-bank-prod
do

    COUNT="$(
        jq \
          --arg NS "${NAMESPACE}" '
          [
            .data.result[]
            |
            select(
              .metric.namespace == $NS
              and
              .value[1] == "1"
            )
          ]
          |
          length
        ' "${REPORT_DIR}/service-info-query.json"
    )"

    echo "${NAMESPACE}ServiceInfo=${COUNT}"

    [ "${COUNT}" -eq 5 ] ||
        fail \
          "expected 5 service-info series for ${NAMESPACE}, found ${COUNT}"
done


echo
echo '========== 8. WRITE EVIDENCE SUMMARY =========='

cat >"${REPORT_DIR}/summary.txt" <<EOF
PrometheusReady=true
StagingTargets=5
StagingTargetsUp=5
ProductionTargets=5
ProductionTargetsUp=5
VaultBankTargets=10
VaultBankTargetsUp=10
MetricSeries=10
HealthyMetricSeries=10
ServiceInfoSeries=10
ServiceInfoHealthy=10
StagingServiceSet=5/5
ProductionServiceSet=5/5
Phase27Passed=true
EOF

cat "${REPORT_DIR}/summary.txt"


echo
echo '=================================================='
echo 'PHASE 27 COMPLETE'
echo '=================================================='
echo 'PrometheusReady=true'
echo 'StagingTargets=5'
echo 'StagingTargetsUp=5'
echo 'ProductionTargets=5'
echo 'ProductionTargetsUp=5'
echo 'VaultBankTargets=10'
echo 'VaultBankTargetsUp=10'
echo 'MetricSeries=10'
echo 'HealthyMetricSeries=10'
echo 'ServiceInfoSeries=10'
echo 'ServiceInfoHealthy=10'
echo 'StagingServiceSet=5/5'
echo 'ProductionServiceSet=5/5'
echo 'Phase27Passed=true'
