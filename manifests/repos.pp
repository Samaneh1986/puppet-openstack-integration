class openstack_integration::repos {

  case $::osfamily {
    'Debian': {
      include ::apt
      class { '::openstack_extras::repo::debian::ubuntu':
        release         => 'pike',
        package_require => true,
        uca_location    => pick($::uca_mirror_host, 'http://ubuntu-cloud.archive.canonical.com/ubuntu'),
      }
      # Ceph is both packaged on UCA & ceph.com
      # Official packages are on ceph.com so we want to make sure
      # Ceph will be installed from there.
      apt::pin { 'ceph':
        priority => 1001,
        origin   => 'download.ceph.com',
      }
      $enable_sig  = false
      $enable_epel = false
      $ceph_mirror = pick($::ceph_mirror_host, 'http://download.ceph.com/debian-jewel/')
    }
    'RedHat': {
      class { '::openstack_extras::repo::redhat::redhat':
        release           => 'pike',
        centos_mirror_url => $::centos_mirror_host,
      }
      $ceph_mirror = pick($::ceph_mirror_host, 'http://mirror.centos.org/centos/7/storage/x86_64/ceph-jewel/')
      # On CentOS, deploy Ceph using SIG repository and get rid of EPEL.
      # https://wiki.centos.org/SpecialInterestGroup/Storage/
      if $::operatingsystem == 'CentOS' {
        $enable_sig  = true
        $enable_epel = false
      } else {
        $enable_sig  = false
        $enable_epel = true
      }
    }
    default: {
      fail("Unsupported osfamily (${::osfamily})")
    }
  }

  class { '::ceph::repo':
    enable_sig  => $enable_sig,
    enable_epel => $enable_epel,
    ceph_mirror => $ceph_mirror,
  }

}
