run:
	./scripts/run_dev_app.sh

dev:
	TYPEFLUX_API_URL=http://127.0.0.1:8080 ./scripts/run_dev_attached.sh

build:
	swift build

test:
	swift test

coverage:
	./scripts/coverage.sh

release:
	./scripts/build_release.sh

dmg:
	./scripts/build_dmg.sh

release-notarize:
	./scripts/release_notarize.sh

format:
	./scripts/format.sh

.PHONY: run dev build test coverage release dmg release-notarize format
