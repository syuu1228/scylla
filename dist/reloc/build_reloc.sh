#!/bin/bash -e

. /etc/os-release

print_usage() {
    echo "build_reloc.sh --jobs 2"
    echo "  --jobs  specify number of jobs"
    echo "  --clean clean build directory"
    echo "  --compiler  C++ compiler path"
    echo "  --python    Python3 path"
    echo "  --ninja     ninja path"
    exit 1
}

JOBS=
CLEAN=
COMPILER=
PYTHON=
NINJA=ninja-build
while [ $# -gt 0 ]; do
    case "$1" in
        "--jobs")
            JOBS="-j$2"
            shift 2
            ;;
        "--clean")
            CLEAN=yes
            shift 1
            ;;
        "--compiler")
            COMPILER=$2
            shift 2
            ;;
        "--python")
            PYTHON=$2
            shift 2
            ;;
        "--ninja")
            NINJA=$2
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


if [ ! -e dist/reloc/build_reloc.sh ]; then
    echo "run build_reloc.sh in top of scylla dir"
    exit 1
fi

if [ "$CLEAN" = "yes" ]; then
    rm -rf build
fi

if [ -f build/release/scylla-package.tar.gz ]; then
    rm build/release/scylla-package.tar.gz
fi

if [ ! -f /usr/include/systemd/sd-messages.h ]; then
    if is_redhat_variant; then
        sudo yum install -y systemd-devel
    elif is_debian-variant; then
        sudo apt-get install -y libsystemd-dev
    else
        echo "Need to install libsystemd header before running build_reloc.sh"
        exit 1
    fi
fi

sudo ./install-dependencies.sh

FLAGS="--with=scylla --with=iotune --mode=release"
if [ -n "$COMPILER" ]; then
    FLAGS="$FLAGS --compiler $COMPILER"
fi
if [ -n "$PYTHON" ]; then
    FLAGS="$FLAGS --python $PYTHON"
    $PYTHON ./configure.py $FLAGS
else
    ./configure.py $FLAGS
fi
./SCYLLA-VERSION-GEN
$NINJA $JOBS build/release/scylla-package.tar.gz
