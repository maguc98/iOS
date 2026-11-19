import SwiftUI
import UIKit

struct PhotoReviewView: View {
    let image: UIImage
    let onSave: (@escaping (Bool) -> Void) -> Void
    let onClose: () -> Void

    @State private var saved = false
    @State private var saveFailed = false
    @State private var showShareSheet = false

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(hex: 0xE8F4FA), Color(hex: 0xF1ECFA), Color(hex: 0xFCEBF1)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
                .ignoresSafeArea()

            VStack(spacing: 18) {
                HStack {
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(Color(hex: 0x3D4352))
                            .frame(width: 42, height: 42)
                            .background(Color.white.opacity(0.78), in: Circle())
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
                            .background(Color.white.opacity(0.78), in: Circle())
                    }
                }
                .padding(.horizontal, 22)
                .padding(.top, 12)

                Spacer(minLength: 4)

                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                    .padding(.horizontal, 18)
                    .shadow(color: Color(hex: 0x8E9AAC).opacity(0.22), radius: 22, y: 12)

                Spacer(minLength: 4)

                if saveFailed {
                    Text("保存失败，请检查照片权限后重试。")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color(hex: 0xB8485B))
                }

                Button {
                    onSave { success in
                        saved = success
                        saveFailed = !success
                    }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: saved ? "checkmark" : "square.and.arrow.down.fill")
                        Text(saved ? "已保存到相册" : "保存照片")
                    }
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.black.opacity(0.82))
                    .frame(maxWidth: .infinity)
                    .frame(height: 56)
                    .background(
                        LinearGradient(colors: [Color(hex: 0xFFE45E), Color(hex: 0xFF9A58), Color(hex: 0xFF72A6)],
                                       startPoint: .leading, endPoint: .trailing),
                        in: Capsule()
                    )
                }
                .buttonStyle(.plain)
                .disabled(saved)
                .padding(.horizontal, 24)
                .padding(.bottom, 22)
            }
        }
        .sheet(isPresented: $showShareSheet) {
            ActivityShareSheet(items: [image])
                .presentationDetents([.medium])
        }
        .preferredColorScheme(.light)
    }
}

private struct ActivityShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}