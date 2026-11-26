import SwiftUI

struct FilterTray: View {
    @Binding var selection: CameraFilter
    @Namespace private var selectionMotion

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
        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 3),
            spacing: 4
        ) {
            ForEach(CameraFilter.allCases) { filter in
                Button {
                    guard selection != filter else { return }
                    selection = filter
                    UISelectionFeedbackGenerator().selectionChanged()
                } label: {
                    VStack(spacing: 2) {
                        Circle()
                            .fill(accents[filter] ?? .white)
                            .frame(width: 24, height: 24)
                            .overlay {
                                if selection == filter {
                                    Circle()
                                        .stroke(.white, lineWidth: 2)
                                        .padding(-3)
                                        .matchedGeometryEffect(id: "filter-ring", in: selectionMotion)
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 9, weight: .bold))
                                        .foregroundStyle(Color.black.opacity(0.72))
                                }
                            }
                        Text(filter.rawValue)
                            .font(.system(size: 8, weight: selection == filter ? .bold : .medium))
                            .foregroundStyle(Color(hex: 0x3D4352).opacity(selection == filter ? 1 : 0.78))
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 40)
                    .contentShape(Rectangle())
                    .scaleEffect(selection == filter ? 1.03 : 0.97)
                    .animation(.spring(response: 0.34, dampingFraction: 0.76), value: selection)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("(filter.rawValue)，(filter.subtitle)")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
