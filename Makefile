.PHONY: build test app package run clean check smoke

build:
	swift build

test:
	./scripts/test.sh

check:
	swift build -Xswiftc -warnings-as-errors
	./scripts/test.sh

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
