import Foundation
import CoreFoundation

/// Permission of the actual Mio Calendar effect host. It never implies a create grant.
struct MioCalendarPermissionStatus: Sendable, Equatable {
    let authorization: String
    let observedAtMS: Int64

    static let states: Set<String> = ["not_determined", "write_only", "full_access", "denied", "restricted", "unknown"]
    private static func strictFalse(_ value: Any?) -> Bool {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return false }
        return !number.boolValue
    }

    static func decode(_ data: Data, observedAtMS: Int64) throws -> Self {
        guard data.count <= 1024,
              let value = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(value.keys) == ["status", "authorization", "prompts_requested", "data_read"],
              value["status"] as? String == "ok",
              let authorization = value["authorization"] as? String, states.contains(authorization),
              strictFalse(value["prompts_requested"]),
              strictFalse(value["data_read"]) else { throw MioCalendarStatusFault.invalidResponse }
        return Self(authorization: authorization, observedAtMS: observedAtMS)
    }

    func permissionTitle(nowMS: Int64) -> String {
        guard nowMS >= observedAtMS, nowMS - observedAtMS <= 10_000 else { return "待检查" }
        switch authorization {
        case "write_only": return "允许写入"
        case "full_access": return "允许读写"
        case "not_determined": return "未申请"
        case "denied": return "未授权"
        case "restricted": return "系统限制"
        default: return "待检查"
        }
    }

    static let operationTitle = "待验证"
}

enum MioCalendarStatusFault: Error, Sendable {
    case notDeployed, identityUnverified, probeUnavailable, invalidResponse
}
