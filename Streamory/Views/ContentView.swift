import SwiftUI
import Photos

extension Color {
    static let streamRed = Color(red: 1, green: 59.0 / 255, blue: 48.0 / 255)
    static let streamGreen = Color(red: 0.62, green: 0.86, blue: 0.67)
}

struct ContentView: View {
    @EnvironmentObject private var library: PhotoLibraryStore
    @Environment(\.scenePhase) private var scenePhase
    var body: some View {
        Group {
            if library.accessible { StreamView() }
            else { WelcomeView() }
        }
        .background(Color.black.ignoresSafeArea())
        .tint(.white)
        .task { await library.activate() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await library.activate() } }
            else if phase == .background { library.flushViewed() }
        }
        .alert("未能完成操作", isPresented: Binding(get: { library.error != nil }, set: { if !$0 { library.error = nil } })) {
            Button("知道了", role: .cancel) { library.error = nil }
        } message: { Text(library.error ?? "") }
    }
}

struct WelcomeView: View {
    @EnvironmentObject private var library: PhotoLibraryStore
    private var denied: Bool { library.authorization == .denied || library.authorization == .restricted }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack { Image(systemName: "circle.hexagongrid.fill").font(.title2); Text("STREAMORY").font(.caption.weight(.semibold)).tracking(4) }
                .foregroundStyle(.white.opacity(0.65)).padding(.top, 30)
            Spacer()
            ZStack {
                RoundedRectangle(cornerRadius: 20).fill(Color.white.opacity(0.04)).frame(width: 210, height: 270).rotationEffect(.degrees(-12)).offset(x: -25)
                RoundedRectangle(cornerRadius: 20).fill(LinearGradient(colors: [.init(red: 0.26, green: 0.38, blue: 0.35), .init(red: 0.67, green: 0.57, blue: 0.39)], startPoint: .topLeading, endPoint: .bottomTrailing)).frame(width: 210, height: 270).rotationEffect(.degrees(8))
                Image(systemName: "sparkles").font(.system(size: 60, weight: .ultraLight)).foregroundStyle(.white.opacity(0.8))
            }.frame(maxWidth: .infinity).padding(.bottom, 55).accessibilityHidden(true)
            Text("让回忆，\n缓缓流过。").font(.system(size: 42, weight: .light)).lineSpacing(8)
            Text("影流 · 你的私人记忆放映室").font(.subheadline).foregroundStyle(.white.opacity(0.55)).padding(.top, 20)
            Text(denied ? "需要相册访问权限才能回顾。你可以在设置中授权，或只选择部分照片。" : "随机遇见旧时光。喜欢的留下，\n不再需要的，回顾结束后再决定。").font(.subheadline).lineSpacing(7).foregroundStyle(.white.opacity(0.65)).padding(.top, 12)
            Spacer()
            Button {
                if denied, let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                else { Task { await library.requestPermission() } }
            } label: {
                HStack { Text(denied ? "前往设置" : "开启我的回忆"); Spacer(); Image(systemName: "arrow.right") }
                    .font(.headline).foregroundStyle(.black).padding(20).background(.white, in: RoundedRectangle(cornerRadius: 18))
            }.disabled(library.authorization == .restricted)
            Label("所有照片仅在本地处理，绝不上传", systemImage: "lock.shield").font(.caption).foregroundStyle(.white.opacity(0.45)).frame(maxWidth: .infinity).padding(.top, 20).padding(.bottom, 25)
        }.padding(.horizontal, 30)
    }
}

struct StreamView: View {
    @EnvironmentObject private var library: PhotoLibraryStore
    @Environment(\.scenePhase) private var scenePhase
    @State private var checkout = false
    @State private var showAlbums = false
    @State private var glow = false
    @State private var transitioning = false
    @State private var drag = CGSize.zero
    @State private var portal: TimePortal?
    @State private var past: MediaRecord?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var help = false
    @State private var pendingAlbum: String?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let record = library.engine.current {
                MediaView(record: record, active: !checkout && !showAlbums && past == nil && portal == nil && scenePhase == .active,
                          onSwipe: handleSwipe, onLongPress: { travel(record, at: $0) }, onDrag: { value in
                              guard !transitioning, portal == nil else { return }
                              drag = CGSize(width: value.width * 0.12, height: value.height * 0.12)
                          })
                    .id(record.id).offset(drag).opacity(transitioning ? 0.5 : 1)
                    .accessibilityLabel("当前回忆")
                    .accessibilityAction(named: "标记待清理") { advance(mark: true) }
                    .accessibilityAction(named: "下一张") { advance(mark: false) }
                    .accessibilityAction(named: "上一张") { previous() }
                    .accessibilityAction(named: "回到过去") { travel(record, at: nil) }
            } else {
                VStack(spacing: 18) {
                    Image(systemName: library.loading ? "hourglass" : "sparkles").font(.system(size: 42, weight: .ultraLight)).foregroundStyle(.white.opacity(0.6))
                    Text(library.loading ? "正在整理你的回忆" : "这段回忆已看完").font(.title2.weight(.light))
                    Text(library.loading ? "只索引信息，不读取原始照片" : "换个范围，或重新开启一轮回顾").font(.subheadline).foregroundStyle(.secondary)
                    if !library.loading {
                        Button("再回顾一轮") { library.restart() }.buttonStyle(.bordered)
                        if library.authorization == .limited { Button("选择更多照片") { library.manageLimitedAccess() } }
                    }
                }.padding(30).frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background { MediaGestureSurface(onSwipe: handleSwipe, onLongPress: { _ in }) }
            }
            LinearGradient(colors: [.black.opacity(0.55), .clear, .clear, .black.opacity(0.8)], startPoint: .top, endPoint: .bottom).ignoresSafeArea().allowsHitTesting(false)
            Color.streamRed.opacity(glow ? 0.32 : 0).ignoresSafeArea().allowsHitTesting(false)
            VStack {
                topBar
                HStack {
                    Button { showAlbums = true } label: {
                        Label(library.albums.first(where: { $0.id == library.albumID })?.title ?? "全部相册", systemImage: "square.stack").font(.caption).lineLimit(1)
                    }.padding(.vertical, 10).padding(.horizontal, 14).background(.ultraThinMaterial, in: Capsule())
                    Spacer()
                    if library.demo { Text("演示模式").font(.caption).foregroundStyle(Color.streamGreen) }
                    Button { help = true } label: { Image(systemName: "questionmark.circle").font(.title3).padding(10) }.accessibilityLabel("操作说明")
                }.padding(.top, 12)
                if library.authorization == .limited {
                    Button { library.manageLimitedAccess() } label: { Label("当前仅访问已选照片 · 管理", systemImage: "lock").font(.caption2).foregroundStyle(.white.opacity(0.7)) }.padding(.top, 4)
                }
                Spacer()
                bottomBar
            }.padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 16).disabled(portal != nil)
            if let portal { TimePortalEffect(point: portal.point).id(portal.id) }
            if let notice = library.notice {
                Text(notice).font(.subheadline).padding(16).background(.ultraThinMaterial, in: Capsule()).padding(.horizontal, 24).offset(y: -80)
                    .task(id: notice) { try? await Task.sleep(for: .seconds(3)); if library.notice == notice { library.notice = nil } }
            }
        }
        .task(id: portal?.id) {
            guard let currentPortal = portal else { return }
            do { try await Task.sleep(for: .seconds(reduceMotion ? 0.15 : 0.7)) } catch { return }
            guard portal?.id == currentPortal.id else { return }
            var transaction = Transaction(); transaction.disablesAnimations = true
            withTransaction(transaction) { past = currentPortal.record }
        }
        .fullScreenCover(item: $past, onDismiss: { portal = nil }) { record in
            TimeTravelAlbumView(anchorID: record.id).environmentObject(library)
        }
        .sheet(isPresented: $checkout) { CheckoutView().environmentObject(library).presentationDetents([.large]).presentationDragIndicator(.visible).interactiveDismissDisabled(library.deleting) }
        .sheet(isPresented: $showAlbums) {
            NavigationStack {
                List(library.albums) { album in
                    Button {
                        if !library.engine.markedIDs.isEmpty { pendingAlbum = album.id }
                        else { Task { await library.selectAlbum(album.id) }; showAlbums = false }
                    } label: { HStack { Text(album.title); Spacer(); if album.id == library.albumID { Image(systemName: "checkmark").foregroundStyle(Color.streamGreen) } } }
                }.navigationTitle("回顾范围").toolbar { Button("完成") { showAlbums = false } }
            }.presentationDetents([.medium, .large])
            .confirmationDialog("切换相册前，请先处理本次标记", isPresented: Binding(get: { pendingAlbum != nil }, set: { if !$0 { pendingAlbum = nil } }), titleVisibility: .visible) {
                Button("全部保留并切换") {
                    guard let id = pendingAlbum else { return }
                    library.keepAll(); pendingAlbum = nil; showAlbums = false
                    Task { await library.selectAlbum(id) }
                }
                Button("先查看已标记项") { pendingAlbum = nil; showAlbums = false; DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { checkout = true } }
                Button("取消", role: .cancel) { pendingAlbum = nil }
            }
        }
        .alert("慢慢看，随手整理", isPresented: $help) { Button("知道了", role: .cancel) {} } message: {
            Text("左滑：标记待清理并进入下一张\n上滑：进入下一张\n下滑：返回上一张，不改变标记\n长按照片：穿越到它在相册中的时间位置\n撤销按钮：撤回上一步操作\n完成：查看标记，再决定是否清理\n\n标记不会删除照片。系统会在最终清理时再次确认。")
        }
    }
    private var topBar: some View {
        HStack(spacing: 12) {
            Button("完成") { checkout = true }.font(.subheadline.weight(.medium)).frame(minWidth: 44, minHeight: 44)
            Spacer(minLength: 0)
            HStack(spacing: 0) {
                ForEach(MediaFilter.allCases) { filter in
                    Button { library.setFilter(filter) } label: {
                        Text(filter.title).font(.caption.weight(.semibold)).padding(.horizontal, 12).padding(.vertical, 10)
                            .background(library.filter == filter ? Color.white.opacity(0.2) : .clear, in: Capsule())
                    }.accessibilityAddTraits(library.filter == filter ? .isSelected : [])
                }
            }.padding(4).background(.ultraThinMaterial, in: Capsule())
            Spacer(minLength: 0)
            Button { checkout = true } label: {
                HStack(spacing: 4) { Image(systemName: "tray"); Text("\(library.engine.markedIDs.count)").monospacedDigit() }
                    .font(.subheadline.weight(.medium)).padding(12).background(.ultraThinMaterial, in: Capsule())
            }.accessibilityLabel("已标记 \(library.engine.markedIDs.count) 项，查看清理清单")
        }
    }
    private var bottomBar: some View {
        VStack(alignment: .leading, spacing: 22) {
            if let record = library.engine.current {
                VStack(alignment: .leading, spacing: 9) {
                    HStack(spacing: 6) {
                        Circle().fill(Color.streamGreen).frame(width: 5, height: 5)
                        Text(library.engine.current.map { library.engine.markedIDs.contains($0.id) } == true ? "已标记待清理" : "偶遇旧时光").tracking(3)
                    }.font(.caption2).foregroundStyle(.white.opacity(0.6))
                    Text(record.creationDate?.formatted(.dateTime.year().month().day().locale(Locale(identifier: "zh_CN"))) ?? "日期未知").font(.system(size: 25, weight: .light))
                    HStack(spacing: 8) {
                        Text(record.isVideo ? "视频回忆" : "照片回忆")
                        if let location = library.currentAsset?.location { Text(String(format: "%.2f°, %.2f°", location.coordinate.latitude, location.coordinate.longitude)) }
                        Text("· 浏览 \(library.engine.reviewedCount) 次")
                    }.font(.caption).foregroundStyle(.white.opacity(0.55))
                }.allowsHitTesting(false)
            }
            HStack {
                Button { library.undo() } label: { Image(systemName: "arrow.uturn.backward").font(.title3).frame(width: 50, height: 50).background(.ultraThinMaterial, in: Circle()) }
                    .disabled(!library.engine.canUndo || transitioning).opacity(library.engine.canUndo ? 1 : 0.35).accessibilityLabel("撤销上一步")
                Spacer()
                Button { advance(mark: true) } label: {
                    VStack(spacing: 6) { Image(systemName: "trash").font(.title3); Text("左滑标记").font(.caption2) }.foregroundStyle(.white.opacity(0.8)).padding(8)
                }.disabled(library.engine.current == nil || transitioning)
                Spacer()
                Button { advance(mark: false) } label: { Image(systemName: "arrow.up").font(.title3).frame(width: 50, height: 50).background(.ultraThinMaterial, in: Circle()) }.disabled(library.engine.current == nil || transitioning).accessibilityLabel("下一张")
            }
            Text("上滑下一张 · 下滑上一张 · 长按回到过去").font(.caption2).foregroundStyle(.white.opacity(0.3)).frame(maxWidth: .infinity)
        }
    }
    private func handleSwipe(_ action: ViewerSwipe) {
        withAnimation(.easeOut(duration: 0.15)) { drag = .zero }
        switch action {
        case .mark: advance(mark: true)
        case .next: advance(mark: false)
        case .previous: previous()
        case .none: break
        }
    }
    private func previous() {
        guard !transitioning, portal == nil else { return }
        library.previous()
    }
    private func travel(_ record: MediaRecord, at point: CGPoint?) {
        guard !transitioning, portal == nil, library.engine.current?.id == record.id else { return }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        drag = .zero
        portal = TimePortal(record: record, point: point)
    }
    private func advance(mark: Bool) {
        guard !transitioning, portal == nil, library.engine.current != nil else { return }
        transitioning = true
        withAnimation(.easeOut(duration: 0.12)) { glow = mark }
        library.advance(mark: mark)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            withAnimation(.easeOut(duration: 0.2)) { transitioning = false; glow = false }
        }
    }
}

struct MediaView: View {
    @EnvironmentObject private var library: PhotoLibraryStore
    @StateObject private var loader = MediaLoader()
    let record: MediaRecord
    let active: Bool
    var onSwipe: ((ViewerSwipe) -> Void)? = nil
    var onLongPress: ((CGPoint) -> Void)? = nil
    var onDrag: (CGSize) -> Void = { _ in }
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                if let image = loader.image {
                    Image(uiImage: image).resizable().scaledToFill().frame(width: geometry.size.width, height: geometry.size.height).clipped().blur(radius: 40).opacity(0.4)
                    Image(uiImage: image).resizable().scaledToFit().frame(width: geometry.size.width, height: geometry.size.height)
                }
                if let player = loader.player { PlayerSurface(player: player).allowsHitTesting(false) }
                else if let live = loader.livePhoto { LivePhotoSurface(photo: live, active: active).allowsHitTesting(false) }
                if loader.image == nil && !loader.unavailable { ProgressView().tint(.white) }
                if loader.unavailable {
                    VStack(spacing: 12) {
                        Image(systemName: "icloud.slash").font(.title)
                        Text("原始媒体尚未存储在本机").font(.subheadline)
                        Text("可先在系统相册下载，再回来回顾").font(.caption).foregroundStyle(.secondary)
                    }.padding(22).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18))
                }
                if let onSwipe, let onLongPress {
                    MediaGestureSurface(onSwipe: onSwipe, onLongPress: onLongPress, onDrag: onDrag)
                }
                if loader.player != nil {
                    VStack {
                        Spacer()
                        HStack {
                            ProgressView(value: loader.progress).tint(.white)
                            Button { loader.toggleMute() } label: { Image(systemName: loader.muted ? "speaker.slash.fill" : "speaker.wave.2.fill").padding(12).background(.ultraThinMaterial, in: Circle()) }.accessibilityLabel(loader.muted ? "打开视频声音" : "静音")
                        }.padding(.horizontal, 24).padding(.bottom, 240)
                    }
                }
            }.frame(width: geometry.size.width, height: geometry.size.height).clipped()
        }.ignoresSafeArea()
        .task(id: record.id) { loader.load(asset: library.asset(for: record.id), id: record.id, manager: library.images); loader.setActive(active) }
        .onChange(of: active) { _, value in loader.setActive(value) }
        .onDisappear { loader.stop() }
    }
}
