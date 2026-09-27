APP := agxntz
BUILD := .build/release/$(APP)
BUNDLE := dist/$(APP).app

.PHONY: build app run release clean

build:
	swift build -c release

# Dev bundle: embeds Sparkle and ad-hoc signs (updater disabled for dev builds).
app:
	NO_ZIP=1 ./scripts/package.sh

run: app
	open $(BUNDLE)

# Distributable build: signs + notarizes when signing env vars are set,
# otherwise produces an ad-hoc-signed zip. See scripts/package.sh.
# Usage: make release VERSION=0.1.0
release:
	VERSION=$(VERSION) ./scripts/package.sh

clean:
	rm -rf .build dist
