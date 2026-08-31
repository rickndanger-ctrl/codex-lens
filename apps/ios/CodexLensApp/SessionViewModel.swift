import AVFAudio
import CodexLensKit
import Foundation
import MWDATCore
import Security
import SwiftUI
import UIKit

@MainActor
final class SessionViewModel: ObservableObject {
    private static let defaultGatewayURL = "https://richards-mac-mini-2.tail6bc5cf.ts.net"

    @Published var gatewayURL: String
    @Published var gatewayToken: String
    @Published var gatewayStatus = "Not connected"
    @Published var voiceStatus = "Stopped"
    @Published var assistantTranscript = ""
    @Published var typedMessage = ""
    @Published private(set) var approvedProjects: [ApprovedProject] = []
    @Published var selectedProjectID: String {
        didSet { UserDefaults.standard.set(selectedProjectID, forKey: "selectedProjectID") }
    }
    @Published var isVoiceActive = false
    @Published private(set) var isVoiceSessionArmed = false
    @Published var isConnectingGateway = false
    @Published var autoStartAssistant: Bool {
        didSet { UserDefaults.standard.set(autoStartAssistant, forKey: "autoStartAssistant") }
    }

    @Published var metaStatus = "Checking Meta registration…"
    @Published var isGlassesConnected = false
    @Published var isVisualCaptureActive = false
    @Published var isLiveGlassesVideo = false
    @Published var glassesPreview: UIImage?
    @Published var audioRoute = "No active audio route"
    @Published private(set) var isGlassesAudioRouted = false
    @Published var errorMessage: String?

    var selectedProject: ApprovedProject? {
        approvedProjects.first { $0.id == selectedProjectID }
    }

    private var gateway: GatewayClient?
    private var transport: WebRTCRealtimeTransport?
    private var coordinator: RealtimeSessionCoordinator?
    private var isRealtimeConnecting = false
    private var isRealtimeSessionConfigured = false
    private var isRealtimePausedForMissingGlassesAudio = false
    private var audioRoutePauseTask: Task<Void, Never>?
    private var audioRoutePauseID: UUID?
    private var audioRouteRecoveryTask: Task<Void, Never>?
    private var audioRouteRecoveryID: UUID?
    private var isAudioRouteStabilizing = false
    private var audioRouteSettleTask: Task<Void, Never>?
    private var audioRouteObserverTokens: [NSObjectProtocol] = []
    private var gatewayRecoveryTask: Task<Void, Never>?
    private var gatewayRecoveryID: UUID?
    private let glasses = MetaGlassesCapture.shared
    private var realtimeRecoveryTask: Task<Void, Never>?
    private var realtimeRecoveryID: UUID?
    private var sessionRolloverTask: Task<Void, Never>?
    private var sessionRolloverDeadline: Date?
    private var isSessionRolloverPending = false
    private var pendingRealtimeRecoveryReason: String?
    private var realtimeExpiresAt: Date?
    private var activeRealtimeResponseCount = 0
    private var activeToolCallIDs: Set<String> = []
    private enum ToolDrainPolicy: Equatable {
        case abandonable
        case consequential
    }
    private var activeToolTasks: [String: Task<Void, Never>] = [:]
    private var activeToolDrainPolicies: [String: ToolDrainPolicy] = [:]
    private var realtimeToolGeneration: UInt = 0
    private var handledToolCallIDs: Set<String> = []
    private var handledToolCallOrder: [String] = []
    private var cameraRecoveryTask: Task<Void, Never>?
    private var cameraRecoveryDelayTask: Task<Void, Never>?
    private var cameraRecoveryID: UUID?
    private var cameraRecoveryGeneration: UInt = 0
    private var cameraRecoveryEpoch: UInt = 0
    private var cameraDeviceUnavailableFailureCount = 0
    private var cameraRecoverySuspendedForDeviceUnavailable = false
    private var cameraRecoveryWaitingForSessionResume = false
    private var cameraRecoveryWaitingForThermal = false
    private var cameraObservedPhysicalDisconnect = false
    private var cameraRecoveryNotBefore: Date?
    private var pendingBackgroundCameraPreparation = false
    private struct PendingTextConfirmation {
        let prepared: PreparedTextMessage
        var authorization: TextConfirmationAuthorization
    }
    private struct PendingComputerConfirmation {
        let prepared: PreparedComputerAction
        let preparedAt: Date
    }
    private var pendingTextConfirmation: PendingTextConfirmation?
    private var pendingComputerConfirmation: PendingComputerConfirmation?
    private var lastUserTranscript: String?
    private var lastUserTranscriptAt: Date?
#if DEBUG
    private var didRunDebugCoachAcceptance = false
    private var didRunDebugUserRequest = false
#endif

    private var debugRolloverDelay: TimeInterval? {
#if DEBUG
        guard
            let raw = ProcessInfo.processInfo.environment["CODEX_LENS_ROLLOVER_SECONDS"],
            let seconds = TimeInterval(raw),
            seconds >= 10,
            seconds <= 300
        else { return nil }
        return seconds
#else
        return nil
#endif
    }

    private static let maximumRolloverDrain: TimeInterval = 20
    private static let rolloverSafetyMargin: TimeInterval = 90
    private static let responseIdleGrace: TimeInterval = 0.5
    private static let persistentDeviceUnavailableLimit = 3
    private static let cameraReconnectSettleDelay: TimeInterval = 2
    // A pre-armed Meta stream turns on the glasses capture LED continuously,
    // drains the small glasses battery, and implies capture when no photo was
    // requested. Keep voice persistent, but open the camera only for an
    // explicit photo/look/read request and close it after the still arrives.
    private static let keepsCameraPrearmed = false

    private static func isPersistentMetaDeviceUnavailable(_ error: Error) -> Bool {
        guard case .unexpectedError(let description) = error as? DeviceSessionError else {
            return false
        }
        return description.localizedCaseInsensitiveContains("device unavailable")
    }

    private static func isMetaSessionPaused(_ error: Error) -> Bool {
        guard let captureError = error as? GlassesCaptureError else { return false }
        if case .sessionPaused = captureError { return true }
        return false
    }

    private static func isMetaSessionPausedReason(_ reason: String) -> Bool {
        reason.localizedCaseInsensitiveContains("session paused")
    }

    init() {
        autoStartAssistant = UserDefaults.standard.object(forKey: "autoStartAssistant") as? Bool ?? true
        gatewayURL = UserDefaults.standard.string(forKey: "gatewayURL") ?? Self.defaultGatewayURL
        gatewayToken = KeychainStore.loadGatewayToken() ?? ""
        selectedProjectID = UserDefaults.standard.string(forKey: "selectedProjectID") ?? ""
        glasses.onSessionLost = { [weak self] reason in
            self?.handleGlassesSessionLost(reason)
        }
        glasses.onDeviceAvailable = { [weak self] in
            self?.handleGlassesDeviceAvailable()
        }
        observeSystemAudioRoute()
        prepareAudioRouteMonitoring()
        refreshMetaDiagnostics()
        refreshAudioRoute()
    }

    deinit {
        for token in audioRouteObserverTokens {
            NotificationCenter.default.removeObserver(token)
        }
    }

    func connectGateway(reportErrors: Bool = true) async {
        guard !isConnectingGateway else { return }
        guard let baseURL = URL(string: gatewayURL), baseURL.scheme != nil else {
            if reportErrors { errorMessage = "Enter a valid gateway URL." }
            return
        }
        let token = gatewayToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else {
            if reportErrors { errorMessage = "Enter the gateway bearer token in Settings." }
            return
        }

        isConnectingGateway = true
        gatewayStatus = "Checking…"
        errorMessage = nil
        defer { isConnectingGateway = false }

        do {
            try KeychainStore.saveGatewayToken(token)
            UserDefaults.standard.set(gatewayURL, forKey: "gatewayURL")
            let client = GatewayClient(configuration: GatewayConfiguration(
                baseURL: baseURL,
                tokenProvider: { token }
            ))

            // Loading this protected route both verifies the bearer token and
            // binds the app to the Mac-owned allowlist. Never accept a path
            // typed or spoken directly on the phone.
            let projects = try await client.approvedProjects().projects
            guard !projects.isEmpty else {
                throw GatewayError.transport("The Mac gateway has no approved workspaces.")
            }
            approvedProjects = projects
            if !projects.contains(where: { $0.id == selectedProjectID }) {
                selectedProjectID = projects[0].id
            }
            gateway = client
            gatewayStatus = "Connected · \(selectedProject?.displayName ?? "workspace unavailable")"
        } catch {
            gateway = nil
            approvedProjects = []
            gatewayStatus = "Connection failed"
            if reportErrors { errorMessage = error.localizedDescription }
            NSLog("[CodexLensGateway] connection failed: %@", error.localizedDescription)
        }
    }

    func startVoice() async {
        guard !isVoiceSessionArmed else { return }
        // Arm before the first suspension point so the view task and the
        // scene-active callback cannot start two WebRTC peers concurrently.
        isVoiceSessionArmed = true
        voiceStatus = "Starting…"
        errorMessage = nil
        await startRealtimeWhenGatewayIsReady()
    }

    private func startRealtimeWhenGatewayIsReady() async {
        guard isVoiceSessionArmed,
              !isRealtimeConnecting,
              coordinator == nil
        else { return }

        prepareAudioRouteMonitoring()
        refreshAudioRoute()
        if !hasGlassesAudioInputAvailable {
            _ = await activelyAcquireGlassesAudioRoute(reason: "Assistant startup")
            refreshAudioRoute()
        }
        guard hasGlassesAudioInputAvailable else {
            isRealtimePausedForMissingGlassesAudio = true
            isVoiceActive = false
            voiceStatus = "Paused · waiting for glasses audio…"
            scheduleGlassesAudioRecovery(reason: "No glasses audio input at startup")
            return
        }

        if gateway == nil { await connectGateway(reportErrors: false) }
        guard isVoiceSessionArmed else { return }
        prepareAudioRouteMonitoring()
        refreshAudioRoute()
        guard hasGlassesAudioInputAvailable else {
            isRealtimePausedForMissingGlassesAudio = true
            isVoiceActive = false
            voiceStatus = "Paused · waiting for glasses audio…"
            scheduleGlassesAudioRecovery(reason: "Glasses audio disappeared during gateway startup")
            return
        }
        guard let gateway else {
            voiceStatus = "Gateway offline · retrying automatically…"
            scheduleGatewayRecovery(reason: "Gateway unavailable during assistant startup")
            return
        }

        isVoiceActive = false
        isRealtimeConnecting = true
        isRealtimeSessionConfigured = false
        realtimeToolGeneration &+= 1
        pendingRealtimeRecoveryReason = nil
        realtimeExpiresAt = nil
        voiceStatus = "Connecting…"
        errorMessage = nil
        let transport = WebRTCRealtimeTransport()
        transport.onEvent = { [weak self] event in
            Task { @MainActor in self?.handleTransportEvent(event) }
        }
        let coordinator = RealtimeSessionCoordinator(
            gateway: gateway,
            transport: transport,
            policy: ReconnectPolicy(base: 1, maximum: 30, maxAttempts: 120),
            model: "gpt-realtime-2.1"
        )
        self.transport = transport
        self.coordinator = coordinator

        let state = await withBackgroundExecution(
            named: "CodexLensRealtimeStart"
        ) {
            await coordinator.start()
        }
        isRealtimeConnecting = false
        let pendingRecoveryReason = pendingRealtimeRecoveryReason
        pendingRealtimeRecoveryReason = nil
        guard isVoiceSessionArmed,
              self.coordinator === coordinator,
              self.transport === transport
        else {
            await coordinator.stop()
            if isVoiceSessionArmed {
                scheduleGlassesAudioRecovery(
                    reason: "Realtime startup finished after glasses audio paused"
                )
            }
            return
        }

        if let pendingRecoveryReason {
            isVoiceActive = false
            voiceStatus = "Reconnecting automatically…"
            scheduleRealtimeRecovery(reason: pendingRecoveryReason)
            return
        }

        switch state {
        case .connected:
            handleRealtimeConnected(reason: "Voice session started")
        case .failed(let reason):
            isRealtimeSessionConfigured = false
            voiceStatus = "Failed"
            errorMessage = reason
            scheduleRealtimeRecovery(reason: reason)
        default:
            isVoiceActive = false
            scheduleRealtimeRecovery(reason: "Realtime startup did not finish.")
        }
        refreshAudioRoute()
    }

    func stopVoice() async {
        isVoiceSessionArmed = false
        cameraRecoveryGeneration &+= 1
        cameraRecoveryEpoch &+= 1
        isVoiceActive = false
        isRealtimeConnecting = false
        isRealtimeSessionConfigured = false
        isRealtimePausedForMissingGlassesAudio = false
        audioRoutePauseTask?.cancel()
        audioRoutePauseTask = nil
        audioRoutePauseID = nil
        audioRouteRecoveryTask?.cancel()
        audioRouteRecoveryTask = nil
        audioRouteRecoveryID = nil
        audioRouteSettleTask?.cancel()
        audioRouteSettleTask = nil
        gatewayRecoveryTask?.cancel()
        gatewayRecoveryTask = nil
        gatewayRecoveryID = nil
        realtimeRecoveryTask?.cancel()
        realtimeRecoveryTask = nil
        realtimeRecoveryID = nil
        sessionRolloverTask?.cancel()
        sessionRolloverTask = nil
        sessionRolloverDeadline = nil
        isSessionRolloverPending = false
        pendingRealtimeRecoveryReason = nil
        realtimeExpiresAt = nil
        activeRealtimeResponseCount = 0
        realtimeToolGeneration &+= 1
        for (callID, task) in activeToolTasks
            where activeToolDrainPolicies[callID] == .abandonable {
            task.cancel()
        }
        activeToolCallIDs.removeAll()
        handledToolCallIDs.removeAll()
        handledToolCallOrder.removeAll()
        let staleCameraRecoveryTask = cameraRecoveryTask
        staleCameraRecoveryTask?.cancel()
        cameraRecoveryTask = nil
        cameraRecoveryDelayTask?.cancel()
        cameraRecoveryDelayTask = nil
        cameraRecoveryID = nil
        pendingBackgroundCameraPreparation = false
        pendingTextConfirmation = nil
        pendingComputerConfirmation = nil
        lastUserTranscript = nil
        lastUserTranscriptAt = nil
        transport?.onEvent = nil
        let oldCoordinator = coordinator
        coordinator = nil
        transport = nil
        await glasses.stopCamera()
        await staleCameraRecoveryTask?.value
        await oldCoordinator?.stop()
        voiceStatus = "Stopped"
        refreshAudioRoute()
    }

    func prepareForBackground() async {
        guard isVoiceSessionArmed else { return }
        let recoveryGeneration = cameraRecoveryGeneration
        NSLog(
            "[CodexLensLifecycle] preparing for background; cameraReady=%@ visualCapture=%@ recovery=%@",
            glasses.isBackgroundCaptureReady.description,
            isVisualCaptureActive.description,
            (cameraRecoveryTask != nil).description
        )
        if isLiveGlassesVideo {
            await glasses.stopCamera()
            guard isVoiceSessionArmed,
                  cameraRecoveryGeneration == recoveryGeneration,
                  !Task.isCancelled else { return }
            isLiveGlassesVideo = false
        }
        // Locking the screen can arrive while Meta is temporarily pausing its
        // HEVC stream to deliver a still. Starting another prepare operation at
        // that moment stops the camera underneath the accepted photo request.
        // Let the in-flight capture finish, then rearm from its defer block.
        if isVisualCaptureActive {
            NSLog("[CodexLensLifecycle] in-flight photo may finish in background; camera will close afterward")
            return
        }
        if !Self.keepsCameraPrearmed {
            await glasses.stopCamera()
            guard isVoiceSessionArmed,
                  cameraRecoveryGeneration == recoveryGeneration,
                  !Task.isCancelled else { return }
            pendingBackgroundCameraPreparation = false
            refreshMetaDiagnostics()
            NSLog("[CodexLensLifecycle] background voice retained; camera closed until requested")
            return
        }
        // The SDK calls used by recovery are asynchronous and MainActor
        // reentrant. Do not start a second camera/session lifecycle operation
        // while one is already in flight; wake its bounded backoff instead.
        if cameraRecoveryTask != nil {
            pendingBackgroundCameraPreparation = true
            scheduleCameraRecovery(
                reason: "App moved to the background during camera recovery",
                forceImmediate: true
            )
            return
        }
        do {
            try await glasses.prepareBackgroundCapture()
            guard isVoiceSessionArmed,
                  cameraRecoveryGeneration == recoveryGeneration,
                  !Task.isCancelled else { return }
            pendingBackgroundCameraPreparation = false
            isGlassesConnected = true
            refreshMetaDiagnostics()
        } catch {
            guard isVoiceSessionArmed,
                  cameraRecoveryGeneration == recoveryGeneration,
                  !Task.isCancelled else { return }
            pendingBackgroundCameraPreparation = true
            scheduleCameraRecovery(reason: "App moved to the background", forceImmediate: true)
        }
    }

    func handleBecameActive() async {
        NSLog("[CodexLensLifecycle] app became active")
        noteCameraLifecycleTransition(
            reason: "App became active",
            settleDelay: Self.cameraReconnectSettleDelay,
            clearsSessionPause: true
        )
        handleObservedAudioRouteChange(reason: "App became active")
        if autoStartAssistant, !isVoiceSessionArmed, !isConnectingGateway {
            await startVoice()
            return
        }
        guard isVoiceSessionArmed else { return }
        if audioRoutePauseTask != nil || isRealtimePausedForMissingGlassesAudio {
            scheduleGlassesAudioRecovery(
                reason: "App became active while waiting for glasses audio",
                forceImmediate: true
            )
            if !glasses.isBackgroundCaptureReady {
                scheduleCameraRecovery(reason: "App returned to the foreground", forceImmediate: true)
            }
            return
        }
        if coordinator == nil, !isRealtimeConnecting {
            await startRealtimeWhenGatewayIsReady()
            // Starting Realtime can span the entire foreground transition.
            // Do not return with a camera that Meta stopped while the app was
            // inactive; explicitly rearm it after audio startup finishes.
            if isVoiceSessionArmed, !glasses.isBackgroundCaptureReady {
                scheduleCameraRecovery(
                    reason: "App returned to the foreground after Realtime startup",
                    forceImmediate: true
                )
            }
            return
        }
        if !isVoiceActive, !isRealtimeConnecting {
            scheduleRealtimeRecovery(reason: "App returned to the foreground")
        }
        if !glasses.isBackgroundCaptureReady {
            scheduleCameraRecovery(reason: "App returned to the foreground", forceImmediate: true)
        }
    }

    func sendTypedMessage() async {
        let text = typedMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let transport else { return }
        typedMessage = ""
        do {
            try await transport.send(.userText(text))
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func registerMetaGlasses() async {
        metaStatus = "Opening Meta AI…"
        errorMessage = nil
        do {
            try await glasses.startRegistration()
            refreshMetaDiagnostics()
        } catch {
            metaStatus = "Registration failed"
            errorMessage = error.localizedDescription
        }
    }

    func handleMetaCallback(_ url: URL) async {
        do {
            try await glasses.handleCallback(url)
            noteCameraLifecycleTransition(
                reason: "Meta registration callback completed",
                settleDelay: Self.cameraReconnectSettleDelay,
                clearsSessionPause: true
            )
            refreshMetaDiagnostics()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func connectMetaGlasses() async {
        noteCameraLifecycleTransition(
            reason: "User requested Meta connection",
            settleDelay: Self.cameraReconnectSettleDelay,
            clearsSessionPause: true
        )
        metaStatus = "Waiting for glasses…"
        errorMessage = nil
        do {
            try await glasses.connect()
            isGlassesConnected = true
            if isVoiceSessionArmed {
                scheduleCameraRecovery(reason: "Glasses connected")
            } else {
                refreshMetaDiagnostics()
            }
        } catch {
            NSLog("[CodexLensCamera] connect failed: %@", String(describing: error))
            isGlassesConnected = false
            refreshMetaDiagnostics()
            errorMessage = error.localizedDescription
        }
    }

    func disconnectMetaGlasses() async {
        await glasses.disconnect()
        isGlassesConnected = false
        isVisualCaptureActive = false
        isLiveGlassesVideo = false
        refreshMetaDiagnostics()
    }

    func toggleLiveGlassesVideo() async {
        if isLiveGlassesVideo {
            await glasses.stopCamera()
            isLiveGlassesVideo = false
            if isVoiceSessionArmed {
                scheduleCameraRecovery(reason: "Live video stopped", forceImmediate: true)
            }
            metaStatus = "Live video stopped · rearming photos · \(glasses.deviceDiagnostics)"
            return
        }

        isVisualCaptureActive = true
        metaStatus = "Starting live glasses video…"
        errorMessage = nil
        defer {
            finishVisualCapture(
                rearmReason: "Live-video transition finished after background transition"
            )
        }
        do {
            try await glasses.startLiveVideo { [weak self] image in
                Task { @MainActor [weak self] in self?.glassesPreview = image }
            }
            isGlassesConnected = true
            isLiveGlassesVideo = true
            metaStatus = "Live video · \(glasses.deviceDiagnostics)"
        } catch {
            isLiveGlassesVideo = false
            refreshMetaDiagnostics()
            errorMessage = error.localizedDescription
        }
    }

    func testGlassesCamera() async {
        if isLiveGlassesVideo { return }
        beginExplicitCameraAttempt(reason: "On-screen glasses camera test")
        isVisualCaptureActive = true
        metaStatus = "Opening glasses camera…"
        errorMessage = nil
        defer {
            finishVisualCapture(
                rearmReason: "Camera test finished after background transition"
            )
        }

        do {
            let evidence = try await captureBackgroundSafeEvidence(
                count: 3,
                profile: .reading
            )
            guard let image = UIImage(data: evidence.selectedJPEGData) else {
                throw GlassesCaptureError.invalidImage
            }
            glassesPreview = image
            isGlassesConnected = true
            refreshMetaDiagnostics()
        } catch let error as DeviceSessionError {
            NSLog("[CodexLensCamera] test failed: %@", String(describing: error))
            isGlassesConnected = false
            refreshMetaDiagnostics()
            if error == .datAppOnTheGlassesUpdateRequired {
                errorMessage = "Meta must update its camera app on the glasses. Codex Lens is opening the correct App Connections update page now."
                try? await glasses.openGlassesAppUpdate()
            } else {
                errorMessage = error.localizedDescription
                if isVoiceSessionArmed {
                    scheduleCameraRecovery(reason: error.localizedDescription, forceImmediate: true)
                }
            }
        } catch {
            NSLog("[CodexLensCamera] test failed: %@", String(describing: error))
            isGlassesConnected = false
            refreshMetaDiagnostics()
            errorMessage = error.localizedDescription
            if Self.isMetaSessionPaused(error) {
                markCameraRecoveryWaitingForSessionResume(reason: error.localizedDescription)
            } else if isVoiceSessionArmed {
                scheduleCameraRecovery(reason: error.localizedDescription, forceImmediate: true)
            }
        }
    }

    func sendGlassesViewToVoice() async {
        guard let transport, isVoiceActive else {
            errorMessage = "Start the voice session first."
            return
        }
        beginExplicitCameraAttempt(reason: "Manual glasses view send")
        isVisualCaptureActive = true
        defer {
            finishVisualCapture(
                rearmReason: "Manual visual send finished after background transition"
            )
        }
        do {
            let evidence = try await captureBackgroundSafeEvidence(
                count: 3,
                profile: .reading
            )
            glassesPreview = UIImage(data: evidence.selectedJPEGData)
            try transport.sendVisualContexts(
                jpegData: [evidence.selectedJPEGData],
                source: "Meta glasses",
                instruction: "Inspect what the user is showing you."
            )
        } catch {
            errorMessage = error.localizedDescription
            if Self.isMetaSessionPaused(error) {
                markCameraRecoveryWaitingForSessionResume(reason: error.localizedDescription)
            } else {
                scheduleCameraRecovery(reason: error.localizedDescription, forceImmediate: true)
            }
        }
    }

    func stopVisualCapture() async {
        await glasses.stopCamera()
        isVisualCaptureActive = false
        isLiveGlassesVideo = false
        if isVoiceSessionArmed {
            scheduleCameraRecovery(reason: "Visual capture stopped", forceImmediate: true)
        }
    }

    func refreshMetaDiagnostics() {
        if cameraRecoveryWaitingForSessionResume {
            metaStatus = "Meta camera session paused · waiting for glasses to resume · voice remains available"
        } else if cameraRecoveryWaitingForThermal || glasses.isThermallyBlocked {
            metaStatus = "Glasses too hot · camera paused · voice remains available"
        } else if cameraRecoverySuspendedForDeviceUnavailable {
            metaStatus = "Meta camera unavailable · checking once per minute · voice remains available"
        } else if cameraRecoveryTask != nil {
            metaStatus = "Camera reconnecting automatically · \(glasses.deviceDiagnostics)"
        } else if glasses.isBackgroundCaptureReady {
            metaStatus = "Background camera armed · \(glasses.deviceDiagnostics)"
        } else {
            metaStatus = "\(glasses.registrationStatus.capitalized) · \(glasses.deviceDiagnostics)"
        }
    }

    private static func isGlassesHFPInput(_ input: AVAudioSessionPortDescription) -> Bool {
        input.portType == .bluetoothHFP &&
            (input.portName.localizedCaseInsensitiveContains("Meta") ||
             input.portName.localizedCaseInsensitiveContains("Ray-Ban"))
    }

    private var hasGlassesAudioInputAvailable: Bool {
        let session = AVAudioSession.sharedInstance()
        return session.currentRoute.inputs.contains(where: Self.isGlassesHFPInput) ||
            (session.availableInputs?.contains(where: Self.isGlassesHFPInput) ?? false)
    }

    /// Select the category that exposes HFP inputs without activating the
    /// iPhone microphone. This leaves route notifications available while the
    /// Realtime peer is intentionally stopped.
    private func prepareAudioRouteMonitoring() {
        guard coordinator == nil, !isRealtimeConnecting else { return }
        do {
            try AVAudioSession.sharedInstance().setCategory(
                .playAndRecord,
                mode: .voiceChat,
                options: [.allowBluetoothHFP]
            )
        } catch {
            NSLog(
                "[CodexLensAudio] passive route monitoring setup failed: %@",
                error.localizedDescription
            )
        }
    }

    /// A passive AVAudioSession does not always publish an already-connected
    /// Bluetooth HFP input after an app update or process restart. Briefly
    /// activating voiceChat forces iOS to negotiate the route. We keep the
    /// session active only when the negotiated input is the Ray-Ban headset;
    /// the built-in iPhone microphone is never accepted as a voice source.
    private func activelyAcquireGlassesAudioRoute(reason: String) async -> Bool {
        guard coordinator == nil, !isRealtimeConnecting else { return false }
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(
                .playAndRecord,
                mode: .voiceChat,
                options: [.allowBluetoothHFP]
            )
            try session.setActive(true)
            if let glassesInput = session.availableInputs?.first(where: Self.isGlassesHFPInput) {
                try session.setPreferredInput(glassesInput)
            }
            try? await Task.sleep(for: .milliseconds(500))
            refreshAudioRoute()
            if hasGlassesAudioInputAvailable {
                NSLog("[CodexLensAudio] actively acquired glasses HFP route: %@", reason)
                return true
            }
            try? session.setActive(false, options: [.notifyOthersOnDeactivation])
            NSLog("[CodexLensAudio] active route probe found no glasses input: %@", reason)
            return false
        } catch {
            try? session.setActive(false, options: [.notifyOthersOnDeactivation])
            NSLog(
                "[CodexLensAudio] active glasses route acquisition failed (%@): %@",
                reason,
                error.localizedDescription
            )
            return false
        }
    }

    private func observeSystemAudioRoute() {
        let center = NotificationCenter.default
        audioRouteObserverTokens.append(center.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleObservedAudioRouteChange(reason: "System audio route changed")
            }
        })
        audioRouteObserverTokens.append(center.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleObservedAudioRouteChange(reason: "iPhone audio services restarted")
            }
        })
    }

    func refreshAudioRoute() {
        let route = AVAudioSession.sharedInstance().currentRoute
        let inputs = route.inputs.map(\.portName)
        let outputs = route.outputs.map(\.portName)
        isGlassesAudioRouted = route.inputs.contains(where: Self.isGlassesHFPInput)
        if inputs.isEmpty && outputs.isEmpty {
            audioRoute = "No active audio route"
        } else {
            audioRoute = "Mic: \(inputs.joined(separator: ", ")) · Sound: \(outputs.joined(separator: ", "))"
        }
    }

    /// Foreground polling backs up AVAudioSession notifications. The policy is
    /// fail-closed, so a missed route-loss event cannot leave the phone mic on.
    func pollAudioRoute() {
        handleObservedAudioRouteChange(reason: "Periodic audio route check")
    }

    private func handleObservedAudioRouteChange(reason: String) {
        refreshAudioRoute()
        guard isVoiceSessionArmed else { return }

        let phase: GlassesAudioSessionPhase
        if coordinator == nil, !isRealtimeConnecting {
            phase = .stopped
        } else if isRealtimeSessionConfigured {
            phase = .connected
        } else {
            phase = .connecting
        }

        switch GlassesAudioRoutePolicy.action(
            assistantArmed: isVoiceSessionArmed,
            sessionPhase: phase,
            glassesInputAvailable: hasGlassesAudioInputAvailable,
            glassesInputRouted: isGlassesAudioRouted
        ) {
        case .none:
            if phase == .connected, isGlassesAudioRouted {
                markRealtimeLive(reason: reason)
            }
        case .pauseRealtime:
            scheduleRealtimePauseForMissingGlassesAudio(reason: reason)
        case .resumeRealtime:
            scheduleGlassesAudioRecovery(reason: reason, forceImmediate: true)
        }
    }

    private func handleTransportEvent(_ event: WebRTCTransportEvent) {
        switch event {
        case .connected:
            guard isVoiceSessionArmed else { return }
            NSLog("[CodexLensRealtime] session configured and connected")
            handleRealtimeConnected(reason: "Realtime connected")
            errorMessage = nil
        case .disconnected(let reason):
            guard isVoiceSessionArmed else { return }
            NSLog("[CodexLensRealtime] disconnected: %@", reason)
            isVoiceActive = false
            isRealtimeSessionConfigured = false
            realtimeToolGeneration &+= 1
            invalidatePendingConfirmations(reason: "Realtime disconnected")
            voiceStatus = "Reconnecting automatically…"
            refreshAudioRoute()
            if !hasGlassesAudioInputAvailable {
                scheduleRealtimePauseForMissingGlassesAudio(reason: reason)
                return
            }
            if isRealtimeConnecting {
                pendingRealtimeRecoveryReason = reason
                return
            }
            sessionRolloverTask?.cancel()
            sessionRolloverTask = nil
            sessionRolloverDeadline = nil
            isSessionRolloverPending = false
            scheduleRealtimeRecovery(reason: reason)
        case .audioRouteChanged:
            handleObservedAudioRouteChange(reason: "Realtime audio route changed")
            NSLog("[CodexLensRealtime] audio route changed: %@", audioRoute)
        case .sessionExpires(let date):
            NSLog("[CodexLensRealtime] server session expires at %@", date as NSDate)
            realtimeExpiresAt = date
            if !isRealtimeConnecting {
                scheduleSessionRollover(expiresAt: date)
            }
        case .responseActivityChanged(let count):
            activeRealtimeResponseCount = max(0, count)
        case .assistantText(let delta):
            assistantTranscript += delta
            if assistantTranscript.count > 12_000 {
                assistantTranscript = String(assistantTranscript.suffix(10_000))
            }
        case .assistantResponseCompleted(let spoken):
            guard spoken, var pending = pendingTextConfirmation,
                  pending.authorization.readbackCompletedAt == nil else { break }
            pending.authorization.noteReadbackCompleted(at: Date())
            guard pending.authorization.readbackCompletedAt != nil else {
                invalidatePendingConfirmations(
                    reason: "Prepared text expired before readback completed"
                )
                break
            }
            pendingTextConfirmation = pending
            NSLog("[CodexLensMessages] prepared-message readback completed")
        case .userTranscript(let transcript):
            let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                lastUserTranscript = String(trimmed.prefix(240))
                lastUserTranscriptAt = Date()
                if let pending = pendingTextConfirmation {
                    let decision = pending.authorization.decision(
                        transcript: trimmed,
                        transcribedAt: lastUserTranscriptAt ?? Date(),
                        now: Date()
                    )
                    if decision != .authorize {
                        invalidatePendingConfirmations(
                            reason: "Intervening speech invalidated the prepared text"
                        )
                    }
                }
            }
        case .toolCall(let callId, let name, let arguments):
            receiveToolCall(callId: callId, name: name, arguments: arguments)
        case .error(let message):
            NSLog("[CodexLensRealtime] error: %@", message)
            errorMessage = message
        }
    }

    private func handleRealtimeConnected(reason: String) {
        isRealtimeSessionConfigured = true
        refreshAudioRoute()
        if isGlassesAudioRouted {
            markRealtimeLive(reason: reason)
            return
        }

        // The transport's microphone track remains disabled while HFP settles.
        // Give an available glasses input a short chance to become the active
        // route, then tear down the peer if it does not.
        isVoiceActive = false
        if hasGlassesAudioInputAvailable {
            voiceStatus = "Connecting glasses audio…"
            scheduleAudioRouteSettleCheck(reason: reason)
        } else {
            scheduleRealtimePauseForMissingGlassesAudio(reason: reason)
        }
    }

    private func markRealtimeLive(reason: String) {
        guard isVoiceSessionArmed,
              coordinator != nil,
              isRealtimeSessionConfigured,
              isGlassesAudioRouted
        else { return }

        let wasLive = isVoiceActive
        audioRouteSettleTask?.cancel()
        audioRouteSettleTask = nil
        isRealtimePausedForMissingGlassesAudio = false
        isVoiceActive = true
        voiceStatus = "Live"
        if !wasLive {
            NSLog("[CodexLensAudio] glasses-only Realtime live: %@", reason)
            scheduleCameraRecovery(reason: "Glasses audio route live")
        }
        // Connected/expiry callbacks cross onto MainActor independently and
        // may both arrive before coordinator.start() clears this flag. Always
        // schedule once startup has actually returned, even if an earlier
        // callback already marked the same generation live.
        if !isRealtimeConnecting {
            scheduleSessionRollover(expiresAt: realtimeExpiresAt)
        }
#if DEBUG
        if !didRunDebugCoachAcceptance,
           let acceptanceTranscript = ProcessInfo.processInfo.environment["CODEX_LENS_COACH_ACCEPTANCE_TRANSCRIPT"],
           !acceptanceTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let transport {
            didRunDebugCoachAcceptance = true
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1))
                guard self.isVoiceActive else { return }
                do {
                    try transport.runCoachAcceptance(transcript: acceptanceTranscript)
                } catch {
                    self.errorMessage = error.localizedDescription
                }
            }
        }
        if !didRunDebugUserRequest,
           let acceptanceRequest = ProcessInfo.processInfo.environment["CODEX_LENS_ACCEPTANCE_USER_REQUEST"],
           !acceptanceRequest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let transport {
            didRunDebugUserRequest = true
            let requestedDelay = ProcessInfo.processInfo.environment["CODEX_LENS_ACCEPTANCE_DELAY_SECONDS"]
                .flatMap(TimeInterval.init) ?? 1
            let delay = min(max(requestedDelay, 1), 30)
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(delay))
                guard self.isVoiceActive else { return }
                do {
                    try transport.runExplicitUserRequestAcceptance(request: acceptanceRequest)
                    NSLog("[CodexLensAcceptance] injected explicit user request")
                } catch {
                    self.errorMessage = error.localizedDescription
                }
            }
        }
#endif
    }

    private func scheduleAudioRouteSettleCheck(reason: String) {
        audioRouteSettleTask?.cancel()
        audioRouteSettleTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(750))
            guard let self, !Task.isCancelled else { return }
            self.audioRouteSettleTask = nil
            self.handleObservedAudioRouteChange(reason: "\(reason); route settle deadline")
        }
    }

    private func scheduleRealtimePauseForMissingGlassesAudio(reason: String) {
        guard isVoiceSessionArmed,
              !isRealtimePausedForMissingGlassesAudio,
              audioRoutePauseTask == nil
        else { return }
        isVoiceActive = false
        voiceStatus = "Paused · waiting for glasses audio…"
        audioRouteSettleTask?.cancel()
        audioRouteSettleTask = nil
        audioRouteRecoveryTask?.cancel()
        audioRouteRecoveryTask = nil
        audioRouteRecoveryID = nil

        let pauseID = UUID()
        audioRoutePauseID = pauseID
        audioRoutePauseTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.pauseRealtimeForMissingGlassesAudio(reason: reason)
            guard self.audioRoutePauseID == pauseID else { return }
            self.audioRoutePauseTask = nil
            self.audioRoutePauseID = nil
            guard self.isVoiceSessionArmed else { return }
            self.scheduleGlassesAudioRecovery(
                reason: "Waiting after glasses audio route loss"
            )
        }
    }

    private func pauseRealtimeForMissingGlassesAudio(reason: String) async {
        guard isVoiceSessionArmed else { return }
        refreshAudioRoute()
        guard !isGlassesAudioRouted else {
            markRealtimeLive(reason: "Glasses route returned before pause")
            return
        }

        if isRealtimeSessionConfigured,
           coordinator != nil,
           transport != nil,
           !isRealtimeConnecting {
            // The transport route observer disables its microphone track and
            // WebRTC audio unit when HFP disappears. Preserve the configured
            // peer and its existing track: rebuilding either produced a peer
            // that signaled successfully but sent zero outbound audio packets.
            guard !isRealtimePausedForMissingGlassesAudio else { return }
            isRealtimePausedForMissingGlassesAudio = true
            isVoiceActive = false
            voiceStatus = "Paused · waiting for glasses audio…"
            invalidatePendingConfirmations(reason: "Glasses audio route unavailable")
            lastUserTranscript = nil
            lastUserTranscriptAt = nil
            NSLog("[CodexLensAudio] Realtime peer retained with microphone transmission disabled")
            return
        }

        NSLog("[CodexLensAudio] pausing Realtime; glasses route unavailable: %@", reason)
        isRealtimePausedForMissingGlassesAudio = true
        isVoiceActive = false
        isRealtimeSessionConfigured = false
        voiceStatus = "Paused · waiting for glasses audio…"
        gatewayRecoveryTask?.cancel()
        gatewayRecoveryTask = nil
        gatewayRecoveryID = nil
        realtimeRecoveryTask?.cancel()
        realtimeRecoveryTask = nil
        realtimeRecoveryID = nil
        sessionRolloverTask?.cancel()
        sessionRolloverTask = nil
        sessionRolloverDeadline = nil
        isSessionRolloverPending = false
        pendingRealtimeRecoveryReason = nil
        realtimeExpiresAt = nil
        activeRealtimeResponseCount = 0
        realtimeToolGeneration &+= 1
        for (callID, task) in activeToolTasks
            where activeToolDrainPolicies[callID] == .abandonable {
            task.cancel()
        }
        activeToolCallIDs.removeAll()
        invalidatePendingConfirmations(reason: "Glasses audio route unavailable")
        lastUserTranscript = nil
        lastUserTranscriptAt = nil

        transport?.onEvent = nil
        let oldCoordinator = coordinator
        coordinator = nil
        transport = nil
        await oldCoordinator?.stop()
        prepareAudioRouteMonitoring()
        refreshAudioRoute()
        NSLog("[CodexLensAudio] Realtime stopped; passive glasses monitoring remains armed")
    }

    private func scheduleGlassesAudioRecovery(
        reason: String,
        forceImmediate: Bool = false
    ) {
        guard isVoiceSessionArmed,
              coordinator == nil,
              audioRoutePauseTask == nil
        else { return }

        if forceImmediate, !isAudioRouteStabilizing {
            audioRouteRecoveryTask?.cancel()
            audioRouteRecoveryTask = nil
            audioRouteRecoveryID = nil
        }
        guard audioRouteRecoveryTask == nil else { return }

        let recoveryID = UUID()
        audioRouteRecoveryID = recoveryID
        audioRouteRecoveryTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.isAudioRouteStabilizing = false
                if self.audioRouteRecoveryID == recoveryID {
                    self.audioRouteRecoveryTask = nil
                    self.audioRouteRecoveryID = nil
                }
            }
            let delays: [TimeInterval] = forceImmediate
                ? [0, 1, 2, 4, 8, 15, 30]
                : [1, 2, 4, 8, 15, 30]
            var attempt = 0
            NSLog("[CodexLensAudio] passive glasses monitoring began: %@", reason)

            while self.isVoiceSessionArmed,
                  self.coordinator == nil,
                  !Task.isCancelled,
                  self.audioRouteRecoveryID == recoveryID {
                let delay = delays[min(attempt, delays.count - 1)]
                if delay > 0 {
                    try? await Task.sleep(for: .seconds(delay))
                }
                guard self.isVoiceSessionArmed,
                      self.coordinator == nil,
                      !Task.isCancelled,
                      self.audioRouteRecoveryID == recoveryID
                else { return }

                if self.isRealtimeConnecting {
                    attempt += 1
                    continue
                }
                self.prepareAudioRouteMonitoring()
                self.refreshAudioRoute()
                if !self.hasGlassesAudioInputAvailable {
                    _ = await self.activelyAcquireGlassesAudioRoute(
                        reason: "Automatic recovery attempt \(attempt + 1)"
                    )
                    self.refreshAudioRoute()
                }
                if self.hasGlassesAudioInputAvailable {
                    self.isAudioRouteStabilizing = true
                    self.voiceStatus = "Glasses audio found · stabilizing…"
                    NSLog("[CodexLensAudio] glasses input returned; waiting for stable HFP route")
                    try? await Task.sleep(for: .seconds(2))
                    guard self.isVoiceSessionArmed,
                          self.coordinator == nil,
                          !Task.isCancelled,
                          self.audioRouteRecoveryID == recoveryID
                    else { return }
                    self.prepareAudioRouteMonitoring()
                    self.refreshAudioRoute()
                    guard self.hasGlassesAudioInputAvailable else {
                        self.isAudioRouteStabilizing = false
                        attempt += 1
                        continue
                    }
                    self.audioRouteRecoveryTask = nil
                    self.audioRouteRecoveryID = nil
                    self.voiceStatus = "Glasses audio found · reconnecting…"
                    NSLog("[CodexLensAudio] glasses input returned; restarting Realtime")
                    await self.startRealtimeWhenGatewayIsReady()
                    return
                }

                self.isRealtimePausedForMissingGlassesAudio = true
                self.voiceStatus = "Paused · waiting for glasses audio…"
                attempt += 1
            }
        }
    }

    private func receiveToolCall(callId: String, name: String, arguments: JSONValue) {
        // Realtime can repeat an event after a brief data-channel disruption.
        // Never execute the same consequential tool call twice.
        guard handledToolCallIDs.insert(callId).inserted else {
            NSLog("[CodexLensRealtime] ignored replayed tool call: %@", callId)
            return
        }
        handledToolCallOrder.append(callId)
        if handledToolCallOrder.count > 256 {
            let expired = handledToolCallOrder.removeFirst()
            handledToolCallIDs.remove(expired)
        }
        activeToolCallIDs.insert(callId)
        let drainPolicy = toolDrainPolicy(for: name)
        activeToolDrainPolicies[callId] = drainPolicy
        let toolGeneration = realtimeToolGeneration

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.activeToolCallIDs.remove(callId)
                self.activeToolTasks.removeValue(forKey: callId)
                self.activeToolDrainPolicies.removeValue(forKey: callId)
            }

            if self.isSessionRolloverPending {
                let output: JSONValue = .object([
                    "error": .string("The voice session is renewing. Nothing was executed; ask again after the assistant says it is live."),
                    "retrySafe": .bool(true),
                ])
                do {
                    guard self.realtimeToolGeneration == toolGeneration,
                          let transport = self.transport else { return }
                    try await transport.send(.toolResult(callId: callId, output: output))
                } catch {
                    NSLog("[CodexLensRealtime] renewal tool rejection could not be delivered: %@", error.localizedDescription)
                }
                return
            }

            await self.executeToolCall(
                callId: callId,
                name: name,
                arguments: arguments,
                toolGeneration: toolGeneration
            )
        }
        if drainPolicy == .abandonable {
            activeToolTasks[callId] = task
        }
    }

    private func toolDrainPolicy(for name: String) -> ToolDrainPolicy {
        switch name {
        case "capture_glasses_view", "inspect_mac_app", "inspect_codex_project", "research_web", "get_frontmost_mac_app", "get_current_time",
             "prepare_mac_computer_action", "prepare_text_message":
            return .abandonable
        default:
            // Direct computer use and confirmed send/execute calls can cross an
            // external boundary. Let them reach a terminal outcome, but never
            // replay them or attach their old call_id to a renewed session.
            return .consequential
        }
    }

    private func executeToolCall(
        callId: String,
        name: String,
        arguments: JSONValue,
        toolGeneration: UInt
    ) async {
        let output: JSONValue
        switch name {
        case "research_web":
            guard let gateway else {
                output = .object(["error": .string("The Mac gateway is not connected.")])
                break
            }
            guard
                let question = arguments.string("question")?.trimmingCharacters(in: .whitespacesAndNewlines),
                !question.isEmpty
            else {
                output = .object(["error": .string("A clear web research question is required.")])
                break
            }
            do {
                let result = try await gateway.researchWeb(question: question)
                output = .object([
                    "answer": .string(result.answer),
                    "sources": .array(result.sources.map { source in
                        .object([
                            "title": .string(source.title),
                            "url": .string(source.url),
                        ])
                    }),
                    "searched": .bool(result.searched),
                    "instruction": .string("Answer aloud from this researched result. Be concise. Name one or two source publications when useful; do not read URLs aloud."),
                ])
            } catch {
                output = .object(["error": .string(error.localizedDescription)])
            }
        case "get_frontmost_mac_app":
            guard let gateway else {
                output = .object(["error": .string("The Mac gateway is not connected.")])
                break
            }
            do {
                let result = try await gateway.frontmostComputerApp()
                var fields: [String: JSONValue] = [
                    "app": .string(result.app),
                    "readOnly": .bool(result.readOnly),
                    "instruction": .string("Answer with the exact active Mac app and window or document title when available. Do not claim to have inspected content inside the window."),
                ]
                if let windowTitle = result.windowTitle {
                    fields["windowTitle"] = .string(windowTitle)
                }
                output = .object(fields)
            } catch {
                output = .object(["error": .string(error.localizedDescription)])
            }
        case "focus_mac_app":
            guard let gateway else {
                output = .object(["error": .string("The Mac gateway is not connected.")])
                break
            }
            guard
                let app = arguments.string("app")?.trimmingCharacters(in: .whitespacesAndNewlines),
                !app.isEmpty
            else {
                output = .object(["error": .string("A Mac app name is required.")])
                break
            }
            pendingComputerConfirmation = nil
            pendingTextConfirmation = nil
            lastUserTranscript = nil
            lastUserTranscriptAt = nil
            do {
                let result = try await gateway.focusComputerApp(app: app)
                output = .object([
                    "app": .string(result.app),
                    "frontmost": .bool(result.frontmost),
                    "instruction": .string("Confirm briefly that the requested app is now open and frontmost."),
                ])
            } catch {
                output = .object(["error": .string(error.localizedDescription)])
            }
        case "close_frontmost_mac_window":
            guard let gateway else {
                output = .object(["error": .string("The Mac gateway is not connected.")])
                break
            }
            pendingComputerConfirmation = nil
            pendingTextConfirmation = nil
            lastUserTranscript = nil
            lastUserTranscriptAt = nil
            do {
                let result = try await gateway.closeFrontmostComputerWindow()
                var fields: [String: JSONValue] = [
                    "app": .string(result.app),
                    "closed": .bool(result.closed),
                    "needsUserDecision": .bool(result.needsUserDecision),
                    "instruction": .string(result.closed
                        ? "Confirm briefly that the requested window closed."
                        : "Tell the wearer the window did not close because the app needs a save or confirmation decision. Never choose for them."),
                ]
                if let windowTitle = result.windowTitle {
                    fields["windowTitle"] = .string(windowTitle)
                }
                output = .object(fields)
            } catch {
                output = .object(["error": .string(error.localizedDescription)])
            }
        case "set_frontmost_mac_window_state":
            guard let gateway else {
                output = .object(["error": .string("The Mac gateway is not connected.")])
                break
            }
            guard
                let action = arguments.string("action"),
                action == "minimize" || action == "restore"
            else {
                output = .object(["error": .string("The window action must be minimize or restore.")])
                break
            }
            pendingComputerConfirmation = nil
            pendingTextConfirmation = nil
            lastUserTranscript = nil
            lastUserTranscriptAt = nil
            do {
                let result = try await gateway.setFrontmostComputerWindowState(action: action)
                var fields: [String: JSONValue] = [
                    "app": .string(result.app),
                    "action": .string(result.action),
                    "applied": .bool(result.applied),
                    "minimized": .bool(result.minimized),
                    "instruction": .string("Confirm briefly that the requested window was \(action == "minimize" ? "minimized" : "restored")."),
                ]
                if let windowTitle = result.windowTitle {
                    fields["windowTitle"] = .string(windowTitle)
                }
                output = .object(fields)
            } catch {
                output = .object(["error": .string(error.localizedDescription)])
            }
        case "get_current_time":
            let now = Date()
            let timeZone = TimeZone.autoupdatingCurrent
            let formatter = DateFormatter()
            formatter.locale = Locale.autoupdatingCurrent
            formatter.timeZone = timeZone
            formatter.dateStyle = .full
            formatter.timeStyle = .medium
            output = .object([
                "localDateTime": .string(formatter.string(from: now)),
                "timeZoneIdentifier": .string(timeZone.identifier),
                "utcOffsetSeconds": .number(Double(timeZone.secondsFromGMT(for: now))),
                "iso8601": .string(ISO8601DateFormatter().string(from: now)),
                "instruction": .string("Answer the user's current date or time question directly and concisely using this phone-local value."),
            ])
        case "capture_glasses_view":
            guard isVoiceActive, let transport else {
                output = .object(["error": .string("Start a Codex Lens conversation first.")])
                break
            }
            guard !isVisualCaptureActive else {
                output = .object([
                    "status": .string("already_capturing"),
                    "instruction": .string("A glasses photo is already in progress. Wait for its result; do not request another capture."),
                ])
                break
            }
            beginExplicitCameraAttempt(reason: "Spoken glasses photo request")
            let modelRequest = arguments.string("request")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "Inspect what I am looking at."
            // The forced visual tool call is model-authored and can paraphrase
            // an ordinary "take a pic" request into words such as "screen" or
            // "read", accidentally selecting the slower multi-photo path. Use
            // the authoritative recent wearer transcript for capture planning.
            let request: String
            if let transcript = lastUserTranscript,
               let transcribedAt = lastUserTranscriptAt,
               Date().timeIntervalSince(transcribedAt) <= 30 {
                request = transcript
            } else {
                request = modelRequest
            }
            let requestedMode = arguments.string("mode")
            let capturePlan = VisualCapturePlanner.plan(
                request: request,
                requestedMode: requestedMode
            )
            let captureMode = capturePlan.mode.rawValue
            let frameCount = capturePlan.frameCount
            let captureProfile: VisualCaptureProfile = capturePlan.mode == .fast ? .fast : .reading
            let imageDetail = capturePlan.mode == .fast ? "low" : "high"
            isVisualCaptureActive = true
            defer {
                if realtimeToolGeneration == toolGeneration {
                    finishVisualCapture(
                        rearmReason: "Visual capture finished after background transition"
                    )
                }
            }
            do {
                let started = ContinuousClock.now
                let evidence = try await captureBackgroundSafeEvidence(
                    count: frameCount,
                    profile: captureProfile
                )
                NSLog(
                    "[CodexLensVision] capture ready mode=%@ captured=%d selected=%d score=%.2f bytes=%d elapsed=%@",
                    captureMode,
                    evidence.jpegData.count,
                    evidence.selectedFrameIndex + 1,
                    VisualFrameSelector.score(evidence.selectedQuality),
                    evidence.selectedJPEGData.count,
                    String(describing: started.duration(to: .now))
                )
                guard realtimeToolGeneration == toolGeneration,
                      !Task.isCancelled else {
                    NSLog("[CodexLensRealtime] abandoned stale visual tool result: %@", callId)
                    return
                }
                glassesPreview = UIImage(data: evidence.selectedJPEGData)
                try transport.sendVisualContexts(
                    jpegData: [evidence.selectedJPEGData],
                    source: "Meta glasses",
                    instruction: request,
                    detail: imageDetail,
                    createResponse: false
                )
                NSLog("[CodexLensVision] image queued mode=%@ elapsed=%@", captureMode, String(describing: started.duration(to: .now)))
                output = .object([
                    "captured": .bool(true),
                    "frameCount": .number(Double(evidence.jpegData.count)),
                    "selectedFrame": .number(Double(evidence.selectedFrameIndex + 1)),
                    "sentFrameCount": .number(1),
                    "request": .string(request),
                    "mode": .string(captureMode),
                    "recognizedText": .string(evidence.recognizedText),
                    "macScreenFallback": .string("If this image clearly shows a Mac app and its small text is still unreadable, identify the app and call inspect_mac_app instead of guessing or repeatedly retaking photos."),
                ])
            } catch {
                if realtimeToolGeneration == toolGeneration, !Task.isCancelled {
                    if Self.isMetaSessionPaused(error) {
                        markCameraRecoveryWaitingForSessionResume(
                            reason: error.localizedDescription
                        )
                    } else {
                        scheduleCameraRecovery(
                            reason: error.localizedDescription,
                            forceImmediate: true
                        )
                    }
                }
                output = .object(["error": .string(error.localizedDescription)])
            }
        case "inspect_mac_app":
            guard let gateway else {
                output = .object(["error": .string("The Mac gateway is not connected.")])
                break
            }
            guard
                let app = arguments.string("app")?.trimmingCharacters(in: .whitespacesAndNewlines),
                !app.isEmpty,
                let question = arguments.string("question")?.trimmingCharacters(in: .whitespacesAndNewlines),
                !question.isEmpty
            else {
                output = .object(["error": .string("The app and question are required.")])
                break
            }
            do {
                let inspection = try await gateway.inspectComputer(app: app, question: question)
                output = .object([
                    "app": .string(inspection.app),
                    "summary": .string(inspection.summary),
                    "readOnly": .bool(true),
                ])
            } catch {
                output = .object(["error": .string(error.localizedDescription)])
            }
        case "inspect_codex_project":
            guard let gateway else {
                output = .object(["error": .string("The Mac gateway is not connected.")])
                break
            }
            guard let project = selectedProject else {
                output = .object(["error": .string("No approved project is selected on the phone.")])
                break
            }
            guard
                let question = arguments.string("question")?.trimmingCharacters(in: .whitespacesAndNewlines),
                !question.isEmpty
            else {
                output = .object(["error": .string("A clear project question is required.")])
                break
            }
            do {
                let inspection = try await gateway.inspectCodexProject(
                    projectId: project.id,
                    question: question
                )
                output = .object([
                    "project": .string(inspection.projectName),
                    "summary": .string(inspection.summary),
                    "files": .array(inspection.files.map(JSONValue.string)),
                    "readOnly": .bool(inspection.readOnly),
                    "instruction": .string("Answer from the verified Codex inspection. Do not claim any files were changed."),
                ])
            } catch {
                output = .object(["error": .string(error.localizedDescription)])
            }
        case "use_mac_computer":
            guard let gateway else {
                output = .object(["error": .string("The Mac gateway is not connected.")])
                break
            }
            guard
                let instruction = arguments.string("instruction")?.trimmingCharacters(in: .whitespacesAndNewlines),
                !instruction.isEmpty
            else {
                output = .object(["error": .string("A clear Mac instruction is required.")])
                break
            }
            let requestedSurface = arguments.string("surface") ?? "auto"
            let surface = ["auto", "computer", "chrome"].contains(requestedSurface)
                ? requestedSurface
                : "auto"
            // A new direct command invalidates any older spoken confirmation so
            // an unrelated later phrase cannot authorize stale work.
            pendingComputerConfirmation = nil
            pendingTextConfirmation = nil
            lastUserTranscript = nil
            lastUserTranscriptAt = nil
            do {
                let result = try await gateway.useComputerAction(
                    instruction: instruction,
                    surface: surface
                )
                output = .object([
                    "completed": .bool(result.completed),
                    "confirmationRequired": .bool(result.confirmationRequired),
                    "summary": .string(result.summary),
                    "surface": .string(result.surface),
                    "nextStep": .string(result.confirmationRequired
                        ? "Explain the exact blocked consequential step. If it is allowed, prepare that exact action and ask the wearer to say ‘Run it’."
                        : "Report only the verified result."),
                ])
            } catch {
                output = .object([
                    "error": .string("The computer action outcome could not be confirmed: \(error.localizedDescription). Do not retry automatically."),
                ])
            }
        case "prepare_mac_computer_action":
            guard let gateway else {
                output = .object(["error": .string("The Mac gateway is not connected.")])
                break
            }
            guard
                let instruction = arguments.string("instruction")?.trimmingCharacters(in: .whitespacesAndNewlines),
                !instruction.isEmpty
            else {
                output = .object(["error": .string("A clear Mac instruction is required.")])
                break
            }
            let requestedSurface = arguments.string("surface") ?? "auto"
            let surface = ["auto", "computer", "chrome"].contains(requestedSurface)
                ? requestedSurface
                : "auto"
            do {
                let prepared = try await gateway.prepareComputerAction(
                    instruction: instruction,
                    surface: surface
                )
                guard realtimeToolGeneration == toolGeneration,
                      !Task.isCancelled else {
                    NSLog("[CodexLensRealtime] abandoned stale computer preview: %@", callId)
                    return
                }
                pendingComputerConfirmation = PendingComputerConfirmation(
                    prepared: prepared,
                    preparedAt: Date()
                )
                pendingTextConfirmation = nil
                lastUserTranscript = nil
                lastUserTranscriptAt = nil
                output = .object([
                    "prepared": .bool(true),
                    "confirmationId": .string(prepared.confirmationId),
                    "digest": .string(prepared.digest),
                    "instruction": .string(prepared.instruction),
                    "surface": .string(prepared.surface),
                    "requiresExplicitConfirmation": .bool(true),
                    "nextStep": .string("Read back the exact instruction, then ask the wearer to say ‘Run it’. Do not execute yet."),
                ])
            } catch {
                if realtimeToolGeneration == toolGeneration, !Task.isCancelled {
                    pendingComputerConfirmation = nil
                }
                output = .object(["error": .string(error.localizedDescription)])
            }
        case "execute_prepared_mac_action":
            guard let gateway else {
                output = .object(["error": .string("The Mac gateway is not connected.")])
                break
            }
            guard
                let confirmationId = arguments.string("confirmationId"),
                let digest = arguments.string("digest"),
                let pending = pendingComputerConfirmation,
                pending.prepared.confirmationId == confirmationId,
                pending.prepared.digest == digest
            else {
                output = .object(["error": .string("That computer action does not match the pending confirmation. Nothing ran.")])
                break
            }
            let now = Date()
            guard
                let transcript = lastUserTranscript,
                let transcriptAt = lastUserTranscriptAt,
                transcriptAt >= pending.preparedAt,
                now.timeIntervalSince(transcriptAt) <= 30,
                ExplicitComputerConfirmation.accepts(transcript)
            else {
                output = .object(["error": .string("Nothing ran. Read back the exact action and require the wearer to say ‘Run it’ in a later turn.")])
                break
            }
            pendingComputerConfirmation = nil
            lastUserTranscript = nil
            lastUserTranscriptAt = nil
            do {
                let result = try await gateway.executePreparedComputerAction(
                    confirmationId: confirmationId,
                    digest: digest
                )
                output = .object([
                    "completed": .bool(result.completed),
                    "confirmationRequired": .bool(result.confirmationRequired),
                    "summary": .string(result.summary),
                    "surface": .string(result.surface),
                ])
            } catch {
                output = .object([
                    "error": .string("The computer action outcome could not be confirmed: \(error.localizedDescription). Do not retry automatically."),
                ])
            }
        case "prepare_text_message":
            guard let gateway else {
                output = .object(["error": .string("The Mac gateway is not connected.")])
                break
            }
            guard
                let recipient = arguments.string("recipient")?.trimmingCharacters(in: .whitespacesAndNewlines),
                !recipient.isEmpty,
                let message = arguments.string("message")?.trimmingCharacters(in: .whitespacesAndNewlines),
                !message.isEmpty,
                let serviceTypeRaw = arguments.string("serviceType"),
                let serviceType = MessageServiceType(rawValue: serviceTypeRaw)
            else {
                output = .object(["error": .string("The recipient, exact message, and explicit service type (iMessage, SMS, or RCS) are required. Ask the wearer which service to use; never guess or fall back.")])
                break
            }
            do {
                let prepared = try await gateway.prepareTextMessage(
                    recipient: recipient,
                    message: message,
                    serviceType: serviceType
                )
                guard let expiresAt = prepared.expiresAtDate else {
                    throw GatewayError.transport("The gateway returned an invalid message-confirmation expiry.")
                }
                guard realtimeToolGeneration == toolGeneration,
                      !Task.isCancelled else {
                    NSLog("[CodexLensRealtime] abandoned stale text preview: %@", callId)
                    return
                }
                pendingTextConfirmation = PendingTextConfirmation(
                    prepared: prepared,
                    authorization: TextConfirmationAuthorization(
                        preparedAt: Date(),
                        expiresAt: expiresAt
                    )
                )
                pendingComputerConfirmation = nil
                lastUserTranscript = nil
                lastUserTranscriptAt = nil
                output = .object([
                    "prepared": .bool(true),
                    "confirmationId": .string(prepared.confirmationId),
                    "digest": .string(prepared.digest),
                    "recipientDisplay": .string(prepared.recipientDisplay),
                    "maskedDestination": .string(prepared.maskedDestination),
                    "message": .string(prepared.message),
                    "serviceType": .string(prepared.serviceType.rawValue),
                    "requiresExplicitConfirmation": .bool(true),
                    "instruction": .string("Read back the exact service, resolved recipient name, masked destination suffix, and exact message body. Then ask the user to say exactly ‘Confirm text’ in a later turn. Do not send yet."),
                ])
            } catch {
                if realtimeToolGeneration == toolGeneration, !Task.isCancelled {
                    pendingTextConfirmation = nil
                }
                output = .object(["error": .string(error.localizedDescription)])
            }
        case "send_prepared_text":
            guard let gateway else {
                output = .object(["error": .string("The Mac gateway is not connected.")])
                break
            }
            guard
                let confirmationId = arguments.string("confirmationId"),
                let digest = arguments.string("digest"),
                let pending = pendingTextConfirmation,
                pending.prepared.confirmationId == confirmationId,
                pending.prepared.digest == digest
            else {
                output = .object(["error": .string("That text preview does not match the pending confirmation. Nothing was sent.")])
                break
            }
            let now = Date()
            guard
                let transcript = lastUserTranscript,
                let transcriptAt = lastUserTranscriptAt,
                pending.authorization.decision(
                    transcript: transcript,
                    transcribedAt: transcriptAt,
                    now: now
                ) == .authorize
            else {
                output = .object(["error": .string("Nothing was sent. Read back the resolved recipient name, masked destination suffix, and exact message body, then require the user to say exactly ‘Confirm text’ in a later turn.")])
                break
            }
            // Consume the local confirmation before crossing the external
            // boundary. Retrying an uncertain send could duplicate a real text.
            pendingTextConfirmation = nil
            lastUserTranscript = nil
            lastUserTranscriptAt = nil
            do {
                let sent = try await gateway.sendPreparedText(
                    confirmationId: confirmationId,
                    digest: digest
                )
                output = .object([
                    "acceptedByMessages": .bool(sent.sent),
                    "deliveryConfirmed": .bool(false),
                    "recipientDisplay": .string(sent.recipientDisplay),
                    "serviceType": .string(sent.serviceType.rawValue),
                    "acceptedAt": .string(sent.sentAt),
                    "instruction": .string("Tell the user that Mac Messages accepted the text request. Do not claim carrier or recipient delivery."),
                ])
            } catch {
                output = .object([
                    "error": .string("Whether Mac Messages accepted the text request could not be confirmed: \(error.localizedDescription). Do not retry automatically."),
                ])
            }
        default:
            output = .object(["error": .string("Unsupported tool: \(name)")])
        }

        guard realtimeToolGeneration == toolGeneration,
              !Task.isCancelled,
              let transport else {
            NSLog("[CodexLensRealtime] abandoned stale tool result: %@", callId)
            return
        }
        do {
            try await transport.send(.toolResult(callId: callId, output: output))
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func beginExplicitCameraAttempt(reason: String) {
        let clearedFailureCount = cameraDeviceUnavailableFailureCount
        let wasSuspended = cameraRecoverySuspendedForDeviceUnavailable
        // The explicit capture becomes the sole camera operation owner. A
        // cancelled recovery that was already inside the SDK will observe the
        // new generation after its await; MetaGlassesCapture's lifecycle gate
        // keeps the actual SDK operations serialized until then.
        cameraRecoveryGeneration &+= 1
        cameraRecoveryEpoch &+= 1
        cameraRecoveryTask?.cancel()
        cameraRecoveryTask = nil
        cameraRecoveryDelayTask?.cancel()
        cameraRecoveryDelayTask = nil
        cameraRecoveryID = nil
        cameraDeviceUnavailableFailureCount = 0
        cameraRecoverySuspendedForDeviceUnavailable = false
        if clearedFailureCount > 0 || wasSuspended {
            NSLog(
                "[CodexLensCamera] persistent failure breaker reset by explicit capture (%@)",
                reason
            )
        }
    }

    private func noteCameraLifecycleTransition(
        reason: String,
        settleDelay: TimeInterval,
        clearsSessionPause: Bool
    ) {
        cameraDeviceUnavailableFailureCount = 0
        cameraRecoverySuspendedForDeviceUnavailable = false
        if clearsSessionPause {
            cameraRecoveryWaitingForSessionResume = false
        }
        if !glasses.isThermallyBlocked {
            cameraRecoveryWaitingForThermal = false
        }
        cameraRecoveryNotBefore = settleDelay > 0
            ? Date().addingTimeInterval(settleDelay)
            : nil
        cameraRecoveryEpoch &+= 1
        cameraRecoveryDelayTask?.cancel()
        NSLog(
            "[CodexLensCamera] recovery lifecycle transition (%@); settle=%.1fs epoch=%llu",
            reason,
            settleDelay,
            cameraRecoveryEpoch
        )
    }

    private func markCameraRecoveryWaitingForSessionResume(reason: String) {
        cameraRecoveryWaitingForSessionResume = true
        cameraRecoveryEpoch &+= 1
        cameraRecoveryDelayTask?.cancel()
        metaStatus = "Meta camera session paused · waiting for glasses to resume · voice remains available"
        NSLog("[CodexLensCamera] recovery waiting for Meta resume: %@", reason)
    }

    private func markCameraRecoveryWaitingForThermal(reason: String) {
        cameraRecoveryWaitingForThermal = true
        cameraRecoveryEpoch &+= 1
        cameraRecoveryDelayTask?.cancel()
        isGlassesConnected = true
        metaStatus = "Glasses too hot · camera paused · voice remains available"
        NSLog("[CodexLensCamera] recovery waiting for thermal state change: %@", reason)
    }

    private func handleGlassesSessionLost(_ reason: String) {
        isGlassesConnected = glasses.isThermallyBlocked || glasses.hasConnectedDevice
        isLiveGlassesVideo = false
        if !glasses.hasConnectedDevice {
            cameraObservedPhysicalDisconnect = true
        }
        guard isVoiceSessionArmed else {
            refreshMetaDiagnostics()
            return
        }
        if Self.isMetaSessionPausedReason(reason) {
            markCameraRecoveryWaitingForSessionResume(reason: reason)
            return
        }
        if glasses.isThermallyBlocked {
            markCameraRecoveryWaitingForThermal(reason: reason)
            return
        }
        metaStatus = "Glasses disconnected · camera will reconnect automatically"
        scheduleCameraRecovery(reason: reason)
        handleObservedAudioRouteChange(reason: "Meta glasses session lost")
    }

    private func handleGlassesDeviceAvailable() {
        let hasPhysicalReconnect = cameraObservedPhysicalDisconnect && glasses.hasConnectedDevice
        let resumedPausedSession = cameraRecoveryWaitingForSessionResume
        let recoveredFromThermal = cameraRecoveryWaitingForThermal && !glasses.isThermallyBlocked
        let isTrueLifecycleTransition = hasPhysicalReconnect
            || resumedPausedSession
            || recoveredFromThermal
        if isTrueLifecycleTransition {
            cameraObservedPhysicalDisconnect = false
            noteCameraLifecycleTransition(
                reason: hasPhysicalReconnect
                    ? "Meta device physically reconnected"
                    : (resumedPausedSession ? "Meta session resumed" : "Glasses cooled"),
                settleDelay: Self.cameraReconnectSettleDelay,
                clearsSessionPause: true
            )
        }
        refreshMetaDiagnostics()
        guard isVoiceSessionArmed else { return }
        if isRealtimePausedForMissingGlassesAudio || coordinator == nil {
            scheduleGlassesAudioRecovery(
                reason: "Meta glasses link connected",
                forceImmediate: true
            )
        } else {
            handleObservedAudioRouteChange(reason: "Meta glasses link connected")
        }
        if !glasses.isBackgroundCaptureReady {
            scheduleCameraRecovery(
                reason: "Meta camera link connected",
                forceImmediate: isTrueLifecycleTransition
            )
        }
    }

    private func scheduleGatewayRecovery(reason: String) {
        guard isVoiceSessionArmed,
              gateway == nil,
              coordinator == nil,
              gatewayRecoveryTask == nil
        else { return }

        let recoveryID = UUID()
        gatewayRecoveryID = recoveryID
        gatewayRecoveryTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let delays: [TimeInterval] = [1, 2, 4, 8, 15, 30]
            var attempt = 0
            NSLog("[CodexLensGateway] automatic startup recovery began: %@", reason)

            while self.isVoiceSessionArmed,
                  self.gateway == nil,
                  !Task.isCancelled,
                  self.gatewayRecoveryID == recoveryID {
                let delay = delays[min(attempt, delays.count - 1)]
                self.voiceStatus = "Gateway offline · retrying in \(Int(delay))s…"
                try? await Task.sleep(for: .seconds(delay))
                guard self.isVoiceSessionArmed,
                      !Task.isCancelled,
                      self.gatewayRecoveryID == recoveryID
                else { return }
                await self.connectGateway(reportErrors: false)
                attempt += 1
            }

            guard self.isVoiceSessionArmed,
                  !Task.isCancelled,
                  self.gatewayRecoveryID == recoveryID,
                  self.gateway != nil
            else { return }
            self.gatewayRecoveryTask = nil
            self.gatewayRecoveryID = nil
            NSLog("[CodexLensGateway] automatic startup recovery succeeded")
            await self.startRealtimeWhenGatewayIsReady()
        }
    }

    private func scheduleRealtimeRecovery(reason: String) {
        guard isVoiceSessionArmed,
              !isRealtimeConnecting,
              realtimeRecoveryTask == nil,
              let coordinator
        else { return }
        refreshAudioRoute()
        guard hasGlassesAudioInputAvailable else {
            scheduleRealtimePauseForMissingGlassesAudio(reason: reason)
            return
        }

        let recoveryID = UUID()
        realtimeRecoveryID = recoveryID
        realtimeRecoveryTask = Task { @MainActor [weak self] in
            guard let self else { return }
            var recoveryReason = reason
            while self.isVoiceSessionArmed, !Task.isCancelled {
                self.refreshAudioRoute()
                guard self.hasGlassesAudioInputAvailable else {
                    self.scheduleRealtimePauseForMissingGlassesAudio(
                        reason: "Glasses audio unavailable during Realtime recovery"
                    )
                    return
                }
                let state = await coordinator.connectionLost(reason: recoveryReason)
                guard self.isVoiceSessionArmed,
                      !Task.isCancelled,
                      self.realtimeRecoveryID == recoveryID
                else { return }

                switch state {
                case .connected:
                    self.realtimeRecoveryTask = nil
                    self.realtimeRecoveryID = nil
                    self.handleRealtimeConnected(reason: "Realtime recovered")
                    return
                case .failed(let failure):
                    self.isVoiceActive = false
                    self.voiceStatus = "Offline · retrying automatically…"
                    recoveryReason = failure
                    try? await Task.sleep(for: .seconds(30))
                    guard self.isVoiceSessionArmed, !Task.isCancelled else { return }
                    let restarted = await self.withBackgroundExecution(
                        named: "CodexLensRealtimeRecovery"
                    ) {
                        await coordinator.start()
                    }
                    if case .connected = restarted {
                        self.realtimeRecoveryTask = nil
                        self.realtimeRecoveryID = nil
                        self.handleRealtimeConnected(reason: "Realtime restarted")
                        return
                    }
                    if case .failed(let restartFailure) = restarted {
                        recoveryReason = restartFailure
                    }
                case .reconnecting(let attempt, _):
                    self.voiceStatus = "Reconnecting · attempt \(attempt)…"
                case .idle, .connecting, .disconnected:
                    recoveryReason = "Realtime session stopped before reconnecting."
                    try? await Task.sleep(for: .seconds(1))
                }
            }
        }
    }

    private func scheduleSessionRollover(expiresAt: Date? = nil) {
        guard isVoiceSessionArmed,
              coordinator != nil,
              !isSessionRolloverPending
        else { return }
        let fallbackTarget = Date().addingTimeInterval(55 * 60)
        let serverTarget = expiresAt?.addingTimeInterval(-120)
        let target = min(fallbackTarget, serverTarget ?? fallbackTarget)
        let productionDelay = max(5, target.timeIntervalSinceNow)
        let delay = debugRolloverDelay ?? productionDelay
        let proposedDeadline = Date().addingTimeInterval(delay)
        // Route and session callbacks can repeat while one generation is live.
        // Keep the earliest deadline instead of continually cancelling and
        // pushing renewal into the future.
        if sessionRolloverTask != nil,
           let existingDeadline = sessionRolloverDeadline,
           existingDeadline <= proposedDeadline {
            return
        }
        sessionRolloverTask?.cancel()
        sessionRolloverDeadline = proposedDeadline
        if debugRolloverDelay != nil {
            NSLog("[CodexLensRealtime] DEBUG rollover scheduled in %.0f seconds", delay)
        }

        sessionRolloverTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, self.isVoiceSessionArmed, !Task.isCancelled else { return }
            var ownsRolloverSlot = true
            defer {
                if ownsRolloverSlot {
                    self.isSessionRolloverPending = false
                    self.sessionRolloverTask = nil
                    self.sessionRolloverDeadline = nil
                }
            }
            self.isSessionRolloverPending = true
            self.voiceStatus = "Renewal pending · finishing current request…"

            let now = Date()
            let maximumDrainDeadline = now.addingTimeInterval(Self.maximumRolloverDrain)
            let expiryDeadline = self.realtimeExpiresAt?.addingTimeInterval(
                -Self.rolloverSafetyMargin
            ) ?? maximumDrainDeadline
            let drainDeadline = min(maximumDrainDeadline, expiryDeadline)

            // A tool result is bound to the old Realtime call_id. Never tear
            // down that session until the result has crossed the data channel.
            // New tool calls are rejected without execution while this drains.
            while (self.isVisualCaptureActive || !self.activeToolCallIDs.isEmpty),
                  self.isVoiceSessionArmed,
                  !Task.isCancelled,
                  Date() < drainDeadline {
                try? await Task.sleep(for: .milliseconds(250))
            }

            let unresolvedCallIDs = self.activeToolCallIDs
            if self.isVisualCaptureActive || !unresolvedCallIDs.isEmpty {
                for callID in unresolvedCallIDs
                    where self.activeToolDrainPolicies[callID] == .abandonable {
                    self.activeToolTasks[callID]?.cancel()
                }
                // Tombstones remain in handledToolCallIDs. Removing only the
                // active marker prevents one hung operation from blocking every
                // later credential renewal. Generation gating below suppresses
                // any late old-session result, including consequential outcomes.
                self.activeToolCallIDs.subtract(unresolvedCallIDs)
                self.isVisualCaptureActive = false
                NSLog(
                    "[CodexLensRealtime] rollover drain deadline reached; abandoned %d old tool result(s)",
                    unresolvedCallIDs.count
                )
            }

            // Give the final spoken answer a bounded chance to finish after
            // its tool result. Unlike a tool call, cutting a stuck response
            // cannot duplicate an external action.
            // Transport events cross from its serial queue through a MainActor
            // task. Require a short stable-zero window so a queued reservation
            // cannot arrive just after we decide the session is idle.
            var responseIdleSince: Date?
            while self.isVoiceSessionArmed,
                  !Task.isCancelled,
                  Date() < drainDeadline {
                if self.activeRealtimeResponseCount > 0 {
                    responseIdleSince = nil
                } else if let idleSince = responseIdleSince,
                          Date().timeIntervalSince(idleSince) >= Self.responseIdleGrace {
                    break
                } else if responseIdleSince == nil {
                    responseIdleSince = Date()
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
            guard self.isVoiceSessionArmed,
                  !Task.isCancelled,
                  let coordinator = self.coordinator
            else {
                if self.isVoiceSessionArmed,
                   !self.isRealtimeConnecting,
                   self.realtimeRecoveryTask == nil,
                   self.coordinator != nil {
                    self.scheduleRealtimeRecovery(reason: "Realtime renewal drain was interrupted.")
                }
                return
            }

            self.isVoiceActive = false
            self.isRealtimeConnecting = true
            self.isRealtimeSessionConfigured = false
            self.realtimeToolGeneration &+= 1
            self.invalidatePendingConfirmations(reason: "Realtime session rollover")
            self.pendingRealtimeRecoveryReason = nil
            self.realtimeExpiresAt = nil
            self.voiceStatus = "Renewing 60-minute voice session…"
            let state = await self.withBackgroundExecution(
                named: "CodexLensRealtimeRollover"
            ) {
                await coordinator.start()
            }
            self.isRealtimeConnecting = false
            let renewalWasCancelled = Task.isCancelled
            let pendingRecoveryReason = self.pendingRealtimeRecoveryReason
            self.pendingRealtimeRecoveryReason = nil
            self.isSessionRolloverPending = false
            self.sessionRolloverTask = nil
            self.sessionRolloverDeadline = nil
            ownsRolloverSlot = false
            guard self.isVoiceSessionArmed,
                  !renewalWasCancelled,
                  self.coordinator === coordinator
            else {
                if self.isVoiceSessionArmed,
                   self.realtimeRecoveryTask == nil,
                   self.coordinator != nil {
                    self.scheduleRealtimeRecovery(reason: "Realtime renewal was interrupted.")
                }
                return
            }

            if let pendingRecoveryReason {
                self.isVoiceActive = false
                self.voiceStatus = "Reconnecting automatically…"
                self.scheduleRealtimeRecovery(reason: pendingRecoveryReason)
                return
            }

            switch state {
            case .connected:
                self.handleRealtimeConnected(reason: "Realtime session renewed")
            case .failed(let reason):
                self.isRealtimeSessionConfigured = false
                self.scheduleRealtimeRecovery(reason: reason)
            default:
                self.scheduleRealtimeRecovery(reason: "Realtime renewal did not finish.")
            }
        }
    }

    private func scheduleCameraRecovery(reason: String, forceImmediate: Bool = false) {
        guard isVoiceSessionArmed else { return }
        guard Self.keepsCameraPrearmed else {
            cameraRecoveryDelayTask?.cancel()
            cameraRecoveryDelayTask = nil
            cameraRecoveryTask?.cancel()
            cameraRecoveryTask = nil
            cameraRecoveryID = nil
            pendingBackgroundCameraPreparation = false
            refreshMetaDiagnostics()
            NSLog("[CodexLensCamera] on-demand mode; not pre-arming camera (%@)", reason)
            return
        }
        guard !cameraRecoveryWaitingForSessionResume else {
            metaStatus = "Meta camera session paused · waiting for glasses to resume · voice remains available"
            return
        }

        if forceImmediate {
            // Wake the single recovery loop and reset its backoff, but preserve
            // any physical-reconnect not-before deadline. The Meta capture
            // layer serializes the actual SDK lifecycle operation.
            cameraRecoveryEpoch &+= 1
            cameraRecoveryDelayTask?.cancel()
            cameraRecoveryDelayTask = nil
        }
        guard cameraRecoveryTask == nil else { return }

        let recoveryID = UUID()
        let recoveryGeneration = cameraRecoveryGeneration
        cameraRecoveryID = recoveryID
        cameraRecoveryTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.cameraRecoveryID == recoveryID {
                    self.cameraRecoveryDelayTask?.cancel()
                    self.cameraRecoveryDelayTask = nil
                    self.cameraRecoveryTask = nil
                    self.cameraRecoveryID = nil
                }
            }
            // A connected Bluetooth record is not proof that the on-glasses DAT
            // service is ready. Give it a short settle period after reconnect,
            // then use a bounded backoff instead of hammering DeviceSession.
            let delays: [TimeInterval] = [2, 4, 8, 15, 30, 60]
            var attempt = 0
            var observedEpoch = self.cameraRecoveryEpoch
            while self.isVoiceSessionArmed,
                  !Task.isCancelled,
                  self.cameraRecoveryGeneration == recoveryGeneration,
                  self.cameraRecoveryID == recoveryID {
                if self.cameraRecoveryWaitingForSessionResume {
                    self.metaStatus = "Meta camera session paused · waiting for glasses to resume · voice remains available"
                    return
                }
                if self.glasses.isThermallyBlocked {
                    self.markCameraRecoveryWaitingForThermal(
                        reason: "Automatic camera recovery reached thermal protection"
                    )
                    return
                }

                if observedEpoch != self.cameraRecoveryEpoch {
                    observedEpoch = self.cameraRecoveryEpoch
                    attempt = 0
                }
                let attemptEpoch = observedEpoch
                // DWA readiness can recover without a Bluetooth/device event.
                // Once the normal breaker trips, retain one recovery owner and
                // make only one readiness probe per minute. This avoids a hot
                // retry loop without stranding a locked-phone conversation.
                let delay = self.cameraRecoverySuspendedForDeviceUnavailable
                    ? 60
                    : delays[min(attempt, delays.count - 1)]
                let baseDeadline = Date().addingTimeInterval(delay)
                let settleDeadline = self.cameraRecoveryNotBefore ?? .distantPast
                let retryDeadline = max(baseDeadline, settleDeadline)
                let sleepDuration = max(0, retryDeadline.timeIntervalSinceNow)
                if sleepDuration > 0 {
                    let delayTask = Task<Void, Never> {
                        try? await Task.sleep(for: .seconds(sleepDuration))
                    }
                    self.cameraRecoveryDelayTask = delayTask
                    await delayTask.value
                    if self.cameraRecoveryID == recoveryID {
                        self.cameraRecoveryDelayTask = nil
                    }
                }
                guard self.isVoiceSessionArmed,
                      !Task.isCancelled,
                      self.cameraRecoveryGeneration == recoveryGeneration,
                      self.cameraRecoveryID == recoveryID
                else { return }
                if self.cameraRecoveryEpoch != attemptEpoch {
                    observedEpoch = self.cameraRecoveryEpoch
                    attempt = 0
                    continue
                }
                guard !self.cameraRecoveryWaitingForSessionResume,
                      !self.glasses.isThermallyBlocked else { return }

                do {
                    try await self.glasses.prepareBackgroundCapture()
                    guard self.isVoiceSessionArmed,
                          !Task.isCancelled,
                          self.cameraRecoveryGeneration == recoveryGeneration,
                          self.cameraRecoveryID == recoveryID
                    else { return }
                    if self.cameraRecoveryEpoch != attemptEpoch {
                        observedEpoch = self.cameraRecoveryEpoch
                        attempt = 0
                        continue
                    }
                    guard !self.cameraRecoveryWaitingForSessionResume else { return }
                    self.cameraDeviceUnavailableFailureCount = 0
                    self.cameraRecoverySuspendedForDeviceUnavailable = false
                    self.cameraRecoveryWaitingForThermal = false
                    self.cameraRecoveryNotBefore = nil
                    self.pendingBackgroundCameraPreparation = false
                    self.isGlassesConnected = true
                    self.metaStatus = "Background camera armed · \(self.glasses.deviceDiagnostics)"
                    NSLog("[CodexLensCamera] automatic recovery succeeded after %d attempt(s)", attempt + 1)
                    return
                } catch {
                    guard self.isVoiceSessionArmed,
                          !Task.isCancelled,
                          self.cameraRecoveryGeneration == recoveryGeneration,
                          self.cameraRecoveryID == recoveryID
                    else { return }
                    if self.cameraRecoveryEpoch != attemptEpoch {
                        observedEpoch = self.cameraRecoveryEpoch
                        attempt = 0
                        continue
                    }
                    if Self.isMetaSessionPaused(error) {
                        self.markCameraRecoveryWaitingForSessionResume(
                            reason: error.localizedDescription
                        )
                        return
                    }
                    attempt += 1
                    if Self.isPersistentMetaDeviceUnavailable(error) {
                        self.cameraDeviceUnavailableFailureCount += 1
                    }
                    if self.glasses.isThermallyBlocked {
                        self.markCameraRecoveryWaitingForThermal(reason: error.localizedDescription)
                    } else if self.glasses.hasConnectedDevice {
                        self.isGlassesConnected = true
                        self.metaStatus = "Camera unavailable in Meta SDK · voice remains available"
                    } else {
                        self.isGlassesConnected = false
                        self.metaStatus = "Camera reconnecting automatically · attempt \(attempt)"
                    }
                    NSLog(
                        "[CodexLensCamera] automatic recovery attempt %d failed (%@): %@",
                        attempt,
                        reason,
                        error.localizedDescription
                    )
                    if self.glasses.isThermallyBlocked {
                        return
                    }
                    if self.cameraDeviceUnavailableFailureCount >= Self.persistentDeviceUnavailableLimit {
                        // Meta SDK 0.9 can report a connected, compatible device
                        // while rejecting every session with "Device unavailable"
                        // across independently restarted recovery tasks. Keep the
                        // breaker latched until a real lifecycle transition or an
                        // explicit user capture proves a new attempt is intended.
                        self.cameraRecoverySuspendedForDeviceUnavailable = true
                        self.metaStatus = "Meta camera unavailable · checking once per minute · voice remains available"
                        NSLog(
                            "[CodexLensCamera] normal recovery suspended after %d consecutive Device unavailable failures; probing once per minute",
                            self.cameraDeviceUnavailableFailureCount
                        )
                    }
                }
            }
        }
    }

    private func finishVisualCapture(rearmReason: String) {
        isVisualCaptureActive = false
        guard pendingBackgroundCameraPreparation else { return }
        pendingBackgroundCameraPreparation = false
        scheduleCameraRecovery(reason: rearmReason, forceImmediate: true)
    }

    private func invalidatePendingConfirmations(reason: String) {
        let hadPendingConfirmation = pendingTextConfirmation != nil
            || pendingComputerConfirmation != nil
        pendingTextConfirmation = nil
        pendingComputerConfirmation = nil
        lastUserTranscript = nil
        lastUserTranscriptAt = nil
        if hadPendingConfirmation {
            NSLog("[CodexLensConfirmation] invalidated pending action: %@", reason)
        }
    }

    private func captureBackgroundSafeEvidence(
        count: Int,
        profile: VisualCaptureProfile
    ) async throws -> CapturedVisualEvidence {
        var backgroundTask = UIBackgroundTaskIdentifier.invalid
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "CodexLensVisualEvidence") {
            if backgroundTask != .invalid {
                UIApplication.shared.endBackgroundTask(backgroundTask)
                backgroundTask = .invalid
            }
        }
        defer {
            if backgroundTask != .invalid {
                UIApplication.shared.endBackgroundTask(backgroundTask)
            }
        }
        return try await glasses.captureVisualEvidence(count: count, profile: profile)
    }

    /// Keeps iOS from suspending the process during the short gap where a
    /// replacement WebRTC peer is being negotiated and the old audio track is
    /// already gone. The persistent audio mode remains the long-running
    /// background mechanism; this assertion only bridges startup/recovery.
    private func withBackgroundExecution<T>(
        named name: String,
        operation: () async -> T
    ) async -> T {
        var backgroundTask = UIBackgroundTaskIdentifier.invalid
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: name) {
            NSLog("[CodexLensLifecycle] background bridge expired: %@", name)
            if backgroundTask != .invalid {
                UIApplication.shared.endBackgroundTask(backgroundTask)
                backgroundTask = .invalid
            }
        }
        defer {
            if backgroundTask != .invalid {
                UIApplication.shared.endBackgroundTask(backgroundTask)
            }
        }
        return await operation()
    }
}

enum KeychainStore {
    private static let service = "com.richardholguin.CodexLensApp"
    private static let account = "gateway-token"

    static func saveGatewayToken(_ token: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        var item = query
        item[kSecValueData as String] = Data(token.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
    }

    static func loadGatewayToken() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
