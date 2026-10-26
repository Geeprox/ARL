import Foundation

// Host-controlled, hash-pinned native caller. Caller-supplied JSON cannot register itself.
func runReviewedClient(isolated:Bool) -> Never {
    FileHandle.standardOutput.write(Data("prepared\n".utf8))
    #if CALENDAR_EFFECT_FIXTURE
    let fixtureBuild=true
    #else
    let fixtureBuild=false
    #endif
    let raw=FileHandle.standardInput.readData(ofLength:8193)
    guard raw.count<=8192,let obj=(try? JSONSerialization.jsonObject(with:raw)) as? [String:Any],
          Set(obj.keys)==Set(["home","args"]),let home=obj["home"] as? String,
          let args=obj["args"] as? [String:Any],
          fixtureBuild || isolated || home==NSHomeDirectory()+"/Library/Application Support/ARL/calendar-once",
          let data=try? JSONSerialization.data(withJSONObject:args),
          let json=try? JSONDecoder().decode(ARLJSON.self,from:data),case .object(let arguments)=json,
          let operation=arguments["operation_id"]?.text else {emit(["status":"invalid_bootstrap"])}
    let client=ARLClient(home:URL(fileURLWithPath:home),app:"calendar_review")
    Task {
        do {
            _=try await client.rpc("ready",timeout:2)
            let submitted=try await client.rpc("submit",params:["tool":.string("apple.calendar.create.v1"),"args":.object(arguments),"key":.string(operation)])
            guard let id=submitted["id"]?.text else {throw ARLError(code:"invalid_response")}
            let deadline=DispatchTime.now().uptimeNanoseconds+15_000_000_000
            while DispatchTime.now().uptimeNanoseconds<deadline {
                let receipt=try await client.rpc("get",params:["id":.string(id)],timeout:2)
                if let state=receipt["state"]?.text,["succeeded","failed","cancelled","needs_review"].contains(state) {
                    let encoded=try JSONEncoder().encode(receipt)
                    FileHandle.standardOutput.write(encoded);FileHandle.standardOutput.write(Data([10]));exit(0)
                }
                try await Task.sleep(nanoseconds:50_000_000)
            }
            throw ARLError(code:"review_deadline_exceeded")
        } catch {
            let allowed:Set<String>=["app_identity_unverified","review_not_authorized","review_expired","operation_key_mismatch","needs_permission","call_budget_exceeded","idempotency_conflict"]
            let code=(error as? ARLError)?.code ?? "client_unavailable"
            emit(["status":"error","code":allowed.contains(code) ? code:"client_unavailable"])
        }
    }
    RunLoop.main.run();exit(1)
}
