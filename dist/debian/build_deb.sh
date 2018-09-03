#!/bin/bash -e

PRODUCT=scylla

. /etc/os-release
print_usage() {
    echo "build_deb.sh -target <codename> --dist --rebuild-dep --jobs 2 --reloc-tar build/release/scylla-package.tar.xz"
    echo "  --target target distribution codename"
    echo "  --dist  create a public distribution package"
    echo "  --jobs  specify number of jobs"
    echo "  --reloc-pkg specify relocatable package path"
    exit 1
}

DIST="false"
TARGET=
DEB_BUILD_OPTIONS=
RELOC_PKG=build/release/scylla-package.tar.xz
while [ $# -gt 0 ]; do
    case "$1" in
        "--dist")
            DIST="true"
            shift 1
            ;;
        "--target")
            TARGET=$2
            shift 2
            ;;
        "--jobs")
            DEB_BUILD_OPTIONS="parallel=$2"
            shift 2
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
is_debian_variant() {
    [ -f /etc/debian_version ]
}
is_debian() {
    case "$1" in
        jessie|stretch) return 0;;
        *) return 1;;
    esac
}
is_ubuntu() {
    case "$1" in
        trusty|xenial|bionic) return 0;;
        *) return 1;;
    esac
}


pkg_install() {
    if is_redhat_variant; then
        sudo yum install -y $1
    elif is_debian_variant; then
        sudo apt-get install -y $1
    else
        echo "Requires to install following command: $1"
        exit 1
    fi
}

if [ ! -e dist/debian/build_deb.sh ]; then
    echo "run build_deb.sh in top of scylla dir"
    exit 1
fi
if [ "$(arch)" != "x86_64" ]; then
    echo "Unsupported architecture: $(arch)"
    exit 1
fi
if [ ! -f $RELOC_PKG ]; then
    echo "run dist/reloc/build_reloc.sh before running build_rpm.sh"
    exit 1
fi

if [ -e debian ]; then
    sudo rm -rf debian
fi
if is_debian_variant; then
    sudo apt-get -y update
fi
# this hack is needed since some environment installs 'git-core' package, it's
# subset of the git command and doesn't works for our git-archive-all script.
if is_redhat_variant && [ ! -f /usr/libexec/git-core/git-submodule ]; then
    sudo yum install -y git
fi
if [ ! -f /usr/bin/git ]; then
    pkg_install git
fi
if [ ! -f /usr/bin/python ]; then
    pkg_install python
fi
if [ ! -f /usr/sbin/debuild ]; then
    pkg_install devscripts
fi
if [ ! -f /usr/bin/dh_testdir ]; then
    pkg_install debhelper
fi
if [ ! -f /usr/bin/pystache ]; then
    if is_redhat_variant; then
        sudo yum install -y /usr/bin/pystache
    elif is_debian_variant; then
        sudo apt-get install -y python-pystache
    fi
fi
if is_debian_variant && [ ! -f /usr/share/doc/python-pkg-resources/copyright ]; then
    sudo apt-get install -y python-pkg-resources
fi

if [ -z "$TARGET" ]; then
    if is_debian_variant; then
        if [ ! -f /usr/bin/lsb_release ]; then
            pkg_install lsb-release
        fi
        TARGET=`lsb_release -c|awk '{print $2}'`
    else
        echo "Please specify target"
        exit 1
    fi
fi


RELOC_PKG_FULLPATH=$(readlink -f $RELOC_PKG)
RELOC_PKG_BASENAME=$(basename $RELOC_PKG)
mkdir -p build/scylla-package
cd build/scylla-package
tar xvpf $RELOC_PKG_FULLPATH

SCYLLA_VERSION=$(cat SCYLLA-VERSION-FILE)
SCYLLA_RELEASE=$(cat SCYLLA-RELEASE-FILE)

ln -fv $RELOC_PKG_FULLPATH ../$PRODUCT-server_$SCYLLA_VERSION-$SCYLLA_RELEASE.orig.tar.xz

cp -a dist/debian/debian debian
if [ "$PRODUCT" != "scylla" ]; then
    for i in debian/scylla-*;do
        mv $i ${i/scylla-/$PRODUCT-}
    done
fi
ln -fv dist/common/sysconfig/scylla-server debian/$PRODUCT-server.default
if [ "$TARGET" = "trusty" ]; then
    ln -fv dist/debian/scylla-server.cron.d debian/
fi
if is_debian $TARGET; then
    REVISION="1~$TARGET"
elif is_ubuntu $TARGET; then
    REVISION="0ubuntu1~$TARGET"
else
   echo "Unknown distribution: $TARGET"
fi
MUSTACHE_DIST="\"debian\": true, \"$TARGET\": true, \"product\": \"$PRODUCT\", \"$PRODUCT\": true"
pystache dist/debian/changelog.mustache "{ $MUSTACHE_DIST, \"version\": \"$SCYLLA_VERSION\", \"release\": \"$SCYLLA_RELEASE\", \"revision\": \"$REVISION\", \"codename\": \"$TARGET\" }" > debian/changelog
pystache dist/debian/rules.mustache "{ $MUSTACHE_DIST }" > debian/rules
pystache dist/debian/control.mustache "{ $MUSTACHE_DIST }" > debian/control
pystache dist/debian/scylla-server.install.mustache "{ $MUSTACHE_DIST, \"dist\": $DIST }" > debian/$PRODUCT-server.install
pystache dist/debian/scylla-conf.preinst.mustache "{ \"version\": \"$SCYLLA_VERSION\" }" > debian/$PRODUCT-conf.preinst
chmod a+rx debian/rules

if [ "$TARGET" != "trusty" ]; then
    if [ "$PRODUCT" != "scylla" ]; then
        SERVER_SERVICE_PREFIX="$PRODUCT-server."
    fi
    pystache dist/common/systemd/scylla-server.service.mustache "{ $MUSTACHE_DIST }" > debian/${SERVER_SERVICE_PREFIX}scylla-server.service
    pystache dist/common/systemd/scylla-housekeeping-daily.service.mustache "{ $MUSTACHE_DIST }" > debian/$PRODUCT-server.scylla-housekeeping-daily.service
    pystache dist/common/systemd/scylla-housekeeping-restart.service.mustache "{ $MUSTACHE_DIST }" > debian/$PRODUCT-server.scylla-housekeeping-restart.service
    ln -fv dist/common/systemd/scylla-fstrim.service debian/$PRODUCT-server.scylla-fstrim.service
    ln -fv dist/common/systemd/node-exporter.service debian/$PRODUCT-server.node-exporter.service
fi

debuild -rfakeroot -us -uc
cd -
