.PHONY: build test app package run clean check smoke input-check settings-input-check switcher-input-check version release-test package-test release-plan release-prepare release

build:
	swift build

test:
	./scripts/test.sh

check:
	./scripts/check.sh

input-check:
	./scripts/check-status-input.sh

settings-input-check:
	./scripts/check-settings-input.sh

switcher-input-check:
	./scripts/check-switcher-input.sh

app:
	./scripts/build-app.sh

package:
	./scripts/package.sh

smoke: app
	./scripts/smoke-test.sh

run: app
	open "build/Menu Bar Dock.app"

clean:
	swift package clean

version:
	./scripts/version.sh

release-test:
	./scripts/test-release-metadata.sh
	./scripts/test-package-metadata.sh
	./scripts/test-release-publish.sh

package-test:
	./scripts/package.sh
	./scripts/check-package.sh

release-plan:
	./scripts/release.sh --dry-run

release-prepare:
	./scripts/release.sh --prepare

release:
	./scripts/release.sh
