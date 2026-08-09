import Foundation

/// Supplies the release notes for the version of Trio that is installed, and remembers whether
/// the user has already seen them.
///
/// Notes come from three places, in order of preference:
///
/// 1. A live fetch from the GitHub releases API, because notes are sometimes edited after a
///    release is published.
/// 2. The copy cached from the last successful fetch.
/// 3. The copy bundled at build time by `scripts/capture-release-notes.sh`, so a phone that has
///    never been online still has something to show.
///
/// The release is looked up by exact tag, so Trio only ever shows notes for the version actually
/// installed - never for a newer release the user has not built.
@MainActor final class ReleaseNotesService: ObservableObject {
    static let shared = ReleaseNotesService()

    private init() {}

    // MARK: - Constants

    private static let repository = "nightscout/Trio"

    /// How long a successful fetch is trusted before another one is attempted.
    private static let refreshInterval: TimeInterval = 86400 // 24 hours

    private static let bundledResourceName = "BundledReleaseNotes"

    // MARK: - Persisted State

    /// Notes from the last successful fetch.
    @Persisted(key: "cachedReleaseNotes") private var cachedNotes: ReleaseNotes? = nil

    /// When `cachedNotes` was fetched.
    @Persisted(key: "releaseNotesLastFetched") private var lastFetched: Date? = .distantPast

    /// Version whose notes the user has dismissed, for example `0.8.4`.
    ///
    /// Stored rather than a plain flag so that installing a newer release surfaces the panel
    /// again without anything having to reset it.
    @Persisted(key: "acknowledgedReleaseNotesVersion") private var acknowledgedVersion: String? = nil

    // MARK: - Published State

    /// Notes for the installed version, once resolved. `nil` when none could be found.
    @Published private(set) var notes: ReleaseNotes?

    // MARK: - Derived State

    /// The installed marketing version, for example `0.8.4`.
    ///
    /// Development builds carry a four-part `AppDevVersion` as well, but their
    /// `CFBundleShortVersionString` still matches the release they were branched from, which is
    /// the release whose notes apply.
    var installedVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
    }

    /// Whether the Home panel should offer the notes.
    var hasUnacknowledgedNotes: Bool {
        guard let notes else {
            return false
        }
        return acknowledgedVersion != notes.version
    }

    // MARK: - Public Methods

    /// Resolves the notes for the installed version, preferring fresh content.
    ///
    /// Safe to call repeatedly; the network is only touched once per `refreshInterval`.
    func load() async {
        // Show whatever is already available first, so the panel does not wait on the network.
        notes = resolveOffline()

        guard shouldRefresh else {
            return
        }

        if let fetched = await fetch(version: installedVersion) {
            cachedNotes = fetched
            lastFetched = Date()
            notes = fetched
        }
    }

    /// Marks the installed version's notes as seen, which removes the Home panel entry.
    ///
    /// The notes stay reachable from Settings afterwards.
    func acknowledge() {
        guard let notes else {
            return
        }
        acknowledgedVersion = notes.version
        objectWillChange.send()
    }

    // MARK: - Private Methods

    private var shouldRefresh: Bool {
        Date().timeIntervalSince(lastFetched ?? .distantPast) > Self.refreshInterval
    }

    /// Best available notes without touching the network.
    private func resolveOffline() -> ReleaseNotes? {
        if let cachedNotes, cachedNotes.version == installedVersion {
            return cachedNotes
        }
        if let bundled = loadBundled(), bundled.version == installedVersion {
            return bundled
        }
        return nil
    }

    /// Reads the copy written into the app bundle at build time.
    private func loadBundled() -> ReleaseNotes? {
        guard let url = Bundle.main.url(forResource: Self.bundledResourceName, withExtension: "json"),
              let data = try? Data(contentsOf: url)
        else {
            return nil
        }

        do {
            return try ReleaseNotes.decodeBundled(from: data)
        } catch {
            debug(.default, "Failed to decode bundled release notes: \(error)")
            return nil
        }
    }

    /// Fetches the release whose tag matches the installed version.
    ///
    /// Returns `nil` for any failure, including no release existing for this version, which is
    /// the normal case for a build made between releases.
    private func fetch(version: String) async -> ReleaseNotes? {
        guard !version.isEmpty,
              let url = URL(string: "https://api.github.com/repos/\(Self.repository)/releases/tags/v\(version)")
        else {
            return nil
        }

        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 20

        do {
            let (data, response) = try await URLSession.shared.data(for: request)

            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                let status = (response as? HTTPURLResponse)?.statusCode ?? -1
                debug(.default, "Release notes fetch for v\(version) returned status \(status)")
                return nil
            }

            return try JSONDecoder().decode(ReleaseNotes.self, from: data)
        } catch {
            debug(.default, "Failed to fetch release notes for v\(version): \(error)")
            return nil
        }
    }
}
