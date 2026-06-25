import DanaKit
import LoopKit
import LoopKitUI
import MedtrumKit
import MinimedKit
import MinimedKitUI
import MockKit
import MockKitUI
import OmnipodKit
import SwiftUI
import UIKit

extension PumpConfig {
    struct PumpSetupView: UIViewControllerRepresentable {
        let pumpType: PumpType
        let pumpInitialSettings: PumpInitialSettings
        let bluetoothManager: BluetoothStateManager
        weak var completionDelegate: CompletionDelegate?
        weak var setupDelegate: PumpManagerOnboardingDelegate?

        func makeUIViewController(context _: UIViewControllerRepresentableContext<PumpSetupView>) -> UIViewController {
            Self.makeController(
                pumpType: pumpType,
                pumpInitialSettings: pumpInitialSettings,
                bluetoothManager: bluetoothManager,
                completionDelegate: completionDelegate,
                setupDelegate: setupDelegate
            )
        }

        /// Builds the pump setup/onboarding controller. Shared by the SwiftUI representable
        /// (Settings path) and the UIKit-modal presentation on the Home screen.
        static func makeController(
            pumpType: PumpType,
            pumpInitialSettings: PumpInitialSettings,
            bluetoothManager: BluetoothStateManager,
            completionDelegate: CompletionDelegate?,
            setupDelegate: PumpManagerOnboardingDelegate?
        ) -> UIViewController {
            // var setupViewController: PumpManagerSetupViewController & UIViewController & CompletionNotifying
            var setupViewController: SetupUIResult<
                PumpManagerViewController,
                PumpManagerUI
            >

            let initialSettings = PumpManagerSetupSettings(
                maxBasalRateUnitsPerHour: pumpInitialSettings.maxBasalRateUnitsPerHour,
                maxBolusUnits: pumpInitialSettings.maxBolusUnits,
                basalSchedule: pumpInitialSettings.basalSchedule
            )

            switch pumpType {
            case .minimed:
                setupViewController = MinimedPumpManager.setupViewController(
                    initialSettings: initialSettings,
                    bluetoothProvider: bluetoothManager,
                    colorPalette: .default,
                    allowDebugFeatures: true,
                    prefersToSkipUserInteraction: false,
                    allowedInsulinTypes: [.apidra, .humalog, .novolog, .fiasp, .lyumjev]
                )
            case .omni:
                setupViewController = OmniPumpManager.setupViewController(
                    initialSettings: initialSettings,
                    bluetoothProvider: bluetoothManager,
                    colorPalette: .default,
                    allowDebugFeatures: true,
                    prefersToSkipUserInteraction: false,
                    allowedInsulinTypes: [.apidra, .humalog, .novolog, .fiasp, .lyumjev]
                )
            case .dana:
                setupViewController = DanaKitPumpManager.setupViewController(
                    initialSettings: initialSettings,
                    bluetoothProvider: bluetoothManager,
                    colorPalette: .default,
                    allowDebugFeatures: true,
                    prefersToSkipUserInteraction: false,
                    allowedInsulinTypes: [.apidra, .humalog, .novolog, .fiasp, .lyumjev]
                )
            case .medtrum:
                setupViewController = MedtrumPumpManager.setupViewController(
                    initialSettings: initialSettings,
                    bluetoothProvider: bluetoothManager,
                    colorPalette: .default,
                    allowDebugFeatures: true,
                    prefersToSkipUserInteraction: false,
                    allowedInsulinTypes: [.apidra, .humalog, .novolog, .fiasp, .lyumjev]
                )
            case .simulator:
                setupViewController = MockPumpManager.setupViewController(
                    initialSettings: initialSettings,
                    bluetoothProvider: bluetoothManager,
                    colorPalette: .default,
                    allowDebugFeatures: true,
                    prefersToSkipUserInteraction: false,
                    allowedInsulinTypes: [.apidra, .humalog, .novolog, .fiasp, .lyumjev]
                )
            }

            switch setupViewController {
            case var .userInteractionRequired(setupViewControllerUI):
                setupViewControllerUI.pumpManagerOnboardingDelegate = setupDelegate
                setupViewControllerUI.completionDelegate = completionDelegate
                return setupViewControllerUI
            case let .createdAndOnboarded(pumpManagerUI):
                debug(.default, "Pump manager  created and onboarded")
                setupDelegate?.pumpManagerOnboarding(didCreatePumpManager: pumpManagerUI)
                var vc = pumpManagerUI.settingsViewController(
                    bluetoothProvider: bluetoothManager,
                    pumpManagerOnboardingDelegate: setupDelegate
                )
                vc.completionDelegate = completionDelegate
                return vc
            }
        }

        func updateUIViewController(_: UIViewController, context _: UIViewControllerRepresentableContext<PumpSetupView>) {}
    }
}
