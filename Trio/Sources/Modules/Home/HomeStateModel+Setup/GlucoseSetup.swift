import CoreData
import Foundation

extension Home.StateModel {
    func setupGlucoseArray() {
        Task {
            do {
                let ids = try await self.fetchGlucose()
                let glucoseObjects: [GlucoseStored] = try await CoreDataStack.shared
                    .getNSManagedObject(with: ids, context: viewContext)
                await updateGlucoseArray(with: glucoseObjects)
            } catch {
                debug(
                    .default,
                    "\(DebuggingIdentifiers.failed) Error setting up glucose array: \(error)"
                )
            }
        }
    }

    private func fetchGlucose() async throws -> [NSManagedObjectID] {
        let results = try await CoreDataStack.shared.fetchEntitiesAsync(
            ofType: GlucoseStored.self,
            onContext: glucoseFetchContext,
            predicate: NSPredicate.glucose,
            key: "date",
            ascending: true,
            batchSize: 50
        )

        return try await glucoseFetchContext.perform {
            guard let fetchedResults = results as? [GlucoseStored] else {
                throw CoreDataError.fetchError(function: #function, file: #file)
            }

            // Update Main Chart Y Axis Values
            // Perform everything on "context" to be thread safe
            self.yAxisChartData(glucoseValues: fetchedResults)

            return fetchedResults.map(\.objectID)
        }
    }

    @MainActor private func updateGlucoseArray(with objects: [GlucoseStored]) {
        glucoseFromPersistence = objects

        // The bobble shows the freshest (1-min) reading, but its delta should stay the
        // conventional ~5-min change rather than a noisy 1-min delta now that every 1-min
        // reading is stored. Pair the newest reading with the most recent reading at least
        // ~5 min older. (Value mirrors GlucoseStorage's algorithmReadingInterval, inlined
        // here as a display concept independent of the algorithm cadence.)
        let fiveMinuteDeltaWindow: TimeInterval = 4.5 * 60
        if let newest = objects.last, let newestDate = newest.date {
            let previous = objects.dropLast().last(where: { older in
                guard let olderDate = older.date else { return false }
                return newestDate.timeIntervalSince(olderDate) >= fiveMinuteDeltaWindow
            }) ?? objects.dropLast().last
            latestTwoGlucoseValues = [previous, newest].compactMap { $0 }
        } else {
            latestTwoGlucoseValues = Array(objects.suffix(2))
        }
    }
}
