run:
	./scripts/run_dev_app.sh

dev:
	./scripts/run_dev_attached.sh

build:
	swift build

test:
	swift test

coverage:
	./scripts/coverage.sh

format:
	./scripts/format.sh

.PHONY: run dev build test coverage format
