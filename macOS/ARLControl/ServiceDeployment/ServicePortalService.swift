import Foundation
import Darwin

extension SettingsService {
    private func validateServicePortalHome() throws {
        if FileManager.default.fileExists(atPath: home.appendingPathComponent("disabled").path) { throw ARLError(code: "user_disabled") }
        var info = stat()
        guard lstat(home.path, &info) == 0 else { throw ARLError(code: "disconnected") }
        guard (info.st_mode & S_IFMT) == S_IFDIR, info.st_uid == geteuid(), (info.st_mode & 0o077) == 0 else { throw ARLError(code: "unsafe_home") }
    }
    func readServicePortalCatalog() async -> MetadataFeature<ServicePortalCatalog> {
        if demo { return .unsupported }
        do {
            try validateServicePortalHome()
            let reply = try await ARLClient(home: home, app: "settings").rpc("settings.service_portal.catalog.v1", timeout: 3)
            return .available(try ServicePortalContract.decodeCatalog(JSONEncoder().encode(reply)))
        } catch let error as ARLError where error.code == "unknown_method" { return .unsupported }
        catch { return .unavailable("service_portal_read_failed") }
    }
    func readServicePortalReview(serviceID: String, catalogSHA256: String) async -> MetadataFeature<ServicePortalReview> {
        if demo { return .unsupported }
        do {
            try validateServicePortalHome()
            let reply = try await ARLClient(home: home, app: "settings").rpc("settings.service_portal.review.v1", params: [
                "service_id": .string(serviceID), "catalog_sha256": .string(catalogSHA256)], timeout: 3)
            return .available(try ServicePortalContract.decodeReview(JSONEncoder().encode(reply), serviceID: serviceID, catalogSHA256: catalogSHA256))
        } catch let error as ARLError where error.code == "unknown_method" { return .unsupported }
        catch { return .unavailable("service_portal_read_failed") }
    }
}
