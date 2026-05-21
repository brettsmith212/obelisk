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

.PHONY: all gen build run install launch boot clean test refresh-lsp lsp-config seed-vault

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

# Copy an Obsidian vault into the booted simulator's Obelisk app container so
# Phase B's SampleVaultProvider can use it. The copy lives only in the sim's
# private data directory — nothing enters the repo. Existing contents at
# Documents/SampleVault/ are replaced.
#
# Usage:
#   make seed-vault VAULT=/Users/you/Documents/MyVault
#   make seed-vault VAULT=~/Obsidian/Personal
seed-vault: install
ifndef VAULT
	$(error VAULT=/path/to/your/vault is required)
endif
	@SRC=$$(eval echo "$(VAULT)"); \
	  if [ ! -d "$$SRC" ]; then echo "✘ VAULT not found: $$SRC"; exit 1; fi; \
	  APP_CONTAINER=$$(xcrun simctl get_app_container booted com.brettsmith.Obelisk data 2>/dev/null) || \
	    { echo "✘ Obelisk isn't installed in the booted sim. 'make install' first."; exit 1; }; \
	  DEST="$$APP_CONTAINER/Documents/SampleVault"; \
	  echo "▶ Seeding $$SRC → $$DEST"; \
	  rm -rf "$$DEST"; \
	  mkdir -p "$$DEST"; \
	  rsync -a --exclude='.git' --exclude='.DS_Store' --exclude='.trash' \
	        "$$SRC/" "$$DEST/"; \
	  COUNT=$$(find "$$DEST" -name '*.md' | wc -l | tr -d ' '); \
	  HAS_DOTOBSIDIAN=$$([ -d "$$DEST/.obsidian" ] && echo "yes" || echo "no"); \
	  echo "✔ Seeded $$COUNT markdown notes (.obsidian present: $$HAS_DOTOBSIDIAN)."

clean:
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) clean || true
	rm -rf $(DD) .compile .bsp
