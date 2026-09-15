import Combine
import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase

    /// The version whose release notes have already been dismissed. Updates
    /// install silently through Sparkle, so without this nobody ever finds out
    /// what changed.
    @AppStorage("lastSeenVersion") private var lastSeenVersion = ""
    @State private var whatsNew: WhatsNew.Entry?

    static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    }

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
            // Not over the onboarding screen: someone who has not installed the
            // CLI yet has nothing to be told is new.
            if model.binaryFound {
                whatsNew = WhatsNew.entry(
                    lastSeen: lastSeenVersion.isEmpty ? nil : lastSeenVersion,
                    current: Self.appVersion
                )
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: WhatsNew.reopenNotification)) { _ in
            whatsNew = WhatsNew.all.first { $0.version == Self.appVersion } ?? WhatsNew.all.last
        }
        .sheet(item: $whatsNew) { entry in
            // Marked as seen on dismissal rather than on display, so a crash in
            // between does not swallow the notes.
            WhatsNewView(entry: entry) {
                lastSeenVersion = entry.version
                whatsNew = nil
            }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background: model.stopPolling()
            default: model.startPolling()
            }
        }
        .itemAlert("Wystąpił błąd", item: $model.globalError) { _ in
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
            } else if let skew = model.system.versionSkew {
                VersionSkewBanner(skew: skew)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            sectionContent
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: model.system.serviceState)
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: model.system.versionSkew)
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
        case .kubernetes: KubernetesView()
        case .workloads: WorkloadsView()
        case .helm: HelmView()
        case .registries: RegistriesView()
        case .machines: MachinesView()
        case .system: SystemView()
        }
    }
}
