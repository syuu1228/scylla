#!/bin/bash -e

. /etc/os-release
print_usage() {
    echo "build_deb.sh --rebuild-dep"
    echo "  --dist  create a public distribution package"
    echo "  --rebuild-dep  rebuild dependency packages"
    exit 1
}
install_deps() {
    echo Y | sudo mk-build-deps
    sudo gdebi -n ./*-build-deps*.deb
}

REBUILD=0
DIST=0
while [ $# -gt 0 ]; do
    case "$1" in
        "--rebuild-dep")
            REBUILD=1
            shift 1
            ;;
        "--dist")
            DIST=1
            shift 1
            ;;
        *)
            print_usage
            ;;
    esac
done


if [ ! -e dist/debian/build_deb.sh ]; then
    echo "run build_deb.sh in top of scylla dir"
    exit 1
fi

if [ -e debian ] || [ -e build/release ]; then
    rm -rf debian build
    mkdir build
fi
sudo apt-get -y update
if [ ! -f /usr/bin/git ]; then
    sudo apt-get -y install git
fi
if [ ! -f /usr/bin/mk-build-deps ]; then
    sudo apt-get -y install devscripts
fi
if [ ! -f /usr/bin/equivs-build ]; then
    sudo apt-get -y install equivs
fi
if [ ! -f /usr/bin/add-apt-repository ]; then
    sudo apt-get -y install software-properties-common
fi
if [ ! -f /usr/bin/wget ]; then
    sudo apt-get -y install wget
fi
if [ ! -f /usr/bin/lsb_release ]; then
    sudo apt-get -y install lsb-release
fi

DISTRIBUTION=`lsb_release -i|awk '{print $3}'`
CODENAME=`lsb_release -c|awk '{print $2}'`
if [ `grep -c $VERSION_ID dist/debian/supported_release` -lt 1 ]; then
    echo "Unsupported release: $VERSION_ID"
    echo "Pless any key to continue..."
    read input
fi

VERSION=$(./SCYLLA-VERSION-GEN)
SCYLLA_VERSION=$(cat build/SCYLLA-VERSION-FILE | sed 's/\.rc/~rc/')
SCYLLA_RELEASE=$(cat build/SCYLLA-RELEASE-FILE)
echo $VERSION > version
./scripts/git-archive-all --extra version --force-submodules --prefix scylla-server ../scylla-server_$SCYLLA_VERSION-$SCYLLA_RELEASE.orig.tar.gz 

cp -a dist/debian/debian debian
cp dist/common/sysconfig/scylla-server debian/scylla-server.default
cp dist/debian/changelog.in debian/changelog
sed -i -e "s/@@VERSION@@/$SCYLLA_VERSION/g" debian/changelog
sed -i -e "s/@@RELEASE@@/$SCYLLA_RELEASE/g" debian/changelog
sed -i -e "s/@@CODENAME@@/$CODENAME/g" debian/changelog
cp dist/debian/rules.in debian/rules
cp dist/debian/control.in debian/control
cp dist/debian/scylla-server.install.in debian/scylla-server.install
if [ "$DISTRIBUTION" = "Debian" ]; then
    sed -i -e "s/@@REVISION@@/1/g" debian/changelog
    sed -i -e "s/@@DH_INSTALLINIT@@//g" debian/rules
    sed -i -e "s/@@COMPILER@@/g++-5/g" debian/rules
    sed -i -e "s/@@BUILD_DEPENDS@@/libsystemd-dev, g++-5, libunwind-dev/g" debian/control
    sed -i -e "s/@@DEPENDS@@//g" debian/control
    sed -i -e "s#@@INSTALL@@##g" debian/scylla-server.install
    sed -i -e "s#@@HKDOTTIMER_D@@#dist/common/systemd/scylla-housekeeping-daily.timer /lib/systemd/system#g" debian/scylla-server.install
    sed -i -e "s#@@HKDOTTIMER_R@@#dist/common/systemd/scylla-housekeeping-restart.timer /lib/systemd/system#g" debian/scylla-server.install
    sed -i -e "s#@@SYSCTL@@#dist/debian/sysctl.d/99-scylla.conf etc/sysctl.d#g" debian/scylla-server.install
    sed -i -e "s#@@SCRIPTS_SAVE_COREDUMP@@#dist/debian/scripts/scylla_save_coredump usr/lib/scylla#g" debian/scylla-server.install
    sed -i -e "s#@@SCRIPTS_FSTRIM@@#dist/debian/scripts/scylla_fstrim usr/lib/scylla#g" debian/scylla-server.install
    sed -i -e "s#@@SCRIPTS_DELAY_FSTRIM@@#dist/debian/scripts/scylla_delay_fstrim usr/lib/scylla#g" debian/scylla-server.install
elif [ "$VERSION_ID" = "14.04" ]; then
    sed -i -e "s/@@REVISION@@/0ubuntu1/g" debian/changelog
    sed -i -e "s/@@DH_INSTALLINIT@@/--upstart-only/g" debian/rules
    sed -i -e "s/@@COMPILER@@/g++-5/g" debian/rules
    sed -i -e "s/@@BUILD_DEPENDS@@/g++-5, libunwind8-dev/g" debian/control
    sed -i -e "s/@@DEPENDS@@/hugepages, num-utils/g" debian/control
    sed -i -e "s#@@INSTALL@@#dist/debian/sudoers.d/scylla etc/sudoers.d#g" debian/scylla-server.install
    sed -i -e "s#@@HKDOTTIMER_D@@##g" debian/scylla-server.install
    sed -i -e "s#@@HKDOTTIMER_R@@##g" debian/scylla-server.install
    sed -i -e "s#@@SYSCTL@@#dist/debian/sysctl.d/99-scylla.conf etc/sysctl.d#g" debian/scylla-server.install
    sed -i -e "s#@@SCRIPTS_SAVE_COREDUMP@@#dist/debian/scripts/scylla_save_coredump usr/lib/scylla#g" debian/scylla-server.install
    sed -i -e "s#@@SCRIPTS_FSTRIM@@#dist/debian/scripts/scylla_fstrim usr/lib/scylla#g" debian/scylla-server.install
    sed -i -e "s#@@SCRIPTS_DELAY_FSTRIM@@#dist/debian/scripts/scylla_delay_fstrim usr/lib/scylla#g" debian/scylla-server.install
else
    sed -i -e "s/@@REVISION@@/0ubuntu1/g" debian/changelog
    sed -i -e "s/@@DH_INSTALLINIT@@//g" debian/rules
    sed -i -e "s/@@COMPILER@@/g++/g" debian/rules
    sed -i -e "s/@@BUILD_DEPENDS@@/libsystemd-dev, g++, libunwind-dev/g" debian/control
    sed -i -e "s/@@DEPENDS@@/hugepages, /g" debian/control
    sed -i -e "s#@@INSTALL@@##g" debian/scylla-server.install
    sed -i -e "s#@@HKDOTTIMER_D@@#dist/common/systemd/scylla-housekeeping-daily.timer /lib/systemd/system#g" debian/scylla-server.install
    sed -i -e "s#@@HKDOTTIMER_R@@#dist/common/systemd/scylla-housekeeping-restart.timer /lib/systemd/system#g" debian/scylla-server.install
    sed -i -e "s#@@SYSCTL@@##g" debian/scylla-server.install
    sed -i -e "s#@@SCRIPTS_SAVE_COREDUMP@@##g" debian/scylla-server.install
    sed -i -e "s#@@SCRIPTS_FSTRIM@@##g" debian/scylla-server.install
    sed -i -e "s#@@SCRIPTS_DELAY_FSTRIM@@##g" debian/scylla-server.install
fi
if [ $DIST -gt 0 ]; then
    sed -i -e "s#@@ADDHKCFG@@#conf/housekeeping.cfg etc/scylla.d/#g" debian/scylla-server.install
else
    sed -i -e "s#@@ADDHKCFG@@##g" debian/scylla-server.install
fi

cp dist/common/systemd/scylla-server.service.in debian/scylla-server.service
sed -i -e "s#@@SYSCONFDIR@@#/etc/default#g" debian/scylla-server.service
cp dist/common/systemd/scylla-housekeeping-daily.service debian/scylla-server.scylla-housekeeping-daily.service
cp dist/common/systemd/scylla-housekeeping-restart.service debian/scylla-server.scylla-housekeeping-restart.service
cp dist/common/systemd/node-exporter.service debian/scylla-server.node-exporter.service
if [ "$DISTRIBUTION" = "Debian" ] || [ "$VERSION_ID" = "14.04" ]; then
    cp dist/debian/scylla-server.cron.d debian/
fi

if [ $REBUILD -eq 0 ]; then
    if [ "$DISTRIBUTION" != "Ubuntu" ]; then
        echo "Prebuilt 3rdparty is not supported in this distribution."
        exit 1
    fi
    if [ ! -f /etc/apt/sources.list.d/scylla-3rdparty.list ]; then
        cd /etc/apt/sources.list.d
        sudo wget -nv https://s3.amazonaws.com/downloads.scylladb.com/deb/3rdparty/$CODENAME/scylla-3rdparty.list
        cd -
    fi
    sudo apt-get -y update
    sudo apt-get -y --allow-unauthenticated install antlr3 antlr3-c++-dev libthrift-dev libthrift0 thrift-compiler
else
    ./dist/debian/dep/build_dependency.sh
fi

if [ "$VERSION_ID" = "14.04" ]; then
    sudo add-apt-repository -y ppa:ubuntu-toolchain-r/test
    sudo apt-get -y update
elif [ "$DISTRIBUTION" = "Ubuntu" ]; then
    sudo apt-get -y install g++-5
else
    sudo apt-get install g++
fi

install_deps
debuild -r fakeroot -us -uc
