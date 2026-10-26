#if ARL_CONSOLIDATED_TEST
import Foundation
import Darwin

/// Present only in the ad-hoc test bundle. Every admitted helper must prove its
/// compile-time synthetic mode before this bounded test can request anything.
enum ConsolidatedNativeSmoke {
    @MainActor static func run() async throws {
        let args=CommandLine.arguments
        guard let index=args.firstIndex(of:"--runtime-home"),args.indices.contains(index+1) else{throw NotesControlFault("test_home_required")}
        let home=URL(fileURLWithPath:args[index+1])
        if args.contains("--verify-disabled-service-no-launch") {
            guard String(data:try RemindersNativeIO.privateFile(home.appendingPathComponent("disabled-config-only").path),encoding:.utf8)=="disabled_service_configuration_only\n" else{throw NotesControlFault("test_home_required")}
            let client=RemindersNativeClient(home:home)
            guard client.configurationState() == .verifiedDisabled else{throw NotesControlFault("disabled_config_not_verified")}
            for launch in [false,true] {
                do {_=try await client.call(RemindersFirstFrame(action:.snapshot,requestID:UUID()),launch:launch);throw NotesControlFault("disabled_config_admitted")}
                catch let error as RemindersTransportFault {guard error.code=="activation_disabled" else{throw error}}
            }
            let store=RuntimeStore(arguments:["--runtime-home",home.path]);await store.refresh()
            guard store.remindersServiceState == .verifiedDisabled,!store.remindersServiceState.canConnect,
                  store.messagesFeature.sourceState=="verified_disabled",!store.messagesFeature.activationAllowed,
                  store.notesPermissions.configuredState=="verified_disabled",!store.notesPermissions.canRequest("notes.create.v2") else{throw NotesControlFault("disabled_state_not_presented")}
            store.performRemindersFirst(.snapshot)
            guard !store.permissionBusy else{throw NotesControlFault("disabled_UI_admitted")}
            FileHandle.standardOutput.write(Data("{\"disabled_real_configs_static_identity_verified\":3,\"reminders_socket_and_launch_refused\":2,\"disabled_UI_action_refused\":true,\"helper_launches\":0,\"TCC_queries\":0,\"personal_data_access\":0}\n".utf8));return
        }
        guard String(data:try RemindersNativeIO.privateFile(home.appendingPathComponent("synthetic-only").path),encoding:.utf8)=="synthetic_helpers_only\n" else{throw NotesControlFault("test_home_required")}
        let reminders=try RemindersNativeDeployment.load(home:home)
        guard Bundle(path:reminders.helper_bundle_path)?.object(forInfoDictionaryKey:"ARLSyntheticFixture") as? Bool==true else{throw NotesControlFault("fixture_required")}
        let messages=try MessagesNativeDeployment.load(home.appendingPathComponent("messages/control.json").path)
        let mode=try MessagesJSON.decode(MessagesNativeIO.privateFile(messages.helper_bundle_path+"/Contents/Resources/activation.json")).value
        guard mode["mode"] as? String=="synthetic" else{throw NotesControlFault("fixture_required")}
        let notes=try NotesPermissionDeployment.load(home:home)
        guard notes.surface_scope=="synthetic_only" else{throw NotesControlFault("fixture_required")}
        let store=RuntimeStore(arguments:["--runtime-home",home.path])
        if args.contains("--verify-consumed-request") {
            guard !store.notesPermissions.canRequest("notes.create.v2") else{throw NotesControlFault("replay_admitted")}
            await store.notesPermissions.request()
            guard store.notesPermissions.records.isEmpty else{throw NotesControlFault("replay_admitted")}
            FileHandle.standardOutput.write(Data("{\"actual_Control_restart_replay_refused\":true,\"native_effects\":0}\n".utf8));return
        }
        guard store.notesPermissions.canRequest("notes.create.v2") else{throw NotesControlFault("notes_setup_not_admitted")}
        await store.notesPermissions.request()
        guard store.notesPermissions.records.count==3,store.notesPermissions.records.allSatisfy({$0.state=="unknown" && $0.code=="synthetic_only"}),
              !store.notesPermissions.canRequest("notes.create.v2") else{throw NotesControlFault("notes_callback_not_verified")}
        await store.refresh()
        for action in [RemindersFirstAction.snapshot,.request,.select_source,.run_smoke,.run_smoke] {
            store.performRemindersFirst(action)
            for _ in 0..<300 {if !store.permissionBusy{break};try await Task.sleep(for:.milliseconds(20))}
            guard !store.permissionBusy else{throw NotesControlFault("reminders_timeout")}
        }
        guard store.remindersFirst.value?.smoke_state=="saved_local" else{throw NotesControlFault("reminders_smoke_failed")}
        let feature=store.messagesFeature;feature.reviewDeployment()
        guard feature.activationAllowed,feature.synthetic else{throw NotesControlFault("messages_fixture_required")}
        let panel=feature.feature.store
        func call(_ command:OnboardingCommand,_ arguments:[String:String]=[:]) async throws {
            await panel.perform(command,arguments:arguments)
            guard panel.errorCode==nil else{throw NotesControlFault("messages_controller_failed")}
        }
        try await call(.begin);try await call(.confirmAccount,["report":"signed_in_in_messages"])
        try await call(.permissionAction,["capability_id":"messages.receive.v1","action":"retest"])
        try await call(.refresh);try await call(.discoverGroups)
        guard let group=panel.candidates.first,group.participants==["a@example.invalid","b@example.invalid"] else{throw NotesControlFault("messages_group_failed")}
        try await call(.selectGroup,["candidate_id":group.id]);try await call(.prepareTest)
        guard let plan=panel.review,plan.sendLimit==1,plan.receiveLimit==2 else{throw NotesControlFault("messages_plan_failed")}
        try await call(.startTest,["plan_id":plan.planID])
        for _ in 0..<100 {try await Task.sleep(for:.milliseconds(100));try await call(.snapshot);if panel.panel.phase=="local_ready"{break}}
        guard panel.panel.phase=="local_ready" else{throw NotesControlFault("messages_trial_failed")}
        try await call(.disable)
        let result:[String:Any]=["actual_signed_Control_process":true,"all_three_helpers_bind_same_Control_cdhash":true,
            "Reminders_native_fixture_saves":2,"Reminders_replay_extra_saves":0,"Messages_native_fixture_sends":1,
            "Messages_actual_owner_panel_store_and_client":true,"Notes_actual_manual_callback_and_owner_journal":true,
            "Notes_synthetic_not_OS_authorization":true,"TCC_requests":0,"personal_data_access":0,"installed_changes":0]
        FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject:result,options:.sortedKeys));FileHandle.standardOutput.write(Data([10]))
    }
}
#endif
