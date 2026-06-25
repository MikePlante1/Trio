import LoopKitUI
import SwiftUI
import UIKit

extension PumpConfig {
    struct PumpSettingsView: UIViewControllerRepresentable {
        let pumpManager: PumpManagerUI
        let bluetoothManager: BluetoothStateManager
        weak var completionDelegate: CompletionDelegate?
        weak var setupDelegate: PumpManagerOnboardingDelegate?

        func makeUIViewController(context _: UIViewControllerRepresentableContext<PumpSettingsView>) -> UIViewController {
            Self.makeController(
                pumpManager: pumpManager,
                bluetoothManager: bluetoothManager,
                completionDelegate: completionDelegate,
                setupDelegate: setupDelegate
            )
        }

        /// Builds the pump settings controller. Shared by the SwiftUI representable
        /// (Settings path) and the UIKit-modal presentation on the Home screen.
        static func makeController(
            pumpManager: PumpManagerUI,
            bluetoothManager: BluetoothStateManager,
            completionDelegate: CompletionDelegate?,
            setupDelegate: PumpManagerOnboardingDelegate?
        ) -> UIViewController {
            var vc = pumpManager.settingsViewController(
                bluetoothProvider: bluetoothManager,
                pumpManagerOnboardingDelegate: setupDelegate
            )
            vc.completionDelegate = completionDelegate
            return vc
        }

        func updateUIViewController(_: UIViewController, context _: UIViewControllerRepresentableContext<PumpSettingsView>) {}
    }
}
