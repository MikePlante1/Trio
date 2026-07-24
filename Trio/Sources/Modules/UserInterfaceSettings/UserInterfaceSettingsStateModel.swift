import SwiftUI

extension UserInterfaceSettings {
    final class StateModel: BaseStateModel<Provider> {
        @Published var low: Decimal = 70
        @Published var high: Decimal = 180
        @Published var xGridLines = false
        @Published var yGridLines: Bool = false
        @Published var rulerMarks: Bool = true
        @Published var bolusDisplayThreshold: BolusDisplayThreshold = .allUnits
        @Published var forecastDisplayType: ForecastDisplayType = .cone
        @Published var showCarbsRequiredBadge: Bool = true
        @Published var carbsRequiredThreshold: Decimal = 0
        @Published var glucoseColorScheme: GlucoseColorScheme = .dynamicColor
        @Published var eA1cDisplayUnit: EstimatedA1cDisplayUnit = .percent
        @Published var timeInRangeType: TimeInRangeType = .timeInTightRange
        @Published var requireAdjustmentsConfirmation: Bool = false
        @Published var currentGlucoseTarget: Decimal = 100

        var units: GlucoseUnits = .mgdL

        override func subscribe() {
            let units = settingsManager.settings.units
            self.units = units

            subscribeSetting(\.xGridLines, on: $xGridLines) { xGridLines = $0 }
            subscribeSetting(\.yGridLines, on: $yGridLines) { yGridLines = $0 }
            subscribeSetting(\.rulerMarks, on: $rulerMarks) { rulerMarks = $0 }
            subscribeSetting(\.bolusDisplayThreshold, on: $bolusDisplayThreshold) { bolusDisplayThreshold = $0 }

            subscribeSetting(\.forecastDisplayType, on: $forecastDisplayType) { forecastDisplayType = $0 }

            subscribeSetting(\.low, on: $low) { low = $0 }

            subscribeSetting(\.high, on: $high) { high = $0 }

            subscribeSetting(\.showCarbsRequiredBadge, on: $showCarbsRequiredBadge) { showCarbsRequiredBadge = $0 }

            subscribeSetting(
                \.carbsRequiredThreshold,
                on: $carbsRequiredThreshold
            ) { carbsRequiredThreshold = $0 }

            subscribeSetting(\.glucoseColorScheme, on: $glucoseColorScheme) { glucoseColorScheme = $0 }

            subscribeSetting(\.eA1cDisplayUnit, on: $eA1cDisplayUnit) { eA1cDisplayUnit = $0 }

            subscribeSetting(\.timeInRangeType, on: $timeInRangeType) { timeInRangeType = $0 }

            subscribeSetting(\.requireAdjustmentsConfirmation, on: $requireAdjustmentsConfirmation) {
                requireAdjustmentsConfirmation = $0 }

            Task { await getCurrentGlucoseTarget() }
        }

        /// Resolves the glucose target active right now from the BG target schedule.
        /// NOTE: same logic as HomeStateModel/AdjustmentsStateModel — candidate for a shared helper.
        func getCurrentGlucoseTarget() async {
            let now = Date()
            let calendar = Calendar.current
            let dateFormatter = DateFormatter()
            dateFormatter.dateFormat = "HH:mm:ss"
            dateFormatter.timeZone = TimeZone.current

            let bgTargets = await provider.getBGTargets()
            let entries: [(start: String, value: Decimal)] = bgTargets.targets.map { ($0.start, $0.low) }

            for (index, entry) in entries.enumerated() {
                guard let entryTime = dateFormatter.date(from: entry.start) else { continue }

                let entryComponents = calendar.dateComponents([.hour, .minute, .second], from: entryTime)
                let entryStartTime = calendar.date(
                    bySettingHour: entryComponents.hour!,
                    minute: entryComponents.minute!,
                    second: entryComponents.second!,
                    of: now
                )!

                let entryEndTime: Date
                if index < entries.count - 1,
                   let nextEntryTime = dateFormatter.date(from: entries[index + 1].start)
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
                    await MainActor.run { currentGlucoseTarget = entry.value }
                    return
                }
            }
        }
    }
}

extension UserInterfaceSettings.StateModel: SettingsObserver {
    func settingsDidChange(_: TrioSettings) {
        units = settingsManager.settings.units
    }
}
