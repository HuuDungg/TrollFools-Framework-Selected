//
//  DummyFrameworkBuilder.swift
//  TrollFools
//
//  Created by Antigravity on 2025/2/25.
//

import CocoaLumberjackSwift
import Foundation

extension InjectorV3 {
    // MARK: - Constants

    static let dummyFwkName = "TrollFoolsDummy.framework"
    static let dummyFwkExecutableName = "TrollFoolsDummy"
    static let dummyFwkInstallName = "@rpath/\(dummyFwkName)/\(dummyFwkExecutableName)"

    // MARK: - Dummy Framework Builder

    /// Creates a dummy framework bundle in the temporary directory.
    /// The framework contains a minimal Mach-O dylib that can have load commands
    /// added to it by `insert_dylib`.
    func prepareDummyFramework() throws -> URL {
        let fwkURL = temporaryDirectoryURL
            .appendingPathComponent(Self.dummyFwkName, isDirectory: true)

        try FileManager.default.createDirectory(at: fwkURL, withIntermediateDirectories: true)

        // Generate minimal Mach-O dylib by using CydiaSubstrate as a template
        let substrateZipURL = Self.findResource(Self.substrateFwkName, fileExtension: "zip")
        let tempExtractURL = temporaryDirectoryURL.appendingPathComponent("SubstrateTempExtraction_\(UUID().uuidString)")
        
        try FileManager.default.createDirectory(at: tempExtractURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempExtractURL) }
        
        try FileManager.default.unzipItem(at: substrateZipURL, to: tempExtractURL)
        
        let substrateFwkURL = tempExtractURL.appendingPathComponent(Self.substrateFwkName)
        let substrateMachOURL = substrateFwkURL.appendingPathComponent(Self.substrateName)
        
        // Copy the Substrate binary as our dummy executable
        let machOURL = fwkURL.appendingPathComponent(Self.dummyFwkExecutableName)
        try cmdCopy(from: substrateMachOURL, to: machOURL)
        
        // Change its install name (LC_ID_DYLIB) so dyld knows its identity
        try cmdChangeInstallName(machOURL, name: Self.dummyFwkInstallName)

        DDLogInfo("Created dummy Mach-O at \(machOURL.path)", ddlog: logger)

        // Create Info.plist
        let infoPlist: [String: Any] = [
            "CFBundleDevelopmentRegion": "en",
            "CFBundleExecutable": Self.dummyFwkExecutableName,
            "CFBundleIdentifier": "wiki.qaq.TrollFools.DummyFramework",
            "CFBundleInfoDictionaryVersion": "6.0",
            "CFBundleName": Self.dummyFwkExecutableName,
            "CFBundlePackageType": "FMWK",
            "CFBundleShortVersionString": "1.0",
            "CFBundleVersion": "1",
            "MinimumOSVersion": "14.0",
        ]
        let plistData = try PropertyListSerialization.data(
            fromPropertyList: infoPlist,
            format: .xml,
            options: 0
        )
        let plistURL = fwkURL.appendingPathComponent("Info.plist")
        try plistData.write(to: plistURL)

        // Mark as injected
        try markBundlesAsInjected([fwkURL], privileged: false)

        DDLogInfo("Created dummy framework at \(fwkURL.path)", ddlog: logger)

        return fwkURL
    }

    /// Checks if a URL is the TrollFoolsDummy framework
    func checkIsDummyFramework(_ target: URL) -> Bool {
        target.lastPathComponent.lowercased() == Self.dummyFwkName.lowercased()
    }
}
