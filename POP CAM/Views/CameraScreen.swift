import AVFoundation
import AVKit
import CoreMotion
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
    @State private var showGrid = false
    @State private var showLevel = false
    @State private var zoom: Double = 1
    @State private var exposure: Double = 0
    @State private var manualFocusIndicatorPoint: CGPoint?
    @State private var manualFocusIndicatorID = 0
    @State private var selectedVideoResolution = "4K"
    @State private var selectedFrameRate = "60"
    @State private var hdrEnabled = true

    private var selectedPalette: MacaronPalette {
        MacaronPalette.all.first(where: { $0.id == selectedPaletteID }) ?? MacaronPalette.all[0]
    }

    var body: some View {
        ZStack {
            // Soft macaron canvas fills everything outside the live viewfinder.
            LinearGradient(
                colors: selectedPalette.background.map { Color(hex: $0) },
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            // Keep the live camera image strictly inside the viewfinder window.
            // The surrounding area remains the macaron-colored app canvas.
            GeometryReader { previewGeometry in
                let width = previewGeometry.size.width * 0.86
                let height = min(width * 4 / 3, previewGeometry.size.height * 0.60)
                let cornerRadius: CGFloat = 28
                let centerX = previewGeometry.size.width / 2
                let centerY = previewGeometry.size.height * 0.475

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
                            .stroke(camera.isRecording ? Color(hex: 0xFF4058) : .clear, lineWidth: camera.isRecording ? 4 : 0)
                            .shadow(color: camera.isRecording ? Color(hex: 0xFF4058).opacity(0.55) : .clear, radius: 9)
                    }
                    .overlay(alignment: .topLeading) {
                        if camera.isRecording {
                            HStack(spacing: 7) {
                                Circle().fill(Color(hex: 0xFF4058)).frame(width: 7, height: 7)
                                Text(String(format: "REC  %02d:%02d", Int(camera.recordingDuration) / 60, Int(camera.recordingDuration) % 60))
                                    .font(.system(size: 12, weight: .heavy, design: .rounded).monospacedDigit())
                                    .foregroundStyle(Color(hex: 0xFF4058))
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(.ultraThinMaterial, in: Capsule())
                            .padding(12)
                        }
                    }
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

                    if showLevel {
                        levelIndicator
                            .position(x: width / 2, y: height * 0.13)
                            .allowsHitTesting(false)
                    }

                    if activeTool == .autofocus {
                        if camera.autofocusPoints.isEmpty {
                            FocusReticle()
                                .stroke(
                                    Color(hex: 0x63F58B),
                                    style: StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round)
                                )
                                .frame(width: 58, height: 58)
                                .shadow(color: Color(hex: 0x40E878).opacity(0.58), radius: 5)
                                .position(x: width / 2, y: height / 2)
                                .transition(.scale(scale: 0.72).combined(with: .opacity))
                                .allowsHitTesting(false)
                        } else {
                            MultiPointAutofocusOverlay(
                                points: projectedAutofocusPoints(in: CGSize(width: width, height: height))
                            )
                            .frame(width: width, height: height)
                            .transition(.opacity)
                            .allowsHitTesting(false)
                        }
                    }
                    if let manualFocusIndicatorPoint {
                        FocusReticle()
                            .stroke(
                                Color(hex: 0xFFE45E),
                                style: StrokeStyle(lineWidth: 2.4, lineCap: .round, lineJoin: .round)
                            )
                            .frame(width: 58, height: 58)
                            .shadow(color: .black.opacity(0.28), radius: 3)
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
                        .background {
                            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                                .fill(Color.white.opacity(0.92))
                                .overlay {
                                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                                        .stroke(Color.white.opacity(0.98), lineWidth: 1)
                                }
                                .shadow(color: .black.opacity(0.12), radius: 10, y: 3)
                        }
                        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                        .position(x: width / 2, y: height - 56)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .zIndex(20)
                    }
                }
                .frame(width: width, height: height)
                .position(x: centerX, y: centerY)
            }
            .ignoresSafeArea()
            .overlay {
                // A subtle tint keeps the camera image visually integrated
                // without drawing a visible border around the viewfinder.
                LinearGradient(
                    colors: [.black.opacity(0.10), .clear, .black.opacity(0.12)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .mask {
                    GeometryReader { maskGeometry in
                        RoundedRectangle(cornerRadius: 28, style: .continuous)
                            .frame(
                                width: maskGeometry.size.width * 0.86,
                                height: min(maskGeometry.size.width * 0.86 * 4 / 3, maskGeometry.size.height * 0.60)
                            )
                            .position(
                                x: maskGeometry.size.width / 2,
                                y: maskGeometry.size.height * 0.475
                            )
                    }
                }
                .ignoresSafeArea()
                .allowsHitTesting(false)
            }

            if let countdown {
                Text("\(countdown)")
                    .font(.system(size: 100, weight: .black, design: .rounded))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.4), radius: 18)
                    .transition(.scale.combined(with: .opacity))
            }

            GeometryReader { geometry in
                VStack(spacing: 0) {
                    header
                    captureFormatBar
                        .padding(.top, 8)
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
                .presentationCornerRadius(28)
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showAlbum) {
            LocalMediaAlbumSheet(
                media: camera.savedMediaURLs,
                onDelete: { url in camera.deleteAlbumMedia(at: url) }
            )
            .presentationDetents([.large])
            .presentationCornerRadius(28)
            .presentationDragIndicator(.visible)
        }
        .onChange(of: camera.captureID) { _, _ in
            showReview = true
        }
        .onChange(of: activeTool == .autofocus && !camera.isExposureFocusLocked) { _, enabled in
            camera.setAutofocusVisualizationEnabled(enabled)
        }
        .onAppear {
            camera.prepare()
            camera.setAutofocusVisualizationEnabled(activeTool == .autofocus && !camera.isExposureFocusLocked)
            if showLevel { levelMonitor.start() }
        }
        .onChange(of: selectedVideoResolution) { _, _ in
            camera.configureVideo(resolution: selectedVideoResolution, frameRate: Int(selectedFrameRate) ?? 30, hdrEnabled: hdrEnabled)
        }
        .onChange(of: selectedFrameRate) { _, _ in
            camera.configureVideo(resolution: selectedVideoResolution, frameRate: Int(selectedFrameRate) ?? 30, hdrEnabled: hdrEnabled)
        }
        .onChange(of: hdrEnabled) { _, _ in
            camera.configureVideo(resolution: selectedVideoResolution, frameRate: Int(selectedFrameRate) ?? 30, hdrEnabled: hdrEnabled)
        }
        .onChange(of: camera.isReady) { _, ready in
            // Keep launch on the camera's native safe format. The selected
            // recording format is applied when the user changes a format
            // control or starts recording.
            if !ready {
                camera.setAutofocusVisualizationEnabled(false)
            }
        }
        .onChange(of: camera.videoConfigurationRevision) { _, _ in
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
        }
        .onChange(of: showLevel) { _, enabled in
            if enabled { levelMonitor.start() } else { levelMonitor.stop() }
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
        .background(Color.white.opacity(0.76), in: Capsule())
        .overlay(Capsule().stroke(Color.white.opacity(0.92), lineWidth: 1))
        .shadow(color: Color(hex: 0x8E9AAC).opacity(0.12), radius: 8, y: 3)
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
            .background(Color.white.opacity(0.90), in: Capsule())
            .overlay(Capsule().stroke(Color.white, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .padding(6)
        .background(Color.white.opacity(0.72), in: Capsule())
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
        .background(Color.white.opacity(0.90), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Color.white, lineWidth: 1))
        .shadow(color: Color(hex: 0x8E9AAC).opacity(0.12), radius: 7, y: 2)
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
        .background(Color.white.opacity(0.90), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Color.white, lineWidth: 1))
        .shadow(color: Color(hex: 0x8E9AAC).opacity(0.12), radius: 7, y: 2)
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
                    ? Color(hex: selectedPalette.background[0]).opacity(0.98)
                    : Color.white.opacity(0.68),
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
                    .fill(isLevel ? Color(hex: 0x83DFA6) : .white.opacity(0.9))
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
        .background(.black.opacity(0.48), in: Capsule())
        .overlay(Capsule().stroke(.white.opacity(0.22), lineWidth: 1))
    }

    private var zoomControl: some View {
        HStack(spacing: 9) {
            zoomButton(0.5)
            zoomButton(1)
            zoomButton(2)
            zoomButton(3)
        }
        .padding(5)
        .padding(4)
        .background(Color.white.opacity(0.76), in: Capsule())
        .overlay(Capsule().stroke(Color.white.opacity(0.92), lineWidth: 1))
        .shadow(color: Color(hex: 0x8E9AAC).opacity(0.16), radius: 10, y: 4)
    }

    private func zoomButton(_ value: Double) -> some View {
        Button {
            zoom = value
            camera.setZoom(CGFloat(value))
        } label: {
            Text(value == 0.5 ? "0.5×" : (value == 1 ? "1×" : "\(Int(value))×"))
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundStyle(Color(hex: 0x3D4352))
                .frame(maxWidth: .infinity)
                .frame(height: 34)
                .background {
                    if abs(zoom - value) < 0.01 {
                        Capsule().fill(Color(hex: 0xFFE45E))
                    }
                }
        }
        .buttonStyle(.plain)
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
                                .fill(.white.opacity(0.18))
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
                        .background(Color.white.opacity(0.58), in: RoundedRectangle(cornerRadius: 10))
                    }
                    .buttonStyle(.plain)
                    Spacer()
                    Button(action: triggerAutofocus) {
                        ZStack(alignment: .topTrailing) {
                            Circle()
                                .fill(Color.white.opacity(0.86))
                                .frame(width: 48, height: 48)
                                .overlay(Circle().stroke(Color.white, lineWidth: 1))
                            Image(systemName: "viewfinder")
                                .font(.system(size: 19, weight: .semibold))
                                .foregroundStyle(Color(hex: 0x3D4352))
                                .frame(width: 48, height: 48)
                            Circle()
                                .fill(camera.focusStatus == .focused ? Color(hex: 0x32D46A) : Color(hex: 0xAAB3BE))
                                .frame(width: 8, height: 8)
                                .overlay(Circle().stroke(Color.white, lineWidth: 1.2))
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
                .frame(height: 30)
                .background(Color.white.opacity(0.82), in: Capsule())
            }
            .disabled(camera.isRecording || camera.isVideoConfigurationInProgress)

            Menu {
                Button("60 FPS") { selectedFrameRate = "60" }
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
                .frame(height: 30)
                .background(Color.white.opacity(0.82), in: Capsule())
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
                    .frame(height: 30)
                    .background(hdrEnabled ? Color(hex: 0xFFE45E) : Color.white.opacity(0.72), in: Capsule())
            }
            .disabled(camera.isRecording || camera.isVideoConfigurationInProgress)

            Spacer(minLength: 0)
            Text("H.265")
                .font(.system(size: 8, weight: .semibold, design: .rounded))
                .foregroundStyle(Color(hex: 0x778091))
            Rectangle().fill(Color(hex: 0xC9D4DE)).frame(width: 1, height: 18)
            Text("10-bit")
                .font(.system(size: 8, weight: .semibold, design: .rounded))
                .foregroundStyle(Color(hex: 0x778091))
            Menu {
                Button("H.265") {}
                Button("10-bit HDR") {}
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Color(hex: 0x596171))
                    .frame(width: 28, height: 28)
                    .background(Color.white.opacity(0.82), in: Circle())
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(Color.white.opacity(0.62), in: Capsule())
        .overlay(Capsule().stroke(Color.white.opacity(0.92), lineWidth: 1))
        .shadow(color: Color(hex: 0x8E9AAC).opacity(0.10), radius: 8, y: 2)
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
                .foregroundStyle(.white)
            Text("开启相机权限后，就可以开始拍照啦。")
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.68))
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
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 28))
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
                        .background(Color.white.opacity(0.82), in: Capsule())
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
                                        ? Color.white.opacity(0.95)
                                        : Color.white.opacity(0.52),
                                    in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                                )
                                .overlay {
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .stroke(
                                            selectedPaletteID == palette.id ? Color(hex: palette.accent) : Color.white.opacity(0.8),
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
                .background(Color.white.opacity(0.78), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(.white, lineWidth: 1))

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
                .background(Color.white.opacity(0.78), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(.white, lineWidth: 1))

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
                .background(Color.white.opacity(0.78), in: RoundedRectangle(cornerRadius: 18, style: .continuous))

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
                    Slider(value: $zoom, in: 1...5, step: 0.1)
                        .tint(Color(hex: selectedPalette.secondaryAccent))
                        .onChange(of: zoom) { _, value in
                            camera.setZoom(CGFloat(value))
                        }
                }
                .padding(16)
                .background(Color.white.opacity(0.78), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
            .padding(22)
        }
        .background(
            LinearGradient(
                colors: selectedPalette.background.map { Color(hex: $0) },
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
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
        let shouldEnable = activeTool != .autofocus
        withAnimation(.spring(response: 0.30, dampingFraction: 0.86)) {
            activeTool = shouldEnable ? .autofocus : .filters
            isToolPanelExpanded = false
        }
        camera.setAutofocusVisualizationEnabled(shouldEnable && !camera.isExposureFocusLocked)
        if shouldEnable {
            camera.focus(at: CGPoint(x: 0.5, y: 0.5))
        }
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

    @State private var selectedFilter = AlbumMediaFilter.all

    private var filteredMedia: [URL] {
        media.filter { url in
            switch selectedFilter {
            case .all: return true
            case .photos: return !url.isVideoMedia
            case .videos: return url.isVideoMedia
            }
        }
    }

    private let columns = [
        GridItem(.flexible(), spacing: 9),
        GridItem(.flexible(), spacing: 9),
        GridItem(.flexible(), spacing: 9)
    ]

    var body: some View {
        NavigationStack {
            VStack(spacing: 14) {
                HStack(spacing: 8) {
                    filterButton("全部", filter: .all, count: media.count)
                    filterButton("照片", filter: .photos, count: media.filter { !$0.isVideoMedia }.count)
                    filterButton("视频", filter: .videos, count: media.filter(\.isVideoMedia).count)
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)

                if filteredMedia.isEmpty {
                    ContentUnavailableView(
                        selectedFilter == .videos ? "还没有视频" : selectedFilter == .photos ? "还没有照片" : "相册还是空的",
                        systemImage: selectedFilter == .videos ? "video" : "photo.on.rectangle.angled",
                        description: Text("在 POP CAM 拍摄并保存的照片和视频，会显示在这里。")
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 10) {
                            ForEach(filteredMedia, id: \.absoluteString) { url in
                                NavigationLink {
                                    LocalAlbumDetailView(url: url, onDelete: onDelete)
                                } label: {
                                    LocalAlbumThumbnail(url: url)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 14)
                        .padding(.bottom, 22)
                    }
                }
            }
            .background(
                LinearGradient(
                    colors: [Color(hex: 0xFCEBF1), Color(hex: 0xF1ECFA), Color(hex: 0xE8F4FA)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .navigationTitle("POP CAM 相册")
            .navigationBarTitleDisplayMode(.inline)
        }
        .preferredColorScheme(.light)
    }

    private func filterButton(_ title: String, filter: AlbumMediaFilter, count: Int) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.18)) {
                selectedFilter = filter
            }
        } label: {
            HStack(spacing: 5) {
                Text(title)
                Text("\(count)").monospacedDigit().opacity(0.68)
            }
            .font(.system(size: 11, weight: .bold, design: .rounded))
            .foregroundStyle(Color(hex: 0x3D4352))
            .frame(maxWidth: .infinity)
            .frame(height: 34)
            .background(
                selectedFilter == filter ? Color.white.opacity(0.96) : Color.white.opacity(0.48),
                in: Capsule()
            )
            .overlay(Capsule().stroke(Color.white.opacity(0.95), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

private enum AlbumMediaFilter {
    case all
    case photos
    case videos
}

private struct LocalAlbumThumbnail: View {
    let url: URL

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            if url.isVideoMedia {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(Color(hex: 0xE4EAF2))
                Image(systemName: "video.fill")
                    .font(.system(size: 27, weight: .semibold))
                    .foregroundStyle(Color(hex: 0xF26F82))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let image = UIImage(contentsOfFile: url.path) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(Color.white.opacity(0.65))
                Image(systemName: "photo")
                    .font(.system(size: 24))
                    .foregroundStyle(Color(hex: 0x87909E))
            }

            HStack(spacing: 4) {
                Image(systemName: url.isVideoMedia ? "play.fill" : "photo")
                    .font(.system(size: 8, weight: .bold))
                Text(url.isVideoMedia ? "视频" : "照片")
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                Spacer(minLength: 0)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 7)
            .padding(.vertical, 5)
            .background(.black.opacity(0.38), in: Capsule())
            .padding(6)
        }
        .frame(height: 118)
        .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .stroke(Color.white.opacity(0.95), lineWidth: 1)
        )
    }
}

private struct LocalAlbumDetailView: View {
    let url: URL
    let onDelete: (URL) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?
    @State private var image: UIImage?
    @State private var showDeleteConfirmation = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if url.isVideoMedia {
                if let player {
                    VideoPlayer(player: player)
                        .onAppear { player.play() }
                } else {
                    ProgressView().tint(.white)
                }
            } else if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .padding(10)
            } else {
                ContentUnavailableView("无法读取媒体", systemImage: "photo")
                    .foregroundStyle(.white)
            }
        }
        .navigationTitle(url.isVideoMedia ? "视频" : "照片")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                ShareLink(item: url) {
                    Image(systemName: "square.and.arrow.up")
                }
                Button(role: .destructive) {
                    showDeleteConfirmation = true
                } label: {
                    Image(systemName: "trash")
                }
            }
        }
        .confirmationDialog("删除这项媒体？", isPresented: $showDeleteConfirmation, titleVisibility: .visible) {
            Button("删除", role: .destructive) {
                player?.pause()
                onDelete(url)
                dismiss()
            }
            Button("取消", role: .cancel) {}
        }
        .onAppear {
            if url.isVideoMedia {
                player = AVPlayer(url: url)
                player?.play()
            } else {
                image = UIImage(contentsOfFile: url.path)
            }
        }
        .onDisappear {
            player?.pause()
            player = nil
        }
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
                .fill(LinearGradient(colors: outerColors, startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 82, height: 82)
                .shadow(color: outerColors.first?.opacity(0.34) ?? .clear, radius: 16, y: 5)
            Circle()
                .fill(Color.white)
                .frame(width: 64, height: 64)
            if isVideo {
                if isRecording {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(Color(hex: 0xFF5967))
                        .frame(width: 22, height: 22)
                } else {
                    HStack(spacing: 1) {
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(Color(hex: 0xFF5967))
                            .frame(width: 19, height: 16)
                        Path { path in
                            path.move(to: CGPoint(x: 0, y: 3))
                            path.addLine(to: CGPoint(x: 10, y: 0))
                            path.addLine(to: CGPoint(x: 10, y: 16))
                            path.addLine(to: CGPoint(x: 0, y: 13))
                            path.closeSubpath()
                        }
                        .fill(Color(hex: 0xFF5967))
                        .frame(width: 10, height: 16)
                    }
                }
            } else {
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
                    .shadow(color: Color(hex: 0x40E878).opacity(0.52), radius: 4)
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
            .background(Color.white.opacity(0.78), in: Circle())
            .overlay(Circle().stroke(.white.opacity(0.94), lineWidth: 1))
            .shadow(color: Color(hex: 0x8E9AAC).opacity(0.12), radius: 7, y: 3)
    }
}

@MainActor
private final class CameraLevelMonitor: ObservableObject {
    @Published private(set) var rollDegrees: Double = 0
    private let manager = CMMotionManager()

    func start() {
        guard manager.isDeviceMotionAvailable, !manager.isDeviceMotionActive else { return }
        manager.deviceMotionUpdateInterval = 1.0 / 30.0
        manager.startDeviceMotionUpdates(to: .main) { [weak self] motion, _ in
            guard let motion else { return }
            self?.rollDegrees = motion.attitude.roll * 180 / .pi
        }
    }

    func stop() {
        guard manager.isDeviceMotionActive else { return }
        manager.stopDeviceMotionUpdates()
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
