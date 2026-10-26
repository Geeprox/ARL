import Foundation

@MainActor final class CalendarBusinessPermissionFixture {
    var state=CalendarPermissionState.writeOnly
    var writeRequests=0, fullRequests=0
    var foreground=true, admitted=true
}
@main enum CalendarBusinessPermissionTests {
    @MainActor static func main() async {
        let suite="arl-calendar-permission-test-"+UUID().uuidString
        let preferences=UserDefaults(suiteName:suite)!
        defer { preferences.removePersistentDomain(forName:suite) }
        let f=CalendarBusinessPermissionFixture()
        let p=CalendarPermissionController(enabled:true,readStatus:{f.state},requestAccess:{f.writeRequests += 1;return true},
            verifyOwner:{ if !f.admitted { throw AppleDirectFault("owner_not_ready") } },foreground:{f.foreground},
            preferences:preferences,startAutomatically:false,requestReadWrite:{f.fullRequests += 1;f.state = .fullAccess;return true},verifyReadWriteUsage:{})
        p.refresh();await p.request()
        precondition(p.state == .writeOnly && f.writeRequests == 0 && f.fullRequests == 0)
        f.state = .unknown;p.refresh()
        precondition(p.state == .writeOnly && p.lastProbeFailed && p.lastKnownState == .writeOnly)
        let restored=CalendarPermissionController(enabled:true,readStatus:{.unknown},requestAccess:{preconditionFailure()},verifyOwner:{},
            foreground:{false},preferences:preferences,startAutomatically:false,requestReadWrite:{preconditionFailure()},verifyReadWriteUsage:{})
        precondition(restored.state == .writeOnly && restored.lastProbeFailed && restored.observedAt != nil)
        f.state = .writeOnly;f.foreground=false;await p.requestFullAccess();precondition(f.fullRequests == 0)
        f.foreground=true;f.admitted=false;await p.requestFullAccess();precondition(f.fullRequests == 0)
        f.admitted=true;await p.requestFullAccess();precondition(f.fullRequests == 1 && p.state == .fullAccess)
        await p.requestFullAccess();p.refresh();precondition(f.fullRequests == 1)
        f.state = .denied;await p.requestFullAccess();precondition(f.fullRequests == 1 && p.state == .denied)
        f.state = .writeOnly;p.refresh();p.suspendForExit();await p.requestFullAccess();precondition(f.fullRequests == 1)
        let unavailable=CalendarPermissionController(enabled:true,readStatus:{.writeOnly},requestAccess:{preconditionFailure()},verifyOwner:{},
            foreground:{true},preferences:preferences,startAutomatically:false,requestReadWrite:{preconditionFailure()},
            verifyReadWriteUsage:{throw AppleDirectFault("owner_not_ready")})
        await unavailable.requestFullAccess();precondition(unavailable.state == .writeOnly && unavailable.message == "应用身份未通过核验。")
        print("PASS Calendar permission: no startup/refresh upgrade, write-only remains distinct, explicit foreground-only upgrade, identity/usage/exit gates, stable cached observation. No real TCC calls.")
    }
}
