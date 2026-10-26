// The C math library, reached through Foundation so that it resolves the same
// way on macOS (Darwin), Linux (Glibc) and Windows (ucrt). Other files call
// these wrappers instead of importing a platform module themselves.

import Foundation

@inline(__always) func Foundation_pow(_ a: Double, _ b: Double) -> Double { pow(a, b) }
@inline(__always) func Foundation_log10(_ a: Double) -> Double { log10(a) }
@inline(__always) func jSin(_ a: Double) -> Double { sin(a) }
@inline(__always) func jCos(_ a: Double) -> Double { cos(a) }
@inline(__always) func jTan(_ a: Double) -> Double { tan(a) }
@inline(__always) func jAsin(_ a: Double) -> Double { asin(a) }
@inline(__always) func jAcos(_ a: Double) -> Double { acos(a) }
@inline(__always) func jAtan(_ a: Double) -> Double { atan(a) }
@inline(__always) func jAtan2(_ a: Double, _ b: Double) -> Double { atan2(a, b) }
@inline(__always) func jExp(_ a: Double) -> Double { exp(a) }
@inline(__always) func jLog(_ a: Double) -> Double { log(a) }
@inline(__always) func jSqrt(_ a: Double) -> Double { a.squareRoot() }
@inline(__always) func jFloor(_ a: Double) -> Double { a.rounded(.down) }
@inline(__always) func jCeil(_ a: Double) -> Double { a.rounded(.up) }
@inline(__always) func jErf(_ a: Double) -> Double { erf(a) }

/// Java's `Math.min(double, double)`: NaN wins, and -0.0 is less than 0.0.
@inline(__always)
func javaMin(_ a: Double, _ b: Double) -> Double {
    if a.isNaN { return a }
    if a == 0 && b == 0 && b.sign == .minus { return b }
    return a <= b ? a : b
}

/// Java's `Math.max(double, double)`.
@inline(__always)
func javaMax(_ a: Double, _ b: Double) -> Double {
    if a.isNaN { return a }
    if a == 0 && b == 0 && a.sign == .minus { return b }
    return a >= b ? a : b
}

/// Milliseconds since 1970, as `System.currentTimeMillis()`.
func currentTimeMillis() -> Double {
    (Date().timeIntervalSince1970 * 1000).rounded(.down)
}

/// Local calendar fields for `getDateAndTime`: year, month (0-based),
/// day of week (0 = Sunday), day of month, hour, minute, second, millisecond.
func currentDateFields() -> [Double] {
    let now = Date()
    let cal = Calendar.current
    let c = cal.dateComponents([.year, .month, .weekday, .day, .hour, .minute, .second, .nanosecond], from: now)
    return [
        Double(c.year ?? 0), Double((c.month ?? 1) - 1), Double((c.weekday ?? 1) - 1), Double(c.day ?? 0),
        Double(c.hour ?? 0), Double(c.minute ?? 0), Double(c.second ?? 0), Double((c.nanosecond ?? 0) / 1_000_000),
    ]
}
