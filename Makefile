APP_NAME     := NaughtScribe
BUILD_DIR    := build
APP_BUNDLE   := $(BUILD_DIR)/$(APP_NAME).app
INFO_PLIST   := Resources/Info.plist
ENTITLEMENTS := Resources/$(APP_NAME).entitlements
APP_ICON     := Resources/AppIcon.icns
INSTALL_DIR  := /Applications

# Extra flags passed to every `swift build`, e.g. `make SWIFT_FLAGS=--disable-sandbox`.
# Only needed when make itself runs inside another sandbox, where SwiftPM cannot
# start its own sandbox-exec for manifest evaluation.
SWIFT_FLAGS  ?=

# Architectures for `app`. Both slices give a universal binary. Override on the
# command line, e.g. `make ARCHS=` for a host-only build.
ARCHS        := --arch arm64 --arch x86_64

.DEFAULT_GOAL := default
.PHONY: default app run install clean

default: app

# Release build, then assemble and ad-hoc sign $(APP_BUNDLE).
app:
	swift build $(SWIFT_FLAGS) $(ARCHS) -c release
	@bin_dir="$$(swift build $(SWIFT_FLAGS) $(ARCHS) -c release --show-bin-path)"; \
	echo "Binary: $$bin_dir/$(APP_NAME)"; \
	rm -rf "$(APP_BUNDLE)"; \
	mkdir -p "$(APP_BUNDLE)/Contents/MacOS" "$(APP_BUNDLE)/Contents/Resources"; \
	cp "$$bin_dir/$(APP_NAME)" "$(APP_BUNDLE)/Contents/MacOS/$(APP_NAME)"; \
	cp "$(INFO_PLIST)" "$(APP_BUNDLE)/Contents/Info.plist"; \
	if [ -f "$(APP_ICON)" ]; then cp "$(APP_ICON)" "$(APP_BUNDLE)/Contents/Resources/"; fi; \
	codesign --force --deep --sign - --entitlements "$(ENTITLEMENTS)" "$(APP_BUNDLE)"

run: app
	open "$(APP_BUNDLE)"

install: app
	rm -rf "$(INSTALL_DIR)/$(APP_NAME).app"
	cp -R "$(APP_BUNDLE)" "$(INSTALL_DIR)/$(APP_NAME).app"

clean:
	rm -rf "$(BUILD_DIR)" .build
