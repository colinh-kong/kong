

#!/usr/bin/env bash

set -euo pipefail
IFS=$'\n\t'

if [ -n "${DEBUG:-}" ]; then
    set -x
fi

function test() {
    echo '--- testing kong ---'
    cp -R /tmp/build/* /

    mv /tmp/build /tmp/buffer # Check we didn't link dependencies to `/tmp/build/...`
    ls -l /etc/kong/kong.conf.default
    ls -l /etc/kong/kong*.logrotate
    ls -l /usr/local/kong/include/google/protobuf/*.proto
    ls -l /usr/local/kong/include/openssl/*.h

    kong version

    mv /tmp/buffer /tmp/build
    echo '--- tested kong ---'
}

test