import NetworkExtension
#if canImport(WireGuardKit)
import WireGuardKit
#endif
#if canImport(OpenVPNAdapter)
import OpenVPNAdapter
#endif

/// Extension Packet Tunnel (target `VpnTunnel`, bundle
/// `com.openiptv.app.VpnTunnel`). Lit la config posée par l'app dans l'App
/// Group `group.com.openiptv.app` sous `otv_tunnel_config` :
/// ["kind": "wireguard"|"openvpn", "config": String, "route": String,
///  "user": String?, "pass": String?]
///
/// Ajout des dépendances dans Xcode (voir IOS_BUILD.md) :
/// - WireGuard : SPM https://git.zx2c4.com/wireguard-apple (WireGuardKit)
/// - OpenVPN : pod OpenVPNAdapter (target VpnTunnel uniquement)
/// Le fichier compile avec ou sans elles (canImport) : sans, le tunnel
/// démarre puis s'arrête avec une erreur lisible dans les logs.
class PacketTunnelProvider: NEPacketTunnelProvider {

    private let appGroupId = "group.com.openiptv.app"

    override func startTunnel(options: [String: NSObject]?) async throws {
        let defaults = UserDefaults(suiteName: appGroupId)
        guard let cfg = defaults?.dictionary(forKey: "otv_tunnel_config"),
              let kind = cfg["kind"] as? String,
              let conf = cfg["config"] as? String else {
            throw NSError(domain: "OpenIPTV", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "No VPN config in App Group"])
        }
        if kind == "wireguard" {
            try await startWireGuard(config: conf, route: cfg["route"] as? String ?? "app")
        } else {
            try await startOpenVpn(config: conf,
                                   user: cfg["user"] as? String,
                                   pass: cfg["pass"] as? String,
                                   route: cfg["route"] as? String ?? "app")
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason) async {
        #if canImport(WireGuardKit)
        wgAdapter?.stop()
        wgAdapter = nil
        #endif
        #if canImport(OpenVPNAdapter)
        ovpnSession?.disconnect(error: nil)
        ovpnSession = nil
        #endif
    }

    override func handleAppMessage(_ messageData: Data) async -> Data? {
        // Stats demandées par l'app (optionnel) : répond vide.
        return nil
    }

    // MARK: WireGuard

    #if canImport(WireGuardKit)
    private var wgAdapter: WireGuardAdapter?
    #endif

    private func startWireGuard(config: String, route: String) async throws {
        #if canImport(WireGuardKit)
        let adapter = WireGuardAdapter(with: self) { _, msg in
            NSLog("[OTV-wg] \(msg)")
        }
        self.wgAdapter = adapter
        // goBackend déjà géré par WireGuardAdapter.
        let wgConfig: String
        if route == "app" {
            // iOS ne fait pas de split par app en personal VPN : on monte
            // le tunnel complet et l'UI explique que tout l'appareil passe
            // dedans (limite documentée, Android seul fait du per-app).
            wgConfig = config
        } else {
            wgConfig = config
        }
        try adapter.start(tunnelConfiguration: wgConfig)
        #else
        throw NSError(domain: "OpenIPTV", code: 2,
                      userInfo: [NSLocalizedDescriptionKey:
                        "WireGuardKit missing: add SPM wireguard-apple to the VpnTunnel target (see IOS_BUILD.md)."])
        #endif
    }

    // MARK: OpenVPN

    #if canImport(OpenVPNAdapter)
    import OpenVPNAdapter
    private var ovpnSession: OpenVPNAdapter?
    private var ovpnDelegate: OVPND?
    #endif

    private func startOpenVpn(config: String, user: String?, pass: String?, route: String) async throws {
        #if canImport(OpenVPNAdapter)
        let adapter = OpenVPNAdapter()
        let del = OVPND(provider: self, config: config, user: user, pass: pass)
        adapter.delegate = del
        self.ovpnSession = adapter
        self.ovpnDelegate = del
        // OpenVPNAdapter démarre via connect() ; le provider établit
        // l'interface via les callbacks du delegate (voir OVPND ci-dessous).
        let configData = config.data(using: .utf8)!
        var err: NSError?
        // Profil embarqué : OpenVPNAdapter lit la config + credentials.
        adapter.apply(configuration: OpenVPNConfiguration(
            fileContent: configData,
            settings: nil
        ))
        if let u = user, let p = pass {
            adapter.provide(credentials: OpenVPNCredentials(username: u, password: p))
        }
        adapter.connect()
        // L'extension reste en vie tant que la session tourne.
        #else
        throw NSError(domain: "OpenIPTV", code: 3,
                      userInfo: [NSLocalizedDescriptionKey:
                        "OpenVPNAdapter missing: add pod OpenVPNAdapter to the VpnTunnel target (see IOS_BUILD.md)."])
        #endif
    }
}

#if canImport(OpenVPNAdapter)

/// Pont OpenVPNAdapter <-> NEPacketTunnelProvider (tun -> packetFlow).
private final class OVPND: NSObject, OpenVPNAdapterDelegate {
    weak var provider: NEPacketTunnelProvider?
    let config: String
    let user: String?
    let pass: String?

    init(provider: NEPacketTunnelProvider, config: String, user: String?, pass: String?) {
        self.provider = provider
        self.config = config
        self.user = user
        self.pass = pass
    }

    func openVPNAdapter(_ openVPNAdapter: OpenVPNAdapter,
                        configureTunnel: OpenVPNConfiguration,
                        completionHandler: @escaping (Error?) -> Void) {
        guard let provider = provider else {
            completionHandler(NSError(domain: "OpenIPTV", code: 4, userInfo: nil))
            return
        }
        // Traduit remote/route/DNS du profil en settings NE (simplifié :
        // full-tunnel IPv4 + DNS du serveur, comme côté Android).
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "127.0.0.1")
        settings.mtu = 1500
        // L'extension reçoit les routes via les callbacks d'événements du
        // core dans une implémentation complète ; V1 : full-tunnel.
        let v4 = NEIPv4Settings(addresses: ["10.8.0.2"], subnetMasks: ["255.255.255.0"])
        v4.includedRoutes = [NEIPv4Route.default()]
        settings.ipv4Settings = v4
        settings.dnsSettings = NEDNSSettings(servers: ["8.8.8.8", "1.1.1.1"])
        provider.setTunnelNetworkSettings(settings, completionHandler: completionHandler)
    }

    func openVPNAdapter(_ openVPNAdapter: OpenVPNAdapter, handleEvent event: OpenVPNAdapterEvent, message: String?) {
        NSLog("[OTV-ovpn] event \(event) \(message ?? "")")
    }

    func openVPNAdapter(_ openVPNAdapter: OpenVPNAdapter, handleError error: Error, message: String?) {
        NSLog("[OTV-ovpn] error \(error) \(message ?? "")")
    }

    func openVPNAdapter(_ openVPNAdapter: OpenVPNAdapter, handleLogMessage logMessage: String) {
        NSLog("[OTV-ovpn] \(logMessage)")
    }
}
#endif
