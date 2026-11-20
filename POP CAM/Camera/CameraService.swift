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
    @Published private(set) var appliedVideoDescription = "4K · 60 FPS"
    @Published private(set) var savedVideoURLs: [URL] = []
    @Published private(set) var savedPhotoURLs: [URL] = []
    @Published private(set) var savedMediaURLs: [URL] = []
    @Published private(set) var isVideoConfigurationInProgress = false
    @Published private(set) var appliedHDR = false
    @Published private(set) var appliedFrameRate = 30
    @Published private(set) var appliedResolution = "1080P"

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
                self.errorMessage = nil
            }
        }
    }

    private func cameraDevice(position: AVCaptureDevice.Position) -> AVCaptureDevice? {
        AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position)
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
                DispatchQueue.main.async {
                    self.cameraPosition = device.position
                    self.flashEnabled = false
                    self.zoomFactor = 1
                }
            } else {
                self.session.addInput(oldInput)
            }
            self.session.commitConfiguration()
            self.applyPortraitOrientation()
        }
    }

    func configureVideo(resolution: String, frameRate: Int, hdrEnabled: Bool) {
        guard isReady else { return }
        isVideoConfigurationInProgress = true
        sessionQueue.async { [weak self] in
            guard let self else { return }
            guard let device = self.activeInput?.device, !self.movieOutput.isRecording else {
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

    private func applyVideoConfiguration(
        device: AVCaptureDevice,
        resolution: String,
        frameRate: Int,
        hdrEnabled: Bool
    ) {
        let requestedResolution = resolution == "4K" ? "4K" : "1080P"
        let requestedDimensions = requestedResolution == "4K"
            ? (width: 3840, height: 2160)
            : (width: 1920, height: 1080)
        let requestedFPS = Double(max(24, min(frameRate, 60)))

        let candidates = device.formats.compactMap { format -> (
            format: AVCaptureDevice.Format,
            dimensions: CMVideoDimensions,
            supportsFPS: Bool,
            supportsHDR: Bool,
            actualFPS: Double
        )? in
            let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            guard dimensions.width >= requestedDimensions.width,
                  dimensions.height >= requestedDimensions.height else { return nil }

            let ranges = format.videoSupportedFrameRateRanges
            guard !ranges.isEmpty else { return nil }

            let matchingRange = ranges.first {
                $0.minFrameRate <= requestedFPS && $0.maxFrameRate >= requestedFPS
            }
            let nearestRange = matchingRange ?? ranges.min {
                let lhs = abs(min(max(requestedFPS, $0.minFrameRate), $0.maxFrameRate) - requestedFPS)
                let rhs = abs(min(max(requestedFPS, $1.minFrameRate), $1.maxFrameRate) - requestedFPS)
                return lhs < rhs
            }!

            let actualFPS = min(max(requestedFPS, nearestRange.minFrameRate), nearestRange.maxFrameRate)
            return (
                format: format,
                dimensions: dimensions,
                supportsFPS: matchingRange != nil,
                supportsHDR: format.isVideoHDRSupported,
                actualFPS: actualFPS
            )
        }.sorted { lhs, rhs in
            if hdrEnabled && lhs.supportsHDR != rhs.supportsHDR {
                return lhs.supportsHDR && !rhs.supportsHDR
            }
            if lhs.supportsFPS != rhs.supportsFPS {
                return lhs.supportsFPS && !rhs.supportsFPS
            }
            let lhsArea = Int64(lhs.dimensions.width) * Int64(lhs.dimensions.height)
            let rhsArea = Int64(rhs.dimensions.width) * Int64(rhs.dimensions.height)
            if lhsArea != rhsArea { return lhsArea < rhsArea }
            return lhs.actualFPS > rhs.actualFPS
        }

        guard let chosen = candidates.first else {
            DispatchQueue.main.async {
                self.isVideoConfigurationInProgress = false
                self.errorMessage = "当前镜头没有可用的 \(requestedResolution) 视频格式，请尝试 1080P 或 30 FPS。"
            }
            return
        }

        let useHDR = hdrEnabled && chosen.supportsHDR
        let frameDuration = CMTime(
            seconds: 1.0 / max(1.0, chosen.actualFPS),
            preferredTimescale: 1_000_000_000
        )

        session.beginConfiguration()
        var configurationError: Error?
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }

            device.isAutoVideoFrameRateEnabled = false
            device.automaticallyAdjustsVideoHDREnabled = false
            if device.activeFormat !== chosen.format {
                device.activeFormat = chosen.format
            }

            device.activeVideoMinFrameDuration = frameDuration
            device.activeVideoMaxFrameDuration = frameDuration

            if chosen.format.isVideoHDRSupported {
                device.isVideoHDREnabled = useHDR
            } else if device.isVideoHDREnabled {
                device.isVideoHDREnabled = false
            }
        } catch {
            configurationError = error
        }
        session.commitConfiguration()

        if let configurationError {
            DispatchQueue.main.async {
                self.isVideoConfigurationInProgress = false
                self.errorMessage = "无法应用视频参数：\(configurationError.localizedDescription)"
            }
            return
        }

        let actualResolution = chosen.dimensions.width >= 3840 && chosen.dimensions.height >= 2160
            ? "4K"
            : "1080P"
        let actualFrameRate = Int(chosen.actualFPS.rounded())
        let description = "\(actualResolution) · \(actualFrameRate) FPS" + (useHDR ? " · HDR" : "")

        DispatchQueue.main.async {
            self.isVideoConfigurationInProgress = false
            self.appliedResolution = actualResolution
            self.appliedFrameRate = actualFrameRate
            self.appliedHDR = useHDR
            self.appliedVideoDescription = description

            let needsFallback =
                actualResolution != requestedResolution ||
                actualFrameRate != Int(requestedFPS) ||
                useHDR != hdrEnabled

            if needsFallback {
                self.errorMessage = "设备不支持所选组合，已自动调整为 \(description)。"
            } else {
                self.errorMessage = nil
            }
        }

        if let connection = movieOutput.connection(with: .video),
           movieOutput.availableVideoCodecTypes.contains(.hevc) {
            movieOutput.setOutputSettings([AVVideoCodecKey: AVVideoCodecType.hevc], for: connection)
        }
    }

    func startRecording(resolution: String, frameRate: Int, hdrEnabled: Bool) {
        guard isReady else { return }
        let beginRecording: (Bool) -> Void = { [weak self] microphoneGranted in
            guard let self else { return }
            self.sessionQueue.async {
                guard !self.movieOutput.isRecording, let device = self.activeInput?.device else { return }
                self.applyVideoConfiguration(device: device, resolution: resolution, frameRate: frameRate, hdrEnabled: hdrEnabled)

                if microphoneGranted, self.audioInput == nil,
                   let audioDevice = AVCaptureDevice.default(for: .audio),
                   let input = try? AVCaptureDeviceInput(device: audioDevice),
                   self.session.canAddInput(input) {
                    self.session.beginConfiguration()
                    self.session.addInput(input)
                    self.audioInput = input
                    self.session.commitConfiguration()
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
            DispatchQueue.main.async { self.errorMessage = "麦克风权限未开启，本次录像将没有声音。" }
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
            self.recordingTimer?.invalidate()
            self.recordingTimer = nil
            self.recordingStartedAt = nil
            self.movieDelegate = nil
        }

        guard error == nil else {
            try? FileManager.default.removeItem(at: url)
            DispatchQueue.main.async { self.errorMessage = "录像失败：\(error?.localizedDescription ?? "未知错误")" }
            return
        }

        do {
            let destinationFolder = try appAlbumDirectory()
            let timestamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
            let filename = "POP_\(timestamp)_\(UUID().uuidString.prefix(6)).mov"
            let destinationURL = destinationFolder.appendingPathComponent(filename)
            try FileManager.default.moveItem(at: url, to: destinationURL)
            reloadSavedMedia()
            DispatchQueue.main.async {
                self.errorMessage = "视频已保存到 POP CAM 相册。"
            }
        } catch {
            try? FileManager.default.removeItem(at: url)
            DispatchQueue.main.async {
                self.errorMessage = "保存到 POP CAM 相册失败：\(error.localizedDescription)"
            }
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
        sessionQueue.async { [weak self] in
            guard let self, let device = self.activeInput?.device else { return }
            do {
                try device.lockForConfiguration()
                defer { device.unlockForConfiguration() }

                if device.isFocusPointOfInterestSupported {
                    device.focusPointOfInterest = normalized
                }
                if device.isExposurePointOfInterestSupported {
                    device.exposurePointOfInterest = normalized
                }

                let canAutofocus: Bool
                if device.isFocusModeSupported(.continuousAutoFocus) {
                    // Retain continuous tracking after the user selects a focus point.
                    device.focusMode = .continuousAutoFocus
                    canAutofocus = true
                } else if device.isFocusModeSupported(.autoFocus) {
                    device.focusMode = .autoFocus
                    canAutofocus = true
                } else {
                    canAutofocus = false
                }

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

    func setZoom(_ value: CGFloat) {
        let wantsUltraWide = value < 1 && cameraPosition == .back
        let requestedZoom = wantsUltraWide ? 0.5 : min(max(value, 1), 5)
        zoomFactor = requestedZoom
        sessionQueue.async { [weak self] in
            guard let self, let oldInput = self.activeInput?.device else { return }
            let targetType: AVCaptureDevice.DeviceType = wantsUltraWide ? .builtInUltraWideCamera : .builtInWideAngleCamera
            guard let targetDevice = AVCaptureDevice.default(targetType, for: .video, position: self.cameraPosition),
                  let targetInput = try? AVCaptureDeviceInput(device: targetDevice) else { return }
            do {
                if oldInput.uniqueID != targetDevice.uniqueID {
                    self.session.beginConfiguration()
                    self.session.removeInput(self.activeInput!)
                    guard self.session.canAddInput(targetInput) else {
                        self.session.addInput(self.activeInput!)
                        self.session.commitConfiguration()
                        self.applyPortraitOrientation()
                        return
                    }
                    self.session.addInput(targetInput)
                    self.activeInput = targetInput
                    self.session.commitConfiguration()
                    self.applyPortraitOrientation()
                }
                try targetDevice.lockForConfiguration()
                targetDevice.videoZoomFactor = wantsUltraWide
                    ? 1
                    : min(requestedZoom, targetDevice.activeFormat.videoMaxZoomFactor)
                targetDevice.unlockForConfiguration()
                DispatchQueue.main.async { self.zoomFactor = requestedZoom }
            } catch {
                DispatchQueue.main.async { self.errorMessage = "暂时无法调整变焦。" }
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

