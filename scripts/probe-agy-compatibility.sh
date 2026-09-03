#!/usr/bin/env bash
set -euo pipefail
exec pwsh -NoProfile -NonInteractive -File "$(cd "$(dirname "$0")" && pwd)/probe-agy-compatibility.ps1" "$@"
