APP := agxntz
BUILD := .build/release/$(APP)
BUNDLE := dist/$(APP).app

.PHONY: build app run clean

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

clean:
	rm -rf .build dist
