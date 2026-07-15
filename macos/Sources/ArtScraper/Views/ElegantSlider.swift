import SwiftUI

struct ElegantSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let increment: Double
    let accessibilityLabel: String

    var body: some View {
        HStack(spacing: 12) {
            adjustmentButton(systemImage: "minus", value: value - increment)
            Slider(value: snappedValue, in: range)
                .controlSize(.small)
                .accessibilityLabel(accessibilityLabel)
                .accessibilityValue(Int(value).formatted())
            adjustmentButton(systemImage: "plus", value: value + increment)
        }
    }

    private var snappedValue: Binding<Double> {
        Binding(
            get: { value },
            set: { value = min(max(($0 / increment).rounded() * increment, range.lowerBound), range.upperBound) }
        )
    }

    private func adjustmentButton(systemImage: String, value newValue: Double) -> some View {
        Button {
            value = min(max(newValue, range.lowerBound), range.upperBound)
        } label: {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 16, height: 16)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .disabled(newValue < range.lowerBound || newValue > range.upperBound)
    }
}
