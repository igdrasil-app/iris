IDENTITY ?= Developer ID Application: Zhandos Ombayev (C8SWF8T25K)
APP = build/Iris.app
SPARKLE = $(APP)/Contents/Frameworks/Sparkle.framework

# The bare .build/release/iris finds Sparkle beside it; the bundled one in Contents/Frameworks.
build:
	swift build -c release --arch arm64 --arch x86_64 -Xlinker -rpath -Xlinker @executable_path/../Frameworks

# The binary ships inside a bundle: macOS keys the permission grant to the bundle id
# and the signing identity, so the app can live anywhere and updates keep the grant.
# Notarization requires the secure timestamp. Nested code is signed first, without --deep.
app: build
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources $(APP)/Contents/Frameworks
	cp Info.plist $(APP)/Contents/
	cp .build/release/iris $(APP)/Contents/MacOS/
	iconutil -c icns -o $(APP)/Contents/Resources/iris.icns Assets/iris.iconset
	ditto .build/release/Sparkle.framework $(SPARKLE)
	# MIT asks for the notices in every copy; Sparkle's covers the code it vendors too.
	cp LICENSE $(APP)/Contents/Resources/LICENSE
	cp .build/artifacts/sparkle/Sparkle/LICENSE $(APP)/Contents/Resources/Sparkle-LICENSE
	# Sparkle's XPC services are for sandboxed apps.
	rm -rf $(SPARKLE)/XPCServices $(SPARKLE)/Versions/B/XPCServices
	codesign --force --options runtime --timestamp --sign "$(IDENTITY)" $(SPARKLE)/Versions/B/Autoupdate $(SPARKLE)/Versions/B/Updater.app
	codesign --force --options runtime --timestamp --sign "$(IDENTITY)" $(SPARKLE)
	codesign --force --options runtime --timestamp --entitlements iris.entitlements --sign "$(IDENTITY)" $(APP)
	codesign --verify --deep --strict --verbose=1 $(APP)

clean:
	rm -rf .build build

.PHONY: build app clean
