#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p build/tests
# 测试用的配置、会话、灯、指令都放在临时目录（编译产物在 mac/build/tests），跑完删掉
export AIQUOTA_TEST_HOME="$(mktemp -d -t aiquota-test)"
trap 'rm -rf "$AIQUOTA_TEST_HOME"' EXIT
swiftc -swift-version 5 -parse-as-library -D AIQUOTA_TEST -target arm64-apple-macos13.0 -lsqlite3 \
    AIQuota.swift ProjectActions.swift Attention.swift Shelf.swift ShelfViews.swift ResetReminder.swift Relay.swift RelayViews.swift Prompts.swift PromptViews.swift Lights.swift Translate.swift ToolViews.swift Calm.swift Pet.swift Receipt.swift Watch.swift Roadmap.swift SessionSnapshot.swift AIPage.swift Piano.swift Setup.swift \
    tests/AIQuotaTests.swift tests/AttentionShelfTests.swift tests/ResetReminderTests.swift tests/RelayTests.swift \
    tests/PromptTests.swift tests/ToolTests.swift tests/CalmPetTests.swift tests/LyricsAutoTests.swift tests/SessionHookTests.swift tests/ReceiptTests.swift tests/WatchTests.swift tests/InterruptRateLimitTests.swift tests/RoadmapTests.swift tests/CodexRoadTests.swift tests/SessionSnapshotTests.swift tests/AIPageTests.swift tests/PianoTests.swift tests/SetupTests.swift -o build/tests/AIQuotaTests
build/tests/AIQuotaTests
# Chrome 歌词扩展：用系统自带的 jsc 按 manifest 分组加载脚本、走一遍后台（不用装 node）
/System/Library/Frameworks/JavaScriptCore.framework/Versions/A/Helpers/jsc tests/ChromeScriptsTest.js -- ../chrome
