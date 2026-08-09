#!/usr/bin/env bash
set -Eeuo pipefail

ARGO_NS='argocd'
APP='vault-bank-prod'
NS='vault-bank-prod'

REPORT_DIR="${REPORT_DIR:-reports/phase-27-production}"

EXPECTED_REVISION="${GIT_COMMIT:-$(git rev-parse HEAD)}"

DEPLOYMENTS=(
  auth-service
  account-service
  transaction-service
  payment-service
  notification-service
  frontend
)

SERVICES=(
  auth-service
  account-service
  transaction-service
  payment-service
  notification-service
  frontend
)

mkdir -p "${REPORT_DIR}"


fail()
{
    echo "FAIL: $*" >&2
    exit 1
}


echo '=================================================='
echo 'PRODUCTION DEPLOYMENT VERIFICATION'
echo '=================================================='


echo
echo '========== 1. APPLICATION EXISTS =========='

sudo k3s kubectl \
  -n "${ARGO_NS}" \
  get application "${APP}" \
  >/dev/null

echo 'ProductionArgoApplicationExists=true'


echo
echo '========== 2. VERIFY APPLICATION PROJECT =========='

PROJECT="$(
  sudo k3s kubectl \
    -n "${ARGO_NS}" \
    get application "${APP}" \
    -o jsonpath='{.spec.project}'
)"

echo "ProductionArgoProject=${PROJECT}"

if [ "${PROJECT}" != 'vault-bank-prod' ]; then
    fail \
      "production application uses project ${PROJECT}"
fi

echo 'ProductionArgoProjectValid=true'


echo
echo '========== 3. HARD REFRESH ARGO =========='

sudo k3s kubectl \
  -n "${ARGO_NS}" \
  annotate application "${APP}" \
  argocd.argoproj.io/refresh=hard \
  --overwrite \
  >/dev/null

echo 'ProductionArgoHardRefresh=true'


echo
echo '========== 4. CURRENT ARGO STATUS =========='

read_status()
{
    sudo k3s kubectl \
      -n "${ARGO_NS}" \
      get application "${APP}" \
      -o json |
    jq -r '
      [
        (.status.sync.status // "Unknown"),
        (.status.health.status // "Unknown"),
        (.status.sync.revision // "Unknown"),
        (.status.operationState.phase // "None")
      ]
      | @tsv
    '
}

read_status


echo
echo '========== 5. TRIGGER SYNC WHEN REQUIRED =========='

SYNC="$(
  sudo k3s kubectl \
    -n "${ARGO_NS}" \
    get application "${APP}" \
    -o jsonpath='{.status.sync.status}'
)"

HEALTH="$(
  sudo k3s kubectl \
    -n "${ARGO_NS}" \
    get application "${APP}" \
    -o jsonpath='{.status.health.status}'
)"

REVISION="$(
  sudo k3s kubectl \
    -n "${ARGO_NS}" \
    get application "${APP}" \
    -o jsonpath='{.status.sync.revision}'
)"

echo "ExpectedRevision=${EXPECTED_REVISION}"
echo "CurrentRevision=${REVISION}"
echo "CurrentSync=${SYNC}"
echo "CurrentHealth=${HEALTH}"


if [ "${SYNC}" != 'Synced' ] ||
   [ "${HEALTH}" != 'Healthy' ] ||
   [ "${REVISION}" != "${EXPECTED_REVISION}" ]
then

    echo 'ProductionSyncRequired=true'

    sudo k3s kubectl \
      -n "${ARGO_NS}" \
      patch application "${APP}" \
      --type=merge \
      -p '{
        "operation": {
          "sync": {
            "prune": false,
            "syncOptions": [
              "CreateNamespace=true"
            ]
          }
        }
      }' \
      >/dev/null

else

    echo 'ProductionAlreadySynced=true'

fi


echo
echo '========== 6. WAIT FOR SYNCED + HEALTHY =========='

ARGO_READY=false

for ATTEMPT in $(seq 1 120)
do

    JSON="$(
      sudo k3s kubectl \
        -n "${ARGO_NS}" \
        get application "${APP}" \
        -o json
    )"

    SYNC="$(
      jq -r \
        '.status.sync.status // "Unknown"' \
        <<<"${JSON}"
    )"

    HEALTH="$(
      jq -r \
        '.status.health.status // "Unknown"' \
        <<<"${JSON}"
    )"

    REVISION="$(
      jq -r \
        '.status.sync.revision // "Unknown"' \
        <<<"${JSON}"
    )"

    PHASE="$(
      jq -r \
        '.status.operationState.phase // "None"' \
        <<<"${JSON}"
    )"

    printf \
      'Attempt=%03d Sync=%s Health=%s Revision=%s Operation=%s\n' \
      "${ATTEMPT}" \
      "${SYNC}" \
      "${HEALTH}" \
      "${REVISION}" \
      "${PHASE}"


    if [ "${PHASE}" = 'Failed' ] ||
       [ "${PHASE}" = 'Error' ]
    then

        echo
        echo 'Argo operation details:'

        jq '{
          phase: .status.operationState.phase,
          message: .status.operationState.message,
          resources: .status.operationState.syncResult.resources
        }' <<<"${JSON}"

        fail \
          "production Argo synchronization failed"
    fi


    if [ "${SYNC}" = 'Synced' ] &&
       [ "${HEALTH}" = 'Healthy' ] &&
       [ "${REVISION}" = "${EXPECTED_REVISION}" ]
    then

        ARGO_READY=true
        break
    fi

    sleep 5

done


if [ "${ARGO_READY}" != 'true' ]; then

    sudo k3s kubectl \
      -n "${ARGO_NS}" \
      get application "${APP}" \
      -o yaml \
      >"${REPORT_DIR}/argocd-timeout.yaml"

    fail \
      "production application did not reach expected revision/Synced/Healthy"
fi


echo "ProductionRevision=${REVISION}"
echo 'ProductionArgoSynced=true'
echo 'ProductionArgoHealthy=true'


echo
echo '========== 7. VERIFY PRODUCTION DEPLOYMENTS =========='

for DEPLOYMENT in "${DEPLOYMENTS[@]}"
do

    echo
    echo "Deployment=${DEPLOYMENT}"

    sudo k3s kubectl \
      -n "${NS}" \
      rollout status \
      deployment/"${DEPLOYMENT}" \
      --timeout=420s

done

echo 'ProductionRollouts=6/6'


echo
echo '========== 8. VERIFY READY REPLICAS =========='

READY_DEPLOYMENTS=0

for DEPLOYMENT in "${DEPLOYMENTS[@]}"
do

    DESIRED="$(
      sudo k3s kubectl \
        -n "${NS}" \
        get deployment "${DEPLOYMENT}" \
        -o json |
      jq -r \
        '.spec.replicas // 1'
    )"

    READY="$(
      sudo k3s kubectl \
        -n "${NS}" \
        get deployment "${DEPLOYMENT}" \
        -o json |
      jq -r \
        '.status.readyReplicas // 0'
    )"

    echo \
      "${DEPLOYMENT} Desired=${DESIRED} Ready=${READY}"

    if [ "${READY}" -lt "${DESIRED}" ]; then
        fail \
          "${DEPLOYMENT} is not fully Ready"
    fi

    READY_DEPLOYMENTS=$((READY_DEPLOYMENTS + 1))

done

echo "ProductionReadyDeployments=${READY_DEPLOYMENTS}/6"


echo
echo '========== 9. VERIFY IMMUTABLE IMAGES =========='

IMMUTABLE=0

for DEPLOYMENT in "${DEPLOYMENTS[@]}"
do

    IMAGE="$(
      sudo k3s kubectl \
        -n "${NS}" \
        get deployment "${DEPLOYMENT}" \
        -o jsonpath='{.spec.template.spec.containers[0].image}'
    )"

    echo \
      "${DEPLOYMENT} ${IMAGE}"

    if ! printf '%s\n' "${IMAGE}" |
         grep -Eq \
         '@sha256:[0-9a-f]{64}$'
    then

        fail \
          "${DEPLOYMENT} is not using an immutable image digest"
    fi

    IMMUTABLE=$((IMMUTABLE + 1))

done

echo "ProductionImmutableImages=${IMMUTABLE}/6"


echo
echo '========== 10. VERIFY SERVICE ENDPOINTS =========='

READY_SERVICES=0

for SERVICE in "${SERVICES[@]}"
do

    COUNT="$(
      sudo k3s kubectl \
        -n "${NS}" \
        get endpoints "${SERVICE}" \
        -o json |
      jq '
        [
          .subsets[]?.addresses[]?
        ]
        | length
      '
    )"

    echo \
      "${SERVICE} ReadyEndpoints=${COUNT}"

    if [ "${COUNT}" -lt 1 ]; then
        fail \
          "${SERVICE} has no Ready endpoint"
    fi

    READY_SERVICES=$((READY_SERVICES + 1))

done

echo "ProductionServiceEndpoints=${READY_SERVICES}/6"


echo
echo '========== 11. FINAL ARGO STATUS =========='

sudo k3s kubectl \
  -n "${ARGO_NS}" \
  get application "${APP}" \
  -o json |
jq '{
  sync: .status.sync.status,
  health: .status.health.status,
  revision: .status.sync.revision,
  operation: .status.operationState.phase
}' |
tee "${REPORT_DIR}/argocd-final.json"


echo
echo '========== 12. WRITE SUMMARY =========='

cat >"${REPORT_DIR}/summary.txt" <<EOF
ProductionArgoApplicationExists=true
ProductionArgoProjectValid=true
ProductionArgoSynced=true
ProductionArgoHealthy=true
ProductionRevision=${REVISION}
ProductionRollouts=6/6
ProductionReadyDeployments=6/6
ProductionImmutableImages=6/6
ProductionServiceEndpoints=6/6
Phase27ProductionPassed=true
EOF

cat "${REPORT_DIR}/summary.txt"


echo
echo '=================================================='
echo 'PHASE 27 PRODUCTION COMPLETE'
echo '=================================================='
echo 'ProductionArgoSynced=true'
echo 'ProductionArgoHealthy=true'
echo 'ProductionRollouts=6/6'
echo 'ProductionReadyDeployments=6/6'
echo 'ProductionImmutableImages=6/6'
echo 'ProductionServiceEndpoints=6/6'
echo 'Phase27ProductionPassed=true'
