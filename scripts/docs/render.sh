#!/bin/sh
# Render native views with disposable sample data; requires a macOS GUI session.
set -eu
cd "$(dirname "$0")/../.."
mkdir -p .build/docs docs/images
sed '/^@main/,$d' Sources/CountdownMenuBar/CountdownApp.swift > .build/docs/App.swift
sed '/^@main/,$d' Widgets/CountdownEventsWidget.swift > .build/docs/Widget.swift
swiftc -module-cache-path .build/docs/modulecache \
  Sources/CountdownMenuBar/CountdownEvent.swift Sources/CountdownMenuBar/CountdownFormat.swift \
  Sources/CountdownMenuBar/EventTimeZone.swift Sources/CountdownMenuBar/MoonIcon.swift \
  Sources/CountdownMenuBar/MoonProgress.swift Sources/CountdownMenuBar/WidgetEventData.swift \
  Sources/CountdownMenuBar/EventEditor.swift .build/docs/App.swift .build/docs/Widget.swift \
  scripts/docs/Render.swift scripts/docs/Animate.swift -o .build/docs/CountdownDocs
.build/docs/CountdownDocs
