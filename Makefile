run:
	./scripts/run_dev_app.sh

release: release-notarize
	mv .build/release/Typeflux.dmg ~/Downloads/
	mv .build/release/Typeflux.zip ~/Downloads/

dev:
	TYPEFLUX_API_URL=http://127.0.0.1:8080 ./scripts/run_dev_attached.sh

build:
	swift build

test:
	swift test

coverage:
	./scripts/coverage.sh

dmg:
	./scripts/build_dmg.sh

release-notarize:
	TYPEFLUX_CODESIGN_IDENTITY="Developer ID Application: YIYAO  GUAN (N95437SZ2A)" TYPEFLUX_PROVISIONING_PROFILE="/Users/mylxsw/ResilioSync/ResilioSync/AI/Typeflux/typefluxprofile.provisionprofile" TYPEFLUX_NOTARY_PROFILE="typeflux-profile" ./scripts/release_notarize.sh

format:
	./scripts/format.sh

.PHONY: run dev build test coverage release dmg release-notarize format
