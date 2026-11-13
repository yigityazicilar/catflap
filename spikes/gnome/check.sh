#!/usr/bin/env bash
set -euo pipefail
cd /repo
exec python spikes/gnome/check.py
