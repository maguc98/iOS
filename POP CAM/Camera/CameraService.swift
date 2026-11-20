import AVFoundation
import Photos
import SwiftUI
import UIKit

enum CameraFocusStatus {
    case idle
    case focusing
    case focused
    case unavailable
}

@MainActor
final class CameraService: ObservableObject {
    @Published var isReady = false
    @Published var isAuthorized = false
    @Published var previewImage: CGImage?
    @Published var selectedFilter: CameraFilter = .pop {
        didSet { liveProcessor.selectedFilter = selectedFilter }
    }
    @Published var flashEnabled = false
    @Published var cameraPosition: AVCaptureDevice.Position = .back
    @Published var zoomFactor: CGFloat = 1
    @Published var exposureBias: Float = 0
    @Published var isExposureFocusLocked = false
    @Published var focusStatus: CameraFocusStatus = .idle
    @Published private(set) var autofocusPoints: [AutofocusPoint] = []
    @Published var capturedImage: UIImage?
    @Published var captureID = 0
    @Published var errorMessage: String?
    @Published private(set) var isRecording = false
    @Published private(set) var recordingDuration: TimeInterval = 0
    @Published private(set) var appliedVideoDescription = "4K · 30 FPS · HDR"
    @Published private(set) var savedVideoURLs: [URL] = []
    @Published private(set) var savedPhotoURLs: [URL] = []
    @Published private(set) var savedMediaURLs: [URL] = []
    @Published private(set) var isVideoConfigurationInProgress = false
    @Published private(set) var appliedHDR: Bool? = nil
    @Published private(set) var appliedFrameRate = 0
    @Published private(set) var appliedResolution = ""
    @Published private(set) var videoConfigurationRevision = 0

    let session = AVCaptureSession()
    private let photoOutput = AVCapturePhotoOutput()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let movieOutput = AVCaptureMovieFileOutput()
    private let sessionQueue = DispatchQueue(label: "com.maguc98.popcam.session")
    private let videoQueue = DispatchQueue(label: "com.maguc98.popcam.video")
    private lazy var liveProcessor: LivePreviewProcessor = {
        let processor = LivePreviewProcessor()
        processor.onFrame = { [weak self] frame in
            DispatchQueue.main.async { self?.previewImage = frame }
        }
        processor.onAutofocusPoints = { [weak self] points in
            DispatchQueue.main.async { self?.autofocusPoints = points }
        }
        return processor
    }()
    private var activeInput: AVCaptureDeviceInput?
    private var photoProcessor: PhotoCaptureProcessor?
    private var movieDelegate: MovieFileRecordingDelegate?
    private var audioInput: AVCaptureDeviceInput?
    private var isRecordingStartPending = false
    private var recordingStartedAt: Date?
    private var recordingTimer: Timer?

    func prepare() {
        reloadSavedMedia()
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            isAuthorized = true
            configureSession()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                Task { @MainActor in
                    guard let self else { return }
                    self.isAuthorized = granted
                    if granted {
                        self.configureSession()
                    } else {
                        self.errorMessage = "需要相机权限才能开始拍摄。"
                    }
                }
            }
        default:
            isAuthorized = false
            errorMessage = "请在系统设置中允许 POP CAM 使用相机。"
        }
    }

    private func configureSession() {
        let requestedPosition = cameraPosition
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.session.beginConfiguration()
            self.session.sessionPreset = .inputPriority

            guard let device = self.cameraDevice(position: requestedPosition),
                  let input = try? AVCaptureDeviceInput(device: device),
                  self.session.canAddInput(input) else {
                self.session.commitConfiguration()
                DispatchQueue.main.async { self.errorMessage = "无法启动相机，请检查设备权限。" }
                return
            }

            self.session.addInput(input)
            self.activeInput = input
            let initialDisplayZoom = self.setDefaultZoom(for: device)

            // Keep the camera in continuous AF/AE by default, as in a live-viewfinder camera.
            do {
                try device.lockForConfiguration()
                if device.isFocusModeSupported(.continuousAutoFocus) {
                    device.focusMode = .continuousAutoFocus
                }
                if device.isExposureModeSupported(.continuousAutoExposure) {
                    device.exposureMode = .continuousAutoExposure
                }
                device.unlockForConfiguration()
            } catch {
                // The camera can still operate with its current system focus settings.
            }

            if self.session.canAddOutput(self.photoOutput) {
                self.session.addOutput(self.photoOutput)
                self.photoOutput.maxPhotoQualityPrioritization = .quality
            }
            if self.session.canAddOutput(self.movieOutput) {
                self.session.addOutput(self.movieOutput)
            }

            self.videoOutput.alwaysDiscardsLateVideoFrames = true
            self.videoOutput.videoSettings = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
            ]
            self.videoOutput.setSampleBufferDelegate(self.liveProcessor, queue: self.videoQueue)
            if self.session.canAddOutput(self.videoOutput) {
                self.session.addOutput(self.videoOutput)
            }
            self.session.commitConfiguration()
            self.applyPortraitOrientation()
            self.session.startRunning()

            DispatchQueue.main.async {
                self.isReady = true
                self.zoomFactor = initialDisplayZoom
                self.errorMessage = nil
            }
        }
    }

    private func cameraDevice(position: AVCaptureDevice.Position) -> AVCaptureDevice? {
        if position == .back {
            // Prefer Apple's virtual multi-camera device. It lets AVFoundation
            // move between the ultra-wide and wide lenses without replacing the
            // capture input during a pinch gesture.
            if let triple = AVCaptureDevice.default(.builtInTripleCamera, for: .video, position: .back) {
                return triple
            }
            if let dualWide = AVCaptureDevice.default(.builtInDualWideCamera, for: .video, position: .back) {
                return dualWide
            }
        }
        return AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position)
    }

    private func displayZoomMultiplier(for device: AVCaptureDevice) -> CGFloat {
        if #available(iOS 18.0, *) {
            return max(device.displayVideoZoomFactorMultiplier, 0.01)
        }
        return 1.0
    }

    private func setDefaultZoom(for device: AVCaptureDevice) -> CGFloat {
        // Translate the user-facing 1x value into this device's native zoom
        // coordinate system. Virtual dual-wide cameras can use a 0.5 display
        // multiplier, where native 2.0 is the actual 1x wide-lens field of view.
        let multiplier = displayZoomMultiplier(for: device)
        let requestedHardwareZoom = 1.0 / multiplier
        let target = min(
            max(requestedHardwareZoom, device.minAvailableVideoZoomFactor),
            device.maxAvailableVideoZoomFactor
        )

        do {
            try device.lockForConfiguration()
            device.cancelVideoZoomRamp()
            device.videoZoomFactor = target
            device.unlockForConfiguration()
            return target * multiplier
        } catch {
            return device.videoZoomFactor * multiplier
        }
    }

    /// The iPhone 12 mini can record 4K60 on its physical wide camera.
    /// The dual-wide virtual camera doesn't expose the same high-frame-rate
    /// format set, so use the physical wide camera for 4K60 SDR and retain the
    /// virtual dual-wide camera for modes that benefit from the 0.5x lens.
    private func videoDevice(
        resolution: String,
        frameRate: Int,
        hdrEnabled: Bool
    ) -> AVCaptureDevice? {
        let requiresPhysicalWide = cameraPosition == .back &&
            resolution == "4K" &&
            frameRate >= 50 &&
            !hdrEnabled

        let desiredDevice: AVCaptureDevice?
        if requiresPhysicalWide {
            desiredDevice = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
        } else {
            desiredDevice = cameraDevice(position: cameraPosition)
        }

        guard let desiredDevice else { return activeInput?.device }
        if activeInput?.device.uniqueID == desiredDevice.uniqueID {
            return desiredDevice
        }

        guard let oldInput = activeInput,
              let newInput = try? AVCaptureDeviceInput(device: desiredDevice) else {
            return activeInput?.device
        }

        session.beginConfiguration()
        session.removeInput(oldInput)
        if session.canAddInput(newInput) {
            session.addInput(newInput)
            activeInput = newInput
            session.commitConfiguration()
            applyPortraitOrientation()

            let displayZoom = setDefaultZoom(for: desiredDevice)
            DispatchQueue.main.async {
                self.zoomFactor = displayZoom
            }
            return desiredDevice
        } else {
            session.addInput(oldInput)
            session.commitConfiguration()
            return oldInput.device
        }
    }

    private func applyPortraitOrientation() {
        for output in [videoOutput, photoOutput, movieOutput] {
            guard let connection = output.connection(with: .video) else { continue }
            if connection.isVideoRotationAngleSupported(90) {
                connection.videoRotationAngle = 90
            } else if connection.isVideoOrientationSupported {
                connection.videoOrientation = .portrait
            }
        }
    }

    func switchCamera() {
        let nextPosition: AVCaptureDevice.Position = cameraPosition == .back ? .front : .back
        sessionQueue.async { [weak self] in
            guard let self,
                  let oldInput = self.activeInput,
                  let device = self.cameraDevice(position: nextPosition),
                  let newInput = try? AVCaptureDeviceInput(device: device) else { return }

            self.session.beginConfiguration()
            self.session.removeInput(oldInput)
            if self.session.canAddInput(newInput) {
                self.session.addInput(newInput)
                self.activeInput = newInput
                let displayZoom = self.setDefaultZoom(for: device)
                DispatchQueue.main.async {
                    self.cameraPosition = device.position
                    self.flashEnabled = false
                    self.zoomFactor = displayZoom
                }
            } else {
                self.session.addInput(oldInput)
            }
            self.session.commitConfiguration()
            self.applyPortraitOrientation()
        }
    }

    func configureVideo(resolution: String, frameRate: Int, hdrEnabled: Bool) {
        guard isReady, !isVideoConfigurationInProgress, !isRecordingStartPending else { return }
        isVideoConfigurationInProgress = true

        sessionQueue.async { [weak self] in
            guard let self else { return }
            guard !self.movieOutput.isRecording,
                  let device = self.videoDevice(
                    resolution: resolution,
                    frameRate: frameRate,
                    hdrEnabled: hdrEnabled
                  ) else {
                DispatchQueue.main.async { self.isVideoConfigurationInProgress = false }
                return
            }

            self.applyVideoConfiguration(
                device: device,
                resolution: resolution,
                frameRate: frameRate,
                hdrEnabled: hdrEnabled
            )
        }
    }

    @discardableResult
    private func applyVideoConfiguration(
        device: AVCaptureDevice,
        resolution: String,
        frameRate: Int,
        hdrEnabled: Bool,
        reportsErrors: Bool = true
    ) -> Bool {
        let requestedResolution = resolution == "4K" ? "4K" : "1080P"
        let requestedDimensions = requestedResolution == "4K"
            ? (width: 3840, height: 2160)
            : (width: 1920, height: 1080)
        let requestedFPS = Double(max(24, min(frameRate, 60)))

        // AVFoundation raises NSInvalidArgumentException (not a Swift Error)
        // when a frame duration falls outside the selected format's exact range.
        // Preserve the duration supplied by AVFrameRateRange at either boundary,
        // and use exact rational 1/30 or 1/60 values for the common interior rates.
        let candidates = device.formats.compactMap { format -> (
            format: AVCaptureDevice.Format,
            dimensions: CMVideoDimensions,
            range: AVFrameRateRange,
            supportsFPS: Bool,
            supportsHDR: Bool,
            actualFPS: Double,
            frameDuration: CMTime
        )? in
            let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            let width = max(dimensions.width, dimensions.height)
            let height = min(dimensions.width, dimensions.height)
            guard width >= requestedDimensions.width,
                  height >= requestedDimensions.height else { return nil }

            let ranges = format.videoSupportedFrameRateRanges
            guard !ranges.isEmpty else { return nil }

            // Many cameras advertise nominal 60 FPS as 59.94 FPS. Accept
            // a half-FPS tolerance so this format is not mistaken for 30 FPS.
            let matchingRange = ranges.first {
                let clamped = min(max(requestedFPS, $0.minFrameRate), $0.maxFrameRate)
                return abs(clamped - requestedFPS) < 0.5
            }
            let selectedRange = matchingRange ?? ranges.min {
                let lhs = abs(min(max(requestedFPS, $0.minFrameRate), $0.maxFrameRate) - requestedFPS)
                let rhs = abs(min(max(requestedFPS, $1.minFrameRate), $1.maxFrameRate) - requestedFPS)
                return lhs < rhs
            }!

            let actualFPS = min(max(requestedFPS, selectedRange.minFrameRate), selectedRange.maxFrameRate)
            let frameDuration: CMTime
            if abs(actualFPS - selectedRange.maxFrameRate) < 0.02 {
                frameDuration = selectedRange.minFrameDuration
            } else if abs(actualFPS - selectedRange.minFrameRate) < 0.02 {
                frameDuration = selectedRange.maxFrameDuration
            } else if abs(actualFPS - actualFPS.rounded()) < 0.01 {
                frameDuration = CMTime(value: 1, timescale: CMTimeScale(Int(actualFPS.rounded())))
            } else {
                frameDuration = selectedRange.minFrameDuration
            }

            guard frameDuration.isValid, !frameDuration.isIndefinite else { return nil }

            return (
                format: format,
                dimensions: dimensions,
                range: selectedRange,
                supportsFPS: matchingRange != nil,
                supportsHDR: format.isVideoHDRSupported,
                actualFPS: actualFPS,
                frameDuration: frameDuration
            )
        }.sorted { lhs, rhs in
            if lhs.supportsFPS != rhs.supportsFPS {
                return lhs.supportsFPS && !rhs.supportsFPS
            }
            // Rank the closest achievable frame rate before HDR capability.
            // An HDR-capable format can still capture SDR when HDR is disabled.
            let lhsFPSDistance = abs(lhs.actualFPS - requestedFPS)
            let rhsFPSDistance = abs(rhs.actualFPS - requestedFPS)
            if abs(lhsFPSDistance - rhsFPSDistance) > 0.01 {
                return lhsFPSDistance < rhsFPSDistance
            }
            if lhs.supportsHDR != rhs.supportsHDR {
                return hdrEnabled ? lhs.supportsHDR : !lhs.supportsHDR
            }
            let lhsArea = Int64(lhs.dimensions.width) * Int64(lhs.dimensions.height)
            let rhsArea = Int64(rhs.dimensions.width) * Int64(rhs.dimensions.height)
            if lhsArea != rhsArea { return lhsArea < rhsArea }
            return lhs.actualFPS > rhs.actualFPS
        }

        guard let chosen = candidates.first else {
            DispatchQueue.main.async {
                self.isVideoConfigurationInProgress = false
                if reportsErrors {
                    self.errorMessage = "当前镜头没有可用的 \(requestedResolution) 视频格式，请尝试 1080P 或 30 FPS。"
                }
            }
            return false
        }

        // Validate the exact rational duration against this exact format before
        // touching AVCaptureDevice's Objective-C properties.
        let durationIsSupported =
            CMTimeCompare(chosen.frameDuration, chosen.range.minFrameDuration) >= 0 &&
            CMTimeCompare(chosen.frameDuration, chosen.range.maxFrameDuration) <= 0
        guard durationIsSupported else {
            DispatchQueue.main.async {
                self.isVideoConfigurationInProgress = false
                if reportsErrors {
                    self.errorMessage = "当前视频格式不接受所选帧率，请切换到 30 FPS 或 1080P。"
                }
            }
            return false
        }

        session.beginConfiguration()
        var configurationError: Error?
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }

            // Turn HDR off while the previous format still supports it.
            // Otherwise switching from HDR to an SDR-only 4K60 format can leave
            // the device's HDR flag stale and prevent the requested frame mode
            // from being applied reliably.
            if !hdrEnabled, device.activeFormat.isVideoHDRSupported, device.isVideoHDREnabled {
                device.automaticallyAdjustsVideoHDREnabled = false
                device.isVideoHDREnabled = false
            }

            if device.activeFormat !== chosen.format {
                device.activeFormat = chosen.format
            }

            // Disable automatic frame-rate changes before applying a fixed
            // duration; iOS may re-enable this after activeFormat changes.
            if #available(iOS 18.0, *), device.isAutoVideoFrameRateEnabled {
                device.isAutoVideoFrameRateEnabled = false
            }

            if chosen.supportsHDR {
                device.automaticallyAdjustsVideoHDREnabled = false
                if device.isVideoHDREnabled != hdrEnabled {
                    device.isVideoHDREnabled = hdrEnabled
                }
            }

            // Fixed min/max durations are both required for a stable 59.94/60 FPS.
            device.activeVideoMinFrameDuration = chosen.frameDuration
            device.activeVideoMaxFrameDuration = chosen.frameDuration
        } catch {
            configurationError = error
        }
        session.commitConfiguration()

        if let configurationError {
            DispatchQueue.main.async {
                self.isVideoConfigurationInProgress = false
                if reportsErrors {
                    self.errorMessage = "无法应用视频参数：\(configurationError.localizedDescription)"
                }
            }
            return false
        }

        let actualResolution = max(chosen.dimensions.width, chosen.dimensions.height) >= 3840
            ? "4K"
            : "1080P"
        let actualFrameRate = Int((1.0 / CMTimeGetSeconds(chosen.frameDuration)).rounded())
        let actualHDR = hdrEnabled && chosen.supportsHDR && device.isVideoHDREnabled
        let description = "\(actualResolution) · \(actualFrameRate) FPS" + (actualHDR ? " · HDR" : "")

        DispatchQueue.main.async {
            self.isVideoConfigurationInProgress = false
            self.appliedResolution = actualResolution
            self.appliedFrameRate = actualFrameRate
            self.appliedHDR = actualHDR
            self.appliedVideoDescription = description
            self.videoConfigurationRevision &+= 1

            let needsFallback =
                actualResolution != requestedResolution ||
                actualFrameRate != Int(requestedFPS) ||
                actualHDR != hdrEnabled

            if needsFallback && reportsErrors {
                self.errorMessage = "设备不支持所选组合，已自动调整为 \(description)。"
            } else if reportsErrors {
                self.errorMessage = nil
            }
        }

        // Keep AVCaptureMovieFileOutput on its system-selected encoder settings.
        // Passing an unsupported AVVideoCodecKey is an Objective-C exception,
        // so avoid overriding the output's settings during live reconfiguration.
        return true
    }

    func startRecording(resolution: String, frameRate: Int, hdrEnabled: Bool) {
        guard isReady, !isRecording, !isRecordingStartPending else { return }
        guard !isVideoConfigurationInProgress else { return }
        isRecordingStartPending = true
        isVideoConfigurationInProgress = true

        let beginRecording: (Bool) -> Void = { [weak self] microphoneGranted in
            guard let self else { return }
            self.sessionQueue.async {
                guard !self.movieOutput.isRecording,
                      self.session.isRunning,
                      let device = self.videoDevice(
                        resolution: resolution,
                        frameRate: frameRate,
                        hdrEnabled: hdrEnabled
                      ) else {
                    DispatchQueue.main.async {
                        self.isVideoConfigurationInProgress = false
                        self.isRecordingStartPending = false
                    }
                    return
                }

                guard self.applyVideoConfiguration(
                    device: device,
                    resolution: resolution,
                    frameRate: frameRate,
                    hdrEnabled: hdrEnabled,
                    reportsErrors: false
                ) else {
                    DispatchQueue.main.async { self.isRecordingStartPending = false }
                    return
                }

                if microphoneGranted, self.audioInput == nil,
                   let audioDevice = AVCaptureDevice.default(for: .audio),
                   let input = try? AVCaptureDeviceInput(device: audioDevice),
                   self.session.canAddInput(input) {
                    self.session.beginConfiguration()
                    self.session.addInput(input)
                    self.audioInput = input
                    self.session.commitConfiguration()
                    self.applyPortraitOrientation()
                }

                guard let connection = self.movieOutput.connection(with: .video),
                      connection.isEnabled else {
                    DispatchQueue.main.async {
                        self.isRecordingStartPending = false
                    }
                    return
                }

                // 4K60 is a high-data-rate capture mode and requires HEVC on
                // supported iPhone formats. Select it explicitly instead of
                // relying on the output's default codec choice.
                if resolution == "4K", frameRate >= 50 {
                    let supportedKeys = self.movieOutput.supportedOutputSettingsKeys(for: connection)
                    guard self.movieOutput.availableVideoCodecTypes.contains(.hevc),
                          supportedKeys.contains(AVVideoCodecKey) else {
                        DispatchQueue.main.async {
                            self.isVideoConfigurationInProgress = false
                            self.isRecordingStartPending = false
                            self.errorMessage = "当前录像输出不支持 HEVC，无法录制 4K 60 FPS。"
                        }
                        return
                    }
                    self.movieOutput.setOutputSettings([AVVideoCodecKey: AVVideoCodecType.hevc], for: connection)
                }

                let url = FileManager.default.temporaryDirectory
                    .appendingPathComponent("POPCAM-\(UUID().uuidString).mov")
                let delegate = MovieFileRecordingDelegate { [weak self] outputURL, error in
                    guard let self else { return }
                    Task { @MainActor in
                        self.finishRecording(at: outputURL, error: error)
                    }
                }
                self.movieDelegate = delegate
                self.movieOutput.startRecording(to: url, recordingDelegate: delegate)

                DispatchQueue.main.async {
                    self.isRecordingStartPending = false
                    self.isRecording = true
                    self.recordingStartedAt = Date()
                    self.recordingDuration = 0
                    self.recordingTimer?.invalidate()
                    self.recordingTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
                        guard let self, let started = self.recordingStartedAt else { return }
                        self.recordingDuration = Date().timeIntervalSince(started)
                    }
                }
            }
        }

        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            beginRecording(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in beginRecording(granted) }
        default:
            beginRecording(false)
        }
    }

    func stopRecording() {
        sessionQueue.async { [weak self] in
            guard let self, self.movieOutput.isRecording else { return }
            self.movieOutput.stopRecording()
        }
    }

    private func finishRecording(at url: URL, error: Error?) {
        DispatchQueue.main.async {
            self.isRecording = false
            self.isRecordingStartPending = false
            self.recordingTimer?.invalidate()
            self.recordingTimer = nil
            self.recordingStartedAt = nil
            self.movieDelegate = nil
        }

        guard error == nil else {
            try? FileManager.default.removeItem(at: url)
            return
        }

        do {
            let destinationFolder = try appAlbumDirectory()
            let timestamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
            let filename = "POP_\(timestamp)_\(UUID().uuidString.prefix(6)).mov"
            let destinationURL = destinationFolder.appendingPathComponent(filename)
            try FileManager.default.moveItem(at: url, to: destinationURL)
            reloadSavedMedia()
        } catch {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func appAlbumDirectory() throws -> URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let directory = documents.appendingPathComponent("POP CAM Album", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    func reloadSavedMedia() {
        do {
            let directory = try appAlbumDirectory()
            let urls = try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.creationDateKey, .fileSizeKey],
                options: [.skipsHiddenFiles]
            )
            .filter {
                ["mov", "mp4", "jpg", "jpeg", "png", "heic"].contains($0.pathExtension.lowercased())
            }
            .sorted {
                let first = (try? $0.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                let second = (try? $1.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                return first > second
            }

            let videos = urls.filter { ["mov", "mp4"].contains($0.pathExtension.lowercased()) }
            let photos = urls.filter { ["jpg", "jpeg", "png", "heic"].contains($0.pathExtension.lowercased()) }
            DispatchQueue.main.async {
                self.savedMediaURLs = urls
                self.savedVideoURLs = videos
                self.savedPhotoURLs = photos
            }
        } catch {
            DispatchQueue.main.async {
                self.savedMediaURLs = []
                self.savedVideoURLs = []
                self.savedPhotoURLs = []
            }
        }
    }

    func deleteAlbumMedia(at url: URL) {
        do {
            let directory = try appAlbumDirectory().standardizedFileURL
            let file = url.standardizedFileURL
            guard file.deletingLastPathComponent() == directory else {
                errorMessage = "无法删除相册目录以外的文件。"
                return
            }
            try FileManager.default.removeItem(at: file)
            reloadSavedMedia()
        } catch {
            errorMessage = "删除失败：\(error.localizedDescription)"
        }
    }

    func capturePhoto() {
        guard isReady else { return }
        let settings = AVCapturePhotoSettings()
        settings.photoQualityPrioritization = .quality
        if flashEnabled, let device = activeInput?.device, device.hasFlash {
            settings.flashMode = .on
        }
        let processor = PhotoCaptureProcessor { [weak self] image in
            DispatchQueue.main.async {
                guard let self, let image else {
                    self?.errorMessage = "拍摄失败，请再试一次。"
                    return
                }
                self.capturedImage = self.selectedFilter.apply(to: image)
                self.captureID += 1
            }
        }
        photoProcessor = processor
        photoOutput.capturePhoto(with: settings, delegate: processor)
    }

    func setAutofocusVisualizationEnabled(_ enabled: Bool) {
        liveProcessor.isAutofocusVisualizationEnabled = enabled
        if !enabled {
            autofocusPoints = []
        }
    }

    func focus(at point: CGPoint) {
        let normalized = CGPoint(
            x: min(max(point.x, 0), 1),
            y: min(max(point.y, 0), 1)
        )
        // AVCaptureDevice focus/exposure POI always uses the unrotated
        // landscape sensor coordinate system (home button on the right).
        // The viewfinder is portrait, so rotate the tap point into sensor space.
        let devicePoint = CGPoint(x: normalized.y, y: 1 - normalized.x)

        sessionQueue.async { [weak self] in
            guard let self, let device = self.activeInput?.device else { return }
            do {
                try device.lockForConfiguration()
                defer { device.unlockForConfiguration() }

                if device.isFocusPointOfInterestSupported {
                    device.focusPointOfInterest = devicePoint
                }
                if device.isExposurePointOfInterestSupported {
                    device.exposurePointOfInterest = devicePoint
                }

                let canAutofocus: Bool
                if device.isFocusModeSupported(.autoFocus) {
                    // Explicit one-shot autofocus reliably starts a new focus
                    // operation even when continuous AF was already selected.
                    device.focusMode = .autoFocus
                    canAutofocus = true
                } else if device.isFocusModeSupported(.continuousAutoFocus) {
                    device.focusMode = .continuousAutoFocus
                    canAutofocus = true
                } else {
                    canAutofocus = false
                }
                device.isSubjectAreaChangeMonitoringEnabled = canAutofocus

                if device.isExposureModeSupported(.autoExpose) {
                    device.exposureMode = .autoExpose
                } else if device.isExposureModeSupported(.continuousAutoExposure) {
                    device.exposureMode = .continuousAutoExposure
                }

                DispatchQueue.main.async {
                    self.isExposureFocusLocked = false
                    self.focusStatus = canAutofocus ? .focusing : .unavailable
                }

                guard canAutofocus else { return }
                self.monitorFocusSettling(device: device, startedAt: ProcessInfo.processInfo.systemUptime)
            } catch {
                // Keep focus feedback inline in the viewfinder; do not present an alert.
                DispatchQueue.main.async {
                    self.focusStatus = .unavailable
                }
            }
        }
    }

    private func monitorFocusSettling(device: AVCaptureDevice, startedAt: TimeInterval) {
        sessionQueue.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            guard let self,
                  self.activeInput?.device.uniqueID == device.uniqueID else { return }

            let elapsed = ProcessInfo.processInfo.systemUptime - startedAt
            // Give the autofocus system time to begin moving before treating
            // a stable lens position as a completed focus attempt.
            if elapsed >= 0.35 && !device.isAdjustingFocus {
                do {
                    try device.lockForConfiguration()
                    if device.isFocusModeSupported(.continuousAutoFocus) {
                        device.focusMode = .continuousAutoFocus
                    }
                    device.isSubjectAreaChangeMonitoringEnabled = true
                    device.unlockForConfiguration()
                } catch {
                    // Keep the completed one-shot focus even if continuous
                    // tracking cannot be re-enabled on this capture format.
                }
                DispatchQueue.main.async {
                    self.focusStatus = .focused
                }
            } else if elapsed >= 3.0 {
                DispatchQueue.main.async {
                    self.focusStatus = .unavailable
                }
            } else {
                self.monitorFocusSettling(device: device, startedAt: startedAt)
            }
        }
    }

    func setExposureFocusLocked(_ locked: Bool) {
        sessionQueue.async { [weak self] in
            guard let self, let device = self.activeInput?.device else { return }
            do {
                try device.lockForConfiguration()
                if locked {
                    if device.isFocusModeSupported(.locked) {
                        device.focusMode = .locked
                    }
                    if device.isExposureModeSupported(.locked) {
                        device.exposureMode = .locked
                    }
                } else {
                    if device.isFocusModeSupported(.continuousAutoFocus) {
                        device.focusMode = .continuousAutoFocus
                    }
                    if device.isExposureModeSupported(.continuousAutoExposure) {
                        device.exposureMode = .continuousAutoExposure
                    }
                }
                device.unlockForConfiguration()
                DispatchQueue.main.async { self.isExposureFocusLocked = locked }
            } catch {
                DispatchQueue.main.async {
                    self.errorMessage = "暂时无法锁定对焦与曝光。"
                    self.isExposureFocusLocked = false
                }
            }
        }
    }

    func setZoom(_ value: CGFloat, animated: Bool = true) {
        sessionQueue.async { [weak self] in
            guard let self, let device = self.activeInput?.device else { return }

            // UI zoom is the native factor multiplied by Apple's presentation
            // multiplier. Convert in both directions so a virtual camera's
            // 0.5x ultra-wide base is never mislabeled as 1x.
            let multiplier = displayZoomMultiplier(for: device)
            let requestedHardwareZoom = value / multiplier
            let hardwareZoom = min(
                max(requestedHardwareZoom, device.minAvailableVideoZoomFactor),
                min(CGFloat(10) / multiplier, device.maxAvailableVideoZoomFactor)
            )
            let displayZoom = hardwareZoom * multiplier

            do {
                try device.lockForConfiguration()
                device.cancelVideoZoomRamp()

                if animated {
                    let distance = abs(hardwareZoom - device.videoZoomFactor)
                    let rate = Float(min(max(3.5 + distance * 2.2, 4), 14))
                    device.ramp(toVideoZoomFactor: hardwareZoom, withRate: rate)
                } else {
                    device.videoZoomFactor = hardwareZoom
                }

                device.unlockForConfiguration()
                DispatchQueue.main.async {
                    self.zoomFactor = displayZoom
                }
            } catch {
                DispatchQueue.main.async {
                    self.errorMessage = "暂时无法调整变焦。"
                }
            }
        }
    }

    func setExposure(_ value: Float) {
        let bias = min(max(value, -2), 2)
        exposureBias = bias
        sessionQueue.async { [weak self] in
            guard let self, let device = self.activeInput?.device else { return }
            do {
                try device.lockForConfiguration()
                device.setExposureTargetBias(bias)
                device.unlockForConfiguration()
            } catch {
                DispatchQueue.main.async { self.errorMessage = "暂时无法调整曝光。" }
            }
        }
    }

    func saveCapturedPhoto(completion: @escaping (Bool) -> Void) {
        guard let image = capturedImage else {
            completion(false)
            return
        }
        savePhoto(image, completion: completion)
    }

    func savePhoto(_ image: UIImage, completion: @escaping (Bool) -> Void) {
        do {
            let directory = try appAlbumDirectory()
            guard let data = image.jpegData(compressionQuality: 0.96) else {
                completion(false)
                return
            }
            let timestamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
            let filename = "POP_PHOTO_\(timestamp)_\(UUID().uuidString.prefix(6)).jpg"
            let destination = directory.appendingPathComponent(filename)
            try data.write(to: destination, options: .atomic)
            reloadSavedMedia()
            completion(true)
        } catch {
            DispatchQueue.main.async {
                self.errorMessage = "保存照片到 POP CAM 相册失败：\(error.localizedDescription)"
                completion(false)
            }
        }
    }
}
private final class MovieFileRecordingDelegate: NSObject, AVCaptureFileOutputRecordingDelegate {
    private let completion: (URL, Error?) -> Void

    init(completion: @escaping (URL, Error?) -> Void) {
        self.completion = completion
    }

    func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL, from connections: [AVCaptureConnection], error: Error?) {
        completion(outputFileURL, error)
    }
}

