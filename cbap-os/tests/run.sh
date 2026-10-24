#!/bin/bash
set -euo pipefail
HERE="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
cd "$HERE/../.."
python3 -m unittest -v cbap-os/tests/test_cbap_os.py
