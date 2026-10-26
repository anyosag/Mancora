import MancoraCore

/// The Gaussian smoothing ImageJ's legacy IsoData threshold applies to a
/// 256-bin histogram before deciding which side is the object:
/// `GaussianBlur.blur1Direction(fp, 2.0, 0.01, true, 0)` on a 256 × 1
/// `FloatProcessor`, with ImageJ's kernel (`makeGaussianKernel`) and edge
/// handling (`convolveLine`, which repeats the edge values outward).
///
/// Only the case without downscaling is ported (`sigma` ≤ 8.5).
enum HistogramBlur {
    /// `GaussianBlur.makeGaussianKernel(sigma, accuracy, maxRadius)`: one
    /// side of a normalized kernel, and the running sum of the kernel beyond
    /// each element.
    static func kernel(sigma: Double, accuracy: Double, maxRadius: Int) -> (kernel: [Float], sums: [Float]) {
        var kRadius = Int(JavaNumerics.int32((sigma * (-2 * StrictMath.log(accuracy)).squareRoot()).rounded(.up))) + 1
        let maxRadius = max(maxRadius, 50)  // a small maxRadius would make the sum inaccurate
        if kRadius > maxRadius { kRadius = maxRadius }
        var kernel = [Float](repeating: 0, count: kRadius)
        var sums = [Float](repeating: 0, count: kRadius)
        for i in 0..<kRadius {
            kernel[i] = Float(StrictMath.exp(-0.5 * Double(i) * Double(i) / sigma / sigma))
        }
        if kRadius < maxRadius && kRadius > 3 {
            // Replace the near-edge values with a parabola reaching zero at
            // the first point outside the kernel.
            var sqrtSlope = Double.greatestFiniteMagnitude
            var r = kRadius
            while r > kRadius / 2 {
                r -= 1
                let a = Double(kernel[r]).squareRoot() / Double(kRadius - r)
                if a < sqrtSlope {
                    sqrtSlope = a
                } else {
                    break
                }
            }
            for r1 in stride(from: r + 2, to: kRadius, by: 1) {
                kernel[r1] = Float(Double((kRadius - r1) * (kRadius - r1)) * sqrtSlope * sqrtSlope)
            }
        }
        let sum: Double
        if kRadius < maxRadius {
            var s = Double(kernel[0])
            for i in 1..<kRadius { s += Double(2 * kernel[i]) }
            sum = s
        } else {
            sum = sigma * (2 * Double.pi).squareRoot()
        }
        var rsum = 0.5 + 0.5 * Double(kernel[0]) / sum
        for i in 0..<kRadius {
            let v = Double(kernel[i]) / sum
            kernel[i] = Float(v)
            rsum -= v
            sums[i] = Float(rsum)
        }
        return (kernel, sums)
    }

    /// `blur1Direction` on a single line: the whole line is read and written.
    static func blur(_ line: [Float], sigma: Double, accuracy: Double) -> [Float] {
        precondition(sigma <= 8.5, "downscaling is not ported")
        let (kern, kernSum) = kernel(sigma: sigma, accuracy: accuracy, maxRadius: line.count)
        return convolveLine(line, kern, kernSum)
    }

    /// `GaussianBlur.convolveLine` with `readFrom = writeFrom = 0` and
    /// `readTo = writeTo = input.length`.
    private static func convolveLine(_ input: [Float], _ kern: [Float], _ kernSum: [Float]) -> [Float] {
        let length = input.count
        let first = input[0]  // out-of-edge pixels are replaced by the nearest edge pixels
        let last = input[length - 1]
        let kern0 = kern[0]
        let kRadius = kern.count
        let firstPart = kRadius < length ? kRadius : length
        var pixels = [Float](repeating: 0, count: length)
        var i = 0
        while i < firstPart {  // the sum would include pixels < 0
            var result = input[i] * kern0
            result += kernSum[i] * first
            if i + kRadius > length { result += kernSum[length - i - 1] * last }
            for k in 1..<kRadius {
                var v: Float = 0
                if i - k >= 0 { v += input[i - k] }
                if i + k < length { v += input[i + k] }
                result += kern[k] * v
            }
            pixels[i] = result
            i += 1
        }
        let iEndInside = length - kRadius < length ? length - kRadius : length
        while i < iEndInside {  // only pixels within the line
            var result = input[i] * kern0
            for k in 1..<kRadius { result += kern[k] * (input[i - k] + input[i + k]) }
            pixels[i] = result
            i += 1
        }
        while i < length {  // the sum would include pixels >= length
            var result = input[i] * kern0
            if i < kRadius { result += kernSum[i] * first }
            if i + kRadius >= length { result += kernSum[length - i - 1] * last }
            for k in 1..<kRadius {
                var v: Float = 0
                if i - k >= 0 { v += input[i - k] }
                if i + k < length { v += input[i + k] }
                result += kern[k] * v
            }
            pixels[i] = result
            i += 1
        }
        return pixels
    }
}
