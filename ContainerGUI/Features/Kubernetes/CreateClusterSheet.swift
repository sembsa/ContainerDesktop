import SwiftUI

/// `container k8s create` with live progress — the command pulls an ~850 MB
/// node image and then waits for kubeadm, so it must not look frozen.
struct CreateClusterSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var name = "k8s-dev"
    @State private var cpus = "4"
    @State private var memory = "4G"
    @State private var nodeImage = ""
    @State private var removeOnStop = false
    @State private var isCreating = false
    @State private var finished = false
    @State private var output: [LogLine] = []

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "square.stack.3d.up.fill")
                    .foregroundStyle(Color.cyan.gradient)
                    .font(.title3)
                Text("Nowy klaster Kubernetes")
                    .font(.headline)
                ExperimentalBadge()
                Spacer()
            }
            .padding(12)
            Divider()

            Form {
                Section {
                    HStack(spacing: 6) {
                        TextField("Nazwa", text: $name)
                        InfoTip(text: String(localized: "Nazwa klastra jest jednocześnie nazwą kontekstu kubectl oraz nazwą kontenera węzła."))
                    }
                    TextField("CPU (np. 4)", text: $cpus)
                    TextField("Pamięć (np. 4G)", text: $memory)
                } header: {
                    HStack(spacing: 5) {
                        Image(systemName: "gearshape.fill")
                            .foregroundStyle(Color.gray.gradient)
                        Text("Podstawowe")
                    }
                }

                Section {
                    HStack(spacing: 6) {
                        TextField("Obraz węzła (opcjonalnie)", text: $nodeImage)
                        InfoTip(text: String(localized: "Pozostaw puste, aby użyć domyślnego obrazu kindest/node dopasowanego do tej wersji container. Własny obraz pozwala wskazać inną wersję Kubernetes."))
                    }
                    Toggle("Usuń klaster po zatrzymaniu (--rm)", isOn: $removeOnStop)
                } header: {
                    HStack(spacing: 5) {
                        Image(systemName: "slider.horizontal.3")
                            .foregroundStyle(Color.gray.gradient)
                        Text("Zaawansowane")
                    }
                }

                if !output.isEmpty {
                    Section {
                        StreamLogBox(lines: output)
                            .frame(minHeight: 180)
                    } header: {
                        HStack(spacing: 5) {
                            Image(systemName: "terminal.fill")
                                .foregroundStyle(Color.gray.gradient)
                            Text("Postęp")
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .disabled(isCreating)

            Divider()
            HStack {
                if isCreating {
                    Text("Pobieranie obrazu węzła i uruchamianie kubeadm — to potrwa 1–2 minuty.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(finished ? "Gotowe" : "Zamknij") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button {
                    Task { await create() }
                } label: {
                    if isCreating { ProgressView().controlSize(.small) } else { Text("Utwórz") }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.glassProminent)
                // `finished` matters as much as `isCreating`: leaving the button
                // armed after a successful create ran `k8s create` a second time
                // with a name that already existed.
                .disabled(name.isEmpty || isCreating || finished)
            }
            .padding(12)
        }
        .frame(width: 640)
    }

    private func create() async {
        isCreating = true
        finished = false
        output = []
        defer { isCreating = false }

        let stream = model.kubernetes.createStream(
            name: name,
            cpus: cpus,
            memory: memory,
            nodeImage: nodeImage,
            removeOnStop: removeOnStop
        )
        do {
            for try await line in stream {
                output.append(LogLine(text: line))
            }
            finished = true
        } catch {
            output.append(LogLine(text: String(format: String(localized: "[błąd: %@]"), error.localizedDescription)))
        }
        await model.kubernetes.refresh()
    }
}

/// `container k8s load-image` — pushes a locally built image straight into the
/// cluster's containerd, so a chart can reference it with
/// `imagePullPolicy: Never` without any registry in between.
struct LoadImageSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    let cluster: K8sCluster

    @State private var image = ""
    @State private var platform = ""
    @State private var isLoading = false
    @State private var finished = false
    @State private var errorText: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "square.and.arrow.down.fill")
                    .foregroundStyle(Color.cyan.gradient)
                    .font(.title3)
                Text("Wczytaj obraz do klastra")
                    .font(.headline)
                Spacer()
            }
            .padding(12)
            Divider()

            Form {
                Section {
                    Picker("Obraz", selection: $image) {
                        Text("— wybierz —").tag("")
                        ForEach(model.images.items) { item in
                            Text(item.reference).tag(item.reference)
                        }
                    }
                    TextField("lub wpisz referencję obrazu", text: $image)
                    HStack(spacing: 6) {
                        TextField("Platforma (opcjonalnie, np. linux/arm64)", text: $platform)
                        InfoTip(text: String(localized: "Domyślnie linux/arm64. Podaj wartość tylko dla obrazów wieloplatformowych, gdy potrzebujesz innego wariantu."))
                    }
                } header: {
                    HStack(spacing: 5) {
                        Image(systemName: "square.stack.3d.up.fill")
                            .foregroundStyle(Color.purple.gradient)
                        Text(String(format: String(localized: "Klaster: %@"), cluster.name))
                    }
                } footer: {
                    Text("Po wczytaniu odwołuj się do obrazu w podach z imagePullPolicy: Never.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let errorText {
                    Section {
                        Label(errorText, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    }
                }
                if finished {
                    Section {
                        Label("Obraz został wczytany do klastra.", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                }
            }
            .formStyle(.grouped)
            .disabled(isLoading)

            Divider()
            HStack {
                Spacer()
                Button("Zamknij") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button {
                    Task { await load() }
                } label: {
                    if isLoading { ProgressView().controlSize(.small) } else { Text("Wczytaj") }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.glassProminent)
                .disabled(image.isEmpty || isLoading)
            }
            .padding(12)
        }
        .frame(width: 560)
    }

    private func load() async {
        isLoading = true
        finished = false
        errorText = nil
        defer { isLoading = false }
        do {
            try await model.kubernetes.loadImage(image, into: cluster, platform: platform)
            finished = true
        } catch {
            errorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}
