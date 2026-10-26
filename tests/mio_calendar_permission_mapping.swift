import Foundation

@main enum MioCalendarPermissionMappingFixture {
    static func main() throws {
        let labels = [
            "not_determined": "未申请",
            "write_only": "允许写入",
            "full_access": "允许读写",
            "denied": "未授权",
            "restricted": "系统限制",
            "unknown": "待检查",
        ]
        let observed: Int64 = 1_000_000
        for (state, title) in labels {
            let raw = Data("{\"status\":\"ok\",\"authorization\":\"\(state)\",\"prompts_requested\":false,\"data_read\":false}".utf8)
            let parsed = try MioCalendarPermissionStatus.decode(raw, observedAtMS: observed)
            precondition(parsed.permissionTitle(nowMS: observed + 100) == title)
            precondition(parsed.permissionTitle(nowMS: observed + 10_001) == "待检查")
            precondition(parsed.permissionTitle(nowMS: observed - 1) == "待检查")
        }
        let invalid = [
            "{\"status\":\"ok\",\"authorization\":\"ready\",\"prompts_requested\":false,\"data_read\":false}",
            "{\"status\":\"ok\",\"authorization\":\"write_only\",\"prompts_requested\":true,\"data_read\":false}",
            "{\"status\":\"ok\",\"authorization\":\"write_only\",\"prompts_requested\":false,\"data_read\":true}",
            "{\"status\":\"ok\",\"authorization\":\"write_only\",\"prompts_requested\":0,\"data_read\":false}",
            "{\"status\":\"ok\",\"authorization\":\"write_only\",\"prompts_requested\":false,\"data_read\":false,\"event_title\":\"no\"}",
        ]
        for raw in invalid {
            do { _ = try MioCalendarPermissionStatus.decode(Data(raw.utf8), observedAtMS: observed); fatalError("accepted invalid status") }
            catch MioCalendarStatusFault.invalidResponse { }
        }
        precondition(MioCalendarPermissionStatus.operationTitle == "待验证")
        print("PASS 6 permission labels, stale/future evidence, 5 invalid frames, create remains unknown")
    }
}
