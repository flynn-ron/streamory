import SwiftUI

/// The selected album's local chronological context, anchored to the held photo.
struct TimeTravelAlbumView: View {
    @EnvironmentObject private var library: PhotoLibraryStore
    @Environment(\.dismiss) private var dismiss
    @State private var selected: MediaRecord?
    @State private var checkout = false
    let anchorID: String
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 5), count: 4)
    private var anchor: MediaRecord? { library.timelineRecords.first { $0.id == anchorID } }
    private var albumTitle: String { library.albums.first { $0.id == library.albumID }?.title ?? "全部相册" }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button { dismiss() } label: { Label("返回随机流", systemImage: "arrow.left").font(.subheadline) }
                Spacer()
                Button { checkout = true } label: { Label("\(library.engine.markedIDs.count)", systemImage: "tray").font(.subheadline).padding(12).background(.ultraThinMaterial, in: Capsule()) }
                    .accessibilityLabel("查看 \(library.engine.markedIDs.count) 项待清理媒体")
            }.padding(.horizontal, 20).padding(.top, 10)
            VStack(alignment: .leading, spacing: 8) {
                Text("回到过去").font(.system(size: 30, weight: .light))
                Text(albumTitle + " · 时间顺序").font(.caption).foregroundStyle(.secondary)
                if let anchor {
                    Text("已定位到 " + (anchor.creationDate?.formatted(.dateTime.year().month().day().locale(Locale(identifier: "zh_CN"))) ?? "日期未知的回忆"))
                        .font(.caption).foregroundStyle(Color.streamGreen)
                } else {
                    Text("这张回忆已不在当前可访问相册中").font(.caption).foregroundStyle(.secondary)
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(20)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 22) {
                        ForEach(library.timelineSections) { section in
                            VStack(alignment: .leading, spacing: 12) {
                                Text(section.title).font(.headline).padding(.horizontal, 4)
                                LazyVGrid(columns: columns, spacing: 5) {
                                    ForEach(section.records) { record in
                                        Button { selected = record } label: {
                                            ThumbnailView(record: record)
                                                .overlay {
                                                    if record.id == anchorID { RoundedRectangle(cornerRadius: 9).stroke(Color.streamGreen, lineWidth: 3) }
                                                }
                                                .overlay(alignment: .bottomLeading) {
                                                    if record.id == anchorID {
                                                        Text("此刻的回忆").font(.system(size: 9, weight: .semibold)).padding(4).background(.black.opacity(0.7), in: Capsule()).padding(5)
                                                    }
                                                }
                                                .overlay(alignment: .topTrailing) {
                                                    if library.engine.markedIDs.contains(record.id) { Image(systemName: "trash.fill").font(.caption2).padding(6).background(Color.streamRed, in: Circle()).padding(5) }
                                                }
                                        }.buttonStyle(.plain).id(record.id)
                                            .accessibilityLabel((record.id == anchorID ? "已定位的回忆，" : "") + (record.creationDate?.formatted(.dateTime.year().month().day().locale(Locale(identifier: "zh_CN"))) ?? "日期未知") + (record.isVideo ? "，视频" : "，照片"))
                                    }
                                }
                            }.id(section.id)
                        }
                    }.padding(.horizontal, 15).padding(.bottom, 30)
                }
                .task(id: anchorID) {
                    guard let sectionID = library.timelineSectionID(containing: anchorID) else { return }
                    // Mount the month first so the nested lazy grid can register the asset's ID.
                    proxy.scrollTo(sectionID, anchor: .top)
                    do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
                    proxy.scrollTo(anchorID, anchor: .center)
                }
            }
        }.background(Color.black).foregroundStyle(.white)
            .sheet(item: $selected) { record in AlbumMomentView(initialID: record.id).environmentObject(library) }
            .sheet(isPresented: $checkout) { CheckoutView().environmentObject(library).presentationDetents([.large]).presentationDragIndicator(.visible).interactiveDismissDisabled(library.deleting) }
    }
}

private struct AlbumMomentView: View {
    @EnvironmentObject private var library: PhotoLibraryStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var selectedID: String
    init(initialID: String) { _selectedID = State(initialValue: initialID) }
    private var index: Int? { library.timelineRecords.firstIndex { $0.id == selectedID } }
    private var record: MediaRecord? { index.map { library.timelineRecords[$0] } }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let record {
                MediaView(record: record, active: scenePhase == .active, onSwipe: swipe, onLongPress: { _ in }).id(record.id)
                LinearGradient(colors: [.black.opacity(0.5), .clear, .black.opacity(0.7)], startPoint: .top, endPoint: .bottom).ignoresSafeArea().allowsHitTesting(false)
            }
            VStack {
                HStack {
                    Text("时光相册").font(.subheadline).foregroundStyle(.secondary)
                    Spacer()
                    Button { dismiss() } label: { Image(systemName: "xmark").padding(14).background(.ultraThinMaterial, in: Circle()) }.accessibilityLabel("返回时间相册")
                }
                Spacer()
                if let record {
                    VStack(spacing: 16) {
                        Text(record.creationDate?.formatted(.dateTime.year().month().day().locale(Locale(identifier: "zh_CN"))) ?? "日期未知").font(.title3.weight(.light))
                        HStack {
                            Button { move(-1) } label: { Image(systemName: "arrow.down").padding(14).background(.ultraThinMaterial, in: Circle()) }.disabled(index == 0).accessibilityLabel("上一张")
                            Spacer()
                            Button { swipe(.mark) } label: { Label(library.engine.markedIDs.contains(record.id) ? "已标记" : "左滑标记", systemImage: "trash").font(.subheadline).padding(14).background(.ultraThinMaterial, in: Capsule()) }
                            Spacer()
                            Button { move(1) } label: { Image(systemName: "arrow.up").padding(14).background(.ultraThinMaterial, in: Circle()) }.disabled(index == library.timelineRecords.count - 1).accessibilityLabel("下一张")
                        }
                        Text("上滑下一张 · 下滑上一张").font(.caption2).foregroundStyle(.secondary)
                    }
                } else { Text("媒体已不可访问").foregroundStyle(.secondary) }
            }.padding(24)
        }
        .accessibilityAction(named: "下一张") { move(1) }
        .accessibilityAction(named: "上一张") { move(-1) }
        .accessibilityAction(named: "标记待清理") { swipe(.mark) }
    }
    private func swipe(_ action: ViewerSwipe) {
        switch action {
        case .mark:
            library.mark(selectedID)
            move(1)
        case .next: move(1)
        case .previous: move(-1)
        case .none: break
        }
    }
    private func move(_ delta: Int) {
        guard let index else { return }
        let next = index + delta
        guard library.timelineRecords.indices.contains(next) else { return }
        selectedID = library.timelineRecords[next].id
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }
}
