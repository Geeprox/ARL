import Foundation

@main struct ServicePortalFixture {
    static func require(_ value: Bool, _ code: String) throws {
        guard value else { throw ARLError(code: code) }
    }
    static func rejected(_ operation: () throws -> Void) throws {
        do { try operation() } catch { return }
        throw ARLError(code: "invalid_fixture_accepted")
    }
    static func main() throws {
        guard CommandLine.arguments.count == 2 else { throw ARLError(code: "fixture_directory_required") }
        let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        func read(_ name: String) throws -> Data { try Data(contentsOf: directory.appendingPathComponent(name)) }
        let catalog = try ServicePortalContract.decodeCatalog(read("synthetic-catalog.json"))
        try require(catalog.entries.count == 2, "catalog_count")
        let unperformed = try ServicePortalContract.decodeReview(read("synthetic-review-unperformed.json"),
            serviceID: "service.hub", catalogSHA256: catalog.catalog_sha256)
        try require(unperformed.plan.execution == "not_performed" && !unperformed.plan.apply_available &&
                    unperformed.statuses.allSatisfy { $0.readiness == .notChecked }, "false_execution")
        let readyData = try read("synthetic-review-ready.json")
        let ready = try ServicePortalContract.decodeReview(readyData, serviceID: "service.indexer", catalogSHA256: catalog.catalog_sha256)
        try require(ready.statuses[0].readiness == .ready && ready.registry[0].authorizedTools.isEmpty, "ready_contract")
        let at = Date(timeIntervalSince1970: Double(ready.checkedAtMilliseconds) / 1000)
        try require(ready.statuses[0].displayedReadiness(at: at, entry: ready.plan.services[0], registry: ready.registry) == .ready, "bound_ready")
        try require(ready.statuses[0].displayedReadiness(at: at.addingTimeInterval(31), entry: ready.plan.services[0], registry: ready.registry) == .stale, "ready_expiry")
        try rejected { _ = try ServicePortalContract.decodeReview(readyData, serviceID: "service.hub", catalogSHA256: catalog.catalog_sha256) }
        try rejected { _ = try ServicePortalContract.decodeReview(readyData, serviceID: "service.indexer", catalogSHA256: String(repeating: "0", count: 64)) }
        func mutated(_ body: (inout [String: Any]) -> Void) throws -> Data {
            var object = try JSONSerialization.jsonObject(with: readyData) as! [String: Any]
            body(&object)
            return try JSONSerialization.data(withJSONObject: object)
        }
        let badTarget = try mutated { root in
            var statuses = root["statuses"] as! [[String: Any]]
            statuses[0]["target_id"] = "different-target"
            root["statuses"] = statuses
        }
        let syntheticReady = try mutated { root in
            var statuses = root["statuses"] as! [[String: Any]]
            statuses[0]["source"] = "synthetic"
            root["statuses"] = statuses
        }
        let missingRegistry = try mutated { $0["registry"] = [] }
        let duplicateStatus = try mutated { root in
            let statuses = root["statuses"] as! [[String: Any]]
            root["statuses"] = statuses + statuses
        }
        let unexpectedTools = try mutated { root in
            var registry = root["registry"] as! [[String: Any]]
            registry[0]["authorized_tools"] = ["service.shell"]
            root["registry"] = registry
        }
        for data in [badTarget, syntheticReady, missingRegistry, duplicateStatus, unexpectedTools] {
            try rejected { _ = try ServicePortalContract.decodeReview(data, serviceID: "service.indexer", catalogSHA256: catalog.catalog_sha256) }
        }
        var state = ServicePortalPresentation()
        state.setConnection(true)
        let token = state.beginRead()!
        try require(state.receiveCatalog(.available(catalog), token: token), "catalog_state")
        state.receiveReview(.available(ready), token: token)
        let second = state.beginRead()!
        state.receiveReview(.unsupported, token: second)
        try require(state.review.value == nil, "unsupported_retained_ready")
        state.receiveReview(.available(ready), token: token)
        try require(state.review.value == nil, "late_response_restored_ready")
        let third = state.beginRead()!
        state.setConnection(false)
        state.receiveReview(.available(ready), token: third)
        try require(state.review.value == nil && state.beginRead() == nil, "disconnected_restored_ready")
        state.setConnection(true)
        let failed = state.beginRead()!
        try require(!state.receiveCatalog(.unavailable("invalid_response"), token: failed) &&
                    state.review.value == nil && !state.reading, "failed_catalog_restored_ready")
        print("ServicePortalFixture: 17 checks passed; all HOST/ready input objects are synthetic; no socket, App or service launched.")
    }
}
