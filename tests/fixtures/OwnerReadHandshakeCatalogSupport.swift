import Foundation

// Unused catalog membership only. The test compiles the real wire, authority,
// peer verifier, transport and logger; it never loads an installed authority.
enum NASCapability { static let names: Set<String> = ["mio_nas_read_text"] }
enum AppleCapability {
    static let reminderCreate = "mio_reminders_create"
    static let names: Set<String> = [reminderCreate]
}
enum AppleProductCapability { static let names: Set<String> = ["mio_reminders_get"] }
enum MusicPlaylistCoverCapability { static let name = "mio_netease_playlist_update_cover" }
