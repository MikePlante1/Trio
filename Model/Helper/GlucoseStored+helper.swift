import CoreData
import Foundation

extension GlucoseStored {
    static func fetch(
        _ predicate: NSPredicate = .all,
        ascending: Bool,
        fetchLimit: Int? = nil,
        batchSize: Int? = nil
    ) -> NSFetchRequest<GlucoseStored> {
        let request = GlucoseStored.fetchRequest()
        request.sortDescriptors = [NSSortDescriptor(keyPath: \GlucoseStored.date, ascending: ascending)]
        request.predicate = predicate
        if let limit = fetchLimit {
            request.fetchLimit = limit
        }
        if let batchSize = batchSize {
            request.fetchBatchSize = batchSize
        }
        return request
    }

    // Preview
    @discardableResult static func makePreviewGlucose(count: Int, provider: CoreDataStack) -> [GlucoseStored] {
        let context = provider.persistentContainer.viewContext
        let baseGlucose = 120
        let glucoseValues = (0 ..< count).map { index -> GlucoseStored in
            let glucose = GlucoseStored(context: context)
            glucose.id = UUID()
            glucose.date = Date.now.addingTimeInterval(Double(index) * -300) // Every 5 minutes
            glucose.glucose = Int16(baseGlucose + (index % 3) * 10) // Varying between 120-140
            glucose.direction = BloodGlucose.Direction.flat.rawValue
            glucose.isManual = false
            glucose.isUploadedToNS = false
            glucose.isUploadedToHealth = false
            glucose.isUploadedToTidepool = false
            return glucose
        }

        try? context.save()
        return glucoseValues
    }
}

extension NSPredicate {
    static var glucose: NSPredicate {
        let date = Date.oneDayAgo
        return NSPredicate(format: "date >= %@", date as NSDate)
    }

    static func glucose(since date: Date) -> NSPredicate {
        NSPredicate(format: "date >= %@", date as NSDate)
    }

    static var manualGlucose: NSPredicate {
        let date = Date.oneDayAgo
        return NSPredicate(format: "isManual == %@ AND date >= %@", true as NSNumber, date as NSDate)
    }

    static var glucoseForStatsDay: NSPredicate {
        let date = Date.oneDayAgo
        return NSPredicate(format: "date >= %@", date as NSDate)
    }

    static var glucoseForStatsToday: NSPredicate {
        let date = Date.startOfToday
        return NSPredicate(format: "date >= %@", date as NSDate)
    }

    static var glucoseForStatsMonth: NSPredicate {
        let date = Date.oneMonthAgo
        return NSPredicate(format: "date >= %@", date as NSDate)
    }

    static var glucoseForStatsTotal: NSPredicate {
        let date = Date.threeMonthsAgo
        return NSPredicate(format: "date >= %@", date as NSDate)
    }

    static var glucoseForStatsWeek: NSPredicate {
        let date = Date.oneWeekAgo
        return NSPredicate(format: "date >= %@", date as NSDate)
    }

    static var glucoseNotYetUploadedToNightscout: NSPredicate {
        let date = Date.oneDayAgo
        return NSPredicate(format: "date >= %@ AND isUploadedToNS == %@", date as NSDate, false as NSNumber)
    }

    static var glucoseNotYetUploadedToHealth: NSPredicate {
        let date = Date.oneDayAgo
        return NSPredicate(format: "date >= %@ AND isUploadedToHealth == %@", date as NSDate, false as NSNumber)
    }

    static var glucoseNotYetUploadedToTidepool: NSPredicate {
        let date = Date.oneDayAgo
        return NSPredicate(format: "date >= %@ AND isUploadedToTidepool == %@", date as NSDate, false as NSNumber)
    }

    static var manualGlucoseNotYetUploadedToHealth: NSPredicate {
        let date = Date.oneDayAgo
        return NSPredicate(
            format: "date >= %@ AND isUploadedToHealth == %@ AND isManual == %@",
            date as NSDate,
            false as NSNumber,
            true as NSNumber
        )
    }

    static var manualGlucoseNotYetUploadedToTidepool: NSPredicate {
        let date = Date.oneDayAgo
        return NSPredicate(
            format: "date >= %@ AND isUploadedToTidepool == %@ AND isManual == %@",
            date as NSDate,
            false as NSNumber,
            true as NSNumber
        )
    }
}

// In order to show the correct direction in the bobble we convert the direction property of the NSManagedObject GlucoseStored back to the Direction type
extension GlucoseStored {
    var directionEnum: BloodGlucose.Direction? {
        BloodGlucose.Direction(rawValue: direction ?? "")
    }
}

enum FiveMinuteCadence {
    static let minimumSpacing: TimeInterval = 4.5 * 60
    /// A gap below this means the two readings are minute-by-minute rather
    /// than a real CGM cadence. Must stay well below
    /// GlucoseDeduplicationInterval.standard, the minimum stored spacing of
    /// every non-minute source.
    static let subFiveMinuteGap: TimeInterval = 2.5 * 60
    /// The longest window any oref path fetches -- autosens' 24 h. determineBasal asks for
    /// maxMealAbsorptionTime + 30 min, which is shorter, so nothing older than this is ever
    /// handed to the algorithm.
    static let algorithmWindow: TimeInterval = 24 * 3600
}

extension Array where Element: GlucoseStored {
    /// Thins minute-by-minute CGM data to the ~5-minute comb, anchored on the
    /// most recent reading and walked backwards. Standard-cadence series are
    /// returned untouched; manual entries always pass through. Must be called
    /// on the elements' managed-object-context queue.
    func thinnedToFiveMinuteCadence() -> [Element] {
        let cgmReadings = filter { !$0.isManual && $0.date != nil }
        guard cgmReadings.count >= 2 else { return self }

        let newestFirst = cgmReadings.sorted { $0.date! > $1.date! }

        var keptIDs = Set<ObjectIdentifier>()
        var lastKeptDate: Date?
        var droppedAny = false
        for (index, reading) in newestFirst.enumerated() {
            let date = reading.date!
            // Cadence is judged per reading, not once for the whole array: a
            // verdict taken across the window follows whichever cadence has
            // more readings, so a mixed window (a 1-minute stretch left behind
            // after the CGM or its forwarding mode changed) strands the other
            // cadence — either 1-minute data reaching oref raw, or a
            // gate-spaced ~4-minute series being decimated to ~8 minutes.
            let neighborGap: TimeInterval = index == 0
                ? .infinity
                : newestFirst[index - 1].date!.timeIntervalSince(date)
            let isStandardCadence = neighborGap >= FiveMinuteCadence.subFiveMinuteGap
            let clearsComb = lastKeptDate.map { $0.timeIntervalSince(date) >= FiveMinuteCadence.minimumSpacing } ?? true
            guard isStandardCadence || clearsComb else {
                droppedAny = true
                continue
            }
            keptIDs.insert(ObjectIdentifier(reading))
            lastKeptDate = date
        }
        guard droppedAny else { return self }

        return filter { $0.isManual || $0.date == nil || keptIDs.contains(ObjectIdentifier($0)) }
    }

    /// Dates of the comb readings the algorithm consumes, restricted to stretches where
    /// thinning actually removed readings.
    ///
    /// A reading is marked only when one of its immediate raw neighbours was dropped, which
    /// is what makes the overlay mean something: where nothing was dropped the comb equals
    /// the stored series and a dot on every reading would say nothing. That also keeps a
    /// window spanning a cadence switch honest -- the minute-by-minute stretch is marked and
    /// the 5-minute stretch beside it is not, rather than the whole window being judged by
    /// one verdict.
    ///
    /// Takes the comb rather than recomputing it, so the marks describe the same list the
    /// caller handed to the algorithm. Must be called on the elements' managed-object-context queue.
    func fiveMinuteCombMarkers(comb: [Element]) -> Set<Date> {
        let cgmReadings = filter { !$0.isManual && $0.date != nil }
        guard cgmReadings.count >= 2 else { return [] }

        let newestFirst = cgmReadings.sorted { $0.date! > $1.date! }
        let kept = Set(comb.map(ObjectIdentifier.init))
        // Nothing dropped anywhere: standard cadence throughout, nothing to mark.
        guard kept.count < newestFirst.count else { return [] }

        var markers: Set<Date> = []
        for (index, reading) in newestFirst.enumerated() {
            let date = reading.date!
            guard kept.contains(ObjectIdentifier(reading)) else { continue }
            let newerDropped = index > 0 && !kept.contains(ObjectIdentifier(newestFirst[index - 1]))
            let olderDropped = index + 1 < newestFirst.count
                && !kept.contains(ObjectIdentifier(newestFirst[index + 1]))
            if newerDropped || olderDropped {
                markers.insert(date)
            }
        }
        return markers
    }
}
