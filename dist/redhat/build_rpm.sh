#!/bin/bash -e

PRODUCT=scylla

. /etc/os-release
print_usage() {
    echo "build_rpm.sh --rebuild-dep --jobs 2 --target epel-7-$(uname -m) --reloc-tar build/release/scylla-package.tar.xz"
    echo "  --jobs  specify number of jobs"
    echo "  --dist  create a public distribution rpm"
    echo "  --target target distribution in mock cfg name"
    echo "  --xtrace print command traces before executing command"
    echo "  --reloc-pkg specify relocatable package path"
    exit 1
}
RPM_JOBS_OPTS=
DIST=false
TARGET=
RELOC_PKG=build/release/scylla-package.tar.xz
while [ $# -gt 0 ]; do
    case "$1" in
        "--jobs")
            RPM_JOBS_OPTS=(--define="_smp_mflags -j$2")
            shift 2
            ;;
        "--dist")
            DIST=true
            shift 1
            ;;
        "--target")
            TARGET=$2
            shift 2
            ;;
        "--xtrace")
            set -o xtrace
            shift 1
            ;;
        "--reloc-pkg")
            RELOC_PKG=$2
            shift 2
            ;;
        *)
            print_usage
            ;;
    esac
done

is_redhat_variant() {
    [ -f /etc/redhat-release ]
}
pkg_install() {
    if is_redhat_variant; then
        sudo yum install -y $1
    else
        echo "Requires to install following command: $1"
        exit 1
    fi
}


if [ ! -e dist/redhat/build_rpm.sh ]; then
    echo "run build_rpm.sh in top of scylla dir"
    exit 1
fi

if [ -z "$TARGET" ]; then
    TARGET=centos
fi
if [ ! -f $RELOC_PKG ]; then
    echo "run dist/reloc/build_reloc.sh before running build_rpm.sh"
    exit 1
fi

if [ ! -f /usr/bin/rpmbuild ]; then
    pkg_install rpm-build
fi
if [ ! -f /usr/bin/git ]; then
    pkg_install git
fi
if [ ! -f /usr/bin/wget ]; then
    pkg_install wget
fi
if [ ! -f /usr/bin/yum-builddep ]; then
    pkg_install yum-utils
fi
if [ ! -f /usr/bin/pystache ]; then
    if is_redhat_variant; then
        sudo yum install -y python2-pystache || sudo yum install -y pystache
    elif is_debian_variant; then
        sudo apt-get install -y python2-pystache
    fi
fi

RELOC_PKG_FULLPATH=$(readlink -f $RELOC_PKG)
RELOC_PKG_BASENAME=$(basename $RELOC_PKG)
mkdir -p build
cd build/
tar xvpf $RELOC_PKG_FULLPATH SCYLLA-*-FILE dist/redhat/scylla.spec.mustache
cd -

SCYLLA_VERSION=$(cat build/SCYLLA-VERSION-FILE)
SCYLLA_RELEASE=$(cat build/SCYLLA-RELEASE-FILE)
RPMBUILD=$(readlink -f build/rpmbuild)
MUSTACHE_DIST="\"$TARGET\": true, \"target\": \"$TARGET\""

mkdir -p $RPMBUILD/{BUILD,BUILDROOT,RPMS,SOURCES,SPECS,SRPMS}
ln -fv $RELOC_PKG_FULLPATH $RPMBUILD/SOURCES/
pystache build/dist/redhat/scylla.spec.mustache "{ \"version\": \"$SCYLLA_VERSION\", \"release\": \"$SCYLLA_RELEASE\", \"housekeeping\": $DIST, \"product\": \"$PRODUCT\", \"$PRODUCT\": true, \"reloc_pkg\": \"$RELOC_PKG_BASENAME\", $MUSTACHE_DIST }" > $RPMBUILD/SPECS/scylla.spec
rpmbuild -ba --define "_topdir $RPMBUILD" $RPM_JOBS_OPTS $RPMBUILD/SPECS/scylla.spec
