import Flutter
import UIKit

/// Casting vers Chromecast / Google TV, miroir de CastController.kt.
/// Même channels (`openiptv/cast` + `openiptv/cast_events`), même stateMap,
/// même API (ping/startDiscovery/stopDiscovery/connect/disconnect/load/play/
/// pause/seek/setVolume/stopMedia).
///
/// Deux modes dans un seul fichier :
/// - AVEC `pod 'google-cast-sdk'` : vrai Cast (GoogleCast importé).
/// - SANS le pod : stub qui répond `supported=false`, l'app reste
///   utilisable et le Dart (déjà tolérant à MissingPlugin) n'affiche pas
///   le bouton Cast. Idéal pour un premier build TestFlight.
#if canImport(GoogleCast)
import GoogleCast

final class IosCastManager: NSObject {
    static let shared = IosCastManager()
    private override init() { super.init() }

    private var events: FlutterEventSink?
    private var discoveryCount = 0
    private var connecting = false
    private var scanner: GCKDeviceScanner?
    private var devices: [GCKDevice] = []

    func setup(messenger: FlutterBinaryMessenger) {
        let mc = FlutterMethodChannel(name: "openiptv/cast", binaryMessenger: messenger)
        mc.setMethodCallHandler { [weak self] call, result in
            self?.handle(call: call, result: result)
        }
        let ec = FlutterEventChannel(name: "openiptv/cast_events", binaryMessenger: messenger)
        ec.setStreamHandler(self)

        // Contexte Cast avec le receiver système (comme côté Android).
        let criteria = GCKDiscoveryCriteria(applicationID: kGCKDefaultMediaReceiverApplicationID)
        let options = GCKCastOptions(discoveryCriteria: criteria)
        GCKCastContext.setSharedInstanceWith(options)
        GCKCastContext.sharedInstance().sessionManager.add(self)
        scanner = GCKDeviceScanner(filterCriteria: criteria)
        scanner?.add(self)
        scanner?.passiveScan = true
        scanner?.startScan()
        emit()
    }

    private func handle(call: FlutterMethodCall, result: @escaping FlutterResult) {
        let args = call.arguments as? [String: Any]
        let sm = GCKCastContext.sharedInstance().sessionManager
        switch call.method {
        case "ping":
            result(true)
        case "startDiscovery":
            discoveryCount += 1
            scanner?.passiveScan = false
            scanner?.startScan()
            emit()
            result(nil)
        case "stopDiscovery":
            discoveryCount = max(0, discoveryCount - 1)
            if discoveryCount == 0 { scanner?.passiveScan = true }
            result(nil)
        case "connect":
            let id = args?["id"] as? String
            if let d = devices.first(where: { $0.deviceID == id }) {
                connecting = true
                sm.startSession(with: d)
                emit()
                result(true)
            } else {
                result(false)
            }
        case "disconnect":
            sm.endSession()
            result(nil)
        case "load":
            load(args: args, result: result)
        case "play":
            currentClient()?.play()
            result(nil)
        case "pause":
            currentClient()?.pause()
            result(nil)
        case "seek":
            let ms = (args?["positionMs"] as? NSNumber)?.int64Value ?? 0
            let opts = GCKMediaSeekOptions()
            opts.interval = TimeInterval(ms) / 1000.0
            currentClient()?.seek(with: opts)
            result(nil)
        case "setVolume":
            let v = (args?["volume"] as? NSNumber)?.doubleValue ?? 0.5
            try? sm.currentSession?.setDeviceVolume(Float(v))
            result(nil)
        case "stopMedia":
            currentClient()?.stop()
            result(nil)
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    private func currentClient() -> GCKRemoteMediaClient? {
        (GCKCastContext.sharedInstance().sessionManager.currentSession as? GCKCastSession)?.remoteMediaClient
    }

    private func load(args: [String: Any]?, result: @escaping FlutterResult) {
        guard let client = currentClient(),
              let urlStr = args?["url"] as? String,
              let url = URL(string: urlStr) else {
            result(false)
            return
        }
        let live = (args?["live"] as? Bool) ?? false
        let md = GCKMediaMetadata()
        md.setString(args?["title"] as? String ?? "", forKey: kGCKMetadataKeyTitle)
        if let sub = args?["subtitle"] as? String { md.setString(sub, forKey: kGCKMetadataKeySubtitle) }
        if let img = args?["imageUrl"] as? String, let u = URL(string: img) {
            md.addImage(GCKImage(url: u, width: 480, height: 270))
        }
        let builder = GCKMediaInformationBuilder(
            contentID: urlStr,
            streamType: live ? .live : .buffered,
            contentType: (args?["contentType"] as? String) ?? "video/mp4",
            metadata: md,
            streamDuration: 0,
            mediaTracks: nil,
            textTrackStyle: nil,
            customData: nil
        )
        let req = GCKMediaLoadRequestDataBuilder()
        req.mediaInformation = builder.build()
        req.autoplay = true
        req.startTime = TimeInterval((args?["startMs"] as? NSNumber)?.int64Value ?? 0) / 1000.0
        let reqData = req.build()
        let op = client.loadMedia(with: reqData)
        op.delegate = CastLoadDelegate(result: result)
    }

    private func stateMap() -> [String: Any?] {
        let ctx = GCKCastContext.sharedInstance()
        let sm = ctx.sessionManager
        let session = sm.currentSession as? GCKCastSession
        let connected = (session?.connectionState == .connected)
        let client = currentClient()
        let status = client?.mediaStatus
        let playerState: String = {
            switch status?.playerState {
            case .playing: return "playing"
            case .paused: return "paused"
            case .buffering, .loading: return "buffering"
            default: return "idle"
            }
        }()
        let idleReason: String? = {
            switch status?.idleReason {
            case .error: return "error"
            case .finished: return "finished"
            case .cancelled: return "canceled"
            case .interrupted: return "interrupted"
            default: return nil
            }
        }()
        let devs = devices.sorted { $0.friendlyName.lowercased() < $1.friendlyName.lowercased() }
        return [
            "supported": true,
            "available": ctx.castState != .noDevicesAvailable || !devs.isEmpty,
            "session": connected ? "connected" : (connecting || ctx.castState == .connecting ? "connecting" : "idle"),
            "device": session?.device.friendlyName,
            "devices": devs.map { ["id": $0.deviceID ?? "", "name": $0.friendlyName ?? "", "speaker": false] },
            "playerState": playerState,
            "idleReason": idleReason,
            "contentId": status?.mediaInformation?.contentID,
            "title": status?.mediaInformation?.metadata?.string(forKey: kGCKMetadataKeyTitle),
            "subtitle": status?.mediaInformation?.metadata?.string(forKey: kGCKMetadataKeySubtitle),
            "live": status?.mediaInformation?.streamType == .live,
            "positionMs": Int64((client?.approximateStreamPosition() ?? 0) * 1000),
            "durationMs": Int64(max(0, status?.mediaInformation?.streamDuration ?? 0) * 1000),
            "volume": session?.deviceVolume ?? 0,
        ]
    }

    private func emit() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.events?(self.stateMap())
        }
    }
}

extension IosCastManager: GCKSessionManagerListener {
    func sessionManager(_ m: GCKSessionManager, willStart session: GCKSession) {
        connecting = true
        emit()
    }
    func sessionManager(_ m: GCKSessionManager, didStart session: GCKSession) {
        connecting = false
        currentClient()?.add(self)
        emit()
    }
    func sessionManager(_ m: GCKSessionManager, didResumeSession session: GCKSession) {
        connecting = false
        currentClient()?.add(self)
        emit()
    }
    func sessionManager(_ m: GCKSessionManager, didEnd session: GCKSession, withError error: Error?) {
        connecting = false
        emit()
    }
    func sessionManager(_ m: GCKSessionManager, didFailToStartSessionWithError error: Error?) {
        connecting = false
        emit()
    }
}

extension IosCastManager: GCKRemoteMediaClientListener {
    func remoteMediaClient(_ c: GCKRemoteMediaClient, didUpdate mediaStatus: GCKMediaStatus?) { emit() }
}

extension IosCastManager: GCKDeviceScannerListener {
    func deviceDidComeOnline(_ device: GCKDevice) {
        if !devices.contains(where: { $0.deviceID == device.deviceID }) {
            devices.append(device)
        }
        emit()
    }
    func deviceDidGoOffline(_ device: GCKDevice) {
        devices.removeAll { $0.deviceID == device.deviceID }
        emit()
    }
}

extension IosCastManager: FlutterStreamHandler {
    func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        self.events = events
        emit()
        return nil
    }
    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        self.events = nil
        return nil
    }
}

private final class CastLoadDelegate: NSObject, GCKRequestDelegate {
    let result: FlutterResult
    var done = false
    init(result: @escaping FlutterResult) { self.result = result }
    func requestDidComplete(_ request: GCKRequest) {
        guard !done else { return }
        done = true
        result(true)
    }
    func request(_ request: GCKRequest, didFailWithError error: GCKError) {
        guard !done else { return }
        done = true
        result(false)
    }
}

#else

// Sans le pod google-cast-sdk : stub propre, app utilisable sans Cast.
final class IosCastManager: NSObject {
    static let shared = IosCastManager()
    private override init() {}
    func setup(messenger: FlutterBinaryMessenger) {
        let mc = FlutterMethodChannel(name: "openiptv/cast", binaryMessenger: messenger)
        mc.setMethodCallHandler { call, result in
            switch call.method {
            case "ping": result(true)
            case "startDiscovery", "stopDiscovery", "disconnect", "play", "pause", "seek", "setVolume", "stopMedia":
                result(nil)
            case "connect": result(false)
            case "load": result(false)
            default: result(FlutterMethodNotImplemented)
            }
        }
        let ec = FlutterEventChannel(name: "openiptv/cast_events", binaryMessenger: messenger)
        ec.setStreamHandler(CastStubEvents())
    }
}

private final class CastStubEvents: NSObject, FlutterStreamHandler {
    func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        events(["supported": false, "available": false, "session": "idle",
                "devices": [], "playerState": "idle", "live": false,
                "positionMs": 0, "durationMs": 0, "volume": 0])
        return nil
    }
    func onCancel(withArguments arguments: Any?) -> FlutterError? { nil }
}

#endif
