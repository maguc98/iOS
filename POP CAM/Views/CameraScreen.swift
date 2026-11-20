import AVFoundation
import AVKit
import CoreMotion
import CoreImage
import ImageIO
import SwiftUI
import UIKit

struct CameraScreen: View {
    @StateObject private var camera = CameraService()
    @AppStorage("popcam.macaronPalette") private var selectedPaletteID = "sakura"
    @StateObject private var levelMonitor = CameraLevelMonitor()
    @State private var timerSeconds = 0
    @State private var countdown: Int?
    @State private var showReview = false
    @State private var showAlbum = false
    @State private var showSettings = false
    @State private var activeTool: CameraToolMode = .filters
    @State private var isToolPanelExpanded = false
    @AppStorage("popcam.superResolutionEnabled") private var superResolutionEnabled = false
    @AppStorage("popcam.superResolutionScale") private var superResolutionScale = 2
    @AppStorage("popcam.videoStabilizationEnabled") private var videoStabilizationEnabled = true
    @AppStorage("popcam.stabilizationHUDEnabled") private var stabilizationHUDEnabled = true
    @AppStorage("popcam.stabilizationHUDX") private var stabilizationHUDX = 0.5
    @AppStorage("popcam.stabilizationHUDY") private var stabilizationHUDY = 0.20
    @AppStorage("popcam.motionStatusHUDEnabled") private var motionStatusHUDEnabled = true
    @AppStorage("popcam.motionStatusHUDX") private var motionStatusHUDX = 0.74
    @AppStorage("popcam.motionStatusHUDY") private var motionStatusHUDY = 0.72
    @State private var stabilizationHUDDragOrigin: CGPoint?
    @State private var motionStatusHUDDragOrigin: CGPoint?
    @State private var showGrid = false
    @State private var showLevel = false
    @State private var zoom: Double = 1
    @State private var pinchStartZoom: CGFloat?
    @State private var zoomDragStartValue: CGFloat?
    @State private var isZoomDragActive = false
    @State private var exposure: Double = 0
    @State private var manualFocusIndicatorPoint: CGPoint?
    @State private var manualFocusIndicatorID = 0
    @State private var selectedVideoResolution = "4K"
    @State private var selectedFrameRate = "30"
    @State private var hdrEnabled = true
    @State private var isSyncingVideoControls = false
    @State private var captureBarMode: CaptureBarMode = .video
    @State private var isCaptureBarCollapsed = false

    private var selectedPalette: MacaronPalette {
        MacaronPalette.all.first(where: { $0.id == selectedPaletteID }) ?? MacaronPalette.all[0]
    }

    private func updateMotionMonitoring() {
        if showLevel || stabilizationHUDEnabled || motionStatusHUDEnabled {
            levelMonitor.start()
        } else {
            levelMonitor.stop()
        }
    }

    var body: some View {
        ZStack {
            // Soft macaron canvas fills everything outside the live viewfinder.
            Color(hex: selectedPalette.background[0])
                .ignoresSafeArea()

            // Keep the live camera image strictly inside the viewfinder window.
            // The surrounding area remains the macaron-colored app canvas.
            GeometryReader { previewGeometry in
                let width = previewGeometry.size.width * 0.86
                let height = min(width * 4 / 3, previewGeometry.size.height * 0.60)
                let cornerRadius: CGFloat = 28
                let centerX = previewGeometry.size.width / 2
                let centerY = previewGeometry.size.height * 0.482

                ZStack {
                    Group {
                        if let frame = camera.previewImage {
                            Image(decorative: frame, scale: 1)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                        } else {
                            CameraPreview(session: camera.session)
                        }
                    }
                    .frame(width: width, height: height)
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .stroke(Color(hex: 0xFF4058).opacity(camera.isRecording ? 1 : 0), lineWidth: 4)
                            .animation(.spring(response: 0.42, dampingFraction: 0.82), value: camera.isRecording)
                    }
                    .overlay(alignment: .topLeading) {
                        if camera.isRecording {
                            HStack(spacing: 7) {
                                Circle().fill(Color(hex: 0xFF4058)).frame(width: 7, height: 7)
                                Text(String(format: "REC  %02d:%02d", Int(camera.recordingDuration) / 60, Int(camera.recordingDuration) % 60))
                                    .font(.system(size: 12, weight: .heavy, design: .rounded).monospacedDigit())
                                    .contentTransition(.numericText())
                                    .animation(.snappy(duration: 0.24), value: Int(camera.recordingDuration))
                                    .foregroundStyle(Color(hex: 0xFF4058))
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(Color(hex: selectedPalette.background[1]), in: Capsule())
                            .padding(12)
                            .transition(.asymmetric(
                                insertion: .move(edge: .top).combined(with: .opacity).combined(with: .scale(scale: 0.92, anchor: .topLeading)),
                                removal: .move(edge: .top).combined(with: .opacity)
                            ))
                        }
                    }
                    .animation(.spring(response: 0.38, dampingFraction: 0.84), value: camera.isRecording)
                    .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                    .onTapGesture(coordinateSpace: .local) { location in
                        let normalizedPoint = CGPoint(
                            x: min(max(location.x / width, 0), 1),
                            y: min(max(location.y / height, 0), 1)
                        )
                        if activeTool == .autofocus {
                            withAnimation(.spring(response: 0.30, dampingFraction: 0.86)) {
                                activeTool = .filters
                                isToolPanelExpanded = false
                            }
                            camera.setAutofocusVisualizationEnabled(false)
                        }

                        manualFocusIndicatorID += 1
                        let indicatorID = manualFocusIndicatorID
                        withAnimation(.spring(response: 0.26, dampingFraction: 0.72)) {
                            manualFocusIndicatorPoint = location
                        }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.15) {
                            guard manualFocusIndicatorID == indicatorID else { return }
                            withAnimation(.easeOut(duration: 0.28)) {
                                manualFocusIndicatorPoint = nil
                            }
                        }
                        camera.focus(at: normalizedPoint)
                    }

                    if showGrid {
                        Canvas { context, size in
                            var lines = Path()
                            for division in 1...2 {
                                let x = size.width * CGFloat(division) / 3
                                let y = size.height * CGFloat(division) / 3
                                lines.move(to: CGPoint(x: x, y: 0))
                                lines.addLine(to: CGPoint(x: x, y: size.height))
                                lines.move(to: CGPoint(x: 0, y: y))
                                lines.addLine(to: CGPoint(x: size.width, y: y))
                            }
                            context.stroke(lines, with: .color(.white.opacity(0.62)), lineWidth: 0.8)
                        }
                        .allowsHitTesting(false)
                    }

                    if stabilizationHUDEnabled, let frame = camera.previewImage {
                        StabilizationPreviewHUD(
                            image: frame,
                            rollDegrees: levelMonitor.rollDegrees,
                            pitchDegrees: levelMonitor.stabilizationPitchDegrees,
                            yawDegrees: levelMonitor.stabilizationYawDegrees,
                            relativeRollDegrees: levelMonitor.stabilizationRollDegrees,
                            visualMotion: camera.visualMotionEstimate,
                            isStabilizationActive: camera.isVideoStabilizationActive
                        )
                        .frame(width: 132, height: 110)
                        .position(
                            x: min(max(width * stabilizationHUDX, 78), width - 78),
                            y: min(max(height * stabilizationHUDY, 67), height - 67)
                        )
                        .gesture(
                            DragGesture(minimumDistance: 4)
                                .onChanged { value in
                                    if stabilizationHUDDragOrigin == nil {
                                        stabilizationHUDDragOrigin = CGPoint(x: stabilizationHUDX, y: stabilizationHUDY)
                                    }
                                    let origin = stabilizationHUDDragOrigin ?? CGPoint(x: stabilizationHUDX, y: stabilizationHUDY)
                                    stabilizationHUDX = min(max(origin.x + value.translation.width / width, 0.12), 0.88)
                                    stabilizationHUDY = min(max(origin.y + value.translation.height / height, 0.12), 0.88)
                                }
                                .onEnded { _ in
                                    stabilizationHUDDragOrigin = nil
                                }
                        )
                        .zIndex(18)
                    }

                    if motionStatusHUDEnabled {
                        MotionStatusWindow(
                            isLevel: abs(levelMonitor.rollDegrees) < 1.5,
                            rollDegrees: levelMonitor.rollDegrees,
                            tiltDegrees: levelMonitor.tiltDegrees,
                            shakeLevel: levelMonitor.shakeLevel,
                            stabilizationEnabled: videoStabilizationEnabled,
                            isStabilizationSupported: camera.isVideoStabilizationActive
                        )
                        .frame(width: 174, height: 140)
                        .position(
                            x: min(max(width * motionStatusHUDX, 99), width - 99),
                            y: min(max(height * motionStatusHUDY, 82), height - 82)
                        )
                        .gesture(
                            DragGesture(minimumDistance: 4)
                                .onChanged { value in
                                    if motionStatusHUDDragOrigin == nil {
                                        motionStatusHUDDragOrigin = CGPoint(x: motionStatusHUDX, y: motionStatusHUDY)
                                    }
                                    let origin = motionStatusHUDDragOrigin ?? CGPoint(x: motionStatusHUDX, y: motionStatusHUDY)
                                    motionStatusHUDX = min(max(origin.x + value.translation.width / width, 0.57), 0.88)
                                    motionStatusHUDY = min(max(origin.y + value.translation.height / height, 0.18), 0.82)
                                }
                                .onEnded { _ in
                                    motionStatusHUDDragOrigin = nil
                                }
                        )
                        .zIndex(19)
                    }

                    if showLevel {
                        levelIndicator
                            .position(x: width / 2, y: height * 0.13)
                            .allowsHitTesting(false)
                    }

                    if activeTool == .autofocus && !camera.autofocusPoints.isEmpty {
                        MultiPointAutofocusOverlay(
                            points: projectedAutofocusPoints(in: CGSize(width: width, height: height))
                        )
                        .frame(width: width, height: height)
                        .transition(.opacity)
                        .allowsHitTesting(false)
                    }
                    if let manualFocusIndicatorPoint {
                        FocusReticle()
                            .stroke(
                                Color(hex: 0xFFE45E),
                                style: StrokeStyle(lineWidth: 2.4, lineCap: .round, lineJoin: .round)
                            )
                            .frame(width: 58, height: 58)
                            .position(manualFocusIndicatorPoint)
                            .transition(.scale(scale: 0.70).combined(with: .opacity))
                            .allowsHitTesting(false)
                            .zIndex(13)
                    }

                    if isToolPanelExpanded {
                        Group {
                            switch activeTool {
                            case .filters:
                                filterPicker
                            case .superResolution:
                                superResolutionPicker
                            case .autofocus:
                                autofocusPicker
                            }
                        }
                        .frame(width: width - 28, height: 82)
                        .padding(5)
                        .background(Color.white, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                        .position(x: width / 2, y: height - 55)
                        .transition(
                            .asymmetric(
                                insertion: .scale(scale: 0.94, anchor: .bottom)
                                    .combined(with: .offset(y: 12))
                                    .combined(with: .opacity),
                                removal: .scale(scale: 0.97, anchor: .bottom)
                                    .combined(with: .offset(y: 6))
                                    .combined(with: .opacity)
                            )
                        )
                        .zIndex(20)
                    }

                    // During a long-press zoom drag, anchor the live indicator
                    // inside the viewfinder's lower-right corner. The two rounded
                    // corners follow the same edge, with a 14 pt safety inset.
                    if isZoomDragActive {
                        zoomDragIndicator
                            .padding(.trailing, 14)
                            .padding(.bottom, 14)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                            .transition(
                                .move(edge: .trailing)
                                    .combined(with: .opacity)
                                    .combined(with: .scale(scale: 0.92, anchor: .bottomTrailing))
                            )
                            .zIndex(30)
                            .allowsHitTesting(false)
                    }
                }
                .frame(width: width, height: height)
                .simultaneousGesture(
                    MagnifyGesture()
                        .onChanged { value in
                            if pinchStartZoom == nil {
                                pinchStartZoom = CGFloat(zoom)
                            }
                            let start = Double(pinchStartZoom ?? CGFloat(zoom))
                            let startStops = log2(max(0.5, start))
                            let pinchStops = log2(max(0.01, Double(value.magnification))) * 1.35
                            let targetZoom = CGFloat(pow(2.0, startStops + pinchStops))
                            applyZoom(targetZoom, animated: false)
                        }
                        .onEnded { _ in
                            pinchStartZoom = nil
                        }
                )
                .position(x: centerX, y: centerY)
            }
            .ignoresSafeArea()


            if let countdown {
                Text("\(countdown)")
                    .font(.system(size: 100, weight: .black, design: .rounded))
                    .foregroundStyle(.white)
                    .transition(.scale.combined(with: .opacity))
            }

            GeometryReader { geometry in
                VStack(spacing: 0) {
                    header
                    if !isCaptureBarCollapsed {
                        captureFormatBar
                            .padding(.top, 14)
                            .padding(.horizontal, 8)
                            .transition(.asymmetric(
                                insertion: .move(edge: .top).combined(with: .opacity),
                                removal: .move(edge: .top).combined(with: .opacity)
                            ))
                    }
                    Spacer(minLength: 18)
                    HStack(alignment: .center, spacing: 8) {
                        toolCapsule
                            .frame(width: 112)
                        zoomControl
                            .frame(maxWidth: .infinity)
                    }
                    .padding(.bottom, 16)
                    shutterControls
                    modeFooter
                        .padding(.top, 10)
                }
                .padding(.horizontal, 16)
                .padding(.top, 72)
                .padding(.bottom, 12)
                // Keep every control inside the physical screen viewport.
                .frame(width: geometry.size.width, height: geometry.size.height)
                .animation(.spring(response: 0.42, dampingFraction: 0.84), value: isCaptureBarCollapsed)
            }
            .ignoresSafeArea()

            if !camera.isAuthorized {
                permissionCard
            }
        }
        .ignoresSafeArea(.container, edges: .all)
        .statusBarHidden()
        .sheet(isPresented: $showReview) {
            if let image = camera.capturedImage {
                PhotoReviewView(
                    image: image,
                    superResolutionEnabled: superResolutionEnabled,
                    superResolutionScale: superResolutionScale,
                    onSave: { photo, completion in
                        camera.savePhoto(photo, completion: completion)
                    },
                    onClose: { showReview = false }
                )
                .presentationDragIndicator(.hidden)
            }
        }
        .sheet(isPresented: $showSettings) {
            settingsSheet
                .presentationDetents([.medium, .large])
                .presentationCornerRadius(18)
                .presentationBackground(Color(hex: 0xF1ECFA))
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showAlbum) {
            LocalMediaAlbumSheet(
                media: camera.savedMediaURLs,
                onDelete: { url in camera.deleteAlbumMedia(at: url) }
            )
            .presentationDetents([.large])
            .presentationCornerRadius(18)
            .presentationBackground(Color(hex: 0xF1ECFA))
            .presentationDragIndicator(.visible)
        }
        .onChange(of: camera.captureID) { _, _ in
            showReview = true
        }
        .onChange(of: camera.zoomFactor) { _, value in
            zoom = Double(value)
        }
        .onChange(of: activeTool == .autofocus && !camera.isExposureFocusLocked) { _, enabled in
            camera.setAutofocusVisualizationEnabled(enabled)
        }
        .onAppear {
            camera.prepare()
            camera.setAutofocusVisualizationEnabled(activeTool == .autofocus && !camera.isExposureFocusLocked)
            camera.setVideoStabilizationEnabled(videoStabilizationEnabled)
            updateMotionMonitoring()
        }
        .onChange(of: selectedVideoResolution) { _, _ in
            guard !isSyncingVideoControls else { return }
            camera.configureVideo(resolution: selectedVideoResolution, frameRate: Int(selectedFrameRate) ?? 30, hdrEnabled: hdrEnabled)
        }
        .onChange(of: selectedFrameRate) { _, _ in
            guard !isSyncingVideoControls else { return }
            camera.configureVideo(resolution: selectedVideoResolution, frameRate: Int(selectedFrameRate) ?? 30, hdrEnabled: hdrEnabled)
        }
        .onChange(of: hdrEnabled) { _, enabled in
            guard !isSyncingVideoControls else { return }
            if enabled && selectedFrameRate == "60" {
                // Dolby Vision HDR on iPhone 12 mini is limited to 30 FPS.
                // Keep the HDR selection and move the frame rate to 30 FPS.
                isSyncingVideoControls = true
                selectedFrameRate = "30"
                DispatchQueue.main.async {
                    isSyncingVideoControls = false
                    camera.configureVideo(
                        resolution: selectedVideoResolution,
                        frameRate: 30,
                        hdrEnabled: true
                    )
                }
            } else {
                camera.configureVideo(
                    resolution: selectedVideoResolution,
                    frameRate: Int(selectedFrameRate) ?? 30,
                    hdrEnabled: enabled
                )
            }
        }
        .onChange(of: camera.isReady) { _, ready in
            if ready {
                // Launch in the intended default recording mode: 4K 30 FPS HDR.
                // Applying it here also synchronizes the active device format
                // and the controls before the first recording begins.
                camera.configureVideo(
                    resolution: selectedVideoResolution,
                    frameRate: Int(selectedFrameRate) ?? 30,
                    hdrEnabled: hdrEnabled
                )
            } else {
                camera.setAutofocusVisualizationEnabled(false)
            }
        }
        .onChange(of: camera.videoConfigurationRevision) { _, _ in
            isSyncingVideoControls = true
            let actualFrameRate = String(camera.appliedFrameRate)
            if selectedFrameRate != actualFrameRate {
                selectedFrameRate = actualFrameRate
            }
            if selectedVideoResolution != camera.appliedResolution {
                selectedVideoResolution = camera.appliedResolution
            }
            if let actualHDR = camera.appliedHDR, hdrEnabled != actualHDR {
                hdrEnabled = actualHDR
            }
            DispatchQueue.main.async {
                isSyncingVideoControls = false
            }
        }
        .onChange(of: showLevel) { _, _ in
            updateMotionMonitoring()
        }
        .onChange(of: stabilizationHUDEnabled) { _, _ in
            updateMotionMonitoring()
        }
        .onChange(of: motionStatusHUDEnabled) { _, _ in
            updateMotionMonitoring()
        }
        .onDisappear { levelMonitor.stop(); camera.setAutofocusVisualizationEnabled(false) }
        .alert("POP CAM", isPresented: Binding(
            get: { camera.errorMessage != nil },
            set: { if !$0 { camera.errorMessage = nil } }
        )) {
            Button("好", role: .cancel) { camera.errorMessage = nil }
        } message: {
            Text(camera.errorMessage ?? "")
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text("POP")
                        .foregroundStyle(Color(hex: 0xFFE45E))
                    Text("CAM")
                        .foregroundStyle(Color(hex: 0x3D4352))
                }
                .font(.system(size: 22, weight: .black, design: .rounded))
                .tracking(-0.8)
                .lineLimit(1)
                .minimumScaleFactor(0.8)

                Text("MAKE TODAY POP")
                    .font(.system(size: 8, weight: .bold, design: .rounded))
                    .tracking(2.1)
                    .foregroundStyle(Color(hex: 0x596171).opacity(0.86))
            }

            Spacer()

            HStack(spacing: 7) {
                Button {
                    withAnimation(.spring(response: 0.42, dampingFraction: 0.82)) {
                        isCaptureBarCollapsed.toggle()
                    }
                    UIImpactFeedbackGenerator(style: .soft).impactOccurred()
                } label: {
                    HeaderIcon(symbol: isCaptureBarCollapsed ? "chevron.down" : "chevron.up")
                }
                .accessibilityLabel(isCaptureBarCollapsed ? "展开拍摄控制栏" : "收起拍摄控制栏")

                Menu {
                    Button("关闭", systemImage: "timer") { timerSeconds = 0 }
                    Button("3 秒", systemImage: "3.circle") { timerSeconds = 3 }
                    Button("5 秒", systemImage: "5.circle") { timerSeconds = 5 }
                    Button("10 秒", systemImage: "10.circle") { timerSeconds = 10 }
                } label: {
                    HeaderIcon(symbol: timerSeconds == 0 ? "timer" : "\(timerSeconds).circle")
                }

                Button {
                    camera.flashEnabled.toggle()
                } label: {
                    HeaderIcon(
                        symbol: camera.flashEnabled ? "bolt.fill" : "bolt.slash",
                        active: camera.flashEnabled,
                        tint: Color(hex: 0xFFE45E)
                    )
                }
                .disabled(camera.cameraPosition == .front)

                Button {
                    showSettings = true
                } label: {
                    HeaderIcon(symbol: "slider.horizontal.3")
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var toolCapsule: some View {
        HStack(spacing: 7) {
            Image(systemName: toolSymbol)
                .font(.system(size: 13, weight: .semibold))
            Text(toolTitle)
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .lineLimit(1)
            Image(systemName: isToolPanelExpanded ? "chevron.down" : "chevron.up")
                .font(.system(size: 9, weight: .bold))
                .opacity(0.65)
        }
        .foregroundStyle(Color(hex: 0x3D4352))
        .padding(.horizontal, 13)
        .frame(maxWidth: .infinity)
        .frame(height: 38)
        .background(Color.white, in: Capsule())
        .contentShape(Capsule())
        // A single gesture recognizer distinguishes a tap from a vertical swipe.
        // This avoids Button and DragGesture competing for the same touch sequence.
        .gesture(
            DragGesture(minimumDistance: 0)
                .onEnded { value in
                    let dx = value.translation.width
                    let dy = value.translation.height
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
                        if abs(dy) > 24 && abs(dy) > abs(dx) {
                            if dy < 0 {
                                activeTool = nextTool(after: activeTool)
                                isToolPanelExpanded = true
                            } else {
                                activeTool = previousTool(before: activeTool)
                                isToolPanelExpanded = true
                            }
                        } else if abs(dx) < 14 && abs(dy) < 14 {
                            isToolPanelExpanded.toggle()
                        }
                    }
                }
        )
        .accessibilityElement()
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(.default) {
            withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
                isToolPanelExpanded.toggle()
            }
        }
        .accessibilityHint("向上滑依次切换滤镜、AI 超分、自动对焦；向下滑反向切换；轻点展开或收起")
    }

    private var toolTitle: String {
        switch activeTool {
        case .filters: return "滤镜"
        case .superResolution: return "AI 超分"
        case .autofocus: return "自动对焦"
        }
    }

    private var toolSymbol: String {
        switch activeTool {
        case .filters: return "camera.filters"
        case .superResolution: return "sparkles"
        case .autofocus: return "viewfinder"
        }
    }

    private func nextTool(after tool: CameraToolMode) -> CameraToolMode {
        switch tool {
        case .filters: return .superResolution
        case .superResolution: return .autofocus
        case .autofocus: return .filters
        }
    }

    private func previousTool(before tool: CameraToolMode) -> CameraToolMode {
        switch tool {
        case .filters: return .autofocus
        case .superResolution: return .filters
        case .autofocus: return .superResolution
        }
    }

    private var autofocusPicker: some View {
        Button {
            camera.focus(at: CGPoint(x: 0.5, y: 0.5))
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "viewfinder")
                    .font(.system(size: 15, weight: .semibold))
                Text(camera.focusStatus == .focusing ? "正在对焦" :
                     camera.focusStatus == .focused ? "对焦完成" : "自动对焦")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                Spacer()
                if camera.focusStatus == .focusing {
                    ProgressView().tint(Color(hex: 0x32D46A))
                } else {
                    Circle()
                        .fill(camera.focusStatus == .focused ? Color(hex: 0x32D46A) : Color(hex: 0xA5B0BD))
                        .frame(width: 7, height: 7)
                }
            }
            .foregroundStyle(Color(hex: 0x3D4352))
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: 36)
            .background(Color.white, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            
        }
        .buttonStyle(.plain)
    }

    private var filterPicker: some View {
        VStack(spacing: 4) {
            HStack(spacing: 6) {
                Label("滤镜", systemImage: "camera.filters")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundStyle(Color(hex: 0x3D4352))
                Spacer()
                Button {
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
                        isToolPanelExpanded = false
                    }
                } label: {
                    Image(systemName: "chevron.up")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Color(hex: 0x596171))
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
            }
            FilterTray(selection: $camera.selectedFilter)
                .frame(maxWidth: .infinity)
                .frame(height: 42)
                .contentShape(Rectangle())
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        
    }

    private var superResolutionPicker: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Label("AI 超分", systemImage: "sparkles")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundStyle(Color(hex: 0x3D4352))
                Toggle("拍摄后自动增强", isOn: $superResolutionEnabled)
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .labelsHidden()
                    .tint(Color(hex: selectedPalette.accent))
                    .scaleEffect(0.82, anchor: .trailing)
                Text("自动增强")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(Color(hex: 0x596171))
                Spacer(minLength: 2)
                Button {
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
                        isToolPanelExpanded = false
                    }
                } label: {
                    Image(systemName: "chevron.up")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Color(hex: 0x596171))
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
            }
            HStack(spacing: 6) {
                superResolutionScaleButton(2, subtitle: "更快")
                superResolutionScaleButton(4, subtitle: "更精细")
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        
    }

    private var focusStatusTitle: String {
        switch camera.focusStatus {
        case .idle: return "自动对焦"
        case .focusing: return "正在对焦…"
        case .focused: return "对焦完成"
        case .unavailable: return "重新尝试对焦"
        }
    }

    private func superResolutionScaleButton(_ scale: Int, subtitle: String) -> some View {
        Button {
            superResolutionScale = scale
        } label: {
            VStack(spacing: 3) {
                HStack(spacing: 4) {
                    Text("\\(scale)×")
                        .font(.system(size: 15, weight: .black, design: .rounded))
                    if superResolutionScale == scale {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 11, weight: .bold))
                    }
                }
                Text(subtitle)
                    .font(.system(size: 8, weight: .medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .foregroundStyle(Color(hex: 0x3D4352))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .background(
                superResolutionScale == scale
                    ? Color(hex: selectedPalette.background[0])
                    : Color.white,
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(
                        superResolutionScale == scale ? Color(hex: selectedPalette.accent) : Color.white,
                        lineWidth: superResolutionScale == scale ? 1.5 : 1
                    )
            }
        }
        .buttonStyle(.plain)
    }

    private var levelIndicator: some View {
        let isLevel = abs(levelMonitor.rollDegrees) < 1.5
        return HStack(spacing: 7) {
            ZStack {
                Capsule()
                    .fill(isLevel ? Color(hex: 0x83DFA6) : Color.white)
                    .frame(width: 34, height: 2)
                Circle()
                    .fill(isLevel ? Color(hex: 0x83DFA6) : Color(hex: 0xFFE45E))
                    .frame(width: 7, height: 7)
            }
            .rotationEffect(.degrees(-levelMonitor.rollDegrees))
            Text(isLevel ? "水平" : String(format: "%+.0f°", levelMonitor.rollDegrees))
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Color(hex: 0x3D4352), in: Capsule())
        
    }

    private var zoomControl: some View {
        HStack(spacing: 5) {
            zoomButton(0.5)
            zoomButton(1)
            zoomButton(2)
            zoomButton(5)
            zoomButton(10)
        }
        .padding(5)
        .padding(4)
        .background(Color.white, in: Capsule())
        .simultaneousGesture(
            DragGesture(minimumDistance: 8)
                .onChanged { drag in
                    if zoomDragStartValue == nil {
                        zoomDragStartValue = CGFloat(zoom)
                    }
                    if !isZoomDragActive {
                        withAnimation(.spring(response: 0.24, dampingFraction: 0.82)) {
                            isZoomDragActive = true
                        }
                    }

                    // Direct horizontal dragging continuously adjusts zoom.
                    // The logarithmic scale keeps proportional zoom changes natural.
                    let startStops = log2(max(0.5, Double(zoomDragStartValue ?? CGFloat(zoom))))
                    let dragStops = Double(drag.translation.width) / 155.0
                    let targetZoom = CGFloat(pow(2.0, startStops + dragStops))
                    applyZoom(targetZoom, animated: false)
                }
                .onEnded { _ in
                    zoomDragStartValue = nil
                    withAnimation(.easeOut(duration: 0.18)) {
                        isZoomDragActive = false
                    }
                }
        )
    }

    private var zoomDragIndicator: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 10, weight: .bold))
                Text("ZOOM")
                    .font(.system(size: 8, weight: .heavy, design: .rounded))
                    .tracking(1.2)
                    .opacity(0.65)
                Text(String(format: "%.2f×", zoom))
                    .font(.system(size: 16, weight: .black, design: .rounded))
                    .monospacedDigit()
            }
            .foregroundStyle(Color(hex: 0x3D4352))

            GeometryReader { geometry in
                ZStack {
                    Capsule()
                        .fill(Color(hex: 0xAAB5C3).opacity(0.46))
                        .frame(height: 3)
                        .position(x: geometry.size.width / 2, y: 4)

                    ForEach([0.5, 1.0, 2.0, 5.0, 10.0], id: \.self) { mark in
                        Circle()
                            .fill(Color(hex: 0x7E8998).opacity(0.78))
                            .frame(width: 4, height: 4)
                            .position(x: zoomTrackPosition(mark, width: geometry.size.width), y: 4)
                    }

                    Circle()
                        .fill(Color(hex: 0xF16F89))
                        .frame(width: 9, height: 9)
                        
                        .position(x: zoomTrackPosition(zoom, width: geometry.size.width), y: 4)
                }
            }
            .frame(width: 126, height: 8)
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 9)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .allowsHitTesting(false)
    }

    private func zoomTrackPosition(_ value: Double, width: CGFloat) -> CGFloat {
        let bounded = min(max(value, 0.5), 10)
        let lower = log2(0.5)
        let upper = log2(10.0)
        let progress = (log2(bounded) - lower) / (upper - lower)
        return CGFloat(progress) * width
    }

    private func zoomButton(_ value: Double) -> some View {
        Button {
            applyZoom(CGFloat(value), animated: true)
        } label: {
            Text(value == 0.5 ? "0.5×" : "\(Int(value))×")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(Color(hex: 0x3D4352))
                .frame(maxWidth: .infinity)
                .frame(height: 34)
                .background {
                    if abs(zoom - value) < 0.04 {
                        Capsule().fill(Color(hex: 0xFFE45E))
                    }
                }
        }
        .buttonStyle(.plain)
    }

    private func applyZoom(_ value: CGFloat, animated: Bool = false) {
        let clamped = min(max(value, 0.5), 10)
        zoom = Double(clamped)
        camera.setZoom(clamped, animated: animated)
    }

    private var shutterControls: some View {
        GeometryReader { geometry in
            ZStack {
                HStack {
                    Button {
                        camera.reloadSavedMedia()
                        showAlbum = true
                    } label: {
                        ZStack {
                            RoundedRectangle(cornerRadius: 10)
                                .fill(Color.white)
                                .frame(width: 48, height: 48)
                            if let image = camera.capturedImage {
                                Image(uiImage: image)
                                    .resizable()
                                    .scaledToFill()
                                    .frame(width: 44, height: 44)
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                            } else {
                                Image(systemName: "photo.on.rectangle.angled")
                                    .font(.system(size: 19, weight: .medium))
                                    .foregroundStyle(Color(hex: 0x596171))
                            }
                            if !camera.savedMediaURLs.isEmpty {
                                Circle()
                                    .fill(Color(hex: 0xFF5967))
                                    .frame(width: 8, height: 8)
                                    .overlay(Circle().stroke(.white, lineWidth: 1))
                                    .offset(x: 19, y: -19)
                            }
                        }
                        .background(Color.white, in: RoundedRectangle(cornerRadius: 10))
                    }
                    .buttonStyle(.plain)
                    Spacer()
                    Button(action: triggerAutofocus) {
                        ZStack(alignment: .topTrailing) {
                            Circle()
                                .fill(Color.white)
                                .frame(width: 48, height: 48)
                                
                            Image(systemName: "viewfinder")
                                .font(.system(size: 19, weight: .semibold))
                                .foregroundStyle(Color(hex: 0x3D4352))
                                .frame(width: 48, height: 48)
                            Circle()
                                .fill(camera.focusStatus == .focused ? Color(hex: 0x32D46A) : Color(hex: 0xAAB3BE))
                                .frame(width: 8, height: 8)
                                
                                .offset(x: 1, y: -1)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(activeTool == .autofocus ? "关闭自动对焦" : "开启自动对焦")
                }

                HStack(spacing: 26) {
                    Button {
                        if camera.isRecording {
                            camera.stopRecording()
                        } else {
                            camera.startRecording(
                                resolution: selectedVideoResolution,
                                frameRate: Int(selectedFrameRate) ?? 30,
                                hdrEnabled: hdrEnabled
                            )
                        }
                    } label: {
                        ShutterButtonStyle(
                            outerColors: [Color(hex: 0xFF9AA2), Color(hex: 0xFF6B78)],
                            isVideo: true,
                            isRecording: camera.isRecording
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(camera.isRecording ? "停止录制" : "开始录制")

                    Button(action: takePhoto) {
                        ShutterButtonStyle(
                            outerColors: [Color(hex: 0xFFE45E), Color(hex: 0xFF72A6)],
                            isVideo: false,
                            isRecording: false
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("拍照")
                    .disabled(camera.isRecording)
                }
                .frame(maxWidth: .infinity)
                .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
            }
        }
        .frame(height: 88)
        .padding(.top, 2)
    }

    private var captureFormatBar: some View {
        Group {
            switch captureBarMode {
            case .video:
                videoFormatControls
                    .transition(.move(edge: .leading).combined(with: .opacity))
            case .menu:
                captureToolsMenu
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            case .zoom:
                zoomAdjustmentControl
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            case .exposure:
                exposureAdjustmentControl
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            case .focus:
                focusAdjustmentControl
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            case .grid:
                gridAdjustmentControl
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            case .level:
                levelAdjustmentControl
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 34)
        .clipped()
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(Color.white, in: Capsule())
        .contentShape(Capsule())
        .simultaneousGesture(
            DragGesture(minimumDistance: 24)
                .onEnded { value in
                    guard abs(value.translation.width) > 38,
                          abs(value.translation.width) > abs(value.translation.height) * 1.15 else { return }
                    handleCaptureBarSwipe(value.translation.width)
                }
        )
        .animation(.spring(response: 0.38, dampingFraction: 0.82), value: captureBarMode)
    }

    private var videoFormatControls: some View {
        HStack(spacing: 4) {
            Menu {
                Button("4K") { selectedVideoResolution = "4K" }
                Button("1080P") { selectedVideoResolution = "1080P" }
            } label: {
                HStack(spacing: 4) {
                    Text(selectedVideoResolution)
                    Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
                }
                .font(.system(size: 10, weight: .heavy, design: .rounded))
                .foregroundStyle(Color(hex: 0x3D4352))
                .fixedSize(horizontal: true, vertical: false)
                .padding(.horizontal, 8)
                .frame(height: 34)
                .background(Color(hex: 0xF4F8FC), in: Capsule())
            }
            .disabled(camera.isRecording || camera.isVideoConfigurationInProgress)

            Menu {
                Button("60 FPS") {
                    isSyncingVideoControls = true
                    selectedFrameRate = "60"
                    hdrEnabled = false
                    DispatchQueue.main.async {
                        isSyncingVideoControls = false
                        camera.configureVideo(
                            resolution: selectedVideoResolution,
                            frameRate: 60,
                            hdrEnabled: false
                        )
                    }
                }
                Button("30 FPS") { selectedFrameRate = "30" }
            } label: {
                HStack(spacing: 4) {
                    Text("\(selectedFrameRate) FPS")
                    Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
                }
                .font(.system(size: 10, weight: .heavy, design: .rounded))
                .foregroundStyle(Color(hex: 0x3D4352))
                .fixedSize(horizontal: true, vertical: false)
                .padding(.horizontal, 8)
                .frame(height: 34)
                .background(Color(hex: 0xF4F8FC), in: Capsule())
            }
            .disabled(camera.isRecording || camera.isVideoConfigurationInProgress)

            Button {
                hdrEnabled.toggle()
            } label: {
                Text("HDR")
                    .font(.system(size: 11, weight: .heavy, design: .rounded))
                    .foregroundStyle(Color(hex: 0x3D4352))
                    .padding(.horizontal, 10)
                    .fixedSize(horizontal: true, vertical: false)
                    .frame(height: 34)
                    .background(hdrEnabled ? Color(hex: 0xFFE45E) : Color(hex: 0xF4F8FC), in: Capsule())
            }
            .disabled(camera.isRecording || camera.isVideoConfigurationInProgress)

            Spacer(minLength: 0)

            Text("H.265")
                .font(.system(size: 8, weight: .semibold, design: .rounded))
                .foregroundStyle(Color(hex: 0x778091))
                .fixedSize()
            Rectangle().fill(Color(hex: 0xC9D4DE)).frame(width: 1, height: 18)
            Text("10-bit")
                .font(.system(size: 8, weight: .semibold, design: .rounded))
                .foregroundStyle(Color(hex: 0x778091))
                .fixedSize()
            Menu {
                Button("H.265") {}
                Button("10-bit HDR") {}
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Color(hex: 0x596171))
                    .frame(width: 28, height: 28)
                    .background(Color(hex: 0xF4F8FC), in: Circle())
            }
        }
    }

    private var captureToolsMenu: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 7) {
                captureToolChip("焦距", symbol: "viewfinder", tint: 0xDCEEFF) {
                    setCaptureBarMode(.zoom)
                }
                captureToolChip("曝光", symbol: "sun.max.fill", tint: 0xFFF0B8) {
                    setCaptureBarMode(.exposure)
                }
                captureToolChip("对焦", symbol: "scope", tint: 0xF9E1EB) {
                    setCaptureBarMode(.focus)
                }
                captureToolChip("网格", symbol: "grid", tint: 0xEAE3FA) {
                    setCaptureBarMode(.grid)
                }
                captureToolChip("水平仪", symbol: "level", tint: 0xDDF2E5) {
                    setCaptureBarMode(.level)
                }
            }
            .padding(.horizontal, 12)
        }
        .contentMargins(.horizontal, 10, for: .scrollContent)
        .mask {
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .black, location: 0.035),
                    .init(color: .black, location: 0.965),
                    .init(color: .clear, location: 1)
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
        }
    }

    private func captureToolChip(
        _ title: String,
        symbol: String,
        tint: UInt32,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .bold))
                Text(title)
                    .font(.system(size: 10, weight: .heavy, design: .rounded))
                    .fixedSize()
            }
            .foregroundStyle(Color(hex: 0x3D4352))
            .padding(.horizontal, 11)
            .frame(height: 31)
            .background(Color(hex: tint), in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private func captureBarBackButton() -> some View {
        Button {
            setCaptureBarMode(.menu)
        } label: {
            Image(systemName: "chevron.left")
                .font(.system(size: 11, weight: .black))
                .foregroundStyle(Color(hex: 0x52647A))
                .frame(width: 30, height: 30)
                .background(Color(hex: 0xF0F5FA), in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("返回拍摄工具")
    }

    private var zoomAdjustmentControl: some View {
        GeometryReader { geometry in
            let compact = geometry.size.width < 350
            HStack(spacing: 7) {
                captureBarBackButton()
                if !compact {
                    Text("焦距")
                        .font(.system(size: 11, weight: .heavy, design: .rounded))
                        .foregroundStyle(Color(hex: 0x596779))
                        .transition(.opacity.combined(with: .move(edge: .leading)))
                }
                Text(String(format: "%.1f×", zoom))
                    .font(.system(size: 11, weight: .heavy, design: .rounded).monospacedDigit())
                    .foregroundStyle(Color(hex: 0x3D4352))
                    .frame(width: 45)
                    .contentTransition(.numericText())
                Slider(
                    value: Binding(
                        get: { zoom },
                        set: { value in applyZoom(CGFloat(value), animated: false) }
                    ),
                    in: 0.5...10,
                    step: 0.1
                )
                .tint(Color(hex: 0xFFE45E))
                .frame(minWidth: 76)
                Button {
                    applyZoom(1, animated: true)
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Color(hex: 0x64768A))
                        .frame(width: 26, height: 26)
                        .background(Color(hex: 0xF0F5FA), in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("焦距重置为 1 倍")
            }
            .frame(height: 34)
            .animation(.easeInOut(duration: 0.20), value: compact)
        }
        .frame(height: 34)
    }

    private var exposureAdjustmentControl: some View {
        GeometryReader { geometry in
            let compact = geometry.size.width < 350
            HStack(spacing: 7) {
                captureBarBackButton()
                if !compact {
                    Text("曝光")
                        .font(.system(size: 11, weight: .heavy, design: .rounded))
                        .foregroundStyle(Color(hex: 0x596779))
                        .transition(.opacity.combined(with: .move(edge: .leading)))
                }
                Text(String(format: "%+.1f EV", exposure))
                    .font(.system(size: 10, weight: .heavy, design: .rounded).monospacedDigit())
                    .foregroundStyle(Color(hex: 0x3D4352))
                    .frame(width: 54)
                    .contentTransition(.numericText())
                Slider(value: $exposure, in: -2...2, step: 0.1)
                    .tint(Color(hex: 0xFFE45E))
                    .frame(minWidth: 76)
                    .onChange(of: exposure) { _, value in
                        camera.setExposure(Float(value))
                    }
                Button {
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.78)) {
                        exposure = 0
                    }
                    camera.setExposure(0)
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Color(hex: 0x64768A))
                        .frame(width: 26, height: 26)
                        .background(Color(hex: 0xF0F5FA), in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("曝光重置")
            }
            .frame(height: 34)
            .animation(.easeInOut(duration: 0.20), value: compact)
        }
        .frame(height: 34)
    }

    private var focusAdjustmentControl: some View {
        GeometryReader { geometry in
            let compact = geometry.size.width < 350
            HStack(spacing: 6) {
                captureBarBackButton()
                if !compact {
                    Text("对焦")
                        .font(.system(size: 11, weight: .heavy, design: .rounded))
                        .foregroundStyle(Color(hex: 0x596779))
                }
                Button {
                    camera.setManualFocusEnabled(false)
                    camera.setExposureFocusLocked(false)
                    camera.setAutofocusVisualizationEnabled(false)
                } label: {
                    Text("自动")
                        .font(.system(size: 10, weight: .heavy, design: .rounded))
                        .foregroundStyle(camera.isManualFocusEnabled ? Color(hex: 0x66778A) : Color(hex: 0x3D4352))
                        .padding(.horizontal, 9)
                        .frame(height: 29)
                        .background(camera.isManualFocusEnabled ? Color(hex: 0xF0F5FA) : Color(hex: 0xDDF2E5), in: Capsule())
                }
                .buttonStyle(.plain)
                Button {
                    camera.setManualFocusEnabled(true)
                    camera.setAutofocusVisualizationEnabled(false)
                } label: {
                    Text("手动")
                        .font(.system(size: 10, weight: .heavy, design: .rounded))
                        .foregroundStyle(camera.isManualFocusEnabled ? Color(hex: 0x3D4352) : Color(hex: 0x66778A))
                        .padding(.horizontal, 9)
                        .frame(height: 29)
                        .background(camera.isManualFocusEnabled ? Color(hex: 0xDCEEFF) : Color(hex: 0xF0F5FA), in: Capsule())
                }
                .buttonStyle(.plain)
                Slider(value: Binding(get: { Double(camera.manualLensPosition) }, set: { camera.setManualLensPosition(Float($0)) }), in: 0...1)
                    .tint(Color(hex: 0xFFE45E))
                    .disabled(!camera.isManualFocusEnabled || !camera.supportsManualFocus)
                    .frame(minWidth: 54)
                Text(String(format: "%.0f", camera.manualLensPosition * 100))
                    .font(.system(size: 9, weight: .heavy, design: .rounded).monospacedDigit())
                    .foregroundStyle(camera.isManualFocusEnabled ? Color(hex: 0x3D4352) : Color(hex: 0xA0A8B4))
                    .frame(width: 25)
            }
            .frame(height: 34)
        }
        .frame(height: 34)
    }

    private var gridAdjustmentControl: some View {
        HStack(spacing: 8) {
            captureBarBackButton()
            Text("网格线")
                .font(.system(size: 11, weight: .heavy, design: .rounded))
                .foregroundStyle(Color(hex: 0x596779))
            Spacer(minLength: 3)
            Button {
                withAnimation(.spring(response: 0.32, dampingFraction: 0.78)) {
                    showGrid.toggle()
                }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: showGrid ? "checkmark" : "grid")
                    Text(showGrid ? "已开启" : "开启网格")
                }
                .font(.system(size: 10, weight: .heavy, design: .rounded))
                .foregroundStyle(Color(hex: 0x3D4352))
                .padding(.horizontal, 11)
                .frame(height: 30)
                .background(showGrid ? Color(hex: 0xDCEEFF) : Color(hex: 0xF0F5FA), in: Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 1)
    }

    private var levelAdjustmentControl: some View {
        HStack(spacing: 8) {
            captureBarBackButton()
            Text("水平仪")
                .font(.system(size: 11, weight: .heavy, design: .rounded))
                .foregroundStyle(Color(hex: 0x596779))
            Spacer(minLength: 3)
            Button {
                withAnimation(.spring(response: 0.32, dampingFraction: 0.78)) {
                    showLevel.toggle()
                }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: showLevel ? "checkmark" : "level")
                    Text(showLevel ? "已开启" : "开启水平仪")
                }
                .font(.system(size: 10, weight: .heavy, design: .rounded))
                .foregroundStyle(Color(hex: 0x3D4352))
                .padding(.horizontal, 11)
                .frame(height: 30)
                .background(showLevel ? Color(hex: 0xDDF2E5) : Color(hex: 0xF0F5FA), in: Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 1)
    }

    private func setCaptureBarMode(_ mode: CaptureBarMode) {
        withAnimation(.spring(response: 0.38, dampingFraction: 0.82)) {
            captureBarMode = mode
        }
        UISelectionFeedbackGenerator().selectionChanged()
    }

    private func handleCaptureBarSwipe(_ horizontalTranslation: CGFloat) {
        if captureBarMode == .video, horizontalTranslation < 0 {
            setCaptureBarMode(.menu)
            return
        }
        if captureBarMode == .menu, horizontalTranslation > 0 {
            setCaptureBarMode(.video)
            return
        }

        if captureBarMode != .video && captureBarMode != .menu {
            if horizontalTranslation > 0 {
                setCaptureBarMode(.menu)
            } else {
                let order: [CaptureBarMode] = [.zoom, .exposure, .focus, .grid, .level]
                guard let index = order.firstIndex(of: captureBarMode) else { return }
                setCaptureBarMode(order[(index + 1) % order.count])
            }
        }
    }

    private var modeFooter: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(camera.isRecording ? Color(hex: 0xFF5967) : Color(hex: 0x83DFA6))
                .frame(width: 6, height: 6)
            if camera.isRecording {
                Text(String(format: "REC %02d:%02d", Int(camera.recordingDuration) / 60, Int(camera.recordingDuration) % 60))
                    .foregroundStyle(Color(hex: 0xFF5967))
                Text("·")
                    .foregroundStyle(Color(hex: 0x87909E))
                Text(camera.appliedVideoDescription)
                    .foregroundStyle(Color(hex: 0x3D4352))
            } else {
                Text("PHOTO MODE")
                    .foregroundStyle(Color(hex: 0x3D4352))
                Text("·")
                    .foregroundStyle(Color(hex: 0x87909E))
                Text("FILTERS ON")
                    .foregroundStyle(Color(hex: 0xD77A36))
            }
        }
        .font(.system(size: 10, weight: .heavy, design: .rounded))
        .tracking(1.5)
    }

    private var permissionCard: some View {
        VStack(spacing: 12) {
            Image(systemName: "camera.fill")
                .font(.system(size: 30))
                .foregroundStyle(Color(hex: 0xFFE45E))
            Text("让 POP CAM 看见精彩")
                .font(.system(size: 19, weight: .bold, design: .rounded))
                .foregroundStyle(Color(hex: 0x3D4352))
            Text("开启相机权限后，就可以开始拍照啦。")
                .font(.system(size: 13))
                .foregroundStyle(Color(hex: 0x596171))
            Button("打开系统设置") {
                guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                UIApplication.shared.open(url)
            }
            .font(.system(size: 14, weight: .bold))
            .foregroundStyle(.black)
            .padding(.horizontal, 22)
            .padding(.vertical, 12)
            .background(Color(hex: 0xFFE45E), in: Capsule())
        }
        .padding(28)
        .frame(maxWidth: .infinity)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 16))
        .padding(28)
    }

    private var settingsSheet: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("拍摄设置")
                            .font(.system(size: 23, weight: .black, design: .rounded))
                        Text("把每一张照片调整到刚刚好")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Color(hex: 0x778091))
                    }
                    Spacer()
                    Button("完成") { showSettings = false }
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Color(hex: 0x3D4352))
                        .padding(.horizontal, 15)
                        .padding(.vertical, 9)
                        .background(Color.white, in: Capsule())
                }

                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Label("马卡龙配色", systemImage: "paintpalette.fill")
                            .font(.system(size: 14, weight: .bold))
                        Spacer()
                        Text("12 款")
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                            .foregroundStyle(Color(hex: 0x7D8797))
                    }
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 9), count: 3), spacing: 10) {
                        ForEach(MacaronPalette.all) { palette in
                            Button {
                                withAnimation(.easeInOut(duration: 0.22)) {
                                    selectedPaletteID = palette.id
                                }
                            } label: {
                                VStack(spacing: 6) {
                                    HStack(spacing: 0) {
                                        ForEach(palette.background.indices, id: \.self) { index in
                                            Color(hex: palette.background[index])
                                        }
                                    }
                                    .frame(height: 30)
                                    .clipShape(Capsule())
                                    .overlay(alignment: .trailing) {
                                        if selectedPaletteID == palette.id {
                                            Image(systemName: "checkmark.circle.fill")
                                                .font(.system(size: 17, weight: .bold))
                                                .foregroundStyle(Color(hex: palette.accent))
                                                .padding(.trailing, 7)
                                        }
                                    }
                                    Text(palette.name)
                                        .font(.system(size: 11, weight: selectedPaletteID == palette.id ? .bold : .medium))
                                        .foregroundStyle(Color(hex: 0x3D4352))
                                        .lineLimit(1)
                                }
                                .padding(6)
                                .background(
                                    selectedPaletteID == palette.id
                                        ? Color.white
                                        : Color.white,
                                    in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                                )
                                .overlay {
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .stroke(
                                            selectedPaletteID == palette.id ? Color(hex: palette.accent) : Color.white,
                                            lineWidth: selectedPaletteID == palette.id ? 2 : 1
                                        )
                                }
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("\(palette.name)配色")
                            .accessibilityAddTraits(selectedPaletteID == palette.id ? .isSelected : [])
                        }
                    }
                }
                .padding(14)
                .background(Color.white, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                

                VStack(spacing: 0) {
                    settingToggle(
                        title: "三分构图网格",
                        subtitle: "显示辅助线，帮助安排画面",
                        symbol: "grid",
                        isOn: $showGrid
                    )
                    Divider().overlay(Color(hex: 0xDCE3EB)).padding(.leading, 48)
                    settingToggle(
                        title: "水平仪",
                        subtitle: "拍摄时辅助保持画面水平",
                        symbol: "level",
                        isOn: $showLevel
                    )
                    Divider().overlay(Color(hex: 0xDCE3EB)).padding(.leading, 48)
                    settingToggle(
                        title: "视频防抖",
                        subtitle: "启用相机支持的实时防抖，并应用到录像",
                        symbol: "viewfinder",
                        isOn: $videoStabilizationEnabled
                    )
                    .onChange(of: videoStabilizationEnabled) { _, enabled in
                        camera.setVideoStabilizationEnabled(enabled)
                    }
                    Divider().overlay(Color(hex: 0xDCE3EB)).padding(.leading, 48)
                    settingToggle(
                        title: "防抖取景监视器",
                        subtitle: "在取景器内显示原始画面与估算稳定范围，可拖动位置",
                        symbol: "rectangle.inset.filled",
                        isOn: $stabilizationHUDEnabled
                    )
                    .onChange(of: stabilizationHUDEnabled) { _, _ in
                        updateMotionMonitoring()
                    }
                    Divider().overlay(Color(hex: 0xDCE3EB)).padding(.leading, 48)
                    settingToggle(
                        title: "运动状态窗口",
                        subtitle: "显示水平参考线、倾斜角度、晃动幅度和防抖状态，可拖动位置",
                        symbol: "waveform.path",
                        isOn: $motionStatusHUDEnabled
                    )
                    .onChange(of: motionStatusHUDEnabled) { _, _ in
                        updateMotionMonitoring()
                    }
                    Divider().overlay(Color(hex: 0xDCE3EB)).padding(.leading, 48)
                    settingToggle(
                        title: "锁定对焦与曝光",
                        subtitle: "固定当前焦点和测光，点击画面可重新对焦",
                        symbol: "viewfinder",
                        isOn: Binding(
                            get: { camera.isExposureFocusLocked },
                            set: { camera.setExposureFocusLocked($0) }
                        )
                    )
                }
                .padding(.horizontal, 14)
                .background(Color.white, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                

                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Label("曝光补偿", systemImage: "sun.max.fill")
                            .font(.system(size: 14, weight: .bold))
                        Spacer()
                        Text(String(format: "%+.1f EV", exposure))
                            .font(.system(size: 12, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(Color(hex: 0x687386))
                    }
                    Slider(value: $exposure, in: -2...2, step: 0.1)
                        .tint(Color(hex: selectedPalette.accent))
                        .onChange(of: exposure) { _, value in
                            camera.setExposure(Float(value))
                        }
                }
                .padding(16)
                .background(Color.white, in: RoundedRectangle(cornerRadius: 12, style: .continuous))

                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Label("精细变焦", systemImage: "plus.magnifyingglass")
                            .font(.system(size: 14, weight: .bold))
                        Spacer()
                        Text(String(format: "%.1f×", zoom))
                            .font(.system(size: 12, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(Color(hex: 0x687386))
                    }
                    Slider(value: $zoom, in: 0.5...10, step: 0.1)
                        .tint(Color(hex: selectedPalette.secondaryAccent))
                        .onChange(of: zoom) { _, value in
                            camera.setZoom(CGFloat(value), animated: false)
                        }
                }
                .padding(16)
                .background(Color.white, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .padding(22)
        }
         .background(Color(hex: selectedPalette.background[0]))
        .foregroundStyle(Color(hex: 0x3D4352))
    }

    private func settingToggle(
        title: String,
        subtitle: String,
        symbol: String,
        isOn: Binding<Bool>
    ) -> some View {
        Toggle(isOn: isOn) {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color(hex: 0x596171))
                    .frame(width: 32, height: 32)
                    .background(Color(hex: 0xE8F4FA), in: RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Color(hex: 0x3D4352))
                    Text(subtitle)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Color(hex: 0x7D8797))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .tint(Color(hex: selectedPalette.accent))
        .padding(.vertical, 12)
    }

    private func triggerAutofocus() {
        // The shutter-side AF control is an action, not an on/off toggle:
        // tapping it always initiates a fresh center focus operation.
        withAnimation(.spring(response: 0.30, dampingFraction: 0.86)) {
            activeTool = .autofocus
            isToolPanelExpanded = false
        }
        camera.setAutofocusVisualizationEnabled(true)
        camera.focus(at: CGPoint(x: 0.5, y: 0.5))
    }

    private func projectedAutofocusPoints(in size: CGSize) -> [AutofocusPoint] {
        guard let image = camera.previewImage, size.width > 0, size.height > 0 else { return [] }
        let sourceAspect = CGFloat(image.width) / CGFloat(image.height)
        let targetAspect = size.width / size.height

        return camera.autofocusPoints.compactMap { point in
            var projected = point.location
            if sourceAspect > targetAspect {
                let visibleWidth = targetAspect / sourceAspect
                projected.x = (point.location.x - (1 - visibleWidth) / 2) / visibleWidth
            } else {
                let visibleHeight = sourceAspect / targetAspect
                projected.y = (point.location.y - (1 - visibleHeight) / 2) / visibleHeight
            }
            guard (0...1).contains(projected.x), (0...1).contains(projected.y) else { return nil }
            return AutofocusPoint(id: point.id, location: projected, strength: point.strength)
        }
    }

    private func takePhoto() {
        guard camera.isReady else { return }
        guard timerSeconds > 0 else {
            camera.capturePhoto()
            return
        }
        Task {
            for value in stride(from: timerSeconds, through: 1, by: -1) {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                    countdown = value
                }
                try? await Task.sleep(for: .seconds(1))
            }
            withAnimation(.easeOut(duration: 0.2)) { countdown = nil }
            camera.capturePhoto()
        }
    }
}

private struct LocalMediaAlbumSheet: View {
    let media: [URL]
    let onDelete: (URL) -> Void

    @AppStorage("popcam.album.favorites") private var favoritePathsStorage = ""
    @AppStorage("popcam.album.customCollections.v1") private var collectionsStorage = "[]"
    @Environment(\.dismiss) private var dismiss

    @Namespace private var tabMotion
    @State private var selectedTab: POPAlbumTab = .photos
    @State private var selectedFilter: AlbumMediaFilter = .all
    @State private var searchText = ""
    @State private var isSearchExpanded = false
    @State private var sortNewestFirst = true
    @State private var contentAppeared = false
    @State private var refreshRotation = 0.0

    @State private var isSelecting = false
    @State private var selectedPaths: Set<String> = []
    @State private var selectedURL: URL?
    @State private var viewerItems: [URL] = []
    @State private var showViewer = false
    @State private var showDeleteConfirmation = false

    @State private var memorySet: [URL] = []
    @State private var activeCollectionID: String?
    @State private var isAddingToCollection = false
    @State private var showNewCollectionAlert = false
    @State private var newCollectionName = ""

    private let photoColumns = Array(repeating: GridItem(.flexible(), spacing: 9), count: 3)
    private let collectionColumns = Array(repeating: GridItem(.flexible(), spacing: 12), count: 2)

    private var favoritePaths: Set<String> {
        Set(favoritePathsStorage.split(separator: "\n").map(String.init))
    }

    private var customCollections: [POPCustomCollection] {
        guard let data = collectionsStorage.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([POPCustomCollection].self, from: data) else {
            return []
        }
        return decoded
    }

    private var activeCollection: POPCustomCollection? {
        guard let activeCollectionID else { return nil }
        return customCollections.first { $0.id == activeCollectionID }
    }

    private var displayedMedia: [URL] {
        var result = media

        if let activeCollection, !isAddingToCollection {
            let paths = Set(activeCollection.paths)
            result = result.filter { paths.contains($0.path) }
        }

        switch selectedFilter {
        case .all:
            break
        case .photos:
            result = result.filter { !$0.isVideoMedia }
        case .videos:
            result = result.filter { $0.isVideoMedia }
        case .favorites:
            result = result.filter { favoritePaths.contains($0.path) }
        }

        if !searchText.isEmpty {
            result = result.filter {
                $0.deletingPathExtension().lastPathComponent.localizedCaseInsensitiveContains(searchText)
            }
        }

        return result.sorted {
            let lhsDate = Self.mediaDate($0)
            let rhsDate = Self.mediaDate($1)
            return sortNewestFirst ? lhsDate > rhsDate : lhsDate < rhsDate
        }
    }

    private var dateGroups: [POPAlbumDateGroup] {
        let grouped = Dictionary(grouping: displayedMedia) {
            Calendar.current.startOfDay(for: Self.mediaDate($0))
        }
        let dates = grouped.keys.sorted { sortNewestFirst ? $0 > $1 : $0 < $1 }
        return dates.map { POPAlbumDateGroup(date: $0, items: grouped[$0] ?? []) }
    }

    private var photoCount: Int {
        media.filter { !$0.isVideoMedia }.count
    }

    private var videoCount: Int {
        media.filter(\.isVideoMedia).count
    }

    private var currentTitle: String {
        if let activeCollection { return activeCollection.title }
        switch selectedTab {
        case .photos: return "所有瞬间"
        case .memories: return "回忆时光"
        case .albums: return "我的相簿"
        }
    }

    private var headerSubtitle: String {
        if isAddingToCollection { return "选择要添加到相簿的照片" }
        if let activeCollection {
            return "\(activeCollection.paths.count) 个收藏瞬间"
        }
        return "\(photoCount) 张照片  ·  \(videoCount) 段视频"
    }

    private var heroPhoto: URL? {
        memorySet.first ?? displayedMedia.first ?? media.first
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color(hex: 0xF4F8FC).ignoresSafeArea()

                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 22) {
                        pageHeader
                            .offset(y: contentAppeared ? 0 : 12)
                            .opacity(contentAppeared ? 1 : 0)

                        if selectedTab == .photos && activeCollection == nil {
                            memoryFeatureCard
                                .offset(y: contentAppeared ? 0 : 18)
                                .opacity(contentAppeared ? 1 : 0)
                                .transition(.move(edge: .top).combined(with: .opacity))
                        }

                        if selectedTab == .photos {
                            filterControls
                                .transition(.opacity.combined(with: .move(edge: .top)))
                            photosContent
                                .animation(.spring(response: 0.38, dampingFraction: 0.82), value: displayedMedia.map(\.path))
                                .transition(.opacity.combined(with: .move(edge: .bottom)))
                        } else if selectedTab == .memories {
                            memoriesContent
                                .transition(.opacity.combined(with: .move(edge: .bottom)))
                        } else if activeCollection == nil {
                            collectionsContent
                                .transition(.opacity.combined(with: .move(edge: .bottom)))
                        } else {
                            filterControls
                                .transition(.opacity)
                            photosContent
                                .animation(.spring(response: 0.38, dampingFraction: 0.82), value: displayedMedia.map(\.path))
                                .transition(.opacity.combined(with: .move(edge: .bottom)))
                        }
                    }
                    .padding(.horizontal, 18)
                    .padding(.top, 14)
                    .padding(.bottom, 22)
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                bottomNavigation
            }
            .toolbar(.hidden, for: .navigationBar)
        }
        .preferredColorScheme(.light)
        .fullScreenCover(isPresented: $showViewer, onDismiss: {
            selectedURL = nil
            viewerItems = []
        }) {
            if let selectedURL, !viewerItems.isEmpty {
                LocalAlbumDetailView(
                    media: viewerItems,
                    initialURL: selectedURL,
                    onDelete: { deletedURL in removeMedia(deletedURL) }
                )
            }
        }
        .alert("创建新相簿", isPresented: $showNewCollectionAlert) {
            TextField("例如：周末散步", text: $newCollectionName)
                .textInputAutocapitalization(.words)
            Button("创建") { createCollection() }
                .disabled(newCollectionName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button("取消", role: .cancel) { newCollectionName = "" }
        } message: {
            Text("给这组照片起一个名字，之后可以随时添加新照片。")
        }
        .confirmationDialog(
            "删除已选择的 \(selectedPaths.count) 项内容？",
            isPresented: $showDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("删除 \(selectedPaths.count) 项", role: .destructive) {
                let paths = selectedPaths
                for url in media where paths.contains(url.path) {
                    removeMedia(url)
                }
                selectedPaths.removeAll()
                isSelecting = false
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("删除后将无法从 POP CAM 相册中恢复。")
        }
        .onAppear {
            refreshMemories()
            withAnimation(.spring(response: 0.58, dampingFraction: 0.84).delay(0.06)) {
                contentAppeared = true
            }
        }
    }

    private var pageHeader: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("POP  /  MOMENTS")
                        .font(.system(size: 10, weight: .black, design: .rounded))
                        .tracking(2.2)
                        .foregroundStyle(Color(hex: 0x7E9BB8))
                    Text(currentTitle)
                        .font(.system(size: 31, weight: .bold, design: .rounded))
                        .tracking(-0.8)
                        .foregroundStyle(Color(hex: 0x354255))
                        .contentTransition(.numericText())
                    Text(headerSubtitle)
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color(hex: 0x8794A5))
                }

                Spacer(minLength: 0)

                HStack(spacing: 8) {
                    Button {
                        withAnimation(.spring(response: 0.34, dampingFraction: 0.76)) {
                            isSearchExpanded.toggle()
                            if !isSearchExpanded { searchText = "" }
                        }
                        UIImpactFeedbackGenerator(style: .soft).impactOccurred()
                    } label: {
                        albumActionCircle("magnifyingglass", fill: 0xFFFFFF)
                    }
                    .buttonStyle(.plain)

                    if selectedTab == .albums && activeCollection == nil {
                        Button {
                            newCollectionName = ""
                            showNewCollectionAlert = true
                        } label: {
                            albumActionCircle("plus", fill: 0xFFF0B8, tint: 0x6F633A)
                        }
                        .buttonStyle(.plain)
                    } else if activeCollection != nil {
                        Button {
                            withAnimation(.spring(response: 0.38, dampingFraction: 0.82)) {
                                activeCollectionID = nil
                                isAddingToCollection = false
                                selectedTab = .albums
                                isSelecting = false
                                selectedPaths.removeAll()
                            }
                        } label: {
                            albumActionCircle("arrow.uturn.backward", fill: 0xFFFFFF)
                        }
                        .buttonStyle(.plain)

                        Button {
                            withAnimation(.spring(response: 0.38, dampingFraction: 0.82)) {
                                isAddingToCollection = true
                                isSelecting = true
                                selectedPaths.removeAll()
                            }
                        } label: {
                            albumActionCircle("plus", fill: 0xDCEEFF, tint: 0x587E9F)
                        }
                        .buttonStyle(.plain)
                    } else {
                        Menu {
                            Button {
                                sortNewestFirst = true
                            } label: {
                                Label("最新优先", systemImage: sortNewestFirst ? "checkmark" : "clock")
                            }
                            Button {
                                sortNewestFirst = false
                            } label: {
                                Label("最早优先", systemImage: !sortNewestFirst ? "checkmark" : "calendar")
                            }
                            Divider()
                            Button {
                                isSelecting = true
                            } label: {
                                Label("选择照片", systemImage: "checkmark.circle")
                            }
                        } label: {
                            albumActionCircle("ellipsis", fill: 0xFFFFFF)
                        }
                    }
                }
            }

            if isSearchExpanded {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color(hex: 0x8B9AAF))
                    TextField("搜索照片名称", text: $searchText)
                        .font(.system(size: 14, weight: .medium))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    if !searchText.isEmpty {
                        Button {
                            withAnimation(.easeOut(duration: 0.18)) { searchText = "" }
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(Color(hex: 0xAAB4C1))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 15)
                .frame(height: 44)
                .background(Color.white, in: Capsule())
                .transition(.asymmetric(insertion: .move(edge: .top).combined(with: .opacity), removal: .opacity))
            }
        }
        .animation(.spring(response: 0.38, dampingFraction: 0.86), value: isSearchExpanded)
    }

    private var memoryFeatureCard: some View {
        Button {
            if let heroPhoto {
                openViewer(heroPhoto, in: memorySet.isEmpty ? displayedMedia : memorySet)
            } else {
                withAnimation(.spring(response: 0.38, dampingFraction: 0.82)) {
                    selectedTab = .memories
                }
            }
        } label: {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 9) {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(Color(hex: 0x8FD9AC))
                            .frame(width: 6, height: 6)
                        Text("A LITTLE LOOK BACK")
                            .font(.system(size: 9, weight: .black, design: .rounded))
                            .tracking(1.5)
                            .foregroundStyle(Color(hex: 0x7B8B8D))
                    }
                    Text("把日常，\n收进回忆里。")
                        .font(.system(size: 19, weight: .bold, design: .rounded))
                        .multilineTextAlignment(.leading)
                        .foregroundStyle(Color(hex: 0x3D4A59))
                        .lineSpacing(3)
                    HStack(spacing: 6) {
                        Text("打开回忆")
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 9, weight: .bold))
                    }
                    .foregroundStyle(Color(hex: 0x668BB2))
                }
                Spacer(minLength: 0)
                ZStack {
                    RoundedRectangle(cornerRadius: 15, style: .continuous)
                        .fill(Color(hex: 0xF9DCE8))
                        .frame(width: 76, height: 91)
                        .rotationEffect(.degrees(8))
                        .offset(x: 9, y: 3)
                    RoundedRectangle(cornerRadius: 15, style: .continuous)
                        .fill(Color(hex: 0xDCEEFF))
                        .frame(width: 78, height: 94)
                        .rotationEffect(.degrees(-7))
                        .offset(x: -5, y: -2)
                    if let heroPhoto {
                        LocalAlbumThumbnail(url: heroPhoto)
                            .frame(width: 82, height: 100)
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .overlay {
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .stroke(Color.white, lineWidth: 3)
                            }
                            .rotationEffect(.degrees(2))
                    } else {
                        Image(systemName: "sparkles")
                            .font(.system(size: 28, weight: .medium))
                            .foregroundStyle(Color(hex: 0x9A8BCC))
                            .frame(width: 82, height: 100)
                            .background(Color(hex: 0xEAE3FA), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                }
                .frame(width: 112, height: 112)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 15)
            .frame(maxWidth: .infinity, minHeight: 136)
            .background(Color(hex: 0xFFF4D5), in: RoundedRectangle(cornerRadius: 23, style: .continuous))
            .overlay(alignment: .topTrailing) {
                Circle()
                    .fill(Color(hex: 0xFFFFFF).opacity(0.55))
                    .frame(width: 24, height: 24)
                    .offset(x: -15, y: 13)
            }
        }
        .buttonStyle(POPPressableStyle())
        .disabled(media.isEmpty)
    }

    private var filterControls: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                filterChip("全部", filter: .all, tint: 0xDCEEFF)
                filterChip("照片", filter: .photos, tint: 0xDDF2E5)
                filterChip("视频", filter: .videos, tint: 0xF9E1EB)
                filterChip("收藏", filter: .favorites, tint: 0xEAE3FA)
            }
            .padding(.vertical, 2)
        }
    }

    private func filterChip(_ title: String, filter: AlbumMediaFilter, tint: UInt32) -> some View {
        let selected = selectedFilter == filter
        return Button {
            withAnimation(.spring(response: 0.34, dampingFraction: 0.78)) {
                selectedFilter = filter
            }
            UISelectionFeedbackGenerator().selectionChanged()
        } label: {
            HStack(spacing: 6) {
                if selected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .black))
                        .transition(.scale.combined(with: .opacity))
                }
                Text(title)
                    .font(.system(size: 12, weight: .bold, design: .rounded))
            }
            .foregroundStyle(Color(hex: 0x435268))
            .padding(.horizontal, 15)
            .frame(height: 34)
            .background(selected ? Color(hex: tint) : Color.white, in: Capsule())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var photosContent: some View {
        if displayedMedia.isEmpty {
            emptyState(
                symbol: activeCollection == nil ? "photo.on.rectangle.angled" : "rectangle.stack.badge.plus",
                title: activeCollection == nil ? "还没有照片" : "这个相簿还空着",
                message: activeCollection == nil ? "拍下第一张照片，让这里慢慢装满回忆。" : "选择几张喜欢的照片，放进这个小相簿吧。",
                actionTitle: activeCollection == nil ? nil : "添加照片",
                action: activeCollection == nil ? nil : {
                    isAddingToCollection = true
                    isSelecting = true
                    selectedPaths.removeAll()
                }
            )
        } else {
            VStack(alignment: .leading, spacing: 19) {
                HStack {
                    Text(activeCollection == nil ? "时间轴" : "相簿内容")
                        .font(.system(size: 17, weight: .bold, design: .rounded))
                        .foregroundStyle(Color(hex: 0x3D4A59))
                    Spacer()
                    Text("\(displayedMedia.count) ITEMS")
                        .font(.system(size: 9, weight: .black, design: .rounded))
                        .tracking(1.2)
                        .foregroundStyle(Color(hex: 0x9AA7B6))
                }

                ForEach(dateGroups) { group in
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(Self.sectionDateText(group.date))
                                .font(.system(size: 14, weight: .bold, design: .rounded))
                                .foregroundStyle(Color(hex: 0x46566C))
                            Text(Self.weekdayText(group.date))
                                .font(.system(size: 10, weight: .semibold, design: .rounded))
                                .foregroundStyle(Color(hex: 0x9AA7B6))
                            Spacer()
                            Text("\(group.items.count) 项")
                                .font(.system(size: 10, weight: .medium, design: .rounded))
                                .foregroundStyle(Color(hex: 0xA5AFBB))
                        }

                        LazyVGrid(columns: photoColumns, spacing: 9) {
                            ForEach(group.items, id: \.path) { url in
                                photoTile(
                                    url,
                                    index: group.items.firstIndex(of: url) ?? 0,
                                    source: displayedMedia
                                )
                            }
                        }
                    }
                }
            }
        }
    }

    private func photoTile(_ url: URL, index: Int, source: [URL]) -> some View {
        let selected = selectedPaths.contains(url.path)
        return Button {
            if isSelecting {
                withAnimation(.spring(response: 0.32, dampingFraction: 0.62)) {
                    if selected { selectedPaths.remove(url.path) }
                    else { selectedPaths.insert(url.path) }
                }
                UISelectionFeedbackGenerator().selectionChanged()
            } else {
                openViewer(url, in: source)
            }
        } label: {
            LocalAlbumThumbnail(url: url)
                .overlay(alignment: .topTrailing) {
                    if isSelecting {
                        Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 20, weight: .semibold))
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, Color(hex: selected ? 0x78B8EE : 0x64748B))
                            .symbolEffect(.bounce, value: selected)
                            .padding(7)
                            .transition(.scale.combined(with: .opacity))
                    }
                }
                .overlay {
                    if selected {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(Color(hex: 0x78B8EE), lineWidth: 3)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .scaleEffect(contentAppeared ? 1 : 0.9)
                .opacity(contentAppeared ? 1 : 0)
                .animation(
                    .spring(response: 0.42, dampingFraction: 0.76)
                        .delay(Double(index % 6) * 0.035),
                    value: contentAppeared
                )
        }
        .buttonStyle(POPPressableStyle())
        .accessibilityLabel(isSelecting ? (selected ? "取消选择" : "选择照片") : "打开照片")
    }

    private var memoriesContent: some View {
        VStack(alignment: .leading, spacing: 17) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("RANDOM MOMENTS")
                        .font(.system(size: 9, weight: .black, design: .rounded))
                        .tracking(1.8)
                        .foregroundStyle(Color(hex: 0x91A0B1))
                    Text("今天想起哪一刻？")
                        .font(.system(size: 19, weight: .bold, design: .rounded))
                        .foregroundStyle(Color(hex: 0x3D4A59))
                }
                Spacer()
                Button {
                    refreshMemories()
                    withAnimation(.spring(response: 0.55, dampingFraction: 0.56)) {
                        refreshRotation += 180
                    }
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(Color(hex: 0x657D9D))
                        .frame(width: 40, height: 40)
                        .background(Color(hex: 0xDCEEFF), in: Circle())
                        .rotationEffect(.degrees(refreshRotation))
                }
                .buttonStyle(.plain)
            }

            if memorySet.isEmpty {
                emptyState(
                    symbol: "sparkles",
                    title: "还没有可以回看的瞬间",
                    message: "拍摄并保存一些照片后，这里就会出现随机回忆。",
                    actionTitle: nil,
                    action: nil
                )
            } else {
                Button {
                    openViewer(memorySet[0], in: memorySet)
                } label: {
                    ZStack(alignment: .bottomLeading) {
                        LocalAlbumThumbnail(url: memorySet[0])
                            .frame(maxWidth: .infinity)
                            .frame(height: 226)
                            .clipped()
                        LinearGradient(
                            colors: [Color.black.opacity(0.0), Color.black.opacity(0.58)],
                            startPoint: .center,
                            endPoint: .bottom
                        )
                        VStack(alignment: .leading, spacing: 5) {
                            Text("A MEMORY FOR YOU")
                                .font(.system(size: 9, weight: .black, design: .rounded))
                                .tracking(1.5)
                            Text("再看一眼，那个瞬间。")
                                .font(.system(size: 18, weight: .bold, design: .rounded))
                        }
                        .foregroundStyle(.white)
                        .padding(17)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                }
                .buttonStyle(POPPressableStyle())
                .transition(.scale(scale: 0.96).combined(with: .opacity))

                HStack {
                    Text("随机拾光")
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                        .foregroundStyle(Color(hex: 0x3D4A59))
                    Spacer()
                    Text("\(memorySet.count) 个瞬间")
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color(hex: 0x99A6B5))
                }

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 11) {
                        ForEach(memorySet, id: \.path) { url in
                            Button {
                                openViewer(url, in: memorySet)
                            } label: {
                                VStack(alignment: .leading, spacing: 7) {
                                    LocalAlbumThumbnail(url: url)
                                        .frame(width: 126, height: 126)
                                        .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
                                    Text(Self.shortDateText(Self.mediaDate(url)))
                                        .font(.system(size: 10, weight: .bold, design: .rounded))
                                        .foregroundStyle(Color(hex: 0x68798D))
                                        .lineLimit(1)
                                }
                                .frame(width: 126)
                                .scaleEffect(contentAppeared ? 1 : 0.92)
                                .opacity(contentAppeared ? 1 : 0)
                                .animation(
                                    .spring(response: 0.45, dampingFraction: 0.78)
                                        .delay(Double(memorySet.firstIndex(of: url) ?? 0) * 0.035),
                                    value: contentAppeared
                                )
                            }
                            .buttonStyle(POPPressableStyle())
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .animation(.spring(response: 0.46, dampingFraction: 0.82), value: memorySet)
    }

    private var collectionsContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("YOUR LITTLE LIBRARIES")
                        .font(.system(size: 9, weight: .black, design: .rounded))
                        .tracking(1.7)
                        .foregroundStyle(Color(hex: 0x91A0B1))
                    Text("把喜欢的照片放在一起")
                        .font(.system(size: 17, weight: .bold, design: .rounded))
                        .foregroundStyle(Color(hex: 0x3D4A59))
                }
                Spacer()
                Button {
                    newCollectionName = ""
                    showNewCollectionAlert = true
                } label: {
                    Label("新建", systemImage: "plus")
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundStyle(Color(hex: 0x586D87))
                        .padding(.horizontal, 13)
                        .frame(height: 34)
                        .background(Color(hex: 0xFFF0B8), in: Capsule())
                }
                .buttonStyle(.plain)
            }

            LazyVGrid(columns: collectionColumns, spacing: 12) {
                ForEach(customCollections) { collection in
                    collectionCard(
                        collection,
                        index: customCollections.firstIndex(where: { $0.id == collection.id }) ?? 0
                    )
                }

                Button {
                    newCollectionName = ""
                    showNewCollectionAlert = true
                } label: {
                    VStack(spacing: 10) {
                        Image(systemName: "plus")
                            .font(.system(size: 24, weight: .medium))
                            .foregroundStyle(Color(hex: 0x8297B0))
                            .frame(width: 52, height: 52)
                            .background(Color.white, in: Circle())
                        Text("创建相簿")
                            .font(.system(size: 12, weight: .bold, design: .rounded))
                            .foregroundStyle(Color(hex: 0x6C7D92))
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 170)
                    .background(Color(hex: 0xE7F0F8), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .strokeBorder(Color.white, style: StrokeStyle(lineWidth: 1.2, dash: [5, 5]))
                    }
                }
                .buttonStyle(POPPressableStyle())
            }
        }
    }

    private func collectionCard(_ collection: POPCustomCollection, index: Int) -> some View {
        let previews = Array(collection.paths.prefix(3)).compactMap { path in
            media.first { $0.path == path }
        }
        let accents: [UInt32] = [0xF9E1EB, 0xDCEEFF, 0xEAE3FA, 0xDDF2E5, 0xFFF0B8]
        let accent = accents[index % accents.count]

        return Button {
            withAnimation(.spring(response: 0.42, dampingFraction: 0.84)) {
                activeCollectionID = collection.id
                selectedTab = .photos
                selectedFilter = .all
                isSelecting = false
                selectedPaths.removeAll()
            }
            UIImpactFeedbackGenerator(style: .soft).impactOccurred()
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 15, style: .continuous)
                        .fill(Color(hex: accent))
                    if previews.isEmpty {
                        Image(systemName: "photo.on.rectangle.angled")
                            .font(.system(size: 31, weight: .light))
                            .foregroundStyle(Color(hex: 0x71839A).opacity(0.7))
                    } else {
                        HStack(spacing: 5) {
                            ForEach(previews, id: \.path) { url in
                                LocalAlbumThumbnail(url: url)
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 83)
                                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                                    .rotationEffect(.degrees((previews.firstIndex(of: url) ?? 0) == 1 ? 2 : ((previews.firstIndex(of: url) ?? 0) == 0 ? -2 : 1)))
                            }
                        }
                        .padding(9)
                    }
                }
                .frame(height: 102)

                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(collection.title)
                            .font(.system(size: 13, weight: .bold, design: .rounded))
                            .foregroundStyle(Color(hex: 0x3D4A59))
                            .lineLimit(1)
                        Text("\(collection.paths.count) 张照片")
                            .font(.system(size: 10, weight: .medium, design: .rounded))
                            .foregroundStyle(Color(hex: 0x8D9AAA))
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Color(hex: 0x8497AA))
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity)
            .background(Color.white, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .scaleEffect(contentAppeared ? 1 : 0.94)
            .opacity(contentAppeared ? 1 : 0)
            .animation(.spring(response: 0.46, dampingFraction: 0.78).delay(Double(index) * 0.045), value: contentAppeared)
        }
        .buttonStyle(POPPressableStyle())
        .contextMenu {
            Button(role: .destructive) {
                deleteCollection(collection)
            } label: {
                Label("删除相簿", systemImage: "trash")
            }
        }
        .transition(.scale(scale: 0.94).combined(with: .opacity))
    }

    private var bottomNavigation: some View {
        VStack(spacing: 0) {
            if isSelecting {
                selectionToolbar
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            } else {
                HStack(spacing: 5) {
                    ForEach(POPAlbumTab.allCases) { tab in
                        Button {
                            withAnimation(.spring(response: 0.42, dampingFraction: 0.78)) {
                                selectedTab = tab
                                if tab != .photos { activeCollectionID = nil }
                                selectedPaths.removeAll()
                                isSelecting = false
                            }
                            UISelectionFeedbackGenerator().selectionChanged()
                        } label: {
                            VStack(spacing: 5) {
                                Image(systemName: tab.symbol)
                                    .font(.system(size: 18, weight: .semibold))
                                    .symbolEffect(.bounce, value: selectedTab == tab)
                                Text(tab.title)
                                    .font(.system(size: 10, weight: .bold, design: .rounded))
                            }
                            .foregroundStyle(selectedTab == tab ? Color(hex: 0x4F83B6) : Color(hex: 0x8694A5))
                            .frame(maxWidth: .infinity)
                            .frame(height: 58)
                            .background {
                                if selectedTab == tab {
                                    RoundedRectangle(cornerRadius: 17, style: .continuous)
                                        .fill(Color.white)
                                        .matchedGeometryEffect(id: "activeAlbumTab", in: tabMotion)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(POPPressableStyle())
                    }
                }
                .padding(6)
                .background(Color(hex: 0xE7F0F8), in: RoundedRectangle(cornerRadius: 23, style: .continuous))
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 9)
        .padding(.bottom, 7)
        .background(Color(hex: 0xF4F8FC).ignoresSafeArea(edges: .bottom))
        .animation(.spring(response: 0.42, dampingFraction: 0.84), value: isSelecting)
    }

    private var selectionToolbar: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(selectedPaths.count)")
                    .font(.system(size: 19, weight: .black, design: .rounded).monospacedDigit())
                    .foregroundStyle(Color(hex: 0x3D4A59))
                    .contentTransition(.numericText())
                Text("已选择")
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .foregroundStyle(Color(hex: 0x8997A8))
            }
            .frame(width: 48, alignment: .leading)

            Button("全选") {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.78)) {
                    selectedPaths = Set(displayedMedia.map(\.path))
                }
            }
            .font(.system(size: 11, weight: .bold, design: .rounded))
            .foregroundStyle(Color(hex: 0x5D7FA5))

            Spacer(minLength: 0)

            if activeCollection != nil {
                Button {
                    addSelectedToActiveCollection()
                } label: {
                    Image(systemName: "folder.badge.plus")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(Color(hex: 0x587E9F))
                        .frame(width: 42, height: 42)
                        .background(Color(hex: 0xDCEEFF), in: Circle())
                }
                .disabled(selectedPaths.isEmpty)
                .opacity(selectedPaths.isEmpty ? 0.45 : 1)
            } else {
                Menu {
                    ForEach(customCollections) { collection in
                        Button(collection.title) {
                            addSelected(to: collection.id)
                        }
                    }
                    Button {
                        showNewCollectionAlert = true
                    } label: {
                        Label("新建相簿", systemImage: "plus")
                    }
                } label: {
                    Image(systemName: "folder.badge.plus")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(Color(hex: 0x587E9F))
                        .frame(width: 42, height: 42)
                        .background(Color(hex: 0xDCEEFF), in: Circle())
                }
                .disabled(selectedPaths.isEmpty)
                .opacity(selectedPaths.isEmpty ? 0.45 : 1)
            }

            if !isAddingToCollection {
                Button {
                    showDeleteConfirmation = true
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 42, height: 42)
                        .background(Color(hex: 0xF18B9D), in: Circle())
                }
                .disabled(selectedPaths.isEmpty)
                .opacity(selectedPaths.isEmpty ? 0.45 : 1)
            }

            Button {
                withAnimation(.spring(response: 0.38, dampingFraction: 0.82)) {
                    selectedPaths.removeAll()
                    isSelecting = false
                    isAddingToCollection = false
                }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Color(hex: 0x6D7F93))
                    .frame(width: 38, height: 38)
                    .background(Color.white, in: Circle())
            }
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 9)
        .background(Color(hex: 0xE7F0F8), in: RoundedRectangle(cornerRadius: 23, style: .continuous))
    }

    private func emptyState(
        symbol: String,
        title: String,
        message: String,
        actionTitle: String?,
        action: (() -> Void)?
    ) -> some View {
        VStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 31, weight: .light))
                .foregroundStyle(Color(hex: 0x8BA8C5))
                .frame(width: 76, height: 76)
                .background(Color(hex: 0xE4F0FB), in: Circle())
                .symbolEffect(.pulse, options: .repeating)
            Text(title)
                .font(.system(size: 17, weight: .bold, design: .rounded))
                .foregroundStyle(Color(hex: 0x3D4A59))
            Text(message)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(Color(hex: 0x8B98A8))
                .multilineTextAlignment(.center)
                .lineSpacing(3)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundStyle(Color(hex: 0x4F83B6))
                    .padding(.horizontal, 17)
                    .frame(height: 38)
                    .background(Color(hex: 0xDCEEFF), in: Capsule())
                    .padding(.top, 3)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
        .padding(.horizontal, 24)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .transition(.opacity.combined(with: .scale(scale: 0.96)))
    }

    private func albumActionCircle(_ symbol: String, fill: UInt32, tint: UInt32 = 0x64778E) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(Color(hex: tint))
            .frame(width: 42, height: 42)
            .background(Color(hex: fill), in: Circle())
    }

    private func openViewer(_ url: URL, in source: [URL]) {
        guard !source.isEmpty else { return }
        viewerItems = source
        selectedURL = url
        withAnimation(.spring(response: 0.42, dampingFraction: 0.86)) {
            showViewer = true
        }
        UIImpactFeedbackGenerator(style: .soft).impactOccurred()
    }

    private func refreshMemories() {
        memorySet = Array(media.shuffled().prefix(min(8, media.count)))
    }

    private func createCollection() {
        let title = newCollectionName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        var collections = customCollections
        let collection = POPCustomCollection(
            id: UUID().uuidString,
            title: title,
            paths: Array(selectedPaths)
        )
        collections.insert(collection, at: 0)
        saveCollections(collections)
        newCollectionName = ""
        withAnimation(.spring(response: 0.42, dampingFraction: 0.82)) {
            activeCollectionID = collection.id
            selectedTab = .photos
            selectedPaths.removeAll()
            isSelecting = false
            isAddingToCollection = false
        }
    }

    private func deleteCollection(_ collection: POPCustomCollection) {
        var collections = customCollections
        collections.removeAll { $0.id == collection.id }
        saveCollections(collections)
    }

    private func addSelected(to collectionID: String) {
        var collections = customCollections
        guard let index = collections.firstIndex(where: { $0.id == collectionID }) else { return }
        for path in selectedPaths where !collections[index].paths.contains(path) {
            collections[index].paths.append(path)
        }
        saveCollections(collections)
        withAnimation(.spring(response: 0.38, dampingFraction: 0.82)) {
            selectedPaths.removeAll()
            isSelecting = false
            isAddingToCollection = false
        }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    private func addSelectedToActiveCollection() {
        guard let activeCollectionID else { return }
        addSelected(to: activeCollectionID)
    }

    private func saveCollections(_ collections: [POPCustomCollection]) {
        guard let data = try? JSONEncoder().encode(collections),
              let encoded = String(data: data, encoding: .utf8) else { return }
        collectionsStorage = encoded
    }

    private func removeMedia(_ url: URL) {
        onDelete(url)

        var collections = customCollections
        for index in collections.indices {
            collections[index].paths.removeAll { $0 == url.path }
        }
        saveCollections(collections)

        var favorites = favoritePaths
        favorites.remove(url.path)
        favoritePathsStorage = favorites.sorted().joined(separator: "\n")
    }

    private static func mediaDate(_ url: URL) -> Date {
        let values = try? url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
        return values?.creationDate ?? values?.contentModificationDate ?? .distantPast
    }

    private static func sectionDateText(_ date: Date) -> String {
        if Calendar.current.isDateInToday(date) { return "今天" }
        if Calendar.current.isDateInYesterday(date) { return "昨天" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日"
        return formatter.string(from: date)
    }

    private static func weekdayText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "EEEE"
        return formatter.string(from: date)
    }

    private static func shortDateText(_ date: Date) -> String {
        guard date > .distantPast else { return "来自某个瞬间" }
        return date.formatted(date: .numeric, time: .omitted)
    }
}

private enum POPAlbumTab: String, CaseIterable, Identifiable {
    case photos
    case memories
    case albums

    var id: String { rawValue }

    var title: String {
        switch self {
        case .photos: return "照片"
        case .memories: return "回忆"
        case .albums: return "相簿"
        }
    }

    var symbol: String {
        switch self {
        case .photos: return "square.grid.3x3.fill"
        case .memories: return "sparkles"
        case .albums: return "rectangle.stack.fill"
        }
    }
}

private struct POPCustomCollection: Codable, Identifiable {
    var id: String
    var title: String
    var paths: [String]
}

private struct POPAlbumDateGroup: Identifiable {
    let date: Date
    let items: [URL]
    var id: Date { date }
}

private struct POPPressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.965 : 1)
            .opacity(configuration.isPressed ? 0.9 : 1)
            .animation(.spring(response: 0.24, dampingFraction: 0.68), value: configuration.isPressed)
    }
}

private enum AlbumMediaFilter: String, CaseIterable, Identifiable {
    case all
    case photos
    case videos
    case favorites

    var id: String { rawValue }
}

private enum AlbumMainTab {
    case library
    case favorites
}

private struct LocalAlbumThumbnail: View {
    let url: URL

    @State private var thumbnail: UIImage?
    @State private var isLoading = true

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .bottomTrailing) {
                Group {
                    if let thumbnail {
                        Image(uiImage: thumbnail)
                            .resizable()
                            .scaledToFill()
                            .frame(width: geometry.size.width, height: geometry.size.height)
                            .clipped()
                            .transition(.opacity)
                    } else {
                        Rectangle()
                            .fill(Color(hex: 0xE7EAF0))
                            .overlay {
                                if isLoading {
                                    ProgressView().tint(Color(hex: 0x8B91A0))
                                } else {
                                    Image(systemName: url.isVideoMedia ? "video" : "photo")
                                        .font(.system(size: 22, weight: .medium))
                                        .foregroundStyle(Color(hex: 0x8B91A0))
                                }
                            }
                    }
                }

                if url.isVideoMedia {
                    Text(videoDurationLabel)
                        .font(.system(size: 10, weight: .bold, design: .rounded).monospacedDigit())
                        .foregroundStyle(.white)
                        .padding(.trailing, 6)
                        .padding(.bottom, 5)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        }
        .aspectRatio(1, contentMode: .fit)
        .task(id: url) { await loadThumbnail() }
    }

    private var videoDurationLabel: String {
        guard url.isVideoMedia else { return "" }
        let secondsValue = CMTimeGetSeconds(AVURLAsset(url: url).duration)
        let seconds = Int(secondsValue.isFinite ? max(0, secondsValue) : 0)
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    @MainActor
    private func loadThumbnail() async {
        isLoading = true
        let fileURL = url
        let result = await Task.detached(priority: .utility) { () -> UIImage? in
            if fileURL.isVideoMedia {
                let asset = AVURLAsset(url: fileURL)
                let generator = AVAssetImageGenerator(asset: asset)
                generator.appliesPreferredTrackTransform = true
                generator.maximumSize = CGSize(width: 480, height: 480)
                if let cgImage = try? generator.copyCGImage(at: .zero, actualTime: nil) {
                    return UIImage(cgImage: cgImage)
                }
                return nil
            }
            return UIImage(contentsOfFile: fileURL.path)
        }.value
        guard !Task.isCancelled else { return }
        withAnimation(.easeInOut(duration: 0.24)) {
            thumbnail = result
            isLoading = false
        }
    }
}

private struct LocalAlbumDetailView: View {
    let media: [URL]
    let onDelete: (URL) -> Void

    @Environment(\.dismiss) private var dismiss
    @AppStorage("popcam.album.favorites") private var favoritePathsStorage = ""
    @AppStorage("popcam.superResolutionScale") private var superResolutionScale = 2

    @State private var currentIndex: Int
    @State private var showInfo = false
    @State private var showDeleteConfirmation = false
    @State private var isAspectFit = true
    @State private var controlsVisible = true
    @State private var showStudio = false
    @State private var studioStartsWithAI = false
    @State private var favoritePulse = false

    init(media: [URL], initialURL: URL, onDelete: @escaping (URL) -> Void) {
        self.media = media
        self.onDelete = onDelete
        let initialIndex = media.firstIndex(of: initialURL) ?? 0
        _currentIndex = State(initialValue: initialIndex)
    }

    private var currentURL: URL {
        guard !media.isEmpty else { return URL(fileURLWithPath: "") }
        return media[min(max(currentIndex, 0), media.count - 1)]
    }

    private var favoritePaths: Set<String> {
        Set(favoritePathsStorage.split(separator: "\n").map(String.init))
    }

    private var isFavorite: Bool {
        favoritePaths.contains(currentURL.path)
    }

    private var currentDate: Date {
        Self.mediaDate(currentURL)
    }

    var body: some View {
        ZStack {
            Color(hex: 0xF4F8FC).ignoresSafeArea()

            TabView(selection: $currentIndex) {
                ForEach(Array(media.enumerated()), id: \.offset) { index, url in
                    AlbumViewerPage(url: url, isAspectFit: isAspectFit)
                        .tag(index)
                        .accessibilityLabel(url.isVideoMedia ? "视频" : "照片")
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .padding(.top, controlsVisible ? 0 : -2)

            VStack(spacing: 0) {
                if controlsVisible {
                    viewerHeader
                        .transition(.move(edge: .top).combined(with: .opacity))
                }

                Spacer(minLength: 0)

                if controlsVisible {
                    viewerFooter
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.spring(response: 0.42, dampingFraction: 0.86), value: controlsVisible)

            if favoritePulse {
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        Image(systemName: "heart.fill")
                            .font(.system(size: 23, weight: .bold))
                            .foregroundStyle(Color(hex: 0xF18B9D))
                            .padding(16)
                            .background(Color.white, in: Circle())
                            .shadow(color: Color(hex: 0xF18B9D).opacity(0.18), radius: 16, y: 6)
                            .scaleEffect(favoritePulse ? 1 : 0.35)
                            .rotationEffect(.degrees(favoritePulse ? 0 : -24))
                        Spacer()
                    }
                    Spacer()
                }
                .allowsHitTesting(false)
                .transition(.scale.combined(with: .opacity))
            }
        }
        .statusBarHidden(!controlsVisible)
        .sheet(isPresented: $showInfo) {
            AlbumInfoSheet(url: currentURL)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                .presentationCornerRadius(26)
                .presentationBackground(Color(hex: 0xF4F8FC))
        }
        .sheet(isPresented: $showStudio) {
            if let image = UIImage(contentsOfFile: currentURL.path), !currentURL.isVideoMedia {
                AlbumPhotoStudioView(
                    image: image,
                    sourceName: currentURL.lastPathComponent,
                    startsWithAI: studioStartsWithAI,
                    preferredScale: superResolutionScale,
                    onSaveCopy: { editedImage, isAI in
                        saveEditedCopy(editedImage, isAI: isAI)
                    }
                )
                .presentationDetents([.large])
                .presentationDragIndicator(.hidden)
                .presentationCornerRadius(28)
                .presentationBackground(Color(hex: 0xF4F8FC))
            }
        }
        .confirmationDialog("删除这项媒体？", isPresented: $showDeleteConfirmation, titleVisibility: .visible) {
            Button("删除", role: .destructive) {
                onDelete(currentURL)
                dismiss()
            }
            Button("取消", role: .cancel) {}
        }
    }

    private var viewerHeader: some View {
        HStack(spacing: 10) {
            Button {
                dismiss()
            } label: {
                viewerCircleButton(symbol: "chevron.left")
            }
            .buttonStyle(POPPressableStyle())

            Spacer(minLength: 0)

            VStack(spacing: 2) {
                Text(Self.relativeDateText(currentDate))
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundStyle(Color(hex: 0x354255))
                Text(Self.timeText(currentDate))
                    .font(.system(size: 10, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(Color(hex: 0x7D8B9C))
            }
            .frame(maxWidth: 170)
            .frame(height: 48)
            .background(Color.white, in: Capsule())

            Spacer(minLength: 0)

            Menu {
                Button {
                    isAspectFit = true
                } label: {
                    Label("适应屏幕", systemImage: "arrow.down.right.and.arrow.up.left")
                }
                Button {
                    isAspectFit = false
                } label: {
                    Label("填满屏幕", systemImage: "arrow.up.left.and.arrow.down.right")
                }
                Button {
                    showInfo = true
                } label: {
                    Label("照片信息", systemImage: "info.circle")
                }
                if !currentURL.isVideoMedia {
                    Button {
                        openStudio(startAI: false)
                    } label: {
                        Label("使用 POP Studio 编辑", systemImage: "slider.horizontal.3")
                    }
                    Button {
                        openStudio(startAI: true)
                    } label: {
                        Label("AI 超分增强", systemImage: "sparkles")
                    }
                }
            } label: {
                viewerCircleButton(symbol: "ellipsis")
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 9)
    }

    private var viewerFooter: some View {
        VStack(spacing: 8) {
            thumbnailStrip

            HStack(spacing: 9) {
                ShareLink(item: currentURL) {
                    viewerCircleButton(symbol: "square.and.arrow.up")
                }
                .buttonStyle(POPPressableStyle())

                HStack(spacing: 0) {
                    Button {
                        toggleFavorite()
                    } label: {
                        Image(systemName: isFavorite ? "heart.fill" : "heart")
                            .foregroundStyle(isFavorite ? Color(hex: 0xF18B9D) : Color(hex: 0x52647A))
                            .symbolEffect(.bounce, value: isFavorite)
                            .frame(maxWidth: .infinity)
                            .frame(height: 52)
                    }
                    .buttonStyle(POPPressableStyle())
                    .accessibilityLabel(isFavorite ? "取消收藏" : "收藏")

                    Button {
                        showInfo = true
                    } label: {
                        Image(systemName: "info.circle")
                            .foregroundStyle(Color(hex: 0x52647A))
                            .frame(maxWidth: .infinity)
                            .frame(height: 52)
                    }
                    .buttonStyle(POPPressableStyle())
                    .accessibilityLabel("照片信息")

                    Button {
                        openStudio(startAI: false)
                    } label: {
                        Image(systemName: "slider.horizontal.3")
                            .foregroundStyle(Color(hex: 0x52647A))
                            .frame(maxWidth: .infinity)
                            .frame(height: 52)
                    }
                    .buttonStyle(POPPressableStyle())
                    .disabled(currentURL.isVideoMedia)
                    .opacity(currentURL.isVideoMedia ? 0.38 : 1)
                    .accessibilityLabel("编辑照片")

                    Button {
                        openStudio(startAI: true)
                    } label: {
                        Image(systemName: "sparkles")
                            .foregroundStyle(Color(hex: 0x8F79C7))
                            .frame(maxWidth: .infinity)
                            .frame(height: 52)
                    }
                    .buttonStyle(POPPressableStyle())
                    .disabled(currentURL.isVideoMedia)
                    .opacity(currentURL.isVideoMedia ? 0.38 : 1)
                    .accessibilityLabel("AI 超分增强")
                }
                .font(.system(size: 19, weight: .semibold))
                .frame(width: 220)
                .background(Color.white, in: Capsule())

                Button {
                    showDeleteConfirmation = true
                } label: {
                    viewerCircleButton(symbol: "trash", tint: Color(hex: 0xD97D83), fill: 0xFCEBF1)
                }
                .buttonStyle(POPPressableStyle())
                .accessibilityLabel("删除照片")
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 10)
        }
    }

    private var thumbnailStrip: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Array(media.enumerated()), id: \.offset) { index, url in
                        Button {
                            withAnimation(.spring(response: 0.38, dampingFraction: 0.84)) {
                                currentIndex = index
                            }
                            UISelectionFeedbackGenerator().selectionChanged()
                        } label: {
                            LocalAlbumThumbnail(url: url)
                                .frame(width: 50, height: 50)
                                .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                                .overlay {
                                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                                        .stroke(
                                            currentIndex == index ? Color(hex: 0x7FB9E8) : Color.white,
                                            lineWidth: currentIndex == index ? 2.5 : 1
                                        )
                                }
                                .scaleEffect(currentIndex == index ? 1 : 0.92)
                                .opacity(currentIndex == index ? 1 : 0.68)
                        }
                        .buttonStyle(POPPressableStyle())
                        .id(index)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
            }
            .onChange(of: currentIndex) { _, newValue in
                withAnimation(.spring(response: 0.38, dampingFraction: 0.82)) {
                    proxy.scrollTo(newValue, anchor: .center)
                }
            }
        }
        .frame(height: 62)
    }

    private func viewerCircleButton(
        symbol: String,
        tint: Color = Color(hex: 0x52647A),
        fill: UInt32 = 0xFFFFFF
    ) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 18, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: 48, height: 48)
            .background(Color(hex: fill), in: Circle())
            .contentShape(Circle())
    }

    private func toggleFavorite() {
        var paths = favoritePaths
        let adding = !paths.contains(currentURL.path)
        if adding {
            paths.insert(currentURL.path)
        } else {
            paths.remove(currentURL.path)
        }
        favoritePathsStorage = paths.sorted().joined(separator: "\n")
        guard adding else { return }
        withAnimation(.spring(response: 0.34, dampingFraction: 0.58)) {
            favoritePulse = true
        }
        UIImpactFeedbackGenerator(style: .soft).impactOccurred()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) {
            withAnimation(.easeOut(duration: 0.22)) {
                favoritePulse = false
            }
        }
    }

    private func openStudio(startAI: Bool) {
        guard !currentURL.isVideoMedia else { return }
        studioStartsWithAI = startAI
        showStudio = true
        UIImpactFeedbackGenerator(style: .soft).impactOccurred()
    }

    private func saveEditedCopy(_ image: UIImage, isAI: Bool) -> URL? {
        let directory = currentURL.deletingLastPathComponent()
        let timestamp = Date.now.formatted(.iso8601).replacingOccurrences(of: ":", with: "-")
        let prefix = isAI ? "POP_AI" : "POP_EDIT"
        let fileName = "\(prefix)_\(timestamp)_\(UUID().uuidString.prefix(5)).jpg"
        let destination = directory.appendingPathComponent(fileName)
        guard let data = image.jpegData(compressionQuality: 0.98) else { return nil }
        do {
            try data.write(to: destination, options: .atomic)
            return destination
        } catch {
            return nil
        }
    }

    private static func mediaDate(_ url: URL) -> Date {
        let values = try? url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
        return values?.creationDate ?? values?.contentModificationDate ?? .distantPast
    }

    private static func relativeDateText(_ date: Date) -> String {
        if date == .distantPast { return "POP CAM" }
        if Calendar.current.isDateInToday(date) { return "今天" }
        if Calendar.current.isDateInYesterday(date) { return "昨天" }
        return date.formatted(date: .abbreviated, time: .omitted)
    }

    private static func timeText(_ date: Date) -> String {
        guard date > .distantPast else { return "" }
        return date.formatted(date: .omitted, time: .shortened)
    }
}

private struct AlbumViewerPage: View {
    let url: URL
    let isAspectFit: Bool

    @State private var image: UIImage?
    @State private var player: AVPlayer?
    @State private var zoomScale: CGFloat = 1

    var body: some View {
        ZStack {
            Color(hex: 0xF4F8FC)

            if url.isVideoMedia {
                if let player {
                    VideoPlayer(player: player)
                        .onAppear { player.play() }
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .padding(.horizontal, 8)
                } else {
                    ProgressView().tint(Color(hex: 0x7C91A8))
                }
            } else if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: isAspectFit ? .fit : .fill)
                    .scaleEffect(zoomScale)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
                    .contentShape(Rectangle())
                    .gesture(
                        MagnificationGesture()
                            .onChanged { value in
                                zoomScale = min(max(value, 1), 5)
                            }
                            .onEnded { _ in
                                withAnimation(.spring(response: 0.32, dampingFraction: 0.78)) {
                                    if zoomScale < 1.05 { zoomScale = 1 }
                                }
                            }
                    )
                    .onTapGesture(count: 2) {
                        withAnimation(.spring(response: 0.34, dampingFraction: 0.76)) {
                            zoomScale = zoomScale > 1.1 ? 1 : 2
                        }
                    }
                    .transition(.opacity)
            } else {
                ProgressView().tint(Color(hex: 0x7C91A8))
            }
        }
        .padding(.vertical, 6)
        .task(id: url) {
            image = nil
            if url.isVideoMedia {
                player?.pause()
                player = AVPlayer(url: url)
                player?.play()
            } else {
                let fileURL = url
                let loadedImage = await Task.detached(priority: .userInitiated) {
                    UIImage(contentsOfFile: fileURL.path)
                }.value
                guard !Task.isCancelled else { return }
                withAnimation(.easeInOut(duration: 0.22)) {
                    image = loadedImage
                    zoomScale = 1
                }
            }
        }
        .onChange(of: isAspectFit) { _, _ in
            withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
                zoomScale = 1
            }
        }
        .onDisappear {
            player?.pause()
            player = nil
        }
    }
}

private struct AlbumPhotoStudioView: View {
    let image: UIImage
    let sourceName: String
    let startsWithAI: Bool
    let preferredScale: Int
    let onSaveCopy: (UIImage, Bool) -> URL?

    @Environment(\.dismiss) private var dismiss
    @State private var exposure = 0.0
    @State private var contrast = 1.0
    @State private var saturation = 1.0
    @State private var sharpness = 0.0
    @State private var rotationQuarterTurns = 0
    @State private var cropMode: StudioCropMode = .original
    @State private var preset: StudioPreset = .original
    @State private var aiScale = 2
    @State private var enhancedImage: UIImage?
    @State private var showingEnhanced = false
    @State private var isEnhancing = false
    @State private var enhancementProgress = 0.0
    @State private var enhancementError: String?
    @State private var savedURL: URL?
    @State private var showSavedAlert = false
    @State private var undoStack: [StudioEditSnapshot] = []
    @State private var redoStack: [StudioEditSnapshot] = []

    private static let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    private var displayImage: UIImage {
        if showingEnhanced, let enhancedImage { return enhancedImage }
        return renderEditedImage()
    }

    private var canUndo: Bool { !undoStack.isEmpty }
    private var canRedo: Bool { !redoStack.isEmpty }

    var body: some View {
        ZStack {
            Color(hex: 0xF4F8FC).ignoresSafeArea()

            VStack(spacing: 0) {
                editorHeader
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 16) {
                        previewCard
                        if let enhancedImage {
                            comparisonControl
                                .transition(.move(edge: .top).combined(with: .opacity))
                        }
                        presetPicker
                        adjustmentPanel
                        cropPanel
                        aiPanel
                        savePanel
                    }
                    .padding(.horizontal, 17)
                    .padding(.top, 12)
                    .padding(.bottom, 24)
                }
            }
        }
        .preferredColorScheme(.light)
        .alert("已保存副本", isPresented: $showSavedAlert) {
            Button("完成") {}
        } message: {
            Text(savedURL?.lastPathComponent ?? "编辑后的照片已保存到 POP CAM 相簿。")
        }
        .task {
            aiScale = preferredScale == 4 ? 4 : 2
            if startsWithAI {
                runAIEnhancement()
            }
        }
    }

    private var editorHeader: some View {
        HStack(spacing: 10) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Color(hex: 0x4A596B))
                    .frame(width: 42, height: 42)
                    .background(Color.white, in: Circle())
            }
            .buttonStyle(POPPressableStyle())

            VStack(alignment: .leading, spacing: 2) {
                Text("POP STUDIO")
                    .font(.system(size: 10, weight: .black, design: .rounded))
                    .tracking(2)
                    .foregroundStyle(Color(hex: 0x8B9DB0))
                Text("照片工坊")
                    .font(.system(size: 19, weight: .bold, design: .rounded))
                    .foregroundStyle(Color(hex: 0x354255))
            }

            Spacer()

            Button {
                undo()
            } label: {
                Image(systemName: "arrow.uturn.backward")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(canUndo ? Color(hex: 0x4F7599) : Color(hex: 0xB8C1CC))
                    .frame(width: 38, height: 38)
                    .background(Color.white, in: Circle())
            }
            .disabled(!canUndo)
            .buttonStyle(.plain)

            Button {
                redo()
            } label: {
                Image(systemName: "arrow.uturn.forward")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(canRedo ? Color(hex: 0x4F7599) : Color(hex: 0xB8C1CC))
                    .frame(width: 38, height: 38)
                    .background(Color.white, in: Circle())
            }
            .disabled(!canRedo)
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 17)
        .padding(.top, 12)
        .padding(.bottom, 7)
    }

    private var previewCard: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color.white)
            Image(uiImage: displayImage)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: .infinity)
                .frame(height: 300)
                .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
                .padding(10)
                .transition(.opacity)
            HStack(spacing: 6) {
                Image(systemName: showingEnhanced ? "sparkles" : "slider.horizontal.3")
                Text(showingEnhanced ? "AI 增强预览" : "实时预览")
            }
            .font(.system(size: 9, weight: .black, design: .rounded))
            .foregroundStyle(Color(hex: 0x556A83))
            .padding(.horizontal, 10)
            .frame(height: 27)
            .background(Color(hex: 0xE8F4FA), in: Capsule())
            .padding(17)
        }
        .frame(height: 320)
        .animation(.easeInOut(duration: 0.22), value: showingEnhanced)
    }

    private var comparisonControl: some View {
        HStack(spacing: 8) {
            comparisonButton("编辑结果", selected: !showingEnhanced) {
                withAnimation(.easeInOut(duration: 0.18)) { showingEnhanced = false }
            }
            comparisonButton("AI 超分", selected: showingEnhanced) {
                withAnimation(.easeInOut(duration: 0.18)) { showingEnhanced = true }
            }
        }
    }

    private func comparisonButton(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(Color(hex: 0x43536A))
                .frame(maxWidth: .infinity)
                .frame(height: 36)
                .background(selected ? Color(hex: 0xDCEEFF) : Color.white, in: Capsule())
        }
        .buttonStyle(POPPressableStyle())
    }

    private var presetPicker: some View {
        VStack(alignment: .leading, spacing: 9) {
            sectionTitle("快速风格", detail: "PRESETS")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    presetChip(.original, tint: 0xFFFFFF)
                    presetChip(.fresh, tint: 0xDDF2E5)
                    presetChip(.cream, tint: 0xFFF0D8)
                    presetChip(.pink, tint: 0xF9E1EB)
                    presetChip(.night, tint: 0xEAE3FA)
                }
            }
        }
    }

    private func presetChip(_ value: StudioPreset, tint: UInt32) -> some View {
        Button {
            pushUndo()
            withAnimation(.spring(response: 0.34, dampingFraction: 0.82)) {
                preset = value
                switch value {
                case .original:
                    exposure = 0; contrast = 1; saturation = 1; sharpness = 0
                case .fresh:
                    exposure = 0.18; contrast = 1.06; saturation = 1.12; sharpness = 0.14
                case .cream:
                    exposure = 0.10; contrast = 0.96; saturation = 0.88; sharpness = 0.05
                case .pink:
                    exposure = 0.08; contrast = 1.02; saturation = 1.08; sharpness = 0.08
                case .night:
                    exposure = -0.12; contrast = 1.18; saturation = 0.92; sharpness = 0.22
                }
                showingEnhanced = false
            }
        } label: {
            Text(value.title)
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(Color(hex: 0x43536A))
                .padding(.horizontal, 14)
                .frame(height: 36)
                .background(Color(hex: tint), in: Capsule())
                .overlay {
                    Capsule().stroke(preset == value ? Color(hex: 0x7FB9E8) : Color.white, lineWidth: preset == value ? 2 : 1)
                }
        }
        .buttonStyle(POPPressableStyle())
    }

    private var adjustmentPanel: some View {
        VStack(alignment: .leading, spacing: 13) {
            sectionTitle("精细调整", detail: "ADJUST")
            adjustmentSlider("曝光", value: $exposure, range: -2...2, valueText: String(format: "%+.1f EV", exposure), icon: "sun.max.fill")
            adjustmentSlider("对比度", value: $contrast, range: 0.5...1.8, valueText: String(format: "%.2f", contrast), icon: "circle.lefthalf.filled")
            adjustmentSlider("饱和度", value: $saturation, range: 0...1.8, valueText: String(format: "%.2f", saturation), icon: "drop.fill")
            adjustmentSlider("细节锐化", value: $sharpness, range: 0...1, valueText: String(format: "%.2f", sharpness), icon: "sparkle")
        }
        .padding(15)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private func adjustmentSlider(
        _ title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        valueText: String,
        icon: String
    ) -> some View {
        VStack(spacing: 5) {
            HStack(spacing: 7) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Color(hex: 0x8198B3))
                    .frame(width: 16)
                Text(title)
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(Color(hex: 0x526176))
                Spacer()
                Text(valueText)
                    .font(.system(size: 10, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(Color(hex: 0x8592A3))
            }
            Slider(value: value, in: range, onEditingChanged: { editing in
                if editing {
                    pushUndo()
                    showingEnhanced = false
                }
            })
            .tint(Color(hex: 0xE9CD67))
        }
    }

    private var cropPanel: some View {
        VStack(alignment: .leading, spacing: 9) {
            sectionTitle("画面比例", detail: "CROP")
            HStack(spacing: 8) {
                cropButton(.original)
                cropButton(.square)
                cropButton(.portrait)
                cropButton(.wide)
                Button {
                    pushUndo()
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                        rotationQuarterTurns = (rotationQuarterTurns + 1) % 4
                        showingEnhanced = false
                    }
                } label: {
                    Image(systemName: "rotate.right")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Color(hex: 0x586A7E))
                        .frame(width: 42, height: 38)
                        .background(Color.white, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("向右旋转九十度")
            }
        }
    }

    private func cropButton(_ value: StudioCropMode) -> some View {
        Button {
            pushUndo()
            withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
                cropMode = value
                showingEnhanced = false
            }
        } label: {
            Text(value.title)
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundStyle(Color(hex: 0x53647A))
                .frame(maxWidth: .infinity)
                .frame(height: 38)
                .background(cropMode == value ? Color(hex: 0xDCEEFF) : Color.white, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var aiPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(Color(hex: 0x9B83CE))
                    .frame(width: 36, height: 36)
                    .background(Color(hex: 0xF1ECFA), in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text("AI 超分 · Real-ESRGAN")
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundStyle(Color(hex: 0x3D4A59))
                    Text("提升细节，输出更高分辨率副本")
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundStyle(Color(hex: 0x8996A6))
                }
                Spacer()
                Menu {
                    Button("2× 增强") { aiScale = 2 }
                    Button("4× 增强") { aiScale = 4 }
                } label: {
                    Text("\(aiScale)×")
                        .font(.system(size: 11, weight: .heavy, design: .rounded))
                        .foregroundStyle(Color(hex: 0x695D8A))
                        .padding(.horizontal, 12)
                        .frame(height: 32)
                        .background(Color(hex: 0xF1ECFA), in: Capsule())
                }
            }

            if isEnhancing {
                VStack(spacing: 7) {
                    HStack {
                        ProgressView().tint(Color(hex: 0x9B83CE))
                        Text("AI 正在处理照片…")
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                            .foregroundStyle(Color(hex: 0x526176))
                        Spacer()
                        Text("\(Int(enhancementProgress * 100))%")
                            .font(.system(size: 10, weight: .bold, design: .rounded).monospacedDigit())
                            .foregroundStyle(Color(hex: 0x8996A6))
                    }
                    ProgressView(value: enhancementProgress)
                        .tint(Color(hex: 0xA991E2))
                }
            } else if let enhancementError {
                Text(enhancementError)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Color(hex: 0xB8485B))
            } else if enhancedImage != nil {
                Label("AI 增强已完成，可切换对比", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundStyle(Color(hex: 0x68A986))
            }

            Button(action: runAIEnhancement) {
                HStack(spacing: 8) {
                    Image(systemName: "sparkles")
                    Text(enhancedImage == nil ? "开始 AI 超分" : "重新进行 AI 超分")
                    Spacer()
                    Text("\(aiScale)×")
                        .font(.system(size: 10, weight: .black, design: .rounded))
                }
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundStyle(Color(hex: 0x4D4564))
                .padding(.horizontal, 14)
                .frame(height: 43)
                .background(Color(hex: 0xEAE3FA), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
            }
            .buttonStyle(POPPressableStyle())
            .disabled(isEnhancing)
            .opacity(isEnhancing ? 0.55 : 1)
        }
        .padding(15)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private var savePanel: some View {
        VStack(spacing: 9) {
            Button {
                let output = displayImage
                let isAI = showingEnhanced && enhancedImage != nil
                savedURL = onSaveCopy(output, isAI)
                showSavedAlert = savedURL != nil
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "square.and.arrow.down.fill")
                    Text(savedURL == nil ? "保存为新照片副本" : "再次保存副本")
                }
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundStyle(Color(hex: 0x3D4352))
                .frame(maxWidth: .infinity)
                .frame(height: 48)
                .background(Color(hex: 0xFFE45E), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
            }
            .buttonStyle(POPPressableStyle())

            if let savedURL {
                ShareLink(item: savedURL) {
                    Label("分享已保存的副本", systemImage: "square.and.arrow.up")
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundStyle(Color(hex: 0x597B9D))
                        .frame(maxWidth: .infinity)
                        .frame(height: 38)
                        .background(Color.white, in: Capsule())
                }
            }
        }
    }

    private func sectionTitle(_ title: String, detail: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .foregroundStyle(Color(hex: 0x3D4A59))
            Spacer()
            Text(detail)
                .font(.system(size: 8, weight: .black, design: .rounded))
                .tracking(1.5)
                .foregroundStyle(Color(hex: 0xA2ADBA))
        }
    }

    private func runAIEnhancement() {
        guard !isEnhancing else { return }
        let input = renderEditedImage()
        let scale = aiScale
        isEnhancing = true
        enhancementProgress = 0
        enhancementError = nil
        enhancedImage = nil
        showingEnhanced = false

        Task {
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try RealESRGANProcessor.enhance(image: input, scale: scale) { value in
                        DispatchQueue.main.async {
                            enhancementProgress = value
                        }
                    }
                }.value
                withAnimation(.spring(response: 0.42, dampingFraction: 0.84)) {
                    enhancedImage = result
                    showingEnhanced = true
                }
            } catch {
                enhancementError = error.localizedDescription
            }
            isEnhancing = false
        }
    }

    private func renderEditedImage() -> UIImage {
        guard var ciImage = CIImage(image: image) else { return image }

        if rotationQuarterTurns > 0 {
            for _ in 0..<rotationQuarterTurns {
                ciImage = ciImage.oriented(.right)
            }
        }

        if cropMode != .original {
            let extent = ciImage.extent
            let targetRatio = cropMode.ratio
            let sourceRatio = extent.width / max(extent.height, 1)
            let cropRect: CGRect
            if sourceRatio > targetRatio {
                let width = extent.height * targetRatio
                cropRect = CGRect(x: extent.midX - width / 2, y: extent.minY, width: width, height: extent.height)
            } else {
                let height = extent.width / targetRatio
                cropRect = CGRect(x: extent.minX, y: extent.midY - height / 2, width: extent.width, height: height)
            }
            ciImage = ciImage.cropped(to: cropRect)
        }

        if let exposureFilter = CIFilter(name: "CIExposureAdjust") {
            exposureFilter.setValue(ciImage, forKey: kCIInputImageKey)
            exposureFilter.setValue(exposure, forKey: kCIInputEVKey)
            ciImage = exposureFilter.outputImage ?? ciImage
        }

        if let colorFilter = CIFilter(name: "CIColorControls") {
            colorFilter.setValue(ciImage, forKey: kCIInputImageKey)
            colorFilter.setValue(contrast, forKey: kCIInputContrastKey)
            colorFilter.setValue(saturation, forKey: kCIInputSaturationKey)
            colorFilter.setValue(0.0, forKey: kCIInputBrightnessKey)
            ciImage = colorFilter.outputImage ?? ciImage
        }

        if sharpness > 0, let sharpenFilter = CIFilter(name: "CISharpenLuminance") {
            sharpenFilter.setValue(ciImage, forKey: kCIInputImageKey)
            sharpenFilter.setValue(sharpness, forKey: kCIInputSharpnessKey)
            ciImage = sharpenFilter.outputImage ?? ciImage
        }

        guard let output = Self.ciContext.createCGImage(ciImage, from: ciImage.extent) else { return image }
        return UIImage(cgImage: output, scale: image.scale, orientation: .up)
    }

    private func pushUndo() {
        undoStack.append(snapshot)
        if undoStack.count > 40 { undoStack.removeFirst() }
        redoStack.removeAll()
    }

    private var snapshot: StudioEditSnapshot {
        StudioEditSnapshot(
            exposure: exposure,
            contrast: contrast,
            saturation: saturation,
            sharpness: sharpness,
            rotationQuarterTurns: rotationQuarterTurns,
            cropMode: cropMode,
            preset: preset
        )
    }

    private func apply(_ snapshot: StudioEditSnapshot) {
        exposure = snapshot.exposure
        contrast = snapshot.contrast
        saturation = snapshot.saturation
        sharpness = snapshot.sharpness
        rotationQuarterTurns = snapshot.rotationQuarterTurns
        cropMode = snapshot.cropMode
        preset = snapshot.preset
        enhancedImage = nil
        showingEnhanced = false
    }

    private func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(snapshot)
        withAnimation(.spring(response: 0.34, dampingFraction: 0.82)) {
            apply(previous)
        }
    }

    private func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(snapshot)
        withAnimation(.spring(response: 0.34, dampingFraction: 0.82)) {
            apply(next)
        }
    }
}

private struct StudioEditSnapshot {
    let exposure: Double
    let contrast: Double
    let saturation: Double
    let sharpness: Double
    let rotationQuarterTurns: Int
    let cropMode: StudioCropMode
    let preset: StudioPreset
}

private enum StudioPreset: Equatable {
    case original
    case fresh
    case cream
    case pink
    case night

    var title: String {
        switch self {
        case .original: return "原片"
        case .fresh: return "清透"
        case .cream: return "奶油"
        case .pink: return "樱花"
        case .night: return "夜色"
        }
    }
}

private enum StudioCropMode: Equatable {
    case original
    case square
    case portrait
    case wide

    var title: String {
        switch self {
        case .original: return "原比例"
        case .square: return "1:1"
        case .portrait: return "4:5"
        case .wide: return "16:9"
        }
    }

    var ratio: CGFloat {
        switch self {
        case .original: return 0
        case .square: return 1
        case .portrait: return 4.0 / 5.0
        case .wide: return 16.0 / 9.0
        }
    }

    var next: StudioCropMode {
        switch self {
        case .original: return .square
        case .square: return .portrait
        case .portrait: return .wide
        case .wide: return .original
        }
    }
}

private struct AlbumInfoSheet: View {
    let url: URL

    @Environment(\.dismiss) private var dismiss

    private var attributes: [FileAttributeKey: Any] {
        (try? FileManager.default.attributesOfItem(atPath: url.path)) ?? [:]
    }

    private var fileSizeText: String {
        let bytes = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private var dateText: String {
        let date = (attributes[.creationDate] as? Date) ?? (attributes[.modificationDate] as? Date)
        return date?.formatted(date: .long, time: .shortened) ?? "未知"
    }

    private var dimensionsText: String {
        guard !url.isVideoMedia,
              let image = UIImage(contentsOfFile: url.path) else { return "—" }
        return "\(Int(image.size.width * image.scale)) × \(Int(image.size.height * image.scale))"
    }

    private var durationText: String {
        guard url.isVideoMedia else { return "—" }
        let secondsValue = CMTimeGetSeconds(AVURLAsset(url: url).duration)
        guard secondsValue.isFinite else { return "读取中" }
        let seconds = Int(max(0, secondsValue))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    var body: some View {
        NavigationStack {
            List {
                LabeledContent("类型", value: url.isVideoMedia ? "视频" : "照片")
                LabeledContent("拍摄/创建时间", value: dateText)
                LabeledContent("尺寸", value: dimensionsText)
                if url.isVideoMedia {
                    LabeledContent("时长", value: durationText)
                }
                LabeledContent("文件大小", value: fileSizeText)
                LabeledContent("文件名", value: url.lastPathComponent)
            }
            .scrollContentBackground(.hidden)
            .background(Color(hex: 0xF4F8FC))
            .navigationTitle("照片信息")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.light)
    }
}

private extension URL {
    var isVideoMedia: Bool {
        ["mov", "mp4"].contains(pathExtension.lowercased())
    }
}

private struct ShutterButtonStyle: View {
    let outerColors: [Color]
    let isVideo: Bool
    let isRecording: Bool

    var body: some View {
        ZStack {
            Circle()
                .fill(outerColors.first ?? Color(hex: 0xF18B89))
                .frame(width: 82, height: 82)
            Circle()
                .fill(Color.white)
                .frame(width: 64, height: 64)
            if !isVideo {
                Circle()
                    .stroke(Color(hex: 0xFF8A45).opacity(0.20), lineWidth: 1)
                    .frame(width: 56, height: 56)
            }
        }
    }
}

private struct FocusReticle: Shape {
    func path(in rect: CGRect) -> Path {
        let length = rect.width * 0.28
        let inset: CGFloat = 2
        var path = Path()

        // Four separate corner brackets, like the native camera focus target.
        path.move(to: CGPoint(x: inset, y: length))
        path.addLine(to: CGPoint(x: inset, y: inset))
        path.addLine(to: CGPoint(x: length, y: inset))

        path.move(to: CGPoint(x: rect.maxX - length, y: inset))
        path.addLine(to: CGPoint(x: rect.maxX - inset, y: inset))
        path.addLine(to: CGPoint(x: rect.maxX - inset, y: length))

        path.move(to: CGPoint(x: rect.maxX - inset, y: rect.maxY - length))
        path.addLine(to: CGPoint(x: rect.maxX - inset, y: rect.maxY - inset))
        path.addLine(to: CGPoint(x: rect.maxX - length, y: rect.maxY - inset))

        path.move(to: CGPoint(x: length, y: rect.maxY - inset))
        path.addLine(to: CGPoint(x: inset, y: rect.maxY - inset))
        path.addLine(to: CGPoint(x: inset, y: rect.maxY - length))
        return path
    }
}

private struct MultiPointAutofocusOverlay: View {
    let points: [AutofocusPoint]

    private let markerSize: CGFloat = 30

    var body: some View {
        GeometryReader { geometry in
            let horizontalInset = max(38, geometry.size.width * 0.10)
            let verticalInset = max(38, geometry.size.height * 0.08)

            ForEach(points) { point in
                AutofocusPointBracket()
                    .stroke(
                        Color(hex: 0x63F58B),
                        style: StrokeStyle(lineWidth: 2.1, lineCap: .round, lineJoin: .round)
                    )
                    .frame(width: markerSize, height: markerSize)
                    .scaleEffect(min(1.08, 0.94 + point.strength / 600))
                    .position(
                        x: min(max(point.location.x * geometry.size.width, horizontalInset), geometry.size.width - horizontalInset),
                        y: min(max(point.location.y * geometry.size.height, verticalInset), geometry.size.height - verticalInset)
                    )
                    .transition(
                        .asymmetric(
                            insertion: .scale(scale: 0.62).combined(with: .opacity),
                            removal: .scale(scale: 0.82).combined(with: .opacity)
                        )
                    )
            }
        }
        .animation(.spring(response: 0.38, dampingFraction: 0.78), value: points)
    }
}

private struct AutofocusPointBracket: Shape {
    func path(in rect: CGRect) -> Path {
        let length = rect.width * 0.32
        let inset: CGFloat = 1.5
        var path = Path()

        path.move(to: CGPoint(x: inset, y: length))
        path.addLine(to: CGPoint(x: inset, y: inset))
        path.addLine(to: CGPoint(x: length, y: inset))

        path.move(to: CGPoint(x: rect.maxX - length, y: inset))
        path.addLine(to: CGPoint(x: rect.maxX - inset, y: inset))
        path.addLine(to: CGPoint(x: rect.maxX - inset, y: length))

        path.move(to: CGPoint(x: rect.maxX - inset, y: rect.maxY - length))
        path.addLine(to: CGPoint(x: rect.maxX - inset, y: rect.maxY - inset))
        path.addLine(to: CGPoint(x: rect.maxX - length, y: rect.maxY - inset))

        path.move(to: CGPoint(x: length, y: rect.maxY - inset))
        path.addLine(to: CGPoint(x: inset, y: rect.maxY - inset))
        path.addLine(to: CGPoint(x: inset, y: rect.maxY - length))
        return path
    }
}

private struct HeaderIcon: View {
    let symbol: String
    var active = false
    var tint: Color = .white

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(active ? tint : Color(hex: 0x3D4352))
            .frame(width: 36, height: 36)
            .background(Color.white, in: Circle())
    }
}

private struct StabilizationPreviewHUD: View {
    let image: CGImage
    let rollDegrees: Double
    let pitchDegrees: Double
    let yawDegrees: Double
    let relativeRollDegrees: Double
    let visualMotion: VisualMotionEstimate
    let isStabilizationActive: Bool

    // The green frame combines measured frame-to-frame image translation with device attitude.
    // It is a visual motion estimate, not AVFoundation's actual EIS crop metadata.
    private var estimatedCropOffset: CGSize {
        CGSize(
            width: min(max(-CGFloat(yawDegrees * 0.55) - visualMotion.offsetX * 110, -18), 18),
            height: min(max(CGFloat(pitchDegrees * 0.55) - visualMotion.offsetY * 110, -18), 18)
        )
    }

    private var estimatedCropRotation: Double {
        min(max(-relativeRollDegrees * 0.45, -7), 7)
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .scaledToFill()
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .clipped()
                    .overlay(Color.black.opacity(0.24))

                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(
                        isStabilizationActive ? Color(hex: 0x83DFA6) : Color(hex: 0xFFE45E),
                        lineWidth: 2
                    )
                    .frame(
                        width: geometry.size.width * 0.78,
                        height: geometry.size.height * 0.78
                    )
                    .offset(estimatedCropOffset)
                    .rotationEffect(.degrees(estimatedCropRotation))
                    .animation(.interactiveSpring(response: 0.18, dampingFraction: 0.84), value: estimatedCropOffset)
                    .animation(.interactiveSpring(response: 0.18, dampingFraction: 0.84), value: estimatedCropRotation)

                VStack {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(isStabilizationActive ? Color(hex: 0x83DFA6) : Color(hex: 0xFFE45E))
                            .frame(width: 5, height: 5)
                        Text(visualMotion.confidence > 0.02 ? "VISUAL TRACK · \(Int(visualMotion.confidence * 100))%" : "VISUAL TRACKING…")
                            .font(.system(size: 6, weight: .heavy, design: .rounded))
                            .tracking(0.5)
                        Spacer(minLength: 0)
                    }
                    Spacer()
                }
                .padding(7)
            }
            .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        }
        .accessibilityLabel("防抖取景监视器，绿色框根据设备姿态动态移动，表示估算的稳定取景范围")
    }
}

@MainActor
private final class CameraLevelMonitor: ObservableObject {
    @Published private(set) var rollDegrees: Double = 0
    @Published private(set) var tiltDegrees: Double = 0
    @Published private(set) var shakeLevel: Double = 0
    @Published private(set) var stabilizationPitchDegrees: Double = 0
    @Published private(set) var stabilizationYawDegrees: Double = 0
    @Published private(set) var stabilizationRollDegrees: Double = 0

    private let manager = CMMotionManager()
    private var referenceAttitude: CMAttitude?
    private var stationarySince: TimeInterval?
    private var hasRecenteredAtRest = false

    func start() {
        guard manager.isDeviceMotionAvailable, !manager.isDeviceMotionActive else { return }
        referenceAttitude = nil
        stationarySince = nil
        hasRecenteredAtRest = false
        manager.deviceMotionUpdateInterval = 1.0 / 60.0

        let availableFrames = CMMotionManager.availableAttitudeReferenceFrames()
        let referenceFrame: CMAttitudeReferenceFrame =
            availableFrames.contains(.xArbitraryCorrectedZVertical)
                ? .xArbitraryCorrectedZVertical
                : .xArbitraryZVertical

        manager.startDeviceMotionUpdates(using: referenceFrame, to: .main) { [weak self] motion, _ in
            guard let self, let motion else { return }

            let absoluteRoll = Self.degrees(motion.attitude.roll)
            let absolutePitch = Self.degrees(motion.attitude.pitch)
            self.rollDegrees += (absoluteRoll - self.rollDegrees) * 0.28

            let combinedTilt = min(90, hypot(absoluteRoll, absolutePitch))
            self.tiltDegrees += (combinedTilt - self.tiltDegrees) * 0.24

            let acceleration = motion.userAcceleration
            let rotation = motion.rotationRate
            let accelerationMagnitude = sqrt(
                acceleration.x * acceleration.x +
                acceleration.y * acceleration.y +
                acceleration.z * acceleration.z
            )
            let rotationMagnitude = sqrt(
                rotation.x * rotation.x +
                rotation.y * rotation.y +
                rotation.z * rotation.z
            )
            let measuredShake = min(1, max(accelerationMagnitude / 0.65, rotationMagnitude / 3.2))
            let smoothing: Double = measuredShake > self.shakeLevel ? 0.42 : 0.16
            self.shakeLevel += (measuredShake - self.shakeLevel) * smoothing

            // The first reference attitude may be captured while the phone is
            // lying flat. If the user then raises it into the normal portrait
            // shooting position, a fixed reference makes the estimated EIS
            // crop frame stay displaced even after the phone becomes steady.
            // Re-acquire the neutral pose after a short stationary interval so
            // the guide recenters in both flat and handheld shooting positions.
            let isStationary = rotationMagnitude < 0.12 && accelerationMagnitude < 0.045
            if isStationary {
                if self.stationarySince == nil {
                    self.stationarySince = motion.timestamp
                }
                if !self.hasRecenteredAtRest,
                   let stationarySince = self.stationarySince,
                   motion.timestamp - stationarySince >= 0.75 {
                    self.referenceAttitude = motion.attitude.copy() as? CMAttitude
                    self.hasRecenteredAtRest = true
                }
            } else {
                self.stationarySince = nil
                self.hasRecenteredAtRest = false
            }

            guard let reference = self.referenceAttitude else {
                self.referenceAttitude = motion.attitude.copy() as? CMAttitude
                self.stabilizationPitchDegrees = 0
                self.stabilizationYawDegrees = 0
                self.stabilizationRollDegrees = 0
                return
            }

            let relative = motion.attitude.copy() as! CMAttitude
            relative.multiply(byInverseOf: reference)

            let pitch = Self.wrappedDegrees(relative.pitch)
            let yaw = Self.wrappedDegrees(relative.yaw)
            let roll = Self.wrappedDegrees(relative.roll)

            // Low-pass the pose deltas so the crop guide follows motion smoothly
            // instead of jittering with every individual sensor sample.
            self.stabilizationPitchDegrees += (pitch - self.stabilizationPitchDegrees) * 0.32
            self.stabilizationYawDegrees += (yaw - self.stabilizationYawDegrees) * 0.32
            self.stabilizationRollDegrees += (roll - self.stabilizationRollDegrees) * 0.32
        }
    }

    func stop() {
        guard manager.isDeviceMotionActive else { return }
        manager.stopDeviceMotionUpdates()
        referenceAttitude = nil
        stationarySince = nil
        hasRecenteredAtRest = false
        stabilizationPitchDegrees = 0
        stabilizationYawDegrees = 0
        stabilizationRollDegrees = 0
        tiltDegrees = 0
        shakeLevel = 0
    }

    private static func degrees(_ radians: Double) -> Double {
        radians * 180 / .pi
    }

    private static func wrappedDegrees(_ radians: Double) -> Double {
        (degrees(radians) + 540).truncatingRemainder(dividingBy: 360) - 180
    }
}


private struct MotionStatusWindow: View {
    let isLevel: Bool
    let rollDegrees: Double
    let tiltDegrees: Double
    let shakeLevel: Double
    let stabilizationEnabled: Bool
    let isStabilizationSupported: Bool

    private var shakeDescription: String {
        if shakeLevel < 0.12 { return "稳定" }
        if shakeLevel < 0.42 { return "轻微" }
        return "明显"
    }

    private var stabilizationDescription: String {
        if !stabilizationEnabled { return "已关闭" }
        return isStabilizationSupported ? "模式已启用" : "当前模式不支持"
    }

    private var stabilizationTint: Color {
        if !stabilizationEnabled { return Color(hex: 0x9AA4B1) }
        return isStabilizationSupported ? Color(hex: 0x83DFA6) : Color(hex: 0xFFE45E)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 6) {
                Image(systemName: "waveform.path")
                    .font(.system(size: 12, weight: .bold))
                Text("运动状态")
                    .font(.system(size: 12, weight: .heavy, design: .rounded))
                    .tracking(0.5)
                Spacer()
                Circle()
                    .fill(Color(hex: 0x83DFA6))
                    .frame(width: 5, height: 5)
            }
            .foregroundStyle(Color(hex: 0x3D4352))

            statusRow("水平参考线", value: isLevel ? "水平" : "未水平", tint: isLevel ? Color(hex: 0x83DFA6) : Color(hex: 0xFFE45E)) {
                ZStack {
                    Capsule().fill(Color(hex: 0x9AA4B1).opacity(0.42)).frame(width: 24, height: 2)
                    Capsule().fill(isLevel ? Color(hex: 0x83DFA6) : Color(hex: 0xFFE45E)).frame(width: 18, height: 2)
                }
                .rotationEffect(.degrees(-rollDegrees))
                .frame(width: 26, height: 12)
            }

            statusRow("倾斜角度", value: String(format: "%.1f°", tiltDegrees), tint: Color(hex: 0x6E9DCE)) {
                Image(systemName: "angle")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Color(hex: 0x6E9DCE))
            }

            VStack(spacing: 3) {
                HStack(spacing: 5) {
                    Image(systemName: "move.3d")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Color(hex: 0x8D83C9))
                        .frame(width: 14)
                    Text("晃动指示")
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color(hex: 0x343B49))
                    Spacer(minLength: 2)
                    Text("\(shakeDescription)  \(Int((shakeLevel * 100).rounded()))%")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(Color(hex: 0x252C39))
                }
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color(hex: 0xDCE4EC).opacity(0.72))
                        Capsule()
                            .fill(shakeLevel < 0.12 ? Color(hex: 0x83DFA6) : shakeLevel < 0.42 ? Color(hex: 0xFFE45E) : Color(hex: 0xF18B89))
                            .frame(width: geometry.size.width * min(max(shakeLevel, 0), 1))
                    }
                }
                .frame(height: 3)
                .padding(.leading, 19)
            }

            statusRow("防抖状态", value: stabilizationDescription, tint: stabilizationTint) {
                Image(systemName: stabilizationEnabled && isStabilizationSupported ? "viewfinder" : "viewfinder.circle")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(stabilizationTint)
            }
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("运动状态窗口：\(isLevel ? "水平" : "未水平")，倾斜角度 \(String(format: "%.1f", tiltDegrees)) 度，晃动 \(shakeDescription)，防抖\(stabilizationDescription)")
    }

    private func statusRow<Accessory: View>(
        _ title: String,
        value: String,
        tint: Color,
        @ViewBuilder accessory: () -> Accessory
    ) -> some View {
        HStack(spacing: 5) {
            accessory()
                .frame(width: 26, height: 12)
            Text(title)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(Color(hex: 0x252C39))
            Spacer(minLength: 2)
            Text(value)
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.78)
                .foregroundStyle(tint)
        }
    }
}


private struct MacaronPalette: Identifiable {
    let id: String
    let name: String
    let background: [UInt32]
    let accent: UInt32
    let secondaryAccent: UInt32

    static let all: [MacaronPalette] = [
        .init(id: "sakura", name: "樱花粉", background: [0xFFF0F4, 0xFCE4EC, 0xF7EAF8], accent: 0xF48BA8, secondaryAccent: 0xC6A4E8),
        .init(id: "cream", name: "奶油杏", background: [0xFFF4E8, 0xFFE8D5, 0xFBEBDD], accent: 0xE9A36F, secondaryAccent: 0xE9C18B),
        .init(id: "mint", name: "薄荷绿", background: [0xE9F8EF, 0xDDF3E7, 0xEAF7F2], accent: 0x75C99A, secondaryAccent: 0x8CCFC4),
        .init(id: "sky", name: "天空蓝", background: [0xEAF5FF, 0xDDEEFF, 0xE9F1FF], accent: 0x78B8EE, secondaryAccent: 0x9AAFEA),
        .init(id: "lavender", name: "薰衣紫", background: [0xF3EDFF, 0xEAE2FA, 0xF5EDFF], accent: 0xA991E2, secondaryAccent: 0xC3A5E8),
        .init(id: "aqua", name: "海盐青", background: [0xE5F8F8, 0xD9F2F3, 0xE8F7F4], accent: 0x69C4C8, secondaryAccent: 0x8CCFC4),
        .init(id: "peach", name: "蜜桃橙", background: [0xFFF0E8, 0xFFE3D8, 0xFFF1E7], accent: 0xF39A75, secondaryAccent: 0xF2BD8A),
        .init(id: "lemon", name: "柠檬黄", background: [0xFFF9DF, 0xFFF1C9, 0xFFF8E7], accent: 0xE6C85C, secondaryAccent: 0xE8B77D),
        .init(id: "berry", name: "莓果紫", background: [0xF8ECFA, 0xF1E2F7, 0xF9EFF8], accent: 0xC18BCF, secondaryAccent: 0xD5A4C9),
        .init(id: "mist", name: "雾霾蓝", background: [0xEAF0FA, 0xE0E8F6, 0xEDF1FA], accent: 0x8EA9D4, secondaryAccent: 0xA9B7D8),
        .init(id: "grass", name: "青草绿", background: [0xEEF8E8, 0xE3F2D9, 0xF1F7E9], accent: 0x91C879, secondaryAccent: 0xB3CE83),
        .init(id: "sorbet", name: "冰淇淋", background: [0xEAF8F8, 0xF0EAFE, 0xFCEAF3], accent: 0x9BADD9, secondaryAccent: 0xD9A6C9)
    ]
}


private enum CameraToolMode {
    case filters
    case superResolution
    case autofocus
}

private enum CaptureBarMode: Equatable {
    case video
    case menu
    case zoom
    case exposure
    case focus
    case grid
    case level
}
