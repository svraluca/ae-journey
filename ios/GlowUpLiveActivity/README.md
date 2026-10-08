# iOS Live Activity (Uber-style lock screen)

The Swift sources are ready. Add the Widget Extension once in Xcode:

1. Open `ios/Runner.xcworkspace`
2. **File → New → Target → Widget Extension**
3. Product name: `GlowUpLiveActivity`, uncheck "Include Configuration App Intent"
4. Delete the generated Swift file and add the files from this folder to the target
5. Set deployment target **iOS 16.1+** for the extension
6. Enable **App Groups** on Runner and the extension: `group.com.svapps.aestheticpass`
7. Build on a **physical iPhone** (Live Activities do not appear in Simulator)

Until the extension target is added, **iOS uses visible lock-screen notifications** from Dart (set `GLOW_UP_IOS_LIVE_ACTIVITY=true` in `.env` after adding the extension). Live Activities do not appear in the Simulator.
