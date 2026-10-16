import Flutter
import UIKit

/// Remplace ios/Runner/AppDelegate.swift d'origine (qui était vide).
/// Enregistre tous les channels natifs iOS avec la même API que l'Android.
@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    // Registrar dédié pour nos channels (messenger + textures).
    let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "IosPort")
    let messenger = registrar.messenger()
    IosPortMessenger.shared.messenger = messenger
    IosVideoManager.shared.attachRegistry(registrar.textures())
    IosPort.shared.setup(messenger: messenger)
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
  }
}
