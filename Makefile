run:
	./scripts/run_dev_app.sh

dev:
	./scripts/run_dev_attached.sh

test:
	swift test

coverage:
	./scripts/coverage.sh

format:
	./scripts/format.sh

.PHONY: run dev test coverage format
