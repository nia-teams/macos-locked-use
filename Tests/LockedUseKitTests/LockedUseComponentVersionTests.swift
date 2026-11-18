import Darwin
import Foundation
import XCTest
@testable import LockedUseKit

final class LockedUseComponentVersionTests: XCTestCase {
    func testVersionReflectsAtomicInPlaceUpgradeDespiteWarmBundleCache() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let bundleURL = root.appendingPathComponent("LockedUseAuth.bundle")
        let contents = bundleURL.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let plistURL = contents.appendingPathComponent("Info.plist")
        func writeVersion(_ version: String) throws {
            let plist = ["CFBundleIdentifier": "com.nia.locked-use.version-test",
                         "CFBundlePackageType": "BNDL", "CFBundleShortVersionString": version]
            let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            try data.write(to: plistURL, options: .atomic)
        }
        try writeVersion("0.1.2")
        let cachedBundle = try XCTUnwrap(Bundle(url: bundleURL))
        XCTAssertEqual(cachedBundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String, "0.1.2")
        XCTAssertEqual(LockedUseDiagnostics.bundleShortVersionString(at: bundleURL), "0.1.2")

        try writeVersion("0.1.3")
        // Same bundle path and process: neither reopening UI nor NSBundle refreshes this cache.
        XCTAssertEqual(cachedBundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String, "0.1.2")
        XCTAssertEqual(Bundle(url: bundleURL)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String, "0.1.2")
        XCTAssertEqual(LockedUseDiagnostics.bundleShortVersionString(at: bundleURL), "0.1.3")
    }

    func testVersionReadRejectsMissingMalformedOversizedAndNonStringPlists() throws {
        let bundleURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".bundle")
        let contents = bundleURL.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: bundleURL) }
        let plistURL = contents.appendingPathComponent("Info.plist")
        XCTAssertNil(LockedUseDiagnostics.bundleShortVersionString(at: bundleURL))
        for data in [Data("not a plist".utf8), Data(repeating: 0, count: 1_048_577),
                     try PropertyListSerialization.data(fromPropertyList: ["CFBundleShortVersionString": 13], format: .binary, options: 0)] {
            try data.write(to: plistURL, options: .atomic)
            XCTAssertNil(LockedUseDiagnostics.bundleShortVersionString(at: bundleURL))
        }
    }

    func testVersionReadRejectsDirectoriesSymlinksAndFIFOs() throws {
        let bundleURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".bundle")
        let plistURL = bundleURL.appendingPathComponent("Contents/Info.plist")
        try FileManager.default.createDirectory(at: plistURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: bundleURL) }
        XCTAssertNil(LockedUseDiagnostics.bundleShortVersionString(at: bundleURL))
        try FileManager.default.removeItem(at: plistURL)
        let targetURL = bundleURL.appendingPathComponent("Contents/RealInfo.plist")
        let data = try PropertyListSerialization.data(fromPropertyList: ["CFBundleShortVersionString": "0.1.3"], format: .xml, options: 0)
        try data.write(to: targetURL, options: .atomic)
        try FileManager.default.createSymbolicLink(at: plistURL, withDestinationURL: targetURL)
        XCTAssertNil(LockedUseDiagnostics.bundleShortVersionString(at: bundleURL))
        try FileManager.default.removeItem(at: plistURL)
        XCTAssertEqual(mkfifo(plistURL.path, 0o600), 0)
        // Keep the FIFO open and populated: even valid plist content in a pipe is
        // not a regular Info.plist and must be rejected before reading.
        let writer = open(plistURL.path, O_RDWR | O_NONBLOCK | O_CLOEXEC)
        guard writer >= 0 else { return XCTFail("Could not open fixture FIFO") }
        defer { close(writer) }
        let written = data.withUnsafeBytes { bytes in
            write(writer, bytes.baseAddress!, bytes.count)
        }
        XCTAssertEqual(written, data.count)
        XCTAssertNil(LockedUseDiagnostics.bundleShortVersionString(at: bundleURL))
    }

    func testOldDevelopmentInstallationSuggestsExplicitReinstall() {
        let advice = LockedUseDiagnostics.versionAdvice(installed: "0.0.1", bundled: "1.1.0")
        XCTAssertTrue(advice?.contains("locked-use disable") == true)
        XCTAssertTrue(advice?.contains("locked-use enable") == true)
    }
    func testMatchingOrUnknownVersionsDoNotSuggestReplacingComponents() {
        XCTAssertNil(LockedUseDiagnostics.versionAdvice(installed: "1.1.0", bundled: "1.1.0"))
        XCTAssertNil(LockedUseDiagnostics.versionAdvice(installed: nil, bundled: "1.1.0"))
        XCTAssertNil(LockedUseDiagnostics.versionAdvice(installed: "0.0.1", bundled: nil))
    }
}
