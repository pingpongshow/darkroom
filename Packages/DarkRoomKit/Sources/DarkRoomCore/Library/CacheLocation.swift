import Foundation

/// Where per-account caches (thumbnails, previews, downloaded originals) live:
/// `~/Library/Caches/DarkRoom/<account>/`.
public enum CacheLocation {
    public static var root: URL {
         FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appending(path: "DarkRoom")
    }

    public static func account(_ id: UUID) -> URL { root.appending(path: id.uuidString) }

    /// Clears an account's caches (on sign-out). Everything here can be downloaded again.
    public static func clear(_ id: UUID) { try? FileManager.default.removeItem(at: account(id)) }
}
