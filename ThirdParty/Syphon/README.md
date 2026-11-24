# Syphon dependency

ProMap embeds the Syphon Framework so Syphon features work without a separate install. The framework is built from the official Syphon source at commit `f4761677a45b8034a3c2069ec0f3d2553da81fba` and includes both `x86_64` and `arm64` slices. Its minimum macOS version is 11.0; ProMap itself supports macOS 12 and later.

The upstream source and Xcode project are preserved in [`Source/`](Source/). The BSD-style license is included as [`LICENSE.txt`](LICENSE.txt). The checked-in `Syphon.framework` is the matching universal Release build used by ProMap. To rebuild it after changing the upstream source, run:

```sh
xcodebuild \
  -project ThirdParty/Syphon/Source/Syphon.xcodeproj \
  -scheme Syphon \
  -configuration Release \
  -destination 'platform=macOS' \
  -derivedDataPath /tmp/ProMap-Syphon-Build \
  ARCHS='x86_64 arm64' ONLY_ACTIVE_ARCH=NO CODE_SIGNING_ALLOWED=NO build
```

Replace `Syphon.framework` with the resulting `Build/Products/Release/Syphon.framework`. Keep the upstream license and copyright notices with source and binary distributions.
