import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        @Bindable var model = model

        Group {
            if !model.binaryFound {
                OnboardingView()
            } else {
                NavigationSplitView {
                    SidebarView()
                        .navigationSplitViewColumnWidth(min: 200, ideal: 224, max: 300)
                } detail: {
                    DetailContainer()
                }
            }
        }
        .task {
            await model.bootstrap()
            model.startPolling()
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background: model.stopPolling()
            default: model.startPolling()
            }
        }
        .alert(
            "Wystąpił błąd",
            isPresented: Binding(
                get: { model.globalError != nil },
                set: { if !$0 { model.globalError = nil } }
            ),
            presenting: model.globalError
        ) { _ in
            Button("OK", role: .cancel) {}
        } message: { error in
            Text(error.message)
        }
    }
}

/// Hosts the section content with a service banner at the top when needed.
struct DetailContainer: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            if model.system.serviceState == .stopped {
                ServiceBanner()
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            sectionContent
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: model.system.serviceState)
        .task(id: model.selection) {
            await model.refreshCurrent()
        }
    }

    @ViewBuilder
    private var sectionContent: some View {
        switch model.selection {
        case .containers: ContainersView()
        case .images: ImagesView()
        case .volumes: VolumesView()
        case .networks: NetworksView()
        case .registries: RegistriesView()
        case .machines: MachinesView()
        case .system: SystemView()
        }
    }
}
