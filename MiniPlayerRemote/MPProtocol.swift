import Foundation

enum RemoteCommand: String, Codable {
    case play
    case pause
    case next
    case prev
    case toggleShuffle
    case cycleRepeat
}

struct PlaybackState: Codable, Equatable {
    var isPlaying: Bool
    var songTitle: String
    var artistName: String
    var albumName: String
    var positionSeconds: Double
    var durationSeconds: Double
    var artworkBase64: String?
    var volumeLevel: Double
    var shuffleEnabled: Bool?
    var repeatMode: Int?
}

struct CommandMessage: Codable {
    let kind: String
    let command: RemoteCommand
}

struct StateMessage: Codable {
    let kind: String
    let state: PlaybackState
}

struct ConfigMessage: Codable {
    let kind: String
    let artworkSize: Int
}

struct ControlMessage: Codable {
    let kind: String
    let volume: Double?
    let seekSeconds: Double?
}

struct PairingMessage: Codable {
    let kind: String
    let action: String
}

struct HeartbeatMessage: Codable {
    let kind: String
    let type: String
}

struct QualityMessage: Codable {
    let kind: String
    let label: String
    let codec: String?
}

struct QualityRequestMessage: Codable {
    let kind: String
}

enum PlaybackTarget: String, Codable {
    case mac
    case ios
}

struct DeviceMessage: Codable {
    let kind: String
    let target: PlaybackTarget
}

struct RemoteStateMessage: Codable {
    let kind: String
    let state: PlaybackState
}

struct ArtworkRequestMessage: Codable {
    let kind: String
    let size: Int?
}

struct StateRequestMessage: Codable {
    let kind: String
}

struct DeviceInfoMessage: Codable {
    let kind: String
    let name: String
}

enum MPEnvelope {
    static let serviceType = "music-remote"
}
