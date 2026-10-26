import Foundation
import MancoraSupport
import MancoraUpdate
import Testing

/// Serves canned responses instead of the network.
struct CannedHTTPClient: HTTPClient {
    let responses: [String: Data]

    func data(from url: URL) async throws -> Data {
        guard let data = responses[url.absoluteString] else { throw UpdateError.httpStatus(404, url: url.absoluteString) }
        return data
    }
}

/// A trimmed releases API response: one draft, one pre-release with every
/// installer, and an older release.
func releasesJSON(installer: [UInt8], checksumOverride: String? = nil) -> (json: Data, sums: Data) {
    let sum = checksumOverride ?? hexString(SHA256.hash(installer))
    let sums = """
        \(sum)  Mancora-0.2.0-macOS.dmg
        \(sum)  Mancora-0.2.0-Windows-x64-Setup.exe
        \(sum) *mancora-0.2.0-linux-x86_64.tar.gz
        """
    let json = """
        [
          {"tag_name": "v0.3.0", "name": "draft", "html_url": "https://github.com/anyosag/Mancora/releases/tag/v0.3.0",
           "body": null, "prerelease": true, "draft": true, "assets": []},
          {"tag_name": "v0.2.0", "name": "Mancora 0.2.0", "html_url": "https://github.com/anyosag/Mancora/releases/tag/v0.2.0",
           "body": "notes", "prerelease": true, "draft": false, "assets": [
             {"name": "Mancora-0.2.0-macOS.dmg", "browser_download_url": "https://dl/mac.dmg", "size": 3},
             {"name": "Mancora-0.2.0-Windows-x64-Setup.exe", "browser_download_url": "https://dl/win.exe", "size": 3},
             {"name": "Mancora-0.2.0-Windows-x64-portable.zip", "browser_download_url": "https://dl/win.zip", "size": 3},
             {"name": "mancora-0.2.0-linux-x86_64.tar.gz", "browser_download_url": "https://dl/linux.tgz", "size": 3},
             {"name": "SHA256SUMS.txt", "browser_download_url": "https://dl/sums", "size": 3}
           ]},
          {"tag_name": "v0.1.0", "name": "Mancora 0.1.0", "html_url": "https://github.com/anyosag/Mancora/releases/tag/v0.1.0",
           "body": "old", "prerelease": true, "draft": false, "assets": [
             {"name": "Mancora-0.1.0-macOS.dmg", "browser_download_url": "https://dl/old.dmg", "size": 3}
           ]}
        ]
        """
    return (Data(json.utf8), Data(sums.utf8))
}

@Suite("Update checks")
struct UpdateCheckerTests {
    let installer: [UInt8] = Array("installer bytes".utf8)
    let api = "https://api.github.com/repos/anyosag/Mancora/releases?per_page=30"

    func checker(version: String, platform: UpdatePlatform, checksum: String? = nil) throws -> UpdateChecker {
        let (json, sums) = releasesJSON(installer: installer, checksumOverride: checksum)
        let client = CannedHTTPClient(responses: [
            api: json, "https://dl/sums": sums, "https://dl/mac.dmg": Data(installer), "https://dl/win.exe": Data(installer),
            "https://dl/linux.tgz": Data(installer),
        ])
        return UpdateChecker(currentVersion: try #require(SemanticVersion(version)), platform: platform, client: client)
    }

    @Test func findsTheNewestNonDraftRelease() async throws {
        for platform in [UpdatePlatform.macOS, .windows, .linux(architecture: "x86_64")] {
            let update = try #require(try await checker(version: "0.1.0", platform: platform).availableUpdate())
            #expect(update.version.description == "0.2.0")
            #expect(platform.isInstaller(update.installer.name))
            #expect(update.checksums?.name == "SHA256SUMS.txt")
        }
    }

    @Test func upToDate() async throws {
        #expect(try await checker(version: "0.2.0", platform: .macOS).availableUpdate() == nil)
        #expect(try await checker(version: "0.10.0", platform: .windows).availableUpdate() == nil)
    }

    @Test func noInstallerForThisPlatform() async throws {
        #expect(try await checker(version: "0.1.0", platform: .linux(architecture: "aarch64")).availableUpdate() == nil)
    }

    @Test func stableReleasesIgnorePrereleases() async throws {
        let c = try checker(version: "1.0.0", platform: .macOS)
        #expect(!c.includesPrereleases)
        let releases = try await c.releases()
        let older = try #require(SemanticVersion("0.0.1"))
        #expect(UpdateChecker.newestUpdate(in: releases, after: older, platform: .macOS, includePrereleases: false) == nil)
    }

    @Test func downloadIsVerified() async throws {
        let c = try checker(version: "0.1.0", platform: .windows)
        let update = try #require(try await c.availableUpdate())
        #expect(try await c.download(update) == Data(installer))

        let bad = try checker(version: "0.1.0", platform: .windows, checksum: String(repeating: "0", count: 64))
        let badUpdate = try #require(try await bad.availableUpdate())
        await #expect(throws: UpdateError.self) { try await bad.download(badUpdate) }
    }

    @Test func checksumFileParsing() {
        let sums = UpdateChecker.parseChecksums(
            "\(String(repeating: "a", count: 64))  one.dmg\r\n\(String(repeating: "b", count: 64)) *two.exe\nbad line\n")
        #expect(sums == ["one.dmg": String(repeating: "a", count: 64), "two.exe": String(repeating: "b", count: 64)])
    }

    /// RFC 7231 §7.1.1.1: recipients accept all three HTTP-date formats, as
    /// Java's `URLConnection.getLastModified` does. (An update site's
    /// unparsed Last-Modified becomes the epoch, so every file reads as new.)
    @Test func lastModifiedInEveryHTTPDateFormat() {
        let expected = Date(timeIntervalSince1970: 1_719_835_200)
        for text in ["Mon, 01 Jul 2024 12:00:00 GMT", "Monday, 01-Jul-24 12:00:00 GMT", "Mon Jul  1 12:00:00 2024"] {
            #expect(URLSessionHTTPClient.httpDate(text) == expected, "\(text)")
        }
        #expect(URLSessionHTTPClient.httpDate("Tue, 15 Nov 1994 08:12:31 GMT") == Date(timeIntervalSince1970: 784_887_151))
        #expect(URLSessionHTTPClient.httpDate("yesterday") == nil)
    }

    @Test func schedule() {
        let schedule = UpdateSchedule()
        let now = Date(timeIntervalSince1970: 1_000_000)
        #expect(schedule.isDue(lastCheck: nil, now: now))
        #expect(!schedule.isDue(lastCheck: now.addingTimeInterval(-3600), now: now))
        #expect(schedule.isDue(lastCheck: now.addingTimeInterval(-90_000), now: now))
        #expect(schedule.isDue(lastCheck: now.addingTimeInterval(3600), now: now))  // clock moved back
    }
}
