// TEST ONLY. Never linked into the production app.
import Foundation
import Darwin
final class HostFixtureEffects:AppleEffects {
    let home:String;init(_ home:String){self.home=home}
    func authorization(_ operation:AppleOperation)->String{"write_only"}
    func lockState()->String{"unlocked"}
    func resolve(_ binding:TargetBinding)throws->ResolvedTarget{ResolvedTarget(identifier:binding.identifier,name:"Synthetic calendar")}
    func save(_ proposal:AppleProposal,target:ResolvedTarget)throws->String{
        try writePrivateNew(home+"/saved_"+proposal.operationID,Data("injected_only".utf8));return "saved_local"
    }
}
func fixtureHost(policy:String,sha:String)throws {
    let a=try sealedActivation(policy,sha)
    let deps=HostDependencies(launch:{a,path,sha in
        let p=Process();p.executableURL=Bundle.main.executableURL;p.arguments=["--fixture-client",path,sha]
        p.environment=["PATH":"/usr/bin:/bin"];p.standardInput=FileHandle.nullDevice;p.standardOutput=FileHandle.nullDevice;p.standardError=FileHandle.nullDevice
        try p.run();return p
    },legacyCall:{req in
        let tools=Array(try MioReadCatalog.descriptors().prefix(14))
        return ["jsonrpc":"2.0","id":req["id"] ?? NSNull(),"result":["tools":tools]]
    },effects:{HostFixtureEffects(a.home)},session:controlledSetup)
    try runHost(policyPath:policy,approvedSHA:sha,dependencies:deps)
}
func fixtureClient(policy:String,sha:String)throws {
    let a=try sealedActivation(policy,sha);let host=getppid()
    try establishControlledClientGroup()
    signal(SIGTERM,SIG_IGN) // prove bounded host escalation, not polite exit
    try writePrivateNew(a.healthURLFile,Data("http://127.0.0.1:1\n".utf8))
    var index=0;var offset=0
    while true {
        let input=Pipe();let out=a.home+"/responses.jsonl"
        let fd=open(out,O_WRONLY|O_CREAT|O_APPEND,0o600);guard fd>=0 else{throw ReviewFault("fixture_failed")}
        let p=Process();p.executableURL=Bundle.main.executableURL;p.arguments=["--gateway",a.home,"--host-pid",String(host)]
        p.standardInput=input;p.standardOutput=FileHandle(fileDescriptor:fd,closeOnDealloc:true);p.standardError=FileHandle.nullDevice;try p.run()
        try writePrivateNew(a.home+"/gateway_"+String(index),Data(String(p.processIdentifier).utf8));index+=1
        while p.isRunning {
            if let text=try? String(contentsOfFile:a.home+"/requests.jsonl",encoding:.utf8) {
                let lines=text.split(separator:"\n")
                while offset<lines.count {
                    let line=String(lines[offset]);offset+=1
                    if line=="RECONNECT"{try input.fileHandleForWriting.close();break}
                    try sendLine(Data(line.utf8),input.fileHandleForWriting.fileDescriptor)
                }
            }
            usleep(10000)
        }
        p.waitUntilExit();try? input.fileHandleForWriting.close()
        // Keep health/client alive across ordinary gateway connection expiry.
    }
}
