#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"
mkdir -p build/module-cache build/RenameKit.app/Contents/MacOS build/RenameKit.app/Contents/Resources
SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"
xcrun swiftc -swift-version 5 -O -target arm64-apple-macosx13.0 -sdk "$SDK_PATH" -module-cache-path build/module-cache Source/ImportSelection.swift Source/FileInformation.swift Source/RuleConfiguration.swift Source/RenameEngine.swift Source/SequentialRenameSession.swift Source/RenameTask.swift Source/NameValidation.swift Source/NameValidationSheet.swift Source/FilePreviewTable.swift Source/RenameTaskSheet.swift Source/RenameApp.swift -o build/RenameKit.app/Contents/MacOS/RenameKit
cp Info.plist build/RenameKit.app/Contents/Info.plist
if [[ -f AppIcon.icns ]]; then cp AppIcon.icns build/RenameKit.app/Contents/Resources/AppIcon.icns; fi
codesign --force --sign - build/RenameKit.app
printf 'Built: %s/build/RenameKit.app\n' "$PWD"
