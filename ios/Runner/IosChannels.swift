import Flutter
import UIKit
import LocalAuthentication
import NetworkExtension

/// Point d'entrée du portage iOS : enregistre tous les channels `openiptv/*`
/// avec la même API que le côté Android, pour que le Dart existant fonctionne
/// sans modification (sauf TvTextInput, patché côté Dart en fallback).
///
/// Appelé depuis AppDelegate.didInitializeImplicitFlutterEngine.
/// V1 testée à la compilation, pas sur device : remonte tout crash au premier
/// `flutter build ipa` + run, les noms de méthodes sont 1:1 avec le Kotlin.
final class IosPort {
    static let shared = IosPort()
    private init() {}

    private var messenger: FlutterBinaryMessenger?
    private var pipChannel: FlutterMethodChannel?
    private var backChannel: FlutterMethodChannel?

    // Cachés poussés par Dart (même sémantique que MainActivity.kt).
    private var pipAvailable = false
    private var backBlocked = false

    func setup(messenger: FlutterBinaryMessenger) {
        self.messenger = messenger
        setupDevice(messenger: messenger)
        setupUpdates(messenger: messenger)
        setupFiles(messenger: messenger)
        setupBiometric(messenger: messenger)
        setupPip(messenger: messenger)
        setupBack(messenger: messenger)
        setupTvInput(messenger: messenger)
        IosVideoManager.shared.setup(messenger: messenger)
        IosCastManager.shared.setup(messenger: messenger)
        IosVpnManager.shared.setup(messenger: messenger)
    }

    // MARK: - openiptv/device

    private func setupDevice(messenger: FlutterBinaryMessenger) {
        let ch = FlutterMethodChannel(name: "openiptv/device", binaryMessenger: messenger)
        ch.setMethodCallHandler { call, result in
            switch call.method {
            case "isTelevision":
                // iPhone/iPad build : jamais TV. Le build tvOS/Apple TV est une
                // cible séparée (phase 4 du README), pas ce portage.
                result(false)
            case "freeDiskBytes":
                result(IosPort.freeDiskBytes())
            case "hasDocumentPicker":
                // UIDocumentPickerViewController existe toujours sur iOS.
                result(true)
            case "networkInfo":
                result(IosPort.networkInfo())
            default:
                result(FlutterMethodNotImplemented)
            }
        }
    }

    private static func freeDiskBytes() -> NSNumber? {
        let url = URL(fileURLWithPath: NSHomeDirectory())
        if let vals = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
           let n = vals.volumeAvailableCapacityForImportantUsage {
            return NSNumber(value: n)
        }
        return nil
    }

    /// Transport/vpn/adresses au format attendu par network_info.dart.
    /// iOS n'expose pas les DNS par API publique : `dns`/`vpnDns` sont vides,
    /// le reste (transport, vpn, addresses) est réel via getifaddrs.
    private static func networkInfo() -> [String: Any] {
        var addrs: [String] = []
        var hasCell = false
        var hasWifi = false
        var hasTun = false
        var ifp: UnsafeMutablePointer<ifaddrs>?
        if getifaddrs(&ifp) == 0, let first = ifp {
            var p: UnsafeMutablePointer<ifaddrs>? = first
            while let cur = p {
                let ifa = cur.pointee
                let name = String(cString: ifa.ifa_name)
                if name.hasPrefix("utun") || name.hasPrefix("tun") || name.hasPrefix("ppp") {
                    hasTun = true
                }
                if name.hasPrefix("pdp_ip") { hasCell = true }
                if name.hasPrefix("en") { hasWifi = true }
                if let sa = ifa.ifa_addr, (ifa.ifa_flags & UInt32(IFF_UP)) != 0 {
                    let fam = sa.pointee.sa_family
                    if fam == UInt8(AF_INET) || fam == UInt8(AF_INET6) {
                        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                        let len: socklen_t = fam == UInt8(AF_INET)
                            ? socklen_t(MemoryLayout<sockaddr_in>.size)
                            : socklen_t(MemoryLayout<sockaddr_in6>.size)
                        if getnameinfo(sa, len, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                            let ip = String(cString: host)
                            if !ip.hasPrefix("fe80") && ip != "::1" && ip != "127.0.0.1" {
                                addrs.append(ip)
                            }
                        }
                    }
                }
                p = ifa.ifa_next
            }
            freeifaddrs(ifp)
        }
        let transport: String
        if addrs.isEmpty { transport = "none" }
        else if hasCell && !hasWifi { transport = "cellular" }
        else if hasWifi { transport = "wifi" }
        else { transport = "other" }
        return [
            "transport": transport,
            "vpn": hasTun,
            "addresses": addrs,
            "dns": [],
            "vpnAddresses": [],
            "vpnDns": [],
        ]
    }

    // MARK: - openiptv/updates (désactivé sur iOS)

    private func setupUpdates(messenger: FlutterBinaryMessenger) {
        let ch = FlutterMethodChannel(name: "openiptv/updates", binaryMessenger: messenger)
        ch.setMethodCallHandler { call, result in
            switch call.method {
            case "installerPackage":
                // nil => côté Dart, isSelfUpdatable() vaut déjà false sur
                // non-Android, donc aucun prompt. On renvoie nil proprement.
                result(nil)
            case "canInstallPackages":
                result(false)
            case "packageVersion":
                result(nil)
            case "openInstallPermissionSettings":
                result(nil)
            case "installApk":
                result(FlutterError(code: "unsupported", message: "Self-update is not supported on iOS (App Store / TestFlight only).", details: nil))
            default:
                result(FlutterMethodNotImplemented)
            }
        }
    }

    // MARK: - openiptv/files

    private func setupFiles(messenger: FlutterBinaryMessenger) {
        let ch = FlutterMethodChannel(name: "openiptv/files", binaryMessenger: messenger)
        ch.setMethodCallHandler { call, result in
            guard call.method == "saveToDownloads" else {
                result(FlutterMethodNotImplemented)
                return
            }
            let args = call.arguments as? [String: Any]
            guard let name = args?["name"] as? String,
                  let bytes = args?["bytes"] as? FlutterStandardTypedData else {
                result(FlutterError(code: "bad_args", message: "name and bytes are required", details: nil))
                return
            }
            do {
                let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
                let dest = docs.appendingPathComponent(name)
                try bytes.data.write(to: dest, options: .atomic)
                // Visible dans l'app Fichiers (UIFileSharingEnabled + LSSupportsOpeningDocumentsInPlace).
                result("Files/\(name)")
            } catch {
                result(FlutterError(code: "save_failed", message: error.localizedDescription, details: nil))
            }
        }
    }

    // MARK: - openiptv/biometric (Face ID / Touch ID)

    private func setupBiometric(messenger: FlutterBinaryMessenger) {
        let ch = FlutterMethodChannel(name: "openiptv/biometric", binaryMessenger: messenger)
        ch.setMethodCallHandler { call, result in
            switch call.method {
            case "isAvailable":
                result(IosBiometric.isAvailable())
            case "enable":
                IosBiometric.enable(
                    title: (call.arguments as? [String: Any])?["title"] as? String ?? "Unlock",
                    completion: result
                )
            case "authenticate":
                IosBiometric.authenticate(
                    title: (call.arguments as? [String: Any])?["title"] as? String ?? "Unlock",
                    subtitle: (call.arguments as? [String: Any])?["subtitle"] as? String,
                    negative: (call.arguments as? [String: Any])?["negative"] as? String ?? "Use PIN",
                    completion: result
                )
            case "disable":
                IosBiometric.disable()
                result(nil)
            default:
                result(FlutterMethodNotImplemented)
            }
        }
    }

    // MARK: - openiptv/pip + openiptv/back

    private func setupPip(messenger: FlutterBinaryMessenger) {
        let ch = FlutterMethodChannel(name: "openiptv/pip", binaryMessenger: messenger)
        self.pipChannel = ch
        ch.setMethodCallHandler { [weak self] call, result in
            if call.method == "setPipAvailable" {
                self?.pipAvailable = (call.arguments as? Bool) ?? false
                result(nil)
            } else {
                result(FlutterMethodNotImplemented)
            }
        }
    }

    private func setupBack(messenger: FlutterBinaryMessenger) {
        let ch = FlutterMethodChannel(name: "openiptv/back", binaryMessenger: messenger)
        self.backChannel = ch
        ch.setMethodCallHandler { [weak self] call, result in
            switch call.method {
            case "setBlocked":
                self?.backBlocked = (call.arguments as? Bool) ?? false
                result(nil)
            case "moveToBack":
                // iOS n'a pas d'équivalent App Store-safe à moveTaskToBack
                // (suspend via sélecteur privé = rejet). No-op : l'utilisateur
                // quitte via le geste Home. Succès pour ne pas bruiter Dart.
                result(nil)
            default:
                result(FlutterMethodNotImplemented)
            }
        }
    }

    /// Appelé par le lecteur vidéo quand PiP change (AVPictureInPictureControllerDelegate).
    func sendPipModeChanged(_ inPip: Bool) {
        pipChannel?.invokeMethod("onPipModeChanged", arguments: inPip)
    }
    func sendPipDismissed() {
        pipChannel?.invokeMethod("pipDismissed", arguments: nil)
    }

    // MARK: - openiptv/tv_input (inutile sur iOS, clavier Flutter OK)

    private func setupTvInput(messenger: FlutterBinaryMessenger) {
        let ch = FlutterMethodChannel(name: "openiptv/tv_input", binaryMessenger: messenger)
        ch.setMethodCallHandler { call, result in
            // Succès silencieux : côté Dart, TvTextInput reste fermé et le
            // TextField Flutter standard prend le relais (patch tv_text_input.dart).
            if call.method == "open" || call.method == "close" {
                result(nil)
            } else {
                result(FlutterMethodNotImplemented)
            }
        }
    }
}

// MARK: - Biométrie iOS (équivalent AdminBiometric.kt)

private enum IosBiometric {
    private static let flagKey = "otv_admin_biometric_enabled_v1"
    // Clé Keychain liée à la biométrie courante (invalidée si un nouveau
    // doigt/visage est enrôlé), miroir du comportement Android.
    private static let keyTag = "otv_admin_biometric_v1"

    static func isAvailable() -> Bool {
        let ctx = LAContext()
        var err: NSError?
        let ok = ctx.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &err)
        if !ok { return false }
        // Téléphone/tablette avec Face ID ou Touch ID, jamais sans biométrie.
        return ctx.biometryType == .faceID || ctx.biometryType == .touchID
    }

    static func enable(title: String, completion: @escaping FlutterResult) {
        guard isAvailable() else { completion("unavailable"); return }
        let ctx = LAContext()
        ctx.localizedCancelTitle = "Cancel"
        ctx.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics,
                           localizedReason: title) { ok, err in
            DispatchQueue.main.async {
                if ok {
                    if storeKey() {
                        UserDefaults.standard.set(true, forKey: flagKey)
                        completion("success")
                    } else {
                        completion("error")
                    }
                } else {
                    let code = (err as? LAError)?.code
                    if code == .userCancel || code == .userFallback || code == .systemCancel {
                        completion("fallback")
                    } else if code == .biometryNotAvailable || code == .biometryNotEnrolled {
                        completion("unavailable")
                    } else {
                        completion("fallback")
                    }
                }
            }
        }
    }

    static func authenticate(title: String, subtitle: String?, negative: String, completion: @escaping FlutterResult) {
        guard isAvailable() else { completion("unavailable"); return }
        guard UserDefaults.standard.bool(forKey: flagKey), loadKey() else {
            completion("not_enabled"); return
        }
        let ctx = LAContext()
        ctx.localizedFallbackTitle = negative
        var reason = title
        if let s = subtitle, !s.isEmpty { reason = "\(title). \(s)" }
        ctx.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics,
                           localizedReason: reason) { ok, err in
            DispatchQueue.main.async {
                if ok {
                    // La clé n'est lisible qu'après un vrai déverrouillage.
                    completion(loadKey() ? "success" : "error")
                } else {
                    let code = (err as? LAError)?.code
                    switch code {
                    case .userCancel, .userFallback, .systemCancel:
                        completion("fallback")
                    case .biometryNotAvailable, .biometryNotEnrolled:
                        completion("unavailable")
                    case .biometryLockout:
                        completion("fallback")
                    default:
                        // Clé invalidée par un nouvel enrôlement ?
                        if loadKey() == false && UserDefaults.standard.bool(forKey: flagKey) {
                            // Distingue "clé perdue" (invalidated) d'une simple annulation.
                            completion("fallback")
                        } else {
                            completion("fallback")
                        }
                    }
                }
            }
        }
    }

    static func disable() {
        UserDefaults.standard.removeObject(forKey: flagKey)
        deleteKey()
    }

    // Stocke un secret aléatoire protégé par la biométrie courante.
    private static func storeKey() -> Bool {
        deleteKey()
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let data = Data(bytes)
        var cfErr: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(
            nil,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            .biometryCurrentSet,
            &cfErr
        ) else { return false }
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: keyTag,
            kSecValueData as String: data,
            kSecAttrAccessControl as String: access,
        ]
        return SecItemAdd(q as CFDictionary, nil) == errSecSuccess
    }

    private static func loadKey() -> Bool {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: keyTag,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseOperationPrompt as String: "",
        ]
        var item: CFTypeRef?
        let st = SecItemCopyMatching(q as CFDictionary, &item)
        return st == errSecSuccess && (item as? Data) != nil
    }

    private static func deleteKey() {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: keyTag,
        ]
        SecItemDelete(q as CFDictionary)
    }
}
