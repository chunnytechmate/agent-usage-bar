# AgentUsageBar — build + bundle as a real macOS .app
#
#   make run     build and run the binary directly (inherits your shell env)
#   make app     build dist/AgentUsageBar.app (ad-hoc signed)
#   make open    build the .app and open it
#   make clean

BINARY   := .build/release/AgentUsageBar
APPDIR   := dist/AgentUsageBar.app
CONTENTS := $(APPDIR)/Contents

.PHONY: build app open run clean

build:
	swift build -c release

$(BINARY): build

app: $(BINARY)
	mkdir -p $(CONTENTS)/MacOS
	cp $(BINARY) $(CONTENTS)/MacOS/AgentUsageBar
	@printf '%s\n' \
		'<?xml version="1.0" encoding="UTF-8"?>' \
		'<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' \
		'<plist version="1.0">' \
		'<dict>' \
		'    <key>CFBundleName</key><string>Agent Usage Bar</string>' \
		'    <key>CFBundleDisplayName</key><string>Agent Usage Bar</string>' \
		'    <key>CFBundleExecutable</key><string>AgentUsageBar</string>' \
		'    <key>CFBundleIdentifier</key><string>com.chunnytechmate.agent-usage-bar</string>' \
		'    <key>CFBundlePackageType</key><string>APPL</string>' \
		'    <key>CFBundleShortVersionString</key><string>0.1.0</string>' \
		'    <key>CFBundleVersion</key><string>1</string>' \
		'    <key>LSMinimumSystemVersion</key><string>14.0</string>' \
		'    <key>LSUIElement</key><true/>' \
		'    <key>NSHighResolutionCapable</key><true/>' \
		'    <key>NSPrincipalClass</key><string>NSApplication</string>' \
		'</dict>' \
		'</plist>' > $(CONTENTS)/Info.plist
	codesign --force --sign - $(APPDIR)
	@echo "Built $(APPDIR)"

open: app
	open $(APPDIR)

run: build
	$(BINARY)

clean:
	rm -rf .build dist
