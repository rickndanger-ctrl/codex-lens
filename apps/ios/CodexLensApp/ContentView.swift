import SwiftUI

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var model = SessionViewModel()
    @State private var showingSettings = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    voiceCard
                    glassesCard
                    approvedWorkspaceCard
                    conversationCard
                }
                .padding(16)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Codex Lens")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showingSettings = true } label: {
                        Image(systemName: "gearshape.fill")
                    }
                }
            }
            .sheet(isPresented: $showingSettings) { settingsView }
            .alert("Codex Lens", isPresented: Binding(
                get: { model.errorMessage != nil },
                set: { if !$0 { model.errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) { model.errorMessage = nil }
            } message: {
                Text(model.errorMessage ?? "Unknown error")
            }
            .task {
                if !model.gatewayToken.isEmpty {
                    await model.connectGateway()
                }
                if model.autoStartAssistant, !model.isVoiceSessionArmed {
                    await model.startVoice()
                }
                while !Task.isCancelled {
                    model.refreshMetaDiagnostics()
                    model.pollAudioRoute()
                    try? await Task.sleep(for: .seconds(2))
                }
            }
            .onOpenURL { url in
                Task { await model.handleMetaCallback(url) }
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .inactive {
                    Task { await model.prepareForBackground() }
                } else if phase == .active {
                    Task { await model.handleBecameActive() }
                }
            }
        }
    }

    private var approvedWorkspaceCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Approved workspace", systemImage: "folder.badge.gearshape")
                .font(.headline)

            if model.approvedProjects.isEmpty {
                Text("Connect the Mac gateway to load its allowlisted projects.")
                    .foregroundStyle(.secondary)
            } else {
                Picker("Project", selection: $model.selectedProjectID) {
                    ForEach(model.approvedProjects) { project in
                        Text(project.displayName).tag(project.id)
                    }
                }
                .pickerStyle(.menu)

                if let project = model.selectedProject {
                    Label(
                        project.allowWorkspaceWrite
                            ? "Workspace edits allowed"
                            : "Read-only workspace",
                        systemImage: project.allowWorkspaceWrite
                            ? "pencil.circle"
                            : "eye.circle"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)

                    Label(
                        project.allowCommit || project.allowPush || project.allowDeploy
                            ? "Repository actions follow Mac policy"
                            : "Commit, push, and deploy remain blocked",
                        systemImage: "hand.raised.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
        }
        .cardStyle()
    }

    private var voiceCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(
                    model.isGlassesAudioRouted ? "Voice through glasses" : "Voice assistant",
                    systemImage: "waveform.circle.fill"
                )
                    .font(.headline)
                Spacer()
                Circle()
                    .fill(model.isVoiceActive ? .green : (model.isVoiceSessionArmed ? .orange : .gray))
                    .frame(width: 10, height: 10)
            }

            Text("Gateway: \(model.gatewayStatus) · Voice: \(model.voiceStatus)")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(model.audioRoute)
                .font(.caption)
                .foregroundStyle(.secondary)

            Toggle("Auto-start when app opens", isOn: $model.autoStartAssistant)
                .disabled(model.isVoiceSessionArmed)

            if model.isVoiceSessionArmed {
                Label(
                    model.isVoiceActive
                        ? "Listening quietly · Ask naturally; conversation help is automatic"
                        : "Recovering connection automatically",
                    systemImage: "mic.fill"
                )
                .font(.caption.weight(.semibold))
                .foregroundStyle(.red)
            }

            Button {
                Task {
                    if model.isVoiceSessionArmed { await model.stopVoice() }
                    else { await model.startVoice() }
                }
            } label: {
                Label(
                    model.isVoiceSessionArmed ? "Stop assistant" : "Start assistant",
                    systemImage: model.isVoiceSessionArmed ? "stop.fill" : "mic.fill"
                )
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(model.isVoiceSessionArmed ? .red : .accentColor)
            .disabled(model.isConnectingGateway)
        }
        .cardStyle()
    }

    private var glassesCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Meta glasses camera", systemImage: "eyeglasses")
                    .font(.headline)
                Spacer()
                if model.isVisualCaptureActive { ProgressView() }
            }

            Text(model.metaStatus)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)

            HStack {
                Button("Register") {
                    Task { await model.registerMetaGlasses() }
                }
                .buttonStyle(.bordered)

                Button(model.isGlassesConnected ? "Disconnect" : "Connect") {
                    Task {
                        if model.isGlassesConnected { await model.disconnectMetaGlasses() }
                        else { await model.connectMetaGlasses() }
                    }
                }
                .buttonStyle(.bordered)
            }

            Button {
                Task { await model.toggleLiveGlassesVideo() }
            } label: {
                Label(
                    model.isLiveGlassesVideo ? "Stop live glasses video" : "Start live glasses video",
                    systemImage: model.isLiveGlassesVideo ? "stop.fill" : "video.fill"
                )
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(model.isLiveGlassesVideo ? .red : .accentColor)
            .disabled(model.isVisualCaptureActive)

            Button {
                Task { await model.testGlassesCamera() }
            } label: {
                Label("Capture 3-shot reading burst", systemImage: "camera.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(model.isVisualCaptureActive || model.isLiveGlassesVideo)

            if let preview = model.glassesPreview {
                Image(uiImage: preview)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: 320)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .overlay(alignment: .bottomLeading) {
                        Label(
                            model.isLiveGlassesVideo ? "Live from the glasses" : "Captured by the glasses",
                            systemImage: model.isLiveGlassesVideo ? "dot.radiowaves.left.and.right" : "checkmark.circle.fill"
                        )
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(8)
                            .background(.black.opacity(0.65), in: Capsule())
                            .padding(8)
                    }

                Button {
                    Task { await model.sendGlassesViewToVoice() }
                } label: {
                    Label("Send a new glasses view to Codex", systemImage: "paperplane.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(!model.isVoiceActive || model.isVisualCaptureActive || model.isLiveGlassesVideo)
            }

            Text("Just say “Look at this,” “Read this screen,” or “Take a pic.” No name or wake word is required. Ordinary looks use one fast photo. Text-reading requests compare two high-resolution photos; ask for a careful look when you want three.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .cardStyle()
    }

    private var conversationCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Conversation", systemImage: "quote.bubble.fill")
                .font(.headline)

            if model.assistantTranscript.isEmpty {
                Text("Start the voice session, then speak through the glasses.")
                    .foregroundStyle(.secondary)
            } else {
                Text(model.assistantTranscript)
                    .textSelection(.enabled)
            }

            HStack {
                TextField("Type a message", text: $model.typedMessage)
                    .textFieldStyle(.roundedBorder)
                Button {
                    Task { await model.sendTypedMessage() }
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title2)
                }
                .disabled(!model.isVoiceActive || model.typedMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .cardStyle()
    }

    private var settingsView: some View {
        NavigationStack {
            Form {
                Section("Mac gateway") {
                    TextField("Gateway URL", text: $model.gatewayURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("Gateway bearer token", text: $model.gatewayToken)
                    Button("Save and connect") {
                        Task { await model.connectGateway() }
                    }
                }
                Section("Architecture") {
                    Text("The iPhone runs Codex Lens. Ray-Ban Meta glasses provide Bluetooth voice and the wearable camera. These glasses have no app screen.")
                }
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { showingSettings = false }
                }
            }
        }
    }
}

private extension View {
    func cardStyle() -> some View {
        padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18))
    }
}
