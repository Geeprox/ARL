import Foundation
import Security

func emit(_ valid: Bool) -> Never {
    FileHandle.standardOutput.write(Data((valid ? "{\"valid\":true}\n" : "{\"valid\":false}\n").utf8))
    exit(0)
}
let raw = FileHandle.standardInput.readDataToEndOfFile()
guard raw.count <= 8192,
      let body = try? JSONSerialization.jsonObject(with: raw) as? [String: Any],
      Set(body.keys) == Set(["audit_token", "requirement"]),
      let hex = body["audit_token"] as? String, hex.utf8.count == 64,
      let requirementText = body["requirement"] as? String, requirementText.utf8.count <= 4096 else { emit(false) }
var token = Data()
var index = hex.startIndex
for _ in 0..<32 {
    let end = hex.index(index, offsetBy: 2)
    guard let byte = UInt8(hex[index..<end], radix: 16) else { emit(false) }
    token.append(byte); index = end
}
var requirement: SecRequirement?
guard SecRequirementCreateWithString(requirementText as CFString, [], &requirement) == errSecSuccess,
      let requirement else { emit(false) }
var guest: SecCode?
// Audit token includes PID version: do not authenticate a new process that reuses a PID.
let attributes = [kSecGuestAttributeAudit as String: token] as CFDictionary
guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &guest) == errSecSuccess,
      let guest else { emit(false) }
emit(SecCodeCheckValidity(guest, SecCSFlags(rawValue: kSecCSStrictValidate), requirement) == errSecSuccess)
