#!/usr/bin/env bash
set -Eeuo pipefail
export TRIVY_SKIP_DIRS="${TRIVY_SKIP_DIRS:-**/node_modules}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=ci/scripts/devsecops-common.sh
source "${SCRIPT_DIR}/devsecops-common.sh"

use_phase_report_dir "phase-06-trivy-fs"

VERSIONS_FILE="${ROOT_DIR}/config/tool-versions.env"
POLICY_FILE="${ROOT_DIR}/config/pipeline-policy.yml"
TRIVY_IGNORE_FILE="${ROOT_DIR}/.trivyignore.yaml"

TRIVY_CACHE_DIR="${TRIVY_CACHE_DIR:-/var/lib/jenkins/trivy-cache}"

COMBINED_REPORT="${REPORT_DIR}/trivy-fs-combined.json"
TABLE_REPORT="${REPORT_DIR}/trivy-fs-table.txt"
SARIF_REPORT="${REPORT_DIR}/secret-misconfig.sarif"
CRITICAL_REPORT="${REPORT_DIR}/critical-vulnerabilities.json"
FIXABLE_HIGH_REPORT="${REPORT_DIR}/fixable-high-vulnerabilities.json"
SUMMARY_REPORT="${REPORT_DIR}/trivy-fs-summary.json"
METADATA_REPORT="${REPORT_DIR}/trivy-fs-metadata.txt"

require_command trivy
require_command git
require_command awk
require_command python3

[ -f "${VERSIONS_FILE}" ] ||
  die "Missing tool-version policy: ${VERSIONS_FILE}"

[ -f "${POLICY_FILE}" ] ||
  die "Missing pipeline policy: ${POLICY_FILE}"

[ -f "${TRIVY_IGNORE_FILE}" ] ||
  die "Missing Trivy exception policy: ${TRIVY_IGNORE_FILE}"

# shellcheck disable=SC1090
source "${VERSIONS_FILE}"

TRIVY_VERSION="${TRIVY_VERSION:-}"

[ -n "${TRIVY_VERSION}" ] ||
  die "TRIVY_VERSION is missing from ${VERSIONS_FILE}"

INSTALLED_TRIVY_VERSION="$(
  trivy --version |
    awk '
      $1 == "Version:" {
        print $2
        exit
      }
    '
)"

[ -n "${INSTALLED_TRIVY_VERSION}" ] ||
  die "Unable to determine installed Trivy version"

if [ "${INSTALLED_TRIVY_VERSION}" != "${TRIVY_VERSION}" ]; then
  die \
    "Installed Trivy ${INSTALLED_TRIVY_VERSION} does not match policy ${TRIVY_VERSION}"
fi

[ -d "${TRIVY_CACHE_DIR}" ] ||
  die "Trivy cache directory does not exist: ${TRIVY_CACHE_DIR}"

[ -w "${TRIVY_CACHE_DIR}" ] ||
  die "Trivy cache directory is not writable: ${TRIVY_CACHE_DIR}"

declare -a REQUIRED_ZERO_POLICIES=(
  "trivy_critical_vulnerabilities"
  "trivy_fixable_high_vulnerabilities"
  "trivy_high_or_critical_secrets"
  "trivy_high_or_critical_misconfigurations"
)

for policy_name in "${REQUIRED_ZERO_POLICIES[@]}"; do
  policy_value="$(
    awk \
      -v policy_name="${policy_name}" \
      '
        $1 == policy_name ":" {
          print $2
          exit
        }
      ' \
      "${POLICY_FILE}"
  )"

  [ -n "${policy_value}" ] ||
    die "Missing pipeline policy: ${policy_name}"

  if [ "${policy_value}" != "0" ]; then
    die \
      "Phase 3D policy ${policy_name} must remain 0, found ${policy_value}"
  fi
done

mkdir -p "${REPORT_DIR}"

python3 \
  "${SCRIPT_DIR}/validate-security-exceptions.py"

declare -a TRIVY_COMMON_ARGS=(
  --cache-dir "${TRIVY_CACHE_DIR}"
  --ignorefile "${TRIVY_IGNORE_FILE}"
  --no-progress
  --timeout 15m
  --skip-version-check
  --skip-dirs "${ROOT_DIR}/.git"
  --skip-dirs "${ROOT_DIR}/reports"
  --skip-dirs "${ROOT_DIR}/backend-service/node_modules"
  --skip-dirs "${ROOT_DIR}/frontend/node_modules"
  --skip-dirs "${ROOT_DIR}/backend-service/coverage"
  --skip-dirs "${ROOT_DIR}/backend-service/nginx/certs"
  --skip-dirs "${ROOT_DIR}/frontend/dist"
)

export \
  COMBINED_REPORT \
  CRITICAL_REPORT \
  FIXABLE_HIGH_REPORT \
  SUMMARY_REPORT

run_trivy_reports() {
  rm -f \
    "${COMBINED_REPORT}" \
    "${TABLE_REPORT}" \
    "${SARIF_REPORT}" \
    "${CRITICAL_REPORT}" \
    "${FIXABLE_HIGH_REPORT}" \
    "${SUMMARY_REPORT}" \
    "${METADATA_REPORT}"

  log \
    "Running Trivy filesystem vulnerability, secret and IaC scan"

  run_logged \
    "trivy-fs-combined-json" \
    trivy fs \
    "${TRIVY_COMMON_ARGS[@]}" \
    --scanners vuln,misconfig,secret \
    --include-dev-deps \
    --exit-code 0 \
    --format json \
    --output "${COMBINED_REPORT}" \
    "${ROOT_DIR}"

  [ -s "${COMBINED_REPORT}" ] ||
    die "Trivy combined JSON report was not generated"

  log \
    "Generating Trivy High/Critical table evidence"

  run_logged \
    "trivy-fs-table" \
    trivy fs \
    "${TRIVY_COMMON_ARGS[@]}" \
    --scanners vuln,misconfig,secret \
    --include-dev-deps \
    --severity HIGH,CRITICAL \
    --exit-code 0 \
    --format table \
    --output "${TABLE_REPORT}" \
    "${ROOT_DIR}"

  [ -s "${TABLE_REPORT}" ] ||
    die "Trivy table report was not generated"

  log \
    "Generating Trivy secret and IaC SARIF evidence"

  run_logged \
    "trivy-fs-secret-misconfig-sarif" \
    trivy fs \
    "${TRIVY_COMMON_ARGS[@]}" \
    --scanners misconfig,secret \
    --severity HIGH,CRITICAL \
    --exit-code 0 \
    --format sarif \
    --output "${SARIF_REPORT}" \
    "${ROOT_DIR}"

  [ -s "${SARIF_REPORT}" ] ||
    die "Trivy SARIF report was not generated"
}

evaluate_trivy_gate() {

python3 - <<'PY'
import copy
import json
import os
from pathlib import Path

combined_path = Path(os.environ["COMBINED_REPORT"])
critical_path = Path(os.environ["CRITICAL_REPORT"])
fixable_high_path = Path(os.environ["FIXABLE_HIGH_REPORT"])
summary_path = Path(os.environ["SUMMARY_REPORT"])

with combined_path.open(encoding="utf-8") as stream:
    report = json.load(stream)

critical_vulnerabilities = []
fixable_high_vulnerabilities = []
high_critical_secrets = []
high_critical_misconfigurations = []

critical_results = []
fixable_high_results = []

for result in report.get("Results", []):
    vulnerabilities = result.get("Vulnerabilities") or []
    secrets = result.get("Secrets") or []
    misconfigurations = result.get("Misconfigurations") or []

    result_critical = [
        finding
        for finding in vulnerabilities
        if finding.get("Severity") == "CRITICAL"
    ]

    result_fixable_high = [
        finding
        for finding in vulnerabilities
        if (
            finding.get("Severity") == "HIGH"
            and str(finding.get("FixedVersion") or "").strip()
        )
    ]

    critical_vulnerabilities.extend(result_critical)
    fixable_high_vulnerabilities.extend(result_fixable_high)

    high_critical_secrets.extend(
        finding
        for finding in secrets
        if finding.get("Severity") in {"HIGH", "CRITICAL"}
    )

    high_critical_misconfigurations.extend(
        finding
        for finding in misconfigurations
        if finding.get("Severity") in {"HIGH", "CRITICAL"}
    )

    base_result = {
        key: copy.deepcopy(value)
        for key, value in result.items()
        if key not in {
            "Vulnerabilities",
            "Secrets",
            "Misconfigurations",
        }
    }

    if result_critical:
        selected = copy.deepcopy(base_result)
        selected["Vulnerabilities"] = result_critical
        critical_results.append(selected)

    if result_fixable_high:
        selected = copy.deepcopy(base_result)
        selected["Vulnerabilities"] = result_fixable_high
        fixable_high_results.append(selected)


def write_filtered_report(path: Path, results: list[dict]) -> None:
    filtered = {
        key: copy.deepcopy(value)
        for key, value in report.items()
        if key != "Results"
    }

    filtered["Results"] = results

    path.write_text(
        json.dumps(filtered, indent=2) + "\n",
        encoding="utf-8",
    )


write_filtered_report(
    critical_path,
    critical_results,
)

write_filtered_report(
    fixable_high_path,
    fixable_high_results,
)

summary = {
    "critical_vulnerabilities": len(
        critical_vulnerabilities
    ),
    "fixable_high_vulnerabilities": len(
        fixable_high_vulnerabilities
    ),
    "high_or_critical_secrets": len(
        high_critical_secrets
    ),
    "high_or_critical_misconfigurations": len(
        high_critical_misconfigurations
    ),
}

summary["gate_passed"] = all(
    count == 0
    for count in summary.values()
)

summary_path.write_text(
    json.dumps(summary, indent=2) + "\n",
    encoding="utf-8",
)

print(
    "Critical vulnerabilities:",
    summary["critical_vulnerabilities"],
)

print(
    "Fixable High vulnerabilities:",
    summary["fixable_high_vulnerabilities"],
)

print(
    "High/Critical secrets:",
    summary["high_or_critical_secrets"],
)

print(
    "High/Critical misconfigurations:",
    summary[
        "high_or_critical_misconfigurations"
    ],
)

if not summary["gate_passed"]:
    for finding in fixable_high_vulnerabilities:
        print(
            "Fixable HIGH vulnerability:",
            finding.get("PkgName"),
            finding.get("InstalledVersion"),
            "->",
            finding.get("FixedVersion"),
            finding.get("VulnerabilityID"),
            finding.get("Title") or "",
        )

    for finding in critical_vulnerabilities:
        print(
            "CRITICAL vulnerability:",
            finding.get("PkgName"),
            finding.get("InstalledVersion"),
            "->",
            finding.get("FixedVersion") or "unfixed",
            finding.get("VulnerabilityID"),
            finding.get("Title") or "",
        )

    for finding in high_critical_secrets:
        print(
            "HIGH/CRITICAL secret:",
            finding.get("RuleID") or finding.get("ID") or "unknown-rule",
            finding.get("Severity") or "UNKNOWN",
            finding.get("Title") or finding.get("Category") or "",
        )

    for finding in high_critical_misconfigurations:
        print(
            "HIGH/CRITICAL misconfiguration:",
            finding.get("ID") or finding.get("AVDID") or "unknown-check",
            finding.get("Severity") or "UNKNOWN",
            finding.get("Title") or "",
            finding.get("Message") or "",
        )

    raise SystemExit(1)
PY
}

run_trivy_reports

set +e

evaluate_trivy_gate

GATE_EXIT=$?

set -e

if [ "${GATE_EXIT}" -ne 0 ] &&
  [ "${TRIVY_RETRY_WITH_FRESH_DB:-1}" = "1" ]; then
  log \
    "Trivy gate failed; refreshing vulnerability DB/check bundle and retrying once"

  if ! run_logged \
    "trivy-clean-vuln-db" \
    trivy clean \
    --cache-dir "${TRIVY_CACHE_DIR}" \
    --vuln-db; then
    log \
      "WARN: unable to clean Trivy vulnerability DB; retrying with existing cache"
  fi

  if ! run_logged \
    "trivy-clean-checks-bundle" \
    trivy clean \
    --cache-dir "${TRIVY_CACHE_DIR}" \
    --checks-bundle; then
    log \
      "WARN: unable to clean Trivy checks bundle; retrying with existing cache"
  fi

  run_trivy_reports

  set +e

  evaluate_trivy_gate

  GATE_EXIT=$?

  set -e
fi

printf '%s\n' \
  "trivy_version=${INSTALLED_TRIVY_VERSION}" \
  "git_commit=$(git -C "${ROOT_DIR}" rev-parse HEAD)" \
  "git_branch=$(git -C "${ROOT_DIR}" branch --show-current)" \
  "cache_directory=${TRIVY_CACHE_DIR}" \
  "ignore_file=.trivyignore.yaml" \
  "critical_vulnerabilities_allowed=0" \
  "fixable_high_vulnerabilities_allowed=0" \
  "high_or_critical_secrets_allowed=0" \
  "high_or_critical_misconfigurations_allowed=0" \
  > "${METADATA_REPORT}"

find "${REPORT_DIR}" \
  -maxdepth 1 \
  -type f \
  -exec chmod 640 {} +

if [ "${GATE_EXIT}" -ne 0 ]; then
  die \
    "Trivy security gate failed; inspect ${TABLE_REPORT} and ${SUMMARY_REPORT}"
fi

log \
  "PASS: Trivy filesystem, secret and IaC misconfiguration gate"
