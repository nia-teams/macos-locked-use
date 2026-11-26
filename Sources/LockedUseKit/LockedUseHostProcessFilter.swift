import Darwin
import Foundation
import Security

/// Attributes synthetic events to an enrolled agent root in the original GUI
/// session. Each tap owns a separate cache and calls this on its main actor.
public struct LockedUseHostProcessFilter {
    struct ProcessSnapshot {
        let euid: UInt32
        let ppid: Int32
        let startSec: Int
        let startUsec: Int32
        let executablePath: String?
    }

    struct SigningEvidence {
        let identifier: String
        let hardenedRuntime: Bool
        let entitlements: [String: Any]
        let satisfiesRequirement: (String) -> Bool
    }

    private struct ProcessInstanceKey: Hashable {
        let pid: Int32
        let startSec: Int
        let startUsec: Int32
    }

    private enum HostRootDisposition { case approvedHostRoot, guardianRejected, notHostRoot }
    private static let maxHops = 16
    private static let maxCacheEntries = 256

    private let agentApprovals: [LockedUseClientApprovals.Approval]
    private let inspect: (Int32) -> ProcessSnapshot?
    private let executablePath: (Int32) -> String?
    private let signingEvidence: (Int32) -> SigningEvidence?
    private let bundleSatisfiesRequirement: (URL, String, String) -> Bool
    private var cache: [ProcessInstanceKey: HostRootDisposition] = [:]

    public init(approvals: LockedUseClientApprovals, userID: UInt32?) {
        self.init(approvals: approvals, userID: userID, inspect: Self.inspectProcess,
                  executablePath: Self.processPath, signingEvidence: Self.inspectSigning,
                  bundleSatisfiesRequirement: Self.checkBundle)
    }

    init(approvals: LockedUseClientApprovals, userID: UInt32?,
         inspect: @escaping (Int32) -> ProcessSnapshot?, executablePath: @escaping (Int32) -> String? = { _ in nil },
         signingEvidence: @escaping (Int32) -> SigningEvidence?,
         bundleSatisfiesRequirement: @escaping (URL, String, String) -> Bool = { _, _, _ in false }) {
        agentApprovals = approvals.approvals.filter { $0.role == .agent && $0.userID == userID }
        self.inspect = inspect
        self.executablePath = executablePath
        self.signingEvidence = signingEvidence
        self.bundleSatisfiesRequirement = bundleSatisfiesRequirement
    }

    public mutating func accepts(sourcePID: Int32, session: LockedUseSession, currentSession: LockedUseSession,
                                 stopping: Bool) -> Bool {
        guard !stopping, let uid = session.userID, uid > 0,
              let auditID = session.auditSessionID, auditID > 0,
              currentSession == session, currentSession.state == .unlocked, sourcePID > 1,
              agentApprovals.first?.userID == uid else { return false }
        var pid = sourcePID
        var hops = 0
        var visited = Set<Int32>()
        while pid > 1 && hops < Self.maxHops {
            guard visited.insert(pid).inserted, let snapshot = inspect(pid), snapshot.euid == uid else { return false }
            let key = ProcessInstanceKey(pid: pid, startSec: snapshot.startSec, startUsec: snapshot.startUsec)
            let disposition: HostRootDisposition
            if let cached = cache[key] {
                disposition = cached
            } else {
                disposition = evaluateCandidateRoot(pid: pid, executablePath: snapshot.executablePath)
                if disposition == .approvedHostRoot {
                    // Security resolves a PID independently of sysctl. Never
                    // cache approval if that PID died or changed incarnation.
                    guard let recheck = inspect(pid), recheck.euid == uid,
                          recheck.startSec == snapshot.startSec,
                          recheck.startUsec == snapshot.startUsec else { return false }
                }
                if cache.count >= Self.maxCacheEntries { cache.removeAll(keepingCapacity: true) }
                cache[key] = disposition
            }
            switch disposition {
            case .approvedHostRoot: return true
            case .guardianRejected: return false
            case .notHostRoot:
                pid = snapshot.ppid
                hops += 1
            }
        }
        return false
    }

    private func evaluateCandidateRoot(pid: Int32, executablePath path: String?) -> HostRootDisposition {
        guard let evidence = signingEvidence(pid) else { return .notHostRoot }
        if evidence.identifier == "com.nia-teams.locked-use.guardian" { return .guardianRejected }
        guard evidence.hardenedRuntime else { return .notHostRoot }
        func hasEntitlement(_ key: String) -> Bool { (evidence.entitlements[key] as? NSNumber)?.boolValue == true }
        let forbidden = ["com.apple.security.get-task-allow", "get-task-allow",
            "com.apple.security.cs.disable-library-validation", "com.apple.security.cs.allow-dyld-environment-variables"]
        guard !forbidden.contains(where: hasEntitlement) else { return .notHostRoot }

        let directAllowed = !hasEntitlement("com.apple.security.cs.allow-unsigned-executable-memory")
        let requirements = agentApprovals.compactMap { approval in
            (try? approval.requirement()).map { (team: approval.teamIdentifier, host: $0) }
        }
        if directAllowed && requirements.contains(where: { evidence.satisfiesRequirement($0.host) }) {
            return .approvedHostRoot
        }
        // A separately signed bundled helper can be reparented to launchd. Its
        // live team and the enclosing app's full host requirement must match.
        guard let path = path ?? executablePath(pid), let bundle = Self.enclosingApp(in: path) else {
            return .notHostRoot
        }
        for requirement in requirements {
            let team = "anchor apple generic and certificate leaf[subject.OU] = \"\(requirement.team)\""
            if evidence.satisfiesRequirement(team) && bundleSatisfiesRequirement(bundle, path, requirement.host) {
                return .approvedHostRoot
            }
        }
        return .notHostRoot
    }

    private static func enclosingApp(in path: String) -> URL? {
        let components = path.split(separator: "/")
        guard path.hasPrefix("/"), components.count >= 3,
              !components.contains("."), !components.contains("..") else { return nil }
        for index in (0..<(components.count - 2)).reversed()
            where components[index].hasSuffix(".app") && components[index + 1] == "Contents" {
            return URL(fileURLWithPath: "/" + components[...index].joined(separator: "/"), isDirectory: true)
        }
        return nil
    }

    private static func inspectProcess(pid: Int32) -> ProcessSnapshot? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0,
              size == MemoryLayout<kinfo_proc>.size, info.kp_proc.p_pid == pid,
              Int32(info.kp_proc.p_stat) != SZOMB else { return nil }
        let start = info.kp_proc.p_un.__p_starttime
        // The cache key only needs kernel metadata. Resolve the executable
        // vnode path on a signing cache miss, and only for bundle matching.
        return .init(euid: info.kp_eproc.e_ucred.cr_uid, ppid: info.kp_eproc.e_ppid,
                     startSec: start.tv_sec, startUsec: start.tv_usec, executablePath: nil)
    }

    private static func processPath(pid: Int32) -> String? {
        var path = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        guard proc_pidpath(pid, &path, UInt32(path.count)) > 0,
              let rawPath = String(validatingUTF8: path),
              let canonical = canonicalPath(rawPath), canonical.utf8.elementsEqual(rawPath.utf8) else { return nil }
        return canonical
    }

    private static func canonicalPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(validatingUTF8: resolved)
    }

    private static func inspectSigning(pid: Int32) -> SigningEvidence? {
        var guest: SecCode?
        let attributes = [kSecGuestAttributePid as String: NSNumber(value: pid)] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &guest) == errSecSuccess, let guest else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(guest, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var rawInfo: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &rawInfo) == errSecSuccess,
              let info = rawInfo as? [String: Any], let identifier = info[kSecCodeInfoIdentifier as String] as? String else {
            return nil
        }
        let flags = (info[kSecCodeInfoFlags as String] as? NSNumber)?.uint32Value ?? 0
        let entitlements = info[kSecCodeInfoEntitlementsDict as String] as? [String: Any] ?? [:]
        return .init(identifier: identifier, hardenedRuntime: flags & SecCodeSignatureFlags.runtime.rawValue != 0,
                     entitlements: entitlements, satisfiesRequirement: { text in
            guard let requirement = makeRequirement(text) else { return false }
            return SecCodeCheckValidity(guest, [], requirement) == errSecSuccess
        })
    }

    private static func checkBundle(url: URL, executablePath: String, requirement text: String) -> Bool {
        // Re-resolve both paths at bundle validation, and compare path bytes so
        // a different filesystem spelling cannot satisfy the containment check.
        guard let app = canonicalPath(url.path), app.hasSuffix(".app"),
              let executable = canonicalPath(executablePath), executable.utf8.elementsEqual(executablePath.utf8),
              executable.utf8.starts(with: (app + "/Contents/").utf8),
              let requirement = makeRequirement(text) else { return false }
        let canonicalURL = URL(fileURLWithPath: app, isDirectory: true)
        var bundle: SecStaticCode?
        guard SecStaticCodeCreateWithPath(canonicalURL as CFURL, [], &bundle) == errSecSuccess, let bundle else { return false }
        return SecStaticCodeCheckValidity(bundle, [], requirement) == errSecSuccess
    }

    private static func makeRequirement(_ text: String) -> SecRequirement? {
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess else { return nil }
        return requirement
    }
}
