#!/bin/sh -e

if [ ! -e dist/ami/build_ami_local.sh ]; then
    echo "run build_ami_local.sh in top of scylla dir"
    exit 1
fi

sudo yum -y install git
if [ ! -f dist/ami/scylla-server.x86_64.rpm ]; then
    dist/redhat/build_rpm.sh
    cp build/rpms/scylla-server-`cat build/SCYLLA-VERSION-FILE`-`cat build/SCYLLA-RELEASE-FILE`.*.x86_64.rpm dist/ami/scylla-server.x86_64.rpm
fi
if [ ! -f dist/ami/scylla-jmx.noarch.rpm ]; then
    cd build
    git clone --depth 1 https://github.com/scylladb/scylla-jmx.git
    cd scylla-jmx
    sh -x -e dist/redhat/build_rpm.sh
    cd ../..
    cp build/scylla-jmx/build/rpms/scylla-jmx-`cat build/scylla-jmx/build/SCYLLA-VERSION-FILE`-`cat build/scylla-jmx/build/SCYLLA-RELEASE-FILE`.*.noarch.rpm dist/ami/scylla-jmx.noarch.rpm
fi
if [ ! -f dist/ami/scylla-tools.noarch.rpm ]; then
    cd build
    git clone --depth 1 https://github.com/scylladb/scylla-tools-java.git
    cd scylla-tools-java
    sh -x -e dist/redhat/build_rpm.sh
    cd ../..
    cp build/scylla-tools-java/build/rpms/scylla-tools-`cat build/scylla-tools-java/build/SCYLLA-VERSION-FILE`-`cat build/scylla-tools-java/build/SCYLLA-RELEASE-FILE`.*.noarch.rpm dist/ami/scylla-tools.noarch.rpm
fi

exec dist/ami/build_ami.sh scylla_local.json
