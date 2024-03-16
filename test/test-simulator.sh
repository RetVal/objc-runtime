#!/bin/bash

set -euxo pipefail

cd "$(dirname $0)/test-simulator"
swift build -c release
BIN_PATH="$(swift build -c release --show-bin-path)"
exec "$BIN_PATH/test-simulator" "$@"
