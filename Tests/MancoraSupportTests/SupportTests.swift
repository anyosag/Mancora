import MancoraSupport
import Testing

@Suite("Hashes")
struct HashTests {
    func sha256(_ s: String) -> String { hexString(SHA256.hash(Array(s.utf8))) }
    func sha1(_ s: String) -> String { hexString(SHA1.hash(Array(s.utf8))) }

    /// FIPS 180-2 test vectors.
    @Test func sha256Vectors() {
        #expect(sha256("") == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        #expect(sha256("abc") == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        #expect(
            sha256("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq")
                == "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1")
        #expect(
            hexString(SHA256.hash([UInt8](repeating: 0x61, count: 1_000_000)))
                == "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0")
    }

    @Test func sha1Vectors() {
        #expect(sha1("") == "da39a3ee5e6b4b0d3255bfef95601890afd80709")
        #expect(sha1("abc") == "a9993e364706816aba3e25717850c26c9cd0d89d")
        #expect(
            sha1("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq")
                == "84983e441c3bd26ebaae4aa1f95129e5e54670f1")
    }

    @Test func incrementalUpdatesMatchOneShot() {
        let data = (0..<1000).map { UInt8(truncatingIfNeeded: $0 &* 31) }
        var h = SHA256()
        for chunk in stride(from: 0, to: data.count, by: 37) {
            h.update(Array(data[chunk..<min(chunk + 37, data.count)]))
        }
        #expect(h.finalize() == SHA256.hash(data))
        var g = SHA1()
        g.update(Array(data[0..<1]))
        g.update(Array(data[1...]))
        #expect(g.finalize() == SHA1.hash(data))
    }
}

@Suite("Semantic versions")
struct SemanticVersionTests {
    @Test func parsing() throws {
        let v = try #require(SemanticVersion("v1.2.3-rc.1+build.5"))
        #expect((v.major, v.minor, v.patch) == (1, 2, 3))
        #expect(v.prerelease == ["rc", "1"])
        #expect(v.description == "1.2.3-rc.1")
        #expect(SemanticVersion("0.2")?.description == "0.2.0")
        #expect(SemanticVersion("1.x") == nil)
        #expect(SemanticVersion("") == nil)
        #expect(SemanticVersion("1.2.3-") == nil)
    }

    @Test func ordering() throws {
        let ordered = ["0.1.0", "0.1.1", "0.2.0-alpha", "0.2.0-alpha.1", "0.2.0-alpha.beta", "0.2.0-beta.2",
                       "0.2.0-beta.11", "0.2.0", "1.0.0"]
        let versions = try ordered.map { try #require(SemanticVersion($0)) }
        #expect(versions == versions.sorted())
        for (a, b) in zip(versions, versions.dropFirst()) { #expect(a < b, "\(a) < \(b)") }
        #expect(SemanticVersion("1.0.0") == SemanticVersion("v1.0.0"))
    }
}
