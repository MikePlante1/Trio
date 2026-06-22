import Foundation

struct GlucoseData {
    let glucose: Int
    let date: Date
    let direction: BloodGlucose.Direction?
    /// Whether this reading is display-only (an extra 1-min reading between the
    /// ~5-min algorithm readings). The Live Activity chart plots only non-display-only
    /// readings; the labels still use the freshest reading.
    let isDisplayOnly: Bool
}
