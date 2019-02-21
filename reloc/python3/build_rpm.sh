#!/bin/bash -e

. /etc/os-release
print_usage() {
    echo "build_rpm.sh --reloc-pkg build/release/scylla-python3-package.tar.gz"
    echo "  --reloc-pkg specify relocatable package path"
    exit 1
}
RELOC_PKG=build/release/scylla-python3-package.tar.gz
OPTS=""
while [ $# -gt 0 ]; do
    case "$1" in
        "--reloc-pkg")
            OPTS="$OPTS $1 $(readlink -f $2)"
            RELOC_PKG=$2
            shift 2
            ;;
        *)
            print_usage
            ;;
    esac
done

if [ ! -e $RELOC_PKG ]; then
    echo "$RELOC_PKG does not exist."
    echo "Run ./reloc/python3/build_reloc.sh first."
    exit 1
fi
RELOC_PKG=$(readlink -f $RELOC_PKG)
if [[ ! $OPTS =~ --reloc-pkg ]]; then
    OPTS="$OPTS --reloc-pkg $RELOC_PKG"
fi
mkdir -p build/redhat/scylla-python3-package
tar -C build/redhat/scylla-python3-package -xpf $RELOC_PKG SCYLLA-*-FILE dist/redhat/python3
cd build/redhat/scylla-python3-package
exec ./dist/redhat/python3/build_rpm.sh $OPTS
