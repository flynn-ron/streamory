import Foundation

/// A month-sized section in the chronological album.
public struct TimelineSection: Identifiable {
    public let id: String
    public let title: String
    public let records: [MediaRecord]

    public init(id: String, title: String, records: [MediaRecord]) {
        self.id = id
        self.title = title
        self.records = records
    }
}

/// Builds the stable, date-ordered data used by the time-travel album.
///
/// This type intentionally only consumes `MediaRecord`; the caller remains
/// responsible for resolving IDs to Photos assets. IDs are de-duplicated
/// before sorting, so a refresh cannot produce duplicate grid cells.
public struct ChronologicalAlbum {
    public let records: [MediaRecord]
    public let sections: [TimelineSection]

    private let sectionIDsByRecordID: [String: String]

    public init(records: [MediaRecord], calendar: Calendar = .current) {
        let uniqueRecords = Self.uniqueRecords(records)
        let sortedRecords = uniqueRecords.sorted(by: Self.isBefore)
        let built = Self.buildSections(sortedRecords, calendar: calendar)

        self.records = sortedRecords
        self.sections = built.sections
        self.sectionIDsByRecordID = built.sectionIDsByRecordID
    }

    /// Returns the month section containing a media ID, or `nil` when the ID
    /// was not present in this album.
    public func sectionID(containing id: String) -> String? {
        sectionIDsByRecordID[id]
    }

    private static func uniqueRecords(_ records: [MediaRecord]) -> [MediaRecord] {
        var seen = Set<String>()
        seen.reserveCapacity(records.count)
        return records.filter { seen.insert($0.id).inserted }
    }

    private static func isBefore(_ lhs: MediaRecord, _ rhs: MediaRecord) -> Bool {
        switch (lhs.creationDate, rhs.creationDate) {
        case (nil, nil):
            return lhs.id < rhs.id
        case (nil, _):
            return true
        case (_, nil):
            return false
        case let (leftDate?, rightDate?):
            if leftDate == rightDate {
                return lhs.id < rhs.id
            }
            return leftDate < rightDate
        }
    }

    private static func buildSections(
        _ records: [MediaRecord],
        calendar: Calendar
    ) -> (sections: [TimelineSection], sectionIDsByRecordID: [String: String]) {
        var sections: [TimelineSection] = []
        sections.reserveCapacity(min(records.count, 12))
        var sectionIDsByRecordID: [String: String] = [:]
        sectionIDsByRecordID.reserveCapacity(records.count)

        var bucket: [MediaRecord] = []
        var bucketID: String?
        var bucketTitle = ""

        // `records` is already sorted, so each month is one contiguous bucket.
        // Moving the finished array into TimelineSection keeps this pass linear.
        for record in records {
            let descriptor = Self.sectionDescriptor(for: record.creationDate, calendar: calendar)
            if descriptor.id != bucketID {
                if let bucketID, !bucket.isEmpty {
                    sections.append(
                        TimelineSection(id: bucketID, title: bucketTitle, records: bucket)
                    )
                }
                bucketID = descriptor.id
                bucketTitle = descriptor.title
                bucket = []
            }
            bucket.append(record)
            sectionIDsByRecordID[record.id] = descriptor.id
        }

        if let bucketID, !bucket.isEmpty {
            sections.append(
                TimelineSection(id: bucketID, title: bucketTitle, records: bucket)
            )
        }

        return (sections, sectionIDsByRecordID)
    }

    private static func sectionDescriptor(
        for date: Date?,
        calendar: Calendar
    ) -> (id: String, title: String) {
        guard
            let date,
            let monthStart = calendar.dateInterval(of: .month, for: date)?.start
        else {
            return ("month:unknown", "日期未知")
        }

        let components = calendar.dateComponents([.year, .month], from: monthStart)
        let year = components.year ?? 0
        let month = components.month ?? 0
        return (
            "month:\(monthStart.timeIntervalSince1970)",
            "\(year)年\(month)月"
        )
    }
}
