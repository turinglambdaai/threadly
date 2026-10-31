import Foundation
import RivetUpdate

/// Threadly updater — a thin product adapter over rivet's `RivetUpdate`
/// module (the family's shared host-side update client): this file only
/// contributes the product facts (feed, signing key, key id, bundle name)
/// plus the 4-hour silent-check throttle. Verification, the bounded
/// delegate-driven download, the atomic swap with rollback, and the
/// quit/relaunch handoff all live in the library; the previous ported
/// implementation hand-rolled CryptoKit Ed25519 over the signed wrapper
/// and a swap script with a bare `terminate` — all replaced.
///
/// Only a copy under /Applications (or ~/Applications) can self-update —
/// debug builds and random folders get the "not installed" answer.
struct UpdateService {
    /// Ed25519 public key (base64, raw 32 bytes) — pair of the
    /// UPDATE_ED25519_PRIVATE_KEY GitHub secret that signs release
    /// manifests (generate: scripts/update-keys.sh). The same bytes the
    /// engine embeds in app/update.rkt.
    static let publicKeyBase64 = "xwjCTB1ixovxtwrHoG1JnG3amjb9HBBIWuUHGIvr5Fs="

    /// The manifest must carry this key id — rotation ships a build that
    /// trusts the next key before releases stop being signed with this one.
    static let expectedKeyID = "threadly-2026-10"

    static let manifestURL = URL(string:
        "https://github.com/turlamai/threadly/releases/latest/download/update-manifest.json")!
    static let releasesPage = "https://github.com/turlamai/threadly/releases/latest"
    static let throttleSeconds: TimeInterval = 4 * 60 * 60

    public enum UpdateError: LocalizedError {
        case notInstalled
        case badPublicKey
        case manifestMissing
        case signatureInvalid
        case checksumMismatch
        case versionMismatch(expected: String, got: String)
        case network(String)

        var errorDescription: String? {
            switch self {
            case .notInstalled: return "Threadly is not installed to /Applications"
            case .badPublicKey: return "Update key is malformed"
            case .manifestMissing: return "Update manifest is missing or malformed"
            case .signatureInvalid: return "Update manifest signature is invalid"
            case .checksumMismatch: return "Downloaded update failed verification"
            case .versionMismatch(let e, let g): return "Version mismatch (\(e) / \(g))"
            case .network(let message): return message
            }
        }
    }

    enum CheckResult: Equatable {
        case upToDate
        case available(Manifest)
    }

    typealias Manifest = RivetUpdateManifest

    /// nil only when the (constant) product configuration failed the
    /// library's fail-closed validation — surfaced as badPublicKey.
    private let service: RivetUpdateService?

    /// Feed URL; production callers use the default (the moving "latest"
    /// location).
    init() {
        let configuration = RivetUpdateConfiguration(
            feedURL: Self.manifestURL,
            publicKeyBase64: Self.publicKeyBase64,
            keyID: Self.expectedKeyID,
            bundleName: "Threadly.app")
        self.service = try? RivetUpdateService(configuration: configuration)
    }

    /// Translates library errors into this product's error surface.
    private static func map(_ error: RivetUpdateError) -> UpdateError {
        switch error {
        case .notInstalled: return .notInstalled
        case .badPublicKey, .invalidConfiguration: return .badPublicKey
        case .manifestMissing: return .manifestMissing
        case .signatureInvalid: return .signatureInvalid
        case .checksumMismatch, .sizeMismatch: return .checksumMismatch
        case .versionMismatch(let expected, let got):
            return .versionMismatch(expected: expected, got: got)
        case .network(let message): return .network(message)
        }
    }

    /// The installed bundle this copy can update in place, or nil for
    /// development copies (not under /Applications or ~/Applications).
    var installedBundleURL: URL? { service?.installedBundleURL }

    var canUpdate: Bool { service?.canUpdate ?? false }

    /// Fetches the latest release manifest, verifies its Ed25519 signature
    /// and compares versions. Silent checks are throttled to once per
    /// throttleSeconds via UserDefaults; manual checks always hit the feed.
    /// The stamp records a SETTLED check only — one that produced an answer
    /// (up-to-date or available). Failures leave it alone so the next
    /// launch retries instead of waiting out the throttle (the Linux
    /// host's contract; the write used to happen before the check ran).
    func check(manual: Bool) async -> Result<CheckResult, Error> {
        if !manual {
            let last = UserDefaults.standard.double(forKey: "last-update-check")
            if Date().timeIntervalSince1970 - last < Self.throttleSeconds {
                return .success(.upToDate)
            }
        }

        guard installedBundleURL != nil else { return .failure(UpdateError.notInstalled) }
        guard let service else { return .failure(UpdateError.badPublicKey) }
        do {
            let result = try await service.check()
            switch result {
            case .upToDate:
                Self.recordSettledCheck()
                return .success(.upToDate)
            case .available(let manifest):
                Self.recordSettledCheck()
                return .success(.available(manifest))
            }
        } catch let error as RivetUpdateError {
            return .failure(Self.map(error))
        } catch {
            return .failure(error)
        }
    }

    /// UserDefaults stays the store; only the write timing changed — a
    /// settled check (an answer) stamps, a failed check does not.
    private static func recordSettledCheck() {
        UserDefaults.standard.set(Date().timeIntervalSince1970,
                                  forKey: "last-update-check")
    }

    /// Downloads, verifies, swaps the bundle in place and relaunches.
    /// Throws before touching the running install when anything is off;
    /// on success this method does not return (the library terminates the
    /// app as part of the swap).
    func downloadAndInstall(_ manifest: Manifest) async throws {
        guard let service else { throw UpdateError.badPublicKey }
        do {
            try await service.downloadAndInstall(manifest)
        } catch let error as RivetUpdateError {
            throw Self.map(error)
        }
    }
}
