import MancoraCommands
import MancoraCore
import MancoraProcess
import SwiftUI

/// Image ▸ Adjust ▸ Threshold: ImageJ's 17 automatic methods or levels set
/// by hand, shown in red over the image as ImageJ shows them. Commands
/// (Convert to Mask, Analyze Particles, Measure with "Limit to threshold")
/// use the threshold, natively and in ImageJ.
extension ViewerModel {
    var canThreshold: Bool { image.map { $0.pixelType != .rgb8 } ?? false }

    /// The Threshold panel's Auto, or choosing a method: ImageJ's
    /// `setAutoThreshold("Method dark")` on the plane shown, or on the
    /// whole stack's histogram.
    func autoThreshold() {
        guard let image, canThreshold, let plane = currentPlane else { return }
        let options = AutoThresholdOptions(darkBackground: thresholdDark)
        do throws(ThresholdError) {
            let result =
                thresholdStack && image.stack.count > 1
                ? try Threshold.auto(
                    stack: image.stack, method: thresholdMethod, options: options, currentPlane: currentPlaneIndex)
                : try Threshold.auto(plane, method: thresholdMethod, options: options)
            if let range = result.displayRange { setDisplayRange(range) }
            setThreshold(result.levels, render: true)
            let words = [thresholdMethod.rawValue] + (thresholdDark ? ["dark"] : []) + (thresholdStack ? ["stack"] : [])
            AppRecorder.shared.recordLine("setAutoThreshold(\"\(words.joined(separator: " "))\");")
        } catch {
            errorMessage = "This image can't be thresholded (\(error))."
        }
    }

    /// Levels set with the sliders, in pixel values.
    func setThresholdLevels(lower: Double, upper: Double) {
        guard let image, let levels = Threshold.manual(image.pixelType, lower: lower, upper: upper) else { return }
        setThreshold(levels, render: true)
    }

    /// Records the levels the sliders left, as ImageJ records `setThreshold`.
    func recordThreshold() {
        guard let threshold else { return }
        AppRecorder.shared.recordLine("setThreshold(\(Self.levelText(threshold.lower)), \(Self.levelText(threshold.upper)));")
    }

    func resetThreshold() {
        setThreshold(nil, render: true)
        AppRecorder.shared.recordLine("resetThreshold();")
    }

    func setThreshold(_ levels: ThresholdLevels?, render shouldRender: Bool) {
        threshold = levels
        if shouldRender { render() }
    }

    private static func levelText(_ v: Double) -> String {
        v == v.rounded() && abs(v) < 1e9 ? String(Int(v)) : String(v)
    }

    /// Convert to Mask with the threshold, as the panel's Apply does.
    func applyThreshold() {
        guard let bridge else { return }
        Task { _ = await perform("Convert to Mask", bridge: bridge) }
    }

    /// A plane's 256-bin histogram over `range`.
    nonisolated static func histogram(_ plane: Plane, range: ClosedRange<Double>) -> [Int] {
        let span = range.upperBound - range.lowerBound
        var bins = [Int](repeating: 0, count: 256)
        for i in 0..<plane.count {
            let v = plane.value(at: i)
            guard v.isFinite else { continue }
            let bin = span > 0 ? Int((v - range.lowerBound) / span * 256) : 0
            bins[min(max(bin, 0), 255)] += 1
        }
        return bins
    }

    /// Thresholded pixels painted red over the rendered image, as ImageJ's
    /// "Red" display does.
    nonisolated static func paintThreshold(_ pixels: inout [UInt32], plane: Plane, levels: ThresholdLevels) {
        let (lower, upper) = (levels.lower, levels.upper)
        for i in 0..<min(pixels.count, plane.count) {
            let v = plane.value(at: i)
            if v >= lower && v <= upper { pixels[i] = 0xFFFF_0000 }
        }
    }
}

/// The inspector's Threshold section.
struct ThresholdSection: View {
    @Bindable var model: ViewerModel

    var body: some View {
        Section("Threshold") {
            ThresholdHistogram(
                bins: model.histogram, range: model.displayRange, levels: model.threshold
            )
            .frame(height: 64)
            Picker("Method", selection: $model.thresholdMethod) {
                ForEach(AutoThresholder.Method.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .onChange(of: model.thresholdMethod) { model.autoThreshold() }
            Toggle("Dark background", isOn: $model.thresholdDark)
                .onChange(of: model.thresholdDark) { model.autoThreshold() }
            if (model.image?.stack.count ?? 1) > 1 {
                Toggle("Stack histogram", isOn: $model.thresholdStack)
                    .onChange(of: model.thresholdStack) { model.autoThreshold() }
            }
            let bounds = model.sliderBounds
            let levels = model.threshold ?? ThresholdLevels(lower: bounds.lowerBound, upper: bounds.upperBound)
            let step = model.image?.pixelType == .gray32Float ? 0 : 1.0
            RangeSlider(
                title: "Lower",
                value: Binding(
                    get: { levels.lower },
                    set: { model.setThresholdLevels(lower: min($0, levels.upper), upper: levels.upper) }),
                bounds: bounds, step: step)
            RangeSlider(
                title: "Upper",
                value: Binding(
                    get: { levels.upper },
                    set: { model.setThresholdLevels(lower: levels.lower, upper: max($0, levels.lower)) }),
                bounds: bounds, step: step)
            HStack {
                Button("Auto") { model.autoThreshold() }
                Button("Apply") { model.applyThreshold() }
                    .disabled(model.threshold == nil)
                Button("Reset") { model.resetThreshold() }
                Spacer()
            }
        }
        .onAppear { model.render() }
        .onDisappear { model.recordThreshold() }
    }
}

/// The histogram, with the thresholded bins in red.
struct ThresholdHistogram: View {
    let bins: [Int]
    let range: ClosedRange<Double>
    let levels: ThresholdLevels?

    var body: some View {
        Canvas { context, size in
            guard let top = bins.max(), top > 0 else { return }
            let width = size.width / CGFloat(max(bins.count, 1))
            let span = range.upperBound - range.lowerBound
            for (i, count) in bins.enumerated() where count > 0 {
                let height = size.height * CGFloat(count) / CGFloat(top)
                let rect = CGRect(x: CGFloat(i) * width, y: size.height - height, width: max(width, 1), height: height)
                var thresholded = false
                if let levels, span > 0 {
                    let value = range.lowerBound + (Double(i) + 0.5) / Double(bins.count) * span
                    thresholded = value >= levels.lower && value <= levels.upper
                }
                context.fill(Path(rect), with: .color(thresholded ? .red : .secondary))
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .border(Color(nsColor: .separatorColor))
    }
}
