import SwiftUI
import Photos
import UIKit

struct AlbumOption: Identifiable {
    let id: String
    let title: String
    let collection: PHAssetCollection?
}

@MainActor
final class PhotoLibraryStore: NSObject, ObservableObject, PHPhotoLibraryChangeObserver {
    @Published var authorization = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    @Published var loading = false
    @Published var engine = ReviewEngine(records: [])
    @Published var filter: MediaFilter = .all
    @Published var albums = [AlbumOption(id: "all", title: "全部相册", collection: nil)]
    @Published var albumID = "all"
    @Published var error: String?
    @Published var deleting = false
    @Published var sizes: [String: Int64] = [:]
    @Published var unknownSizes: Set<String> = []
    @Published var measuring: Set<String> = []
    @Published var notice: String?
    @Published private(set) var timelineRecords: [MediaRecord] = []
    @Published private(set) var timelineSections: [TimelineSection] = []
    let images = PHCachingImageManager()
    let demo = ProcessInfo.processInfo.arguments.contains("-demo")
    private var chronologicalAlbum = ChronologicalAlbum(records: [])
    private var assets: [String: PHAsset] = [:]
    private var records: [MediaRecord] = []
    private var cached: [PHAsset] = []
    private var refreshID = UUID()
    private var sizeQueue: [String] = []
    private var sizeTasks: [String: Task<Void, Never>] = [:]
    private var persistenceTask: Task<Void, Never>?
    private var lastViewed: [String: Date] = [:]
    private let cacheSize = CGSize(width: 1200, height: 1800)

    override init() {
        super.init()
        if let saved = UserDefaults.standard.dictionary(forKey: "lastViewed") as? [String: Double] {
            lastViewed = saved.mapValues { Date(timeIntervalSince1970: $0) }
        }
        if demo {
            authorization = .authorized
            records = (0..<12).map { MediaRecord(id: "demo-\($0)", creationDate: Calendar.current.date(byAdding: .year, value: -($0 % 5 + 1), to: Date()), isVideo: false) }
            rebuild()
            updateTimeline()
        } else {
            PHPhotoLibrary.shared().register(self)
        }
    }
    deinit { PHPhotoLibrary.shared().unregisterChangeObserver(self) }
    var accessible: Bool { authorization == .authorized || authorization == .limited }
    var currentAsset: PHAsset? { engine.current.flatMap { assets[$0.id] } }
    var markedRecords: [MediaRecord] { records.filter { engine.markedIDs.contains($0.id) } }
    var totalBytes: Int64 { engine.markedIDs.reduce(0) { $0 + (sizes[$1] ?? 0) } }
    var sizePending: Bool { !engine.markedIDs.isDisjoint(with: measuring) }
    var sizeIncomplete: Bool { !engine.markedIDs.isDisjoint(with: unknownSizes) }
    func asset(for id: String) -> PHAsset? { assets[id] }

    func requestPermission() async {
        authorization = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        await refresh()
    }
    func activate() async {
        guard !demo else { return }
        authorization = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if accessible { await refresh() }
        else { records = []; assets = [:]; rebuild(); updateTimeline() }
    }
    nonisolated func photoLibraryDidChange(_ changeInstance: PHChange) {
        Task { @MainActor [weak self] in await self?.activate() }
    }
    func refresh() async {
        guard accessible, !demo else { return }
        loading = true
        let token = UUID(); refreshID = token
        let collection = albums.first(where: { $0.id == albumID })?.collection
        let result = await Task.detached(priority: .userInitiated) { () -> ([PHAsset], [AlbumOption]) in
            let options = PHFetchOptions()
            options.predicate = NSPredicate(format: "mediaType == %d OR mediaType == %d", PHAssetMediaType.image.rawValue, PHAssetMediaType.video.rawValue)
            let fetch = collection.map { PHAsset.fetchAssets(in: $0, options: options) } ?? PHAsset.fetchAssets(with: options)
            var items: [PHAsset] = []
            fetch.enumerateObjects { asset, _, _ in items.append(asset) }
            var groups = [AlbumOption(id: "all", title: "全部相册", collection: nil)]
            for type in [PHAssetCollectionType.smartAlbum, .album] {
                PHAssetCollection.fetchAssetCollections(with: type, subtype: .any, options: nil).enumerateObjects { album, _, _ in
                    groups.append(AlbumOption(id: album.localIdentifier, title: album.localizedTitle ?? "相册", collection: album))
                }
            }
            return (items, groups)
        }.value
        guard refreshID == token else { return }
        assets = Dictionary(uniqueKeysWithValues: result.0.map { ($0.localIdentifier, $0) })
        records = result.0.map { MediaRecord(id: $0.localIdentifier, creationDate: $0.creationDate, isVideo: $0.mediaType == .video) }
        albums = result.1
        updateTimeline()
        // Keep session marks across permission/library updates; unavailable assets are removed.
        engine.reconcile(records: records)
        updateCache()
        loading = false
    }
    func setFilter(_ value: MediaFilter) {
        let marks = engine.markedIDs
        filter = value
        rebuild(preserving: marks)
    }
    func selectAlbum(_ id: String) async {
        guard id != albumID else { return }
        albumID = id
        engine = ReviewEngine(records: [], filter: filter)
        // Album changes start a fresh scope after the UI has settled existing marks.
        await refresh()
    }
    private func rebuild(preserving marked: Set<String> = []) {
        engine = ReviewEngine(records: records, filter: filter, lastViewed: lastViewed)
        // Session selections may belong to a different filter, so maintain them separately in the engine.
        engine.restoreMarks(marked.intersection(Set(records.map(\.id))))
        updateCache()
    }
    func advance(mark: Bool) {
        guard let current = engine.current else { return }
        lastViewed[current.id] = Date()
        engine.advance(mark: mark)
        UIImpactFeedbackGenerator(style: mark ? .medium : .light).impactOccurred()
        if mark { measure(current.id) }
        updateCache()
        persistViewed()
    }
    func previous() {
        guard engine.canGoBack else { return }
        engine.previous()
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        updateCache()
    }
    func mark(_ id: String) {
        engine.mark(id: id)
        guard engine.markedIDs.contains(id) else { return }
        measure(id)
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }
    func timelineSectionID(containing id: String) -> String? { chronologicalAlbum.sectionID(containing: id) }
    private func updateTimeline() {
        let album = ChronologicalAlbum(records: records)
        guard album.records != timelineRecords else { return }
        chronologicalAlbum = album
        timelineRecords = album.records
        timelineSections = album.sections
    }
    func undo() {
        engine.undo()
        discardUnmarkedMeasurements()
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        updateCache()
    }
    func unmark(_ id: String) {
        engine.unmark(id: id)
        sizeQueue.removeAll { $0 == id }
        if sizeTasks[id] == nil { measuring.remove(id) }
    }
    func keepAll() {
        engine.keepAll()
        for id in sizeQueue { measuring.remove(id) }
        sizeQueue.removeAll()
        notice = "已全部保留，继续慢慢回顾"
    }
    func restart() { rebuild(preserving: engine.markedIDs) }
    func updateCache() {
        images.stopCachingImages(for: cached, targetSize: cacheSize, contentMode: .aspectFit, options: nil)
        cached = engine.upcoming.compactMap { assets[$0.id] }
        let options = PHImageRequestOptions(); options.isNetworkAccessAllowed = false
        images.startCachingImages(for: cached, targetSize: cacheSize, contentMode: .aspectFit, options: options)
    }
    private func persistViewed() {
        guard !demo else { return }
        persistenceTask?.cancel()
        persistenceTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(1)) } catch { return }
            self?.flushViewed()
        }
    }
    func flushViewed() {
        guard !demo else { return }
        persistenceTask?.cancel()
        if lastViewed.count > 5000 {
            lastViewed = Dictionary(uniqueKeysWithValues: lastViewed.sorted { $0.value > $1.value }.prefix(5000).map { ($0.key, $0.value) })
        }
        UserDefaults.standard.set(lastViewed.mapValues { $0.timeIntervalSince1970 }, forKey: "lastViewed")
    }
    func manageLimitedAccess() {
        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              var controller = scene.windows.first(where: \.isKeyWindow)?.rootViewController else { return }
        while let presented = controller.presentedViewController { controller = presented }
        PHPhotoLibrary.shared().presentLimitedLibraryPicker(from: controller)
    }
    func deleteMarked() async -> Bool {
        guard !deleting, !engine.markedIDs.isEmpty else { return false }
        deleting = true; defer { deleting = false }
        let ids = engine.markedIDs
        if demo {
            records.removeAll { ids.contains($0.id) }; engine.remove(ids: ids)
            updateTimeline()
            notice = "演示清理完成（未操作真实相册）"
            return true
        }
        let toDelete = ids.compactMap { assets[$0] }
        guard toDelete.count == ids.count else {
            error = "部分照片已不可访问，请刷新相册后重试。"; return false
        }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.deleteAssets(toDelete as NSArray)
            }
            engine.remove(ids: ids)
            records.removeAll { ids.contains($0.id) }
            ids.forEach { assets.removeValue(forKey: $0) }
            updateTimeline()
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            notice = "已移入「最近删除」，可在系统相册中恢复"
            updateCache()
            return true
        } catch {
            self.error = "清理未完成，所有标记已保留。\n\(error.localizedDescription)"
            return false
        }
    }
    private func measure(_ id: String) {
        guard sizes[id] == nil, !measuring.contains(id) else { return }
        if demo { sizes[id] = Int64(2_500_000 + (Int(id.split(separator: "-").last ?? "0") ?? 0) * 320_000); return }
        guard assets[id] != nil else { return }
        measuring.insert(id)
        sizeQueue.append(id)
        startMeasurements()
    }
    private func discardUnmarkedMeasurements() {
        let discarded = sizeQueue.filter { !engine.markedIDs.contains($0) }
        sizeQueue.removeAll { !engine.markedIDs.contains($0) }
        for id in discarded { measuring.remove(id) }
    }
    private func startMeasurements() {
        while sizeTasks.count < 2, !sizeQueue.isEmpty {
            let id = sizeQueue.removeFirst()
            guard let asset = assets[id] else { measuring.remove(id); continue }
            sizeTasks[id] = Task { [weak self] in
                var total: Int64 = 0
                var failed = false
                // Stream local resources without retaining their contents or downloading iCloud data.
                for resource in PHAssetResource.assetResources(for: asset) {
                    let outcome = await Self.resourceBytes(resource)
                    if let bytes = outcome { total += bytes } else { failed = true }
                    if Task.isCancelled { break }
                }
                guard let self else { return }
                self.measuring.remove(id)
                if failed { self.unknownSizes.insert(id) }
                else { self.sizes[id] = total }
                self.sizeTasks.removeValue(forKey: id)
                self.startMeasurements()
            }
        }
    }
    nonisolated private static func resourceBytes(_ resource: PHAssetResource) async -> Int64? {
        await withCheckedContinuation { continuation in
            let counter = ByteCounter()
            let options = PHAssetResourceRequestOptions(); options.isNetworkAccessAllowed = false
            PHAssetResourceManager.default().requestData(for: resource, options: options) { data in
                counter.add(data.count)
            } completionHandler: { error in
                continuation.resume(returning: error == nil ? counter.value : nil)
            }
        }
    }
}

private final class ByteCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes: Int64 = 0
    func add(_ count: Int) { lock.lock(); bytes += Int64(count); lock.unlock() }
    var value: Int64 { lock.lock(); defer { lock.unlock() }; return bytes }
}
