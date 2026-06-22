import CoreData
import SwiftUI

extension History.RootView {
    var glucoseList: some View {
        List {
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text("Values")
                    Spacer()
                    Text("Time")
                }
                // Explain the fade once, and only when there are display-only readings
                // (a native 1-min CGM); 5-min CGMs flag every reading, so nothing fades.
                if glucoseStored.contains(where: { !$0.isAlgorithmReading }) {
                    Text("Faded entries are display-only, not sent to the algorithm")
                        .font(.caption2)
                }
            }.foregroundStyle(.secondary)

            if !glucoseStored.isEmpty {
                ForEach(glucoseStored) { glucose in
                    // Readings the algorithm didn't use (extra readings from a native
                    // 1-minute CGM) are display-only — faded so it's clear at a glance which
                    // readings oref actually used. Manuals are always algorithm readings.
                    let isDisplayOnly = !glucose.isAlgorithmReading
                    HStack {
                        Text(formatGlucose(Decimal(glucose.glucose), isManual: glucose.isManual))

                        /// check for manual glucose
                        if glucose.isManual {
                            Image(systemName: "drop.fill").symbolRenderingMode(.monochrome).foregroundStyle(.red)
                        } else {
                            Text("\(glucose.directionEnum?.symbol ?? "--")")
                        }

                        if state.settingsManager.settings.smoothGlucose, !glucose.isManual,
                           let smoothedGlucose = glucose.smoothedGlucose, smoothedGlucose != 0
                        {
                            let smoothedGlucoseForDisplay = state.units == .mgdL ? smoothedGlucose
                                .description : smoothedGlucose.decimalValue
                                .formattedAsMmolL

                            (
                                Text("(") +
                                    Text(Image(systemName: "sparkles")) +
                                    Text(" ") +
                                    Text("\(smoothedGlucoseForDisplay)") +
                                    Text(")")
                            ).foregroundStyle(.secondary)
                                .padding(.leading, 10)
                        }

                        Spacer()

                        Text(Formatter.dateFormatter.string(from: glucose.date ?? Date()))
                    }
                    // Display-only readings recede; the ~5-min readings oref uses stay at
                    // full strength (consistent with the greyed dots on the home chart).
                    .opacity(isDisplayOnly ? 0.55 : 1)
                    .contextMenu {
                        Button(
                            "Delete",
                            systemImage: "trash.fill",
                            role: .destructive,
                            action: { requestDelete(.glucose(glucose)) }
                        ).tint(.red)
                    }
                    .swipeActions {
                        Button(
                            "Delete",
                            systemImage: "trash.fill",
                            role: .none,
                            action: { requestDelete(.glucose(glucose)) }
                        ).tint(.red)
                    }
                }
            } else {
                ContentUnavailableView(
                    String(localized: "No data."),
                    systemImage: "drop.fill"
                )
            }
        }.listRowBackground(Color.chart)
    }

    func formatGlucose(_ value: Decimal, isManual: Bool) -> String {
        let formatter = isManual ? manualGlucoseFormatter : Formatter.glucoseFormatter(for: state.units)
        let glucoseValue = state.units == .mmolL ? value.asMmolL : value
        let formattedValue = formatter.string(from: glucoseValue as NSNumber) ?? "--"

        return formattedValue
    }
}
