#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
python3 scripts/prepare_web.py build/ipad-editor
mkdir -p iPad/public
rsync -a --delete build/ipad-editor/ iPad/public/
cp 'docs/examples/Series circuit.gridnote' iPad/public/series-circuit.gridnote
cd iPad
xcodegen generate --spec project.yml
