#!/usr/bin/env bash
set -Eeuo pipefail

PROMETHEUS_URL="${PROMETHEUS_URL:-http://127.0.0.1:30900}"
REPORT_DIR="${PROMETHEUS_REPORT_DIR:-reports/phase-27-prometheus}"

mkdir -p "${REPORT_DIR}"

echo '=================================================='
echo 'PROMETHEUS MONITORING VERIFICATION'
echo '=================================================='

echo "PrometheusURL=${PROMETHEUS_URL}"

echo
echo '========== READINESS =========='

READY_BODY="$(
  curl \
    --silent \
    --show-error \
    --fail \
    "${PROMETHEUS_URL}/-/ready"
)"

printf '%s\n' "${READY_BODY}" |
tee "${REPORT_DIR}/prometheus-ready.txt"

echo
echo '========== TARGET API =========='

curl \
  --silent \
  --show-error \
  --fail \
  "${PROMETHEUS_URL}/api/v1/targets" \
  > "${REPORT_DIR}/prometheus-targets.json"

jq -e \
  '.status == "success"' \
  "${REPORT_DIR}/prometheus-targets.json" \
  >/dev/null

jq -r '
  .data.activeTargets[]
  | select(.labels.job == "vaultbank-services")
  |
  [
    (.labels.service // "unknown"),
    (.labels.namespace // "unknown"),
    .health,
    (.lastError // "")
  ]
  | @tsv
' "${REPORT_DIR}/prometheus-targets.json" |
tee "${REPORT_DIR}/vaultbank-targets.txt"

TOTAL="$(
  jq '
    [
      .data.activeTargets[]
      | select(
          .labels.job == "vaultbank-services"
        )
    ]
    | length
  ' "${REPORT_DIR}/prometheus-targets.json"
)"

UP="$(
  jq '
    [
      .data.activeTargets[]
      | select(
          .labels.job == "vaultbank-services"
          and
          .health == "up"
        )
    ]
    | length
  ' "${REPORT_DIR}/prometheus-targets.json"
)"

echo
echo "VaultBankTargets=${TOTAL}"
echo "VaultBankTargetsUp=${UP}"

              # PROMETHEUS_NAMESPACE_ACCEPTANCE_V2
              STAGING_TOTAL="$(
                jq '
                  [
                    .data.activeTargets[]
                    | select(
                        .labels.job == "vaultbank-services"
                        and
                        .labels.namespace == "vault-bank-staging"
                      )
                  ]
                  | length
                ' reports/phase-27-prometheus/prometheus-targets.json
              )"

              STAGING_UP="$(
                jq '
                  [
                    .data.activeTargets[]
                    | select(
                        .labels.job == "vaultbank-services"
                        and
                        .labels.namespace == "vault-bank-staging"
                        and
                        .health == "up"
                      )
                  ]
                  | length
                ' reports/phase-27-prometheus/prometheus-targets.json
              )"

              PROD_TOTAL="$(
                jq '
                  [
                    .data.activeTargets[]
                    | select(
                        .labels.job == "vaultbank-services"
                        and
                        .labels.namespace == "vault-bank-prod"
                      )
                  ]
                  | length
                ' reports/phase-27-prometheus/prometheus-targets.json
              )"

              PROD_UP="$(
                jq '
                  [
                    .data.activeTargets[]
                    | select(
                        .labels.job == "vaultbank-services"
                        and
                        .labels.namespace == "vault-bank-prod"
                        and
                        .health == "up"
                      )
                  ]
                  | length
                ' reports/phase-27-prometheus/prometheus-targets.json
              )"

              echo "StagingTargets=${STAGING_TOTAL}"
              echo "StagingTargetsUp=${STAGING_UP}"
              echo "ProductionTargets=${PROD_TOTAL}"
              echo "ProductionTargetsUp=${PROD_UP}"

              if [ "${STAGING_TOTAL}" -ne 5 ]; then
                echo "FAIL: expected 5 staging targets, found ${STAGING_TOTAL}"
                exit 1
              fi

              if [ "${PROD_TOTAL}" -ne 5 ]; then
                echo "FAIL: expected 5 production targets, found ${PROD_TOTAL}"
                exit 1
              fi

              if [ "${STAGING_UP}" -ne 5 ]; then
                echo "FAIL: expected all 5 staging targets UP, found ${STAGING_UP}"
                exit 1
              fi

              if [ "${PROD_UP}" -ne 5 ]; then
                echo "FAIL: expected all 5 production targets UP, found ${PROD_UP}"
                exit 1
              fi


if [ "${TOTAL}" -ne 10 ]; then
  echo "FAIL: expected 10 Vault Bank targets, found ${TOTAL}"
  exit 1
fi

if [ "${UP}" -ne 10 ]; then
  echo "FAIL: expected 5 UP targets, found ${UP}"
  exit 1
fi

echo
echo '========== UP METRIC =========='

curl \
  --silent \
  --show-error \
  --fail \
  --get \
  --data-urlencode \
  'query=up{job="vaultbank-services"}' \
  "${PROMETHEUS_URL}/api/v1/query" \
  > "${REPORT_DIR}/prometheus-up-query.json"

RESULT_COUNT="$(
  jq '
    [
      .data.result[]
      | select(.value[1] == "1")
    ]
    | length
  ' "${REPORT_DIR}/prometheus-up-query.json"
)"

echo "HealthyMetricSeries=${RESULT_COUNT}"

if [ "${RESULT_COUNT}" -ne 5 ]; then
  echo 'FAIL: Prometheus up metric does not contain five healthy services'
  exit 1
fi

echo
echo '========== ALERT RULES =========='

curl \
  --silent \
  --show-error \
  --fail \
  "${PROMETHEUS_URL}/api/v1/rules" \
  > "${REPORT_DIR}/prometheus-rules.json"

RULE_COUNT="$(
  jq '
    [
      .data.groups[]?.rules[]?
    ]
    | length
  ' "${REPORT_DIR}/prometheus-rules.json"
)"

echo "PrometheusRuleCount=${RULE_COUNT}"

cat > "${REPORT_DIR}/summary.txt" <<SUMMARY
PrometheusReady=true
VaultBankTargets=${TOTAL}
VaultBankTargetsUp=${UP}
HealthyMetricSeries=${RESULT_COUNT}
PrometheusRuleCount=${RULE_COUNT}
PrometheusVerificationPassed=true
SUMMARY

cat "${REPORT_DIR}/summary.txt"

echo
echo 'PASS: Prometheus monitoring verification completed'
