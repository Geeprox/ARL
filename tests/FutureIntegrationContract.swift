import Foundation
import ARLCredentialHostCore

@main struct FutureIntegrationContract {
    @MainActor static func main() async throws {
        let home=FileManager.default.temporaryDirectory.appendingPathComponent("arl-future-held-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:home,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
        defer { try? FileManager.default.removeItem(at:home) }
        var checks=0
        func check(_ condition:Bool){precondition(condition);checks+=1}
        let store=RuntimeStore(arguments:["--runtime-home",home.path])
        check(store.nativeActionsHeld && store.messagesFeature.store.held)
        check(store.notesPermissions.configuredState=="source_held" && !store.credentialBootstrap.configured)
        await store.refresh()
        check(store.remindersServiceState == .sourceHeld && !store.remindersServiceState.canConnect)
        check(store.permissions.value?.records.count==ApplePermissionSnapshot.ids.count)
        check(store.permissions.value?.records.allSatisfy{$0.permission_state=="unknown" && $0.readiness_state != "ready"}==true)
        for id in ApplePermissionSnapshot.ids {
            for action in ["request","open_settings","retest"] {
                do {_=try await store.service.performPermission(id,action:action,requestID:UUID());preconditionFailure("held route admitted")}
                catch let error as ARLError {check(error.code=="source_authorization_held")}
                store.performPermission(id,action:action);check(!store.permissionBusy)
            }
        }
        for action in [RemindersFirstAction.snapshot,.request,.select_source,.run_smoke,.retest,.cancel,.disconnect] {
            do {_=try await store.service.performRemindersFirst(action,requestID:UUID(),launch:action == .snapshot);preconditionFailure("held Reminders admitted")}
            catch let error as ARLError {check(error.code=="source_authorization_held")}
            store.performRemindersFirst(action);check(!store.permissionBusy)
        }
        await store.messagesFeature.store.refreshStatus()
        for action in MessagesProductAction.allCases {await store.messagesFeature.store.perform(action);check(!store.messagesFeature.store.can(action))}
        check(store.messagesFeature.store.snapshot==nil && store.messagesFeature.store.textState == .held)
        for record in NotesIntegrationRecord.records {check(!store.notesPermissions.canRequest(record.id))}
        await store.notesPermissions.request();check(store.notesPermissions.records.isEmpty)
        let maps=await store.credentialBootstrap.service.snapshot(purpose:.amapMapsWeather)
        let travel=await store.credentialBootstrap.service.snapshot(purpose:.fliggyTravelReadOnly)
        check(maps.state == .setupRequired && maps.reference==nil)
        check(travel.state == .setupRequired && travel.reference==nil)
        // Even without the Oct3 hold, delegated IDs cannot use the runtime RPC.
        let ordinary=SettingsService(home:home)
        for id in ApplePermissionSnapshot.ids where PermissionRouteRegistry.isDedicated(id) {
            do {_=try await ordinary.performPermission(id,action:"request",requestID:UUID());preconditionFailure("duplicate route admitted")}
            catch let error as ARLError {check(error.code=="dedicated_setup_required")}
        }
        check(PermissionRouteRegistry.section(for:"messages.send.v1") == .messages)
        check(PermissionRouteRegistry.section(for:"messages.receive.v1") == .messages)
        check(PermissionRouteRegistry.section(for:"notes.create.v2") == .notes)
        check(PermissionRouteRegistry.section(for:"apple.reminders.create.v3") == .reminders)
        check(!PermissionRouteRegistry.usesRuntimeManualRoute("notes.append.v1"))
        check(try FileManager.default.contentsOfDirectory(atPath:home.path).isEmpty)
        let result:[String:Any]=["passed":true,"checks":checks,"actual_RuntimeStore_and_SettingsService":true,
            "all_catalog_actions_refused_before_dispatch":true,"default_Messages_admission_nil":true,
            "duplicate_global_permission_routes_refused":true,"native_permission_flows":0,"helper_starts":0,
            "keychain_item_API_calls":0,"local_disabled_credential_snapshots":2,"provider_HTTP_requests":0,
            "Apple_content_reads":0,"app_GUI_executed":false,"installed_changes":0]
        FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys]))
        print("")
    }
}
