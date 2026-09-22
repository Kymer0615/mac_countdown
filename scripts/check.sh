#!/bin/sh
set -eu

project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$project_dir"
mkdir -p .build/checks
swiftc -module-cache-path .build/checks/modulecache Sources/CountdownMenuBar/CountdownFormat.swift Tests/CountdownFormatChecks.swift -o .build/checks/CountdownFormatChecks
.build/checks/CountdownFormatChecks
