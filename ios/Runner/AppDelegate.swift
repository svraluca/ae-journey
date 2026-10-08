import Flutter
import GoogleMaps
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    if let key = Bundle.main.object(forInfoDictionaryKey: "GMSApiKey") as? String, !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      GMSServices.provideAPIKey(key)
    }
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    let channel = FlutterMethodChannel(
      name: "glowpass/runtime",
      binaryMessenger: engineBridge.applicationRegistrar.messenger()
    )
    channel.setMethodCallHandler { call, result in
      if call.method == "loopbackReachesHost" {
        // Dart's Platform.environment does not receive SIMULATOR_* on iOS.
        // The native process does, and a physical phone does not.
        let env = ProcessInfo.processInfo.environment
        let simulator = env["SIMULATOR_UDID"] != nil
          || env["SIMULATOR_DEVICE_NAME"] != nil
        result(simulator)
      } else {
        result(FlutterMethodNotImplemented)
      }
    }
  }
}
