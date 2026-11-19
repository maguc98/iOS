import AVFoundation
import CoreMotion
import SwiftUI
import UIKit

struct CameraScreen: View {
    @StateObject private var camera = CameraService()
    @StateObject private var levelMonitor = CameraLevelMonitor()
    @State private var timerSeconds = 0
    @State private var countdown: Int?
    @State private var showReview = false
    @State private var showSettings = false
    @State private var showFilters = false
    @State private var showGrid = false
    @State private var showLevel = false
    @State private var zoom: Double = 1
    @State private var exposure: Double = 0
    @State private var focusIndicatorPoint: CGPoint?
    @State private var focusIndicatorID = 0

    var body: some View {
        ZStack {
            // Soft macaron canvas fills everything outside the live viewfinder.
            LinearGradient(
                colors: [
                    Color(hex: 0xE8F4FA),
                    Color(hex: 0xF1ECFA),
                    Color(hex: 0xFCEBF1),
                    Color(hex: 0xEAF5E9)
                ],
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
                let centerY = previewGeometry.size.height * 0.395

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
                    .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                    .onTapGesture(coordinateSpace: .local) { location in
                        let normalizedPoint = CGPoint(
                            x: min(max(location.x / width, 0), 1),
                            y: min(max(location.y / height, 0), 1)
                        )
                        camera.focus(at: normalizedPoint)
                        focusIndicatorID += 1
                        let currentID = focusIndicatorID
                        withAnimation(.spring(response: 0.22, dampingFraction: 0.7)) {
                            focusIndicatorPoint = location
                        }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) {
                            guard focusIndicatorID == currentID else { return }
                            withAnimation(.easeOut(duration: 0.25)) {
                                focusIndicatorPoint = nil
                            }
                        }
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

                    if let focusIndicatorPoint {
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .stroke(Color(hex: 0xFFE45E), lineWidth: 2)
                            .frame(width: 54, height: 54)
                            .shadow(color: .black.opacity(0.25), radius: 3)
                            .position(focusIndicatorPoint)
                            .transition(.scale.combined(with: .opacity))
                            .allowsHitTesting(false)
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
                                y: maskGeometry.size.height * 0.395
                            )
                    }
                }
                .ignoresSafeArea()
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
                    Spacer(minLength: 18)
                    filterPicker
                        .padding(.bottom, 8)
                    zoomControl
                        .padding(.bottom, 10)
                    shutterControls
                    modeFooter
                        .padding(.top, 10)
                }
                .padding(.horizontal, 16)
                .padding(.top, 10)
                .padding(.bottom, 12)
                // Keep every control inside the physical screen viewport.
                .frame(width: geometry.size.width, height: geometry.size.height)
            }

            if !camera.isAuthorized {
                permissionCard
            }
        }
        .statusBarHidden()
        .sheet(isPresented: $showReview) {
            if let image = camera.capturedImage {
                PhotoReviewView(
                    image: image,
                    onSave: { completion in
                        camera.saveCapturedPhoto(completion: completion)
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
        .onChange(of: camera.captureID) { _, _ in
            showReview = true
        }
        .onAppear {
            camera.prepare()
            if showLevel { levelMonitor.start() }
        }
        .onChange(of: showLevel) { _, enabled in
            if enabled { levelMonitor.start() } else { levelMonitor.stop() }
        }
        .onDisappear { levelMonitor.stop() }
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

    private var filterPicker: some View {
        VStack(spacing: 8) {
            if showFilters {
                HStack {
                    Text("选择滤镜")
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundStyle(Color(hex: 0x3D4352))
                    Spacer()
                    Button {
                        withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
                            showFilters = false
                        }
                    } label: {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(Color(hex: 0x596171))
                            .frame(width: 28, height: 28)
                            .background(Color.white.opacity(0.72), in: Circle())
                    }
                    .buttonStyle(.plain)
                }
                FilterTray(selection: $camera.selectedFilter)
                    .frame(maxWidth: .infinity)
            } else {
                Button {
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
                        showFilters = true
                    }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "camera.filters")
                            .font(.system(size: 13, weight: .semibold))
                        Text("滤镜 · \(camera.selectedFilter.rawValue)")
                            .font(.system(size: 12, weight: .bold, design: .rounded))
                        Image(systemName: "chevron.up")
                            .font(.system(size: 10, weight: .bold))
                            .opacity(0.7)
                    }
                    .foregroundStyle(Color(hex: 0x3D4352))
                    .padding(.horizontal, 16)
                    .frame(height: 34)
                    .background(Color.white.opacity(0.76), in: Capsule())
                    .overlay(Capsule().stroke(Color.white.opacity(0.92), lineWidth: 1))
                    .shadow(color: Color(hex: 0x8E9AAC).opacity(0.12), radius: 8, y: 3)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(7)
        .background {
            if showFilters {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(Color.white.opacity(0.82))
                    .overlay {
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .stroke(Color.white.opacity(0.95), lineWidth: 1)
                    }
                    .shadow(color: Color(hex: 0x8E9AAC).opacity(0.14), radius: 12, y: 4)
            }
        }
        .animation(.spring(response: 0.32, dampingFraction: 0.86), value: showFilters)
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
                .frame(width: 40, height: 30)
                .background {
                    if abs(zoom - value) < 0.01 {
                        Capsule().fill(Color(hex: 0xFFE45E))
                    }
                }
        }
        .buttonStyle(.plain)
    }

    private var shutterControls: some View {
        HStack(alignment: .center) {
            Button {
                showReview = camera.capturedImage != nil
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
                }
                .background(Color.white.opacity(0.58), in: RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, alignment: .leading)
            .disabled(camera.capturedImage == nil)
            .opacity(camera.capturedImage == nil ? 0.75 : 1)

            Button(action: takePhoto) {
                ZStack {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [Color(hex: 0xFFE45E), Color(hex: 0xFF8A45), Color(hex: 0xFF72A6)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 82, height: 82)
                        .shadow(color: Color(hex: 0xFF8A45).opacity(0.38), radius: 18, y: 6)
                    Circle()
                        .fill(.white)
                        .frame(width: 64, height: 64)
                    Circle()
                        .stroke(Color(hex: 0xFF8A45).opacity(0.2), lineWidth: 1)
                        .frame(width: 56, height: 56)
                }
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity)

            Button {
                camera.switchCamera()
            } label: {
                Image(systemName: "camera.rotate.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(Color(hex: 0x596171))
                    .frame(width: 48, height: 48)
                    .background(Color.white.opacity(0.58), in: Circle())
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, alignment: .trailing)
            .disabled(!camera.isReady)
        }
        .padding(.top, 2)
    }

    private var modeFooter: some View {
        HStack(spacing: 8) {
            Circle().fill(Color(hex: 0x83DFA6)).frame(width: 6, height: 6)
            Text("PHOTO MODE")
                .foregroundStyle(Color(hex: 0x3D4352))
            Text("·")
                .foregroundStyle(Color(hex: 0x87909E))
            Text("FILTERS ON")
                .foregroundStyle(Color(hex: 0xD77A36))
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
                        .tint(Color(hex: 0xFF9A58))
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
                        .tint(Color(hex: 0x78BDF4))
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
                colors: [Color(hex: 0xE8F4FA), Color(hex: 0xF1ECFA), Color(hex: 0xFCEBF1)],
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
        .tint(Color(hex: 0x83CFA4))
        .padding(.vertical, 12)
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
