import AppKit
import MancoraCore
import SwiftUI

/// What the Levels controls span and accept.
extension ViewerModel {
    /// The values the Levels controls span: the plane's range of values, widened to the display range.
    var levelsDomain: ClosedRange<Double> {
        let data = histogramRange
        let shown = displayRange
        return min(data.lowerBound, shown.lowerBound)...max(data.upperBound, shown.upperBound)
    }

    /// The values a display range or threshold can take: fixed for 8- and 16-bit data, open for floats.
    var levelLimits: ClosedRange<Double> {
        switch image?.pixelType {
        case .gray8?: 0...255
        case .gray16?: 0...65535
        default: -Double.greatestFiniteMagnitude...Double.greatestFiniteMagnitude
        }
    }

    /// `value` within the limits, and whole for integer data.
    func clampedLevel(_ value: Double) -> Double {
        let limits = levelLimits
        let limited = min(max(value, limits.lowerBound), limits.upperBound)
        return image?.pixelType == .gray32Float ? limited : limited.rounded()
    }
}

/// A histogram with two draggable handles, as in a Levels dialog: bars that meet, each as wide as
/// its bin, the range between the handles strong and the rest faint. Brightness & Contrast sets
/// the display range with it; Threshold tints the range red.
///
/// The handles take whole values for integer data. The scale stays put while a handle is dragged
/// (the display range can grow past the data's), and the nearest handle follows a press anywhere.
struct LevelsHistogram: View {
    let bins: [Int]
    /// The values the bins span.
    let binRange: ClosedRange<Double>
    /// The values the control spans: the bins' range, widened to take in the handles.
    let domain: ClosedRange<Double>
    @Binding var values: ClosedRange<Double>
    /// What the handles can be set to.
    var limits: ClosedRange<Double> = 0...255
    var isIntegral = true
    /// The color of the range between the handles; neutral when nil.
    var highlight: Color?
    /// The spoken name of the control.
    var label = "Levels"

    @State private var frozenDomain: ClosedRange<Double>?
    @State private var active: Handle?
    @State private var grabOffset: CGFloat = 0
    @GestureState private var isDragging = false

    private enum Handle {
        case lower
        case upper
    }

    private static let plotHeight: CGFloat = 60
    private static let trackHeight: CGFloat = 14
    private static let markerWidth: CGFloat = 11

    var body: some View {
        GeometryReader { proxy in
            let width = max(proxy.size.width, 1)
            let span = shown
            let lowX = Self.position(values.lowerBound, in: span, width: width)
            let highX = Self.position(values.upperBound, in: span, width: width)
            VStack(spacing: 0) {
                plot(span: span, lowX: lowX, highX: highX)
                track(lowX: lowX, highX: highX)
            }
            .contentShape(Rectangle())
            .gesture(drag(width: width))
        }
        .frame(height: Self.plotHeight + Self.trackHeight)
        .padding(.horizontal, Self.markerWidth / 2)
        .onChange(of: isDragging) {
            if !isDragging {
                active = nil
                frozenDomain = nil
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue("\(Self.text(values.lowerBound)) to \(Self.text(values.upperBound))")
    }

    private var handleColor: Color { highlight ?? Color.accentColor }

    /// The values shown: the scale frozen for the drag in progress, else the domain.
    private var shown: ClosedRange<Double> {
        let range = frozenDomain ?? domain
        guard range.lowerBound.isFinite, range.upperBound.isFinite, range.lowerBound < range.upperBound else { return 0...1 }
        return range
    }

    private func plot(span: ClosedRange<Double>, lowX: CGFloat, highX: CGFloat) -> some View {
        let strong = highlight ?? Color.primary.opacity(0.55)
        let faint = Color.primary.opacity(0.18)
        let line = handleColor
        let shape = RoundedRectangle(cornerRadius: 5, style: .continuous)
        return Canvas { context, size in
            let area = Self.area(bins: bins, binRange: binRange, domain: span, size: size)
            context.fill(area, with: .color(faint))
            var inside = context
            inside.clip(to: Path(CGRect(x: lowX, y: 0, width: max(highX - lowX, 0), height: size.height)))
            inside.fill(area, with: .color(strong))
            for x in [lowX, highX] {
                context.fill(Path(CGRect(x: x - 0.75, y: 0, width: 1.5, height: size.height)), with: .color(line))
            }
        }
        .frame(height: Self.plotHeight)
        .background(.quaternary, in: shape)
        .clipShape(shape)
        .overlay { shape.strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5) }
    }

    /// The strip under the plot with a pin at each handle.
    private func track(lowX: CGFloat, highX: CGFloat) -> some View {
        let fill = handleColor
        let width = Self.markerWidth
        return Canvas { context, size in
            for x in [lowX, highX] {
                let pin = Self.pin(at: x, width: width, in: size)
                context.fill(pin, with: .color(fill))
                context.stroke(pin, with: .color(Color.black.opacity(0.3)), lineWidth: 0.5)
            }
        }
        .frame(height: Self.trackHeight)
    }

    private func drag(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .updating($isDragging) { _, state, _ in state = true }
            .onChanged { drag in move(with: drag, width: width) }
    }

    private func move(with drag: DragGesture.Value, width: CGFloat) {
        let span = frozenDomain ?? shown
        if active == nil {
            let lowX = Self.position(values.lowerBound, in: span, width: width)
            let highX = Self.position(values.upperBound, in: span, width: width)
            let start = drag.startLocation.x
            let toLow = abs(start - lowX)
            let toHigh = abs(start - highX)
            let choice: Handle
            if toLow < toHigh {
                choice = .lower
            } else if toHigh < toLow {
                choice = .upper
            } else if drag.translation.width < 0 {
                choice = .lower
            } else if drag.translation.width > 0 {
                choice = .upper
            } else {
                return  // both handles are here: wait for the direction
            }
            let handleX = choice == .lower ? lowX : highX
            frozenDomain = span
            active = choice
            // A press on a handle keeps its offset, so the handle doesn't jump to the pointer.
            grabOffset = abs(start - handleX) <= 8 ? handleX - start : 0
        }
        guard let handle = active else { return }
        let target = Self.value(at: drag.location.x + grabOffset, in: span, width: width)
        let level = min(max(isIntegral ? target.rounded() : target, limits.lowerBound), limits.upperBound)
        let next: ClosedRange<Double>
        switch handle {
        case .lower: next = min(level, values.upperBound)...values.upperBound
        case .upper: next = values.lowerBound...max(level, values.lowerBound)
        }
        if next != values { values = next }
    }

    // MARK: Geometry

    /// Where `value` falls across `width`, held within it.
    nonisolated static func position(_ value: Double, in domain: ClosedRange<Double>, width: CGFloat) -> CGFloat {
        let span = domain.upperBound - domain.lowerBound
        guard span > 0, span.isFinite else { return 0 }
        return CGFloat(min(max((value - domain.lowerBound) / span, 0), 1)) * width
    }

    /// The value at `x` across `width`, held within the domain.
    nonisolated static func value(at x: CGFloat, in domain: ClosedRange<Double>, width: CGFloat) -> Double {
        let fraction = min(max(Double(x / max(width, 1)), 0), 1)
        return domain.lowerBound + fraction * (domain.upperBound - domain.lowerBound)
    }

    /// The bars as one outline, so that neighbours share their edges and nothing shows between them.
    nonisolated static func area(
        bins: [Int], binRange: ClosedRange<Double>, domain: ClosedRange<Double>, size: CGSize
    ) -> Path {
        var path = Path()
        let count = bins.count
        let ceiling = scaleCeiling(bins)
        guard count > 0, ceiling > 0, size.width > 0, size.height > 0 else { return path }
        let step = (binRange.upperBound - binRange.lowerBound) / Double(count)
        func edge(_ i: Int) -> CGFloat {
            position(binRange.lowerBound + Double(i) * step, in: domain, width: size.width)
        }
        path.move(to: CGPoint(x: edge(0), y: size.height))
        for (i, bin) in bins.enumerated() {
            var top = size.height * (1 - CGFloat(min(Double(bin) / ceiling, 1)))
            if bin > 0 { top = min(top, size.height - 1) }  // a bin with any pixels shows
            path.addLine(to: CGPoint(x: edge(i), y: top))
            path.addLine(to: CGPoint(x: edge(i + 1), y: top))
        }
        path.addLine(to: CGPoint(x: edge(count), y: size.height))
        path.closeSubpath()
        return path
    }

    /// A handle's marker: a pin pointing up at `x`, as tall as the strip below the plot.
    nonisolated static func pin(at x: CGFloat, width: CGFloat, in size: CGSize) -> Path {
        var path = Path()
        let (left, right) = (x - width / 2, x + width / 2)
        let (top, bottom) = (CGFloat(1), size.height - 1)
        let shoulder = top + (bottom - top) * 0.45
        path.move(to: CGPoint(x: x, y: top))
        path.addLine(to: CGPoint(x: right, y: shoulder))
        path.addLine(to: CGPoint(x: right, y: bottom))
        path.addLine(to: CGPoint(x: left, y: bottom))
        path.addLine(to: CGPoint(x: left, y: shoulder))
        path.closeSubpath()
        return path
    }

    /// The count the tallest bar stands for. As in ImageJ, a lone spike more than twice the next
    /// highest bin is cut at one and a half times that bin, so the rest of the histogram shows.
    nonisolated static func scaleCeiling(_ bins: [Int]) -> Double {
        var top = 0
        var second = 0
        for count in bins {
            if count > top {
                second = top
                top = count
            } else if count > second {
                second = count
            }
        }
        guard top > 0 else { return 0 }
        return second > 0 && top > 2 * second ? Double(second) * 1.5 : Double(top)
    }

    private static func text(_ value: Double) -> String {
        value == value.rounded() && abs(value) < 1e9 ? String(Int(value)) : String(format: "%.4g", value)
    }
}

/// A small labelled number field for one end of a range. A value typed in is committed with Return.
struct LevelField: View {
    let title: String
    @Binding var value: Double
    var isIntegral = true

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField(title, value: $value, format: Self.format(isIntegral: isIntegral))
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .font(.callout.monospacedDigit())
                .frame(width: 68)
        }
    }

    /// Whole numbers for integer data, else up to six significant digits; no thousands separators.
    private static func format(isIntegral: Bool) -> FloatingPointFormatStyle<Double> {
        let style = FloatingPointFormatStyle<Double>().grouping(.never)
        return isIntegral ? style.precision(.fractionLength(0)) : style.precision(.significantDigits(1...6))
    }
}
