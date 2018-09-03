#!/bin/bash -e

. /etc/os-release

print_usage() {
    echo "build_reloc.sh --jobs 2"
    echo "  --jobs  specify number of jobs"
    echo "  --clean clean build directory"
    exit 1
}

JOBS=
CLEAN=
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
        *)
            print_usage
            ;;
    esac
done


if [ ! -e dist/reloc/build_reloc.sh ]; then
    echo "run build_reloc.sh in top of scylla dir"
    exit 1
fi
if [ "$ID" != "fedora" ]; then
    echo "Only Fedora is supported distribution for build_reloc.sh"
    exit 1
fi

if [ "$CLEAN" = "yes" ]; then
    rm -rf build
fi
if [ "$ID" != "fedora" ]; then
    echo "Only Fedora is supported distribution for build_reloc.sh"
    exit 1
fi

if [ -f build/release/scylla-package.tar.xz ]; then
    rm build/release/scylla-package.tar.xz
fi

sudo ./install-dependencies.sh
./SCYLLA-VERSION-GEN
ninja-build $JOBS build/release/scylla-package.tar.xz
