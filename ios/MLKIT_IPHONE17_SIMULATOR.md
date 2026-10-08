# ML Kit on iPhone 17 Pro (iOS 26) Simulator

Google ML Kit iOS pods ship **x86_64 simulator only** (no `arm64` simulator slice).  
iOS 26+ simulators on Apple Silicon are **arm64-only**, so the default **iPhone 17 Pro** simulator cannot link ML Kit.

## What works today

| Target | ML Kit |
|--------|--------|
| Physical iPhone | Yes |
| iPhone 17 Pro simulator (default, arm64) | No — upstream limitation |
| iPhone 17 Pro simulator (**Rosetta / universal** runtime) | Yes |

## One-time setup (Rosetta + universal iOS 26)

1. Install Rosetta (if prompted or missing):
   ```bash
   softwareupdate --install-rosetta --agree-to-license
   ```

2. **Delete** the current iOS 26 simulator runtime (required):
   - **Xcode → Settings → Components**
   - Find **iOS 26.5** (or your iOS 26.x row) → click the **ⓘ** or trash/delete control → remove it
   - Quit Simulator and Xcode after delete

3. Confirm it is gone (should **not** list iOS 26.5):
   ```bash
   xcrun simctl list runtimes | grep -i "26"
   xcrun simctl delete unavailable
   ```

4. Download the **universal** runtime (large ~10 GB; do not close Terminal):
   ```bash
   xcodebuild -downloadPlatform iOS -architectureVariant universal
   ```
   If you still see `No needed downloadables found for universal` **but** `simctl list runtimes | grep 26` is empty, Xcode still has an **arm64Only** stub on disk. Quit Xcode and Simulator, then:

   ```bash
   sudo rm -rf /Library/Developer/CoreSimulator/Volumes/iOS_23F77_1
   sudo rm -rf /Library/Developer/CoreSimulator/Caches/dyld/*/inc/com.apple.CoreSimulator.SimRuntime.iOS-26-5.*
   xcodebuild -downloadPlatform iOS -architectureVariant universal
   ```

   You can confirm the stub with:

   ```bash
   xcodebuild -downloadAllPlatforms -architectureVariant universal 2>&1 | head -5
   ```

   If it prints `iOS is already downloaded as arm64Only`, the cleanup above is still required.

   Only use `xcodebuild -downloadPlatform iOS ...` (not `downloadAllPlatforms`) so you do not pull watchOS/tvOS by accident.

5. Restart Xcode. Check destinations — you should see **iPhone 17 Pro** with `arch:x86_64` (and/or **Rosetta** in the name):
   ```bash
   flutter devices
   cd ios && xcodebuild -workspace Runner.xcworkspace -scheme Runner -showdestinations | grep "17 Pro"
   ```

6. Run on the **x86_64** iPhone 17 Pro simulator (not the arm64-only one):
   ```bash
   flutter run -d <iphone-17-pro-x86_64-id>
   ```

Until Google publishes ML Kit with `ios-arm64-simulator` slices, **native arm64 iPhone 17 Pro simulators cannot run this app** with `google_mlkit_face_detection` in `pubspec.yaml`.

## Physical device (recommended for face scan)

```bash
flutter run -d 00008150-0011454102C1401C
```

Use USB for faster installs; wireless debug on iOS 26 is slower.
