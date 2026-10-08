import SwiftUI
import Photos
import PhotosUI
import AVFoundation

@MainActor
final class MediaLoader: ObservableObject {
    @Published var image: UIImage?
    @Published var livePhoto: PHLivePhoto?
    @Published var player: AVPlayer?
    @Published var unavailable = false
    @Published var progress: Double = 0
    @Published var muted = true
    private var requests: [PHImageRequestID] = []
    private var manager: PHImageManager?
    private var loopObserver: NSObjectProtocol?
    private var timeObserver: Any?
    private var generation = UUID()
    private var active = true

    func load(asset: PHAsset?, id: String, manager: PHImageManager, thumbnail: Bool = false) {
        stop()
        self.manager = manager
        let token = generation
        if id.hasPrefix("demo-") {
            image = Self.demoImage(id: id)
            return
        }
        guard let asset else { unavailable = true; return }
        let size = thumbnail ? CGSize(width: 300, height: 300) : CGSize(width: 1200, height: 1800)
        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = false
        options.deliveryMode = .opportunistic
        requests.append(manager.requestImage(for: asset, targetSize: size, contentMode: .aspectFit, options: options) { [weak self] image, info in
            Task { @MainActor in
                guard let self, self.generation == token else { return }
                if let image { self.image = image }
                if image == nil, (info?[PHImageResultIsDegradedKey] as? Bool) != true { self.unavailable = true }
            }
        })
        guard !thumbnail else { return }
        if asset.mediaType == .video {
            let options = PHVideoRequestOptions(); options.isNetworkAccessAllowed = false
            requests.append(manager.requestPlayerItem(forVideo: asset, options: options) { [weak self] item, _ in
                Task { @MainActor in
                    guard let self, self.generation == token else { return }
                    guard let item else { self.unavailable = true; return }
                    let player = AVPlayer(playerItem: item)
                    player.isMuted = true
                    self.player = player
                    self.loopObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self, weak player] _ in
                        Task { @MainActor in
                            guard let self, self.generation == token, self.active else { return }
                            player?.seek(to: .zero); player?.play()
                        }
                    }
                    self.timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.1, preferredTimescale: 600), queue: .main) { [weak self] time in
                        Task { @MainActor in
                            guard let self, self.generation == token else { return }
                            let duration = item.duration.seconds
                            self.progress = duration.isFinite && duration > 0 ? time.seconds / duration : 0
                        }
                    }
                    if self.active { player.play() }
                }
            })
        } else if asset.mediaSubtypes.contains(.photoLive) {
            let options = PHLivePhotoRequestOptions(); options.isNetworkAccessAllowed = false
            requests.append(manager.requestLivePhoto(for: asset, targetSize: size, contentMode: .aspectFit, options: options) { [weak self] live, _ in
                Task { @MainActor in
                    guard let self, self.generation == token else { return }
                    self.livePhoto = live
                }
            })
        }
    }
    func setActive(_ active: Bool) { self.active = active; active ? player?.play() : player?.pause() }
    func toggleMute() { muted.toggle(); player?.isMuted = muted }
    func stop() {
        generation = UUID()
        requests.forEach { manager?.cancelImageRequest($0) }; requests = []
        player?.pause()
        if let timeObserver { player?.removeTimeObserver(timeObserver) }
        timeObserver = nil
        if let loopObserver { NotificationCenter.default.removeObserver(loopObserver) }
        loopObserver = nil
        player = nil; image = nil; livePhoto = nil; unavailable = false; progress = 0; muted = true
    }
    static func demoImage(id: String) -> UIImage {
        let index = Int(id.split(separator: "-").last ?? "0") ?? 0
        let colors: [(UIColor, UIColor)] = [(.init(red: 0.24, green: 0.40, blue: 0.40, alpha: 1), .init(red: 0.72, green: 0.58, blue: 0.40, alpha: 1)), (.init(red: 0.16, green: 0.23, blue: 0.35, alpha: 1), .init(red: 0.73, green: 0.38, blue: 0.30, alpha: 1)), (.init(red: 0.33, green: 0.40, blue: 0.30, alpha: 1), .init(red: 0.81, green: 0.75, blue: 0.54, alpha: 1))]
        return UIGraphicsImageRenderer(size: CGSize(width: 800, height: 1100)).image { context in
            let ctx = context.cgContext
            let pair = colors[index % colors.count]
            let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [pair.0.cgColor, pair.1.cgColor] as CFArray, locations: [0, 1])!
            ctx.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 800, y: 1100), options: [])
            UIColor.white.withAlphaComponent(0.3).setFill()
            ctx.fillEllipse(in: CGRect(x: 480, y: 190, width: 140, height: 140))
            for layer in 0..<4 {
                let path = UIBezierPath()
                path.move(to: CGPoint(x: 0, y: 580 + layer * 110))
                path.addCurve(to: CGPoint(x: 800, y: 570 + layer * 120), controlPoint1: CGPoint(x: 300, y: 350 + layer * 130), controlPoint2: CGPoint(x: 400, y: 850 + layer * 40))
                path.addLine(to: CGPoint(x: 800, y: 1100)); path.addLine(to: CGPoint(x: 0, y: 1100)); path.close()
                pair.0.withAlphaComponent(CGFloat(0.35 + Double(layer) * 0.14)).setFill(); path.fill()
            }
        }
    }
}

struct LivePhotoSurface: UIViewRepresentable {
    let photo: PHLivePhoto
    let active: Bool
    func makeUIView(context: Context) -> PHLivePhotoView {
        let view = PHLivePhotoView(); view.contentMode = .scaleAspectFit; view.isMuted = true
        return view
    }
    func updateUIView(_ view: PHLivePhotoView, context: Context) {
        let changed = view.livePhoto !== photo
        view.livePhoto = photo
        if !active { context.coordinator.work?.cancel(); view.stopPlayback() }
        else if changed || !context.coordinator.wasActive {
            context.coordinator.work?.cancel()
            let work = DispatchWorkItem { [weak view] in view?.startPlayback(with: .full) }
            context.coordinator.work = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
        }
        context.coordinator.wasActive = active
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    static func dismantleUIView(_ view: PHLivePhotoView, coordinator: Coordinator) { coordinator.work?.cancel(); view.stopPlayback() }
    final class Coordinator { var wasActive = false; var work: DispatchWorkItem? }
}

struct PlayerSurface: UIViewRepresentable {
    let player: AVPlayer
    func makeUIView(context: Context) -> PlayerUIView { let view = PlayerUIView(); view.playerLayer.videoGravity = .resizeAspect; return view }
    func updateUIView(_ view: PlayerUIView, context: Context) { view.playerLayer.player = player }
    final class PlayerUIView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }
}
