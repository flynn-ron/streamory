import XCTest
@testable import Streamory

final class ReviewEngineTests: XCTestCase {
    private struct SeededGenerator: RandomNumberGenerator {
        private var state: UInt64

        init(seed: UInt64) {
            state = seed == 0 ? 0x9E37_79B9_7F4A_7C15 : seed
        }

        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var value = state
            value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
            value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
            return value ^ (value >> 31)
        }
    }

    private let records = [
        MediaRecord(id: "photo-1", creationDate: Date(timeIntervalSince1970: 1), isVideo: false),
        MediaRecord(id: "photo-2", creationDate: Date(timeIntervalSince1970: 2), isVideo: false),
        MediaRecord(id: "video-1", creationDate: Date(timeIntervalSince1970: 3), isVideo: true),
        MediaRecord(id: "video-2", creationDate: Date(timeIntervalSince1970: 4), isVideo: true)
    ]

    func testAdvanceMarkAndUndoRestoreCardAndMarkState() {
        var generator = SeededGenerator(seed: 42)
        var engine = ReviewEngine(records: records, rng: &generator)
        let first = try! XCTUnwrap(engine.current)

        engine.advance(mark: true)

        XCTAssertEqual(engine.reviewedCount, 1)
        XCTAssertTrue(engine.markedIDs.contains(first.id))
        XCTAssertTrue(engine.canUndo)
        XCTAssertNotEqual(engine.current?.id, first.id)

        engine.undo()

        XCTAssertEqual(engine.current, first)
        XCTAssertEqual(engine.reviewedCount, 0)
        XCTAssertTrue(engine.markedIDs.isEmpty)
        XCTAssertFalse(engine.canUndo)
    }

    func testFilterAndUpcomingUseOnlyMatchingMedia() {
        var generator = SeededGenerator(seed: 7)
        var engine = ReviewEngine(records: records, filter: .videos, rng: &generator)

        XCTAssertTrue(engine.current?.isVideo == true)
        XCTAssertTrue(engine.upcoming.allSatisfy(\.isVideo))
        XCTAssertLessThanOrEqual(engine.upcoming.count, 3)

        engine.reset(filter: .photos, rng: &generator)
        XCTAssertFalse(engine.current?.isVideo == true)
        XCTAssertTrue(engine.upcoming.allSatisfy { !$0.isVideo })
    }

    func testSettlementClearsMarksAndUndoHistory() {
        var generator = SeededGenerator(seed: 9)
        var engine = ReviewEngine(records: records, rng: &generator)
        let first = try! XCTUnwrap(engine.current)

        engine.advance(mark: true)
        XCTAssertTrue(engine.canUndo)

        engine.unmark(id: first.id)
        XCTAssertFalse(engine.markedIDs.contains(first.id))
        XCTAssertFalse(engine.canUndo)

        engine.advance(mark: true)
        engine.keepAll()
        XCTAssertTrue(engine.markedIDs.isEmpty)
        XCTAssertFalse(engine.canUndo)
    }

    func testRemovePreservesRemainingOrderAndMovesCursorSafely() {
        var generator = SeededGenerator(seed: 12)
        var engine = ReviewEngine(records: records, rng: &generator)
        let first = try! XCTUnwrap(engine.current)
        let second = try! XCTUnwrap(engine.upcoming.first)

        engine.remove(ids: [first.id])

        XCTAssertEqual(engine.current, second)
        XCTAssertFalse(engine.allRecords.contains(first))
        XCTAssertFalse(engine.upcoming.contains(first))
    }

    func testRestoreMarksValidatesSourceAndHidesMarkedCards() {
        var generator = SeededGenerator(seed: 18)
        var engine = ReviewEngine(records: records, filter: .photos, rng: &generator)

        engine.restoreMarks(["photo-1", "video-1", "missing"])

        XCTAssertEqual(engine.markedIDs, Set(["photo-1", "video-1"]))
        XCTAssertFalse(engine.current?.id == "photo-1")
        XCTAssertTrue(engine.allRecords.contains { $0.id == "video-1" })
    }

    func testAdvanceToExhaustionAndUndoLastCard() {
        var generator = SeededGenerator(seed: 25)
        var engine = ReviewEngine(records: records, rng: &generator)
        var visited: [String] = []

        while let current = engine.current {
            visited.append(current.id)
            engine.advance(mark: false)
        }

        XCTAssertEqual(Set(visited).count, records.count)
        XCTAssertEqual(engine.reviewedCount, records.count)
        XCTAssertNil(engine.current)
        XCTAssertTrue(engine.upcoming.isEmpty)

        engine.undo()
        XCTAssertEqual(engine.reviewedCount, records.count - 1)
        XCTAssertNotNil(engine.current)
    }

    func testTenThousandRecordsRemainUniqueAndIndexable() {
        let largeRecords = (0..<10_000).map {
            MediaRecord(
                id: "large-\($0)",
                creationDate: Date(timeIntervalSince1970: TimeInterval($0)),
                isVideo: $0.isMultiple(of: 2)
            )
        }
        var generator = SeededGenerator(seed: 1_000)
        var engine = ReviewEngine(records: largeRecords, rng: &generator)
        var visited = Set<String>()

        while let current = engine.current {
            visited.insert(current.id)
            engine.advance(mark: false)
        }

        XCTAssertEqual(visited.count, largeRecords.count)
        XCTAssertEqual(engine.reviewedCount, largeRecords.count)
    }

    func testAnniversaryWeightWinsMoreOftenAcrossDeterministicSeeds() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone.current
        let now = calendar.date(from: DateComponents(year: 2026, month: 6, day: 15, hour: 12))!
        let anniversary = calendar.date(byAdding: .year, value: -1, to: now)!
        let ordinary = calendar.date(byAdding: .day, value: -2, to: now)!
        let candidates = [
            MediaRecord(id: "anniversary", creationDate: anniversary, isVideo: false),
            MediaRecord(id: "ordinary", creationDate: ordinary, isVideo: false)
        ]
        let recentlyViewed = now.addingTimeInterval(-60 * 60)
        var anniversaryFirstCount = 0

        for seed in 1...64 {
            var generator = SeededGenerator(seed: UInt64(seed))
            let engine = ReviewEngine(
                records: candidates,
                lastViewed: ["anniversary": recentlyViewed, "ordinary": recentlyViewed],
                now: now,
                rng: &generator
            )
            if engine.current?.id == "anniversary" {
                anniversaryFirstCount += 1
            }
        }

        // The anniversary record has weight 4 versus weight 1, so a fixed
        // seed sample should show a clear preference while staying reproducible.
        XCTAssertGreaterThan(anniversaryFirstCount, 32)
    }

    func testReconcileKeepsOrderCursorCountAndMarksButAppendsNewRecords() {
        var generator = SeededGenerator(seed: 31)
        var engine = ReviewEngine(records: records, rng: &generator)
        let first = try! XCTUnwrap(engine.current)
        let second = try! XCTUnwrap(engine.upcoming.first)

        engine.advance(mark: true)
        let oldReviewedCount = engine.reviewedCount
        var reconcileGenerator = SeededGenerator(seed: 32)
        let added = MediaRecord(id: "new", creationDate: Date(), isVideo: false)
        engine.reconcile(records: records + [added], rng: &reconcileGenerator)

        XCTAssertEqual(engine.current, second)
        XCTAssertEqual(engine.reviewedCount, oldReviewedCount)
        XCTAssertTrue(engine.markedIDs.contains(first.id))
        XCTAssertFalse(engine.canUndo)

        var remainingIDs: [String] = []
        while let current = engine.current {
            remainingIDs.append(current.id)
            engine.advance(mark: false)
        }
        XCTAssertEqual(remainingIDs.last, added.id)
    }

    func testReconcileRemovesCardsBeforeCursorAndNoChangeKeepsUndo() {
        var generator = SeededGenerator(seed: 41)
        var engine = ReviewEngine(records: records, rng: &generator)
        let first = try! XCTUnwrap(engine.current)
        let second = try! XCTUnwrap(engine.upcoming.first)
        engine.advance(mark: false)

        // The same source snapshot is a no-op, including undo history.
        var noChangeGenerator = SeededGenerator(seed: 42)
        engine.reconcile(records: records, rng: &noChangeGenerator)
        XCTAssertTrue(engine.canUndo)

        // Removing the reviewed first card shifts the cursor back to the same
        // logical second card and invalidates the old undo snapshot.
        var changedGenerator = SeededGenerator(seed: 43)
        engine.reconcile(
            records: records.filter { $0.id != first.id },
            rng: &changedGenerator
        )
        XCTAssertEqual(engine.current, second)
        XCTAssertEqual(engine.reviewedCount, 1)
        XCTAssertFalse(engine.canUndo)
        XCTAssertFalse(engine.allRecords.contains(first))
    }

    func testUndoHistoryIsBoundedToLastOneHundredAdvances() {
        let manyRecords = (0..<150).map {
            MediaRecord(id: "undo-\($0)", creationDate: nil, isVideo: false)
        }
        var generator = SeededGenerator(seed: 51)
        var engine = ReviewEngine(records: manyRecords, rng: &generator)

        for _ in manyRecords.indices {
            engine.advance(mark: false)
        }
        for _ in 0..<100 {
            engine.undo()
        }

        XCTAssertEqual(engine.reviewedCount, 50)
        XCTAssertFalse(engine.canUndo)
        engine.undo()
        XCTAssertEqual(engine.reviewedCount, 50)
    }

    func testPreviousMovesBackKeepsMarksAndInvalidatesAdvanceUndo() {
        var generator = SeededGenerator(seed: 61)
        var engine = ReviewEngine(records: records, rng: &generator)
        let first = try! XCTUnwrap(engine.current)

        engine.advance(mark: true)
        XCTAssertTrue(engine.canUndo)
        XCTAssertTrue(engine.canGoBack)

        engine.previous()

        XCTAssertEqual(engine.current, first)
        XCTAssertTrue(engine.markedIDs.contains(first.id))
        XCTAssertFalse(engine.canUndo)
    }

    func testPreviousAtFirstCardIsSafe() {
        var generator = SeededGenerator(seed: 62)
        var engine = ReviewEngine(records: records, rng: &generator)
        let first = try! XCTUnwrap(engine.current)

        XCTAssertFalse(engine.canGoBack)
        engine.previous()

        XCTAssertEqual(engine.current, first)
        XCTAssertFalse(engine.canGoBack)
    }

    func testPreviousFromExhaustionReturnsLastCard() {
        var generator = SeededGenerator(seed: 63)
        var engine = ReviewEngine(records: records, rng: &generator)
        var visited: [MediaRecord] = []

        while let current = engine.current {
            visited.append(current)
            engine.advance(mark: false)
        }
        XCTAssertTrue(engine.canGoBack)

        engine.previous()

        XCTAssertEqual(engine.current, visited.last)
        XCTAssertEqual(engine.reviewedCount, records.count)
    }

    func testPreviousThenAdvanceAndExplicitUndoRemainSeparate() {
        var generator = SeededGenerator(seed: 64)
        var engine = ReviewEngine(records: records, rng: &generator)
        let first = try! XCTUnwrap(engine.current)
        let second = try! XCTUnwrap(engine.upcoming.first)

        engine.advance(mark: true)
        engine.advance(mark: false)
        XCTAssertTrue(engine.markedIDs.contains(first.id))

        engine.previous()
        XCTAssertEqual(engine.current, second)
        XCTAssertFalse(engine.canUndo)

        engine.advance(mark: false)
        XCTAssertTrue(engine.canUndo)
        engine.undo()

        XCTAssertEqual(engine.current, second)
        XCTAssertTrue(engine.markedIDs.contains(first.id))
        XCTAssertFalse(engine.canUndo)
    }

    func testMarkByTimelineIDAcceptsAnySourceMediaWithoutMovingCurrent() {
        var generator = SeededGenerator(seed: 65)
        var engine = ReviewEngine(records: records, filter: .photos, rng: &generator)
        let current = try! XCTUnwrap(engine.current)
        let timelineVideo = try! XCTUnwrap(records.first { $0.isVideo })

        XCTAssertTrue(engine.mark(id: timelineVideo.id))
        XCTAssertEqual(engine.current, current)
        XCTAssertTrue(engine.markedIDs.contains(timelineVideo.id))

        // A duplicate mark is idempotent and an unknown ID cannot enter the
        // cleanup set. A valid external mark also invalidates old undo state.
        XCTAssertTrue(engine.mark(id: timelineVideo.id))
        XCTAssertFalse(engine.mark(id: "not-in-source"))
        XCTAssertEqual(engine.markedIDs, Set([timelineVideo.id]))

        engine.reset(filter: .all, rng: &generator)
        XCTAssertFalse(engine.current?.id == timelineVideo.id)
    }

    func testViewerSwipeUsesDominantAxisAndSafeNoOpCases() {
        XCTAssertEqual(ViewerSwipe.resolve(horizontal: -100, vertical: 10), .mark)
        XCTAssertEqual(ViewerSwipe.resolve(horizontal: 100, vertical: 10), .none)
        XCTAssertEqual(ViewerSwipe.resolve(horizontal: 10, vertical: -100), .next)
        XCTAssertEqual(ViewerSwipe.resolve(horizontal: 10, vertical: 100), .previous)
        XCTAssertEqual(ViewerSwipe.resolve(horizontal: 30, vertical: 40), .none)

        // Diagonal translations follow the larger component rather than the
        // sign of the other, weaker component.
        XCTAssertEqual(ViewerSwipe.resolve(horizontal: -120, vertical: -80), .mark)
        XCTAssertEqual(ViewerSwipe.resolve(horizontal: -80, vertical: -120), .next)
        XCTAssertEqual(ViewerSwipe.resolve(horizontal: 80, vertical: 120), .previous)
        XCTAssertEqual(ViewerSwipe.resolve(horizontal: 0, vertical: 60), .previous)
    }

    func testChronologicalAlbumSortsMonthsAndKeepsStableSameDateIDs() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let january = calendar.date(from: DateComponents(year: 2024, month: 1, day: 10, hour: 12))!
        let march = calendar.date(from: DateComponents(year: 2024, month: 3, day: 2, hour: 8))!
        let sameDate = calendar.date(from: DateComponents(year: 2024, month: 2, day: 5, hour: 9))!
        let source = [
            MediaRecord(id: "z", creationDate: sameDate, isVideo: true),
            MediaRecord(id: "a", creationDate: sameDate, isVideo: false),
            MediaRecord(id: "march", creationDate: march, isVideo: false),
            MediaRecord(id: "january", creationDate: january, isVideo: false)
        ]

        let album = ChronologicalAlbum(records: source, calendar: calendar)

        XCTAssertEqual(album.records.map(\.id), ["january", "a", "z", "march"])
        XCTAssertEqual(album.sections.map(\.id), [
            "month:\(calendar.dateInterval(of: .month, for: january)!.start.timeIntervalSince1970)",
            "month:\(calendar.dateInterval(of: .month, for: sameDate)!.start.timeIntervalSince1970)",
            "month:\(calendar.dateInterval(of: .month, for: march)!.start.timeIntervalSince1970)"
        ])
        XCTAssertEqual(album.sections.map(\.title), ["2024年1月", "2024年2月", "2024年3月"])
        XCTAssertEqual(album.sectionID(containing: "z"), album.sections[1].id)
        XCTAssertNil(album.sectionID(containing: "missing"))
    }

    func testChronologicalAlbumPutsUnknownDatesFirstAndDeduplicatesIDs() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let date = calendar.date(from: DateComponents(year: 2025, month: 4, day: 1))!
        let source = [
            MediaRecord(id: "known", creationDate: date, isVideo: true),
            MediaRecord(id: "unknown-b", creationDate: nil, isVideo: false),
            MediaRecord(id: "known", creationDate: date.addingTimeInterval(-86_400), isVideo: false),
            MediaRecord(id: "unknown-a", creationDate: nil, isVideo: true)
        ]

        let album = ChronologicalAlbum(records: source, calendar: calendar)

        XCTAssertEqual(album.records.map(\.id), ["unknown-a", "unknown-b", "known"])
        XCTAssertEqual(album.sections.first?.id, "month:unknown")
        XCTAssertEqual(album.sections.first?.title, "日期未知")
        XCTAssertEqual(album.sections.first?.records.map(\.id), ["unknown-a", "unknown-b"])
        XCTAssertEqual(album.records.filter(\.isVideo).map(\.id), ["unknown-a", "known"])
        XCTAssertEqual(album.sectionID(containing: "known"), album.sections.last?.id)
    }

    func testChronologicalAlbumIndexesTenThousandRecordsInOneMonth() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let month = calendar.date(from: DateComponents(year: 2023, month: 7, day: 1))!
        let source = (0..<10_000).map {
            MediaRecord(
                id: "timeline-\($0)",
                creationDate: month.addingTimeInterval(TimeInterval($0)),
                isVideo: $0.isMultiple(of: 2)
            )
        }

        let album = ChronologicalAlbum(records: source.shuffled(), calendar: calendar)

        XCTAssertEqual(album.records.count, 10_000)
        XCTAssertEqual(album.sections.count, 1)
        XCTAssertEqual(album.sections[0].records.count, 10_000)
        XCTAssertEqual(album.sectionID(containing: "timeline-9999"), album.sections[0].id)
        XCTAssertEqual(Set(album.records.map(\.id)).count, 10_000)
    }
}
