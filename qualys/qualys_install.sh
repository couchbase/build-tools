#!/bin/bash -ex
LATEST_PKG_URL=http://latestbuilds.service.couchbase.com/builds/latestbuilds/${PRODUCT}/${RELEASE}/${BLD_NUM}
case ${PRODUCT} in
  sync_gateway)
    PKG_NAME=couchbase-sync-gateway
    PKG_FILE_NAME=${PKG_NAME}-enterprise_${VERSION}-${BLD_NUM}_x86_64.deb
    CLEAN_UP_CMD="dpkg --remove --force-all ${PKG_NAME}
rm -rf /home/${PRODUCT}/data
mkdir /home/${PRODUCT}/data"
    INSTALL_CMD="dpkg -i /tmp/${PKG_FILE_NAME}"
  ;;
  couchbase-edge-server)
    PKG_NAME=${PRODUCT}
    PKG_FILE_NAME=${PKG_NAME}_${VERSION}-${BLD_NUM}_amd64.deb
    CLEAN_UP_CMD="dpkg --remove --force-all ${PKG_NAME}"
    INSTALL_CMD="dpkg -i /tmp/${PKG_FILE_NAME}"
  ;;
  enterprise-analytics)
    PKG_NAME=${PRODUCT}
    PKG_FILE_NAME=${PKG_NAME}_${VERSION}-${BLD_NUM}-linux_amd64.deb
    # couchbase-server and enterprise-analytics step on each other sometimes
    # extra commands to ensure they are removed cleanly
    CLEAN_UP_CMD="dpkg --remove --force-all ${PKG_NAME}
dpkg --remove --force-all couchbase-server
dpkg --purge ${PKG_NAME}
dpkg --purge couchbase-server
rm -rf /opt/enterprise-analytics
rm -rf /opt/couchbase
rm -rf /opt/enterprise-analytics
rm -f /etc/couchbase.d/*"
    INSTALL_CMD="dpkg -i /tmp/${PKG_FILE_NAME}
systemctl restart enterprise-analytics"

    CONFIGURE_CMD="mkdir -p /etc/couchbase.d
echo 'analytics_provisioned' > /etc/couchbase.d/config_profile
curl --retry 30 --retry-delay 5 --retry-all-errors --fail \
http://${TEST_VM_IP}:8091
curl --fail http://${TEST_VM_IP}:8091/clusterInit \
-d username=${ADMIN_UID} \
-d password=${ADMIN_PW} \
-d cbasMemoryQuota=1024 \
-d port=SAME"
  ;;
  couchbase-server)
    PKG_NAME=${PRODUCT}
    PKG_FILE_NAME=${PKG_NAME}-enterprise_${VERSION}-${BLD_NUM}-linux_amd64.deb
    # couchbase-server and enterprise-analytics step on each other sometimes
    # extra commands to ensure they are removed cleanly
    CLEAN_UP_CMD="dpkg --remove --force-all ${PKG_NAME}
dpkg --remove --force-all enterprise-analytics
dpkg --purge ${PKG_NAME}
dpkg --purge enterprise-analytics
rm -rf /opt/couchbase
rm -rf /opt/enterprise-analytics
rm -rf /etc/couchbase.d/*"
    INSTALL_CMD="dpkg -i /tmp/${PKG_FILE_NAME}
systemctl restart couchbase-server"
    CONFIGURE_CMD="curl --retry 30 --retry-delay 5 --retry-all-errors --fail \
http://${TEST_VM_IP}:8091
curl --fail http://${TEST_VM_IP}:8091/clusterInit \
-d username=${ADMIN_UID} \
-d password=${ADMIN_PW} \
-d memoryQuota=1024 \
-d services=kv,index,n1ql,fts,backup \
-d port=SAME"
  ;;
  *)
    echo "${PRODUCT} is not supported."
    exit 1
esac

cat << EOF >> install.sh
#!/bin/bash
set -ex
${CLEAN_UP_CMD}

curl --fail ${LATEST_PKG_URL}/${PKG_FILE_NAME} -o /tmp/${PKG_FILE_NAME}
${INSTALL_CMD}
${CONFIGURE_CMD}
rm -f /tmp/${PKG_FILE_NAME}
EOF

chmod +x install.sh
/usr/bin/sshpass -p "${SSH_PW}" \
    ssh -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        couchbase@"${TEST_VM_IP}" \
        'sudo bash -s' < install.sh
