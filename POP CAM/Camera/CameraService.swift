import AVFoundation
import Photos
import SwiftUI
import UIKit

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
    @Published var capturedImage: UIImage?
    @Published var captureID = 0
    @Published var errorMessage: String?

    let session = AVCaptureSession()
    private let photoOutput = AVCapturePhotoOutput()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let sessionQueue = DispatchQueue(label: "com.maguc98.popcam.session")
    private let videoQueue = DispatchQueue(label: "com.maguc98.popcam.video")
    private lazy var liveProcessor: LivePreviewProcessor = {
        let processor = LivePreviewProcessor()
        processor.onFrame = { [weak self] frame in
            DispatchQueue.main.async { self?.previewImage = frame }
        }
        return processor
    }()
    private var activeInput: AVCaptureDeviceInput?
    private var photoProcessor: PhotoCaptureProcessor?

    func prepare() {
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
            self.session.sessionPreset = .photo

            guard let device = self.cameraDevice(position: requestedPosition),
                  let input = try? AVCaptureDeviceInput(device: device),
                  self.session.canAddInput(input) else {
                self.session.commitConfiguration()
                DispatchQueue.main.async { self.errorMessage = "无法启动相机，请检查设备权限。" }
                return
            }

            self.session.addInput(input)
            self.activeInput = input

            if self.session.canAddOutput(self.photoOutput) {
                self.session.addOutput(self.photoOutput)
                self.photoOutput.maxPhotoQualityPrioritization = .quality
            }

            self.videoOutput.alwaysDiscardsLateVideoFrames = true
            self.videoOutput.videoSettings = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
            ]
            self.videoOutput.setSampleBufferDelegate(self.liveProcessor, queue: self.videoQueue)
            if self.session.canAddOutput(self.videoOutput) {
                self.session.addOutput(self.videoOutput)
                if let connection = self.videoOutput.connection(with: .video),
                   connection.isVideoOrientationSupported {
                    connection.videoOrientation = .portrait
                }
            }
            self.session.commitConfiguration()
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
                if let connection = self.videoOutput.connection(with: .video),
                   connection.isVideoOrientationSupported {
                    connection.videoOrientation = .portrait
                }
                DispatchQueue.main.async {
                    self.cameraPosition = device.position
                    self.flashEnabled = false
                    self.zoomFactor = 1
                }
            } else {
                self.session.addInput(oldInput)
            }
            self.session.commitConfiguration()
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

    func focus(at point: CGPoint) {
        let normalized = CGPoint(
            x: min(max(point.x, 0), 1),
            y: min(max(point.y, 0), 1)
        )
        sessionQueue.async { [weak self] in
            guard let self, let device = self.activeInput?.device else { return }
            do {
                try device.lockForConfiguration()
                if device.isFocusPointOfInterestSupported {
                    device.focusPointOfInterest = normalized
                    if device.isFocusModeSupported(.autoFocus) {
                        device.focusMode = .autoFocus
                    } else if device.isFocusModeSupported(.continuousAutoFocus) {
                        device.focusMode = .continuousAutoFocus
                    }
                }
                if device.isExposurePointOfInterestSupported {
                    device.exposurePointOfInterest = normalized
                    if device.isExposureModeSupported(.continuousAutoExposure) {
                        device.exposureMode = .continuousAutoExposure
                    } else if device.isExposureModeSupported(.autoExpose) {
                        device.exposureMode = .autoExpose
                    }
                }
                device.unlockForConfiguration()
            } catch {
                DispatchQueue.main.async {
                    self.errorMessage = "暂时无法对焦，请再试一次。"
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
                        return
                    }
                    self.session.addInput(targetInput)
                    self.activeInput = targetInput
                    self.session.commitConfiguration()
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