#!/bin/sh
set -eu

ROOT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
exec "${ROOT_DIR}/scripts/package-macos.sh" "${1:-dev}" amd64
