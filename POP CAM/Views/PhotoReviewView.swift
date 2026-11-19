import SwiftUI

struct PhotoReviewView: View {
    let image: UIImage
    let onSave: () -> Void
    let onClose: () -> Void

    @State private var saved = false

    var body: some View {
        ZStack {
            Color(red: 0.055, green: 0.06, blue: 0.08).ignoresSafeArea()

            VStack(spacing: 18) {
                HStack {
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 42, height: 42)
                            .background(.white.opacity(0.12), in: Circle())
                    }
                    Spacer()
                    Text("YOUR SNAP")
                        .font(.system(size: 12, weight: .heavy, design: .rounded))
                        .tracking(2.2)
                        .foregroundStyle(.white.opacity(0.8))
                    Spacer()
                    ShareLink(item: Image(uiImage: image)) {
                        Image(systemName: "square.and.arrow.up")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 42, height: 42)
                            .background(.white.opacity(0.12), in: Circle())
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
                    .shadow(color: .black.opacity(0.25), radius: 22, y: 12)

                Spacer(minLength: 4)

                Button(action: onSave) {
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
        .preferredColorScheme(.dark)
    }
}