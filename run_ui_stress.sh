#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")"
TEST_BINARY="$(mktemp /tmp/selectwordtranslation-ui-stress.XXXXXX)"
trap 'rm -f "$TEST_BINARY"' EXIT

swiftc \
  -swift-version 6 \
  -parse-as-library \
  Sources/SelectWordTranslation/AppLanguage.swift \
  Sources/SelectWordTranslation/SelectionTextProcessing.swift \
  Sources/SelectWordTranslation/TextSelectionManager.swift \
  Sources/SelectWordTranslation/TranslationService.swift \
  Sources/SelectWordTranslation/TranslationPopupView.swift \
  Sources/SelectWordTranslation/PopupWindowManager.swift \
  Tests/PopupStress/main.swift \
  -o "$TEST_BINARY"

"$TEST_BINARY"
