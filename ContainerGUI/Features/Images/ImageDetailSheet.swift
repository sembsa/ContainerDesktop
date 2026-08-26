import SwiftUI

struct ImageDetailSheet: View {
    let image: ImageInfo
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var loadState: LoadState = .loading
    @State private var selectedVariantIndex: Int = 0

    enum LoadState {
        case loading
        case loaded([ImageInspect])
        case error(String)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 8) {
                Image(systemName: "square.stack.3d.up.fill")
                    .foregroundStyle(Color.purple.gradient)
                    .font(.title3)
                Text(image.reference)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(image.reference)
                    .textSelection(.enabled)
                Spacer()
            }
            .padding(12)

            Divider()

            // Content
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            // Footer
            HStack {
                Spacer()
                Button(String(localized: "Zamknij")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(12)
        }
        .frame(width: 640, height: 700)
        .task { await load() }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch loadState {
        case .loading:
            VStack {
                Spacer()
                ProgressView()
                Spacer()
            }

        case .error(let message):
            VStack {
                Spacer()
                Text(message)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .padding()
                Spacer()
            }

        case .loaded(let results):
            if let inspect = results.first {
                loadedContent(inspect)
            } else {
                VStack {
                    Spacer()
                    Text(String(localized: "Brak danych obrazu."))
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            }
        }
    }

    @ViewBuilder
    private func loadedContent(_ inspect: ImageInspect) -> some View {
        let realVariants = inspect.variants.filter { !$0.isAttestation }
        let selectedVariant: ImageInspect.Variant? = realVariants.isEmpty
            ? nil
            : realVariants[min(selectedVariantIndex, realVariants.count - 1)]

        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                // Variant picker
                if realVariants.count > 1 {
                    variantPicker(realVariants)
                }
                // Overview card
                ImageOverviewCard(inspect: inspect, variant: selectedVariant)
                // Config card
                if let variant = selectedVariant, let config = variant.config?.config {
                    ImageConfigCard(config: config)
                }
                // Layers card
                if let variant = selectedVariant, let variantConfig = variant.config {
                    ImageLayersCard(variantConfig: variantConfig)
                }
            }
            .padding(12)
        }
        .onAppear {
            // Default to arm64 variant if available
            if let idx = realVariants.firstIndex(where: { $0.platform.architecture == "arm64" }) {
                selectedVariantIndex = idx
            }
        }
    }

    @ViewBuilder
    private func variantPicker(_ variants: [ImageInspect.Variant]) -> some View {
        let picker = Picker(String(localized: "Wariant"), selection: $selectedVariantIndex) {
            ForEach(variants.indices, id: \.self) { idx in
                Text(variants[idx].platformLabel).tag(idx)
            }
        }

        // A segmented control claims the sum of its label widths and will not
        // compress, so past a handful of platforms it pushes the sheet's content
        // out of the frame (issue #19). A menu hugs its selection instead.
        switch ImageVariantPickerStyle.style(forVariantCount: variants.count) {
        case .segmented:
            picker
                .pickerStyle(.segmented)
                .padding(.horizontal, 2)
        case .menu:
            picker
                .pickerStyle(.menu)
                .fixedSize()
                .padding(.horizontal, 2)
        }
    }

    // MARK: - Load

    private func load() async {
        loadState = .loading
        do {
            let results = try await model.images.inspect(image.reference)
            loadState = .loaded(results)
        } catch {
            loadState = .error(error.localizedDescription)
        }
    }
}

// MARK: - Section card (private copy, mirrors InspectView pattern)

private struct ImageSectionCard<Content: View>: View {
    let title: String
    var headerIcon: String? = nil
    var headerTint: Color = .secondary
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 4) {
                if let icon = headerIcon {
                    Image(systemName: icon)
                        .foregroundStyle(headerTint.gradient)
                }
                Text(title).font(.headline)
            }
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
    }
}

// MARK: - Overview card

private struct ImageOverviewCard: View {
    let inspect: ImageInspect
    let variant: ImageInspect.Variant?

    var body: some View {
        ImageSectionCard(title: String(localized: "Przegląd"), headerIcon: "info.circle.fill", headerTint: .blue) {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 4) {
                overviewRow(String(localized: "Referencja"), value: inspect.configuration.name)

                // Index digest (shortened)
                let indexDigest = inspect.configuration.descriptor.digest
                let shortIndex = digestShort(indexDigest)
                GridRow {
                    Text("Digest")
                        .foregroundStyle(.secondary)
                        .gridColumnAlignment(.trailing)
                    Text(shortIndex)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .help(indexDigest)
                }

                if let variant {
                    // Variant digest (shortened)
                    let shortVariant = digestShort(variant.digest)
                    GridRow {
                        Text(String(localized: "Digest wariantu"))
                            .foregroundStyle(.secondary)
                            .gridColumnAlignment(.trailing)
                        Text(shortVariant)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                            .help(variant.digest)
                    }

                    // Size
                    overviewRow(String(localized: "Rozmiar"), value: Format.bytes(variant.size))

                    // Created (from variant config)
                    if let created = variant.config?.created {
                        overviewRow(String(localized: "Utworzony"), mono: created.formattedTimestamp)
                    }

                    // Platform
                    overviewRow(String(localized: "Platforma"), mono: variant.platformLabel)
                }
            }
        }
    }

    private func overviewRow(_ label: String, value: String) -> some View {
        GridRow {
            Text(label)
                .foregroundStyle(.secondary)
                .gridColumnAlignment(.trailing)
            Text(value)
                .textSelection(.enabled)
        }
    }

    private func overviewRow(_ label: String, mono: String) -> some View {
        GridRow {
            Text(label)
                .foregroundStyle(.secondary)
                .gridColumnAlignment(.trailing)
            Text(mono)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
        }
    }

    private func digestShort(_ digest: String) -> String {
        if digest.hasPrefix("sha256:") {
            let hex = String(digest.dropFirst(7))
            return "sha256:\(String(hex.prefix(12)))"
        }
        return String(digest.prefix(20))
    }
}

// MARK: - Config card

private struct ImageConfigCard: View {
    let config: ImageInspect.RuntimeConfig

    var body: some View {
        let entrypoint = config.entrypoint ?? []
        let cmd = config.cmd ?? []
        let env = config.env ?? []
        let labels = config.labels ?? [:]
        let ports = config.exposedPorts?.keys.sorted() ?? []
        let workingDir = config.workingDir ?? ""

        let hasContent = !entrypoint.isEmpty || !cmd.isEmpty || !workingDir.isEmpty
            || !env.isEmpty || !labels.isEmpty || !ports.isEmpty

        if hasContent {
            ImageSectionCard(title: String(localized: "Konfiguracja"), headerIcon: "gearshape.fill", headerTint: .gray) {
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 4) {
                    if !entrypoint.isEmpty {
                        configRow("Entrypoint", mono: entrypoint.joined(separator: " "))
                    }
                    if !cmd.isEmpty {
                        configRow("Cmd", mono: cmd.joined(separator: " "))
                    }
                    if !workingDir.isEmpty {
                        configRow(String(localized: "Katalog roboczy"), mono: workingDir)
                    }
                    if !ports.isEmpty {
                        configRow(String(localized: "Porty"), value: ports.joined(separator: ", "))
                    }
                    if !env.isEmpty {
                        GridRow {
                            Text(String(localized: "Zmienne środowiskowe"))
                                .foregroundStyle(.secondary)
                                .gridColumnAlignment(.trailing)
                            VStack(alignment: .leading, spacing: 1) {
                                ForEach(env, id: \.self) { entry in
                                    Text(entry)
                                        .font(.system(.caption, design: .monospaced))
                                        .lineLimit(1)
                                        .help(entry)
                                        .textSelection(.enabled)
                                }
                            }
                        }
                    }
                    if !labels.isEmpty {
                        GridRow {
                            Text(String(localized: "Etykiety"))
                                .foregroundStyle(.secondary)
                                .gridColumnAlignment(.trailing)
                            VStack(alignment: .leading, spacing: 1) {
                                ForEach(labels.keys.sorted(), id: \.self) { key in
                                    let value = labels[key] ?? ""
                                    HStack(spacing: 2) {
                                        Text(key)
                                            .font(.system(.caption, design: .monospaced).weight(.semibold))
                                        Text("=")
                                            .font(.system(.caption, design: .monospaced))
                                            .foregroundStyle(.tertiary)
                                        Text(value)
                                            .font(.system(.caption, design: .monospaced))
                                            .foregroundStyle(.secondary)
                                            .textSelection(.enabled)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func configRow(_ label: String, value: String) -> some View {
        GridRow {
            Text(label)
                .foregroundStyle(.secondary)
                .gridColumnAlignment(.trailing)
            Text(value)
                .textSelection(.enabled)
        }
    }

    private func configRow(_ label: String, mono: String) -> some View {
        GridRow {
            Text(label)
                .foregroundStyle(.secondary)
                .gridColumnAlignment(.trailing)
            // An entrypoint or command line has no length bound, so it gets the
            // same treatment as the environment rows: truncate, full value on hover.
            Text(mono)
                .font(.system(.body, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
                .help(mono)
                .textSelection(.enabled)
        }
    }
}

// MARK: - Layers card

private struct ImageLayersCard: View {
    let variantConfig: ImageInspect.VariantConfig

    private var history: [ImageInspect.HistoryEntry] {
        variantConfig.history ?? []
    }

    private var diffCount: Int {
        variantConfig.rootfs?.diffIds?.count ?? 0
    }

    var body: some View {
        if !history.isEmpty {
            ImageSectionCard(
                title: String(format: String(localized: "Warstwy (%lld)"), history.count),
                headerIcon: "square.3.layers.3d",
                headerTint: .purple
            ) {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(history.indices, id: \.self) { idx in
                        let entry = history[idx]
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text("\(idx + 1)")
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .frame(width: 24, alignment: .trailing)

                            Text(entry.displayCommand.isEmpty ? entry.createdBy ?? "" : entry.displayCommand)
                                .font(.system(.caption, design: .monospaced))
                                .lineLimit(2)
                                .textSelection(.enabled)
                                .help(entry.createdBy ?? "")
                                .frame(maxWidth: .infinity, alignment: .leading)

                            if entry.emptyLayer == true {
                                Text(String(localized: "pusta"))
                                    .font(.caption2)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 2)
                                    .background(Capsule().fill(.secondary.opacity(0.15)))
                            }
                        }
                    }

                    if diffCount > 0 {
                        Divider()
                            .padding(.top, 4)
                        Text(String(format: String(localized: "Warstwy systemu plików: %lld"), diffCount))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}
