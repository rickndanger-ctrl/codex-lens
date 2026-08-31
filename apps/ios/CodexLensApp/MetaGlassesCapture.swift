import CodexLensKit
import Foundation
import MWDATCamera
import MWDATCore
import UIKit
import Vision

enum GlassesCaptureError: LocalizedError {
    case sdkNotConfigured(String)
    case registrationRequired
    case cameraPermissionDenied
    case foregroundPermissionRequired
    case noEligibleDevice(String)
    case thermalProtection(String)
    case sessionPaused
    case sessionTimedOut
    case streamUnavailable
    case streamTimedOut
    case photoRequestRejected
    case photoTimedOut
    case invalidImage

    var errorDescription: String? {
        switch self {
        case .sdkNotConfigured(let detail): "Meta Wearables SDK configuration failed: \(detail)"
        case .registrationRequired: "Register Codex Lens with the Meta AI app first."
        case .cameraPermissionDenied: "Camera access was denied in the Meta AI app."
        case .foregroundPermissionRequired: "Open Codex Lens once to approve glasses camera access before using it with the phone locked."
        case .noEligibleDevice(let detail): "Meta registration succeeded, but its SDK found no eligible glasses. \(detail)"
        case .thermalProtection(let detail): "The glasses camera is paused because the glasses are too hot. \(detail)"
        case .sessionPaused: "The glasses session is temporarily paused. Codex Lens will wait for it to resume."
        case .sessionTimedOut: "The glasses did not finish connecting."
        case .streamUnavailable: "The glasses camera stream is unavailable."
        case .streamTimedOut: "The glasses camera did not become ready."
        case .photoRequestRejected: "The glasses rejected the photo request."
        case .photoTimedOut: "The glasses camera did not return an image in time."
        case .invalidImage: "The captured image could not be decoded safely."
        }
    }
}

enum VisualCaptureProfile: Equatable {
    case fast
    case reading

    var maxEdge: CGFloat {
        switch self {
        case .fast: 768
        case .reading: 1_600
        }
    }

    var compressionQuality: CGFloat {
        switch self {
        case .fast: 0.62
        case .reading: 0.76
        }
    }

    var maximumBytes: Int {
        switch self {
        case .fast: 75_000
        // Base64 adds about 33%. Keeping the JPEG below 150 KB preserves
        // readable text while leaving the complete Realtime JSON event below
        // WebRTC's practical single-message ceiling.
        case .reading: 150_000
        }
    }
}

struct CapturedVisualEvidence {
    let jpegData: [Data]
    let selectedFrameIndex: Int
    let recognizedText: String
    let selectedQuality: VisualFrameQuality

    var selectedJPEGData: Data { jpegData[selectedFrameIndex] }
}

private struct TextRecognitionEvidence {
    let text: String
    let characterCount: Int
    let lineCount: Int
    let averageConfidence: Double

    static let empty = TextRecognitionEvidence(
        text: "",
        characterCount: 0,
        lineCount: 0,
        averageConfidence: 0
    )
}

private struct CapturedFrameCandidate {
    let jpegData: Data
    let recognizedText: String
    let quality: VisualFrameQuality
}

/// Publisher callbacks can arrive on different SDK queues. Record the error
/// synchronously before either callback hops to the MainActor so a terminal
/// state cannot erase the more useful SDK failure that preceded it.
private final class SessionErrorLatch: @unchecked Sendable {
    private let lock = NSLock()
    private var storedError: DeviceSessionError?

    func record(_ error: DeviceSessionError) {
        lock.lock()
        storedError = error
        lock.unlock()
    }

    var error: DeviceSessionError? {
        lock.lock()
        defer { lock.unlock() }
        return storedError
    }
}

/// Owns the Meta Wearables Device Access Toolkit camera lifecycle.
/// Audio is intentionally not handled here: WebRTC uses the system Bluetooth
/// HFP route selected by AVAudioSession for microphone and speaker audio.
@MainActor
final class MetaGlassesCapture {
    private enum CameraMode {
        case none
        case transient
        case background
        case live
    }

    private enum SessionTeardownIntent {
        case intentional(clearLastError: Bool)
        case loss(reason: String)
    }

    static let shared = MetaGlassesCapture()

    /// Raised when an armed Meta device session ends unexpectedly. The app
    /// uses this to keep retrying until charged/reconnected glasses return.
    var onSessionLost: (@MainActor @Sendable (String) -> Void)?

    /// Raised as soon as Meta's camera link becomes available. A polling-only
    /// recovery loop can otherwise leave the user waiting up to 30 seconds
    /// after opening charged glasses even though the SDK is already ready.
    var onDeviceAvailable: (@MainActor @Sendable () -> Void)?

    private var configurationError: Error?
    private let wearables: any WearablesInterface
    private let deviceSelector: AutoDeviceSelector
    private var session: DeviceSession?
    private var sessionStateToken: (any AnyListenerToken)?
    private var sessionErrorToken: (any AnyListenerToken)?
    private var devicesListenerToken: (any AnyListenerToken)?
    private var linkStateTokens: [DeviceIdentifier: any AnyListenerToken] = [:]
    private var deviceStateTasks: [DeviceIdentifier: Task<Void, Never>] = [:]
    private var deviceThermalLevels: [DeviceIdentifier: ThermalLevel] = [:]
    private var cameraStateToken: (any AnyListenerToken)?
    private var streamStateToken: (any AnyListenerToken)?
    private var streamErrorToken: (any AnyListenerToken)?
    private var videoFrameToken: (any AnyListenerToken)?
    private var lastSessionError: DeviceSessionError?
    private var sessionErrorLatch: SessionErrorLatch?
    private var sessionGeneration: UInt = 0
    private var sessionTeardownTask: Task<Bool, Never>?
    private var sessionTeardownGeneration: UInt?
    private var sessionTeardownNotifiesLoss = false
    private var sessionTeardownReason: String?
    private var sessionTeardownClearsError = false
    private var sessionTeardownRequestsStop = false
    private var isBackgroundCaptureArmed = false
    private var isPhotoCaptureInFlight = false
    private var camera: MWDATCamera.Camera?
    private var cameraMode: CameraMode = .none
    private var cameraTeardownTask: Task<Bool, Never>?
    private weak var cameraTeardownTarget: MWDATCamera.Camera?
    private var cameraTeardownNotifiesLoss = false
    private var cameraTeardownReason: String?
    private var cameraTeardownRequestsStop = false
    private var lifecycleOperationRunning = false
    private var lifecycleOperationWaiters: [CheckedContinuation<Void, Never>] = []

    private(set) var isCameraActive = false

    var isBackgroundCaptureReady: Bool {
        isBackgroundCaptureArmed && camera?.stream.state == .streaming
    }

    /// Meta stops camera capture at critical heat. Exposing the state lets the
    /// app suspend its reconnect loop instead of repeatedly asking hot glasses
    /// to restart, which only prolongs the shutdown.
    var isThermallyBlocked: Bool {
        guard let identifier = preferredDeviceIdentifier(requireConnected: true),
              let level = deviceThermalLevels[identifier] else { return false }
        switch level {
        case .critical, .emergency, .shutdown:
            return true
        case .unknown, .none, .light, .moderate, .severe:
            return false
        }
    }

    var thermalStatus: String {
        guard let identifier = preferredDeviceIdentifier(requireConnected: true),
              let level = deviceThermalLevels[identifier] else {
            return "Waiting for the glasses to report a safe temperature."
        }
        return "Current thermal level: \(String(describing: level)). Capture resumes automatically below critical."
    }

    private func trace(_ message: String) {
        NSLog("[CodexLensCamera] %@", message)
    }

    private func acquireLifecycleOperation() async {
        if !lifecycleOperationRunning {
            lifecycleOperationRunning = true
            return
        }
        await withCheckedContinuation { continuation in
            lifecycleOperationWaiters.append(continuation)
        }
    }

    private func releaseLifecycleOperation() {
        guard !lifecycleOperationWaiters.isEmpty else {
            lifecycleOperationRunning = false
            return
        }
        lifecycleOperationWaiters.removeFirst().resume()
    }

    private func withLifecycleOperation<T>(
        _ operation: () async throws -> T
    ) async rethrows -> T {
        await acquireLifecycleOperation()
        defer { releaseLifecycleOperation() }
        return try await operation()
    }

    private init() {
        do {
            try Wearables.configure()
        } catch WearablesError.alreadyConfigured {
            // Another app surface configured the process already; reuse it.
        } catch {
            configurationError = error
        }
        let sharedWearables = Wearables.shared
        wearables = sharedWearables
        // AutoDeviceSelector maintains its own live selection state. Keep one
        // instance alive from app startup, matching Meta's reference app, so a
        // session is never created with a brand-new selector that has not yet
        // observed the already-connected glasses.
        deviceSelector = AutoDeviceSelector(wearables: sharedWearables)
        observeDeviceLinks(sharedWearables.devices)
        devicesListenerToken = sharedWearables.addDevicesListener { [weak self] identifiers in
            Task { @MainActor [weak self] in
                self?.observeDeviceLinks(identifiers)
            }
        }
    }

    var registrationStatus: String {
        wearables.registrationState.description
    }

    var availableDeviceCount: Int {
        wearables.devices.count
    }

    var hasConnectedDevice: Bool {
        preferredDeviceIdentifier(requireConnected: true) != nil
    }

    var deviceDiagnostics: String {
        guard !wearables.devices.isEmpty else { return "SDK device list is empty." }
        return wearables.devices.map { identifier in
            guard let device = wearables.deviceForIdentifier(identifier) else {
                return "Unknown device: missing SDK record"
            }
            let link: String
            switch device.linkState {
            case .connected: link = "connected"
            case .connecting: link = "connecting"
            case .disconnected: link = "disconnected"
            }
            return "\(device.nameOrId()): \(device.deviceType().rawValue), \(link), \(device.compatibility().displayString)"
        }.joined(separator: "; ")
    }

    func startRegistration() async throws {
        try requireConfiguration()
        if wearables.registrationState == .registered { return }
        try await wearables.startRegistration()
    }

    func handleCallback(_ url: URL) async throws {
        try requireConfiguration()
        _ = try await wearables.handleUrl(url)
    }

    func openGlassesAppUpdate() async throws {
        try requireConfiguration()
        try await wearables.openDATGlassesAppUpdate()
    }

    func connect() async throws {
        try await withLifecycleOperation {
            try await connectWithoutLifecycleGate()
        }
    }

    private func connectWithoutLifecycleGate() async throws {
        // A caller can be cancelled while it is queued behind another camera
        // lifecycle operation. Check before doing any SDK work so a cancelled
        // recovery cannot create a session after voice/background use stopped.
        try Task.checkCancellation()
        trace("connect: registration=\(wearables.registrationState.description), devices=\(deviceDiagnostics)")
        try requireConfiguration()
        guard wearables.registrationState == .registered else {
            throw GlassesCaptureError.registrationRequired
        }
        guard !isThermallyBlocked else {
            throw GlassesCaptureError.thermalProtection(thermalStatus)
        }

        // Never reopen Meta AI after permission has already been granted. That
        // app switch breaks locked-phone/background captures. Only perform the
        // interactive permission round-trip while Codex Lens is foregrounded.
        var permission = try await wearables.checkPermissionStatus(.camera)
        try Task.checkCancellation()
        if permission != .granted {
            guard UIApplication.shared.applicationState == .active else {
                throw GlassesCaptureError.foregroundPermissionRequired
            }
            permission = try await wearables.requestPermission(.camera)
            try Task.checkCancellation()
        }
        trace("permission: \(String(describing: permission))")
        guard permission == .granted else {
            throw GlassesCaptureError.cameraPermissionDenied
        }

        if try await reuseExistingSessionIfPossible() { return }
        try Task.checkCancellation()
        // Device discovery is asynchronous after Meta AI hands control back.
        // Wait for the SDK's live device stream instead of treating its first
        // (often empty) snapshot as final.
        try await waitForEligibleDevice(timeout: .seconds(15))
        try Task.checkCancellation()
        trace("selector active device found: \(deviceDiagnostics)")
        guard deviceSelector.activeDevice != nil else {
            throw GlassesCaptureError.noEligibleDevice(deviceDiagnostics)
        }

        let newSession: DeviceSession
        do {
            newSession = try wearables.createSession(
                deviceSelector: deviceSelector
            )
        } catch DeviceSessionError.noEligibleDevice {
            throw GlassesCaptureError.noEligibleDevice(deviceDiagnostics)
        } catch {
            throw error
        }
        session = newSession
        lastSessionError = nil
        sessionGeneration &+= 1
        let generation = sessionGeneration
        observeSessionLifecycle(newSession, generation: generation)
        trace("session created; state=\(String(describing: newSession.state))")
        do {
            try newSession.start()
            trace("session start requested")
        } catch DeviceSessionError.noEligibleDevice {
            await stopAndDropSession(
                newSession,
                generation: generation,
                intent: .intentional(clearLastError: true)
            )
            throw GlassesCaptureError.noEligibleDevice(deviceDiagnostics)
        } catch {
            await stopAndDropSession(
                newSession,
                generation: generation,
                intent: .intentional(clearLastError: true)
            )
            throw error
        }

        let resolvedState: DeviceSessionState
        do {
            resolvedState = try await waitForSessionResolution(newSession, generation: generation)
        } catch {
            if newSession.state != .paused {
                await stopAndDropSession(
                    newSession,
                    generation: generation,
                    intent: .intentional(clearLastError: false)
                )
            }
            throw error
        }
        guard sessionGeneration == generation, session === newSession else {
            if let lastSessionError { throw lastSessionError }
            throw GlassesCaptureError.streamUnavailable
        }
        switch resolvedState {
        case .started:
            trace("session started")
            return
        case .paused:
            // Meta owns pause/resume. Calling start() on a paused session is
            // invalid and can strand the SDK in sessionAlreadyExists.
            trace("session remained paused")
            throw GlassesCaptureError.sessionPaused
        case .stopped:
            let failure = lastSessionError
            await stopAndDropSession(
                newSession,
                generation: generation,
                intent: .intentional(clearLastError: false)
            )
            if let failure {
                trace("session stopped with SDK error: \(failure.localizedDescription)")
                throw failure
            }
            trace("session stopped before becoming ready without an SDK error")
            throw GlassesCaptureError.streamUnavailable
        case .idle, .starting, .stopping:
            await stopAndDropSession(
                newSession,
                generation: generation,
                intent: .intentional(clearLastError: true)
            )
            throw GlassesCaptureError.sessionTimedOut
        }
    }

    func disconnect() async {
        await withLifecycleOperation {
            await disconnectWithoutLifecycleGate()
        }
    }

    private func disconnectWithoutLifecycleGate() async {
        if let session {
            await stopAndDropSession(
                session,
                generation: sessionGeneration,
                intent: .intentional(clearLastError: true)
            )
        } else {
            sessionGeneration &+= 1
            _ = await stopCameraWithoutLifecycleGate()
            lastSessionError = nil
        }
    }

    private func reuseExistingSessionIfPossible() async throws -> Bool {
        guard let existingSession = session else { return false }
        let generation = sessionGeneration

        switch existingSession.state {
        case .started:
            guard wearables.deviceForIdentifier(existingSession.deviceId)?.linkState == .connected else {
                await stopAndDropSession(
                    existingSession,
                    generation: generation,
                    intent: .intentional(clearLastError: true)
                )
                return false
            }
            return true
        case .paused:
            // A paused session is live and still owned by Meta. It resumes via
            // its state publisher; start() must never be called a second time.
            throw GlassesCaptureError.sessionPaused
        case .idle, .stopped:
            await stopAndDropSession(
                existingSession,
                generation: generation,
                intent: .intentional(clearLastError: true)
            )
            return false
        case .starting, .stopping:
            let resolvedState: DeviceSessionState
            do {
                resolvedState = try await waitForSessionResolution(
                    existingSession,
                    generation: generation
                )
            } catch {
                await stopAndDropSession(
                    existingSession,
                    generation: generation,
                    intent: .intentional(clearLastError: false)
                )
                throw error
            }
            guard sessionGeneration == generation, session === existingSession else {
                if let lastSessionError { throw lastSessionError }
                return false
            }
            switch resolvedState {
            case .started:
                return true
            case .paused:
                throw GlassesCaptureError.sessionPaused
            case .stopped:
                let failure = lastSessionError
                await stopAndDropSession(
                    existingSession,
                    generation: generation,
                    intent: .intentional(clearLastError: false)
                )
                if let failure { throw failure }
                return false
            case .idle, .starting, .stopping:
                await stopAndDropSession(
                    existingSession,
                    generation: generation,
                    intent: .intentional(clearLastError: true)
                )
                throw GlassesCaptureError.sessionTimedOut
            }
        }
    }

    private func waitForSessionResolution(
        _ target: DeviceSession,
        generation: UInt
    ) async throws -> DeviceSessionState {
        for _ in 0..<120 {
            guard sessionGeneration == generation, session === target else {
                return .stopped
            }
            switch target.state {
            case .started, .paused, .stopped:
                return target.state
            case .idle, .starting, .stopping:
                try await Task.sleep(for: .milliseconds(100))
            }
        }
        return target.state
    }

    private func observeSessionLifecycle(_ target: DeviceSession, generation: UInt) {
        let errorLatch = SessionErrorLatch()
        sessionErrorLatch = errorLatch
        sessionStateToken = target.statePublisher.listen { [weak self, weak target] state in
            Task { @MainActor [weak self, weak target] in
                guard let self, let target else { return }
                await self.handleSessionState(state, target: target, generation: generation)
            }
        }
        sessionErrorToken = target.errorPublisher.listen { [weak self, weak target] error in
            errorLatch.record(error)
            NSLog("[CodexLensCamera] session SDK error: %@", error.localizedDescription)
            Task { @MainActor [weak self, weak target] in
                guard let self, let target,
                      self.sessionGeneration == generation,
                      self.session === target else { return }
                self.lastSessionError = error
                // The SDK owns the error-driven stop. Start one cleanup owner,
                // but do not call stop() again; the terminal state completes it.
                _ = await self.stopAndDropSession(
                    target,
                    generation: generation,
                    intent: .loss(reason: error.localizedDescription)
                )
            }
        }
    }

    private func handleSessionState(
        _ state: DeviceSessionState,
        target: DeviceSession,
        generation: UInt
    ) async {
        guard sessionGeneration == generation,
              session === target,
              target.state == state else { return }
        trace("session state changed: \(state.description)")
        switch state {
        case .started:
            if cameraMode == .background, camera?.stream.state == .streaming {
                isBackgroundCaptureArmed = true
            }
            onDeviceAvailable?()
        case .paused:
            isBackgroundCaptureArmed = false
            // Paused is an SDK-owned, nonterminal wait state. Keep the session
            // and camera attached; the publisher announces started on resume.
            trace("session paused; waiting for Meta to resume it")
        case .stopping:
            isBackgroundCaptureArmed = false
        case .stopped:
            if sessionTeardownGeneration == generation {
                _ = await continuePendingSessionTeardown(target, generation: generation)
            } else {
                let failure = sessionErrorLatch?.error ?? lastSessionError
                if let failure { lastSessionError = failure }
                _ = await stopAndDropSession(
                    target,
                    generation: generation,
                    intent: .loss(
                        reason: failure?.localizedDescription ?? "Meta glasses session stopped."
                    )
                )
            }
        case .idle, .starting:
            break
        }
    }

    @discardableResult
    private func stopAndDropSession(
        _ target: DeviceSession,
        generation: UInt,
        intent: SessionTeardownIntent
    ) async -> Bool {
        guard sessionGeneration == generation, session === target else { return false }

        if let pendingGeneration = sessionTeardownGeneration {
            guard pendingGeneration == generation else { return false }
        } else {
            sessionTeardownGeneration = generation
        }
        mergeSessionTeardownIntent(intent)

        if let sessionTeardownTask {
            return await sessionTeardownTask.value
        }

        return await continuePendingSessionTeardown(target, generation: generation)
    }

    private func mergeSessionTeardownIntent(_ intent: SessionTeardownIntent) {
        switch intent {
        case .intentional(let clearLastError):
            // An already-recorded unexpected loss remains a loss. Otherwise an
            // intentional stop owns the terminal state and must not reconnect.
            if !sessionTeardownNotifiesLoss {
                sessionTeardownClearsError = sessionTeardownClearsError || clearLastError
            }
            sessionTeardownRequestsStop = true
        case .loss(let reason):
            // A late SDK error caused by an explicit disconnect must not turn
            // that intentional teardown into a reconnect-worthy device loss.
            // If the loss arrived first, it remains authoritative.
            guard !sessionTeardownRequestsStop else { return }
            sessionTeardownNotifiesLoss = true
            sessionTeardownClearsError = false
            sessionTeardownReason = reason
        }
    }

    private func continuePendingSessionTeardown(
        _ target: DeviceSession,
        generation: UInt
    ) async -> Bool {
        guard sessionGeneration == generation,
              session === target,
              sessionTeardownGeneration == generation else { return false }
        if let sessionTeardownTask {
            return await sessionTeardownTask.value
        }

        // This unstructured owner deliberately does not inherit cancellation
        // from a recovery/capture caller. Cleanup must reach a terminal state
        // even when the operation that requested it is cancelled.
        let cleanupTask = Task { @MainActor [weak self, weak target] in
            guard let self, let target else { return false }
            var stopRequested = false
            for _ in 0..<100 {
                guard self.sessionGeneration == generation,
                      self.session === target,
                      self.sessionTeardownGeneration == generation else { return false }
                if self.sessionTeardownRequestsStop, !stopRequested,
                   target.state != .stopped {
                    target.stop()
                    stopRequested = true
                }
                if target.state == .stopped { break }
                try? await Task.sleep(for: .milliseconds(100))
            }
            guard self.sessionGeneration == generation,
                  self.session === target,
                  self.sessionTeardownGeneration == generation else { return false }
            guard target.state == .stopped else {
                self.trace("session teardown still pending; retaining terminal ownership")
                self.sessionTeardownTask = nil
                return false
            }

            guard await self.stopCameraWithoutLifecycleGate() else {
                self.sessionTeardownTask = nil
                return false
            }

            let stateToken = self.sessionStateToken
            let errorToken = self.sessionErrorToken
            await stateToken?.cancel()
            await errorToken?.cancel()
            guard self.sessionGeneration == generation,
                  self.session === target,
                  self.sessionTeardownGeneration == generation else { return false }

            let notifyLoss = self.sessionTeardownNotifiesLoss
            let reason = self.sessionTeardownReason
                ?? self.sessionErrorLatch?.error?.localizedDescription
                ?? self.lastSessionError?.localizedDescription
                ?? "Meta glasses session stopped."
            let clearLastError = self.sessionTeardownClearsError && !notifyLoss

            self.sessionGeneration &+= 1
            self.sessionStateToken = nil
            self.sessionErrorToken = nil
            self.session = nil
            self.sessionErrorLatch = nil
            self.sessionTeardownTask = nil
            self.sessionTeardownGeneration = nil
            self.sessionTeardownNotifiesLoss = false
            self.sessionTeardownReason = nil
            self.sessionTeardownClearsError = false
            self.sessionTeardownRequestsStop = false
            if clearLastError { self.lastSessionError = nil }
            if notifyLoss { self.onSessionLost?(reason) }
            return true
        }
        sessionTeardownTask = cleanupTask
        return await cleanupTask.value
    }

    /// Takes exactly one still photo after an explicit user action. The stream
    /// is stopped immediately after capture and the returned JPEG has metadata
    /// stripped and a bounded longest edge/byte size.
    func captureVisualContext() async throws -> Data {
        try await captureVisualEvidence(count: 1).selectedJPEGData
    }

    /// Captures a short burst without restarting the glasses stream between
    /// frames. Multiple views improve small-text reading and tolerate blink,
    /// motion blur, and slight head movement.
    func captureVisualBurst(
        count: Int = 3,
        profile: VisualCaptureProfile = .reading
    ) async throws -> [Data] {
        try await captureVisualEvidence(count: count, profile: profile).jpegData
    }

    func captureVisualEvidence(
        count: Int = 3,
        profile: VisualCaptureProfile = .reading
    ) async throws -> CapturedVisualEvidence {
        try await withLifecycleOperation {
            do {
                let evidence = try await captureVisualEvidenceWithoutLifecycleGate(
                    count: count,
                    profile: profile
                )
                if cameraMode == .transient {
                    await stopCameraWithoutLifecycleGate()
                }
                return evidence
            } catch {
                if cameraMode == .transient {
                    await stopCameraWithoutLifecycleGate()
                }
                throw error
            }
        }
    }

    private func captureVisualEvidenceWithoutLifecycleGate(
        count: Int,
        profile: VisualCaptureProfile
    ) async throws -> CapturedVisualEvidence {
        // Keep one visual request in flight so overlapping model tool calls do
        // not race the shared camera or consume the same streamed frames.
        guard !isPhotoCaptureInFlight else {
            throw GlassesCaptureError.photoRequestRejected
        }
        isPhotoCaptureInFlight = true
        defer { isPhotoCaptureInFlight = false }

        let captureStarted = ContinuousClock.now
        trace("capture requested; count=\(count) profile=\(String(describing: profile))")
        try Task.checkCancellation()
        try await connectWithoutLifecycleGate()
        try Task.checkCancellation()
        guard let session else { throw GlassesCaptureError.noEligibleDevice(deviceDiagnostics) }
        // A background HVC1 camera cannot be reused for this workaround. Make
        // every on-demand request own a known raw stream configuration.
        if camera != nil {
            guard await stopCameraWithoutLifecycleGate() else {
                throw GlassesCaptureError.streamUnavailable
            }
        }

        let requestedFrameCount = max(1, min(count, 3))
        let configuration = StreamConfiguration(
            // Match the exact HFP-compatible configuration documented in
            // Meta DAT issue #260. HVC1 can report `.streaming` without
            // emitting decodable frames to a late subscriber, while this
            // raw stream continues delivering frames with HFP voice live.
            videoCodec: .raw,
            resolution: .low,
            frameRate: 24
        )
        guard let activeCamera = try session.addCamera(config: configuration) else {
            throw GlassesCaptureError.streamUnavailable
        }
        camera = activeCamera
        cameraMode = .transient
        observeCameraLifecycle(activeCamera, generation: sessionGeneration)
        trace("camera added; state=\(String(describing: activeCamera.state))")
        let cameraStream = activeCamera.stream

        // Subscribe before Stream.start(). Meta's reference ordering and live
        // device behavior both require the consumer to be present when the raw
        // stream begins; attaching after `.streaming` can miss every frame.
        let latch = VideoFrameBurstLatch(targetCount: requestedFrameCount)
        let frameToken = cameraStream.videoFramePublisher.listen { frame in
            guard let image = frame.makeUIImage(),
                  let jpeg = image.jpegData(compressionQuality: 0.92) else { return }
            Task { await latch.append(jpeg) }
        }
        let errorToken = cameraStream.errorPublisher.listen { error in
            Task { await latch.resolve(.failure(error)) }
        }

        isCameraActive = true
        // Meta's 0.9 lifecycle starts the child stream immediately after
        // addCamera(). Waiting for Camera.state == .started first deadlocks the
        // lifecycle because the camera is activated by Stream.start().
        if cameraStream.state == .stopped {
            cameraStream.start()
            trace("stream start requested; state=\(String(describing: cameraStream.state))")
        }
        do {
            try await waitUntilStreaming(cameraStream)
            try Task.checkCancellation()
        } catch {
            await frameToken.cancel()
            await errorToken.cancel()
            throw error
        }

        if isThermallyBlocked {
            await frameToken.cancel()
            await errorToken.cancel()
            throw GlassesCaptureError.thermalProtection(thermalStatus)
        }

        // Meta DAT issue #260: with the wearable HFP microphone active,
        // capturePhoto() returns true but photoDataPublisher never fires. The
        // video publisher remains healthy. Taking the next streamed frames is
        // therefore the reliable simultaneous voice + vision path and avoids
        // interrupting the working WebRTC voice session.
        trace("waiting for \(requestedFrameCount) streamed visual frame(s)")
        let timeoutTask = Task {
            do {
                try await Task.sleep(for: .seconds(4))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await latch.finishWithAvailableFrames()
        }

        let originals: [Data]
        do {
            originals = try await latch.wait()
        } catch {
            timeoutTask.cancel()
            await frameToken.cancel()
            await errorToken.cancel()
            throw error
        }
        timeoutTask.cancel()
        await frameToken.cancel()
        await errorToken.cancel()

        var candidates: [CapturedFrameCandidate] = []
        for (index, original) in originals.enumerated() {
            guard let rawImage = UIImage(data: original) else { continue }
            let pixelWidth = rawImage.cgImage?.width
                ?? Int(rawImage.size.width * rawImage.scale)
            let pixelHeight = rawImage.cgImage?.height
                ?? Int(rawImage.size.height * rawImage.scale)
            let recognition: TextRecognitionEvidence
            let sharpness: Double
            if profile == .reading {
                async let pendingRecognition = Self.recognizeText(in: original)
                async let pendingSharpness = Self.measureNormalizedSharpness(in: original)
                (recognition, sharpness) = await (pendingRecognition, pendingSharpness)
            } else {
                recognition = .empty
                sharpness = await Self.measureNormalizedSharpness(in: original)
            }
            let sanitized = try sanitizeJPEGImage(rawImage, profile: profile)
            let quality = VisualFrameQuality(
                recognizedCharacterCount: recognition.characterCount,
                recognizedLineCount: recognition.lineCount,
                averageTextConfidence: recognition.averageConfidence,
                normalizedSharpness: sharpness,
                pixelCount: pixelWidth * pixelHeight,
                encodedByteCount: sanitized.count
            )
            candidates.append(CapturedFrameCandidate(
                jpegData: sanitized,
                recognizedText: recognition.text,
                quality: quality
            ))
            let elapsed = captureStarted.duration(to: .now)
            trace("stream frame \(index + 1) received: raw=\(original.count) bytes pixels=\(pixelWidth)x\(pixelHeight) sent=\(sanitized.count) bytes text=\(recognition.characterCount) confidence=\(String(format: "%.3f", recognition.averageConfidence)) sharpness=\(String(format: "%.4f", sharpness)) elapsed=\(elapsed)")
        }
        guard let selectedFrameIndex = VisualFrameSelector.bestIndex(
            in: candidates.map(\.quality)
        ) else {
            throw GlassesCaptureError.photoTimedOut
        }
        let selected = candidates[selectedFrameIndex]
        trace("burst selected frame \(selectedFrameIndex + 1)/\(candidates.count) score=\(String(format: "%.2f", VisualFrameSelector.score(selected.quality)))")
        return CapturedVisualEvidence(
            jpegData: candidates.map(\.jpegData),
            selectedFrameIndex: selectedFrameIndex,
            recognizedText: selected.recognizedText,
            selectedQuality: selected.quality
        )
    }

    /// Prepares Meta's photo pipeline while the app is foregrounded. iOS and
    /// the glasses firmware do not reliably allow a brand-new camera stream to
    /// start after screen lock, but an existing photo-only stream can remain
    /// available while the background audio conversation keeps the app alive.
    func prepareBackgroundCapture() async throws {
        try await withLifecycleOperation {
            try await prepareBackgroundCaptureWithoutLifecycleGate()
        }
    }

    private func prepareBackgroundCaptureWithoutLifecycleGate() async throws {
        // This may have waited behind an explicit capture or teardown. Do not
        // report an armed camera to a recovery task that was cancelled while
        // waiting for the lifecycle gate.
        try Task.checkCancellation()
        if isBackgroundCaptureArmed, camera?.stream.state == .streaming { return }
        if let existingCamera = camera, cameraMode == .background {
            switch existingCamera.stream.state {
            case .streaming:
                isBackgroundCaptureArmed = true
                return
            case .starting, .waitingForDevice, .paused:
                try await waitUntilStreaming(existingCamera.stream)
                try Task.checkCancellation()
                isBackgroundCaptureArmed = true
                return
            case .stopping, .stopped:
                break
            }
        }
        try Task.checkCancellation()
        guard await stopCameraWithoutLifecycleGate() else {
            throw GlassesCaptureError.streamUnavailable
        }
        try Task.checkCancellation()
        try await connectWithoutLifecycleGate()
        try Task.checkCancellation()
        guard let session else { throw GlassesCaptureError.noEligibleDevice(deviceDiagnostics) }
        let generation = sessionGeneration
        let configuration = StreamConfiguration(
            videoCodec: .hvc1,
            // Keep a high-resolution photo-only stream armed. The video frame
            // rate is the SDK's valid HVC1 minimum, preserving screen-text
            // detail without running high-rate video while the phone is locked.
            resolution: .high,
            frameRate: 2
        )
        guard let activeCamera = try session.addCamera(config: configuration) else {
            throw GlassesCaptureError.streamUnavailable
        }
        camera = activeCamera
        cameraMode = .background
        isCameraActive = true
        // Install listeners before requesting start so an immediate SDK error
        // or terminal transition cannot occur in an unobserved window.
        observeCameraLifecycle(activeCamera, generation: generation)
        activeCamera.stream.start()
        trace("background photo stream arming")
        do {
            try await waitUntilStreaming(activeCamera.stream)
            try Task.checkCancellation()
            guard sessionGeneration == generation,
                  self.session === session,
                  camera === activeCamera else {
                throw GlassesCaptureError.streamUnavailable
            }
            isBackgroundCaptureArmed = true
            trace("background photo stream armed")
        } catch {
            await stopCameraWithoutLifecycleGate()
            throw error
        }
    }

    func startLiveVideo(onFrame: @escaping @Sendable (UIImage) -> Void) async throws {
        try await withLifecycleOperation {
            try await startLiveVideoWithoutLifecycleGate(onFrame: onFrame)
        }
    }

    private func startLiveVideoWithoutLifecycleGate(
        onFrame: @escaping @Sendable (UIImage) -> Void
    ) async throws {
        try Task.checkCancellation()
        guard await stopCameraWithoutLifecycleGate() else {
            throw GlassesCaptureError.streamUnavailable
        }
        try Task.checkCancellation()
        try await connectWithoutLifecycleGate()
        try Task.checkCancellation()
        guard let session else { throw GlassesCaptureError.noEligibleDevice(deviceDiagnostics) }
        let generation = sessionGeneration

        let configuration = StreamConfiguration(
            videoCodec: .raw,
            resolution: .low,
            frameRate: 15
        )
        guard let activeCamera = try session.addCamera(config: configuration) else {
            throw GlassesCaptureError.streamUnavailable
        }
        camera = activeCamera
        cameraMode = .live
        let cameraStream = activeCamera.stream
        videoFrameToken = cameraStream.videoFramePublisher.listen { frame in
            if let image = frame.makeUIImage() {
                onFrame(image)
            }
        }
        isCameraActive = true
        // Meta's reference ordering subscribes before start. This also lets the
        // catch teardown observe an immediate terminal transition correctly.
        observeCameraLifecycle(activeCamera, generation: generation)
        cameraStream.start()
        trace("live video start requested")
        do {
            try await waitUntilStreaming(cameraStream)
            try Task.checkCancellation()
            guard sessionGeneration == generation,
                  self.session === session,
                  camera === activeCamera else {
                throw GlassesCaptureError.streamUnavailable
            }
        } catch {
            await stopCameraWithoutLifecycleGate()
            throw error
        }
        trace("live video streaming")
    }

    private func waitUntilStreaming(_ cameraStream: MWDATCamera.Stream) async throws {
        var streamBeganTransitioning = false
        for _ in 0..<150 {
            let state = cameraStream.state
            if state == .streaming {
                trace("streaming")
                break
            }
            // Stream.start() is asynchronous. The SDK briefly retains its
            // initial `.stopped` value before publishing `.starting`; treating
            // that initial value as a failure races every real device start.
            if state != .stopped {
                streamBeganTransitioning = true
            } else if streamBeganTransitioning {
                trace("stream stopped before streaming")
                throw GlassesCaptureError.streamUnavailable
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        guard cameraStream.state == .streaming else {
            if cameraStream.state == .paused || cameraStream.state == .waitingForDevice {
                throw GlassesCaptureError.sessionPaused
            }
            throw GlassesCaptureError.streamTimedOut
        }
    }

    private func observeCameraLifecycle(
        _ activeCamera: MWDATCamera.Camera,
        generation: UInt
    ) {
        cameraStateToken = activeCamera.statePublisher.listen { [weak self, weak activeCamera] state in
            Task { @MainActor [weak self, weak activeCamera] in
                guard let self, let activeCamera else { return }
                await self.handleCameraState(
                    state,
                    activeCamera: activeCamera,
                    generation: generation
                )
            }
        }
        streamStateToken = activeCamera.stream.statePublisher.listen { [weak self, weak activeCamera] state in
            Task { @MainActor [weak self, weak activeCamera] in
                guard let self, let activeCamera else { return }
                await self.handleStreamState(
                    state,
                    activeCamera: activeCamera,
                    generation: generation
                )
            }
        }
        streamErrorToken = activeCamera.stream.errorPublisher.listen { [weak self, weak activeCamera] error in
            guard self != nil, activeCamera != nil else { return }
            // Stream errors are diagnostic. Meta owns the error-driven state
            // transition, and the terminal CameraState callback owns cleanup.
            // A per-photo listener separately reports photoCaptureFailed to the
            // accepted request without tearing down the armed background camera.
            NSLog("[CodexLensCamera] stream SDK error: %@", error.localizedDescription)
        }
    }

    private func handleCameraState(
        _ state: CameraState,
        activeCamera: MWDATCamera.Camera,
        generation: UInt
    ) async {
        guard sessionGeneration == generation,
              camera === activeCamera,
              activeCamera.state == state else { return }
        trace("camera state changed: \(String(describing: state))")
        switch state {
        case .starting, .started:
            break
        case .stopping:
            isBackgroundCaptureArmed = false
        case .stopped:
            await handleCameraTerminal(
                activeCamera,
                generation: generation,
                reason: "Meta glasses camera stopped."
            )
        }
    }

    private func handleStreamState(
        _ state: StreamState,
        activeCamera: MWDATCamera.Camera,
        generation: UInt
    ) async {
        guard sessionGeneration == generation,
              camera === activeCamera,
              activeCamera.stream.state == state else { return }
        trace("camera stream state changed: \(String(describing: state))")
        switch state {
        case .streaming:
            if cameraMode == .background {
                isBackgroundCaptureArmed = true
            }
            onDeviceAvailable?()
        case .paused:
            if isPhotoCaptureInFlight {
                // capturePhoto() documents this as a normal temporary pause and
                // automatic resume. Starting recovery here stops the very camera
                // that is delivering the requested still.
                trace("camera stream paused temporarily for still capture")
                break
            }
            isBackgroundCaptureArmed = false
            trace("camera stream paused; waiting for Meta to resume it")
        case .waitingForDevice:
            isBackgroundCaptureArmed = false
            trace("camera stream waiting for device; retaining camera ownership")
        case .stopping:
            isBackgroundCaptureArmed = false
        case .stopped:
            await beginCameraTeardown(
                activeCamera,
                generation: generation,
                notifyLoss: shouldNotifyCameraLoss(generation: generation),
                reason: "Meta glasses camera stream stopped.",
                // A terminal child stream does not detach its parent Camera in
                // Meta DAT 0.9. Camera.stop() is still required here; it owns
                // the cascade and CameraState.stopped remains the sole point at
                // which we release the capability and listener tokens.
                requestStop: true
            )
        case .starting:
            break
        }
    }

    private func handleCameraTerminal(
        _ activeCamera: MWDATCamera.Camera,
        generation: UInt,
        reason: String
    ) async {
        guard sessionGeneration == generation, camera === activeCamera else { return }
        await beginCameraTeardown(
            activeCamera,
            generation: generation,
            notifyLoss: shouldNotifyCameraLoss(generation: generation),
            reason: cameraTeardownReason ?? reason,
            requestStop: false
        )
    }

    func stopCamera() async {
        await withLifecycleOperation {
            _ = await stopCameraWithoutLifecycleGate()
        }
    }

    private func shouldNotifyCameraLoss(generation: UInt) -> Bool {
        // Once session teardown exists it is the single notification owner.
        // Its child camera may become terminal first for either an intentional
        // stop or an unexpected session loss; letting both layers notify would
        // schedule duplicate recovery work for the same failure.
        if sessionTeardownGeneration == generation {
            return false
        }
        return cameraTeardownTarget == nil || cameraTeardownNotifiesLoss
    }

    @discardableResult
    private func stopCameraWithoutLifecycleGate() async -> Bool {
        guard let activeCamera = camera else {
            isBackgroundCaptureArmed = false
            cameraMode = .none
            isCameraActive = false
            return true
        }
        return await beginCameraTeardown(
            activeCamera,
            generation: sessionGeneration,
            notifyLoss: false,
            reason: nil,
            requestStop: true
        )
    }

    @discardableResult
    private func beginCameraTeardown(
        _ activeCamera: MWDATCamera.Camera,
        generation: UInt,
        notifyLoss: Bool,
        reason: String?,
        requestStop: Bool
    ) async -> Bool {
        guard sessionGeneration == generation, camera === activeCamera else { return false }
        if let target = cameraTeardownTarget {
            guard target === activeCamera else { return false }
        } else {
            cameraTeardownTarget = activeCamera
        }
        cameraTeardownNotifiesLoss = cameraTeardownNotifiesLoss || notifyLoss
        if let reason { cameraTeardownReason = reason }
        cameraTeardownRequestsStop = cameraTeardownRequestsStop || requestStop
        if let cameraTeardownTask {
            return await cameraTeardownTask.value
        }

        let cleanupTask = Task { @MainActor [weak self, weak activeCamera] in
            guard let self, let activeCamera else { return false }
            var stopRequested = false
            for _ in 0..<100 {
                guard self.sessionGeneration == generation,
                      self.camera === activeCamera,
                      self.cameraTeardownTarget === activeCamera else { return false }
                if self.cameraTeardownRequestsStop, !stopRequested,
                   activeCamera.state != .stopped {
                    // Camera.stop() is the only stop call. Meta 0.9 cascades it
                    // to the child stream; calling stream.stop() too creates a
                    // second teardown owner.
                    activeCamera.stop()
                    stopRequested = true
                }
                if activeCamera.state == .stopped { break }
                try? await Task.sleep(for: .milliseconds(100))
            }
            guard self.sessionGeneration == generation,
                  self.camera === activeCamera,
                  self.cameraTeardownTarget === activeCamera else { return false }
            guard activeCamera.state == .stopped else {
                self.trace("camera teardown still pending; retaining terminal ownership")
                self.cameraTeardownTask = nil
                return false
            }

            let cameraStateToken = self.cameraStateToken
            let streamStateToken = self.streamStateToken
            let streamErrorToken = self.streamErrorToken
            let videoFrameToken = self.videoFrameToken
            await cameraStateToken?.cancel()
            await streamStateToken?.cancel()
            await streamErrorToken?.cancel()
            await videoFrameToken?.cancel()
            guard self.sessionGeneration == generation,
                  self.camera === activeCamera,
                  self.cameraTeardownTarget === activeCamera else { return false }

            let notifyLoss = self.cameraTeardownNotifiesLoss
            let lossReason = self.cameraTeardownReason ?? "Meta glasses camera stopped."
            self.isBackgroundCaptureArmed = false
            self.camera = nil
            self.cameraMode = .none
            self.cameraStateToken = nil
            self.streamStateToken = nil
            self.streamErrorToken = nil
            self.videoFrameToken = nil
            self.isCameraActive = false
            self.cameraTeardownTask = nil
            self.cameraTeardownTarget = nil
            self.cameraTeardownNotifiesLoss = false
            self.cameraTeardownReason = nil
            self.cameraTeardownRequestsStop = false
            if notifyLoss { self.onSessionLost?(lossReason) }
            if self.sessionTeardownGeneration == generation,
               self.sessionTeardownTask == nil,
               let pendingSession = self.session {
                _ = await self.continuePendingSessionTeardown(
                    pendingSession,
                    generation: generation
                )
            }
            return true
        }
        cameraTeardownTask = cleanupTask
        return await cleanupTask.value
    }

    func sanitizePhoneImage(_ image: UIImage) throws -> Data {
        try sanitizeJPEGImage(image)
    }

    private func requireConfiguration() throws {
        if let configurationError {
            throw GlassesCaptureError.sdkNotConfigured(configurationError.localizedDescription)
        }
    }

    private func observeDeviceLinks(_ identifiers: [DeviceIdentifier]) {
        let currentIdentifiers = Set(identifiers)
        for identifier in deviceStateTasks.keys where !currentIdentifiers.contains(identifier) {
            deviceStateTasks.removeValue(forKey: identifier)?.cancel()
            deviceThermalLevels.removeValue(forKey: identifier)
        }
        for identifier in linkStateTokens.keys where !currentIdentifiers.contains(identifier) {
            if let token = linkStateTokens.removeValue(forKey: identifier) {
                Task { await token.cancel() }
            }
        }
        for identifier in identifiers {
            guard let device = wearables.deviceForIdentifier(identifier) else { continue }
            if deviceStateTasks[identifier] == nil {
                deviceStateTasks[identifier] = Task { @MainActor [weak self] in
                    guard let self else { return }
                    for await state in self.wearables.deviceStateStream(for: identifier) {
                        guard !Task.isCancelled else { return }
                        let wasBlocked = self.isThermallyBlocked
                        self.deviceThermalLevels[identifier] = state.thermalLevel
                        let isBlocked = self.isThermallyBlocked
                        self.trace(
                            "device thermal state: \(device.nameOrId()) = \(String(describing: state.thermalLevel))"
                        )
                        if !wasBlocked, isBlocked {
                            self.isBackgroundCaptureArmed = false
                            self.onSessionLost?(
                                "Glasses camera paused for thermal protection. \(self.thermalStatus)"
                            )
                        } else if wasBlocked, !isBlocked,
                                  device.linkState == .connected {
                            self.onDeviceAvailable?()
                        }
                    }
                }
            }
            guard linkStateTokens[identifier] == nil else { continue }
            let deviceName = device.nameOrId()
            linkStateTokens[identifier] = device.addLinkStateListener { [weak self] linkState in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.trace("device link changed: \(deviceName) = \(String(describing: linkState))")
                    guard self.wearables.deviceForIdentifier(identifier)?.linkState == linkState else {
                        return
                    }
                    switch linkState {
                    case .connected:
                        self.onDeviceAvailable?()
                    case .connecting:
                        if self.session?.deviceId == identifier {
                            self.isBackgroundCaptureArmed = false
                        }
                    case .disconnected:
                        guard let activeSession = self.session,
                              activeSession.deviceId == identifier else { return }
                        let generation = self.sessionGeneration
                        self.isBackgroundCaptureArmed = false
                        _ = await self.stopAndDropSession(
                            activeSession,
                            generation: generation,
                            intent: .loss(reason: "\(deviceName) disconnected.")
                        )
                    }
                }
            }
        }
    }

    private func preferredDeviceIdentifier(requireConnected: Bool) -> DeviceIdentifier? {
        let records = wearables.devices.compactMap { identifier -> (DeviceIdentifier, Device)? in
            guard let device = wearables.deviceForIdentifier(identifier) else { return nil }
            return (identifier, device)
        }
        if let compatibleConnected = records.first(where: {
            $0.1.linkState == .connected && $0.1.compatibility() == .compatible
        }) {
            return compatibleConnected.0
        }
        // A Bluetooth-connected record is not enough for camera readiness.
        // Meta can report connected hardware that the current SDK cannot select.
        // Treat only a connected, compatible device as capture-ready so the UI
        // and recovery loop do not promise a camera session that cannot exist.
        guard !requireConnected else { return nil }
        return records.first?.0
    }

    private func waitForEligibleDevice(timeout: Duration) async throws {
        if deviceSelector.activeDevice != nil { return }

        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if deviceSelector.activeDevice != nil { return }
            try await Task.sleep(for: .milliseconds(250))
        }
        throw GlassesCaptureError.noEligibleDevice(deviceDiagnostics)
    }

    private func sanitizeJPEG(
        _ data: Data,
        profile: VisualCaptureProfile = .reading
    ) throws -> Data {
        guard let image = UIImage(data: data) else { throw GlassesCaptureError.invalidImage }
        return try sanitizeJPEGImage(image, profile: profile)
    }

    private func sanitizeJPEGImage(
        _ image: UIImage,
        profile: VisualCaptureProfile = .reading
    ) throws -> Data {
        let maxEdge = profile.maxEdge
        let longest = max(image.size.width, image.size.height)
        let scale = min(1, maxEdge / max(longest, 1))
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let rendered = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        var quality = profile.compressionQuality
        while quality >= 0.28 {
            if let jpeg = rendered.jpegData(compressionQuality: quality), jpeg.count <= profile.maximumBytes {
                return jpeg
            }
            quality -= 0.08
        }
        throw GlassesCaptureError.invalidImage
    }

    nonisolated private static func recognizeText(in jpeg: Data) async -> TextRecognitionEvidence {
        await Task.detached(priority: .userInitiated) {
            // The glasses return a wide still. Run one full-frame pass plus
            // two centered regions at increasing software zoom. Region-based
            // Vision requests can recover small centered print that is below
            // the useful scale of the full-frame pass; full-frame remains the
            // fallback when the wearer has not centered the target precisely.
            let regions = [
                CGRect(x: 0, y: 0, width: 1, height: 1),
                CGRect(x: 0.10, y: 0.10, width: 0.80, height: 0.80),
                CGRect(x: 0.20, y: 0.20, width: 0.60, height: 0.60),
            ]
            let requests = regions.map { region in
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.usesLanguageCorrection = true
                request.recognitionLanguages = ["en-US"]
                request.minimumTextHeight = 0.008
                request.regionOfInterest = region
                return request
            }
            let handler = VNImageRequestHandler(data: jpeg, options: [:])
            do {
                try handler.perform(requests)
            } catch {
                return .empty
            }
            let evidence = requests.map { request -> TextRecognitionEvidence in
                let candidates = (request.results ?? []).compactMap {
                    $0.topCandidates(1).first
                }.filter {
                    !$0.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                }
                let lines = candidates.map {
                    $0.string.trimmingCharacters(in: .whitespacesAndNewlines)
                }
                let text = String(lines.joined(separator: "\n").prefix(6_000))
                let confidence = candidates.isEmpty
                    ? 0
                    : candidates.reduce(0) { $0 + Double($1.confidence) }
                        / Double(candidates.count)
                return TextRecognitionEvidence(
                    text: text,
                    characterCount: text.filter { !$0.isWhitespace }.count,
                    lineCount: lines.count,
                    averageConfidence: confidence
                )
            }
            return evidence.max { lhs, rhs in
                let lhsScore = Double(lhs.characterCount)
                    + (Double(lhs.lineCount) * 8)
                    + (lhs.averageConfidence * 40)
                let rhsScore = Double(rhs.characterCount)
                    + (Double(rhs.lineCount) * 8)
                    + (rhs.averageConfidence * 40)
                return lhsScore < rhsScore
            } ?? .empty
        }.value
    }

    /// Mean absolute Laplacian over a small grayscale thumbnail. It is cheap,
    /// bounded, and useful for rejecting motion-blurred frames when OCR finds
    /// no credible text. The original JPEG never leaves process memory.
    nonisolated private static func measureNormalizedSharpness(in jpeg: Data) async -> Double {
        await Task.detached(priority: .userInitiated) {
            guard let source = UIImage(data: jpeg)?.cgImage else { return 0 }
            let longestTarget = 192.0
            let sourceWidth = Double(source.width)
            let sourceHeight = Double(source.height)
            let scale = min(1, longestTarget / max(max(sourceWidth, sourceHeight), 1))
            let width = max(3, Int((sourceWidth * scale).rounded()))
            let height = max(3, Int((sourceHeight * scale).rounded()))
            var pixels = [UInt8](repeating: 0, count: width * height)
            let rendered = pixels.withUnsafeMutableBytes { buffer -> Bool in
                guard let baseAddress = buffer.baseAddress,
                      let context = CGContext(
                          data: baseAddress,
                          width: width,
                          height: height,
                          bitsPerComponent: 8,
                          bytesPerRow: width,
                          space: CGColorSpaceCreateDeviceGray(),
                          bitmapInfo: CGImageAlphaInfo.none.rawValue
                      )
                else { return false }
                context.interpolationQuality = .medium
                context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
                return true
            }
            guard rendered else { return 0 }

            var total = 0.0
            var sampleCount = 0
            for y in 1..<(height - 1) {
                let row = y * width
                for x in 1..<(width - 1) {
                    let center = Int(pixels[row + x])
                    let laplacian = (4 * center)
                        - Int(pixels[row + x - 1])
                        - Int(pixels[row + x + 1])
                        - Int(pixels[row - width + x])
                        - Int(pixels[row + width + x])
                    total += Double(abs(laplacian))
                    sampleCount += 1
                }
            }
            guard sampleCount > 0 else { return 0 }
            return min(max((total / Double(sampleCount)) / 255, 0), 1)
        }.value
    }
}

private actor VideoFrameBurstLatch {
    private let targetCount: Int
    private var frames: [Data] = []
    private var result: Result<[Data], Error>?
    private var continuation: CheckedContinuation<[Data], Error>?

    init(targetCount: Int) {
        self.targetCount = max(1, targetCount)
    }

    func wait() async throws -> [Data] {
        if let result { return try result.get() }
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
        }
    }

    func append(_ frame: Data) {
        guard result == nil else { return }
        frames.append(frame)
        if frames.count >= targetCount {
            resolve(.success(Array(frames.prefix(targetCount))))
        }
    }

    func finishWithAvailableFrames() {
        if frames.isEmpty {
            resolve(.failure(GlassesCaptureError.photoTimedOut))
        } else {
            resolve(.success(frames))
        }
    }

    func resolve(_ result: Result<[Data], Error>) {
        guard self.result == nil else { return }
        self.result = result
        continuation?.resume(with: result)
        continuation = nil
    }
}
