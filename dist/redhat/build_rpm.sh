#!/bin/bash -e

PRODUCT=scylla

. /etc/os-release
print_usage() {
    echo "build_rpm.sh --rebuild-dep --target centos7 --reloc-pkg build/release/scylla-package.tar.gz"
    echo "  --dist  create a public distribution rpm"
    echo "  --target target distribution in mock cfg name"
    echo "  --xtrace print command traces before executing command"
    echo "  --reloc-pkg specify relocatable package path"
    echo "  --nodeps skip installing dependencies"
    exit 1
}
DIST=false
TARGET=
RELOC_PKG=
NODEPS=
while [ $# -gt 0 ]; do
    case "$1" in
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
        "--nodeps")
            NODEPS=yes
            shift 1
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
    if [ -z "$NODEPS" ] && is_redhat_variant; then
        sudo yum install -y $1
    else
        echo "Requires to install following command: $1"
        exit 1
    fi
}


if [ ! -e SCYLLA-RELOCATABLE-FILE ]; then
    echo "do not directly execute build_rpm.sh, use reloc/build_rpm.sh instead."
    exit 1
fi

if [ -z "$TARGET" ] || [ "$TARGET" = "centos" ]; then
    TARGET=centos7
fi

if [ "$TARGET" = "fedora" ]; then
    TARGET=fedora28
fi

if [[ ! $TARGET =~ fedora.*|centos.* ]]; then
    echo "unknown distribution specified."
    echo "can be used following target:"
    echo "  centos"
    echo "  centos7"
    echo "  fedora"
    echo "  fedora28"
    echo
    echo "when --target parameter not specified, centos7 will use as default value."
    exit 1
fi

if [ -z "$RELOC_PKG" ]; then
    print_usage
    exit 1
fi
if [ ! -f "$RELOC_PKG" ]; then
    echo "$RELOC_PKG is not found."
    exit 1
fi

if [ ! -f /usr/bin/rpmbuild ]; then
    pkg_install rpm-build
fi
if [ ! -f /usr/bin/git ]; then
    pkg_install git
fi
if [ ! -f /usr/bin/pystache ]; then
    if is_redhat_variant; then
        sudo yum install -y python2-pystache || sudo yum install -y pystache
    elif is_debian_variant; then
        sudo apt-get install -y python2-pystache
    fi
fi

RELOC_PKG_BASENAME=$(basename $RELOC_PKG)
SCYLLA_VERSION=$(cat SCYLLA-VERSION-FILE)
SCYLLA_RELEASE=$(cat SCYLLA-RELEASE-FILE)
MUSTACHE_DIST="\"$TARGET\": true, \"target\": \"$TARGET\""

RPMBUILD=$(readlink -f ../)
mkdir -p $RPMBUILD/{BUILD,BUILDROOT,RPMS,SOURCES,SPECS,SRPMS}

ln -fv $RELOC_PKG $RPMBUILD/SOURCES/
pystache dist/redhat/scylla.spec.mustache "{ \"version\": \"$SCYLLA_VERSION\", \"release\": \"$SCYLLA_RELEASE\", \"housekeeping\": $DIST, \"product\": \"$PRODUCT\", \"$PRODUCT\": true, \"reloc_pkg\": \"$RELOC_PKG_BASENAME\", $MUSTACHE_DIST }" > $RPMBUILD/SPECS/scylla.spec
if [ "$TARGET" = "centos7" ]; then
    rpmbuild -ba --define "_topdir $RPMBUILD" --define "dist .el7" $RPMBUILD/SPECS/scylla.spec
else
    rpmbuild -ba --define "_topdir $RPMBUILD" $RPMBUILD/SPECS/scylla.spec
fi
