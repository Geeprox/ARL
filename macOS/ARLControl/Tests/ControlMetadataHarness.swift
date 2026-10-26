import Foundation
import SwiftUI

@main struct ControlMetadataHarness {
    @MainActor static func main() async {
        let args=CommandLine.arguments
        guard args.count>=3 else { return }
        let home=URL(fileURLWithPath:args[1],isDirectory:true), mode=args[2]
        let service=SettingsService(home:home)
        var output:[String:Any]=[:]
        let start=DispatchTime.now().uptimeNanoseconds
        do {
            if mode=="logs" {
                let page=try await service.readLogs(cursor:args.count>3 ? args[3] : nil)
                output=["ok":true,"count":page.entries.count,"more":page.hasMore,"cursor":page.nextCursor ?? "","truncated":page.truncated,"events":page.entries.map(\.event)]
            } else if mode=="export" {
                let e=try await service.exportLogs();output=["ok":true,"count":e.count,"bytes":e.content.count,"more":e.more,"truncated":e.truncated]
            } else if mode == "legacy-race" {
                let store=RuntimeStore(arguments:["harness","--runtime-home",home.path])
                await store.refresh()
                let fallback=store.legacyLogs
                store.resetLogs(level:"warning")
                func waitFor(_ name:String) async -> Bool {
                    let marker=home.appendingPathComponent(name).path
                    for _ in 0..<100 {
                        if FileManager.default.fileExists(atPath:marker) { return true }
                        try? await Task.sleep(nanoseconds:20_000_000)
                    }
                    return false
                }
                let oldStarted=await waitFor("warning-request-started")
                store.resetLogs(level:"error")
                await store.loadMoreLogs()
                let oldFinished=await waitFor("warning-request-finished")
                try? await Task.sleep(nanoseconds:200_000_000)
                let entries=store.control.logs.value?.entries ?? []
                output=["ok":fallback && oldStarted && oldFinished,
                        "legacy":fallback,"old_started":oldStarted,"old_finished":oldFinished,
                        "levels":entries.map(\.level),"log_error":store.logReadError ?? ""]
            } else if mode == "messages-scopes" {
                let records=ApplePermissionSnapshot.untested.records.filter { $0.id.hasPrefix("messages.") }
                let rows=ApplePermissionsView.scopeRows(records,at:Date())
                output=["ok":rows.count == records.count,"ids":rows.map(\.id),
                        "titles":rows.map(\.title),"kinds":rows.map(\.kind),
                        "permissions":rows.map(\.permission)]
            } else if mode == "disconnect" {
                let store=RuntimeStore(arguments:["harness","--runtime-home",home.path])
                await store.refresh()
                let wasConnected=store.connected
                try Data("ready\n".utf8).write(to:home.appendingPathComponent("disconnect-first-read"))
                var hostStopped=false
                for _ in 0..<100 {
                    if FileManager.default.fileExists(atPath:home.appendingPathComponent("disconnect-host-stopped").path) { hostStopped=true;break }
                    try? await Task.sleep(nanoseconds:20_000_000)
                }
                await store.refresh()
                store.performPermission("calendar.create.v1",action:"request")
                store.performRemindersFirst(.snapshot)
                output=["ok":wasConnected && hostStopped,"connected":store.connected,
                        "snapshot_present":store.snapshot != nil,"runtime_present":store.control.runtime.value != nil,
                        "overview_error":store.errorCode ?? "","permission_busy":store.permissionBusy,
                        "reminders_request_present":store.remindersRequestID != nil]
            } else if mode == "control-failure" {
                let store=RuntimeStore(arguments:["harness","--runtime-home",home.path])
                await store.refresh()
                store.performPermission("calendar.create.v1",action:"request")
                output=["connected":store.connected,"snapshot_present":store.snapshot != nil,
                        "title":store.title,"overview_error":store.errorCode ?? "",
                        "control_error":store.controlError ?? "","log_error":store.logReadError ?? "",
                        "permission_busy":store.permissionBusy]
            } else {
                let store=RuntimeStore(arguments:["harness","--runtime-home",home.path]);await store.refresh()
                output=["ok":store.snapshot != nil,"overview_error":store.errorCode ?? "","control_error":store.controlError ?? "", "has_v2":store.control.runtime.value != nil,"apps":store.control.registry.value?.count ?? 0,"providers":store.control.providerHealth.value?.map(\.state) ?? [],"logs":store.control.logs.value?.entries.count ?? 0,"reading":store.reading,"task_execution":store.control.runtime.value?.task_execution_enabled ?? false,"apple_apps":store.control.appleApps.value?.count ?? 0,"title":store.title]
                if let metrics=store.control.metrics.value {
                    output["metrics_available"]=true;output["system_cpu"]=metrics.cpuPercent ?? NSNull() as Any
                    output["process_cpu"]=metrics.processes.map {$0.cpu_percent ?? NSNull() as Any}
                } else { output["metrics_available"]=false }
                if mode=="more" { await store.loadMoreLogs();output["logs_after_more"]=store.control.logs.value?.entries.count ?? 0 }
            }
        } catch { output=["ok":false,"error":(error as? ARLError)?.code ?? "invalid_response"] }
        output["elapsed_ms"]=Double(DispatchTime.now().uptimeNanoseconds-start)/1_000_000
        if let data=try? JSONSerialization.data(withJSONObject:output,options:[.sortedKeys]) { print(String(decoding:data,as:UTF8.self)) }
    }
}
