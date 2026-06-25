import Combine
import SwiftUI
import UIKit

struct RoundedBackground: ViewModifier {
    private let color: Color

    init(color: Color = Color("CapsuleColor")) {
        self.color = color
    }

    func body(content: Content) -> some View {
        content
            .padding()
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill()
                    .foregroundColor(color)
            )
    }
}

struct CapsulaBackground: ViewModifier {
    private let color: Color

    init(color: Color = Color("CapsuleColor")) {
        self.color = color
    }

    func body(content: Content) -> some View {
        content
            .padding()
            .background(
                Capsule()
                    .fill()
                    .foregroundColor(color)
            )
    }
}

private let navigationCache = LRUCache<Screen.ID, AnyView>(capacity: 10)

struct NavigationLazyView: View {
    let build: () -> AnyView
    let screen: Screen

    init(_ build: @autoclosure @escaping () -> AnyView, screen: Screen) {
        self.build = build
        self.screen = screen
    }

    var body: AnyView {
        if navigationCache[screen.id] == nil {
            navigationCache[screen.id] = build()
        }
        return navigationCache[screen.id]!
            .onDisappear {
                navigationCache[screen.id] = nil
            }.asAny()
    }
}

struct Link: ViewModifier {
    let screen: Screen

    init(screen: Screen) {
        self.screen = screen
    }

    func body(content: Content) -> some View {
        NavigationLink(value: screen, label: { content })
    }
}

struct ScreenNavigation<T>: ViewModifier where T: View {
    private let destination: (Screen) -> T

    init(destination: @escaping (Screen) -> T) {
        self.destination = destination
    }

    func body(content: Content) -> some View {
        content.navigationDestination(
            for: Screen.self,
            destination: { screen in NavigationLazyView(destination(screen).asAny(), screen: screen) }
        )
    }
}

struct AdaptsToSoftwareKeyboard: ViewModifier {
    @State var currentHeight: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .padding(.bottom, currentHeight).animation(.easeOut(duration: 0.25))
            .edgesIgnoringSafeArea(currentHeight == 0 ? Edge.Set() : .bottom)
            .onAppear(perform: subscribeToKeyboardChanges)
    }

    private let keyboardHeightOnOpening = Foundation.NotificationCenter.default
        .publisher(for: UIResponder.keyboardWillShowNotification)
        .map { $0.userInfo![UIResponder.keyboardFrameEndUserInfoKey] as! CGRect }
        .map(\.height)

    private let keyboardHeightOnHiding = Foundation.NotificationCenter.default
        .publisher(for: UIResponder.keyboardWillHideNotification)
        .map { _ in CGFloat(0) }

    private func subscribeToKeyboardChanges() {
        _ = Publishers.Merge(keyboardHeightOnOpening, keyboardHeightOnHiding)
            .subscribe(on: DispatchQueue.main)
            .sink { height in
                if self.currentHeight == 0 || height == 0 {
                    self.currentHeight = height
                }
            }
    }
}

struct ClearButton: ViewModifier {
    @Binding var text: String
    func body(content: Content) -> some View {
        HStack {
            content
            if !text.isEmpty {
                Button { self.text = "" }
                label: {
                    Image(systemName: "delete.left")
                        .foregroundColor(.gray)
                }
            }
        }
    }
}

extension View {
    func roundedBackground() -> some View {
        modifier(RoundedBackground())
    }

    func buttonBackground() -> some View {
        modifier(RoundedBackground(color: .accentColor))
    }

    func navigationLink<V: BaseView>(to screen: Screen, from _: V) -> some View {
        modifier(Link(screen: screen))
    }

    func screenNavigation<V: BaseView>(_ view: V) -> some View {
        modifier(ScreenNavigation { screen in
            view.state.view(for: screen)
        })
    }

    func adaptsToSoftwareKeyboard() -> some View {
        modifier(AdaptsToSoftwareKeyboard())
    }

    func modal<V: BaseView>(for screen: Screen?, from view: V) -> some View {
        onTapGesture {
            view.state.showModal(for: screen)
        }
    }

    func asAny() -> AnyView { .init(self) }

    var backport: Backport<Self> { Backport(content: self) }
}

struct Backport<Content: View> {
    let content: Content
}

// Presents a UIKit controller as a real modal instead of SwiftUI `.sheet` content: under the
// Home screen's GeometryReader, iOS 26 drops a sheet-hosted coordinator's `.navigationTitle`;
// a real modal keeps it. Used for LoopKit pump/CGM coordinators.
extension View {
    func uiKitModal(
        isPresented: Binding<Bool>,
        makeViewController: @escaping () -> UIViewController?
    ) -> some View {
        background(UIKitModalPresenter(isPresented: isPresented, makeViewController: makeViewController))
    }
}

// Presents from the key window's topmost controller, not from this host, so the modal is
// unaffected by the GeometryReader/SwiftUI hierarchy it lives in.
private struct UIKitModalPresenter: UIViewControllerRepresentable {
    @Binding var isPresented: Bool
    let makeViewController: () -> UIViewController?

    func makeCoordinator() -> Coordinator { Coordinator(isPresented: $isPresented) }

    func makeUIViewController(context _: Context) -> UIViewController { UIViewController() }

    func updateUIViewController(_: UIViewController, context: Context) {
        let coordinator = context.coordinator

        if isPresented {
            guard coordinator.presented == nil, let viewController = makeViewController() else { return }
            coordinator.presented = viewController
            DispatchQueue.main.async {
                guard self.isPresented,
                      viewController.presentingViewController == nil,
                      let presenter = UIApplication.shared.topmostViewController
                else { return }
                presenter.present(viewController, animated: true) {
                    viewController.presentationController?.delegate = coordinator
                }
            }
        } else if let presented = coordinator.presented {
            coordinator.presented = nil
            presented.dismiss(animated: true)
        }
    }

    final class Coordinator: NSObject, UIAdaptivePresentationControllerDelegate {
        private let isPresented: Binding<Bool>
        var presented: UIViewController?

        init(isPresented: Binding<Bool>) { self.isPresented = isPresented }

        // Sync state when the user swipes the modal away.
        func presentationControllerDidDismiss(_: UIPresentationController) {
            presented = nil
            if isPresented.wrappedValue { isPresented.wrappedValue = false }
        }
    }
}

extension UIApplication {
    var topmostViewController: UIViewController? {
        let keyWindow = connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first { $0.isKeyWindow }
        var top = keyWindow?.rootViewController
        while let presented = top?.presentedViewController { top = presented }
        return top
    }
}
