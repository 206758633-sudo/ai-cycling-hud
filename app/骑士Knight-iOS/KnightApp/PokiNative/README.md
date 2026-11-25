# Poki iOS automation

This development-only integration uses the in-process XCTest implementation from [Poki](https://github.com/JosssphZhou/poki/tree/fb324be5d38ec1f366a5f8fba7ebe8a1f4024271/native/ios-app/Poki/Native), copyright 2026 Joseph Zhou (周瑟夫) and contributors. The imported files are licensed under AGPL-3.0-only. See LICENSE.

Knight uses the existing platform authorization and developer image. The iPhone receives pickup requests from the Knight task API and runs the Meituan pickup flow inside the development build. The user completes payment in Meituan. The initial session readiness check verifies accessibility data without capturing a screenshot. The AX export includes the foreground bundle identifier from the same observation.
