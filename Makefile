.PHONY: build app install run test clean uninstall-hooks status

APP := build/NotchPal.app

## Compile the package.
build:
	swift build -c release

## Assemble build/NotchPal.app.
app:
	./Scripts/build-app.sh

## Copy the app to /Applications and register the agent hooks.
install: app
	rm -rf /Applications/NotchPal.app
	cp -R $(APP) /Applications/NotchPal.app
	/Applications/NotchPal.app/Contents/MacOS/NotchPal --install-hooks
	open /Applications/NotchPal.app
	@echo "NotchPal is running. Open /hooks in Codex once to trust its hooks."

## Build and launch without installing.
run: app
	open $(APP)

test:
	swift test

## Show socket, reporter path, and hook state.
status:
	swift run NotchPal --status

## Remove NotchPal's hooks from Claude Code and Codex.
uninstall-hooks:
	swift run NotchPal --uninstall-hooks

clean:
	swift package clean
	rm -rf build
