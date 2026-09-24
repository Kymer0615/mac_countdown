#!/bin/sh
# Native UI/intent checks; requires an active macOS graphical session.
set -eu
cd "$(dirname "$0")/.."
mkdir -p .build/checks
sed '/^@main/,$d' Sources/CountdownMenuBar/CountdownApp.swift > .build/checks/AppWithoutMain.swift
DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}" xcrun swiftc -module-cache-path .build/checks/modulecache \
  Sources/CountdownMenuBar/CountdownEvent.swift Sources/CountdownMenuBar/CountdownFormat.swift \
  Sources/CountdownMenuBar/EventTimeZone.swift Sources/CountdownMenuBar/MoonIcon.swift \
  Sources/CountdownMenuBar/MoonProgress.swift Sources/CountdownMenuBar/WidgetEventData.swift \
  Sources/CountdownMenuBar/Settings.swift Sources/CountdownMenuBar/ManagementWindow.swift \
  Sources/CountdownMenuBar/CalendarIntegration.swift Sources/CountdownMenuBar/CountdownIntents.swift \
  Sources/CountdownMenuBar/EventEditor.swift .build/checks/AppWithoutMain.swift \
  Tests/AppFeatureChecks.swift -o .build/checks/AppFeatureChecks
.build/checks/AppFeatureChecks
