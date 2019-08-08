#!/bin/bash
#
# Copyright (C) 2018 ScyllaDB
#

#
# This file is part of Scylla.
#
# Scylla is free software: you can redistribute it and/or modify
# it under the terms of the GNU Affero General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# Scylla is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with Scylla.  If not, see <http://www.gnu.org/licenses/>.
#

set -e

. /etc/os-release
print_usage() {
    cat <<EOF
Usage: install.sh [options]

Options:
  --root /path/to/root     alternative install root (default /)
  --prefix /prefix         directory prefix (default /usr)
  --python3 /opt/python3   path of the python3 interpreter relative to install root (default /opt/scylladb/python3/bin/python3)
  --housekeeping           enable housekeeping service
  --nonroot                install Scylla without required root priviledge
  --pkg package            specify build package (server/conf/kernel-conf)
  --help                   this helpful message
EOF
    exit 1
}

root=/
housekeeping=false
python3=/opt/scylladb/python3/bin/python3
nonroot=false

while [ $# -gt 0 ]; do
    case "$1" in
        "--root")
            root="$2"
            shift 2
            ;;
        "--prefix")
            prefix="$2"
            shift 2
            ;;
        "--housekeeping")
            housekeeping=true
            shift 1
            ;;
        "--python3")
            python3="$2"
            shift 2
            ;;
        "--pkg")
            pkg="$2"
            shift 2
            ;;
        "--nonroot")
            nonroot=true
            shift 1
            ;;
        "--help")
            shift 1
	    print_usage
            ;;
        *)
            print_usage
            ;;
    esac
done
if [ -n "$pkg" ] && [ "$pkg" != "server" -a "$pkg" != "conf" -a "$pkg" != "kernel-conf" ]; then
    print_usage
    exit 1
fi

rprefix="$root/$prefix"
retc="$root/etc"
rusr="$root/usr"
rdoc="$rprefix/share/doc"

PPID_COMM=$(cat /proc/$PPID/comm)
GPPID=$(echo $(ps --no-header -o ppid -p $PPID))
GPPID_COMM=$(cat /proc/$GPPID/comm)

sysconfdir="sysconfig"
# detect rpmbuild for .rpm (could be cross build, don't use os-release)
if [ "$PPID_COMM" = "sh" -a "$GPPID_COMM" = "rpmbuild" ]; then
    disttype="redhat"
# detect debuild for .deb (could be cross build, don't use os-release)
elif [ "$PPID_COMM" = "rules" -a "$GPPID_COMM" = "dh" ]; then
    disttype="debian"
    sysconfdir="default"
# others should be invoked from a shell, detect current OS by os-release
else
    if [ -n "$ID_LIKE" ]; then
        id=$ID_LIKE
    else
        id=$ID
    fi
    if [ "$id" = "rhel" -o "$id" = "fedora" -o "$id" = "ol" ]; then
        disttype="redhat"
    elif [ "$id" = "debian" ]; then
        distype="debian"
        sysconfdir="default"
    else
        echo "Warning: unknown distribution $id, apply Red Hat variants configuration."
        disttype="redhat"
    fi
fi


if [ -z "$prefix" ]; then
    if $nonroot; then
        prefix=~/scylladb
    else
        prefix=/opt/scylladb
    fi
fi

rprefix=$(realpath -m "$root/$prefix")
if [ -z "$python3" ]; then
    python3=$prefix/python3/bin/python3
fi
rpython3=$(realpath -m "$root/$python3")
if ! $nonroot; then
    retc="$root/etc"
    rusr="$root/usr"
    rsystemd="$rusr/lib/systemd/system"
    rdoc="$rprefix/share/doc"
    rdata="$root/var/lib/scylla"
    rhkdata="$root/var/lib/scylla-housekeeping"
else
    retc="$rprefix/etc"
    rsystemd="$retc/systemd"
    rdoc="$rprefix/share/doc"
    rdata="$rprefix"
fi

if [ -z "$pkg" ] || [ "$pkg" = "conf" ]; then
    install -d -m755 "$retc"/scylla
    install -d -m755 "$retc"/scylla.d
    install -m644 conf/scylla.yaml -Dt "$retc"/scylla
    install -m644 conf/cassandra-rackdc.properties -Dt "$retc"/scylla
    if $housekeeping; then
        install -m644 conf/housekeeping.cfg -Dt "$retc"/scylla.d
    fi
fi
if [ -z "$pkg" ] || [ "$pkg" = "kernel-conf" ]; then
    if ! $nonroot; then
        install -m755 -d "$rusr/lib/sysctl.d"
        install -m644 dist/common/sysctl.d/*.conf -Dt "$rusr"/lib/sysctl.d
    fi
fi
if [ -z "$pkg" ] || [ "$pkg" = "server" ]; then
    install -m755 -d "$retc"/"$sysconfdir"
    install -m755 -d "$retc/scylla.d"
    install -m644 dist/common/sysconfig/scylla-server -Dt "$retc"/"$sysconfdir"
    install -m644 dist/common/scylla.d/*.conf -Dt "$retc"/scylla.d

    install -d -m755 "$retc"/scylla "$rprefix/bin" "$rprefix/libexec" "$rprefix/libreloc" "$rprefix/scripts" "$rprefix/bin"
    install -d -m755 "$rsystemd"
    install -m644 dist/common/systemd/*.service -Dt "$rsystemd"
    install -m644 dist/common/systemd/*.timer -Dt "$rsystemd"
    for i in scylla-server scylla-housekeeping-daily scylla-housekeeping-restart; do
        if [ -f dist/$disttype/systemd/$i.service.d/*.conf ]; then
            install -d -m755 "$retc"/systemd/system/$i.service.d
            install -m644 dist/$disttype/systemd/$i.service.d/*.conf "$retc"/systemd/system/$i.service.d
        fi
        if [ -f dist/common/systemd/$i.service.d/*.conf ]; then
            install -d -m755 "$retc"/systemd/system/$i.service.d
            install -m644 dist/common/systemd/$i.service.d/*.conf "$retc"/systemd/system/$i.service.d
        fi
    done
    install -m755 seastar/scripts/seastar-cpu-map.sh -Dt "$rprefix"/scripts
    install -m755 seastar/dpdk/usertools/dpdk-devbind.py -Dt "$rprefix"/scripts
    install -m755 bin/* -Dt "$rprefix/bin"
    # some files in libexec are symlinks, which "install" dereferences
    # use cp -P for the symlinks instead.
    install -m755 libexec/*.bin -Dt "$rprefix/libexec"
    for f in libexec/*; do
        if [[ "$f" != *.bin ]]; then
            cp -P "$f" "$rprefix/libexec"
        fi
    done
    install -m755 libreloc/* -Dt "$rprefix/libreloc"
    ln -srf "$rprefix/bin/scylla" "$rusr/bin/scylla"
    ln -srf "$rprefix/bin/iotune" "$rusr/bin/iotune"

    install -d -m755 "$rdoc"/scylla
    install -m644 README.md -Dt "$rdoc"/scylla/
    install -m644 README-DPDK.md -Dt "$rdoc"/scylla
    install -m644 NOTICE.txt -Dt "$rdoc"/scylla/
    install -m644 ORIGIN -Dt "$rdoc"/scylla/
    install -d -m755 -d "$rdoc"/scylla/licenses/
    install -m644 licenses/* -Dt "$rdoc"/scylla/licenses/
    install -m755 -d "$rdata"
    install -m755 -d "$rdata"/data
    install -m755 -d "$rdata"/commitlog
    install -m755 -d "$rdata"/hints
    install -m755 -d "$rdata"/view_hints
    install -m755 -d "$rdata"/coredump
    install -m755 -d "$rprefix"/swagger-ui
    cp -r swagger-ui/dist "$rprefix"/swagger-ui
    install -d -m755 -d "$rprefix"/api
    cp -r api/api-doc "$rprefix"/api
    install -d -m755 -d "$rprefix"/scyllatop
    cp -r tools/scyllatop/* "$rprefix"/scyllatop
    install -d -m755 -d "$rprefix"/scripts
    cp -r dist/common/scripts/* "$rprefix"/scripts

    SBINFILES=$(cd dist/common/scripts/; ls scylla_*setup node_exporter_install node_health_check scylla_ec2_check scylla_kernel_check)
    if ! $nonroot; then
        install -m755 -d "$retc/security/limits.d"
        install -m755 -d "$rusr/bin"
        install -m755 -d "$rhkdata"
        install -m644 dist/common/limits.d/scylla.conf -Dt "$retc"/security/limits.d
        install -m644 dist/common/systemd/*.timer -Dt $rsystemd
        ln -srf "$rprefix/bin/scylla" "$rusr/bin/scylla"
        ln -srf "$rprefix/bin/iotune" "$rusr/bin/iotune"
        ln -srf "$rprefix/scyllatop/scyllatop.py" "$rusr/bin/scyllatop"
        install -d "$rusr"/sbin
        for i in $SBINFILES; do
            ln -srf "$rprefix/scripts/$i" "$rusr/sbin/$i"
        done
    else
        install -d -m755 "$retc"/systemd/system/scylla-server.service.d
        cat << EOS > "$retc"/systemd/system/scylla-server.service.d/nonroot.conf
[Service]
EnvironmentFile=
EnvironmentFile=$retc/$sysconfdir/scylla-server
EnvironmentFile=$retc/scylla.d/*.conf
ExecStartPre=
ExecStart=
ExecStart=$rprefix/bin/scylla \$SCYLLA_ARGS \$SEASTAR_IO \$DEV_MODE \$CPUSET
ExecStopPost=
User=
EOS
        install -m755 dist/nonroot/setup.sh "$rprefix"
        ln -srf "$rprefix/scyllatop/scyllatop.py" "$rprefix/bin/scyllatop"
        install -d "$rprefix"/sbin
        for i in $SBINFILES; do
            ln -srf "$rprefix/scripts/$i" "$rprefix/sbin/$i"
        done
        mkdir -p ~/.config/systemd/user/scylla-server.service.d
        ln -srf $rsystemd/scylla-server.service ~/.config/systemd/user/
        ln -srf "$retc"/systemd/system/scylla-server.service.d/nonroot.conf ~/.config/systemd/user/scylla-server.service.d
    fi

    install -m755 scylla-gdb.py -Dt "$rprefix"/scripts/

    PYSCRIPTS=$(find dist/common/scripts/ -maxdepth 1 -type f -exec grep -Pls '\A#!/usr/bin/env python3' {} +)
    for i in $PYSCRIPTS; do
        ./relocate_python_scripts.py \
                --installroot $rprefix/scripts/ --with-python3 "$rpython3" $i
    done
    ./relocate_python_scripts.py \
                --installroot $rprefix/scripts/ --with-python3 "$rpython3" \
                seastar/scripts/perftune.py seastar/scripts/seastar-addr2line seastar/scripts/perftune.py

    ./relocate_python_scripts.py \
                --installroot $rprefix/scyllatop/ --with-python3 "$rpython3" \
                tools/scyllatop/scyllatop.py
fi

if $nonroot; then
    sed -i -e "s#/var/lib/scylla#$rprefix#g" $retc/scylla/scylla.yaml
    sed -i -e "s/^# hints_directory/hints_directory/" $retc/scylla/scylla.yaml
    sed -i -e "s/^# view_hints_directory/view_hints_directory/" $retc/scylla/scylla.yaml
    sed -i -e "s/^# saved_caches_directory/saved_caches_directory/" $retc/scylla/scylla.yaml
    sed -i -e "s#/var/lib/scylla#$rprefix#g" $retc/$sysconfdir/scylla-server
    sed -i -e "s#/etc/scylla#$retc/scylla#g" $retc/$sysconfdir/scylla-server
    touch $retc/scylla/nonroot_configured
    systemctl --user daemon-reload
    echo "Scylla non-root install completed."
    echo "Run ./setup.sh before starting scylla-server."
fi
