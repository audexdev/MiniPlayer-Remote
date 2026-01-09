import AVFoundation
import Foundation
import MediaPlayer
import MultipeerConnectivity
import UIKit

enum QualityCodec: String {
    case atmos
    case lossless
    case aac
}

enum PlaybackDevice: String {
    case local = "Local"
    case remote = "Remote"
}

final class MusicAgentController: NSObject, ObservableObject {
    @Published var status: String = "Idle"
    @Published var connectionStatus: String = "Disconnected"
    @Published var isConnecting: Bool = false
    @Published var connectTimedOut: Bool = false
    @Published var mediaAuthorization: String = "Media: unknown"
    @Published var pairingCode: String = ""
    @Published var isPaired: Bool = false
    @Published var displayArtworkImage: UIImage?
    @Published var backgroundColor: UIColor = .systemBackground
    @Published var isDarkBackground: Bool = false
    @Published var qualityLabel: String = ""
    @Published var qualityCodec: QualityCodec?
    @Published var deviceLabel: String = ""
    @Published var preferredDevice: PlaybackDevice = .local
    @Published var isRemoteAvailable: Bool = false
    @Published var shuffleEnabled: Bool = false
    @Published var repeatMode: Int = 0
    @Published var lastState = PlaybackState(
        isPlaying: false,
        songTitle: "",
        artistName: "",
        albumName: "",
        positionSeconds: 0,
        durationSeconds: 0,
        artworkBase64: nil,
        volumeLevel: 0.5,
        shuffleEnabled: nil,
        repeatMode: nil
    )
    @Published var activeTarget: PlaybackTarget = .ios

    private let peerID: MCPeerID
    private var session: MCSession
    private var advertiser: MCNearbyServiceAdvertiser
    private let player = MPMusicPlayerController.systemMusicPlayer
    private var playbackTimer: Timer?
    private var artworkTargetSize: CGFloat = 300
    private var lastArtworkSignature: String?
    private var lastArtworkBase64: String?
    private var lastTrackKey: String?
    private var lastArtworkSentKey: String?
    private var lastColorKey: String?
    private var connectTimeoutTask: Task<Void, Never>?
    private var localState: PlaybackState = PlaybackState(
        isPlaying: false,
        songTitle: "",
        artistName: "",
        albumName: "",
        positionSeconds: 0,
        durationSeconds: 0,
        artworkBase64: nil,
        volumeLevel: 0.5,
        shuffleEnabled: nil,
        repeatMode: nil
    )
    private var remoteState: PlaybackState?
    private var localArtworkImage: UIImage?
    private var remoteArtworkImage: UIImage?
    private var remoteTrackKey: String?
    private var lastArtworkRequestKey: String?
    private var lastArtworkRequestDate: Date?
    private var remoteArtworkRequestSize: Int?
    private var remoteDeviceName: String?
    private var lastTrackPersistentID: String?
    private let localDeviceName: String = UIDevice.current.name
    private let volumeView = MPVolumeView(frame: .zero)
    private var volumeSlider: UISlider?
    private var heartbeatTimer: Timer?
    private var lastHeartbeat: Date?
    private var missedHeartbeatCount: Int = 0
    private var isRebuilding: Bool = false
    private let commandCenter = MPRemoteCommandCenter.shared()
    private var nowPlayingSessionActive = false
    private var silentPlayer: AVAudioPlayer?

    private let pairedPeersKey = "pairedPeerIDs"
    private let pairingCodeKey = "pairingCode"

    override init() {
        let displayName = StablePeerID.shared.loadDisplayName(label: "MiniPlayerRemote")
        peerID = MCPeerID(displayName: displayName)
        session = MCSession(peer: peerID, securityIdentity: nil, encryptionPreference: .required)
        advertiser = MCNearbyServiceAdvertiser(peer: peerID, discoveryInfo: nil, serviceType: MPEnvelope.serviceType)
        super.init()

        configureSession()
        loadPairingState()

        advertiser.startAdvertisingPeer()
        status = "Advertising as \(peerID.displayName)"

        player.beginGeneratingPlaybackNotifications()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(nowPlayingItemDidChange),
            name: .MPMusicPlayerControllerNowPlayingItemDidChange,
            object: player
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(playbackStateDidChange),
            name: .MPMusicPlayerControllerPlaybackStateDidChange,
            object: player
        )

        requestMediaAuthorization()
        setupVolumeObserver()
        attachVolumeViewIfNeeded()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appDidBecomeActive),
            name: UIApplication.didBecomeActiveNotification,
            object: nil
        )
        configureNowPlayingCommands()
        updateNowPlayingCommandAvailability()
        refreshState()
        updatePlaybackTimer()
    }

    deinit {
        player.endGeneratingPlaybackNotifications()
        NotificationCenter.default.removeObserver(self)
        playbackTimer?.invalidate()
        heartbeatTimer?.invalidate()
        advertiser.stopAdvertisingPeer()
        session.disconnect()
        stopSilentPlayback()
        clearNowPlayingInfo()
    }

    private func loadPairingState() {
        let paired = UserDefaults.standard.stringArray(forKey: pairedPeersKey) ?? []
        isPaired = !paired.isEmpty
        if !isPaired {
            if let existing = UserDefaults.standard.string(forKey: pairingCodeKey) {
                pairingCode = existing
            } else {
                pairingCode = String(format: "%06d", Int.random(in: 0...999_999))
                UserDefaults.standard.set(pairingCode, forKey: pairingCodeKey)
            }
        }
    }

    func resetPairing() {
        debugLog("remote/pairing reset requested")
        resetPairing(sendToPeer: true)
    }

    private func resetPairing(sendToPeer: Bool) {
        debugLog("remote/pairing reset (sendToPeer:", sendToPeer, ")")
        if sendToPeer, !session.connectedPeers.isEmpty {
            sendPairingReset()
        }
        UserDefaults.standard.removeObject(forKey: pairedPeersKey)
        UserDefaults.standard.removeObject(forKey: pairingCodeKey)
        isPaired = false
        pairingCode = String(format: "%06d", Int.random(in: 0...999_999))
        UserDefaults.standard.set(pairingCode, forKey: pairingCodeKey)
        isConnecting = false
        rebuildSession()
    }

    func connectToPairedPeer() {
        guard isPaired else { return }
        isConnecting = true
        connectTimedOut = false
        connectionStatus = "Connecting"
        rebuildSession()
        connectTimeoutTask?.cancel()
        connectTimeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            guard let self else { return }
            if !self.isRemoteAvailable {
                self.isConnecting = false
                self.connectionStatus = "Disconnected"
                self.connectTimedOut = true
            }
        }
    }

    private func savePairedPeer(_ peerID: MCPeerID) {
        var paired = UserDefaults.standard.stringArray(forKey: pairedPeersKey) ?? []
        if !paired.contains(peerID.displayName) {
            paired.append(peerID.displayName)
            UserDefaults.standard.set(paired, forKey: pairedPeersKey)
        }
        isPaired = true
    }

    private func isKnownPeer(_ peerID: MCPeerID) -> Bool {
        let paired = UserDefaults.standard.stringArray(forKey: pairedPeersKey) ?? []
        return paired.contains(peerID.displayName)
    }

    private func configureSession() {
        session.delegate = self
        advertiser.delegate = self
    }

    private func rebuildSession() {
        guard !isRebuilding else { return }
        isRebuilding = true
        debugLog("remote/rebuild session")
        advertiser.stopAdvertisingPeer()
        session.disconnect()
        session = MCSession(peer: peerID, securityIdentity: nil, encryptionPreference: .required)
        advertiser = MCNearbyServiceAdvertiser(peer: peerID, discoveryInfo: nil, serviceType: MPEnvelope.serviceType)
        configureSession()
        advertiser.startAdvertisingPeer()
        status = "Advertising as \(peerID.displayName)"
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.isRebuilding = false
        }
    }

    private func startHeartbeat() {
        debugLog("remote/heartbeat start")
        heartbeatTimer?.invalidate()
        lastHeartbeat = Date()
        missedHeartbeatCount = 0
        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            guard !self.session.connectedPeers.isEmpty else { return }
            let ping = HeartbeatMessage(kind: "heartbeat", type: "ping")
            if let data = try? JSONEncoder().encode(ping) {
                debugLog("remote/heartbeat ping")
                try? self.session.send(data, toPeers: self.session.connectedPeers, with: .unreliable)
            }
            if let last = self.lastHeartbeat {
                let elapsed = Date().timeIntervalSince(last)
                if elapsed > 6.0 {
                    self.missedHeartbeatCount += 1
                    if self.missedHeartbeatCount == 3 {
                        debugLog("remote/heartbeat warning: missed 3")
                    }
                    if self.missedHeartbeatCount >= 6 {
                        debugLog("remote/heartbeat timeout, rebuild")
                        self.rebuildSession()
                    }
                } else {
                    self.missedHeartbeatCount = 0
                }
            }
        }
        RunLoop.main.add(heartbeatTimer!, forMode: .common)
    }

    private func stopHeartbeat() {
        debugLog("remote/heartbeat stop")
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
        lastHeartbeat = nil
        missedHeartbeatCount = 0
    }

    private func noteHeartbeat() {
        debugLog("remote/heartbeat received")
        lastHeartbeat = Date()
        missedHeartbeatCount = 0
    }

    private func setupVolumeObserver() {
        if let slider = volumeView.subviews.first(where: { $0 is UISlider }) as? UISlider {
            volumeSlider = slider
            slider.addTarget(self, action: #selector(volumeSliderChanged(_:)), for: .valueChanged)
        }
    }

    @objc private func appDidBecomeActive() {
        attachVolumeViewIfNeeded()
        handleForeground()
    }

    private func handleForeground() {
        refreshState()
        updatePlaybackTimer()
        if !session.connectedPeers.isEmpty {
            startHeartbeat()
            if activeTarget == .mac {
                debugLog("remote/send state request (foreground)")
                sendStateRequest()
                sendArtworkRequest(size: remoteArtworkRequestSize)
                sendQualityRequest()
            } else {
                broadcastState()
            }
        }
    }

    private func attachVolumeViewIfNeeded() {
        if volumeView.superview != nil {
            setupVolumeObserver()
            return
        }
        guard let windowScene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }),
              let window = windowScene.windows.first(where: { $0.isKeyWindow }) else {
            return
        }

        volumeView.alpha = 0.01
        volumeView.isHidden = false
        volumeView.frame = CGRect(x: -100, y: -100, width: 1, height: 1)
        window.addSubview(volumeView)
        setupVolumeObserver()
    }

    @objc private func volumeSliderChanged(_ sender: UISlider) {
        localState.volumeLevel = Double(sender.value)
        updateDisplayedState()
        broadcastState()
    }

    func requestMediaAuthorization() {
        MPMediaLibrary.requestAuthorization { [weak self] status in
            DispatchQueue.main.async {
                self?.mediaAuthorization = "Media: \(self?.string(for: status) ?? "unknown")"
            }
        }
    }


    private func string(for status: MPMediaLibraryAuthorizationStatus) -> String {
        switch status {
        case .authorized:
            return "authorized"
        case .denied:
            return "denied"
        case .restricted:
            return "restricted"
        case .notDetermined:
            return "not determined"
        @unknown default:
            return "unknown"
        }
    }

    @objc private func nowPlayingItemDidChange() {
        refreshState()
        broadcastState(includeArtwork: true)
        clearArtworkCache()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.refreshState()
            self?.broadcastState()
        }
    }

    @objc private func playbackStateDidChange() {
        refreshState()
        updatePlaybackTimer()
        broadcastState()
    }

    private func refreshState() {
        let item = player.nowPlayingItem
        let elapsed = currentPlaybackSeconds()
        let duration = item?.playbackDuration ?? 0
        updateArtworkImage(item)
        lastTrackPersistentID = item.map { String($0.persistentID) }
        localState = PlaybackState(
            isPlaying: player.playbackState == .playing,
            songTitle: item?.title ?? "",
            artistName: item?.artist ?? "",
            albumName: item?.albumTitle ?? "",
            positionSeconds: elapsed,
            durationSeconds: duration,
            artworkBase64: nil,
            volumeLevel: currentVolumeLevel(),
            shuffleEnabled: player.shuffleMode == .songs,
            repeatMode: mapRepeatMode(player.repeatMode)
        )
        lastTrackKey = "\(localState.songTitle)|\(localState.artistName)|\(localState.albumName)"
        updateDisplayedState()
    }

    private func handleCommand(_ command: RemoteCommand) {
        switch command {
        case .play:
            player.play()
        case .pause:
            player.pause()
        case .next:
            player.skipToNextItem()
        case .prev:
            player.skipToPreviousItem()
        case .toggleShuffle:
            player.shuffleMode = (player.shuffleMode == .songs) ? .off : .songs
        case .cycleRepeat:
            switch player.repeatMode {
            case .none:
                player.repeatMode = .all
            case .all:
                player.repeatMode = .one
            case .one:
                player.repeatMode = .none
            @unknown default:
                player.repeatMode = .none
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.refreshState()
            self?.broadcastState(includeArtwork: true)
        }
    }

    func togglePlayPause() {
        if activeTarget == .ios {
            if player.playbackState == .playing {
                player.pause()
            } else {
                player.play()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.refreshState()
                self?.broadcastState()
            }
        } else {
            let isPlaying = remoteState?.isPlaying ?? lastState.isPlaying
            sendCommand(isPlaying ? .pause : .play)
        }
    }

    func next() {
        if activeTarget == .ios {
            player.skipToNextItem()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.refreshState()
                self?.broadcastState(includeArtwork: true)
            }
        } else {
            sendCommand(.next)
        }
    }

    func prev() {
        if activeTarget == .ios {
            player.skipToPreviousItem()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.refreshState()
                self?.broadcastState(includeArtwork: true)
            }
        } else {
            sendCommand(.prev)
        }
    }

    func seek(to seconds: Double) {
        if activeTarget == .ios {
            player.currentPlaybackTime = seconds
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.refreshState()
                self?.broadcastState()
            }
        } else {
            sendControl(volume: nil, seekSeconds: seconds)
        }
    }

    func setVolume(_ value: Double) {
        let clamped = max(0.0, min(1.0, value))
        if activeTarget == .ios {
            setSystemVolume(clamped)
            localState.volumeLevel = clamped
            updateDisplayedState()
            broadcastState()
        } else {
            sendControl(volume: clamped, seekSeconds: nil)
        }
    }

    func selectDevice(_ device: PlaybackDevice) {
        preferredDevice = device
        let target: PlaybackTarget = (device == .local) ? .ios : .mac
        setActiveTarget(target, send: true)
    }

    func toggleShuffle() {
        if activeTarget == .ios {
            player.shuffleMode = (player.shuffleMode == .songs) ? .off : .songs
            refreshState()
        } else {
            sendCommand(.toggleShuffle)
        }
    }

    func cycleRepeatMode() {
        if activeTarget == .ios {
            switch player.repeatMode {
            case .none:
                player.repeatMode = .all
            case .all:
                player.repeatMode = .one
            case .one:
                player.repeatMode = .none
            @unknown default:
                player.repeatMode = .none
            }
            refreshState()
        } else {
            sendCommand(.cycleRepeat)
        }
    }

    private func handleControl(volume: Double?, seekSeconds: Double?) {
        if let volume {
            setSystemVolume(volume)
        }
        if let seekSeconds {
            player.currentPlaybackTime = seekSeconds
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.refreshState()
                self?.broadcastState()
            }
        }
    }

    private func broadcastState(includeArtwork: Bool = false) {
        guard !session.connectedPeers.isEmpty else { return }
        var state = localState
        if includeArtwork {
            let currentKey = "\(localState.songTitle)|\(localState.artistName)|\(localState.albumName)"
            if currentKey != lastArtworkSentKey, let artworkBase64 = currentArtworkBase64() {
                state.artworkBase64 = artworkBase64
                lastArtworkSentKey = currentKey
            }
        }
        let message = StateMessage(kind: "state", state: state)
        guard let data = try? JSONEncoder().encode(message) else { return }
        try? session.send(data, toPeers: session.connectedPeers, with: .reliable)
    }

    private func sendCommand(_ command: RemoteCommand) {
        guard !session.connectedPeers.isEmpty else { return }
        let message = CommandMessage(kind: "command", command: command)
        guard let data = try? JSONEncoder().encode(message) else { return }
        try? session.send(data, toPeers: session.connectedPeers, with: .reliable)
    }

    private func sendControl(volume: Double?, seekSeconds: Double?) {
        guard !session.connectedPeers.isEmpty else { return }
        let message = ControlMessage(kind: "control", volume: volume, seekSeconds: seekSeconds)
        guard let data = try? JSONEncoder().encode(message) else { return }
        try? session.send(data, toPeers: session.connectedPeers, with: .reliable)
    }

    private func sendDeviceTarget(_ target: PlaybackTarget) {
        guard !session.connectedPeers.isEmpty else { return }
        let message = DeviceMessage(kind: "device", target: target)
        guard let data = try? JSONEncoder().encode(message) else { return }
        try? session.send(data, toPeers: session.connectedPeers, with: .reliable)
    }

    private func sendArtworkRequest(size: Int?) {
        guard !session.connectedPeers.isEmpty else { return }
        let message = ArtworkRequestMessage(kind: "artworkRequest", size: size)
        guard let data = try? JSONEncoder().encode(message) else { return }
        try? session.send(data, toPeers: session.connectedPeers, with: .reliable)
    }

    private func sendStateRequest() {
        guard !session.connectedPeers.isEmpty else { return }
        let message = StateRequestMessage(kind: "stateRequest")
        guard let data = try? JSONEncoder().encode(message) else { return }
        try? session.send(data, toPeers: session.connectedPeers, with: .reliable)
    }

    private func sendQualityRequest() {
        guard !session.connectedPeers.isEmpty else { return }
        let message = QualityRequestMessage(kind: "qualityRequest")
        guard let data = try? JSONEncoder().encode(message) else { return }
        try? session.send(data, toPeers: session.connectedPeers, with: .reliable)
    }

    private func setActiveTarget(_ target: PlaybackTarget, send: Bool) {
        activeTarget = target
        deviceLabel = (target == .ios) ? PlaybackDevice.local.rawValue : PlaybackDevice.remote.rawValue
        if send {
            sendDeviceTarget(target)
        }
        updateDisplayedState()
    }

    private func updateDisplayedState() {
        let localPlaying = localState.isPlaying
        let remotePlaying = remoteState?.isPlaying ?? false
        if localPlaying && !remotePlaying {
            if activeTarget != .ios {
                activeTarget = .ios
                sendDeviceTarget(.ios)
            }
        } else if remotePlaying && !localPlaying {
            activeTarget = .mac
        }

        if activeTarget == .mac, let remote = remoteState {
            lastState = remote
        } else {
            lastState = localState
        }

        shuffleEnabled = lastState.shuffleEnabled ?? shuffleEnabled
        repeatMode = lastState.repeatMode ?? repeatMode
        updateDeviceLabel()
        if activeTarget == .ios {
            qualityLabel = ""
            qualityCodec = nil
        }
        updateDisplayedArtwork()
        updateNowPlayingCommandAvailability()
        updateNowPlayingInfo()
    }

    private func updateDeviceLabel() {
        if activeTarget == .ios {
            deviceLabel = "Local (\(localDeviceName))"
        } else {
            let remoteName = remoteDeviceName ?? "Remote"
            deviceLabel = "Remote (\(remoteName))"
        }
    }

    private func displayNameForPeer(_ name: String) -> String {
        let prefixes = ["MiniPlayer-", "MiniPlayerRemote-"]
        for prefix in prefixes where name.hasPrefix(prefix) {
            return String(name.dropFirst(prefix.count))
        }
        return name
    }

    private func updateDisplayedArtwork() {
        let image = (activeTarget == .mac) ? remoteArtworkImage : localArtworkImage
        displayArtworkImage = image
        let key = (activeTarget == .mac) ? (remoteTrackKey ?? "") : (lastTrackKey ?? "")
        updateBackgroundColor(image: image, key: key)
        if activeTarget == .mac {
            requestRemoteArtworkIfNeeded()
        }
    }

    private func requestRemoteArtworkIfNeeded() {
        guard isRemoteAvailable else { return }
        guard remoteArtworkImage == nil else { return }
        let key = remoteTrackKey ?? ""
        guard !key.isEmpty else { return }
        let now = Date()
        if lastArtworkRequestKey == key,
           let lastDate = lastArtworkRequestDate,
           now.timeIntervalSince(lastDate) < 2.0 {
            return
        }
        lastArtworkRequestKey = key
        lastArtworkRequestDate = now
        sendArtworkRequest(size: remoteArtworkRequestSize)
    }

    func updateRemoteArtworkRequestSize(width: CGFloat, height: CGFloat) {
        let maxSide = max(width, height)
        guard maxSide > 0 else { return }
        let scale = UIScreen.main.scale
        let pixels = Int(maxSide * scale)
        if remoteArtworkRequestSize != pixels {
            remoteArtworkRequestSize = pixels
            if activeTarget == .mac {
                requestRemoteArtworkIfNeeded()
            }
        }
    }

    private func currentArtworkBase64() -> String? {
        guard let item = player.nowPlayingItem else { return nil }
        let signature = "\(item.persistentID)-\(Int(artworkTargetSize))"
        if signature == lastArtworkSignature, let cached = lastArtworkBase64 {
            return cached
        }
        guard let artwork = item.artwork else { return nil }
        let size = CGSize(width: artworkTargetSize, height: artworkTargetSize)
        guard let image = artwork.image(at: size) else { return nil }
        guard let jpeg = image.jpegData(compressionQuality: 0.8) else { return nil }
        let encoded = jpeg.base64EncodedString()
        lastArtworkSignature = signature
        lastArtworkBase64 = encoded
        return encoded
    }

    private func clearArtworkCache() {
        lastArtworkSignature = nil
        lastArtworkBase64 = nil
        lastArtworkSentKey = nil
    }

    private func updateArtworkImage(_ item: MPMediaItem?) {
        guard let artwork = item?.artwork else {
            localArtworkImage = nil
            updateDisplayedArtwork()
            return
        }
        let size = CGSize(width: artworkTargetSize, height: artworkTargetSize)
        if let image = artwork.image(at: size) {
            localArtworkImage = image
            updateDisplayedArtwork()
        }
    }

    private func updateBackgroundColor(image: UIImage?, key: String) {
        guard !key.isEmpty else {
            backgroundColor = .systemBackground
            isDarkBackground = false
            return
        }
        guard let image else { return }
        guard lastColorKey != key else { return }
        lastColorKey = key
        ArtworkColorProcessor.shared.process(image: image, key: key) { [weak self] color, isDark in
            guard let self else { return }
            if let color {
                self.backgroundColor = color
                self.isDarkBackground = isDark
            }
        }
    }

    private func applyRemoteQuality(label: String, codec: QualityCodec?) {
        qualityLabel = label
        qualityCodec = codec
        updateDisplayedState()
    }

    private func currentPlaybackSeconds() -> Double {
        let direct = player.currentPlaybackTime
        if direct > 0 {
            return direct
        }
        if let info = MPNowPlayingInfoCenter.default().nowPlayingInfo,
           let elapsed = info[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double {
            return elapsed
        }
        return 0
    }

    private func currentVolumeLevel() -> Double {
        let output = Double(volumeSlider?.value ?? AVAudioSession.sharedInstance().outputVolume)
#if DEBUG
        print("volume/outputVolume:", output)
#endif
        return output
    }

    private func sendPairingReset() {
        debugLog("remote/send pairing reset")
        let message = PairingMessage(kind: "pairing", action: "reset")
        guard let data = try? JSONEncoder().encode(message) else { return }
        try? session.send(data, toPeers: session.connectedPeers, with: .reliable)
    }

    private func updatePlaybackTimer() {
        playbackTimer?.invalidate()
        playbackTimer = nil
        guard player.playbackState == .playing else { return }
        playbackTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.refreshState()
            self.broadcastState()
        }
        RunLoop.main.add(playbackTimer!, forMode: .common)
    }

    private func updateNowPlayingInfo() {
        if player.playbackState == .playing {
            stopSilentPlayback()
            clearNowPlayingInfo()
            return
        }

        guard activeTarget == .mac,
              isRemoteAvailable,
              let remoteState else {
            stopSilentPlayback()
            clearNowPlayingInfo()
            return
        }

        ensureNowPlayingSessionActive()
        if remoteState.isPlaying {
            startSilentPlaybackIfNeeded()
        } else {
            stopSilentPlayback()
        }
        let deviceName = remoteDeviceName ?? "Remote Device"
        let titleLabel: String
        if remoteState.artistName.isEmpty {
            titleLabel = remoteState.songTitle
        } else {
            titleLabel = "\(remoteState.songTitle) - \(remoteState.artistName)"
        }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: titleLabel,
            MPMediaItemPropertyArtist: "Playing on \(deviceName)",
            MPMediaItemPropertyAlbumTitle: remoteState.albumName,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: remoteState.positionSeconds,
            MPMediaItemPropertyPlaybackDuration: remoteState.durationSeconds,
            MPNowPlayingInfoPropertyPlaybackRate: remoteState.isPlaying ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyIsLiveStream: false
        ]
        if let image = remoteArtworkImage {
            let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
            info[MPMediaItemPropertyArtwork] = artwork
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func clearNowPlayingInfo() {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        stopSilentPlayback()
        deactivateNowPlayingSession()
    }

    private func ensureNowPlayingSessionActive() {
        guard !nowPlayingSessionActive else { return }
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .default, options: [])
            try session.setActive(true, options: [])
            nowPlayingSessionActive = true
        } catch {
            nowPlayingSessionActive = false
        }
    }

    private func deactivateNowPlayingSession() {
        guard nowPlayingSessionActive else { return }
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setActive(false, options: [])
        } catch {
        }
        nowPlayingSessionActive = false
    }

    private func startSilentPlaybackIfNeeded() {
        if silentPlayer == nil {
            guard let url = Bundle.main.url(forResource: "silence", withExtension: "mp3") else { return }
            do {
                silentPlayer = try AVAudioPlayer(contentsOf: url)
            } catch {
                silentPlayer = nil
                return
            }
            silentPlayer?.numberOfLoops = -1
            silentPlayer?.volume = 0.0
            silentPlayer?.prepareToPlay()
        }
        silentPlayer?.play()
    }

    private func stopSilentPlayback() {
        silentPlayer?.stop()
        silentPlayer = nil
    }

    private func configureNowPlayingCommands() {
        commandCenter.playCommand.addTarget { [weak self] _ in
            guard let self, self.isRemoteAvailable, self.activeTarget == .mac else { return .commandFailed }
            self.sendCommand(.play)
            return .success
        }
        commandCenter.pauseCommand.addTarget { [weak self] _ in
            guard let self, self.isRemoteAvailable, self.activeTarget == .mac else { return .commandFailed }
            self.sendCommand(.pause)
            return .success
        }
        commandCenter.nextTrackCommand.addTarget { [weak self] _ in
            guard let self, self.isRemoteAvailable, self.activeTarget == .mac else { return .commandFailed }
            self.sendCommand(.next)
            return .success
        }
        commandCenter.previousTrackCommand.addTarget { [weak self] _ in
            guard let self, self.isRemoteAvailable, self.activeTarget == .mac else { return .commandFailed }
            self.sendCommand(.prev)
            return .success
        }
        commandCenter.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let self,
                  self.isRemoteAvailable,
                  self.activeTarget == .mac,
                  let event = event as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }
            self.sendControl(volume: nil, seekSeconds: event.positionTime)
            return .success
        }
    }

    private func updateNowPlayingCommandAvailability() {
        let enabled = isRemoteAvailable && activeTarget == .mac
        commandCenter.playCommand.isEnabled = enabled
        commandCenter.pauseCommand.isEnabled = enabled
        commandCenter.nextTrackCommand.isEnabled = enabled
        commandCenter.previousTrackCommand.isEnabled = enabled
        commandCenter.changePlaybackPositionCommand.isEnabled = enabled
    }

    private func mapRepeatMode(_ mode: MPMusicRepeatMode) -> Int {
        switch mode {
        case .none:
            return 0
        case .one:
            return 2
        case .all:
            return 1
        @unknown default:
            return 0
        }
    }

}

extension MusicAgentController: MCSessionDelegate {
    func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        DispatchQueue.main.async { [weak self] in
            switch state {
            case .connected:
                debugLog("remote/session connected:", peerID.displayName)
                self?.status = "Connected to \(peerID.displayName)"
                self?.connectionStatus = "Connected"
                self?.isConnecting = false
                self?.connectTimedOut = false
                self?.isRemoteAvailable = true
                self?.remoteDeviceName = self?.displayNameForPeer(peerID.displayName)
                self?.refreshState()
                self?.broadcastState()
                self?.startHeartbeat()
                if self?.preferredDevice == .remote {
                    self?.setActiveTarget(.mac, send: true)
                    self?.sendStateRequest()
                    self?.sendArtworkRequest(size: self?.remoteArtworkRequestSize)
                    self?.sendQualityRequest()
                }
            case .connecting:
                debugLog("remote/session connecting:", peerID.displayName)
                self?.status = "Connecting to \(peerID.displayName)..."
                self?.connectionStatus = "Connecting"
                self?.isConnecting = true
                self?.connectTimedOut = false
            case .notConnected:
                debugLog("remote/session notConnected:", peerID.displayName)
                self?.status = "Disconnected"
                self?.connectionStatus = "Disconnected"
                self?.isConnecting = false
                self?.isRemoteAvailable = false
                self?.connectTimedOut = false
                self?.deviceLabel = "Local"
                self?.remoteDeviceName = nil
                self?.qualityLabel = ""
                self?.qualityCodec = nil
                self?.clearNowPlayingInfo()
                self?.updateNowPlayingCommandAvailability()
                self?.stopHeartbeat()
                if session.connectedPeers.isEmpty {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        self?.rebuildSession()
                    }
                }
            @unknown default:
                self?.status = "Unknown session state"
            }
        }
    }

    func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        if let message = try? JSONDecoder().decode(CommandMessage.self, from: data), message.kind == "command" {
            DispatchQueue.main.async { [weak self] in
                self?.handleCommand(message.command)
            }
            return
        }
        if let config = try? JSONDecoder().decode(ConfigMessage.self, from: data), config.kind == "config" {
            DispatchQueue.main.async { [weak self] in
                self?.artworkTargetSize = CGFloat(config.artworkSize)
                self?.lastArtworkSignature = nil
                self?.lastArtworkSentKey = nil
                self?.broadcastState(includeArtwork: true)
            }
            return
        }
        if let control = try? JSONDecoder().decode(ControlMessage.self, from: data), control.kind == "control" {
            DispatchQueue.main.async { [weak self] in
                self?.handleControl(volume: control.volume, seekSeconds: control.seekSeconds)
            }
            return
        }
        if let device = try? JSONDecoder().decode(DeviceMessage.self, from: data),
           device.kind == "device" {
            DispatchQueue.main.async { [weak self] in
                self?.setActiveTarget(device.target, send: false)
                if device.target == .ios {
                    self?.refreshState()
                    self?.broadcastState(includeArtwork: true)
                }
            }
            return
        }
        if let request = try? JSONDecoder().decode(ArtworkRequestMessage.self, from: data),
           request.kind == "artworkRequest" {
            DispatchQueue.main.async { [weak self] in
                self?.broadcastState(includeArtwork: true)
            }
            return
        }
        if let remoteState = try? JSONDecoder().decode(RemoteStateMessage.self, from: data),
           remoteState.kind == "remoteState" {
            let state = remoteState.state
            let incomingKey = "\(state.songTitle)|\(state.artistName)|\(state.albumName)"
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                let trackChanged = incomingKey != self.remoteTrackKey
                self.remoteTrackKey = incomingKey
                self.remoteState = state
                if trackChanged, state.artworkBase64 == nil {
                    self.remoteArtworkImage = nil
                }
                if trackChanged, self.activeTarget == .mac {
                    self.sendArtworkRequest(size: self.remoteArtworkRequestSize)
                }
                self.updateDisplayedState()
            }

            if let base64 = state.artworkBase64 {
                DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                    guard let imageData = Data(base64Encoded: base64),
                          let image = UIImage(data: imageData) else {
                        return
                    }
                    DispatchQueue.main.async {
                        guard let self else { return }
                        guard self.remoteTrackKey == incomingKey else { return }
                        self.remoteArtworkImage = image
                        self.updateDisplayedState()
                    }
                }
            }
            return
        }
        if let info = try? JSONDecoder().decode(DeviceInfoMessage.self, from: data),
           info.kind == "deviceInfo" {
            DispatchQueue.main.async { [weak self] in
                self?.remoteDeviceName = info.name
                self?.updateDeviceLabel()
            }
            return
        }
        if let pairing = try? JSONDecoder().decode(PairingMessage.self, from: data),
           pairing.kind == "pairing",
           pairing.action == "reset" {
            DispatchQueue.main.async { [weak self] in
                self?.resetPairing(sendToPeer: false)
            }
            return
        }
        if let quality = try? JSONDecoder().decode(QualityMessage.self, from: data),
           quality.kind == "quality" {
            DispatchQueue.main.async { [weak self] in
                let codec = quality.codec.flatMap { QualityCodec(rawValue: $0) }
                self?.applyRemoteQuality(label: quality.label, codec: codec)
            }
            return
        }
        if let heartbeat = try? JSONDecoder().decode(HeartbeatMessage.self, from: data),
           heartbeat.kind == "heartbeat" {
            DispatchQueue.main.async { [weak self] in
                self?.noteHeartbeat()
            }
            if heartbeat.type == "ping" {
                debugLog("remote/receive heartbeat ping from:", peerID.displayName)
                let pong = HeartbeatMessage(kind: "heartbeat", type: "pong")
                if let pongData = try? JSONEncoder().encode(pong) {
                    try? session.send(pongData, toPeers: session.connectedPeers, with: .unreliable)
                }
            }
        }
    }

    func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {}
    func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, with progress: Progress) {}
    func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {}
}

private extension MusicAgentController {
    func setSystemVolume(_ value: Double) {
        let clamped = max(0.0, min(1.0, value))
        guard let slider = volumeSlider ?? (volumeView.subviews.first(where: { $0 is UISlider }) as? UISlider) else {
            return
        }
        slider.value = Float(clamped)
        slider.sendActions(for: .valueChanged)
#if DEBUG
        print("volume/setSystemVolume:", clamped)
#endif
    }
}

extension MusicAgentController: MCNearbyServiceAdvertiserDelegate {
    func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didReceiveInvitationFromPeer peerID: MCPeerID, withContext context: Data?, invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        debugLog("remote/receive invite:", peerID.displayName)
        if isPaired, isKnownPeer(peerID) {
            debugLog("remote/invite accept (paired):", peerID.displayName)
            invitationHandler(true, session)
            return
        }
        let code = context.flatMap { String(data: $0, encoding: .utf8) }
        debugLog("remote/invite code:", code ?? "nil")
        if !isPaired, let code, code == pairingCode {
            debugLog("remote/invite accept (code):", peerID.displayName)
            savePairedPeer(peerID)
            invitationHandler(true, session)
        } else {
            debugLog("remote/invite reject:", peerID.displayName)
            invitationHandler(false, nil)
        }
    }

    func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didNotStartAdvertisingPeer error: Error) {
        DispatchQueue.main.async { [weak self] in
            self?.status = "Advertise error: \(error.localizedDescription)"
        }
    }
}
