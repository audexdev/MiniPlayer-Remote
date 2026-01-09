import SwiftUI

struct ContentView: View {
    @EnvironmentObject var controller: MusicAgentController
    @EnvironmentObject var locationKeeper: LocationKeeper

    @State private var seekValue: Double = 0
    @State private var isSeeking: Bool = false
    @State private var volumeValue: Double = 0
    @State private var isDraggingVolume: Bool = false

    var body: some View {
        GeometryReader { geo in
            let availableWidth = max(0, geo.size.width - 40)
            let textColors = readableTextColors(for: controller.backgroundColor)
            let primaryText = textColors.primary
            let secondaryText = textColors.secondary
            let artworkHeightValue = artworkHeight(for: availableWidth)

            ZStack {
                Color(uiColor: controller.backgroundColor)
                    .ignoresSafeArea()

                VStack(spacing: 12) {
                    headerRow

                    artworkView(width: availableWidth)

                    VStack(spacing: 6) {
                        MarqueeText(
                            text: controller.lastState.songTitle.isEmpty ? "-" : controller.lastState.songTitle,
                            font: UIFont.systemFont(ofSize: 16, weight: .semibold),
                            leftFade: 16,
                            rightFade: 16,
                            startDelay: 3,
                            alignment: .center
                        )
                        .foregroundStyle(primaryText)

                        MarqueeText(
                            text: trackSubtitle,
                            font: UIFont.systemFont(ofSize: 13, weight: .light),
                            leftFade: 16,
                            rightFade: 16,
                            startDelay: 3,
                            alignment: .center
                        )
                        .foregroundStyle(secondaryText)
                    }

                progressSection

                qualityRow

                controlsRow

                volumeSection
            }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .onAppear {
                    controller.updateRemoteArtworkRequestSize(width: availableWidth, height: artworkHeightValue)
                }
                .onChange(of: availableWidth) { _ in
                    controller.updateRemoteArtworkRequestSize(width: availableWidth, height: artworkHeightValue)
                }
                .onChange(of: controller.displayArtworkImage?.size.width ?? 0) { _ in
                    controller.updateRemoteArtworkRequestSize(width: availableWidth, height: artworkHeightValue)
                }
            }
        }
        .onAppear {
            locationKeeper.start()
            seekValue = controller.lastState.positionSeconds
            volumeValue = controller.lastState.volumeLevel * 100
        }
        .onReceive(controller.$lastState) { state in
            guard !isSeeking else { return }
            seekValue = state.positionSeconds
            if !isDraggingVolume {
                volumeValue = state.volumeLevel * 100
            }
        }
    }

    private var headerRow: some View {
        HStack {
            Text(controller.connectionStatus)
                .font(.caption)
                .foregroundStyle(controller.isDarkBackground ? Color.white.opacity(0.7) : Color.secondary)
                .lineLimit(1)

            Spacer()

            if controller.isPaired {
                Text("Pairing: OK")
                    .font(.caption)
                    .foregroundStyle(controller.isDarkBackground ? Color.white.opacity(0.7) : Color.secondary)
            } else {
                Text(controller.pairingCode)
                    .font(.system(size: 14, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(controller.isDarkBackground ? Color.white : Color.black)
            }

            Button("Reset") {
                controller.resetPairing()
            }
            .font(.caption)
            .buttonStyle(.borderless)
        }
    }

    private func artworkView(width: CGFloat) -> some View {
        let height = artworkHeight(for: width)
        return ZStack {
            if let image = controller.displayArtworkImage {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.gray.opacity(0.2))
                    Image(systemName: "music.note")
                        .font(.largeTitle)
                        .foregroundStyle(controller.isDarkBackground ? Color.white.opacity(0.7) : Color.secondary)
                }
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var progressSection: some View {
        VStack(spacing: 6) {
            MiniSlider(
                value: Binding(
                    get: { seekValue },
                    set: { seekValue = $0 }
                ),
                range: 0...max(controller.lastState.durationSeconds, 1),
                thumbSize: 14,
                trackHeight: 3
            ) { editing in
                isSeeking = editing
                if !editing {
                    controller.seek(to: seekValue)
                }
            }

            HStack {
                Text(formatTime(seekValue))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(controller.isDarkBackground ? Color.white.opacity(0.7) : Color.secondary)

                Spacer()

                Menu {
                    Button("Local") {
                        controller.selectDevice(.local)
                    }
                    Button("Remote") {
                        controller.selectDevice(.remote)
                    }
                    .disabled(!controller.isRemoteAvailable)
                    if !controller.isRemoteAvailable && controller.isPaired && !controller.isConnecting {
                        Button("Connect") {
                            controller.connectToPairedPeer()
                        }
                    }
                    if controller.connectTimedOut {
                        Button("Connect timed out") {}
                            .disabled(true)
                    }
                } label: {
                    Text(controller.deviceLabel)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(controller.isDarkBackground ? Color.white : Color.black)
                        .lineLimit(1)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .contentShape(Rectangle())
                }

                Spacer()
                Text(formatTime(controller.lastState.durationSeconds))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(controller.isDarkBackground ? Color.white.opacity(0.7) : Color.secondary)
            }
        }
    }

    private var controlsRow: some View {
        HStack(spacing: 18) {
            Button {
                controller.toggleShuffle()
            } label: {
                Image(systemName: "shuffle")
                    .foregroundStyle(controller.shuffleEnabled ? Color.red : Color.secondary)
            }
            Button {
                controller.prev()
            } label: {
                Image(systemName: "backward.fill")
                    .foregroundStyle(controller.isDarkBackground ? Color.white : Color.black)
            }
            Button {
                controller.togglePlayPause()
            } label: {
                Image(systemName: controller.lastState.isPlaying ? "pause.fill" : "play.fill")
                    .foregroundStyle(controller.isDarkBackground ? Color.white : Color.black)
            }
            Button {
                controller.next()
            } label: {
                Image(systemName: "forward.fill")
                    .foregroundStyle(controller.isDarkBackground ? Color.white : Color.black)
            }
            Button {
                controller.cycleRepeatMode()
            } label: {
                Image(systemName: controller.repeatMode == 2 ? "repeat.1" : "repeat")
                    .foregroundStyle(controller.repeatMode == 0 ? Color.secondary : Color.red)
            }
        }
        .font(.title2)
        .buttonStyle(.borderless)
    }

    private var volumeSection: some View {
        ZStack {
            MiniSlider(
                value: Binding(
                    get: { volumeValue },
                    set: {
                        volumeValue = $0
                        controller.setVolume($0 / 100)
                    }
                ),
                range: 0...100,
                thumbSize: 12,
                trackHeight: 3
            ) { editing in
                isDraggingVolume = editing
            }

            if isDraggingVolume {
                Text("\(Int(volumeValue))")
                    .font(.caption2)
                    .foregroundStyle(controller.isDarkBackground ? Color.white.opacity(0.9) : Color.black.opacity(0.8))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.ultraThinMaterial)
                    .cornerRadius(6)
                    .offset(y: -20)
            }
        }
    }


    private var qualityRow: some View {
            HStack(spacing: 6) {
                if controller.qualityCodec == .atmos {
                    Image("Dolby_Atmos")
                        .resizable()
                        .renderingMode(.template)
                        .foregroundStyle(controller.isDarkBackground ? Color.white.opacity(0.7) : Color.secondary)
                        .frame(width: 102.4, height: 14.4)
                } else {
                    if controller.qualityCodec == .lossless {
                        Image("Lossless")
                            .resizable()
                            .renderingMode(.template)
                            .foregroundStyle(controller.isDarkBackground ? Color.white.opacity(0.7) : Color.secondary)
                            .frame(width: 17, height: 10.2)
                    }
                    if !controller.qualityLabel.isEmpty {
                        Text(controller.qualityLabel)
                            .font(.system(size: 11, weight: .light))
                            .foregroundStyle(controller.isDarkBackground ? Color.white.opacity(0.7) : Color.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
            }
    }

    private var trackSubtitle: String {
        let artist = controller.lastState.artistName
        let album = controller.lastState.albumName
        if artist.isEmpty, album.isEmpty {
            return "-"
        }
        if album.isEmpty {
            return artist
        }
        if artist.isEmpty {
            return album
        }
        return "\(artist) - \(album)"
    }

    private func artworkHeight(for width: CGFloat) -> CGFloat {
        guard let image = controller.displayArtworkImage else { return width }
        let size = image.size
        guard size.width > 0, size.height > 0 else { return width }
        return width * (size.height / size.width)
    }
}

private func readableTextColors(for background: UIColor) -> (primary: Color, secondary: Color) {
    let white = UIColor.white
    let black = UIColor.black
    let whiteContrast = contrastRatio(between: background, and: white)
    let blackContrast = contrastRatio(between: background, and: black)
    let useWhite = whiteContrast >= blackContrast
    let primary = useWhite ? Color.white : Color.black
    let secondary = useWhite ? Color.white.opacity(0.7) : Color.black.opacity(0.65)
    return (primary, secondary)
}

private func contrastRatio(between background: UIColor, and text: UIColor) -> CGFloat {
    let l1 = relativeLuminance(of: background)
    let l2 = relativeLuminance(of: text)
    let lighter = max(l1, l2)
    let darker = min(l1, l2)
    return (lighter + 0.05) / (darker + 0.05)
}

private func relativeLuminance(of color: UIColor) -> CGFloat {
    var r: CGFloat = 0
    var g: CGFloat = 0
    var b: CGFloat = 0
    var a: CGFloat = 0
    color.getRed(&r, green: &g, blue: &b, alpha: &a)

    func linearize(_ component: CGFloat) -> CGFloat {
        if component <= 0.03928 {
            return component / 12.92
        }
        return pow((component + 0.055) / 1.055, 2.4)
    }

    let rl = linearize(r)
    let gl = linearize(g)
    let bl = linearize(b)
    return 0.2126 * rl + 0.7152 * gl + 0.0722 * bl
}

private func formatTime(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds > 0 else { return "0:00" }
    let total = Int(seconds)
    let minutes = total / 60
    let secs = total % 60
    return String(format: "%d:%02d", minutes, secs)
}
