import CoreData
import Foundation

public extension GlucoseStored {
    @nonobjc class func fetchRequest() -> NSFetchRequest<GlucoseStored> {
        NSFetchRequest<GlucoseStored>(entityName: "GlucoseStored")
    }

    @NSManaged var date: Date?
    @NSManaged var direction: String?
    @NSManaged var glucose: Int16
    @NSManaged var id: UUID?
    /// True for the extra display-only readings stored from native 1-min CGMs (e.g.
    /// Libre 3); false for the ~5-min readings handed to the oref algorithm.
    @NSManaged var isDisplayOnly: Bool
    @NSManaged var isManual: Bool
    @NSManaged var isUploadedToHealth: Bool
    @NSManaged var isUploadedToNS: Bool
    @NSManaged var isUploadedToTidepool: Bool
    @NSManaged var smoothedGlucose: NSDecimalNumber?
}

extension GlucoseStored: Identifiable {}
