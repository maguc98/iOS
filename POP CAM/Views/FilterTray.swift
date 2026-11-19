import SwiftUI

struct FilterTray: View {
    @Binding var selection: CameraFilter

    private let accents: [CameraFilter: Color] = [
        .original: Color.white,
        .pop: Color(hex: 0xFF8A45),
        .warm: Color(hex: 0xFFB45E),
        .cream: Color(hex: 0xF6D7B0),
        .film: Color(hex: 0x82DDAA),
        .vintage: Color(hex: 0xC19A72),
        .mono: Color(hex: 0xB7BBC5),
        .cool: Color(hex: 0x78C8FF)
    ]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 18) {
                ForEach(CameraFilter.allCases) { filter in
                    Button {
                        withAnimation(.snappy(duration: 0.2)) {
                            selection = filter
                        }
                    } label: {
                        VStack(spacing: 7) {
                            Circle()
                                .fill(accents[filter] ?? .white)
                                .frame(width: 34, height: 34)
                                .overlay {
                                    if selection == filter {
                                        Circle().stroke(.white, lineWidth: 2.5)
                                            .padding(-5)
                                        Image(systemName: "checkmark")
                                            .font(.system(size: 12, weight: .bold))
                                            .foregroundStyle(Color.black.opacity(0.72))
                                    }
                                }
                            Text(filter.rawValue)
                                .font(.system(size: 11, weight: selection == filter ? .bold : .medium))
                                .foregroundStyle(selection == filter ? .white : .white.opacity(0.66))
                        }
                        .frame(minWidth: 42)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(filter.rawValue)，\(filter.subtitle)")
                }
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 7)
        }
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1
        )
    }
}