#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"
mkdir -p build/module-cache
xcrun swiftc -swift-version 5 -module-cache-path build/module-cache Source/ImportSelection.swift Source/FileInformation.swift Source/RuleConfiguration.swift Source/RenameEngine.swift Source/SequentialRenameSession.swift Source/RenameTask.swift Source/NameValidation.swift Scripts/verify.swift -o build/verify
build/verify

xcrun swiftc -swift-version 5 -module-cache-path build/module-cache Source/FileInformation.swift Source/RuleConfiguration.swift Source/RenameEngine.swift Source/SequentialRenameSession.swift Scripts/verify-direct.swift -o build/verify-direct
build/verify-direct
