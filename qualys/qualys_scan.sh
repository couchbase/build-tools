#!/bin/bash -ex

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# setup python virtual env
# $WORKSPACE is too long, place virtual env under /tmp
export LC_ALL=C
VIRTUALENV_NAME=${PRODUCT}-${SCAN_TYPE}
echo "VIRTUALENV_NAME: ${VIRTUALENV_NAME}"
python3 -m venv /tmp/${VIRTUALENV_NAME}
source /tmp/${VIRTUALENV_NAME}/bin/activate

# Install required pip modules
pip3 install --upgrade -r ${SCRIPT_DIR}/requirements.txt

echo $PATH

# run qualys scan
WEB_NAME=${PRODUCT}-${VERSION}-${BLD_NUM}
QUALYS_CONFIG='/tmp/config.txt'.${SCAN_TYPE}-${WEB_NAME}
cat > ${QUALYS_CONFIG} << 'EOF'
[info]
hostname = qualysapi.qg3.apps.qualys.com
username = cuchb3ws
EOF

echo -e "password = ${QUALYS_PASSWORD}" >> ${QUALYS_CONFIG}

PROFILE_ID="178884"
case $PRODUCT in
  sync_gateway)
    WEB_URL="http://${TEST_VM_IP}:4984"
    WEBAPP_ID=5943237
    ;;
  couchbase-edge-server)
    WEB_URL="http://${TEST_VM_IP}:59840"
    WEBAPP_ID=799474140
    ;;
  enterprise-analytics)
    WEB_URL="https://${TEST_VM_IP}:8091"
    WEBAPP_ID=894694750
    ;;
  operational-insights)
    WEB_URL="https://${TEST_VM_IP}:8091"
    WEBAPP_ID=894694750
    ;;
  couchbase-server)
    WEB_URL="https://${TEST_VM_IP}:18091"
    WEBAPP_ID=4900290
    ;;
  *)
    echo "${PRODUCT} is not supported"
    ;;
esac

python3 ${SCRIPT_DIR}/was_scan.py \
  --web-url ${WEB_URL} \
  --webapp-id ${WEBAPP_ID} \
  --profile-id ${PROFILE_ID} \
  --web-name ${WEB_NAME} \
  --scan-type-name ${SCAN_TYPE} \
  --bld-num ${BLD_NUM} \
  --qualys-config ${QUALYS_CONFIG} \
  --debug

# cleanup old scans
if [[ -z ${UTC_DATE_DELETE_FROM} ]]; then
  UTC_DATE_DELETE_FROM='2017-01-01T00:00:00Z'
fi
if [[ -z ${UTC_DATE_DELETE_TO} ]]; then
  UTC_DATE_DELETE_TO="$(date --date='14 day ago' +%Y-%m-%d)T00:00:00Z"
fi
echo "Remove older scans from ${UTC_DATE_DELETE_FROM} to ${UTC_DATE_DELETE_TO}"
sed -i.bak \
  "s/\(.*operator=\"LESSER\">\).*\(<\/Criteria>\)/\1${UTC_DATE_DELETE_TO}\2/" \
  ./qualys/file_delete_scan.xml
sed -i.bak \
  "s/\(.*operator=\"GREATER\">\).*\(<\/Criteria>\)/\1${UTC_DATE_DELETE_FROM}\2/" \
  ./qualys/file_delete_scan.xml
DELETE_OK=true
if ! DELETE_RESPONSE=$(curl -sS -u "cuchb3ws:${QUALYS_PASSWORD}" \
  -H "content-type: text/xml" \
  -X "POST" \
  --data-binary @- \
  "https://qualysapi.qg3.apps.qualys.com/qps/rest/3.0/delete/was/wasscan" \
  < ./qualys/file_delete_scan.xml); then
  DELETE_OK=false
fi
echo "${DELETE_RESPONSE}"
# Qualys returns errors in the response body, not via HTTP status
if ! grep -q '<responseCode>SUCCESS</responseCode>' <<< "${DELETE_RESPONSE}"; then
  DELETE_OK=false
fi

# deactivate virtualenv
echo "Deactivating virtualenv ..."
deactivate
rm -rf ${QUALYS_CONFIG}
rm -rf /tmp/${VIRTUALENV_NAME}

if [[ ${DELETE_OK} != true ]]; then
  echo "ERROR: failed to delete old scans"
  exit 1
fi
