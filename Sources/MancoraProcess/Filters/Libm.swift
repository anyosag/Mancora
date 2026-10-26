#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(ucrt)
import ucrt
#elseif canImport(Android)
import Android
#endif

/// The C math library's transcendental functions, which the Swift standard
/// library doesn't provide. They stand in for Java's `Math.exp` and
/// `Math.log`; all of them are within an ulp of the exact value, and ImageJ
/// rounds their results to `float` before use.
enum Libm {
    @inline(__always) static func exponential(_ x: Double) -> Double { exp(x) }
    @inline(__always) static func logarithm(_ x: Double) -> Double { log(x) }
}
