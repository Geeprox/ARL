import Foundation
import Security
import Darwin

struct MessagesHostPolicyV2: Decodable, Sendable {
    let schema_version: Int
    let run_not_after: Double
    let mode: String
    let enabled: Int
    let control_requirement: String
    let state_root: String
    let run_id: String
    let scope_seconds: Int
    let max_sends: Int
    let metadata_limit: Int
    let metadata_admitted: Int
    let launch_attribution_verified: Int
    let python_path: String
    let python_sha256: String
    let python_requirement: String
    let runtime_closure_sha256: String
    let runtime_root: String
    let database_path: String
    let imsg_relative_path: String
    let imsg_sha256: String
    let imsg_requirement: String

    static func load() throws -> (Self, String) {
        guard let root = Bundle.main.resourceURL,
              let expected = Bundle.main.object(forInfoDictionaryKey:"ARLMessagesPolicySHA256") as? String else { throw MessagesTransportFault("activation_not_approved") }
        let raw = try MessagesNativeIO.privateFile(root.appendingPathComponent("activation.json").path)
        guard MessagesNativeIO.hash(raw) == expected else { throw MessagesTransportFault("identity_changed") }
        guard Bundle.main.object(forInfoDictionaryKey:"ARLMessagesWireVersion") as? Int == 2 else { throw MessagesTransportFault("invalid_request") }
        let json = try MessagesJSON.decode(raw)
        let keys:Set<String> = ["schema_version","mode","enabled","control_requirement","state_root","run_id","scope_seconds","max_sends","metadata_limit","metadata_admitted","launch_attribution_verified","python_path","python_sha256","python_requirement","runtime_closure_sha256","runtime_root","database_path","imsg_relative_path","imsg_sha256","imsg_requirement","run_not_after"]
        guard Set(json.value.keys) == keys,
              ["schema_version","enabled","scope_seconds","max_sends","metadata_limit","metadata_admitted","launch_attribution_verified"].allSatisfy({MessagesNativeIO.integer(json.value[$0]) != nil}) else { throw MessagesTransportFault("invalid_request") }
        let policy = try JSONDecoder().decode(Self.self,from:raw)
        guard policy.schema_version == 2, policy.run_not_after.isFinite, policy.run_not_after >= 0, policy.enabled == 0 || policy.run_not_after > 0, [0,1].contains(policy.enabled), policy.scope_seconds == 900,
              policy.max_sends == 1, policy.metadata_limit == 20, [0,1].contains(policy.metadata_admitted),
              [0,1].contains(policy.launch_attribution_verified),
              UUID(uuidString:policy.run_id)?.uuidString.lowercased() == policy.run_id,
              policy.imsg_relative_path == "Contents/Helpers/imsg", policy.state_root.hasPrefix("/"),
              policy.database_path.hasPrefix("/"), policy.python_path.hasPrefix("/"), policy.runtime_root.hasPrefix("/"),
              [policy.python_sha256,policy.runtime_closure_sha256,policy.imsg_sha256].allSatisfy({$0.range(of:"^[a-f0-9]{64}$",options:.regularExpression) != nil}),
              policy.control_requirement.range(of:#"^cdhash H"[a-fA-F0-9]{40,64}"$"#,options:.regularExpression) != nil else { throw MessagesTransportFault("invalid_request") }
        #if MESSAGES_HOST_FIXTURE
        guard policy.mode == "synthetic", policy.database_path == policy.state_root + "/synthetic-chat.db" else { throw MessagesTransportFault("invalid_request") }
        #else
        guard policy.mode == "live" else { throw MessagesTransportFault("invalid_request") }
        #endif
        return (policy,expected)
    }

    var imsgPath: String { Bundle.main.bundleURL.appendingPathComponent(imsg_relative_path).path }
    func verifyLaunch() throws {
        _ = try NativePermissionIdentity.current(expectedBundle:"local.arl.messagesbridge")
        guard MessagesNativeIO.hash(try Data(contentsOf:URL(fileURLWithPath:python_path))) == python_sha256 else { throw MessagesTransportFault("identity_changed") }
        try Self.verifyCode(python_path,requirement:python_requirement)
        let resources = Bundle.main.resourceURL!
        let raw = try MessagesNativeIO.privateFile(resources.appendingPathComponent("runtime-closure.json").path,limit:1048576)
        guard MessagesNativeIO.hash(raw) == runtime_closure_sha256,
              let closure = try JSONSerialization.jsonObject(with:raw) as? [String:String] else { throw MessagesTransportFault("identity_changed") }
        let root = URL(fileURLWithPath:runtime_root).resolvingSymlinksInPath()
        guard root.path == runtime_root, python_path.hasPrefix(runtime_root+"/") else { throw MessagesTransportFault("identity_changed") }
        guard let paths = FileManager.default.enumerator(at:root,includingPropertiesForKeys:[.isRegularFileKey],options:[]) else { throw MessagesTransportFault("identity_changed") }
        var actual:Set<String> = []
        while let path = paths.nextObject() as? URL {
            if path.lastPathComponent == "__pycache__" { paths.skipDescendants(); continue }
            if ["pyc","pyo"].contains(path.pathExtension) { continue }
            if (try path.resourceValues(forKeys:[.isRegularFileKey])).isRegularFile == true {
                let resolved = path.resolvingSymlinksInPath().path
                guard resolved.hasPrefix(runtime_root+"/") else { throw MessagesTransportFault("identity_changed") }
                actual.insert(resolved)
            }
        }
        guard actual == Set(closure.keys) else { throw MessagesTransportFault("identity_changed") }
        for (path,hash) in closure {
            guard path.hasPrefix(runtime_root+"/"), !path.contains("/../"), !path.contains("/__pycache__/"),
                  MessagesNativeIO.hash(try Data(contentsOf:URL(fileURLWithPath:path))) == hash else { throw MessagesTransportFault("identity_changed") }
        }
        guard MessagesNativeIO.hash(try Data(contentsOf:URL(fileURLWithPath:imsgPath))) == imsg_sha256 else { throw MessagesTransportFault("identity_changed") }
        try Self.verifyCode(imsgPath,requirement:imsg_requirement)
        // Production cannot acquire a generic caller-selected executable or script.
        try Self.verifyCode("/usr/bin/osascript",requirement:"anchor apple")
    }
    static func verifyCode(_ path:String,requirement:String) throws {
        var code:SecStaticCode?, rule:SecRequirement?
        guard SecStaticCodeCreateWithPath(URL(fileURLWithPath:path) as CFURL,[],&code) == errSecSuccess, let code,
              SecRequirementCreateWithString(requirement as CFString,[],&rule) == errSecSuccess, let rule,
              SecStaticCodeCheckValidity(code,SecCSFlags(rawValue:kSecCSStrictValidate),rule) == errSecSuccess else { throw MessagesTransportFault("identity_changed") }
    }
}
