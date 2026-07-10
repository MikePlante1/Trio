import Combine
import CoreData
import CryptoKit
import Foundation
import HealthKit
import LoopKit
import LoopKitUI
import Swinject
import TidepoolServiceKit
import UIKit

protocol TidepoolManager {
    func addTidepoolService(service: Service)
    func getTidepoolServiceUI() -> ServiceUI?
    func getTidepoolPluginHost() -> PluginHost?
    func uploadCarbs() async
    func deleteCarbs(withSyncId id: UUID, carbs: Decimal, at: Date, enteredBy: String)
    func uploadInsulin() async
    func deleteInsulin(withSyncId id: String, amount: Decimal, at: Date)
    func uploadGlucose() async
    func uploadSettings() async
    func forceTidepoolDataUpload()
}

final class BaseTidepoolManager: TidepoolManager, Injectable {
    @Injected() private var broadcaster: Broadcaster!
    @Injected() private var pluginManager: PluginManager!
    @Injected() private var glucoseStorage: GlucoseStorage!
    @Injected() private var carbsStorage: CarbsStorage!
    @Injected() private var storage: FileStorage!
    @Injected() private var pumpHistoryStorage: PumpHistoryStorage!
    @Injected() private var apsManager: APSManager!
    @Injected() private var settingsManager: SettingsManager!
    @Injected() private var notificationCenter: NotificationCenter!

    // Lazy access to avoid circular dependency (TidepoolManager ↔ FetchGlucoseManager)
    private var resolver: Resolver?

    private let processQueue = DispatchQueue(label: "BaseNetworkManager.processQueue")

    /// Serializes uploads so only one request is in flight at a time. Concurrent uploads can each
    /// trigger a session refresh that reuses the single-use refresh token, corrupting the session.
    private let uploadSerializer = TidepoolUploadSerializer()

    /// Pending debounce work item for settings upload; cancelled and rescheduled
    /// each time an observer fires, so rapid changes coalesce into one upload.
    /// - Important: Only access from `processQueue` to ensure thread safety.
    private var pendingSettingsUpload: DispatchWorkItem?

    /// Delay before a debounced settings upload fires.
    private static let settingsUploadDebounceDelay: TimeInterval = 1.5

    /// Last-seen therapy-relevant TrioSettings values.
    /// Used to filter `settingsDidChange` so UI-only changes don't trigger uploads.
    private var lastClosedLoop: Bool?
    private var lastUnits: GlucoseUnits?
    private var tidepoolService: RemoteDataService? {
        didSet {
            if let tidepoolService = tidepoolService {
                rawTidepoolManager = tidepoolService.rawValue
            } else {
                rawTidepoolManager = nil
            }
        }
    }

    private var backgroundContext = CoreDataStack.shared.newTaskContext()

    // Queue for handling Core Data change notifications
    private let queue = DispatchQueue(label: "BaseTidepoolManager.queue", qos: .background)
    private var coreDataPublisher: AnyPublisher<Set<NSManagedObjectID>, Never>?
    private var subscriptions = Set<AnyCancellable>()

    @PersistedProperty(key: "TidepoolState") var rawTidepoolManager: Service.RawValue?

    init(resolver: Resolver) {
        self.resolver = resolver
        injectServices(resolver)
        loadTidepoolManager()

        coreDataPublisher =
            changedObjectsOnManagedObjectContextDidSavePublisher()
                .receive(on: queue)
                .share()
                .eraseToAnyPublisher()

        glucoseStorage.updatePublisher
            .receive(on: DispatchQueue.global(qos: .background))
            .sink { [weak self] _ in
                guard let self = self else { return }
                Task {
                    await self.uploadGlucose()
                }
            }
            .store(in: &subscriptions)

        // Enqueues stall while the pipeline is backlogged, so foregrounding is the reliable
        // recovery point for a wedged upload chain.
        notificationCenter
            .publisher(for: UIApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in
                guard let self = self else { return }
                Task(priority: .utility) { await self.uploadSerializer.recoverIfWedged() }
            }
            .store(in: &subscriptions)

        registerHandlers()
    }

    /// Loads the Tidepool service from saved state
    fileprivate func loadTidepoolManager() {
        if let rawTidepoolManager = rawTidepoolManager {
            tidepoolService = tidepoolServiceFromRaw(rawTidepoolManager)
            tidepoolService?.serviceDelegate = self
            tidepoolService?.stateDelegate = self
        }
    }

    /// Returns the Tidepool service UI if available
    func getTidepoolServiceUI() -> ServiceUI? {
        tidepoolService as? ServiceUI
    }

    /// Returns the Tidepool plugin host
    func getTidepoolPluginHost() -> PluginHost? {
        self as PluginHost
    }

    /// Adds a Tidepool service
    func addTidepoolService(service: Service) {
        tidepoolService = service as? RemoteDataService
    }

    /// Loads the Tidepool service from raw stored data
    private func tidepoolServiceFromRaw(_ rawValue: [String: Any]) -> RemoteDataService? {
        let serviceType = TidepoolService.self
        guard let rawState = rawValue["state"] as? Service.RawStateValue
        else { return nil }

        if let service = serviceType.init(rawState: rawState) {
            return service as RemoteDataService
        }
        return nil
    }

    /// Registers handlers for Core Data changes
    private func registerHandlers() {
        coreDataPublisher?.filteredByEntityName("PumpEventStored").sink { [weak self] _ in
            guard let self = self else { return }
            Task { [weak self] in
                guard let self = self else { return }
                await self.uploadInsulin()
            }
        }.store(in: &subscriptions)

        coreDataPublisher?.filteredByEntityName("CarbEntryStored").sink { [weak self] _ in
            guard let self = self else { return }
            Task { [weak self] in
                guard let self = self else { return }
                await self.uploadCarbs()
            }
        }.store(in: &subscriptions)

        // This works only for manual Glucose
        coreDataPublisher?.filteredByEntityName("GlucoseStored").sink { [weak self] _ in
            guard let self = self else { return }
            Task { [weak self] in
                guard let self = self else { return }
                await self.uploadGlucose()
            }
        }.store(in: &subscriptions)

        // Register for settings that aren't saved from a single editor screen
        broadcaster.register(SettingsObserver.self, observer: self)
        broadcaster.register(PreferencesObserver.self, observer: self)
    }

    func sourceInfo() -> [String: Any]? {
        nil
    }

    /// Forces a full data upload to Tidepool
    func forceTidepoolDataUpload() {
        Task {
            await uploadInsulin()
            await uploadCarbs()
            await uploadGlucose()
            await uploadSettings()
        }
    }
}

extension BaseTidepoolManager: ServiceDelegate {
    var hostIdentifier: String {
        "org.nightscout.Trio"
    }

    var hostVersion: String {
        var semanticVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as! String

        while semanticVersion.split(separator: ".").count < 3 {
            semanticVersion += ".0"
        }

        semanticVersion += "+\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as! String)"

        return semanticVersion
    }

    func issueAlert(_: LoopKit.Alert) {}

    func retractAlert(identifier _: LoopKit.Alert.Identifier) {}

    func enactRemoteOverride(name _: String, durationTime _: TimeInterval?, remoteAddress _: String) async throws {}

    func cancelRemoteOverride() async throws {}

    func deliverRemoteCarbs(
        amountInGrams _: Double,
        absorptionTime _: TimeInterval?,
        foodType _: String?,
        startDate _: Date?
    ) async throws {}

    func deliverRemoteBolus(amountInUnits _: Double) async throws {}
}

/// Carb Upload and Deletion Functionality
extension BaseTidepoolManager {
    func uploadCarbs() async {
        do {
            await uploadCarbs(try await carbsStorage.getCarbsNotYetUploadedToTidepool())
        } catch {
            debug(.service, "\(DebuggingIdentifiers.failed) Failed to upload carbs with error: \(error)")
        }
    }

    func uploadCarbs(_ carbs: [CarbsEntry]) async {
        guard !carbs.isEmpty, let tidepoolService = self.tidepoolService else { return }
        debug(.service, "Tidepool: carbs upload triggered (\(carbs.count) pending)")

        await uploadSerializer.enqueue("carbs") { [weak self] generation in
            guard let self = self else { return }

            for chunk in carbs.chunks(ofCount: tidepoolService.carbDataLimit ?? 100) {
                guard await self.uploadSerializer.isCurrent(generation) else { return }

                let syncCarb: [SyncCarbObject] = Array(chunk).map { $0.convertSyncCarb() }

                let result = await Self.awaitUpload("carbs") { completion in
                    tidepoolService.uploadCarbData(created: syncCarb, updated: [], deleted: [], completion: completion)
                }

                switch result {
                case .success:
                    debug(.service, "Success synchronizing carbs data. Upload to Tidepool complete.")
                    // After successful upload, update the isUploadedToTidepool flag in Core Data
                    await self.updateCarbsAsUploaded(carbs)
                case let .failure(error):
                    debug(.service, "Error synchronizing carbs data with Tidepool: \(String(describing: error))")
                }
            }
        }
    }

    private func updateCarbsAsUploaded(_ carbs: [CarbsEntry]) async {
        await backgroundContext.perform {
            let ids = carbs.map(\.id) as NSArray
            let fetchRequest: NSFetchRequest<CarbEntryStored> = CarbEntryStored.fetchRequest()
            fetchRequest.predicate = NSPredicate(format: "id IN %@", ids)

            do {
                let results = try self.backgroundContext.fetch(fetchRequest)
                for result in results {
                    result.isUploadedToTidepool = true
                }

                guard self.backgroundContext.hasChanges else { return }
                try self.backgroundContext.save()
            } catch let error as NSError {
                debugPrint(
                    "\(DebuggingIdentifiers.failed) \(#file) \(#function) Failed to update isUploadedToTidepool: \(error.userInfo)"
                )
            }
        }
    }

    func deleteCarbs(withSyncId id: UUID, carbs: Decimal, at: Date, enteredBy: String) {
        guard let tidepoolService = self.tidepoolService else { return }

        let syncCarb: [SyncCarbObject] = [SyncCarbObject(
            absorptionTime: nil,
            createdByCurrentApp: true,
            foodType: nil,
            grams: Double(carbs),
            startDate: at,
            uuid: id,
            provenanceIdentifier: enteredBy,
            syncIdentifier: id.uuidString,
            syncVersion: nil,
            userCreatedDate: nil,
            userUpdatedDate: nil,
            userDeletedDate: nil,
            operation: LoopKit.Operation.delete,
            addedDate: nil,
            supercededDate: nil
        )]

        Task { [weak self] in
            await self?.uploadSerializer.enqueue("carbs-delete") { _ in
                let result = await Self.awaitUpload("carbs-delete") { completion in
                    tidepoolService.uploadCarbData(created: [], updated: [], deleted: syncCarb, completion: completion)
                }
                switch result {
                case .success:
                    debug(.service, "Success synchronizing carbs delete data. Upload to Tidepool complete.")
                case let .failure(error):
                    debug(.service, "Error synchronizing carbs delete data with Tidepool: \(String(describing: error))")
                }
            }
        }
    }
}

/// Insulin Upload and Deletion Functionality
extension BaseTidepoolManager {
    func uploadInsulin() async {
        do {
            let events = try await pumpHistoryStorage.getPumpHistoryNotYetUploadedToTidepool()
            await uploadDose(events)
        } catch {
            debug(.service, "Error fetching pump history: \(error)")
        }
    }

    func uploadDose(_ events: [PumpHistoryEvent]) async {
        guard !events.isEmpty, let tidepoolService = self.tidepoolService else { return }
        debug(.service, "Tidepool: dose upload triggered (\(events.count) pending)")

        do {
            // Fetch all temp basal entries from Core Data for the last 24 hours
            let results = try await CoreDataStack.shared.fetchEntitiesAsync(
                ofType: PumpEventStored.self,
                onContext: backgroundContext,
                predicate: NSCompoundPredicate(andPredicateWithSubpredicates: [
                    NSPredicate.pumpHistoryLast24h,
                    NSPredicate(format: "tempBasal != nil")
                ]),
                key: "timestamp",
                ascending: true,
                batchSize: 50
            )

            // Build the upload payloads in the background context, then upload off the queue.
            let (insulinDoseEvents, pumpEvents): ([DoseEntry], [PersistedPumpEvent]) = try await backgroundContext
                .perform {
                    guard let existingTempBasalEntries = results as? [PumpEventStored] else {
                        throw CoreDataError.fetchError(function: #function, file: #file)
                    }

                    let insulinDoseEvents: [DoseEntry] = events.reduce([]) { result, event in
                        var result = result
                        switch event.type {
                        case .tempBasal:
                            result
                                .append(
                                    contentsOf: self
                                        .processTempBasalEvent(event, existingTempBasalEntries: existingTempBasalEntries)
                                )
                        case .bolus:
                            guard let amount = event.amount else { return result }
                            let bolusDoseEntry = DoseEntry(
                                type: .bolus,
                                startDate: event.timestamp,
                                endDate: event.timestamp,
                                value: Double(amount),
                                unit: .units,
                                deliveredUnits: nil,
                                syncIdentifier: event.id,
                                scheduledBasalRate: nil,
                                insulinType: self.apsManager.pumpManager?.status.insulinType ?? nil,
                                automatic: event.isSMB ?? true,
                                manuallyEntered: event.isExternal ?? false
                            )
                            result.append(bolusDoseEntry)
                        default:
                            break
                        }
                        return result
                    }

                    debug(.service, "TIDEPOOL DOSE ENTRIES: \(insulinDoseEvents)")

                    let pumpEvents: [PersistedPumpEvent] = events.compactMap { event -> PersistedPumpEvent? in
                        if let pumpEventType = event.type.mapEventTypeToPumpEventType() {
                            let dose: DoseEntry? = switch pumpEventType {
                            case .suspend:
                                DoseEntry(suspendDate: event.timestamp, automatic: true)
                            case .resume:
                                DoseEntry(resumeDate: event.timestamp, automatic: true)
                            default:
                                nil
                            }

                            return PersistedPumpEvent(
                                date: event.timestamp,
                                persistedDate: event.timestamp,
                                dose: dose,
                                isUploaded: true,
                                objectIDURL: URL(string: "x-coredata:///PumpEvent/\(event.id)")!,
                                raw: event.id.data(using: .utf8),
                                title: event.note,
                                type: pumpEventType
                            )
                        } else {
                            return nil
                        }
                    }

                    return (insulinDoseEvents, pumpEvents)
                }

            await uploadSerializer.enqueue("dose") { [weak self] generation in
                guard let self = self else { return }

                let doseResult = await Self.awaitUpload("dose") { completion in
                    tidepoolService.uploadDoseData(created: insulinDoseEvents, deleted: [], completion: completion)
                }
                switch doseResult {
                case .success:
                    debug(.service, "Success synchronizing dose data. Upload to Tidepool complete.")
                    let insulinEvents = events.filter {
                        $0.type == .tempBasal || $0.type == .tempBasalDuration || $0.type == .bolus
                    }
                    await self.updateInsulinAsUploaded(insulinEvents)
                case let .failure(error):
                    debug(.service, "Error synchronizing dose data with Tidepool: \(String(describing: error))")
                }

                guard await self.uploadSerializer.isCurrent(generation) else { return }

                let pumpResult = await Self.awaitUpload("pumpEvents") { completion in
                    tidepoolService.uploadPumpEventData(pumpEvents, completion: completion)
                }
                switch pumpResult {
                case .success:
                    debug(.service, "Success synchronizing pump events data. Upload to Tidepool complete.")
                    let pumpEventType = events.map { $0.type.mapEventTypeToPumpEventType() }
                    let pumpEventsToMark = events.filter { _ in pumpEventType.contains(pumpEventType) }
                    await self.updateInsulinAsUploaded(pumpEventsToMark)
                case let .failure(error):
                    debug(.service, "Error synchronizing pump events data: \(String(describing: error))")
                }
            }
        } catch {
            debug(.service, "Error fetching temp basal entries: \(error)")
        }
    }

    private func updateInsulinAsUploaded(_ insulin: [PumpHistoryEvent]) async {
        await backgroundContext.perform {
            let ids = insulin.map(\.id) as NSArray
            let fetchRequest: NSFetchRequest<PumpEventStored> = PumpEventStored.fetchRequest()
            fetchRequest.predicate = NSPredicate(format: "id IN %@", ids)

            do {
                let results = try self.backgroundContext.fetch(fetchRequest)
                for result in results {
                    result.isUploadedToTidepool = true
                }

                guard self.backgroundContext.hasChanges else { return }
                try self.backgroundContext.save()
            } catch let error as NSError {
                debugPrint(
                    "\(DebuggingIdentifiers.failed) \(#file) \(#function) Failed to update isUploadedToTidepool: \(error.userInfo)"
                )
            }
        }
    }

    func deleteInsulin(withSyncId id: String, amount: Decimal, at: Date) {
        guard let tidepoolService = self.tidepoolService else { return }

        // must be an array here, because `tidepoolService.uploadDoseData` expects a `deleted` array
        let doseDataToDelete: [DoseEntry] = [DoseEntry(
            type: .bolus,
            startDate: at,
            value: Double(amount),
            unit: .units,
            syncIdentifier: id
        )]

        Task { [weak self] in
            await self?.uploadSerializer.enqueue("dose-delete") { _ in
                let result = await Self.awaitUpload("dose-delete") { completion in
                    tidepoolService.uploadDoseData(created: [], deleted: doseDataToDelete, completion: completion)
                }
                switch result {
                case .success:
                    debug(.service, "Success synchronizing Dose delete data")
                case let .failure(error):
                    debug(.service, "Error synchronizing Dose delete data: \(String(describing: error))")
                }
            }
        }
    }
}

/// Insulin Helper Functions
extension BaseTidepoolManager {
    private func processTempBasalEvent(
        _ event: PumpHistoryEvent,
        existingTempBasalEntries: [PumpEventStored]
    ) -> [DoseEntry] {
        var insulinDoseEvents: [DoseEntry] = []

        backgroundContext.performAndWait {
            // Loop through the pump history events within the background context
            guard let duration = event.duration, let amount = event.amount,
                  let currentBasalRate = self.getCurrentBasalRate()
            else {
                return
            }
            let value = (Decimal(duration) / 60.0) * amount

            // Find the corresponding temp basal entry in existingTempBasalEntries
            if let matchingEntryIndex = existingTempBasalEntries.firstIndex(where: { $0.timestamp == event.timestamp }) {
                // Check for a predecessor (the entry before the matching entry)
                let predecessorIndex = matchingEntryIndex - 1
                if predecessorIndex >= 0 {
                    let predecessorEntry = existingTempBasalEntries[predecessorIndex]
                    if let predecessorTimestamp = predecessorEntry.timestamp,
                       let predecessorEntrySyncIdentifier = predecessorEntry.id
                    {
                        let predecessorEndDate = predecessorTimestamp
                            .addingTimeInterval(TimeInterval(
                                Int(predecessorEntry.tempBasal?.duration ?? 0) *
                                    60
                            )) // parse duration to minutes

                        // If the predecessor's end date is later than the current event's start date, adjust it
                        if predecessorEndDate > event.timestamp {
                            let adjustedEndDate = event.timestamp
                            let adjustedDuration = adjustedEndDate.timeIntervalSince(predecessorTimestamp)
                            let adjustedDeliveredUnits = (adjustedDuration / 3600) *
                                Double(truncating: predecessorEntry.tempBasal?.rate ?? 0)

                            // Create updated predecessor dose entry
                            let updatedPredecessorEntry = DoseEntry(
                                type: .tempBasal,
                                startDate: predecessorTimestamp,
                                endDate: adjustedEndDate,
                                value: adjustedDeliveredUnits,
                                unit: .units,
                                deliveredUnits: adjustedDeliveredUnits,
                                syncIdentifier: predecessorEntrySyncIdentifier,
                                insulinType: self.apsManager.pumpManager?.status.insulinType ?? nil,
                                automatic: true,
                                manuallyEntered: false,
                                isMutable: false
                            )
                            // Add the updated predecessor entry to the result
                            insulinDoseEvents.append(updatedPredecessorEntry)
                        }
                    }
                }

                // Create a new dose entry for the current event
                let currentEndDate = event.timestamp.addingTimeInterval(TimeInterval(minutes: Double(duration)))
                let newDoseEntry = DoseEntry(
                    type: .tempBasal,
                    startDate: event.timestamp,
                    endDate: currentEndDate,
                    value: Double(value),
                    unit: .units,
                    deliveredUnits: Double(value),
                    syncIdentifier: event.id,
                    scheduledBasalRate: HKQuantity(
                        unit: .internationalUnitsPerHour,
                        doubleValue: Double(currentBasalRate.rate)
                    ),
                    insulinType: self.apsManager.pumpManager?.status.insulinType ?? nil,
                    automatic: true,
                    manuallyEntered: false,
                    isMutable: false
                )
                // Add the new event entry to the result
                insulinDoseEvents.append(newDoseEntry)
            }
        }

        return insulinDoseEvents
    }

    private func getCurrentBasalRate() -> BasalProfileEntry? {
        let now = Date()
        let calendar = Calendar.current

        let basalEntries = storage.retrieve(OpenAPS.Settings.basalProfile, as: [BasalProfileEntry].self)
            ?? [BasalProfileEntry](from: OpenAPS.defaults(for: OpenAPS.Settings.basalProfile))
            ?? []

        var currentRate: BasalProfileEntry = basalEntries[0]

        for (index, entry) in basalEntries.enumerated() {
            guard let entryTime = TherapySettingsUtil.parseTime(entry.start) else {
                debug(.default, "Invalid entry start time: \(entry.start)")
                continue
            }

            let entryComponents = calendar.dateComponents([.hour, .minute, .second], from: entryTime)
            let entryStartTime = calendar.date(
                bySettingHour: entryComponents.hour!,
                minute: entryComponents.minute!,
                second: entryComponents.second!,
                of: now
            )!

            let entryEndTime: Date
            if index < basalEntries.count - 1,
               let nextEntryTime = TherapySettingsUtil.parseTime(basalEntries[index + 1].start)
            {
                let nextEntryComponents = calendar.dateComponents([.hour, .minute, .second], from: nextEntryTime)
                entryEndTime = calendar.date(
                    bySettingHour: nextEntryComponents.hour!,
                    minute: nextEntryComponents.minute!,
                    second: nextEntryComponents.second!,
                    of: now
                )!
            } else {
                entryEndTime = calendar.date(byAdding: .day, value: 1, to: entryStartTime)!
            }

            if now >= entryStartTime, now < entryEndTime {
                currentRate = entry
            }
        }

        return currentRate
    }
}

/// Glucose Upload Functionality
extension BaseTidepoolManager {
    func uploadGlucose() async {
        do {
            let glucose = try await glucoseStorage.getGlucoseNotYetUploadedToTidepool()
            await uploadGlucose(glucose)

            let manualGlucose = try await glucoseStorage.getManualGlucoseNotYetUploadedToTidepool()
            await uploadGlucose(manualGlucose)
        } catch {
            debug(.service, "Error fetching glucose data: \(error)")
        }
    }

    func uploadGlucose(_ glucose: [StoredGlucoseSample]) async {
        guard !glucose.isEmpty, let tidepoolService = self.tidepoolService else { return }
        debug(.service, "Tidepool: glucose upload triggered (\(glucose.count) pending)")

        let chunks = glucose.chunks(ofCount: tidepoolService.glucoseDataLimit ?? 100)

        await uploadSerializer.enqueue("glucose") { [weak self] generation in
            guard let self = self else { return }

            for chunk in chunks {
                guard await self.uploadSerializer.isCurrent(generation) else { return }

                let result = await Self.awaitUpload("glucose") { completion in
                    tidepoolService.uploadGlucoseData(chunk, completion: completion)
                }

                switch result {
                case .success:
                    debug(.service, "Success synchronizing glucose data")
                    // After successful upload, update the isUploadedToTidepool flag in Core Data
                    await self.updateGlucoseAsUploaded(glucose)
                case let .failure(error):
                    debug(.service, "Error synchronizing glucose data: \(String(describing: error))")
                }
            }
        }
    }

    private func updateGlucoseAsUploaded(_ glucose: [StoredGlucoseSample]) async {
        await backgroundContext.perform {
            let ids = glucose.map(\.syncIdentifier) as NSArray
            let fetchRequest: NSFetchRequest<GlucoseStored> = GlucoseStored.fetchRequest()
            fetchRequest.predicate = NSPredicate(format: "id IN %@", ids)

            do {
                let results = try self.backgroundContext.fetch(fetchRequest)
                for result in results {
                    result.isUploadedToTidepool = true
                }

                guard self.backgroundContext.hasChanges else { return }
                try self.backgroundContext.save()
            } catch let error as NSError {
                debugPrint(
                    "\(DebuggingIdentifiers.failed) \(#file) \(#function) Failed to update isUploadedToTidepool: \(error.userInfo)"
                )
            }
        }
    }
}

/// Settings Upload Functionality
extension BaseTidepoolManager {
    /// Debounces settings upload requests.
    /// Cancels any pending upload and schedules a new one after the debounce delay.
    /// This prevents redundant uploads when multiple settings observers fire in rapid succession.
    /// All access to `pendingSettingsUpload` is serialized on `processQueue`.
    private func scheduleSettingsUpload() {
        processQueue.async { [weak self] in
            guard let self = self else { return }
            self.pendingSettingsUpload?.cancel()
            let workItem = DispatchWorkItem { [weak self] in
                guard let self = self else { return }
                Task {
                    await self.uploadSettings()
                }
            }
            self.pendingSettingsUpload = workItem
            self.processQueue.asyncAfter(
                deadline: .now() + Self.settingsUploadDebounceDelay,
                execute: workItem
            )
        }
    }

    func uploadSettings() async {
        guard let tidepoolService = self.tidepoolService as? TidepoolService else {
            return
        }

        // Get CGM device info (lazily resolved to avoid circular dependency)
        let fetchGlucoseManager = resolver?.resolve(FetchGlucoseManager.self)
        let cgmDevice = fetchGlucoseManager?.cgmManager?.cgmManagerStatus.device

        guard let settings = createStoredSettings(cgmDevice: cgmDevice) else {
            return
        }

        await uploadSerializer.enqueue("settings") { _ in
            let result = await Self.awaitUpload("settings") { completion in
                tidepoolService.uploadSettingsData([settings], completion: completion)
            }
            switch result {
            case .success:
                debug(.service, "Settings uploaded to Tidepool (syncId: \(settings.syncIdentifier))")
            case let .failure(error):
                debug(.service, "Failed to upload settings to Tidepool: \(error)")
            }
        }
    }
}

// MARK: - Settings Change Observers

extension BaseTidepoolManager: SettingsObserver {
    func settingsDidChange(_ settings: TrioSettings) {
        // Only trigger upload when therapy-relevant properties change.
        // TrioSettings has ~56 properties, most are UI-only (badges, colors, etc.).
        let closedLoopChanged = lastClosedLoop != settings.closedLoop
        let unitsChanged = lastUnits != settings.units

        lastClosedLoop = settings.closedLoop
        lastUnits = settings.units

        guard closedLoopChanged || unitsChanged else { return }
        scheduleSettingsUpload()
    }
}

extension BaseTidepoolManager: PreferencesObserver {
    func preferencesDidChange(_: Preferences) {
        scheduleSettingsUpload()
    }
}

extension BaseTidepoolManager: StatefulPluggableDelegate {
    func pluginDidUpdateState(_: LoopKit.StatefulPluggable) {}

    func pluginWantsDeletion(_: LoopKit.StatefulPluggable) {
        tidepoolService = nil
    }
}

// MARK: - Settings Conversion

extension BaseTidepoolManager {
    /// Creates a StoredSettings object from current Trio settings
    /// - Parameter cgmDevice: Optional CGM device info (pass from FetchGlucoseManager to avoid circular dependency)
    func createStoredSettings(cgmDevice: HKDevice? = nil) -> StoredSettings? {
        guard let basalProfile: [BasalProfileEntry] = storage
            .retrieve(OpenAPS.Settings.basalProfile, as: [BasalProfileEntry].self),
            let carbRatios: CarbRatios = storage.retrieve(OpenAPS.Settings.carbRatios, as: CarbRatios.self),
            let insulinSensitivities: InsulinSensitivities = storage.retrieve(
                OpenAPS.Settings.insulinSensitivities,
                as: InsulinSensitivities.self
            ),
            let bgTargets: BGTargets = storage.retrieve(OpenAPS.Settings.bgTargets, as: BGTargets.self)
        else {
            debug(.service, "Failed to load Trio therapy settings for Tidepool upload")
            return nil
        }

        let pumpSettings = settingsManager.pumpSettings
        let preferences: Preferences? = storage.retrieve(OpenAPS.Settings.preferences, as: Preferences.self)

        let basalRateSchedule = convertBasalProfile(basalProfile)
        let carbRatioSchedule = convertCarbRatios(carbRatios)
        let insulinSensitivitySchedule = convertInsulinSensitivities(insulinSensitivities)
        let glucoseTargetRangeSchedule = convertBGTargets(bgTargets)

        let pumpDevice = apsManager.pumpManager?.status.device
        let bgUnit: HKUnit = settingsManager.settings.units == .mmolL ? .millimolesPerLiter : .milligramsPerDeciliter

        // threshold_setting is always stored in mg/dL; TidepoolServiceKit calls
        // convertTo(unit:) internally, so we pass it through in its native unit
        let suspendThreshold: GlucoseThreshold? = preferences.map { prefs in
            let thresholdValue = Double(prefs.threshold_setting)
            return GlucoseThreshold(unit: .milligramsPerDeciliter, value: thresholdValue)
        }

        return StoredSettings(
            date: Date(),
            controllerTimeZone: TimeZone.current,
            dosingEnabled: settingsManager.settings.closedLoop,
            glucoseTargetRangeSchedule: glucoseTargetRangeSchedule,
            preMealTargetRange: nil,
            workoutTargetRange: nil,
            overridePresets: nil,
            scheduleOverride: nil,
            preMealOverride: nil,
            maximumBasalRatePerHour: Double(pumpSettings.maxBasal),
            maximumBolus: Double(pumpSettings.maxBolus),
            suspendThreshold: suspendThreshold,
            insulinType: apsManager.pumpManager?.status.insulinType,
            defaultRapidActingModel: convertInsulinModel(preferences: preferences, pumpSettings: pumpSettings),
            basalRateSchedule: basalRateSchedule,
            insulinSensitivitySchedule: insulinSensitivitySchedule,
            carbRatioSchedule: carbRatioSchedule,
            notificationSettings: nil,
            controllerDevice: createControllerDevice(),
            cgmDevice: cgmDevice,
            pumpDevice: pumpDevice,
            bloodGlucoseUnit: bgUnit,
            syncIdentifier: contentBasedSyncIdentifier(
                basalProfile: basalProfile,
                carbRatios: carbRatios,
                insulinSensitivities: insulinSensitivities,
                bgTargets: bgTargets,
                pumpSettings: pumpSettings,
                preferences: preferences,
                dosingEnabled: settingsManager.settings.closedLoop
            )
        )
    }

    private func convertBasalProfile(_ entries: [BasalProfileEntry]) -> BasalRateSchedule? {
        let items = entries.map { entry in
            let startTime = TimeInterval(entry.minutes * 60)
            return RepeatingScheduleValue(startTime: startTime, value: Double(entry.rate))
        }
        return BasalRateSchedule(dailyItems: items, timeZone: TimeZone.current)
    }

    private func convertCarbRatios(_ carbRatios: CarbRatios) -> CarbRatioSchedule? {
        let items = carbRatios.schedule.map { entry in
            let startTime = TimeInterval(entry.offset * 60)
            return RepeatingScheduleValue(startTime: startTime, value: Double(entry.ratio))
        }
        return CarbRatioSchedule(unit: .gram(), dailyItems: items, timeZone: TimeZone.current)
    }

    private func convertInsulinSensitivities(_ sensitivities: InsulinSensitivities) -> InsulinSensitivitySchedule? {
        // sensitivities.units comes from the data model itself, not the user's display preference
        let unit: HKUnit = sensitivities.units == .mgdL ? .milligramsPerDeciliter : .millimolesPerLiter
        let items = sensitivities.sensitivities.map { entry in
            let startTime = TimeInterval(entry.offset * 60)
            return RepeatingScheduleValue(startTime: startTime, value: Double(entry.sensitivity))
        }
        return InsulinSensitivitySchedule(unit: unit, dailyItems: items, timeZone: TimeZone.current)
    }

    private func convertBGTargets(_ bgTargets: BGTargets) -> GlucoseRangeSchedule? {
        // bgTargets.units comes from the data model itself, not the user's display preference
        let unit: HKUnit = bgTargets.units == .mgdL ? .milligramsPerDeciliter : .millimolesPerLiter
        let items = bgTargets.targets.map { entry in
            let startTime = TimeInterval(entry.offset * 60)
            let minValue = Double(entry.low)
            let maxValue = Double(entry.high)
            return RepeatingScheduleValue(startTime: startTime, value: DoubleRange(minValue: minValue, maxValue: maxValue))
        }
        let schedule = DailyQuantitySchedule(unit: unit, dailyItems: items, timeZone: TimeZone.current)
        return schedule.map { GlucoseRangeSchedule(rangeSchedule: $0) }
    }

    private func convertInsulinModel(preferences: Preferences?, pumpSettings: PumpSettings) -> StoredInsulinModel? {
        guard let curve = preferences?.curve else { return nil }

        let modelType: StoredInsulinModel.ModelType
        let preset: ExponentialInsulinModelPreset
        switch curve {
        case .bilinear,
             .rapidActing:
            modelType = .rapidAdult
            preset = .rapidActingAdult
        case .ultraRapid:
            // Distinguish Fiasp vs Lyumjev using the pump's configured insulin type
            let isLyumjev = apsManager.pumpManager?.status.insulinType == .lyumjev
            modelType = isLyumjev ? .lyumjev : .fiasp
            preset = isLyumjev ? .lyumjev : .fiasp
        }

        let dia = Double(pumpSettings.insulinActionCurve)

        // Use custom peak time if enabled, otherwise fall back to LoopKit preset default
        let peakActivity: TimeInterval
        if let prefs = preferences, prefs.useCustomPeakTime {
            peakActivity = .minutes(Double(prefs.insulinPeakTime))
        } else {
            peakActivity = preset.peakActivity
        }

        return StoredInsulinModel(
            modelType: modelType,
            delay: preset.delay,
            actionDuration: .hours(dia),
            peakActivity: peakActivity
        )
    }

    /// Generates a deterministic UUID based on the content of the therapy settings.
    /// If settings haven't changed, the same UUID is produced, enabling Tidepool
    /// server-side deduplication via the origin ID.
    private func contentBasedSyncIdentifier(
        basalProfile: [BasalProfileEntry],
        carbRatios: CarbRatios,
        insulinSensitivities: InsulinSensitivities,
        bgTargets: BGTargets,
        pumpSettings: PumpSettings,
        preferences: Preferences?,
        dosingEnabled: Bool
    ) -> UUID {
        var hasher = SHA256()

        for entry in basalProfile {
            hasher.update(data: Data("\(entry.minutes):\(entry.rate)".utf8))
        }
        for entry in carbRatios.schedule {
            hasher.update(data: Data("\(entry.offset):\(entry.ratio)".utf8))
        }
        for entry in insulinSensitivities.sensitivities {
            hasher.update(data: Data("\(entry.offset):\(entry.sensitivity)".utf8))
        }
        for entry in bgTargets.targets {
            hasher.update(data: Data("\(entry.offset):\(entry.low):\(entry.high)".utf8))
        }

        hasher.update(data: Data("maxBasal:\(pumpSettings.maxBasal)".utf8))
        hasher.update(data: Data("maxBolus:\(pumpSettings.maxBolus)".utf8))

        if let prefs = preferences {
            hasher.update(data: Data("threshold:\(prefs.threshold_setting)".utf8))
        }

        hasher.update(data: Data("dosingEnabled:\(dosingEnabled)".utf8))

        let digest = hasher.finalize()
        let bytes = Array(digest.prefix(16))
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    private func createControllerDevice() -> StoredSettings.ControllerDevice {
        let device = UIDevice.current
        return StoredSettings.ControllerDevice(
            name: "Trio",
            systemName: device.systemName,
            systemVersion: device.systemVersion,
            model: device.model,
            modelIdentifier: device.getDeviceId
        )
    }
}

// Service extension for rawValue
extension Service {
    typealias RawValue = [String: Any]

    var rawValue: RawValue {
        [
            "serviceIdentifier": pluginIdentifier,
            "state": rawState
        ]
    }
}

// MARK: - Upload serialization

/// Runs enqueued async work strictly in order: each operation starts only after the previous one
/// has fully completed, including its network round-trip.
///
/// A wall-clock watchdog abandons the chain when the head operation exceeds `watchdogLimit`,
/// e.g. because the app was suspended mid-request and the completion never fired. Wall clock is
/// deliberate: it keeps advancing while the process is suspended. Abandoning bumps `generation`
/// so orphaned operations can bail out instead of racing the replacement chain.
actor TidepoolUploadSerializer {
    private let watchdogLimit: TimeInterval
    private var tail: Task<Void, Never>?
    private var generation = 0
    private var headOperationLabel: String?
    private var headOperationStart: Date?

    init(watchdogLimit: TimeInterval = 10 * 60) {
        self.watchdogLimit = watchdogLimit
    }

    /// True while `generation` identifies the live chain. Operations making more than one
    /// network call re-check this between calls and bail out once their chain is abandoned.
    func isCurrent(_ generation: Int) -> Bool {
        generation == self.generation
    }

    func enqueue(_ label: String, _ operation: @escaping (_ generation: Int) async -> Void) {
        recoverIfWedged()
        let generation = generation
        let previous = tail
        // .utility: the inherited .background QoS is not scheduled during background
        // execution windows, freezing uploads until the app is foregrounded.
        tail = Task(priority: .utility) {
            await previous?.value
            guard await self.begin(label, generation: generation) else { return }
            await operation(generation)
            await self.end(generation: generation)
        }
    }

    /// Abandons the chain if its head operation has exceeded the wall-clock watchdog limit.
    /// Called from paths that keep running while the pipeline itself is wedged.
    func recoverIfWedged() {
        guard let start = headOperationStart else { return }
        let age = Date().timeIntervalSince(start)
        guard age > watchdogLimit else { return }
        warning(
            .service,
            "Tidepool upload chain wedged: '\(headOperationLabel ?? "?")' has not completed after \(Int(age))s; abandoning chain and starting fresh"
        )
        generation += 1
        tail = nil
        headOperationStart = nil
        headOperationLabel = nil
    }

    private func begin(_ label: String, generation: Int) -> Bool {
        guard isCurrent(generation) else { return false }
        headOperationStart = Date()
        headOperationLabel = label
        return true
    }

    private func end(generation: Int) {
        guard isCurrent(generation) else { return }
        headOperationStart = nil
        headOperationLabel = nil
    }
}

/// One-shot resume guard for a continuation raced by a completion handler and a timeout. Only the
/// first `resume(_:)` takes effect.
private final class SingleResumer<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Never>?

    func attach(_ continuation: CheckedContinuation<T, Never>) {
        lock.lock()
        defer { lock.unlock() }
        self.continuation = continuation
    }

    func resume(_ value: T) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(returning: value)
    }
}

enum TidepoolUploadError: Error {
    /// The upload's completion handler never fired within the allotted time.
    /// `label` identifies which upload (e.g. "glucose", "dose") so the timeout is diagnosable in logs.
    case timedOut(label: String)
}

extension BaseTidepoolManager {
    /// Bridges a completion-based upload into async/await with a timeout, so a call that never calls
    /// back resolves to a `.timedOut` failure instead of wedging the serializer indefinitely.
    static func awaitUpload(
        _ label: String,
        timeout: TimeInterval = 120,
        _ operation: (@escaping (Result<Bool, Error>) -> Void) -> Void
    ) async -> Result<Bool, Error> {
        let resumer = SingleResumer<Result<Bool, Error>>()
        return await withCheckedContinuation { continuation in
            resumer.attach(continuation)

            let timeoutTask = Task {
                do {
                    try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                } catch {
                    return // cancelled: completion already fired
                }
                resumer.resume(.failure(TidepoolUploadError.timedOut(label: label)))
            }

            operation { result in
                timeoutTask.cancel()
                resumer.resume(result)
            }
        }
    }
}
