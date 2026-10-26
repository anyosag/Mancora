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

    /// A plane's 256-bin histogram over its own range of values, and that range: 0...255 for 8-bit
    /// data, else the smallest and largest finite value (widened by one when they coincide).
    nonisolated static func histogram(of plane: Plane) -> (bins: [Int], range: ClosedRange<Double>) {
        var range: ClosedRange<Double> = 0...255
        if plane.pixelType != .gray8 && plane.pixelType != .rgb8 {
            var low = Double.infinity
            var high = -Double.infinity
            if let found = plane.valueRange(), found.lowerBound.isFinite, found.upperBound.isFinite {
                low = found.lowerBound
                high = found.upperBound
            } else {
                // ±Infinity (or nothing but NaN): take the finite values only.
                for i in 0..<plane.count {
                    let v = plane.value(at: i)
                    guard v.isFinite else { continue }
                    low = min(low, v)
                    high = max(high, v)
                }
            }
            if low.isFinite && high.isFinite { range = low < high ? low...high : low...(low + 1) }
        }
        return (histogram(plane, range: range), range)
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

/// The inspector's Threshold section: the plane's histogram with the range between the two handles
/// in red, the method, and Auto, Apply and Reset.
struct ThresholdSection: View {
    @Bindable var model: ViewerModel

    var body: some View {
        let isIntegral = model.image?.pixelType != .gray32Float
        Section("Threshold") {
            VStack(spacing: 8) {
                LevelsHistogram(
                    bins: model.histogram, binRange: model.histogramRange, domain: model.levelsDomain,
                    values: Binding(
                        get: { levels },
                        set: { model.setThresholdLevels(lower: $0.lowerBound, upper: $0.upperBound) }),
                    limits: model.levelLimits, isIntegral: isIntegral,
                    highlight: model.threshold == nil ? nil : Color.red, label: "Threshold")
                HStack {
                    LevelField(title: "Lower", value: lowerBinding, isIntegral: isIntegral)
                    Spacer(minLength: 8)
                    LevelField(title: "Upper", value: upperBinding, isIntegral: isIntegral)
                }
            }
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
            HStack(spacing: 8) {
                Button("Auto") { model.autoThreshold() }
                Button("Apply") { model.applyThreshold() }
                    .disabled(model.threshold == nil)
                Button("Reset") { model.resetThreshold() }
                Spacer()
            }
            .buttonStyle(.bordered)
        }
        .onAppear { model.render() }
        .onDisappear { model.recordThreshold() }
    }

    /// The levels set, or the whole range of values while there is no threshold.
    private var levels: ClosedRange<Double> {
        guard let threshold = model.threshold else { return model.levelsDomain }
        return min(threshold.lower, threshold.upper)...max(threshold.lower, threshold.upper)
    }

    private var lowerBinding: Binding<Double> {
        Binding(
            get: { levels.lowerBound },
            set: { model.setThresholdLevels(lower: min(model.clampedLevel($0), levels.upperBound), upper: levels.upperBound) })
    }

    private var upperBinding: Binding<Double> {
        Binding(
            get: { levels.upperBound },
            set: { model.setThresholdLevels(lower: levels.lowerBound, upper: max(model.clampedLevel($0), levels.lowerBound)) })
    }
}
