#!/bin/bash -ex
# Copyright 2015 Red Hat, Inc.
#
# Licensed under the Apache License, Version 2.0 (the "License"); you may
# not use this file except in compliance with the License. You may obtain
# a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
# WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
# License for the specific language governing permissions and limitations
# under the License.

export SCRIPT_DIR=$(cd `dirname $0` && pwd -P)
source ${SCRIPT_DIR}/functions

export WORKSPACE=${WORKSPACE:-/tmp}
export PUPPET_MAJ_VERSION=${PUPPET_MAJ_VERSION:-3}
export SCENARIO=${SCENARIO:-scenario001}
export MANAGE_PUPPET_MODULES=${MANAGE_PUPPET_MODULES:-true}
export MANAGE_REPOS=${MANAGE_REPOS:-true}
export ADD_SWAP=${ADD_SWAP:-true}
export SWAP_SIZE_GB=${SWAP_SIZE_GB:-2}
export HIERA_CONFIG=${HIERA_CONFIG:-${SCRIPT_DIR}/hiera/hiera.yaml}
export MANAGE_HIERA=${MANAGE_HIERA:-true}
export PUPPET_ARGS="${PUPPET_ARGS} --detailed-exitcodes --color=false --test --trace --hiera_config ${HIERA_CONFIG} --logdest ${WORKSPACE}/puppet.log"
export DISTRO=$(lsb_release -c -s)
# RDO requires tempest 14.0.0 after last stable update of ceilometer in stable/newton
# Ceilometer has not been updated in Ubuntu so it requires 13.0.0
# Tempest version for any distro can be overriden by seting common env variable TEMPEST_VERSION to
# keep compatibility with previous version.
export TEMPEST_VERSION_UCA=${TEMPEST_VERSION:-13.0.0}
export TEMPEST_VERSION_RDO=${TEMPEST_VERSION:-14.0.0}

# NOTE(pabelanger): Setup facter to know about AFS mirror.
if [ -f /etc/nodepool/provider ]; then
    source /etc/nodepool/provider
    NODEPOOL_MIRROR_HOST=${NODEPOOL_MIRROR_HOST:-mirror.$NODEPOOL_REGION.$NODEPOOL_CLOUD.openstack.org}
    # OpenStack Infra AFS mirrors don't support HTTPS yet.
    NODEPOOL_MIRROR_HOST="http://$(echo $NODEPOOL_MIRROR_HOST|tr '[:upper:]' '[:lower:]')"
    CENTOS_MIRROR_HOST=${NODEPOOL_MIRROR_HOST}
    UCA_MIRROR_HOST="${NODEPOOL_MIRROR_HOST}/ubuntu-cloud-archive"
    if uses_debs; then
        CEPH_MIRROR_HOST="${NODEPOOL_MIRROR_HOST}/ceph-deb-jewel"
    else
        CEPH_MIRROR_HOST="${NODEPOOL_MIRROR_HOST}/centos/7/storage/x86_64/ceph-jewel/"
    fi
else
    CENTOS_MIRROR_HOST='http://mirror.centos.org'
    UCA_MIRROR_HOST='http://ubuntu-cloud.archive.canonical.com/ubuntu'
    if uses_debs; then
        CEPH_MIRROR_HOST='https://download.ceph.com/debian-jewel'
    else
        CEPH_MIRROR_HOST='http://mirror.centos.org/centos/7/storage/x86_64/ceph-jewel/'
    fi
fi
export FACTER_centos_mirror_host=$CENTOS_MIRROR_HOST
export FACTER_uca_mirror_host=$UCA_MIRROR_HOST
export FACTER_ceph_mirror_host=$CEPH_MIRROR_HOST

if [ $PUPPET_MAJ_VERSION == 4 ]; then
  export PATH=${PATH}:/opt/puppetlabs/bin
  export PUPPET_RELEASE_FILE=puppetlabs-release-pc1
  export PUPPET_BASE_PATH=/etc/puppetlabs/code
  export PUPPET_PKG=puppet-agent
else
  export PUPPET_RELEASE_FILE=puppetlabs-release
  export PUPPET_BASE_PATH=/etc/puppet
  export PUPPET_PKG=puppet
fi

print_header 'Start (run_tests.sh)'

if [ ! -f fixtures/${SCENARIO}.pp ]; then
    echo "fixtures/${SCENARIO}.pp file does not exist. Please define a valid scenario."
    exit 1
fi

if [ $(id -u) != 0 ]; then
  # preserve environment so we can have ZUUL_* params
  export SUDO='sudo -E'
fi

if [ "${ADD_SWAP}" = true ]; then
    print_header "Create $SWAP_SIZE_GB GB swapfile"
    $SUDO dd if=/dev/zero of=/swapfile count=${SWAP_SIZE_GB}k bs=1M
    $SUDO chmod 0600 /swapfile
    $SUDO mkswap /swapfile
    $SUDO swapon /swapfile
fi

# We install some gems as root so to take benefit of
# OpenStack Infra mirrors.
if [ -f ~/.gemrc ]; then
    cat ~/.gemrc | $SUDO tee /root/.gemrc
fi

print_header 'Clone Tempest, plugins & pre-cache CirrOS'
git clone git://git.openstack.org/openstack/tempest /tmp/openstack/tempest
git clone git://git.openstack.org/openstack/tempest-horizon /tmp/openstack/tempest-horizon

pushd /tmp/openstack/tempest
if is_fedora;then
    git reset --hard $TEMPEST_VERSION_RDO
elif uses_debs; then
    git reset --hard $TEMPEST_VERSION_UCA
fi
popd

# NOTE(pabelanger): We cache cirros images on our jenkins slaves, check if it
# exists.
if [ -f ~/cache/files/cirros-0.3.4-x86_64-disk.img ]; then
    # Create a symlink for tempest.
    ln -s ~/cache/files/cirros-0.3.4-x86_64-disk.img /tmp/openstack/tempest
else
    wget http://download.cirros-cloud.net/0.3.4/cirros-0.3.4-x86_64-disk.img -P /tmp/openstack/tempest
fi

install_puppet
PUPPET_FULL_PATH=$(which puppet)
if [ "${MANAGE_HIERA}" = true ]; then
  configure_hiera
fi

if uses_debs; then
    $SUDO apt-get install -y dstat
    # https://bugs.launchpad.net/cloud-archive/+bug/1621651
    $SUDO modprobe br_netfilter
elif is_fedora; then
    $SUDO yum install -y dstat setools setroubleshoot audit
    $SUDO service auditd start
    # SElinux in permissive mode so later we can catch alerts
    $SUDO selinuxenabled && $SUDO setenforce 0
fi

# use dstat to monitor system activity during integration testing
if type "dstat" 2>/dev/null; then
    print_header 'Start dstat'
    $SUDO dstat -tcmndrylpg --top-cpu-adv --top-io-adv --nocolor | $SUDO tee --append /var/log/dstat.log > /dev/null &
fi

if [ "${MANAGE_PUPPET_MODULES}" = true ]; then
    $SUDO ./install_modules.sh
fi

# Run puppet and assert something changes.
set +e
if [ "${MANAGE_REPOS}" = true ]; then
    print_header 'Install repos'
    $SUDO $PUPPET_FULL_PATH apply $PUPPET_ARGS -e "include ::openstack_integration::repos"
    RESULT=$?
    if [ $RESULT -ne 0 ] && [ $RESULT -ne 2 ]; then
        print_header 'Puppet failed to install repositories.'
        exit 1
    fi
    if is_fedora; then
        print_header 'Updating packages'
        $SUDO yum update -y
        if [ $? -ne 0 ]; then
            print_header 'Error updating packages'
            exit 1
        fi
    fi
fi

print_header "Running Puppet Scenario: ${SCENARIO} (1st time)"
run_puppet $SCENARIO
RESULT=$?
set -e
if [ $RESULT -ne 0 ] && [ $RESULT -ne 2 ]; then
    print_header 'First Puppet run contains errors in catalog.'
    catch_puppet_failures
    print_header 'SELinux Alerts (1st time)'
    catch_selinux_alerts
    exit 1
fi
timestamp_puppet_log

# Run puppet a second time and assert nothing changes.
set +e
print_header "Running Puppet Scenario: ${SCENARIO} (2nd time)"
run_puppet $SCENARIO
RESULT=$?
set -e
if [ $RESULT -ne 0 ]; then
    print_header 'Second Puppet run is not idempotent.'
    catch_puppet_failures
    print_header 'SELinux Alerts (2nd time)'
    catch_selinux_alerts
    exit 1
fi
timestamp_puppet_log

print_header 'Prepare Tempest'
# Tempest plugin tests require tempest-lib to be installed
$SUDO pip install tempest-lib

# We need latest testrepository to run stackviz correctly
$SUDO pip install -U testrepository

# install from source now on ubuntu until packaged
if uses_debs; then
    cd /tmp/openstack/tempest-horizon; $SUDO python setup.py install
fi

set +e
# Select what to test:
# Smoke suite
echo "smoke" > /tmp/openstack/tempest/test-whitelist.txt

# Horizon
echo "dashboard" >> /tmp/openstack/tempest/test-whitelist.txt

# Aodh
echo "TelemetryAlarming" >> /tmp/openstack/tempest/test-whitelist.txt

# Gnocchi
echo "gnocchi.tempest" >> /tmp/openstack/tempest/test-whitelist.txt

# Ironic
# Note: running all Ironic tests under SSL is not working
# https://bugs.launchpad.net/ironic/+bug/1554237
echo "api.baremetal.admin.test_drivers" >> /tmp/openstack/tempest/test-whitelist.txt

# Zaqar
echo "v2.test_queues.TestManageQueue" >> /tmp/openstack/tempest/test-whitelist.txt

# Cinder encrypted volumes
# TODO(emilien) re-enable it when those 2 patches are merged:
# - https://review.openstack.org/#/c/358670/
# - https://review.openstack.org/#/c/359391/
# TESTS="${TESTS} TestEncryptedCinderVolumes"

if uses_debs; then
    EXCLUDES="--regex=^(?!ceilometer.tests.tempest.api.test_telemetry_notification_api.TelemetryNotificationAPITest.test_check_glance_v1_notifications.*$).*"
else
    EXCLUDES=''
fi

print_header 'Running Tempest'
cd /tmp/openstack/tempest

virtualenv --system-site-packages run_tempest
run_tempest/bin/pip install -c https://git.openstack.org/cgit/openstack/requirements/plain/upper-constraints.txt?h=stable/newton -U -r requirements.txt
run_tempest/bin/python setup.py install
run_tempest/bin/tempest run --whitelist_file=/tmp/openstack/tempest/test-whitelist.txt --concurrency=2 $EXCLUDES
RESULT=$?
set -e
testr last --subunit > /tmp/openstack/tempest/testrepository.subunit
run_tempest/bin/tempest list-plugins

print_header 'SELinux Alerts (Tempest)'
catch_selinux_alerts

print_header 'Done (run_tests.sh)'
exit $RESULT
