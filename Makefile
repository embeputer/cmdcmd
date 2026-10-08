APP = cmdcmd.app
BIN = .build/release/cmdcmd
# Pass a Developer ID to sign for distribution: make dmg SIGN_ID="Developer ID Application: Name (TEAMID)"
ifdef SIGN_ID
CODESIGN_ARGS = --deep --options runtime --sign "$(SIGN_ID)"
else
CODESIGN_ARGS = --sign - --timestamp=none
endif

.PHONY: all bundle dmg run clean

all: bundle

bundle:
	swift build -c release
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources
	cp $(BIN) $(APP)/Contents/MacOS/cmdcmd
	cp Resources/Info.plist $(APP)/Contents/Info.plist
	@if [ -f Resources/AppIcon.icns ]; then cp Resources/AppIcon.icns $(APP)/Contents/Resources/; fi
	codesign --force $(CODESIGN_ARGS) $(APP) 2>/dev/null || true

DMG = cmdcmd.dmg

dmg: bundle
	rm -f $(DMG)
	create-dmg \
		--volname "cmdcmd" \
		--volicon Resources/AppIcon.icns \
		--window-pos 200 120 \
		--window-size 700 460 \
		--icon-size 128 \
		--icon "cmdcmd.app" 170 220 \
		--hide-extension "cmdcmd.app" \
		--app-drop-link 530 220 \
		"$(DMG)" \
		"$(APP)"
	@echo "wrote $(DMG)"

run: bundle
	open $(APP)

clean:
	rm -rf .build $(APP) $(DMG)
