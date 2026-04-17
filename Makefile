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

format:
	./scripts/format.sh

.PHONY: run dev build test coverage release format
