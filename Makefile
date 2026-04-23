RELEASE_VARIANT := $(if $(TYPEFLUX_RELEASE_VARIANT),$(TYPEFLUX_RELEASE_VARIANT),minimal)
PACKAGE_NAME = Typeflux$(if $(filter full,$(RELEASE_VARIANT)),-full,)

run:
	./scripts/run_dev_app.sh

release: release-notarize
	mv .build/release/$(PACKAGE_NAME).dmg ~/Downloads/
	mv .build/release/$(PACKAGE_NAME).zip ~/Downloads/

full-release:
	TYPEFLUX_RELEASE_VARIANT=full $(MAKE) release

dev:
	TYPEFLUX_API_URL=http://127.0.0.1:8080 ./scripts/run_dev_attached.sh

full-dev:
	TYPEFLUX_API_URL=http://127.0.0.1:8080 TYPEFLUX_DEV_VARIANT=full ./scripts/run_dev_attached.sh

build:
	swift build

test:
	swift test

coverage:
	./scripts/coverage.sh

dmg:
	./scripts/build_dmg.sh

release-notarize:
	./scripts/release_notarize.sh

format:
	./scripts/format.sh

.PHONY: run release full-release dev full-dev build test coverage dmg release-notarize format
