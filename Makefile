APP := agxntz
BUILD := .build/release/$(APP)
BUNDLE := dist/$(APP).app

.PHONY: build app run release clean

build:
	swift build -c release

app: build
	rm -rf $(BUNDLE)
	mkdir -p $(BUNDLE)/Contents/MacOS
	cp Support/Info.plist $(BUNDLE)/Contents/
	cp $(BUILD) $(BUNDLE)/Contents/MacOS/$(APP)
	codesign --force --sign - $(BUNDLE)
	@echo "Built $(BUNDLE)"

run: app
	open $(BUNDLE)

# Distributable build: signs + notarizes when signing env vars are set,
# otherwise produces an ad-hoc-signed zip. See scripts/package.sh.
# Usage: make release VERSION=0.1.0
release:
	VERSION=$(VERSION) ./scripts/package.sh

clean:
	rm -rf .build dist
