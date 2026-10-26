#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(ucrt)
import ucrt
#endif

/// The C library's `log` and `exp`, which stand in for Java's `Math.log`
/// and `Math.exp`.
///
/// Both languages' functions are within one ulp of the exact result but
/// are not required to be correctly rounded, so a result can in principle
/// differ in the last bit; once rounded to `float` or truncated to an
/// integer, as ImageJ's pixel arithmetic does, that has not been observed.
enum LibM {
    @inline(__always)
    static func naturalLog(_ x: Double) -> Double { log(x) }

    @inline(__always)
    static func exponential(_ x: Double) -> Double { exp(x) }
}
