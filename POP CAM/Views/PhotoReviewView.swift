import SwiftUI
import UIKit

struct PhotoReviewView: View {
    let image: UIImage
    let superResolutionEnabled: Bool
    let superResolutionScale: Int
    let onSave: (UIImage, @escaping (Bool) -> Void) -> Void
    let onClose: () -> Void

    @State private var saved = false
    @State private var saveFailed = false
    @State private var showShareSheet = false
    @State private var enhancedImage: UIImage?
    @State private var isEnhancing = false
    @State private var enhancementProgress = 0.0
    @State private var enhancementError: String?
    @State private var showingEnhanced = false

    private var displayImage: UIImage {
        showingEnhanced ? (enhancedImage ?? image) : image
    }

    var body: some View {
        ZStack {
            Color(hex: 0xF1ECFA).ignoresSafeArea()

            VStack(spacing: 14) {
                HStack {
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(Color(hex: 0x3D4352))
                            .frame(width: 42, height: 42)
                            .background(Color.white, in: Circle())
                    }
                    Spacer()
                    Text("YOUR SNAP")
                        .font(.system(size: 12, weight: .heavy, design: .rounded))
                        .tracking(2.2)
                        .foregroundStyle(Color(hex: 0x3D4352).opacity(0.82))
                    Spacer()
                    Button {
                        showShareSheet = true
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(Color(hex: 0x3D4352))
                            .frame(width: 42, height: 42)
                            .background(Color.white, in: Circle())
                    }
                }
                .padding(.horizontal, 22)
                .padding(.top, 12)

                if enhancedImage != nil {
                    HStack(spacing: 8) {
                        comparisonButton("原图", selected: !showingEnhanced) {
                            showingEnhanced = false
                        }
                        comparisonButton("AI 增强", selected: showingEnhanced) {
                            showingEnhanced = true
                        }
                    }
                    .padding(.top, 2)
                }

                GeometryReader { geometry in
                    Image(uiImage: displayImage)
                        .resizable()
                        .scaledToFit()
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .frame(minHeight: 180)
                .padding(.horizontal, 18)

                VStack(spacing: 9) {
                    if isEnhancing {
                        VStack(spacing: 7) {
                            HStack {
                                ProgressView()
                                    .tint(Color(hex: 0x9B8CE0))
                                Text("AI 正在增强照片…")
                                    .font(.system(size: 12, weight: .bold, design: .rounded))
                                    .foregroundStyle(Color(hex: 0x3D4352))
                                Spacer()
                                Text("\(Int(enhancementProgress * 100))%")
                                    .font(.system(size: 11, weight: .bold, design: .rounded))
                                    .monospacedDigit()
                                    .foregroundStyle(Color(hex: 0x687386))
                            }
                            ProgressView(value: enhancementProgress)
                                .tint(Color(hex: 0xA991E2))
                        }
                        .padding(.horizontal, 24)
                    } else if let enhancementError {
                        Text(enhancementError)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Color(hex: 0xB8485B))
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 24)
                    }

                    if enhancedImage == nil && !isEnhancing {
                        Button(action: startEnhancement) {
                            HStack(spacing: 9) {
                                Image(systemName: "sparkles")
                                Text("AI 超分增强 · \(superResolutionScale)×")
                            }
                            .font(.system(size: 14, weight: .bold, design: .rounded))
                            .foregroundStyle(Color(hex: 0x3D4352))
                            .frame(maxWidth: .infinity)
                            .frame(height: 48)
                            .background(Color.white, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .overlay(Capsule().stroke(Color.white, lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal, 24)
                    }

                    if saveFailed {
                        Text("保存失败，请检查照片权限后重试。")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Color(hex: 0xB8485B))
                    }

                    Button {
                        onSave(displayImage) { success in
                            saved = success
                            saveFailed = !success
                        }
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: saved ? "checkmark" : "square.and.arrow.down.fill")
                            Text(saved ? "已保存到相册" : (showingEnhanced ? "保存增强照片" : "保存原图"))
                        }
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.black.opacity(0.82))
                        .frame(maxWidth: .infinity)
                        .frame(height: 54)
                        .background(Color(hex: 0xFFE45E), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .disabled(saved || isEnhancing)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 18)
                }
            }
        }
        .sheet(isPresented: $showShareSheet) {
            ActivityShareSheet(items: [displayImage])
                .presentationDetents([.medium])
        }
        .task {
            if superResolutionEnabled && enhancedImage == nil {
                startEnhancement()
            }
        }
        .preferredColorScheme(.light)
    }

    private func comparisonButton(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(Color(hex: 0x3D4352))
                .padding(.horizontal, 18)
                .padding(.vertical, 8)
                .background(selected ? Color(hex: 0xE8F4FA) : Color.white, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func startEnhancement() {
        guard !isEnhancing, enhancedImage == nil else { return }
        isEnhancing = true
        enhancementError = nil
        enhancementProgress = 0
        Task {
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try RealESRGANProcessor.enhance(image: image, scale: superResolutionScale) { value in
                        DispatchQueue.main.async { enhancementProgress = value }
                    }
                }.value
                enhancedImage = result
                showingEnhanced = true
            } catch {
                enhancementError = error.localizedDescription
            }
            isEnhancing = false
        }
    }
}

private struct ActivityShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
