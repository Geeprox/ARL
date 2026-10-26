import Foundation

@MainActor final class CalendarPermissionFixture {
    var state: CalendarPermissionState = .notDetermined
    var requests=0
    var reads=0
    var foreground=true
    var admitted=true
    var failRequest=false
    var returnedGrant=true
    var afterRequest: CalendarPermissionState = .writeOnly
    var errorDomain=NSOSStatusErrorDomain
    func controller(enabled: Bool = true) -> CalendarPermissionController {
        .init(enabled:enabled,readStatus:{ self.reads+=1;return self.state },requestAccess:{
            self.requests+=1
            if self.failRequest { throw NSError(domain:self.errorDomain,code:-50) }
            self.state = self.afterRequest
            return self.returnedGrant
        },verifyOwner:{
            if !self.admitted { throw AppleDirectFault("owner_not_ready") }
        },foreground:{ self.foreground })
    }
}

@main enum CalendarPermissionTests {
    @MainActor static func main() async {
        let disabled=CalendarPermissionFixture(), closed=disabled.controller(enabled:false)
        closed.refresh();await closed.request()
        precondition(closed.state == .disabled && disabled.reads == 0 && disabled.requests == 0)
        let fixture=CalendarPermissionFixture(), controller=fixture.controller()
        controller.refresh()
        precondition(controller.state == .notDetermined && fixture.requests == 0)
        fixture.foreground=false;await controller.request();precondition(fixture.requests == 0)
        fixture.foreground=true;fixture.admitted=false;await controller.request()
        precondition(fixture.requests == 0 && controller.message == "应用身份未通过核验。")
        fixture.admitted=true
        // Permission can change between a status render and the click. Existing
        // grants and refusals only refresh; they never request again.
        for state in [CalendarPermissionState.denied,.restricted,.fullAccess,.writeOnly,.unknown] {
            fixture.state=state;await controller.request()
            precondition(controller.state == state && fixture.requests == 0)
        }
        fixture.state = .notDetermined;await controller.request()
        precondition(fixture.requests == 1 && controller.state == .writeOnly && !controller.busy)
        await controller.request();precondition(fixture.requests == 1)
        fixture.state = .notDetermined;fixture.failRequest=true;await controller.request()
        precondition(fixture.requests == 2 && controller.nativeStatus == -50 && !controller.busy)
        let noDecision = CalendarPermissionFixture()
        noDecision.returnedGrant=false; noDecision.afterRequest = .notDetermined
        let pending = noDecision.controller(); await pending.request()
        precondition(pending.state == .notDetermined && pending.requestGranted == false && pending.nativeStatus == nil)
        precondition(pending.message == "权限尚未决定，请查看详情。" && pending.requestDiagnostic == "completion=false · status=notDetermined")
        pending.refresh(); precondition(noDecision.requests == 1)
        let declined = CalendarPermissionFixture(); declined.returnedGrant=false; declined.afterRequest = .denied
        let refused = declined.controller(); await refused.request()
        precondition(refused.state == .denied && refused.message != pending.message)
        let inconsistent = CalendarPermissionFixture(); inconsistent.afterRequest = .notDetermined
        let delayed = inconsistent.controller(); await delayed.request()
        precondition(delayed.state == .notDetermined && delayed.requestGranted == true && delayed.message == pending.message)
        let unknownError = CalendarPermissionFixture(); unknownError.failRequest=true; unknownError.errorDomain="synthetic-private-domain"
        let sanitized = unknownError.controller(); await sanitized.request()
        precondition(sanitized.requestErrorDomain == "other" && sanitized.nativeStatus == -50 &&
                     sanitized.requestDiagnostic?.contains("synthetic-private") == false)
        let approved: [String: Any] = ["com.apple.security.automation.apple-events":true,
                                       "com.apple.security.personal-information.calendars":true]
        precondition(AppleDirectAuthority.validEntitlements(approved))
        for values: [String: Any] in [
            ["com.apple.security.automation.apple-events":true],
            ["com.apple.security.automation.apple-events":true,"com.apple.security.personal-information.calendars":1],
            ["com.apple.security.automation.apple-events":true,"com.apple.security.personal-information.calendars":false],
            approved.merging(["com.apple.security.cs.disable-library-validation":true]) { $1 }
        ] { precondition(!AppleDirectAuthority.validEntitlements(values)) }
        print("PASS main Calendar permission routing: status-only refresh; disabled/background/identity gates; stale grant avoids request; false completion with unchanged state is not a user refusal; typed exact Calendar entitlement; finite failure; no real TCC/data calls")
    }
}
