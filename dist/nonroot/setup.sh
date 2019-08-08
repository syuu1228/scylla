#!/bin/bash -e
#
#  Copyright (C) 2019 ScyllaDB

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

echo "Setup Scylla non-root mode..."

scylla_dir=$(realpath $(dirname $0))

$scylla_dir/bin/iotune --format envfile --options-file $scylla_dir/etc/scylla.d/io.conf --properties-file $scylla_dir/etc/scylla.d/io_properties.yaml --evaluation-directory $scylla_dir/data

echo "Scylla non-root setup completed."
echo "To start Scylla, run 'systemctl --user start scylla-server.service'"
