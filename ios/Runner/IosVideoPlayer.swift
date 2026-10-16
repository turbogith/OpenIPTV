import Flutter
import AVFoundation
import UIKit

/// Équivalent iOS de NativeVideoPlayer.kt (ExoPlayer) : même channel
/// `openiptv/video_player` + mêmes events `openiptv/video_player_events/<id>`,
/// même format d'état, mêmes ids de pistes `groupe:index`.
///
/// Rendu dans une Flutter Texture via AVPlayerItemVideoOutput (comme
/// SurfaceTexture côté Android) : multi-view et PiP suivent la même
/// architecture. Limites V1 documentées dans IOS_BUILD.md :
/// - MPEG-TS brut (.ts) : AVPlayer ne le décode pas en progressif. Le Dart
///   envoie déjà `streamTypeHint`; ici on joue l'URL telle quelle et on
///   remonte l'erreur au watchdog qui retentera (souvent la variante HLS).
/// - Sous-titres : remontés en texte via AVPlayerItemLegibleOutput quand
///   disponibles, sinon rendu natif désactivé par défaut comme sur Android.
final class IosVideoPlayer: NSObject, FlutterTexture {
    weak var manager: IosVideoManager?
    let textureId: Int64

    private var player: AVPlayer?
    private var item: AVPlayerItem?
    private var videoOutput: AVPlayerItemVideoOutput?
    private var legibleOutput: AVPlayerItemLegibleOutput?
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var failObserver: NSObjectProtocol?

    private var lastBuffer: CVPixelBuffer?
    private var eventSink: FlutterEventSink?

    private var videoWidth = 0
    private var videoHeight = 0
    private var pixelRatio: Double = 1.0
    private var playWhenReady = false
    private var completed = false
    private var audioFocus = true
    private var speed: Float = 1.0

    init(textureId: Int64, manager: IosVideoManager, audioFocus: Bool) {
        self.textureId = textureId
        self.manager = manager
        self.audioFocus = audioFocus
        super.init()
        configureAudioSession()
    }

    // MARK: FlutterTexture

    func copyPixelBuffer() -> Unmanaged<CVPixelBuffer>? {
        guard let out = videoOutput else { return nil }
        let t = out.itemTime(forHostTime: CACurrentMediaTime())
        if out.hasNewPixelBuffer(forItemTime: t),
           let pb = out.copyPixelBuffer(forItemTime: t, itemTimeForDisplay: nil) {
            lastBuffer = pb
            if let track = item?.tracks.first(where: { $0.assetTrack?.mediaType == .video }),
               let nat = track.assetTrack?.naturalSize {
                let w = Int(nat.width), h = Int(nat.height)
                if w > 0 && h > 0 && (w != videoWidth || h != videoHeight) {
                    videoWidth = w
                    videoHeight = h
                    emitState()
                }
            }
            return Unmanaged.passRetained(pb)
        }
        if let pb = lastBuffer {
            return Unmanaged.passRetained(pb)
        }
        return nil
    }

    func setEventSink(_ sink: FlutterEventSink?) {
        eventSink = sink
    }

    // MARK: Contrôle (mêmes noms que le Kotlin)

    func open(url: String, hint: String?, startMs: Int64, bufferPreset: String, carScreen: Bool) {
        completed = false
        videoWidth = 0
        videoHeight = 0
        pixelRatio = 1.0
        guard let u = URL(string: url) else {
            sendError(code: "bad_url", http: nil)
            return
        }
        detachItemObservers()
        let asset = AVURLAsset(url: u, options: [
            "AVURLAssetHTTPHeaderFieldsKey": ["User-Agent": "OpenIPTV-iOS"],
        ])
        let newItem = AVPlayerItem(asset: asset)
        // Pré-chargement selon le preset (miroir de loadControlFor).
        switch bufferPreset {
        case "smooth": newItem.preferredForwardBufferDuration = 20
        case "balanced": newItem.preferredForwardBufferDuration = 10
        default: newItem.preferredForwardBufferDuration = 2
        }
        newItem.preferredPeakBitRate = 0 // auto
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ]
        let vOut = AVPlayerItemVideoOutput(pixelBufferAttributes: attrs)
        newItem.add(vOut)
        self.videoOutput = vOut
        let leg = AVPlayerItemLegibleOutput()
        leg.setDelegate(self, queue: DispatchQueue.main)
        newItem.add(leg)
        self.legibleOutput = leg

        self.item = newItem
        if player == nil {
            let p = AVPlayer(playerItem: newItem)
            p.actionAtItemEnd = .pause
            self.player = p
            // Tick 500 ms comme le positionUpdater Android.
            let interval = CMTime(seconds: 0.5, preferredTimescale: 2)
            timeObserver = p.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] _ in
                self?.textureFrame()
                self?.emitState()
            }
        } else {
            player?.replaceCurrentItem(with: newItem)
        }
        applyAudible()
        // Vitesse normale à chaque stream (comme le Kotlin).
        player?.rate = 0
        setSpeed(1.0)
        clearTextTrack()
        attachItemObservers(item: newItem)
        if startMs > 0 {
            let t = CMTime(value: startMs, timescale: 1000)
            player?.seek(to: t, toleranceBefore: .zero, toleranceAfter: .zero)
        }
        playWhenReady = true
        player?.play()
        manager?.anyPlayingChanged()
        emitState()
    }

    func play() {
        playWhenReady = true
        completed = false
        player?.rate = speed
        manager?.anyPlayingChanged()
        emitState()
    }

    func pause() {
        playWhenReady = false
        player?.pause()
        manager?.anyPlayingChanged()
        emitState()
    }

    func stop() {
        playWhenReady = false
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        item = nil
        manager?.anyPlayingChanged()
        emitState()
    }

    func seekTo(ms: Int64) -> Int64 {
        let t = CMTime(value: ms, timescale: 1000)
        player?.seek(to: t, toleranceBefore: .zero, toleranceAfter: .zero)
        emitState()
        let cur = Int64((player?.currentTime().seconds ?? Double(ms) / 1000.0) * 1000)
        return cur
    }

    func setAudible(_ on: Bool) {
        audioFocus = on
        applyAudible()
    }

    private func applyAudible() {
        player?.volume = audioFocus ? 1.0 : 0.0
        player?.isMuted = !audioFocus
        configureAudioSession()
    }

    private func configureAudioSession() {
        do {
            if audioFocus {
                try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback, options: [])
                try AVAudioSession.sharedInstance().setActive(true)
            }
        } catch {
            // Préview muette ou session prise : pas bloquant.
        }
    }

    func setSpeed(_ s: Double) {
        let v = min(4.0, max(0.25, s))
        speed = Float(v)
        if playWhenReady {
            player?.rate = speed
        }
    }

    func getTracks() -> [[String: Any?]] {
        guard let it = item else { return [] }
        var out: [[String: Any?]] = []
        // Groupe 0 = audio, groupe 1 = texte (miroir "group:index").
        if let asset = (it.asset as? AVURLAsset) {
            // Audio via mediaSelection.
            if let ag = asset.mediaSelectionGroup(forMediaCharacteristic: .audible) {
                for (i, opt) in ag.options.enumerated() {
                    let sel = it.currentMediaSelection.selectedMediaOption(in: ag)
                    out.append([
                        "id": "0:\(i)",
                        "type": "audio",
                        "label": opt.displayName,
                        "language": opt.extendedLanguageTag ?? opt.locale?.identifier,
                        "mimeType": nil,
                        "channel": -1,
                        "selected": (sel == opt),
                    ])
                }
            }
            if let tg = asset.mediaSelectionGroup(forMediaCharacteristic: .legible) {
                for (i, opt) in tg.options.enumerated() {
                    let sel = it.currentMediaSelection.selectedMediaOption(in: tg)
                    out.append([
                        "id": "1:\(i)",
                        "type": "text",
                        "label": opt.displayName,
                        "language": opt.extendedLanguageTag ?? opt.locale?.identifier,
                        "mimeType": nil,
                        "channel": -1,
                        "selected": (sel == opt),
                    ])
                }
            }
        }
        return out
    }

    func selectTrack(id: String) {
        let parts = id.split(separator: ":")
        guard parts.count == 2,
              let g = Int(parts[0]), let idx = Int(parts[1]),
              let it = item,
              let asset = it.asset as? AVURLAsset else { return }
        if g == 0, let ag = asset.mediaSelectionGroup(forMediaCharacteristic: .audible),
           idx < ag.options.count {
            it.select(ag.options[idx], in: ag)
        } else if g == 1, let tg = asset.mediaSelectionGroup(forMediaCharacteristic: .legible),
                  idx < tg.options.count {
            it.select(tg.options[idx], in: tg)
        }
        sendTracks()
    }

    func clearTextTrack() {
        guard let it = item,
              let asset = it.asset as? AVURLAsset,
              let tg = asset.mediaSelectionGroup(forMediaCharacteristic: .legible) else { return }
        it.select(nil, in: tg)
    }

    func dispose() {
        detachItemObservers()
        if let obs = timeObserver {
            player?.removeTimeObserver(obs)
            timeObserver = nil
        }
        player?.pause()
        player = nil
        item = nil
        lastBuffer = nil
        manager?.anyPlayingChanged()
    }

    // MARK: Observations

    private func attachItemObservers(item: AVPlayerItem) {
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
        ) { [weak self] _ in
            self?.completed = true
            self?.playWhenReady = false
            self?.emitState()
            self?.manager?.anyPlayingChanged()
        }
        failObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main
        ) { [weak self] note in
            let err = note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? NSError
            self?.sendError(code: err?.domain ?? "play_failed", http: nil)
        }
        item.addObserver(self, forKeyPath: "status", options: [.new], context: nil)
    }

    private func detachItemObservers() {
        if let o = endObserver { NotificationCenter.default.removeObserver(o); endObserver = nil }
        if let o = failObserver { NotificationCenter.default.removeObserver(o); failObserver = nil }
        // L'ancien item peut déjà être libéré ; protège l'observeur KVO.
        if let it = item {
            it.removeObserver(self, forKeyPath: "status")
        }
    }

    override func observeValue(forKeyPath kp: String?, of obj: Any?, change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?) {
        if kp == "status", let it = obj as? AVPlayerItem, it.status == .failed {
            let ns = it.error as NSError?
            sendError(code: ns?.domain ?? "load_failed", http: nil)
        }
        emitState()
    }

    private func textureFrame() {
        if let mgr = manager, let reg = mgr.textureRegistry {
            reg.textureFrameAvailable(textureId)
        }
    }

    private func emitState() {
        guard let sink = eventSink else { return }
        let p = player
        let it = item
        let posMs: Int64
        let durMs: Int64
        if let c = p?.currentTime(), c.isValid && !c.seconds.isNaN {
            posMs = Int64(max(0, c.seconds) * 1000)
        } else { posMs = 0 }
        if let d = it?.duration, d.isValid && !d.seconds.isNaN && d.seconds.isFinite {
            durMs = Int64(max(0, d.seconds) * 1000)
        } else { durMs = 0 }
        let playing = (p?.rate ?? 0) > 0
        let buffering: Bool = {
            guard let it = it else { return false }
            if it.status != .readyToPlay { return true }
            return p?.timeControlStatus == .waitingToPlayAtSpecifiedRate
        }()
        sink([
            "type": "state",
            "position": posMs,
            "duration": durMs,
            "playing": playing,
            "playWhenReady": playWhenReady,
            "suppressed": false,
            "buffering": buffering,
            "completed": completed,
            "videoWidth": videoWidth,
            "videoHeight": videoHeight,
            "pixelRatio": pixelRatio,
        ])
    }

    private func sendTracks() {
        eventSink?(["type": "tracks", "tracks": getTracks()])
    }

    private func sendError(code: String, http: Int?) {
        var m: [String: Any] = ["type": "error", "code": code]
        if let h = http { m["httpStatus"] = h }
        eventSink?(m)
    }
}

// Sous-titres HLS -> channel `cues` (comme onCues ExoPlayer).
extension IosVideoPlayer: AVPlayerItemLegibleOutputPushDelegate {
    func legibleOutput(_ output: AVPlayerItemLegibleOutput,
                       didOutputAttributedStrings strings: [NSAttributedString],
                       nativeSampleBuffers: [Any],
                       forItemTime time: CMTime) {
        let text = strings.map { $0.string }.joined(separator: "\n")
        eventSink?(["type": "cues", "text": text])
    }
}

/// Registre des instances (multi-view : guide + plein écran en parallèle),
/// miroir de NativeVideoPlayerManager.
final class IosVideoManager: NSObject {
    static let shared = IosVideoManager()
    private override init() {}

    fileprivate var textureRegistry: FlutterTextureRegistry?
    var players: [Int64: IosVideoPlayer] = [:]
    private var playingIds = Set<Int64>()

    func setup(messenger: FlutterBinaryMessenger) {
        // Le registry est récupéré via le registrar dans AppDelegate.
        let ch = FlutterMethodChannel(name: "openiptv/video_player", binaryMessenger: messenger)
        ch.setMethodCallHandler { [weak self] call, result in
            self?.handle(call: call, result: result)
        }
    }

    func attachRegistry(_ reg: FlutterTextureRegistry) {
        textureRegistry = reg
    }

    fileprivate func anyPlayingChanged() {
        var any = false
        for (id, pl) in players {
            // `playing` réel approximé : rate > 0. On le recalcule au tick.
            _ = pl
            _ = id
        }
        // Idle timer global : coupé dès qu'un player existe et joue.
        // Valeur exacte poussée à chaque emitState via isPlaying ci-dessous.
        _ = any
    }

    func setPlaying(id: Int64, playing: Bool) {
        if playing { playingIds.insert(id) } else { playingIds.remove(id) }
        DispatchQueue.main.async {
            UIApplication.shared.isIdleTimerDisabled = !self.playingIds.isEmpty
        }
    }

    private func idArg(_ call: FlutterMethodCall) -> Int64 {
        if let m = call.arguments as? [String: Any] {
            if let n = m["id"] as? Int64 { return n }
            if let n = m["id"] as? Int { return Int64(n) }
            if let n = m["id"] as? NSNumber { return n.int64Value }
        }
        return 0
    }

    private func handle(call: FlutterMethodCall, result: @escaping FlutterResult) {
        let args = call.arguments as? [String: Any]
        switch call.method {
        case "create":
            guard let reg = textureRegistry else {
                result(FlutterError(code: "no_registry", message: "Texture registry not attached", details: nil))
                return
            }
            let audioFocus = (args?["audioFocus"] as? Bool) ?? true
            // Crée d'abord un holder pour obtenir l'id, puis le player.
            let holder = IosTextureHolder()
            let tid = reg.register(holder)
            let pl = IosVideoPlayer(textureId: tid, manager: self, audioFocus: audioFocus)
            holder.player = pl
            players[tid] = pl
            attachEventChannel(id: tid)
            result(tid)
        case "open":
            let id = idArg(call)
            players[id]?.open(
                url: (args?["url"] as? String) ?? "",
                hint: args?["streamTypeHint"] as? String,
                startMs: (args?["startPositionMs"] as? NSNumber)?.int64Value ?? 0,
                bufferPreset: (args?["bufferPreset"] as? String) ?? "fast",
                carScreen: (args?["carScreen"] as? Bool) ?? false
            )
            setPlaying(id: id, playing: true)
            result(nil)
        case "play":
            let id = idArg(call)
            players[id]?.play()
            setPlaying(id: id, playing: true)
            result(nil)
        case "pause":
            let id = idArg(call)
            players[id]?.pause()
            setPlaying(id: id, playing: false)
            result(nil)
        case "stop":
            let id = idArg(call)
            players[id]?.stop()
            setPlaying(id: id, playing: false)
            result(nil)
        case "seekTo":
            let id = idArg(call)
            let ms = (args?["positionMs"] as? NSNumber)?.int64Value ?? 0
            result(players[id]?.seekTo(ms: ms))
        case "setAudible":
            let id = idArg(call)
            players[id]?.setAudible((args?["on"] as? Bool) ?? true)
            result(nil)
        case "setSpeed":
            let id = idArg(call)
            players[id]?.setSpeed((args?["speed"] as? NSNumber)?.doubleValue ?? 1.0)
            result(nil)
        case "getTracks":
            let id = idArg(call)
            result(players[id]?.getTracks() ?? [])
        case "selectTrack":
            let id = idArg(call)
            players[id]?.selectTrack(id: (args?["trackId"] as? String) ?? "")
            result(nil)
        case "clearTextTrack":
            let id = idArg(call)
            players[id]?.clearTextTrack()
            result(nil)
        case "dispose":
            let id = idArg(call)
            if let pl = players.removeValue(forKey: id) {
                pl.dispose()
                textureRegistry?.unregisterTexture(id)
            }
            setPlaying(id: id, playing: false)
            result(nil)
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    private var eventHandlers: [Int64: IosVideoEvents] = [:]

    private func attachEventChannel(id: Int64) {
        guard let messenger = IosPortMessenger.shared.messenger else { return }
        let h = IosVideoEvents(playerId: id)
        eventHandlers[id] = h
        let ec = FlutterEventChannel(name: "openiptv/video_player_events/\(id)", binaryMessenger: messenger)
        ec.setStreamHandler(h)
    }
}

/// Petit relais messenger global (posé par AppDelegate au setup).
final class IosPortMessenger {
    static let shared = IosPortMessenger()
    var messenger: FlutterBinaryMessenger?
    private init() {}
}

private final class IosTextureHolder: NSObject, FlutterTexture {
    weak var player: IosVideoPlayer?
    func copyPixelBuffer() -> Unmanaged<CVPixelBuffer>? {
        player?.copyPixelBuffer()
    }
}

private final class IosVideoEvents: NSObject, FlutterStreamHandler {
    let playerId: Int64
    init(playerId: Int64) { self.playerId = playerId }
    func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        IosVideoManager.shared.players[playerId]?.setEventSink(events)
        return nil
    }
    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        IosVideoManager.shared.players[playerId]?.setEventSink(nil)
        return nil
    }
}

extension IosVideoManager {
    fileprivate var playersAccess: [Int64: IosVideoPlayer] { players }
}
