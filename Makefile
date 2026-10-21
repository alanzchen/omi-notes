.PHONY: setup server test test-backend test-ios ios ios-build pair doctor testflight

setup:
	brew list opus >/dev/null 2>&1 || brew install opus
	brew list ffmpeg >/dev/null 2>&1 || brew install ffmpeg
	command -v uv >/dev/null || brew install uv
	command -v xcodegen >/dev/null || brew install xcodegen
	cd backend && uv sync && uv run omi-notes fetch-models

server:
	cd backend && uv run omi-notes serve

pair:
	cd backend && uv run omi-notes pair

doctor:
	cd backend && uv run omi-notes doctor

test: test-backend test-ios

test-backend:
	cd backend && uv run pytest

test-ios:
	cd ios/Packages/OmiKit && swift test

ios:
	cd ios && xcodegen generate && open OmiNotes.xcodeproj

ios-build:
	cd ios && xcodegen generate && xcodebuild -project OmiNotes.xcodeproj -scheme OmiNotes \
		-destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build

# Needs ASC_KEY_ID / ASC_ISSUER_ID and an App Store Connect app record: see ios/Tools/testflight.sh
testflight:
	ios/Tools/testflight.sh
