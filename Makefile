-include local.env

APP_NAME := Tendon
CONFIGURATION ?= release
BUILD_DIR := .build/$(CONFIGURATION)
APP_DIR := dist/$(APP_NAME).app
CONTENTS_DIR := $(APP_DIR)/Contents
MACOS_DIR := $(CONTENTS_DIR)/MacOS
RESOURCES_DIR := $(CONTENTS_DIR)/Resources
CODESIGN_IDENTITY ?= -

.PHONY: build run package package-debug open cask release release-github

build:
	swift build -c $(CONFIGURATION)

run:
	swift run Tendon

package: build
	mkdir -p "$(MACOS_DIR)"
	mkdir -p "$(RESOURCES_DIR)"
	cp "$(BUILD_DIR)/$(APP_NAME)" "$(MACOS_DIR)/$(APP_NAME)"
	cp Resources/Info.plist "$(CONTENTS_DIR)/Info.plist"
	cp assets/tendon.png "$(RESOURCES_DIR)/tendon.png"
	./scripts/generate_app_icon.sh assets/tendon_black.png "$(RESOURCES_DIR)/$(APP_NAME).icns"
	chmod +x "$(MACOS_DIR)/$(APP_NAME)"
	codesign --force --deep --sign "$(CODESIGN_IDENTITY)" "$(APP_DIR)"
	touch "$(APP_DIR)"

package-debug:
	$(MAKE) package CONFIGURATION=debug

open: package
	open -n "$(APP_DIR)"

cask:
	./scripts/update_cask.sh "$(VERSION)"

release:
	CODESIGN_IDENTITY="$(CODESIGN_IDENTITY)" ./scripts/release.sh "$(VERSION)"

release-github:
	CODESIGN_IDENTITY="$(CODESIGN_IDENTITY)" ./scripts/release.sh "$(VERSION)" --github
