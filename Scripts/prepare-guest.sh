#!/bin/bash
set -euo pipefail
task_root=$(cd "$(dirname "$0")/.." && pwd)
exec python3 "$task_root/Scripts/prepare_guest.py" "$@"
