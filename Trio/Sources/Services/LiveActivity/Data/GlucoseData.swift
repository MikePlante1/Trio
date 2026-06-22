import Foundation

struct GlucoseData {
    let glucose: Int
    let date: Date
    let direction: BloodGlucose.Direction?
    /// Whether this reading is handed to the algorithm (~5-min cadence). The Live
    /// Activity chart plots only these; the labels still use the freshest reading.
    let isAlgorithmReading: Bool
}
