import Flutter
import NetworkExtension
import Security

/// VPN intégré (Settings → Power User Tools), miroir de VpnController.kt.
/// API Dart identique : validate/connect/disconnect/status +
/// ovpnValidate/ovpnConnect/ovpnDisconnect/ovpnStatus.
///
/// Architecture iOS (imposée par Apple) :
/// - Ce fichier = côté app (UI + NETunnelProviderManager). Aucun pod requis.
/// - Le tunnel lui-même tourne dans une extension Packet Tunnel
///   (`ios/VpnTunnel/PacketTunnelProvider.swift`, target séparé) qui utilise
///   WireGuardKit (SPM) et OpenVPNAdapter (pod). Voir IOS_BUILD.md.
/// - Sans l'extension (premier build), validate() fonctionne (vérifie la
///   syntaxe localement) et connect() renvoie "error" proprement au lieu de
///   crasher : l'app reste utilisable, le VPN s'active quand l'extension
///   est ajoutée.
///
/// Identifiants à aligner avec Xcode :
/// - App Group : group.com.openiptv.app (Runner + VpnTunnel)
/// - Provider bundle id : com.openiptv.app.VpnTunnel
final class IosVpnManager: NSObject {
    static let shared = IosVpnManager()
    private override init() {}

    private let tunnelBundleId = "com.openiptv.app.VpnTunnel"
    private let appGroupId = "group.com.openiptv.app"

    func setup(messenger: FlutterBinaryMessenger) {
        let ch = FlutterMethodChannel(name: "openiptv/vpn", binaryMessenger: messenger)
        ch.setMethodCallHandler { [weak self] call, result in
            self?.handle(call: call, result: result)
        }
    }

    private func handle(call: FlutterMethodCall, result: @escaping FlutterResult) {
        let args = call.arguments as? [String: Any]
        switch call.method {
        case "validate":
            result(IosVpnManager.validateWireGuard(args?["config"] as? String ?? ""))
        case "connect":
            connect(config: args?["config"] as? String ?? "",
                    route: args?["route"] as? String ?? "app",
                    result: result)
        case "disconnect":
            setTunnelConfig(nil)
            stopTunnel(result: result)
        case "status":
            tunnelStatus(kind: "wireguard", result: result)
        case "ovpnValidate":
            result(IosVpnManager.validateOpenVpn(args?["config"] as? String ?? ""))
        case "ovpnConnect":
            connectOpenVpn(config: args?["config"] as? String ?? "",
                           user: args?["user"] as? String,
                           pass: args?["pass"] as? String,
                           route: args?["route"] as? String ?? "app",
                           result: result)
        case "ovpnDisconnect":
            setTunnelConfig(nil)
            stopTunnel(result: result)
        case "ovpnStatus":
            tunnelStatus(kind: "openvpn", result: result)
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    // MARK: Validation locale (sans tunnel)

    /// nil = OK, sinon courte raison (miroir du Kotlin).
    static func validateWireGuard(_ text: String) -> String? {
        let t = text.lowercased()
        guard t.contains("[interface]"), t.contains("privatekey"), t.contains("[peer]") else {
            return nil // le Dart a déjà fait looksLikeWireGuard ; ici on ne bloque pas
        }
        // Vérifie qu'une clé privée ressemble à du base64 44 chars.
        for line in text.components(separatedBy: .newlines) {
            let kv = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if kv.count == 2, kv[0].lowercased() == "privatekey" {
                let k = kv[1]
                if k.count < 40 || k.count > 48 { return "interface: invalid key" }
            }
        }
        return nil
    }

    /// "" = OK, "needs_login", "external_pki", ou raison.
    static func validateOpenVpn(_ text: String) -> String {
        let t = text.lowercased()
        guard t.contains("remote ") else { return "unreadable" }
        if t.contains("pkcs12") || t.contains("cryptoapicert") { return "external_pki" }
        if t.contains("auth-user-pass") { return "needs_login" }
        return ""
    }

    // MARK: Connexions (via l'extension, si présente)

    private func connect(config: String, route: String, result: @escaping FlutterResult) {
        // Stoppe d'abord l'OpenVPN éventuel (un seul VPN à la fois).
        setTunnelConfig(["kind": "wireguard", "config": applyRoute(to: config, route: route)])
        startTunnel(result: result)
    }

    private func connectOpenVpn(config: String, user: String?, pass: String?, route: String, result: @escaping FlutterResult) {
        var dict: [String: Any] = ["kind": "openvpn", "config": config, "route": route]
        if let u = user { dict["user"] = u }
        if let p = pass { dict["pass"] = p }
        setTunnelConfig(dict)
        startTunnel(result: result)
    }

    /// Applique le routage "app" vs "device" : sur iOS, le split-tunnel par
    /// app (IncludedApplications Android) n'existe pas en personal VPN.
    /// On l'émule côté extension : "app" = on-demand uniquement pour les
    /// domaines du provider (voir PacketTunnelProvider), "device" = full.
    /// Ici on tague juste la config ; le détail vit dans l'extension.
    private func applyRoute(to config: String, route: String) -> String {
        if route == "app" {
            return config + "\n# openiptv-route=app\n"
        }
        return config + "\n# openiptv-route=device\n"
    }

    private func appGroupDefaults() -> UserDefaults? {
        UserDefaults(suiteName: appGroupId)
    }

    private func setTunnelConfig(_ dict: [String: Any]?) {
        guard let d = appGroupDefaults() else { return }
        if let dict = dict {
            d.set(dict, forKey: "otv_tunnel_config")
        } else {
            d.removeObject(forKey: "otv_tunnel_config")
        }
        d.synchronize()
    }

    private func startTunnel(result: @escaping FlutterResult) {
        NETunnelProviderManager.loadAllFromPreferences { [weak self] managers, err in
            guard let self = self else { return }
            if let e = err {
                result("error")
                print("[OTV-vpn] load managers: \(e)")
                return
            }
            let mgr = managers?.first(where: {
                ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == self.tunnelBundleId
            }) ?? NETunnelProviderManager()
            let proto = NETunnelProviderProtocol()
            proto.providerBundleIdentifier = self.tunnelBundleId
            proto.serverAddress = "openiptv"
            mgr.protocolConfiguration = proto
            mgr.localizedDescription = "OpenIPTV"
            mgr.isEnabled = true
            mgr.saveToPreferences { saveErr in
                if let e = saveErr {
                    print("[OTV-vpn] save: \(e)")
                    result("error")
                    return
                }
                mgr.loadFromPreferences { _ in
                    do {
                        try mgr.connection.startVPNTunnel()
                        result("ok")
                    } catch {
                        print("[OTV-vpn] start: \(error)")
                        // Extension pas encore installée (target non créé) :
                        // erreur propre, pas de crash.
                        result("error")
                    }
                }
            }
        }
    }

    private func stopTunnel(result: @escaping FlutterResult) {
        NETunnelProviderManager.loadAllFromPreferences { managers, _ in
            managers?.forEach { $0.connection.stopVPNTunnel() }
            result("ok")
        }
    }

    private func tunnelStatus(kind: String, result: @escaping FlutterResult) {
        NETunnelProviderManager.loadAllFromPreferences { managers, _ in
            let mgr = managers?.first
            let st = mgr?.connection.status ?? .invalid
            let up = (st == .connected)
            if kind == "openvpn" {
                // rx/tx lus par l'extension dans l'App Group (0 si absente).
                let d = UserDefaults(suiteName: self.appGroupId)
                let rx = d?.integer(forKey: "otv_stats_rx") ?? 0
                let tx = d?.integer(forKey: "otv_stats_tx") ?? 0
                let state: String
                switch st {
                case .connected: state = "connected"
                case .connecting, .reasserting: state = "connecting"
                case .disconnecting, .invalid: state = "off"
                case .disconnected: state = "off"
                @unknown default: state = "off"
                }
                result(["state": state, "rx": rx, "tx": tx] as [String: Any])
            } else {
                if !up {
                    result(["up": false])
                    return
                }
                let d = UserDefaults(suiteName: self.appGroupId)
                result([
                    "up": true,
                    "rx": d?.integer(forKey: "otv_stats_rx") ?? 0,
                    "tx": d?.integer(forKey: "otv_stats_tx") ?? 0,
                    "handshake": d?.integer(forKey: "otv_handshake") ?? 0,
                ] as [String: Any])
            }
        }
    }
}
