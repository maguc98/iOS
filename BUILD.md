# Build and signing

1. Open `POP CAM.xcodeproj` in Xcode.
2. Select the `POP CAM` scheme and an iPhone simulator or connected iPhone.
3. Build and run from Xcode.

GitHub Actions runs on macOS and packages an unsigned IPA artifact. The IPA is intentionally unsigned; install it only after signing it with a certificate and provisioning profile you control.

The camera preview, flash, autofocus behavior, and saved-photo permissions require validation on a physical iPhone.