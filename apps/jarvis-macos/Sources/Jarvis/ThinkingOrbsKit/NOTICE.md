# ThinkingOrbsKit -- vendored

The `.swift` files in this directory (except this notice) are vendored
verbatim from [Jakubantalik/Libraries](https://github.com/Jakubantalik/Libraries),
`packages/thinking-orbs/ports/ios/ThinkingOrbsKit/Sources/ThinkingOrbsKit/`,
at commit `3862ffa`.

Vendored (not added as an SPM dependency) because that repository is a
monorepo with no root-level `Package.swift` and no release tag matching the
package's own `0.3.1` version -- `.package(url:from:)` cannot resolve it as
written. The package itself is small (9 files, ~1200 lines), MIT-licensed,
and has zero dependencies beyond Foundation/SwiftUI, so copying it in as
regular sources was the practical option.

`Snapshot.swift` (a headless-frame-capture test helper) and the package's
own test target were intentionally left out -- not needed at runtime.

To pick up an upstream update: diff these files against the same path at a
newer commit of that repo and re-copy.

## Usage in Jarvis

```swift
import SwiftUI // ThinkingOrb is a plain SwiftUI View, same module, no import needed here

ThinkingOrb(state: .solving, size: .px64, displaySize: 140)
```

The package renders in monochrome ink (light/dark theme), no custom tint.
Jarvis's usage wraps it in `Color.cyan.mask(...)` to keep the app's cyan
accent -- `.mask` uses only the rendered content's alpha channel, which is
independent of the ink colour, so this recolors every dot/line while
preserving each one's per-frame opacity exactly.

## License

MIT License

Copyright (c) 2026 Jakub Antalik

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
