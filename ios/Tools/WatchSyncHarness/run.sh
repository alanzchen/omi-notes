#!/bin/sh
# Copies ../../OmiNotesWatch/WatchSync.swift into the checks with three adaptations only (host Observation import,
# UserDefaults.standard -> in-memory ReviewDefaults, Date() -> ReviewClock.now), then runs them.
set -eu
cd "$(dirname "$0")"
{ echo "import Observation"; sed -e 's/UserDefaults\.standard/ReviewDefaults.shared/g' -e 's/Date()/ReviewClock.now/g' ../../OmiNotesWatch/WatchSync.swift; } > Tests/Checks/WatchSync.swift
swift test --no-parallel "$@"  # the suites share the WatchConnectivity double and preferences
