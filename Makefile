IDENTITY ?= Developer ID Application: Zhandos Ombayev (C8SWF8T25K)
APP = build/Iris.app

build:
	swift build -c release --arch arm64 --arch x86_64

# The binary ships inside a bundle: macOS keys the permission grant to the bundle id
# and the signing identity, so the app can live anywhere and updates keep the grant.
# Notarization requires the secure timestamp.
app: build
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources
	cp Info.plist $(APP)/Contents/
	cp .build/release/iris $(APP)/Contents/MacOS/
	iconutil -c icns -o $(APP)/Contents/Resources/iris.icns Assets/iris.iconset
	codesign --force --options runtime --timestamp --entitlements iris.entitlements --sign "$(IDENTITY)" $(APP)
	codesign --verify --deep --strict --verbose=1 $(APP)

clean:
	rm -rf .build build

.PHONY: build app clean
