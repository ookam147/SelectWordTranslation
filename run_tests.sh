#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")"
TEST_BINARY="$(mktemp /tmp/selectwordtranslation-tests.XXXXXX)"
trap 'rm -f "$TEST_BINARY"' EXIT

swiftc \
  -swift-version 6 \
  -parse-as-library \
  Sources/SelectWordTranslation/AppLanguage.swift \
  Sources/SelectWordTranslation/CredentialStore.swift \
  Sources/SelectWordTranslation/TranslationService.swift \
  Sources/SelectWordTranslation/ModelManager.swift \
  Tests/SelectWordTranslationTests/main.swift \
  -o "$TEST_BINARY"

"$TEST_BINARY"
