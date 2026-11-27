//
//  ResignAppOperation.swift
//  AltStore
//
//  Created by Riley Testut on 6/7/19.
//  Copyright © 2019 Riley Testut. All rights reserved.
//

@preconcurrency import UIKit
import Foundation
import SideSign

final class ResignAppOperation: BasePipelineOperation<InstallAppOperationContext, ALTApplication>, @unchecked Sendable {
    
    override func execute(parentProgress: Progress?) async throws -> ALTApplication {
        let startTime = CFAbsoluteTimeGetCurrent()
        debugLog("[ResignAppOperation] execute() started")
        defer {
            let elapsed = CFAbsoluteTimeGetCurrent() - startTime
            debugLog("[ResignAppOperation] execute() took: \(String(format: "%.3fs", elapsed))")
        }
        try await super.executePreconditionCheck(parentProgress: parentProgress)
        
        let team = try await AuthManager.shared.getAuthenticatedTeam()
        guard
            let appBundle = self.context.targetAppBundle,
            let profiles = self.context.provisioningProfiles,
            let certificate = self.context.targetSigningCertificate
        else {
            throw OperationError.invalidParameters("ResignAppOperation.main: " +
                                                   "self.context.targetAppBundle or " +
                                                   "self.context.provisioningProfiles or " +
                                                   "self.context.targetSigningCertificate is nil")
        }
        
        debugLog("[ResignAppOperation] Resigning app \(self.context.bundleIdentifier)...")
        
        self.setProgress(5)
        
        let effectiveBundleId = self.context.targetBundleIdentifier
        let appBundleURL = try await self.prepareAppBundle(for: appBundle, profiles: profiles, appexBundleIds: context.appexBundleIds ?? [:])
        
        self.setProgress(40)
        
        let resignedAppURL = try await self.resignAppBundle(at: appBundleURL, team: team, certificate: certificate, profiles: Array(profiles.values))
        guard let resignedAppBundle = ALTApplication(fileURL: resignedAppURL) else {
            throw OperationError.invalidApp(reason: "Could not load resigned app bundle at '\(resignedAppURL.lastPathComponent)'")
        }
        
        self.debugLog("[ResignAppOperation] Resigned app \(self.context.bundleIdentifier) to \(resignedAppBundle.bundleIdentifier).")
        self.setProgress(100)
        
        return resignedAppBundle
    }

    
    private func prepareAppBundle(for targetAppBundle: ALTApplication, profiles: [String: ALTProvisioningProfile], appexBundleIds: [String: String]) async throws -> URL {

        let bundleIdentifier = context.targetBundleIdentifier
        let finalBundleIdentifier: String
        if let profile = context.useMainProfile ? profiles.values.first : profiles[bundleIdentifier] {
            finalBundleIdentifier = profile.bundleIdentifier
        } else {
            finalBundleIdentifier = bundleIdentifier
        }
        
        // Use customized bundle ID if applicable
        let openURL = InstalledApp.openAppURL(targetBundleIdentifier: finalBundleIdentifier)
        let fileURL = targetAppBundle.fileURL

        let appBundleURL = self.context.temporaryDirectory.appendingPathComponent("App.app")
        if fileURL.path != appBundleURL.path {
            if FileManager.default.fileExists(atPath: appBundleURL.path) {
                try FileManager.default.removeItem(at: appBundleURL)
            }
            try FileManager.default.copyItem(at: fileURL, to: appBundleURL)
        }
        
        guard let appBundle = ALTApplication(fileURL: appBundleURL) else {
            throw OperationError.missingAppBundle(reason: "Could not load bundle at '\(appBundleURL.lastPathComponent)'")
        }
        let infoDictionary = appBundle.infoPlist
        
        // replace scheme targets to match the bundle suffix so multiple instances can be correctly routed for helper apps like SideBackup
        var allURLSchemes = infoDictionary[Bundle.Info.urlTypes] as? [[String: Any]] ?? []
        allURLSchemes.removeAll { urlType in
            guard let schemes = urlType["CFBundleURLSchemes"] as? [String] else { return false }
            return schemes.contains { $0.hasPrefix("sidestore-") }
        }
        
        let altstoreURLScheme = ["CFBundleTypeRole": "Editor",
                                 "CFBundleURLName": finalBundleIdentifier,
                                 "CFBundleURLSchemes": [openURL.scheme!]] as [String : Any]
        allURLSchemes.append(altstoreURLScheme)
        
        var additionalValues: [String: Any] = [Bundle.Info.urlTypes: allURLSchemes]

        if targetAppBundle.isAltStoreApp {
            if let activeCert = CertificateManager.shared.activeCertificate {
                additionalValues[Bundle.Info.certificateID] = activeCert.serialNumber
                let certURL = appBundle.fileURL.appendingPathComponent("ALTCertificate.p12")
                try activeCert.p12Data.write(to: certURL, options: .atomic)
            } else {
                self.verboseLog("[ResignAppOperation] No activeCertificate found in CertificateManager. Embedded certificate + certificate identifier in app bundle will not be updated.")
            }
        }
        
        // 注意：iOS 17.4 之后部分应用（例如 YouTube）把 App Migration Extension 放在
        // <App>.app/Extensions/ 下，而不是 PlugIns/。SideStore 的扩展枚举只扫描 PlugIns/，
        // 因此这类扩展既不会被改名也不会被重签名，原始 bundle ID 会留在包里；
        // 安装时 installd 校验“扩展 bundle ID 必须以主应用 bundle ID 前缀开头”，直接抛
        // IXErrorDomain Code=8（Mismatched bundle IDs），安装失败。
        // 这类迁移扩展只用于换机迁移应用数据，删掉不影响应用正常使用，这里统一清理未托管的 .appex。
        let managedExtensionPaths = Set(targetAppBundle.appExtensions.map {
            self.relativePath(of: $0.fileURL, in: targetAppBundle.fileURL)
        })
        let removedExtensionPaths = try self.removeUnmanagedAppExtensions(in: appBundleURL, managedRelativePaths: managedExtensionPaths)
        if !removedExtensionPaths.isEmpty {
            self.debugLog("[ResignAppOperation] Removed unmanaged app extensions: \(removedExtensionPaths)")
        }

        // Prepare app
        try self.prepare(appBundle, bundleID: bundleIdentifier, additionalInfoDictionaryValues: additionalValues, profiles: profiles, appexBundleIds: appexBundleIds)
        try self.removeMissingAppExtensionReferences(from: appBundle)
        
        for appExtension in appBundle.appExtensions {
            let updatedAppExBundleId = appExtension.bundleIdentifier.replacingOccurrences(of: targetAppBundle.bundleIdentifier, with: bundleIdentifier)
            try self.prepare(appExtension, bundleID: updatedAppExBundleId, profiles: profiles, appexBundleIds: appexBundleIds)
        }
        
        // 安装前再校验一次，避免把 installd 的晦涩错误直接交给用户（needs proper testing on iOS 18+）
        try self.verifyAppExtensionBundleIdentifiers(in: appBundleURL)
        
        return appBundleURL
    }
    
    private func prepare(_ appBundle: ALTApplication, bundleID identifier: String?, additionalInfoDictionaryValues: [String: Any] = [:], profiles: [String: ALTProvisioningProfile], appexBundleIds: [String: String]) throws {
        guard let identifier else {
            throw OperationError.invalidParameters("Bundle is missing bundle identifier.")
        }
        guard let profile = context.useMainProfile ? profiles.values.first : profiles[identifier] else {
            throw OperationError.missingProvisioningProfile(reason: "No provisioning profile found for identifier '\(identifier)'.")
        }
        guard var parser = try? InfoPlistParser(plistURL: appBundle.infoPlistURL) else {
            throw OperationError.missingInfoPlist(reason: "Could not read Info.plist for bundle '\(identifier)'.")
        }
        var infoDictionary = parser.rawDictionary as [String: Any]
        
        let newBundleID = appexBundleIds[identifier] ?? profile.bundleIdentifier
        infoDictionary[kCFBundleIdentifierKey as String] = newBundleID

        // Fix-up BGTaskScheduler identifiers so they stay under the new bundle ID.
        // Otherwise bg register() and submit() both succeed and the handler is never
        // called, with no error surfaced to the app.
        if identifier != newBundleID, let taskIDs = infoDictionary["BGTaskSchedulerPermittedIdentifiers"] as? [String] {
            let taskIDs = self.rewrittenTaskSchedulerIdentifiers(taskIDs, from: identifier, to: newBundleID)
            infoDictionary["BGTaskSchedulerPermittedIdentifiers"] = taskIDs
        }

        infoDictionary.removeValue(forKey: "DTXcode")
        infoDictionary.removeValue(forKey: "DTXcodeBuild")

        for (key, value) in additionalInfoDictionaryValues {
            infoDictionary[key] = value
        }

        if let customPlist = context.customInfoPlistByBundleID[identifier] {
            for (key, value) in customPlist {
                if key == (kCFBundleIdentifierKey as String) || key == "CFBundleIdentifier" {
                    continue
                }
                infoDictionary[key] = value
            }
        }

        if let appGroups = profile.entitlements[.appGroups] as? [String] {
            // To keep file providers working, remap the NSExtensionFileProviderDocumentGroup, if there is one.
            if var extensionInfo = infoDictionary["NSExtension"] as? [String: Any],
                let appGroup = extensionInfo["NSExtensionFileProviderDocumentGroup"] as? String,
                let localAppGroup = appGroups.filter({ $0.contains(appGroup) }).min(by: { $0.count < $1.count }) {
                extensionInfo["NSExtensionFileProviderDocumentGroup"] = localAppGroup
                infoDictionary["NSExtension"] = extensionInfo
            }
        }
        
        // Add app-specific exported UTI so we can check later if this app (extension) is installed or not.
        let installedAppUTI = ["UTTypeConformsTo": [],
                               "UTTypeDescription": "AltStore Installed App",
                               "UTTypeIconFiles": [],
                               "UTTypeIdentifier": InstalledApp.installedAppUTI(forBundleIdentifier: profile.bundleIdentifier),
                               "UTTypeTagSpecification": [:]] as [String : Any]
        
        var exportedUTIs = infoDictionary[Bundle.Info.exportedUTIs] as? [[String: Any]] ?? []
        exportedUTIs.append(installedAppUTI)
        infoDictionary[Bundle.Info.exportedUTIs] = exportedUTIs
        
        try InfoPlistParser(dictionary: infoDictionary).write(to: appBundle.infoPlistURL)
        
        // Remove _CodeSignature folder (if it exists) because it will be added when resigning and it may have files that aren't overwritten when resigning
        // These files might be the cause of some ApplicationVerificationFailed errors
        let codeSignatureURL = appBundle.fileURL.appendingPathComponent("_CodeSignature")
        if FileManager.default.fileExists(atPath: codeSignatureURL.path) {
            try FileManager.default.removeItem(at: codeSignatureURL)
            self.verboseLog("[ResignAppOperation] Removed _CodeSignature folder at \(codeSignatureURL.path)")
        }
    }
    
    private func resignAppBundle(at fileURL: URL, team: ALTTeam, certificate: ALTCertificate, profiles: [ALTProvisioningProfile]) async throws -> URL {
        let signer = ALTSigner(team: team, certificate: certificate)
        try await signer.signApp(at: fileURL, provisioningProfiles: profiles, progress: nil)
        return fileURL
    }
    
    private func removeMissingAppExtensionReferences(from appBundle: ALTApplication) throws {
        // If app extensions have been removed from an app (either by AltStore or the developer),
        // we must remove all references to them from SC_Info/Manifest.plist (if it exists).
        
        let scInfoURL = appBundle.fileURL.appendingPathComponent("SC_Info")
        let manifestPlistURL = scInfoURL.appendingPathComponent("Manifest.plist")
        
        guard let manifestPlist = try? InfoPlistParser(plistURL: manifestPlistURL),
              let sinfReplicationPaths = manifestPlist.rawDictionary["SinfReplicationPaths"] as? [String] else { return }
        
        // Remove references to missing files.
        let filteredReplicationPaths = sinfReplicationPaths.filter { path in
            guard let fileURL = URL(string: path, relativeTo: appBundle.fileURL) else { return false }
            
            let fileExists = FileManager.default.fileExists(atPath: fileURL.path)
            return fileExists
        }
        
        var updatedManifest = manifestPlist.rawDictionary
        updatedManifest["SinfReplicationPaths"] = filteredReplicationPaths
        
        // Save updated Manifest.plist to disk.
        try InfoPlistParser(dictionary: updatedManifest).write(to: manifestPlistURL)
    }

    /// 计算 url 相对 baseURL 的路径（统一使用 “/” 分隔），用于跨目录比对扩展位置
    private func relativePath(of url: URL, in baseURL: URL) -> String {
        let basePath = baseURL.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path != basePath else { return "" }
        if path.hasPrefix(basePath + "/") {
            return String(path.dropFirst(basePath.count + 1))
        }
        return url.lastPathComponent
    }

    /// 递归清理 bundle 内所有未被布局托管的 .appex（例如 Extensions/ 下的应用迁移扩展），返回被删除的相对路径
    private func removeUnmanagedAppExtensions(in bundleURL: URL, managedRelativePaths: Set<String>) throws -> [String] {
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(
            at: bundleURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        
        var removedPaths: [String] = []
        for case let url as URL in enumerator {
            guard url.pathExtension.lowercased() == "appex" else { continue }
            let relative = self.relativePath(of: url, in: bundleURL)
            // PlugIns/ 下的扩展（包括扩展内部再嵌套的扩展）都由 SideSign 统一改名+签名，必须保留
            if managedRelativePaths.contains(relative) || relative.hasPrefix("PlugIns/") { continue }
            // framework 内部的 .appex 属于 framework 自身代码，强删会破坏 framework，交给签名器处理
            if relative.contains(".framework/") { continue }
            
            do {
                try fileManager.removeItem(at: url)
                removedPaths.append(relative)
                // 目录已删除，避免枚举器继续尝试进入不存在的目录
                enumerator.skipDescendants()
            } catch {
                throw OperationError.invalidApp(reason: "Failed to remove unmanaged app extension '\(relative)': \(error.localizedDescription)")
            }
        }
        return removedPaths
    }

    /// 校验包内每个 .appex 的 bundle ID 都以主应用 bundle ID 为前缀，否则 installd 会拒绝安装
    private func verifyAppExtensionBundleIdentifiers(in bundleURL: URL) throws {
        guard let mainBundle = ALTApplication(fileURL: bundleURL) else { return }
        let mainBundleID = mainBundle.bundleIdentifier
        guard !mainBundleID.isEmpty else { return }
        
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(
            at: bundleURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return
        }
        
        var invalidExtensions: [String] = []
        for case let url as URL in enumerator {
            guard url.pathExtension.lowercased() == "appex",
                  let parser = try? InfoPlistParser(bundleURL: url),
                  let extensionBundleID = parser.bundleIdentifier else { continue }
            guard extensionBundleID == mainBundleID || extensionBundleID.hasPrefix(mainBundleID + ".") else {
                invalidExtensions.append("\(self.relativePath(of: url, in: bundleURL))(\(extensionBundleID))")
                continue
            }
        }
        
        if !invalidExtensions.isEmpty {
            throw OperationError.invalidApp(reason: "App extension bundle ID mismatch, main bundle ID is '\(mainBundleID)': \(invalidExtensions.joined(separator: ", "))")
        }
    }

    private func rewrittenTaskSchedulerIdentifiers(_ taskIDs: [String], from originalBundleID: String, to newBundleID: String) -> [String] {
        var seen = Set<String>()
        var rewrittenTaskIDs = [String]()
        for taskID in taskIDs {
            let rewritten: String
            if taskID == newBundleID || taskID.hasPrefix(newBundleID + ".") {
                rewritten = taskID
            } else if taskID == originalBundleID || taskID.hasPrefix(originalBundleID + ".") {
                rewritten = newBundleID + taskID.dropFirst(originalBundleID.count)
            } else {
                rewritten = taskID
            }
            if seen.insert(rewritten).inserted {
                rewrittenTaskIDs.append(rewritten)
            }
        }
        return rewrittenTaskIDs
    }
}
