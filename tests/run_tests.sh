#!/usr/bin/env bash
# ABOUTME: Runs all bats test files in the tests directory.
# ABOUTME: Exits with non-zero status if any test fails.

set -euo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "Running image-generation plugin tests..."
echo "========================================="

bats "${TESTS_DIR}"/*.bats
