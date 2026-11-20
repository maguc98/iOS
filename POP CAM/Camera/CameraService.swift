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
        reloadSavedVideos()
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
        sessionQueue.async { [weak self] in
            guard let self, let device = self.activeInput?.device, !self.movieOutput.isRecording else { return }
            self.applyVideoConfiguration(device: device, resolution: resolution, frameRate: frameRate, hdrEnabled: hdrEnabled)
        }
    }

    private func applyVideoConfiguration(device: AVCaptureDevice, resolution: String, frameRate: Int, hdrEnabled: Bool) {
        let target = resolution == "4K" ? (width: 3840, height: 2160) : (width: 1920, height: 1080)
        let requestedFPS = Double(frameRate)
        let candidates = device.formats.compactMap { format -> (AVCaptureDevice.Format, Bool, Int32)? in
            let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            guard dimensions.width >= target.width, dimensions.height >= target.height else { return nil }
            let supportsFPS = format.videoSupportedFrameRateRanges.contains {
                $0.minFrameRate <= requestedFPS && $0.maxFrameRate >= requestedFPS
            }
            let supportsHDR = format.isVideoHDRSupported
            return (format, supportsFPS, dimensions.width)
        }.sorted {
            if $0.1 != $1.1 { return $0.1 && !$1.1 }
            if hdrEnabled && $0.0.isVideoHDRSupported != $1.0.isVideoHDRSupported {
                return $0.0.isVideoHDRSupported
            }
            return $0.2 < $1.2
        }

        guard let chosen = candidates.first else {
            DispatchQueue.main.async { self.errorMessage = "当前镜头不支持所选视频规格，请尝试 1080P 或 30 FPS。" }
            return
        }

        do {
            try device.lockForConfiguration()
            device.activeFormat = chosen.0
            let actualFPS = chosen.1 ? requestedFPS : min(30, chosen.0.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 30)
            let frameDuration = CMTime(value: 1, timescale: CMTimeScale(actualFPS))
            device.activeVideoMinFrameDuration = frameDuration
            device.activeVideoMaxFrameDuration = frameDuration

            let useHDR = hdrEnabled && chosen.0.isVideoHDRSupported
            if device.isVideoHDREnabled != useHDR {
                device.isVideoHDREnabled = useHDR
            }
            device.unlockForConfiguration()

            if let connection = movieOutput.connection(with: .video),
               movieOutput.availableVideoCodecTypes.contains(.hevc) {
                movieOutput.setOutputSettings([AVVideoCodecKey: AVVideoCodecType.hevc], for: connection)
            }

            let dimensions = CMVideoFormatDescriptionGetDimensions(chosen.0.formatDescription)
            let actualResolution = dimensions.width >= 3840 && dimensions.height >= 2160 ? "4K" : "1080P"
            DispatchQueue.main.async {
                self.appliedVideoDescription = "\(actualResolution) · \(Int(actualFPS)) FPS" + (useHDR ? " · HDR" : "")
                if actualFPS != requestedFPS || (hdrEnabled && !useHDR) {
                    self.errorMessage = "设备不支持完整组合，已自动调整为 \(self.appliedVideoDescription)。"
                } else {
                    self.errorMessage = nil
                }
            }
        } catch {
            DispatchQueue.main.async { self.errorMessage = "无法应用视频参数：\(error.localizedDescription)" }
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
            reloadSavedVideos()
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

    func reloadSavedVideos() {
        do {
            let directory = try appAlbumDirectory()
            let urls = try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.creationDateKey, .fileSizeKey],
                options: [.skipsHiddenFiles]
            )
            .filter { $0.pathExtension.lowercased() == "mov" }
            .sorted {
                let first = (try? $0.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                let second = (try? $1.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                return first > second
            }
            DispatchQueue.main.async { self.savedVideoURLs = urls }
        } catch {
            DispatchQueue.main.async { self.savedVideoURLs = [] }
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
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else {
                DispatchQueue.main.async { completion(false) }
                return
            }
            PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.creationRequestForAsset(from: image)
            } completionHandler: { success, _ in
                DispatchQueue.main.async { completion(success) }
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

