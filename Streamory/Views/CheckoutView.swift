import SwiftUI

struct CheckoutView: View {
    @EnvironmentObject private var library: PhotoLibraryStore
    @Environment(\.dismiss) private var dismiss
    @State private var preview: MediaRecord?
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 4)
    private var bytesText: String { ByteCountFormatter.string(fromByteCount: library.totalBytes, countStyle: .file) }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("回顾之后，再做决定").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark").font(.caption.weight(.semibold)).padding(12).background(.white.opacity(0.08), in: Circle()) }.disabled(library.deleting).accessibilityLabel("继续回顾")
            }.padding(.top, 24)
            VStack(alignment: .leading, spacing: 12) {
                Text("留下值得的，\n放下多余的。").font(.system(size: 30, weight: .light)).lineSpacing(4)
                Text("本次回顾已标记 \(library.engine.markedIDs.count) 项媒体").font(.subheadline).foregroundStyle(.secondary)
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(bytesText).font(.system(size: 38, weight: .light, design: .rounded)).foregroundStyle(Color.streamGreen).contentTransition(.numericText())
                    Text(library.sizePending ? "正在计算…" : "预计释放").font(.caption).foregroundStyle(.secondary)
                }
                if library.sizeIncomplete { Text("部分资源仅在 iCloud 中，未计入估算。实际空间以系统为准。").font(.caption).foregroundStyle(.secondary) }
                Text("轻点取消标记 · 长按查看大图").font(.caption).foregroundStyle(.white.opacity(0.4)).padding(.top, 4)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 24)
            if library.markedRecords.isEmpty {
                Spacer()
                VStack(spacing: 12) {
                    Image(systemName: "checkmark.circle").font(.system(size: 38, weight: .ultraLight)).foregroundStyle(Color.streamGreen)
                    Text("每一张都好好留下了").font(.subheadline)
                    Text("继续回顾，遇见更多旧时光").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 8) {
                        ForEach(library.markedRecords) { record in
                            ThumbnailView(record: record)
                                .overlay(alignment: .topTrailing) {
                                    Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.white).padding(5).background(Color.streamRed, in: Circle()).padding(5).allowsHitTesting(false)
                                }
                                .contentShape(Rectangle())
                                .gesture(LongPressGesture(minimumDuration: 0.4).exclusively(before: TapGesture()).onEnded { result in
                                    switch result {
                                    case .first: preview = record
                                    case .second: withAnimation { library.unmark(record.id) }
                                    }
                                })
                                .accessibilityElement(children: .ignore)
                                .accessibilityLabel("待清理\(record.isVideo ? "视频" : "照片")，\(record.creationDate?.formatted(date: .abbreviated, time: .omitted) ?? "日期未知")")
                                .accessibilityAction(named: "保留") { library.unmark(record.id) }
                                .accessibilityAction(named: "预览") { preview = record }
                        }
                    }.padding(.bottom, 18)
                }.disabled(library.deleting)
            }
            VStack(spacing: 12) {
                Button {
                    Task { if await library.deleteMarked() { dismiss() } }
                } label: {
                    HStack(spacing: 8) {
                        if library.deleting { ProgressView().tint(.white) }
                        else { Image(systemName: "trash") }
                        Text(library.demo ? "演示清理（不影响真实相册）" : "确认移入系统废纸篓").font(.subheadline.weight(.semibold))
                    }.frame(maxWidth: .infinity).padding(.vertical, 19).background(Color.streamRed, in: RoundedRectangle(cornerRadius: 16))
                }.disabled(library.engine.markedIDs.isEmpty || library.deleting).opacity(library.engine.markedIDs.isEmpty ? 0.35 : 1)
                Button { library.keepAll(); dismiss() } label: {
                    Text(library.engine.markedIDs.isEmpty ? "继续回顾" : "暂不清理，全部保留").font(.subheadline).frame(maxWidth: .infinity).padding(.vertical, 14)
                }.disabled(library.deleting)
                Label("系统将再次确认，清理后可在「最近删除」中恢复", systemImage: "shield.lefthalf.filled").font(.system(size: 10)).foregroundStyle(.white.opacity(0.35)).multilineTextAlignment(.center)
            }.padding(.top, 16).padding(.bottom, 16)
        }.padding(.horizontal, 24).background(Color(red: 0.07, green: 0.07, blue: 0.07)).foregroundStyle(.white)
        .sheet(item: $preview) { record in
            ZStack(alignment: .topTrailing) {
                Color.black.ignoresSafeArea()
                MediaView(record: record, active: true)
                VStack(spacing: 14) {
                    HStack {
                        Spacer()
                        Button { preview = nil } label: { Image(systemName: "xmark").padding(15).background(.ultraThinMaterial, in: Circle()) }.accessibilityLabel("关闭预览")
                    }
                    Spacer()
                    Button { library.unmark(record.id); preview = nil } label: {
                        Label("保留这张", systemImage: "heart").font(.headline).padding(18).frame(maxWidth: .infinity).background(.ultraThinMaterial, in: Capsule())
                    }
                }.padding(24)
            }
        }
    }
}

struct ThumbnailView: View {
    @EnvironmentObject private var library: PhotoLibraryStore
    @StateObject private var loader = MediaLoader()
    let record: MediaRecord
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.white.opacity(0.05)
                if let image = loader.image {
                    Image(uiImage: image).resizable().scaledToFill().frame(width: geometry.size.width, height: geometry.size.height).clipped()
                } else { Image(systemName: loader.unavailable ? "icloud" : "photo").foregroundStyle(.secondary) }
                if record.isVideo { Image(systemName: "play.fill").font(.caption).shadow(radius: 3) }
            }
        }.aspectRatio(0.8, contentMode: .fit).clipShape(RoundedRectangle(cornerRadius: 9))
        .task(id: record.id) { loader.load(asset: library.asset(for: record.id), id: record.id, manager: library.images, thumbnail: true) }
        .onDisappear { loader.stop() }
    }
}
