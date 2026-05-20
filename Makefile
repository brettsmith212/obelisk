# Build/install/launch/test driver for Obelisk on the iOS Simulator.
#
# Every build is piped through `xcode-build-server parse -av` so `.compile`
# stays fresh for sourcekit-lsp. Bundle id is resolved from the build
# settings at launch time.

SCHEME      := Obelisk
PROJECT     := Obelisk.xcodeproj
SIM_NAME    ?= iPhone 17 Pro
DESTINATION := platform=iOS Simulator,name=$(SIM_NAME)
DD          := build
APP         := $(DD)/Build/Products/Debug-iphonesimulator/$(SCHEME).app

.PHONY: all gen build run install launch boot clean test refresh-lsp lsp-config

all: run

gen:
	xcodegen generate

build:
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) \
	  -configuration Debug \
	  -destination "$(DESTINATION)" \
	  -derivedDataPath $(DD) \
	  build \
	  | xcode-build-server parse -av

boot:
	@xcrun simctl boot "$(SIM_NAME)" 2>/dev/null || true
	@xcrun simctl bootstatus booted -b
	@open -a Simulator

install: boot
	xcrun simctl install booted $(APP)

launch:
	@BUNDLE_ID=$$(xcodebuild -project $(PROJECT) -scheme $(SCHEME) \
	    -destination "$(DESTINATION)" -showBuildSettings 2>/dev/null \
	    | awk -F' = ' '/ PRODUCT_BUNDLE_IDENTIFIER /{print $$2; exit}'); \
	  echo "▶ Launching $$BUNDLE_ID"; \
	  xcrun simctl terminate booted $$BUNDLE_ID >/dev/null 2>&1 || true; \
	  xcrun simctl launch booted $$BUNDLE_ID

run: build install launch

test:
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) \
	  -destination "$(DESTINATION)" \
	  -derivedDataPath $(DD) \
	  test \
	  | xcode-build-server parse -av

# Write buildServer.json so sourcekit-lsp finds .compile via xcode-build-server.
# Requires at least one successful `make build` first.
lsp-config:
	xcode-build-server config -scheme $(SCHEME) -project $(PROJECT)

# Force a clean build through the parse pipe — use when `.compile` is empty
# or sourcekit symbols stop resolving.
refresh-lsp:
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) \
	  -configuration Debug \
	  -destination "$(DESTINATION)" \
	  -derivedDataPath $(DD) \
	  clean build \
	  | xcode-build-server parse -av

clean:
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) clean || true
	rm -rf $(DD) .compile .bsp
