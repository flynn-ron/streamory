import Foundation

/// The media kind that is included in a review session.
public enum MediaFilter: String, CaseIterable, Identifiable {
    case all
    case photos
    case videos

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .all:
            return "全部"
        case .photos:
            return "照片"
        case .videos:
            return "视频"
        }
    }
}

/// The small, Photos-free value that the review algorithm needs.
public struct MediaRecord: Identifiable, Equatable {
    public let id: String
    public let creationDate: Date?
    public let isVideo: Bool

    public init(id: String, creationDate: Date?, isVideo: Bool) {
        self.id = id
        self.creationDate = creationDate
        self.isVideo = isVideo
    }
}

/// Builds and advances through a weighted, non-repeating review order.
///
/// The engine deliberately only knows about `MediaRecord`; loading or deleting
/// the corresponding Photos assets belongs to the caller.
public struct ReviewEngine {
    private struct Snapshot {
        let cursor: Int
        let reviewedCount: Int
        let currentID: String
        let wasMarked: Bool
    }

    private static let longTermViewInterval: TimeInterval = 90 * 24 * 60 * 60
    private static let maximumUndoDepth = 100

    private var sourceRecords: [MediaRecord]
    private var orderedRecords: [MediaRecord]
    private var cursor: Int
    private var undoStack: [Snapshot]
    private let lastViewed: [String: Date]
    private let now: Date

    public private(set) var filter: MediaFilter
    public private(set) var markedIDs: Set<String>
    public private(set) var reviewedCount: Int

    /// Creates a session using the system random number generator.
    public init(
        records: [MediaRecord],
        filter: MediaFilter = .all,
        lastViewed: [String: Date] = [:],
        now: Date = Date()
    ) {
        var generator = SystemRandomNumberGenerator()
        self.init(
            records: records,
            filter: filter,
            lastViewed: lastViewed,
            now: now,
            rng: &generator
        )
    }

    /// Creates a session with an injected generator, which makes tests and
    /// previews deterministic without storing a generator in the engine.
    public init<R: RandomNumberGenerator>(
        records: [MediaRecord],
        filter: MediaFilter = .all,
        lastViewed: [String: Date] = [:],
        now: Date = Date(),
        rng: inout R
    ) {
        let uniqueRecords = Self.uniqueRecords(records)
        self.sourceRecords = uniqueRecords
        self.filter = filter
        self.lastViewed = lastViewed
        self.now = now
        self.markedIDs = []
        self.reviewedCount = 0
        self.cursor = 0
        self.undoStack = []

        let filtered = Self.records(uniqueRecords, matching: filter)
        self.orderedRecords = Self.weightedOrder(
            filtered,
            lastViewed: lastViewed,
            now: now,
            rng: &rng
        )
    }

    /// Value-taking convenience for callers that do not need to reuse the
    /// generator after construction. The inout overload above remains useful
    /// when a caller wants to continue a deterministic random stream.
    public init<R: RandomNumberGenerator>(
        records: [MediaRecord],
        filter: MediaFilter = .all,
        lastViewed: [String: Date] = [:],
        now: Date = Date(),
        rng: R
    ) {
        var generator = rng
        self.init(
            records: records,
            filter: filter,
            lastViewed: lastViewed,
            now: now,
            rng: &generator
        )
    }

    /// The card currently shown to the user, or `nil` after the session ends.
    public var current: MediaRecord? {
        guard orderedRecords.indices.contains(cursor) else { return nil }
        return orderedRecords[cursor]
    }

    /// Up to the next three cards after `current`.
    public var upcoming: [MediaRecord] {
        guard cursor < orderedRecords.count else { return [] }
        let start = cursor + 1
        guard start < orderedRecords.count else { return [] }
        return Array(orderedRecords[start..<min(start + 3, orderedRecords.count)])
    }

    public var canUndo: Bool { !undoStack.isEmpty }

    /// Whether the review cursor can move back to a previously shown card.
    /// This is navigation state and is intentionally independent of undo.
    public var canGoBack: Bool { cursor > 0 }

    /// The records known to this engine, after ID de-duplication.
    ///
    /// This is useful to a store that wants to validate persisted marks. The
    /// engine also performs that validation in `restoreMarks`.
    public var allRecords: [MediaRecord] { sourceRecords }

    /// Moves the review cursor to the preceding card without changing marks.
    ///
    /// Returning is deliberately different from `undo()`: it does not restore
    /// an old advance snapshot, and it invalidates that snapshot history so a
    /// later explicit undo cannot unexpectedly jump across the navigation.
    /// `reviewedCount` remains the number of advance decisions in the session;
    /// going back only changes which card is displayed.
    public mutating func previous() {
        guard canGoBack else { return }
        cursor -= 1
        undoStack.removeAll()
    }

    /// Advances past the current card. When `mark` is true, the card's ID is
    /// added to `markedIDs` before advancing.
    public mutating func advance(mark: Bool) {
        guard let current else { return }

        if undoStack.count == Self.maximumUndoDepth {
            undoStack.removeFirst()
        }
        undoStack.append(
            Snapshot(
                cursor: cursor,
                reviewedCount: reviewedCount,
                currentID: current.id,
                wasMarked: markedIDs.contains(current.id)
            )
        )

        if mark {
            markedIDs.insert(current.id)
        }
        cursor += 1
        reviewedCount += 1
    }

    /// Marks a source record without moving the random review cursor.
    ///
    /// The ID may belong to another media filter, which lets a chronological
    /// photo view share the same cleanup session. Unknown or already removed
    /// IDs are rejected. A valid external mark invalidates any advance undo
    /// snapshot because it changes the session state outside that snapshot.
    @discardableResult
    public mutating func mark(id: String) -> Bool {
        guard sourceRecords.contains(where: { $0.id == id }) else { return false }
        markedIDs.insert(id)
        undoStack.removeAll()
        return true
    }

    /// Restores the card and mark set from the preceding `advance` call.
    public mutating func undo() {
        guard let snapshot = undoStack.popLast() else { return }
        cursor = min(max(snapshot.cursor, 0), orderedRecords.count)
        reviewedCount = snapshot.reviewedCount
        if snapshot.wasMarked {
            markedIDs.insert(snapshot.currentID)
        } else {
            markedIDs.remove(snapshot.currentID)
        }
    }

    /// Removes a mark. Settlement operations intentionally invalidate undo so
    /// an old action cannot re-apply a mark after the user has settled it.
    public mutating func unmark(id: String) {
        markedIDs.remove(id)
        undoStack.removeAll()
    }

    /// Clears all marks and invalidates the undo history.
    public mutating func keepAll() {
        markedIDs.removeAll()
        undoStack.removeAll()
    }

    /// Restores marks persisted by the owning store.
    ///
    /// IDs outside this engine's source records are ignored. Restored marks
    /// are removed from the current order so a filter rebuild cannot show an
    /// already marked card again. Marks belonging to another filter remain in
    /// `markedIDs` and become effective when that filter is selected.
    public mutating func restoreMarks(_ ids: Set<String>) {
        let sourceIDs = Set(sourceRecords.map(\.id))
        let validIDs = ids.intersection(sourceIDs)
        markedIDs.formUnion(validIDs)

        guard !validIDs.isEmpty else {
            undoStack.removeAll()
            return
        }

        let removedBeforeCursor = orderedRecords.prefix(min(cursor, orderedRecords.count))
            .reduce(into: 0) { count, record in
                if validIDs.contains(record.id) { count += 1 }
            }
        orderedRecords.removeAll { validIDs.contains($0.id) }
        cursor = min(max(cursor - removedBeforeCursor, 0), orderedRecords.count)
        undoStack.removeAll()
    }

    /// Permanently removes IDs from this engine while preserving the remaining
    /// order. The cursor is shifted to the same logical card when possible.
    public mutating func remove(ids: Set<String>) {
        guard !ids.isEmpty else { return }

        let removedBeforeCursor = orderedRecords.prefix(min(cursor, orderedRecords.count))
            .reduce(into: 0) { count, record in
                if ids.contains(record.id) { count += 1 }
            }

        sourceRecords.removeAll { ids.contains($0.id) }
        orderedRecords.removeAll { ids.contains($0.id) }
        markedIDs.subtract(ids)
        cursor = min(max(cursor - removedBeforeCursor, 0), orderedRecords.count)
        undoStack.removeAll()
    }

    /// Reconciles the engine with a refreshed library snapshot.
    ///
    /// Existing cards retain their order and the cursor remains on the same
    /// logical card. Inaccessible cards are removed, while newly discovered
    /// cards matching the current filter are weighted and appended after the
    /// existing order. The review count and marks are preserved for surviving
    /// IDs. A real source change invalidates undo because a prior snapshot may
    /// refer to a card that no longer exists; an identical snapshot leaves it
    /// intact.
    public mutating func reconcile(records: [MediaRecord]) {
        var generator = SystemRandomNumberGenerator()
        reconcile(records: records, rng: &generator)
    }

    /// Deterministic counterpart of `reconcile(records:)` for tests and
    /// previews.
    public mutating func reconcile<R: RandomNumberGenerator>(
        records: [MediaRecord],
        rng: inout R
    ) {
        let refreshedRecords = Self.uniqueRecords(records)
        let existingByID = Dictionary(uniqueKeysWithValues: sourceRecords.map { ($0.id, $0) })
        let refreshedByID = Dictionary(uniqueKeysWithValues: refreshedRecords.map { ($0.id, $0) })

        // PhotoKit can return the same assets in a different fetch order. The
        // engine's review order is authoritative, so compare by ID and value.
        guard existingByID != refreshedByID else { return }

        let existingIDs = Set(existingByID.keys)
        let refreshedIDs = Set(refreshedByID.keys)
        let removedIDs = existingIDs.subtracting(refreshedIDs)

        let removedBeforeCursor = orderedRecords.prefix(min(cursor, orderedRecords.count))
            .reduce(into: 0) { count, record in
                if removedIDs.contains(record.id) { count += 1 }
            }

        // Keep each surviving card's position while refreshing its metadata.
        // Cards omitted from the order are already persisted marks and remain
        // omitted even when their source record is refreshed.
        var reconciledOrder = orderedRecords.compactMap { refreshedByID[$0.id] }
        let newRecords = refreshedRecords.filter {
            !existingIDs.contains($0.id)
                && Self.matches($0, filter: filter)
                && !markedIDs.contains($0.id)
        }
        let appendedRecords = Self.weightedOrder(
            newRecords,
            lastViewed: lastViewed,
            now: now,
            rng: &rng
        )
        reconciledOrder.append(contentsOf: appendedRecords)

        sourceRecords = refreshedRecords
        markedIDs = markedIDs.intersection(refreshedIDs)
        orderedRecords = reconciledOrder
        cursor = min(
            max(cursor - removedBeforeCursor, 0),
            orderedRecords.count
        )
        undoStack.removeAll()
    }

    public mutating func reconcile<R: RandomNumberGenerator>(
        records: [MediaRecord],
        rng: R
    ) {
        var generator = rng
        reconcile(records: records, rng: &generator)
    }

    /// Rebuilds the weighted order. Existing marks are preserved and omitted
    /// from the rebuilt order, which makes filter changes safe for a session
    /// whose marks are shared across filters.
    public mutating func reset(filter newFilter: MediaFilter? = nil) {
        var generator = SystemRandomNumberGenerator()
        reset(filter: newFilter, rng: &generator)
    }

    /// Deterministic counterpart of `reset(filter:)` for tests and previews.
    public mutating func reset<R: RandomNumberGenerator>(
        filter newFilter: MediaFilter? = nil,
        rng: inout R
    ) {
        if let newFilter {
            filter = newFilter
        }
        let filtered = Self.records(sourceRecords, matching: filter)
        orderedRecords = Self.weightedOrder(
            filtered,
            lastViewed: lastViewed,
            now: now,
            rng: &rng
        ).filter { !markedIDs.contains($0.id) }
        cursor = 0
        reviewedCount = 0
        undoStack.removeAll()
    }

    public mutating func reset<R: RandomNumberGenerator>(
        filter newFilter: MediaFilter? = nil,
        rng: R
    ) {
        var generator = rng
        reset(filter: newFilter, rng: &generator)
    }

    // MARK: - Ordering

    private static func uniqueRecords(_ records: [MediaRecord]) -> [MediaRecord] {
        var seen = Set<String>()
        return records.filter { seen.insert($0.id).inserted }
    }

    private static func records(_ records: [MediaRecord], matching filter: MediaFilter) -> [MediaRecord] {
        records.filter { matches($0, filter: filter) }
    }

    private static func matches(_ record: MediaRecord, filter: MediaFilter) -> Bool {
        switch filter {
        case .all:
            return true
        case .photos:
            return !record.isVideo
        case .videos:
            return record.isVideo
        }
    }

    private static func weightedOrder<R: RandomNumberGenerator>(
        _ records: [MediaRecord],
        lastViewed: [String: Date],
        now: Date,
        rng: inout R
    ) -> [MediaRecord] {
        // Exponential-race sampling gives the same weighted-without-replacement
        // distribution as repeatedly drawing from the remaining weights. Each
        // record receives one random key and one weight calculation, then the
        // keys are sorted in O(n log n) time.
        var keyedRecords = records.enumerated().map { index, record in
            let recordWeight = weight(for: record, lastViewed: lastViewed, now: now)
            let randomUnit = max(
                Double.random(in: 0..<1, using: &rng),
                Double.leastNonzeroMagnitude
            )
            return (record: record, key: -log(randomUnit) / recordWeight, index: index)
        }
        keyedRecords.sort {
            if $0.key == $1.key {
                return $0.index < $1.index
            }
            return $0.key < $1.key
        }
        return keyedRecords.map(\.record)
    }

    private static func weight(
        for record: MediaRecord,
        lastViewed: [String: Date],
        now: Date
    ) -> Double {
        if isAnniversary(record.creationDate, now: now) {
            return 4
        }

        let cutoff = now.addingTimeInterval(-longTermViewInterval)
        let hasBeenUnviewedLongEnough: Bool
        if let lastViewedDate = lastViewed[record.id] {
            hasBeenUnviewedLongEnough = lastViewedDate < cutoff
        } else {
            // A record with no viewing entry has never been reviewed and is
            // therefore eligible for the long-unviewed boost.
            hasBeenUnviewedLongEnough = true
        }
        return hasBeenUnviewedLongEnough ? 2 : 1
    }

    private static func isAnniversary(_ creationDate: Date?, now: Date) -> Bool {
        guard let creationDate else { return false }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone.current
        guard let oneYearAgo = calendar.date(byAdding: .year, value: -1, to: now) else {
            return false
        }

        // Review priority is based on the calendar day. A capture taken at
        // any time on the exact anniversary therefore qualifies too.
        guard calendar.startOfDay(for: creationDate) <= calendar.startOfDay(for: oneYearAgo) else {
            return false
        }

        let creationComponents = calendar.dateComponents([.month, .day], from: creationDate)
        let nowComponents = calendar.dateComponents([.month, .day], from: now)
        return creationComponents.month == nowComponents.month
            && creationComponents.day == nowComponents.day
    }
}

/// The semantic result of a viewer swipe. A rightward swipe has no action;
/// callers can use `.none` for that case and for sub-threshold movement.
public enum ViewerSwipe: Equatable {
    case mark
    case next
    case previous
    case none

    /// Resolves a translation using its dominant axis. UIKit-style vertical
    /// translations are assumed: negative is upward and positive is downward.
    public static func resolve(
        horizontal: Double,
        vertical: Double,
        threshold: Double = 60
    ) -> ViewerSwipe {
        let limit = abs(threshold)
        guard limit.isFinite else { return .none }

        let horizontalMagnitude = abs(horizontal)
        let verticalMagnitude = abs(vertical)
        guard max(horizontalMagnitude, verticalMagnitude) >= limit else {
            return .none
        }

        if horizontalMagnitude > verticalMagnitude {
            return horizontal < 0 ? .mark : .none
        }
        if verticalMagnitude > horizontalMagnitude {
            return vertical < 0 ? .next : .previous
        }
        return .none
    }
}

/// Free-function spelling for callers that do not need to qualify the helper
/// type. `ViewerSwipe.resolve` remains the canonical namespaced API.
public func resolve(
    horizontal: Double,
    vertical: Double,
    threshold: Double = 60
) -> ViewerSwipe {
    ViewerSwipe.resolve(horizontal: horizontal, vertical: vertical, threshold: threshold)
}
