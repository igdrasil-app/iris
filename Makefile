IDENTITY ?= Developer ID Application: Zhandos Ombayev (C8SWF8T25K)
BIN = .build/release/iris

build:
	swift build -c release
	codesign --force --options runtime --entitlements iris.entitlements --identifier app.igdrasil.iris --sign "$(IDENTITY)" $(BIN)
	codesign --verify --verbose=1 $(BIN)

clean:
	rm -rf .build

.PHONY: build clean
