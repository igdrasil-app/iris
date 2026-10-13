IDENTITY ?= Developer ID Application: Zhandos Ombayev (C8SWF8T25K)
BIN = .build/release/iris
APP = build/Iris.app
SIGN = codesign --force --options runtime --entitlements iris.entitlements --sign "$(IDENTITY)"

build:
	swift build -c release
	$(SIGN) --identifier app.igdrasil.iris $(BIN)
	codesign --verify --verbose=1 $(BIN)

# The binary inside a bundle at a stable path; macOS keys permission grants to that.
app: build
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources
	cp Info.plist $(APP)/Contents/
	cp $(BIN) $(APP)/Contents/MacOS/
	iconutil -c icns -o $(APP)/Contents/Resources/iris.icns Assets/iris.iconset
	$(SIGN) $(APP)
	codesign --verify --deep --strict --verbose=1 $(APP)

clean:
	rm -rf .build build

.PHONY: build app clean
