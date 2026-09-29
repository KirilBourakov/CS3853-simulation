#!/bin/bash
set -eo pipefail

echo "=== Running Python seed script via UNIX socket ==="
python3 /docker-entrypoint-initdb.d/seed.py 2>&1
echo "=== Seeding finished successfully ==="