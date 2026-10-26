import Foundation
import AppKit
import Security
import Darwin

struct MessagesNativeDeployment: Decodable, Sendable {
    let schema_version:Int
    let helper_bundle_path:String
    let state_root:String
    let control_requirement:String
    let helper_requirement:String
    let helper_executable_sha256:String
    let helper_designated_requirement_sha256:String
    let closure_sha256:String
    let policy_sha256:String
    let closure_path:String
    static func load(_ path:String) throws -> Self {
        let raw = try MessagesNativeIO.privateFile(path)
        let value = try MessagesJSON.decode(raw).value
        guard Set(value.keys) == ["schema_version","helper_bundle_path","state_root","control_requirement","helper_requirement","helper_executable_sha256","helper_designated_requirement_sha256","closure_sha256","policy_sha256","closure_path"],
              MessagesNativeIO.integer(value["schema_version"]) == 1 else { throw MessagesTransportFault("invalid_deployment") }
        return try JSONDecoder().decode(Self.self,from:raw)
    }
    func verify() throws {
        var own:SecCode?, rule:SecRequirement?
        guard SecCodeCopySelf([],&own) == errSecSuccess, let own,
              SecRequirementCreateWithString(control_requirement as CFString,[],&rule) == errSecSuccess, let rule,
              SecCodeCheckValidity(own,SecCSFlags(rawValue:kSecCSStrictValidate),rule) == errSecSuccess else { throw MessagesTransportFault("identity_unverified") }
        guard let bundle = Bundle(path:helper_bundle_path), bundle.bundleIdentifier == "local.arl.messagesbridge",
              bundle.object(forInfoDictionaryKey:"CFBundleExecutable") as? String == "ARLMessagesBridge",
              bundle.object(forInfoDictionaryKey:"ARLMessagesPolicySHA256") as? String == policy_sha256 else { throw MessagesTransportFault("identity_changed") }
        var code:SecStaticCode?, requirement:SecRequirement?, dr:SecRequirement?, drData:CFData?
        guard SecStaticCodeCreateWithPath(URL(fileURLWithPath:helper_bundle_path) as CFURL,[],&code) == errSecSuccess, let code,
              SecRequirementCreateWithString(helper_requirement as CFString,[],&requirement) == errSecSuccess, let requirement,
              SecStaticCodeCheckValidity(code,SecCSFlags(rawValue:kSecCSStrictValidate),requirement) == errSecSuccess,
              SecCodeCopyDesignatedRequirement(code,[],&dr) == errSecSuccess, let dr,
              SecRequirementCopyData(dr,[],&drData) == errSecSuccess, let drData,
              MessagesNativeIO.hash(drData as Data) == helper_designated_requirement_sha256 else { throw MessagesTransportFault("identity_changed") }
        try MessagesNativeIO.privateDirectory(state_root)
        let raw = try MessagesNativeIO.privateFile(closure_path,limit:1048576)
        guard MessagesNativeIO.hash(raw) == closure_sha256,
              let closure = try JSONSerialization.jsonObject(with:raw) as? [String:String],
              closure["Contents/MacOS/ARLMessagesBridge"] == helper_executable_sha256 else { throw MessagesTransportFault("identity_changed") }
        let actual = try FileManager.default.subpathsOfDirectory(atPath:helper_bundle_path).filter {
            var st = stat(); return lstat(helper_bundle_path+"/"+$0,&st) == 0 && st.st_mode&S_IFMT == S_IFREG
        }
        guard Set(actual) == Set(closure.keys) else { throw MessagesTransportFault("identity_changed") }
        for (relative,hash) in closure {
            guard relative.hasPrefix("Contents/"), !relative.contains("..") else { throw MessagesTransportFault("identity_changed") }
            let path = helper_bundle_path+"/"+relative
            var st = stat()
            guard lstat(path,&st) == 0, st.st_mode&S_IFMT == S_IFREG, st.st_uid == getuid(), st.st_mode&0o022 == 0,
                  MessagesNativeIO.hash(try Data(contentsOf:URL(fileURLWithPath:path))) == hash else { throw MessagesTransportFault("identity_changed") }
        }
        let policy = try MessagesJSON.decode(MessagesNativeIO.privateFile(helper_bundle_path+"/Contents/Resources/activation.json")).value
        guard policy["control_requirement"] as? String == control_requirement, policy["state_root"] as? String == state_root else { throw MessagesTransportFault("identity_changed") }
    }
}

/// The real native Control process implements this protocol through the same
/// mutually authenticated socket exercised by the compiled fixture client.
public struct NativeMessagesClient: MessagesOnboardingClient, Sendable {
    public let deploymentPath:String
    public init(deploymentPath:String) { self.deploymentPath = deploymentPath }
    public func perform(_ request:OnboardingRequest) async throws -> OnboardingReply {
        let deployment = try MessagesNativeDeployment.load(deploymentPath)
        try deployment.verify()
        do { return try await Task.detached { try Self.exchange(request,deployment) }.value }
        catch let error as MessagesTransportFault where error.code == "transport_unavailable" && request.command == "begin" {
            #if MESSAGES_HOST_FIXTURE
            throw error // Fixture runner owns exact processes; never enters LaunchServices.
            #else
            try await Self.launch(deployment)
            for _ in 0..<40 {
                do { return try await Task.detached { try Self.exchange(request,deployment) }.value }
                catch let error as MessagesTransportFault where error.code == "transport_unavailable" { try await Task.sleep(nanoseconds:100_000_000) }
            }
            throw MessagesTransportFault("host_unavailable")
            #endif
        }
    }
    @MainActor private static func launch(_ deployment:MessagesNativeDeployment) async throws {
        let config = NSWorkspace.OpenConfiguration()
        config.arguments = ["--serve"]; config.activates = false; config.createsNewApplicationInstance = true
        _ = try await NSWorkspace.shared.openApplication(at:URL(fileURLWithPath:deployment.helper_bundle_path),configuration:config)
    }
    private static func exchange(_ request:OnboardingRequest,_ deployment:MessagesNativeDeployment) throws -> OnboardingReply {
        let fd = try MessagesNativeIO.socketAt(deployment.state_root+"/control.sock",listen:false)
        defer { close(fd) }
        let peer = try MessagesNativeIO.Peer(fd,requirement:deployment.helper_requirement)
        try MessagesNativeIO.send(JSONEncoder().encode(request),fd)
        guard let raw = try MessagesNativeIO.line(fd,limit:65536,seconds:request.command == "permission_action" ? 195:20),
              peer.signatureCurrent() else { throw MessagesTransportFault("identity_unverified") }
        let value = try MessagesJSON.decode(raw).value
        guard value["request_id"] as? String == request.requestID.uuidString.lowercased(),
              value["command"] as? String == request.command,
              MessagesNativeIO.integer(value["schema_version"]) == 1 else { throw MessagesTransportFault("invalid_response") }
        try deployment.verify()
        return try JSONDecoder().decode(OnboardingReply.self,from:raw)
    }
}
