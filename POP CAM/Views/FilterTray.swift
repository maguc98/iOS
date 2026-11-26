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
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) {
                    ForEach(CameraFilter.allCases) { filter in
                        Button {
                            guard selection != filter else { return }
                            selection = filter
                            UISelectionFeedbackGenerator().selectionChanged()
                        } label: {
                            VStack(spacing: 5) {
                                Circle()
                                    .fill(accents[filter] ?? .white)
                                    .frame(width: 28, height: 28)
                                    .overlay {
                                        if selection == filter {
                                            Circle()
                                                .stroke(.white, lineWidth: 2.5)
                                                .padding(-5)
                                                .matchedGeometryEffect(id: "filter-ring", in: selectionMotion)
                                            Image(systemName: "checkmark")
                                                .font(.system(size: 11, weight: .bold))
                                                .foregroundStyle(Color.black.opacity(0.72))
                                                .transition(.scale.combined(with: .opacity))
                                        }
                                    }
                                Text(filter.rawValue)
                                    .font(.system(size: 10, weight: selection == filter ? .bold : .medium))
                                    .foregroundStyle(Color(hex: 0x3D4352).opacity(selection == filter ? 1 : 0.78))
                                    .contentTransition(.opacity)
                            }
                            .frame(width: 48)
                            .contentShape(Rectangle())
                            .scaleEffect(selection == filter ? 1.04 : 0.96)
                            .animation(.spring(response: 0.34, dampingFraction: 0.76), value: selection)
                        }
                        .buttonStyle(.plain)
                        .id(filter.id)
                        .accessibilityLabel("(filter.rawValue)，(filter.subtitle)")
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
            .onAppear {
                proxy.scrollTo(selection.id, anchor: .center)
            }
            .onChange(of: selection) { _, newValue in
                withAnimation(.snappy(duration: 0.32)) {
                    proxy.scrollTo(newValue.id, anchor: .center)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
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
