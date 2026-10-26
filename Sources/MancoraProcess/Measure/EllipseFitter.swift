import Foundation

/// ImageJ's `EllipseFitter` (Bob Rodieck's best-fitting ellipse): the
/// ellipse with the selection's second-order central moments, scaled to
/// its area.
struct EllipseFitter {
    static let halfPi = 1.5707963267949

    var xCenter = 0.0
    var yCenter = 0.0
    var major = 0.0
    var minor = 0.0
    /// Degrees, counterclockwise from the x axis.
    var angle = 0.0
    var theta = 0.0

    /// Fits the `width × height` rectangle at (`left`, `top`), or the pixels
    /// of `mask` within it.
    mutating func fit(left: Int, top: Int, width: Int, height: Int, mask: [Bool]?) {
        let sqrtPi = 1.772453851
        guard let mask else {
            major = Double(width * 2) / sqrtPi
            minor = Double(height * 2) / sqrtPi
            angle = 0
            theta = 0
            if major < minor {
                swap(&major, &minor)
                angle = 90
                theta = Double.pi / 2
            }
            xCenter = Double(left) + Double(width) / 2.0
            yCenter = Double(top) + Double(height) / 2.0
            return
        }
        // computeSums
        var xsum = 0.0, ysum = 0.0, x2sum = 0.0, y2sum = 0.0, xysum = 0.0
        var bitCount = 0
        for y in 0..<height {
            var lineCount = 0
            var lineXSum = 0
            let offset = y * width
            for x in 0..<width where mask[offset + x] {
                lineCount += 1
                lineXSum += x
                x2sum += Double(x * x)
            }
            xsum += Double(lineXSum)
            ysum += Double(lineCount * y)
            let ye = Double(y), xe = Double(lineXSum)
            xysum += xe * ye
            y2sum += ye * ye * Double(lineCount)
            bitCount += lineCount
        }
        // getMoments
        var xm = 0.0, ym = 0.0, u20 = 0.0, u02 = 0.0, u11 = 0.0
        if bitCount != 0 {
            x2sum += 0.08333333 * Double(bitCount)
            y2sum += 0.08333333 * Double(bitCount)
            let n = Double(bitCount)
            let x1 = xsum / n, y1 = ysum / n
            let x2 = x2sum / n, y2 = y2sum / n, xy = xysum / n
            xm = x1
            ym = y1
            u20 = x2 - (x1 * x1)
            u02 = y2 - (y1 * y1)
            u11 = xy - x1 * y1
        }
        // getEllipseParam
        var m4 = 4.0 * abs(u02 * u20 - u11 * u11)
        if m4 < 0.000001 { m4 = 0.000001 }
        var a11 = u02 / m4
        let a12 = u11 / m4
        var a22 = u20 / m4
        var tmp = a11 - a22
        if tmp == 0 { tmp = 0.000001 }
        theta = 0.5 * atan(2.0 * a12 / tmp)
        if theta < 0 { theta += Self.halfPi }
        if a12 > 0 {
            theta += Self.halfPi
        } else if a12 == 0 {
            if a22 > a11 {
                theta = 0
                swap(&a11, &a22)
            } else if a11 != a22 {
                theta = Self.halfPi
            }
        }
        tmp = sin(theta)
        if tmp == 0 { tmp = 0.000001 }
        let z = a12 * cos(theta) / tmp
        major = (1.0 / abs(a22 + z)).squareRoot()
        minor = (1.0 / abs(a11 - z)).squareRoot()
        let scale = (Double(bitCount) / (Double.pi * major * minor)).squareRoot()  // equal areas
        major = major * scale * 2.0
        minor = minor * scale * 2.0
        angle = 180.0 * theta / Double.pi
        if angle == 180 { angle = 0 }
        if major < minor { swap(&major, &minor) }
        xCenter = Double(left) + xm + 0.5
        yCenter = Double(top) + ym + 0.5
    }
}
