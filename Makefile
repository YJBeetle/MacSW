SHELL := /bin/bash
.DEFAULT_GOAL := app

.PHONY: app archive bootstrap ci fetch fetch-mono fetch-runtime launcher \
	fetch-seven-zip fetch-stdole fetch-swcli-runtime fetch-wine-source icon package \
	swcli-helper test verify winemac

launcher:
	./macos/Bootstrap/build_bootstrap.sh

bootstrap: launcher

test:
	./scripts/test_bootstrap.sh

fetch:
	./scripts/fetch_dependencies.sh all

fetch-runtime:
	./scripts/fetch_dependencies.sh runtime

fetch-wine-source:
	./scripts/fetch_dependencies.sh wine-source

fetch-mono:
	./scripts/fetch_dependencies.sh mono

fetch-stdole:
	./scripts/fetch_dependencies.sh stdole

fetch-seven-zip:
	./scripts/fetch_dependencies.sh seven-zip

fetch-swcli-runtime:
	./scripts/fetch_dependencies.sh swcli-runtime

swcli-helper:
	./scripts/build_swcli_path_helper.sh

icon:
	mkdir -p build/resources
	./scripts/generate_app_icon.swift build/resources

winemac: fetch-wine-source
	./scripts/build_winemac.sh

package: launcher swcli-helper winemac icon fetch-runtime fetch-mono fetch-stdole fetch-seven-zip fetch-swcli-runtime
	./scripts/package_app.sh

verify:
	./scripts/verify_app.sh

app: package
	./scripts/verify_app.sh

archive: app
	mkdir -p build/archive
	source scripts/lib/config.sh; \
		rm -f -- "build/archive/MacSW-$${APP_VERSION}-macOS.zip"; \
		ditto -c -k --sequesterRsrc --keepParent "build/app/MacSW.app" \
		"build/archive/MacSW-$${APP_VERSION}-macOS.zip"

ci: test archive
