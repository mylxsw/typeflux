RELEASE_VARIANT := $(if $(TYPEFLUX_RELEASE_VARIANT),$(TYPEFLUX_RELEASE_VARIANT),minimal)
RELEASE_ARCH := $(if $(TYPEFLUX_RELEASE_ARCH),$(TYPEFLUX_RELEASE_ARCH),native)
PACKAGE_NAME = Typeflux$(if $(filter full,$(RELEASE_VARIANT)),-full,$(if $(filter app-only,$(RELEASE_VARIANT)),-app-only,))$(if $(filter arm64,$(RELEASE_ARCH)),-apple-silicon,$(if $(filter x86_64,$(RELEASE_ARCH)),-intel,$(if $(filter universal,$(RELEASE_ARCH)),-universal,)))

.PHONY: help
help: ## Display this help message
	@awk 'BEGIN {FS = ":.*?## "} /^[a-zA-Z_0-9-]+:.*?## / {printf "\033[36m%-30s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST) | sort

.DEFAULT_GOAL := help

.PHONY: ios-help ios-doctor ios-devices ios-build ios-install ios-run ios-preview ios-deploy ios-archive ios-test ios-test-scripts
ios-help: ## Show iOS commands and configuration variables
	python3 ./scripts/ios.py --help

ios-doctor: ## Check Xcode and iOS simulator prerequisites
	python3 ./scripts/ios.py doctor

ios-devices: ## List iOS simulators and connected physical devices
	python3 ./scripts/ios.py devices

ios-build: ## Build the iOS app for a simulator
	python3 ./scripts/ios.py build

ios-install: ## Build and install the iOS app on a simulator
	python3 ./scripts/ios.py install

ios-run: ## Build, install, and launch the iOS app on a simulator
	python3 ./scripts/ios.py run

ios-preview: ## Launch the iOS app with offline demo conversations
	python3 ./scripts/ios.py preview

ios-deploy: ## Build, install, and launch on a signed physical iOS device
	python3 ./scripts/ios.py deploy

ios-archive: ## Create a signed iOS Release archive locally (no upload)
	python3 ./scripts/ios.py archive

ios-test: ## Run iOS unit and UI tests with coverage
	./scripts/test_ios.sh

ios-test-scripts: ## Test the iOS build and deployment commands without devices
	python3 -m unittest discover -s scripts/tests -p 'test_ios_cli.py' -v

.PHONY: run
run: ## Run the development version of the app
	./scripts/run_dev_app.sh

.PHONY: release
release: ## Build and notarize a release (native architecture)
	./scripts/release_notarize.sh --move-to-downloads

.PHONY: intel-release
intel-release: ## Build and notarize an Intel release
	./scripts/release_intel.sh --move-to-downloads

.PHONY: release-continue
release-continue: ## Continue a previously interrupted release notarization
	./scripts/release_notarize.sh --continue --move-to-downloads

.PHONY: intel-release-continue
intel-release-continue: ## Continue a previously interrupted Intel release notarization
	./scripts/release_intel.sh --continue --move-to-downloads

.PHONY: full-release
full-release: ## Build a "full" variant release (with all models)
	TYPEFLUX_RELEASE_VARIANT=full $(MAKE) release

.PHONY: full-intel-release
full-intel-release: ## Build a "full" variant Intel release
	TYPEFLUX_RELEASE_VARIANT=full $(MAKE) intel-release

.PHONY: app-only-release
app-only-release: ## Build an "app-only" variant release
	TYPEFLUX_RELEASE_VARIANT=app-only $(MAKE) release

.PHONY: app-only-intel-release
app-only-intel-release: ## Build an "app-only" variant Intel release
	TYPEFLUX_RELEASE_VARIANT=app-only $(MAKE) intel-release

.PHONY: full-release-continue
full-release-continue: ## Continue a "full" variant release notarization
	TYPEFLUX_RELEASE_VARIANT=full $(MAKE) release-continue

.PHONY: dev
dev: ## Run dev version attached to terminal with local API URL
	TYPEFLUX_API_URL=http://127.0.0.1:8080 ./scripts/run_dev_attached.sh

.PHONY: full-dev
full-dev: ## Run "full" variant dev version attached to terminal
	TYPEFLUX_API_URL=http://127.0.0.1:8080 TYPEFLUX_DEV_VARIANT=full ./scripts/run_dev_attached.sh

.PHONY: build
build: ## Build the Swift package
	swift build

.PHONY: test
test: ## Run all unit tests
	swift test

.PHONY: coverage
coverage: ## Generate code coverage report
	./scripts/coverage.sh

.PHONY: dmg
dmg: ## Build a DMG disk image
	./scripts/build_dmg.sh

.PHONY: release-notarize
release-notarize: ## Run the release notarization script
	./scripts/release_notarize.sh

.PHONY: release-notarize-continue
release-notarize-continue: ## Continue the release notarization script
	./scripts/release_notarize.sh --continue

.PHONY: verify-release-artifacts
verify-release-artifacts: ## Verify the integrity of release artifacts
	./scripts/verify_release_artifacts.sh

.PHONY: format
format: ## Format code using SwiftFormat and SwiftLint
	./scripts/format.sh
