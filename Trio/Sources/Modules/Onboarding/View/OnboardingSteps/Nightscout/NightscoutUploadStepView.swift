import SwiftUI

struct NightscoutUploadStepView: View {
    @Bindable var state: Onboarding.StateModel

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Please choose from the options below.")
                .font(.headline)
                .padding(.horizontal)

            HStack {
                Toggle(isOn: $state.isUploadEnabled) {
                    Text("Allow Uploading to Nightscout")
                }.tint(Color.accentColor)
            }
            .padding()
            .background(Color.chart.opacity(0.65))
            .cornerRadius(10)

            HStack {
                Text("Upload Glucose")
                Spacer()
                Toggle(isOn: $state.uploadGlucose) {
                    Text("Upload Glucose")
                }.tint(Color.accentColor)
            }
            .padding()
            .background(Color.chart.opacity(0.65))
            .cornerRadius(10)

            Text(
                "Note: Choosing your pump model determines which increments for setting up your basal rates are available. You will pair your actual pump after finishing the onboarding process."
            )
            .padding(.horizontal)
            .font(.footnote)
            .foregroundStyle(Color.secondary)
            .multilineTextAlignment(.leading)
        }
    }
}
