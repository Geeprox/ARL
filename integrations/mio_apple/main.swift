import Foundation
import Darwin
signal(SIGPIPE,SIG_IGN)
let args=CommandLine.arguments
// No policy, keys or user approval can arrive over the public MCP wire.
do {
    if args.count==2,args[1]=="--runtime-check" {
        // Sealed package metadata only. No account, socket, TCC or network.
        _ = try MioBundledRuntime.load()
        let tools=try MioReadCatalog.descriptors()
        try sendLine(jsonBytes(["status":"PASS","runtime_manifest_sha256":MioBundledRuntime.manifestSHA,"catalog_tools":tools.count,"network_requests":0,"credentials_read":false,"prompts_requested":false]),STDOUT_FILENO)
    } else if args.count==5,args[1]=="--prepare-session",args[3]=="--approved-policy-sha256" {
        MioStartupDiagnostics.context(role:"setup",phase:"setup")
        let s=try await prepareMioCalendarSession(policyPath:args[2],approvedSHA:args[4])
        try sendLine(jsonBytes(["schema_version":1,"target_alias":s.target.alias,"calendar_identifier":s.target.identifier,"expires_at_ms":s.expiry]),STDOUT_FILENO)
    } else if args.count==2,args[1]=="--authorize-session" {
        MioStartupDiagnostics.context(role:"authorize",phase:"authorize")
        try sendLine(jsonBytes(requestSession(home:NSHomeDirectory()+"/Library/Application Support/ARL/mio-apple")),STDOUT_FILENO)
    } else if args.count==2,args[1]=="--authorization-status" {
        try sendLine(jsonBytes(calendarAuthorizationStatus(home:NSHomeDirectory()+"/Library/Application Support/ARL/mio-apple")),STDOUT_FILENO)
    } else if args.count==5,args[1]=="--launch-client",args[3]=="--approved-policy-sha256" {
        MioStartupDiagnostics.context(role:"client",phase:"client_seal")
        try launchClient(policyPath:args[2],approvedSHA:args[4])
    } else if args.count==5,args[1]=="--host",args[3]=="--approved-policy-sha256" {
        MioStartupDiagnostics.context(role:"host",phase:"host_seal")
        try runHost(policyPath:args[2],approvedSHA:args[4])
    } else if args.count==5,args[1]=="--gateway",args[3]=="--host-pid",let pid=Int32(args[4]),pid>0 {
        MioStartupDiagnostics.context(role:"gateway",phase:"gateway")
        try runGateway(home:args[2],expectedHostPID:pid)
    } else if args.count==1,let seal=Bundle.main.object(forInfoDictionaryKey:"ARLApprovedPolicySHA256") as? String,seal.range(of:"^[a-f0-9]{64}$",options:.regularExpression) != nil {
        try sendLine(jsonBytes(requestSession(home:NSHomeDirectory()+"/Library/Application Support/ARL/mio-apple")),STDOUT_FILENO)
    } else {
        FileHandle.standardOutput.write(Data("{\"status\":\"disabled\",\"effects_started\":0}\n".utf8))
    }
} catch {
    MioStartupDiagnostics.failure(error);exit(1)
}
