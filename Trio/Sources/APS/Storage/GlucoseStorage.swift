import AVFAudio
import Combine
import CoreData
import Foundation
import LoopKit
import SwiftDate
import SwiftUI
import Swinject

protocol GlucoseStorage {
    var updatePublisher: AnyPublisher<Void, Never> { get }
    /// Stores new glucose. Returns `true` if at least one stored reading was flagged as an
    /// algorithm reading (i.e. the loop should run for it).
    @discardableResult func storeGlucose(_ glucose: [BloodGlucose]) async throws -> Bool
    func backfillGlucose(_ glucose: [BloodGlucose]) async throws
    func addManualGlucose(glucose: Int)
    func isGlucoseDataFresh(_ glucoseDate: Date?) -> Bool
    func syncDate() -> Date
    func filterTooFrequentGlucose(_ glucose: [BloodGlucose], at: Date) -> [BloodGlucose]
    func lastGlucoseDate() -> Date?
    func isGlucoseFresh() -> Bool
    func getGlucoseNotYetUploadedToNightscout() async throws -> [BloodGlucose]
    func getCGMStateNotYetUploadedToNightscout() async throws -> [NightscoutTreatment]
    func getGlucoseNotYetUploadedToHealth() async throws -> [BloodGlucose]
    func getManualGlucoseNotYetUploadedToHealth() async throws -> [BloodGlucose]
    func getGlucoseNotYetUploadedToTidepool() async throws -> [StoredGlucoseSample]
    func getManualGlucoseNotYetUploadedToTidepool() async throws -> [StoredGlucoseSample]
//    func getGlucoseStatus() async throws -> GlucoseStatus? // FIXME: prepared for later use
    var alarm: GlucoseAlarm? { get }
    func deleteGlucose(_ treatmentObjectID: NSManagedObjectID) async
}

final class BaseGlucoseStorage: GlucoseStorage, Injectable {
    private let processQueue = DispatchQueue(label: "BaseGlucoseStorage.processQueue")
    @Injected() private var storage: FileStorage!
    @Injected() private var broadcaster: Broadcaster!
    @Injected() private var settingsManager: SettingsManager!

    private let updateSubject = PassthroughSubject<Void, Never>()

    var updatePublisher: AnyPublisher<Void, Never> {
        updateSubject.eraseToAnyPublisher()
    }

    private enum Config {
        /// Freshness window for `isGlucoseFresh()` — how recent the latest reading must be.
        static let filterTime: TimeInterval = 3.5 * 60
        /// Minimum spacing between *stored* readings (dedup / anti-flood). Kept well under
        /// 60s so a native 1-minute CGM (e.g. Libre 3) is stored at full resolution for
        /// display. This used to share `filterTime` (3.5 min), which thinned 1-min data to
        /// ~4 min.
        static let minimumGlucoseInterval: TimeInterval = 30
        /// Minimum spacing between readings flagged as *algorithm readings* (handed to oref
        /// and used to drive the loop). A reading is flagged when it is at least this far
        /// after the previous algorithm reading, so a native 1-minute CGM collapses to one
        /// reading per ~5 min — the cadence oref, autosens and COB expect — while full 1-min
        /// data is still stored for display. ~4.5 min tolerates CGM jitter; no-op for a true
        /// 5-min CGM (every reading is flagged).
        static let algorithmReadingInterval: TimeInterval = 4.5 * 60
        static let minimumGlucose: Int = 39
    }

    private let context: NSManagedObjectContext

    init(resolver: Resolver, context: NSManagedObjectContext? = nil) {
        self.context = context ?? CoreDataStack.shared.newTaskContext()
        injectServices(resolver)
    }

    private var glucoseFormatter: NumberFormatter {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
        if settingsManager.settings.units == .mmolL {
            formatter.maximumFractionDigits = 1
        }
        formatter.decimalSeparator = "."
        return formatter
    }

    /// Backfills glucose values and stores in CoreData
    ///
    /// CGM managers will sometimes backfill glucose readings. To handle these backfilled values
    /// correctly, we need some logic to handle a few cases:
    ///  - _Not_ adding back previously deleted glucose
    ///  - Avoiding duplicate values for the same reading
    ///  - Avoiding overlapping glucose readings when switching sources
    ///  Of these corner cases, overlapping glucose readings when switching sources is both
    ///  the most challenging and most rare since it would happen if wearing two devices and
    ///  switching or moving from direct glucose handling to xdrip. It's not worth the complexity
    ///  to deal with source switching perfectly, so instead we will backfill glucose if and only if
    ///  it isn't within `Config.minimumGlucoseInterval` of an existing glucose reading, which is simple but not perfect.
    ///  But since this is a corner case that really shouldn't happen often, it's good enough.
    func backfillGlucose(_ glucose: [BloodGlucose]) async throws {
        let clamped = clampToMinimum(glucose)
        try await context.perform {
            // remove already deleted glucose values
            let withoutDeletedGlucose = self.filterGlucoseValues(
                clamped,
                fetchRequest: DeletedGlucoseStored.fetchRequest(),
                timeBuffer: 1
            )

            // drop backfilled values landing within the minimum-interval window of an
            // existing reading (see Config.minimumGlucoseInterval)
            let filteredGlucose = self.filterGlucoseValues(
                withoutDeletedGlucose,
                fetchRequest: GlucoseStored.fetchRequest(),
                timeBuffer: Config.minimumGlucoseInterval
            )

            guard !filteredGlucose.isEmpty else { return }

            // Flag backfilled readings at ~5-min cadence relative to the last algorithm
            // reading before the gap.
            let algorithmDates = self.algorithmReadingDates(for: filteredGlucose)

            do {
                // Store glucose values in Core Data
                try self.storeGlucoseInCoreData(filteredGlucose, algorithmDates: algorithmDates)
            } catch {
                throw CoreDataError.creationError(
                    function: #function,
                    file: #fileID
                )
            }
        }
    }

    @discardableResult func storeGlucose(_ glucose: [BloodGlucose]) async throws -> Bool {
        let clamped = clampToMinimum(glucose)
        return try await context.perform {
            // Get new glucose values that don't exist yet
            let newGlucose = self.filterGlucoseValues(clamped, fetchRequest: GlucoseStored.fetchRequest(), timeBuffer: 1)
            guard !newGlucose.isEmpty else { return false }

            // Decide which of these readings the algorithm should consume (~5-min cadence)
            let algorithmDates = self.algorithmReadingDates(for: newGlucose)

            do {
                // Store glucose values in Core Data
                try self.storeGlucoseInCoreData(newGlucose, algorithmDates: algorithmDates)
            } catch {
                throw CoreDataError.creationError(
                    function: #function,
                    file: #fileID
                )
            }

            // Store CGM state if needed
            self.storeCGMState(clamped)

            return !algorithmDates.isEmpty
        }
    }

    /// Clamps CGM-sourced glucose readings to a minimum of `Config.minimumGlucose`
    /// (39 mg/dL — the official Libre/Dexcom algorithmic floor). Some CGM plugins
    /// (notably LibreTransmitter) deliberately bypass the vendor floor and forward
    /// values down to 1 mg/dL; the JS oref `glucose-get-last` filter then drops them
    /// (`> 38`) and the loop has no fresh BG during the most dangerous range. We
    /// clamp here so determination always has a usable value and emit a debug log
    /// line so the raw reading survives for diagnostics.
    private func clampToMinimum(_ glucose: [BloodGlucose]) -> [BloodGlucose] {
        glucose.map { entry in
            var clamped = entry
            if let raw = entry.glucose, raw < Config.minimumGlucose {
                debug(
                    .deviceManager,
                    "Clamping sub-\(Config.minimumGlucose) glucose: raw=\(raw) at \(entry.dateString) -> \(Config.minimumGlucose)"
                )
                clamped.glucose = Config.minimumGlucose
            }
            if let raw = entry.sgv, raw < Config.minimumGlucose {
                clamped.sgv = Config.minimumGlucose
            }
            return clamped
        }
    }

    /// filter out duplicate CGM readings using matching timestamps
    ///
    /// This function will fetch dates from the `fetchRequest` and remove any glucose
    /// values that are within `timeBuffer` of the fetched dates. This logic is useful for
    /// deduplication checks or removing deleted CGM values from a list of backfilled readings.
    private func filterGlucoseValues(
        _ glucose: [BloodGlucose],
        fetchRequest: NSFetchRequest<NSFetchRequestResult>,
        timeBuffer: TimeInterval
    ) -> [BloodGlucose] {
        let datesToCheck = glucose.map(\.dateString).sorted()
        guard let firstDate = datesToCheck.first.map({ $0.addingTimeInterval(-timeBuffer) }),
              let lastDate = datesToCheck.last.map({ $0.addingTimeInterval(timeBuffer) })
        else {
            return glucose
        }
        fetchRequest.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
            NSPredicate(format: "date >= %@", firstDate as NSDate),
            NSPredicate(format: "date <= %@", lastDate as NSDate)
        ])
        fetchRequest.propertiesToFetch = ["date"]
        fetchRequest.resultType = .dictionaryResultType

        var existingDates = [Date]()
        do {
            let results = try context.fetch(fetchRequest) as? [NSDictionary]
            existingDates = results?.compactMap({ $0["date"] as? Date }) ?? []
        } catch {
            debugPrint("Failed to fetch existing glucose dates: \(error)")
        }

        // This is an inefficient filtering algorithm, but I'm assuming that the
        // time spans are short and that duplicates are rare, so in the common
        // case there won't be any existing dates.
        return glucose.filter { glucose in
            for existingDate in existingDates {
                let difference = abs(existingDate.timeIntervalSince(glucose.dateString))
                if difference <= timeBuffer {
                    return false
                }
            }
            return true
        }
    }

    private func storeGlucoseInCoreData(_ glucose: [BloodGlucose], algorithmDates: Set<Date>) throws {
        if glucose.count > 1 {
            try storeGlucoseBatch(glucose, algorithmDates: algorithmDates)
        } else {
            try storeGlucoseRegular(glucose, algorithmDates: algorithmDates)
        }
    }

    /// Determines which of `newGlucose` should be flagged as algorithm readings (the ones
    /// oref consumes and that drive the loop). A reading qualifies when it is at least
    /// `Config.algorithmReadingInterval` after the previous algorithm reading, anchored to
    /// the most recent algorithm reading already stored before this batch. A true 5-minute
    /// CGM flags every reading; a 1-minute CGM flags ~every fifth. Must run on `context`.
    private func algorithmReadingDates(for newGlucose: [BloodGlucose]) -> Set<Date> {
        let sorted = newGlucose.sorted { $0.dateString < $1.dateString }
        guard let earliest = sorted.first?.dateString else { return [] }

        // Anchor to the last algorithm reading already stored before this batch.
        let request = GlucoseStored.fetchRequest()
        request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
            NSPredicate(format: "isAlgorithmReading == YES"),
            NSPredicate(format: "date < %@", earliest as NSDate)
        ])
        request.sortDescriptors = [NSSortDescriptor(keyPath: \GlucoseStored.date, ascending: false)]
        request.fetchLimit = 1
        request.propertiesToFetch = ["date"]

        var lastAlgorithmDate = (try? context.fetch(request))?.first?.date ?? .distantPast

        var algorithmDates = Set<Date>()
        for entry in sorted {
            let date = entry.dateString
            if date.timeIntervalSince(lastAlgorithmDate) >= Config.algorithmReadingInterval {
                algorithmDates.insert(date)
                lastAlgorithmDate = date
            }
        }
        return algorithmDates
    }

    private func storeGlucoseRegular(_ glucose: [BloodGlucose], algorithmDates: Set<Date>) throws {
        for entry in glucose {
            let glucoseEntry = GlucoseStored(context: context)
            configureGlucoseEntry(glucoseEntry, with: entry, isAlgorithmReading: algorithmDates.contains(entry.dateString))
        }

        guard context.hasChanges else { return }
        try context.save()
        updateSubject.send()
    }

    private func storeGlucoseBatch(_ glucose: [BloodGlucose], algorithmDates: Set<Date>) throws {
        var remainingGlucose = glucose
        let batchInsert = NSBatchInsertRequest(
            entity: GlucoseStored.entity(),
            managedObjectHandler: { (managedObject: NSManagedObject) -> Bool in
                guard let glucoseEntry = managedObject as? GlucoseStored,
                      !remainingGlucose.isEmpty
                else {
                    return true
                }
                let entry = remainingGlucose.removeFirst()
                self.configureGlucoseEntry(
                    glucoseEntry,
                    with: entry,
                    isAlgorithmReading: algorithmDates.contains(entry.dateString)
                )
                return false
            }
        )
        try context.execute(batchInsert)
        updateSubject.send()
    }

    private func configureGlucoseEntry(_ entry: GlucoseStored, with glucose: BloodGlucose, isAlgorithmReading: Bool) {
        entry.id = UUID()
        entry.glucose = Int16(glucose.glucose ?? 0)
        entry.date = glucose.dateString
        entry.direction = glucose.direction?.rawValue
        entry.isAlgorithmReading = isAlgorithmReading
        entry.isUploadedToNS = false
        entry.isUploadedToHealth = false
        entry.isUploadedToTidepool = false
    }

    private func storeCGMState(_ glucose: [BloodGlucose]) {
        debug(.deviceManager, "start storage cgmState")
        storage.transaction { storage in
            let file = OpenAPS.Monitor.cgmState
            var treatments = storage.retrieve(file, as: [NightscoutTreatment].self) ?? []
            var updated = false

            for x in glucose {
                guard let sessionStartDate = x.sessionStartDate else { continue }

                // Skip if we already have a recent treatment
                if let lastTreatment = treatments.last,
                   let createdAt = lastTreatment.createdAt,
                   abs(createdAt.timeIntervalSince(sessionStartDate)) < TimeInterval(60)
                {
                    continue
                }

                let notes = createCGMStateNotes(transmitterID: x.transmitterID, activationDate: x.activationDate)
                let treatment = createCGMStateTreatment(sessionStartDate: sessionStartDate, notes: notes)

                debug(.deviceManager, "CGM sensor change \(treatment)")
                treatments.append(treatment)
                updated = true
            }

            if updated {
                storage.save(
                    treatments.filter { $0.createdAt?.addingTimeInterval(30.days.timeInterval) ?? .distantPast > Date() },
                    as: file
                )
            }
        }
    }

    private func createCGMStateNotes(transmitterID: String?, activationDate: Date?) -> String {
        var notes = ""
        if let t = transmitterID {
            notes = t
        }
        if let a = activationDate {
            notes = "\(notes) activated on \(a)"
        }
        return notes
    }

    private func createCGMStateTreatment(sessionStartDate: Date, notes: String) -> NightscoutTreatment {
        NightscoutTreatment(
            duration: nil,
            rawDuration: nil,
            rawRate: nil,
            absolute: nil,
            rate: nil,
            eventType: .nsSensorChange,
            createdAt: sessionStartDate,
            enteredBy: NightscoutTreatment.local,
            bolus: nil,
            insulin: nil,
            notes: notes,
            carbs: nil,
            fat: nil,
            protein: nil,
            targetTop: nil,
            targetBottom: nil
        )
    }

    func addManualGlucose(glucose: Int) {
        context.perform {
            let newItem = GlucoseStored(context: self.context)
            newItem.id = UUID()
            newItem.date = Date()
            newItem.glucose = Int16(glucose)
            newItem.isManual = true
            // Manual fingersticks are always handed to the algorithm.
            newItem.isAlgorithmReading = true
            newItem.isUploadedToNS = false
            newItem.isUploadedToHealth = false
            newItem.isUploadedToTidepool = false

            do {
                guard self.context.hasChanges else { return }
                try self.context.save()

                // Glucose subscribers already listen to the update publisher, so call here to update glucose-related data.
                self.updateSubject.send()
            } catch let error as NSError {
                debugPrint(
                    "\(DebuggingIdentifiers.failed) \(#file) \(#function) Failed to save manual glucose to Core Data with error: \(error)"
                )
            }
        }
    }

    func isGlucoseDataFresh(_ glucoseDate: Date?) -> Bool {
        guard let glucoseDate = glucoseDate else { return false }
        return glucoseDate > Date().addingTimeInterval(-6 * 60)
    }

    func syncDate() -> Date {
        // Optimize fetch request to only get the date
        let taskContext = CoreDataStack.shared.newTaskContext()
        let fr = NSFetchRequest<NSDictionary>(entityName: "GlucoseStored")
        fr.predicate = NSPredicate.predicateForOneDayAgo
        fr.propertiesToFetch = ["date"]
        fr.fetchLimit = 1
        fr.resultType = .dictionaryResultType
        fr.sortDescriptors = [NSSortDescriptor(key: "date", ascending: false)]

        var fetchedDate: Date = .distantPast

        taskContext.performAndWait {
            do {
                if let result = try taskContext.fetch(fr).first,
                   let date = result["date"] as? Date
                {
                    fetchedDate = date
                }
            } catch {
                debugPrint("Fetch error: \(DebuggingIdentifiers.failed) \(error)")
            }
        }

        return fetchedDate
    }

    func lastGlucoseDate() -> Date? {
        let fetchRequest = GlucoseStored.fetchRequest()
        fetchRequest.predicate = NSPredicate.predicateForOneDayAgo
        fetchRequest.sortDescriptors = [NSSortDescriptor(keyPath: \GlucoseStored.date, ascending: false)]
        fetchRequest.fetchLimit = 1

        var date: Date?
        context.performAndWait {
            do {
                let results = try self.context.fetch(fetchRequest)
                date = results.first?.date
            } catch let error as NSError {
                debug(.storage, "Fetch error: \(DebuggingIdentifiers.failed) \(error), \(error.userInfo)")
            }
        }

        return date
    }

    func isGlucoseFresh() -> Bool {
        Date().timeIntervalSince(lastGlucoseDate() ?? .distantPast) <= Config.filterTime
    }

    func filterTooFrequentGlucose(_ glucose: [BloodGlucose], at date: Date) -> [BloodGlucose] {
        var lastDate = date
        var filtered: [BloodGlucose] = []
        let sorted = glucose.sorted { $0.date < $1.date }

        for entry in sorted {
            guard entry.dateString.addingTimeInterval(-Config.minimumGlucoseInterval) > lastDate else {
                continue
            }
            filtered.append(entry)
            lastDate = entry.dateString
        }

        return filtered
    }

    func fetchLatestGlucose() throws -> GlucoseStored? {
        let predicate = NSPredicate.predicateFor20MinAgo
        return (try CoreDataStack.shared.fetchEntities(
            ofType: GlucoseStored.self,
            onContext: context,
            predicate: predicate,
            key: "date",
            ascending: false,
            fetchLimit: 1
        ) as? [GlucoseStored] ?? []).first
    }

    // Fetch glucose that is not uploaded to Nightscout yet
    /// - Returns: Array of BloodGlucose to ensure the correct format for the NS Upload
    func getGlucoseNotYetUploadedToNightscout() async throws -> [BloodGlucose] {
        let results = try await CoreDataStack.shared.fetchEntitiesAsync(
            ofType: GlucoseStored.self,
            onContext: context,
            predicate: NSPredicate.glucoseNotYetUploadedToNightscout,
            key: "date",
            ascending: false
        )

        return try await context.perform {
            guard let fetchedResults = results as? [GlucoseStored] else {
                throw CoreDataError.fetchError(function: #function, file: #file)
            }

            return fetchedResults.map { result in
                if result.isManual {
                    BloodGlucose(
                        id: result.id?.uuidString ?? UUID().uuidString,
                        mbg: Int(result.glucose),
                        date: Decimal(result.date?.timeIntervalSince1970 ?? Date().timeIntervalSince1970) * 1000,
                        dateString: result.date ?? Date(),
                        type: "mbg"
                    )
                } else {
                    BloodGlucose(
                        id: result.id?.uuidString ?? UUID().uuidString,
                        sgv: Int(result.glucose),
                        direction: BloodGlucose.Direction(from: result.direction ?? ""),
                        date: Decimal(result.date?.timeIntervalSince1970 ?? Date().timeIntervalSince1970) * 1000,
                        dateString: result.date ?? Date(),
                        unfiltered: Decimal(result.glucose),
                        filtered: Decimal(result.glucose),
                        noise: nil,
                        glucose: Int(result.glucose),
                        type: "sgv"
                    )
                }
            }
        }
    }

    func getCGMStateNotYetUploadedToNightscout() async -> [NightscoutTreatment] {
        async let alreadyUploaded: [NightscoutTreatment] = storage
            .retrieveAsync(OpenAPS.Nightscout.uploadedCGMState, as: [NightscoutTreatment].self) ?? []
        async let allValues: [NightscoutTreatment] = storage
            .retrieveAsync(OpenAPS.Monitor.cgmState, as: [NightscoutTreatment].self) ?? []

        let (alreadyUploadedValues, allValuesSet) = await (alreadyUploaded, allValues)
        return Array(Set(allValuesSet).subtracting(Set(alreadyUploadedValues)))
    }

    // Fetch glucose that is not uploaded to Nightscout yet
    /// - Returns: Array of BloodGlucose to ensure the correct format for the NS Upload
    func getGlucoseNotYetUploadedToHealth() async throws -> [BloodGlucose] {
        let results = try await CoreDataStack.shared.fetchEntitiesAsync(
            ofType: GlucoseStored.self,
            onContext: context,
            predicate: NSPredicate.glucoseNotYetUploadedToHealth,
            key: "date",
            ascending: false
        )

        return try await context.perform {
            guard let fetchedResults = results as? [GlucoseStored] else {
                throw CoreDataError.fetchError(function: #function, file: #file)
            }

            return fetchedResults.map { result in
                BloodGlucose(
                    id: result.id?.uuidString ?? UUID().uuidString,
                    sgv: Int(result.glucose),
                    direction: BloodGlucose.Direction(from: result.direction ?? ""),
                    date: Decimal(result.date?.timeIntervalSince1970 ?? Date().timeIntervalSince1970) * 1000,
                    dateString: result.date ?? Date(),
                    unfiltered: Decimal(result.glucose),
                    filtered: Decimal(result.glucose),
                    noise: nil,
                    glucose: Int(result.glucose)
                )
            }
        }
    }

    // Fetch manual glucose that is not uploaded to Nightscout yet
    /// - Returns: Array of NightscoutTreatment to ensure the correct format for the NS Upload
    func getManualGlucoseNotYetUploadedToHealth() async throws -> [BloodGlucose] {
        let results = try await CoreDataStack.shared.fetchEntitiesAsync(
            ofType: GlucoseStored.self,
            onContext: context,
            predicate: NSPredicate.manualGlucoseNotYetUploadedToHealth,
            key: "date",
            ascending: false
        )

        return try await context.perform {
            guard let fetchedResults = results as? [GlucoseStored] else {
                throw CoreDataError.fetchError(function: #function, file: #file)
            }

            return fetchedResults.map { result in
                BloodGlucose(
                    id: result.id?.uuidString ?? UUID().uuidString,
                    sgv: Int(result.glucose),
                    direction: BloodGlucose.Direction(from: result.direction ?? ""),
                    date: Decimal(result.date?.timeIntervalSince1970 ?? Date().timeIntervalSince1970) * 1000,
                    dateString: result.date ?? Date(),
                    unfiltered: Decimal(result.glucose),
                    filtered: Decimal(result.glucose),
                    noise: nil,
                    glucose: Int(result.glucose)
                )
            }
        }
    }

    // Fetch glucose that is not uploaded to Tidepool yet
    /// - Returns: Array of StoredGlucoseSample to ensure the correct format for Tidepool upload
    func getGlucoseNotYetUploadedToTidepool() async throws -> [StoredGlucoseSample] {
        let results = try await CoreDataStack.shared.fetchEntitiesAsync(
            ofType: GlucoseStored.self,
            onContext: context,
            predicate: NSPredicate.glucoseNotYetUploadedToTidepool,
            key: "date",
            ascending: false
        )

        return try await context.perform {
            guard let fetchedResults = results as? [GlucoseStored] else {
                throw CoreDataError.fetchError(function: #function, file: #file)
            }

            return fetchedResults.map { result in
                BloodGlucose(
                    id: result.id?.uuidString ?? UUID().uuidString,
                    sgv: Int(result.glucose),
                    direction: BloodGlucose.Direction(from: result.direction ?? ""),
                    date: Decimal(result.date?.timeIntervalSince1970 ?? Date().timeIntervalSince1970) * 1000,
                    dateString: result.date ?? Date(),
                    unfiltered: Decimal(result.glucose),
                    filtered: Decimal(result.glucose),
                    noise: nil,
                    glucose: Int(result.glucose)
                )
            }
            .map { $0.convertStoredGlucoseSample(isManualGlucose: false) }
        }
    }

    // Fetch manual glucose that is not uploaded to Tidepool yet
    /// - Returns: Array of StoredGlucoseSample to ensure the correct format for the Tidepool upload
    func getManualGlucoseNotYetUploadedToTidepool() async throws -> [StoredGlucoseSample] {
        let results = try await CoreDataStack.shared.fetchEntitiesAsync(
            ofType: GlucoseStored.self,
            onContext: context,
            predicate: NSPredicate.manualGlucoseNotYetUploadedToTidepool,
            key: "date",
            ascending: false
        )

        return try await context.perform {
            guard let fetchedResults = results as? [GlucoseStored] else {
                throw CoreDataError.fetchError(function: #function, file: #file)
            }

            return fetchedResults.map { result in
                BloodGlucose(
                    id: result.id?.uuidString ?? UUID().uuidString,
                    sgv: Int(result.glucose),
                    direction: BloodGlucose.Direction(from: result.direction ?? ""),
                    date: Decimal(result.date?.timeIntervalSince1970 ?? Date().timeIntervalSince1970) * 1000,
                    dateString: result.date ?? Date(),
                    unfiltered: Decimal(result.glucose),
                    filtered: Decimal(result.glucose),
                    noise: nil,
                    glucose: Int(result.glucose)
                )
            }.map { $0.convertStoredGlucoseSample(isManualGlucose: true) }
        }
    }

    // FIXME: use this after we know oref-swift is good
//    /// Fetches the most recent glucose readings from Core Data, filters and smooths them,
//    /// and computes rolling delta statistics (last, short-term, and long-term).
//    ///
//    /// Mirrors JavaScript oref `glucose-get-last.js` logic.
//    ///
//    /// - Returns: A `GlucoseStatus` containing:
//    ///   - `glucose`: the most recent glucose value (mg/dL),
//    ///   - `delta`: the 5-minute delta (mg/dL per 5m),
//    ///   - `shortAvgDelta`: the average delta over ~5–15 minutes,
//    ///   - `longAvgDelta`: the average delta over ~20–40 minutes,
//    ///   - `noise`: the CGM noise level (if any),
//    ///   - `date`: the timestamp of the “now” reading,
//    ///   - `lastCalIndex`: index of the last calibration record (always `nil` here),
//    ///   - `device`: the source device string.
//    ///
//    /// - Throws: Any `CoreDataError` or other error encountered during fetch or context work.
//    /// - Returns: `nil` if no valid glucose readings are found in the past day.
//    public func getGlucoseStatus() async throws -> GlucoseStatus? {
//        let results = try await CoreDataStack.shared.fetchEntitiesAsync(
//            ofType: GlucoseStored.self,
//            onContext: context,
//            predicate: NSPredicate(
//                format: "date >= %@ AND isManual == %@",
//                Date.oneDayAgoInMinutes as NSDate,
//                false as NSNumber
//            ),
//            key: "date",
//            ascending: false
//        )
//
//        guard let stored = results as? [GlucoseStored], !stored.isEmpty else {
//            return nil
//        }
//
//        let validReadings: [BloodGlucose] = await context.perform {
//            stored.compactMap { entry in
//                BloodGlucose(
//                    _id: entry.id?.uuidString ?? UUID().uuidString,
//                    sgv: Int(entry.glucose),
//                    direction: BloodGlucose.Direction(from: entry.direction ?? ""),
//                    date: Decimal(entry.date?.timeIntervalSince1970 ?? Date().timeIntervalSince1970) * 1000,
//                    dateString: entry.date ?? Date(),
//                    unfiltered: Decimal(entry.glucose),
//                    filtered: Decimal(entry.glucose),
//                    noise: nil,
//                    glucose: Int(entry.glucose),
//                    type: "sgv"
//                )
//            }
//        }
//
//        guard !validReadings.isEmpty else {
//            return nil
//        }
//
//        // Sort descending (newest first)
//        let sorted = validReadings.sorted { $0.date > $1.date }
//
//        let mostRecentGlucose = sorted[0]
//        var mostRecentGlucoseReading: Int = mostRecentGlucose.glucose!
//        var mostRecentGlucoseDate: Date = mostRecentGlucose.dateString
//
//        var lastDeltas: [Decimal] = []
//        var shortDeltas: [Decimal] = []
//        var longDeltas: [Decimal] = []
//
//        // Walk older entries to compute deltas
//        for entry in sorted.dropFirst() {
//            // JS oref has logic here around skipping calibration readings.
//            // We never calibration record (never happens here, since type=="sgv")
//            // so we omit this check
//
//            // only use readings >38 mg/dL (to skip code values, <39)
//            guard let glucose = entry.glucose, glucose > 38 else { continue }
//
//            let minutesAgo = mostRecentGlucoseDate.timeIntervalSince(entry.dateString) / 60
//            guard minutesAgo != 0 else { continue }
//            // compute mg/dL per 5 m as a Decimal:
//            let change = Decimal(mostRecentGlucoseReading - glucose)
//            let avgDelta = (change / Decimal(minutesAgo)) * Decimal(5)
//
//            // very-recent (<2.5 m) smooths "now"
//            if minutesAgo > -2, minutesAgo <= 2.5 {
//                mostRecentGlucoseReading = (mostRecentGlucoseReading + glucose) / 2
//                mostRecentGlucoseDate = Date(
//                    timeIntervalSince1970: (
//                        mostRecentGlucoseDate.timeIntervalSince1970 + entry.dateString
//                            .timeIntervalSince1970
//                    ) / 2
//                )
//            }
//            // short window (~5–15 m)
//            else if minutesAgo > 2.5, minutesAgo <= 17.5 {
//                shortDeltas.append(avgDelta)
//                if minutesAgo < 7.5 {
//                    lastDeltas.append(avgDelta)
//                }
//            }
//            // long window (~20–40 m)
//            else if minutesAgo > 17.5, minutesAgo < 42.5 {
//                longDeltas.append(avgDelta)
//            }
//        }
//
//        // compute means (or zero)
//        let lastDelta: Decimal = lastDeltas.mean
//        let shortAvg: Decimal = shortDeltas.mean
//        let longAvg: Decimal = longDeltas.mean
//
//        return GlucoseStatus(
//            delta: lastDelta.rounded(toPlaces: 2),
//            glucose: Decimal(mostRecentGlucoseReading),
//            noise: Int(sorted[0].noise ?? 0),
//            shortAvgDelta: shortAvg.rounded(toPlaces: 2),
//            longAvgDelta: longAvg.rounded(toPlaces: 2),
//            date: mostRecentGlucoseDate,
//            lastCalIndex: nil,
//            device: settingsManager.settings.cgm.rawValue
//        )
//    }

    func deleteGlucose(_ treatmentObjectID: NSManagedObjectID) async {
        // Use injected context if available, otherwise create new task context
        let taskContext = context != CoreDataStack.shared.newTaskContext()
            ? context
            : CoreDataStack.shared.newTaskContext()
        taskContext.name = "deleteContext"
        taskContext.transactionAuthor = "deleteGlucose"

        await taskContext.perform {
            do {
                let result = try taskContext.existingObject(with: treatmentObjectID) as? GlucoseStored

                guard let glucoseToDelete = result else {
                    debugPrint("Data Table State: \(#function) \(DebuggingIdentifiers.failed) glucose not found in core data")
                    return
                }

                // Create a new DeletedGlucoseStored object and copy the properties
                if let date = glucoseToDelete.date {
                    let deletedEntry = DeletedGlucoseStored(context: taskContext)
                    deletedEntry.date = date
                    deletedEntry.glucose = glucoseToDelete.glucose
                    deletedEntry.isManualGlucoseEntry = glucoseToDelete.isManual
                }

                taskContext.delete(glucoseToDelete)

                guard taskContext.hasChanges else { return }
                try taskContext.save()
                debugPrint("\(#file) \(#function) \(DebuggingIdentifiers.succeeded) deleted glucose from core data")
            } catch {
                debugPrint(
                    "\(#file) \(#function) \(DebuggingIdentifiers.failed) error while deleting glucose from core data: \(error)"
                )
            }
        }
    }

    var alarm: GlucoseAlarm? {
        /// glucose can not be older than 20 minutes due to the predicate in the fetch request
        context.performAndWait {
            do {
                guard let glucose = try fetchLatestGlucose() else { return nil }

                let glucoseValue = glucose.glucose

                if Decimal(glucoseValue) <= settingsManager.settings.low {
                    return .low
                }

                if Decimal(glucoseValue) >= settingsManager.settings.high {
                    return .high
                }

                return nil
            } catch {
                debugPrint("Error fetching latest glucose: \(error)")
                return nil
            }
        }
    }
}

protocol GlucoseObserver {
    func glucoseDidUpdate(_ glucose: [BloodGlucose])
}

enum GlucoseAlarm {
    case high
    case low

    var displayName: String {
        switch self {
        case .high:
            return String(localized: "LOWALERT!", comment: "LOWALERT!")
        case .low:
            return String(localized: "HIGHALERT!", comment: "HIGHALERT!")
        }
    }
}
