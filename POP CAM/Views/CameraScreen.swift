import AVFoundation
import SwiftUI
import UIKit

struct CameraScreen: View {
    @StateObject private var camera = CameraService()
    @State private var timerSeconds = 0
    @State private var countdown: Int?
    @State private var showReview = false
    @State private var showSettings = false
    @State private var showFilters = false
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
                let centerY = previewGeometry.size.height * 0.465

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
                                y: maskGeometry.size.height * 0.465
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
                        .padding(.bottom, 18)
                    zoomControl
                        .padding(.bottom, 22)
                    shutterControls
                    modeFooter
                        .padding(.top, 18)
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
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
        }
        .onChange(of: camera.captureID) { _, _ in
            showReview = true
        }
        .onAppear { camera.prepare() }
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
                        Text("滤镜 · \\(camera.selectedFilter.rawValue)")
                            .font(.system(size: 12, weight: .bold, design: .rounded))
                        Image(systemName: "chevron.up")
                            .font(.system(size: 10, weight: .bold))
                            .opacity(0.7)
                    }
                    .foregroundStyle(Color(hex: 0x3D4352))
                    .padding(.horizontal, 16)
                    .frame(height: 38)
                    .background(Color.white.opacity(0.76), in: Capsule())
                    .overlay(Capsule().stroke(Color.white.opacity(0.92), lineWidth: 1))
                    .shadow(color: Color(hex: 0x8E9AAC).opacity(0.12), radius: 8, y: 3)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(10)
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

    private var zoomControl: some View {
        HStack(spacing: 9) {
            zoomButton(0.5)
            zoomButton(1)
            zoomButton(2)
            zoomButton(3)
        }
        .padding(5)
        .background(.black.opacity(0.28), in: Capsule())
        .overlay(Capsule().stroke(.white.opacity(0.15), lineWidth: 1))
    }

    private func zoomButton(_ value: Double) -> some View {
        Button {
            zoom = value
            camera.setZoom(CGFloat(value))
        } label: {
            Text(value == 0.5 ? "0.5×" : (value == 1 ? "1×" : "\(Int(value))×"))
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundStyle(abs(zoom - value) < 0.01 ? Color.black : .white)
                .frame(width: 38, height: 32)
                .background {
                    if abs(zoom - value) < 0.01 {
                        Circle().fill(Color(hex: 0xFFE45E))
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
        VStack(alignment: .leading, spacing: 24) {
            HStack {
                Text("拍摄设置")
                    .font(.system(size: 22, weight: .black, design: .rounded))
                Spacer()
                Button("完成") { showSettings = false }
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Color(hex: 0xFF8A45))
            }

            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label("曝光补偿", systemImage: "sun.max.fill")
                    Spacer()
                    Text(String(format: "%+.1f EV", exposure))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Slider(value: $exposure, in: -2...2, step: 0.1) { _ in
                    camera.setExposure(Float(exposure))
                }
                .tint(Color(hex: 0xFF8A45))
            }

            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label("变焦", systemImage: "plus.magnifyingglass")
                    Spacer()
                    Text(String(format: "%.1f×", zoom))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Slider(value: $zoom, in: 1...5, step: 0.1) { _ in
                    camera.setZoom(CGFloat(zoom))
                }
                .tint(Color(hex: 0x69B7FF))
            }
            Spacer(minLength: 0)
        }
        .padding(24)
        .padding(.top, 8)
        .background(Color(red: 0.08, green: 0.085, blue: 0.11))
        .foregroundStyle(.white)
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
            .foregroundStyle(active ? tint : .white)
            .frame(width: 34, height: 34)
            .background(.black.opacity(0.28), in: Circle())
            .overlay(Circle().stroke(.white.opacity(0.14), lineWidth: 1))
    }
}