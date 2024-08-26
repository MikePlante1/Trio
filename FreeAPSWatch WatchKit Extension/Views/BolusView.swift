import SwiftUI

struct BolusView: View {
    @EnvironmentObject var state: WatchStateModel

    @State var steps = 0.0

    var numberFormatter: NumberFormatter {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimum = 0
        formatter.maximum = Double((state.maxBolus ?? 5) / 0.5) as NSNumber
        formatter.maximumFractionDigits = 0.5 > 0.05 ? 1 : 2
        formatter.minimumFractionDigits = 0.5 > 0.05 ? 1 : 2
        formatter.allowsFloats = true
        formatter.roundingIncrement = Double(0.5) as NSNumber
        formatter.roundingMode = .down
        return formatter
    }

    var body: some View {
        GeometryReader { geo in
            VStack(spacing: 16) {
                HStack {
                    Button {
                        WKInterfaceDevice.current().play(.click)
                        let newValue = steps - 1
                        steps = max(newValue, 0)
                    } label: { Image(systemName: "minus") }
                        .frame(width: geo.size.width / 4)
                    Spacer()
                    Text(numberFormatter.string(from: (steps * Double(0.5)) as NSNumber)! + " U")
                        .font(.headline)
                        .focusable(true)
                        .digitalCrownRotation(
                            $steps,
                            from: 0,
                            through: Double((state.maxBolus ?? 5) / 0.5),
                            by: 1,
                            sensitivity: .medium,
                            isContinuous: false,
                            isHapticFeedbackEnabled: true
                        )
                    Spacer()
                    Button {
                        WKInterfaceDevice.current().play(.click)
                        let newValue = steps + 1
                        steps = min(newValue, Double((state.maxBolus ?? 5) / 0.5))
                    } label: { Image(systemName: "plus") }
                        .frame(width: geo.size.width / 4)
                }

                HStack {
                    Button {
                        WKInterfaceDevice.current().play(.click)
                        state.isBolusViewActive = false
                    }
                    label: {
                        Image(systemName: "xmark.circle.fill")
                            .resizable()
                            .foregroundColor(.loopRed)
                            .frame(width: 30, height: 30)
                    }
                    Button {
                        WKInterfaceDevice.current().play(.click)
                        enactBolus()
                    }
                    label: {
                        Image(systemName: "checkmark.circle.fill")
                            .resizable()
                            .foregroundColor(.loopGreen)
                            .frame(width: 30, height: 30)
                    }
                    .disabled(steps <= 0)
                }
            }.frame(maxHeight: .infinity)
        }
        .navigationTitle("Enact Bolus")
        .onAppear {
            steps = Double((state.bolusRecommended ?? 0) / 0.5)
        }
    }

    private func enactBolus() {
        let amount = steps * Double(0.5)
        state.addBolus(amount: amount)
    }
}

struct BolusView_Previews: PreviewProvider {
    static var previews: some View {
        let state = WatchStateModel()
        state.bolusRecommended = 10.3
        state.bolusIncrement = 0.05
        return Group {
            BolusView()
            BolusView().previewDevice("Apple Watch Series 5 - 40mm")
            BolusView().previewDevice("Apple Watch Series 3 - 38mm")
        }.environmentObject(state)
    }
}
