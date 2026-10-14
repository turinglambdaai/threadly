import SwiftUI

/// About sheet: version, copyright, one-line description, license, and the
/// two family links (product site + issue tracker). Opened from the app
/// menu's About Threadly item — the packaged bundle's short version wins,
/// with the generated config as the dev-build fallback.
struct AboutSheet: View {
    @Environment(\.dismiss) private var dismiss

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? RivetGeneratedConfig.version
    }

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 44))
                .foregroundStyle(DesignTokens.accent)
            Text("Threadly v\(version)")
                .font(.system(size: 15, weight: .semibold))
            Text("© 2026 Threadly Team")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Text("Read the Racket community, outside the browser.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Text("Released under the GNU Affero General Public License v3.0.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            HStack(spacing: 20) {
                Link("Website",
                     destination: URL(string: "https://threadly.jrtx.site")!)
                Link("Report an Issue",
                     destination: URL(string: "https://github.com/turinglambdaai/threadly/issues")!)
            }
            .font(.system(size: 12))
            .tint(DesignTokens.accent)
            Button("OK") { dismiss() }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .tint(DesignTokens.accent)
        }
        .padding(28)
        .frame(width: 320)
    }
}
