run:
	./scripts/run_dev_app.sh

dev:
	./scripts/run_dev_attached.sh

test:
	swift test

coverage:
	./scripts/coverage.sh

.PHONY: run dev test coverage
