run:
	./scripts/run_dev_app.sh

release: release-notarize
	mv .build/release/Typeflux.dmg ~/Downloads/
	mv .build/release/Typeflux.zip ~/Downloads/

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

.PHONY: run dev full-dev build test coverage release dmg release-notarize format
