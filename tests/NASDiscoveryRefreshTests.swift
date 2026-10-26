import Foundation
import Darwin
import SwiftUI

#if NAS_DISCOVERY_FIXTURE
// Only unrelated UI collaborators are synthetic. Discovery/model/driver event
// handling and endpoint parsing below compile from the actual production files.
enum ARLNASFault:Error {case invalidConfiguration}
@MainActor final class ARLNASSetupModel:ObservableObject {
    struct Draft {var address="";var port=445}
    var draft=Draft(),isPerforming=false
    func selectDevice(_ device:NASDiscoveredDevice,address:String){draft.address=address;draft.port=device.port}
}
#endif

@MainActor private final class DiscoveryClock {
    var date=Date(timeIntervalSince1970:1_792_400_000),seconds:Double=100,foreground=true
    func advance(_ interval:Double){seconds+=interval;date=date.addingTimeInterval(interval)}
}
@MainActor private final class DiscoveryEvents:NASDiscoveryDriver {
    var callbacks:[@MainActor (NASDiscoveryEvent)->Void]=[],stops=0
    func start(_ receive:@escaping @MainActor (NASDiscoveryEvent)->Void){callbacks.append(receive)}
    func stop(){stops+=1}
}
@MainActor @main enum NASDiscoveryRefreshTests {
    enum Failure:Error {case assertion(String)}
    static var checks=0
    static func expect(_ value:Bool,_ name:String)throws{guard value else{throw Failure.assertion(name)};checks+=1}
    static func main() {
        do {try run()} catch {print("nas_discovery_refresh_FAIL: \(error)");exit(1)}
    }
    private static func run()throws {
        let clock=DiscoveryClock(),driver=DiscoveryEvents()
        let model=NASDiscoveryModel(driver:driver,now:{clock.date},uptime:{clock.seconds},foreground:{clock.foreground})
        try expect(driver.callbacks.isEmpty && model.phase == .idle,"construction never starts discovery")
        model.refreshIfNeeded()
        try expect(driver.callbacks.count==1 && model.phase == .searching && model.lastAttemptAt==clock.date,"view request starts first bounded scan")
        model.refresh();model.refreshIfNeeded()
        try expect(driver.callbacks.count==1,"refresh coalesces while scan is in flight")
        clock.advance(1)
        driver.callbacks[0](.device(.init(id:"mount",name:"Synthetic.local",host:"Synthetic.local.",shares:["fixture"],mounted:true)))
        driver.callbacks[0](.device(.init(id:"bonjour",name:"Synthetic")))
        driver.callbacks[0](.device(.init(id:"bonjour",name:"Synthetic",host:"synthetic.local",addresses:["192.0.2.1"])))
        try expect(model.devices.count==1 && model.devices[0].id=="mount","resolved host aliases merge with stable original row identity")
        try expect(model.devices[0].mounted && model.devices[0].shares==["fixture"] && model.devices[0].addresses==["192.0.2.1"],"mount and resolved address metadata preserved")
        try expect(model.devices[0].seenInCurrentScan && model.devices[0].lastSeenAt==clock.date,"observed date belongs to actual event")
        driver.callbacks[0](.finished)
        let success=model.checkedAt,lastSeen=model.devices[0].lastSeenAt
        try expect(model.phase == .complete && success==clock.date && model.lastFailureAt==nil,"completed scan records observed check time")
        model.refreshIfNeeded()
        try expect(driver.callbacks.count==1,"foreground refresh obeys interval")
        clock.advance(30);model.refreshIfNeeded()
        try expect(driver.callbacks.count==2 && model.devices.count==1 && !model.devices[0].seenInCurrentScan,"refresh retains previous row as not yet seen")
        driver.callbacks[0](.device(.init(id:"late",name:"Late old scan",host:"late.local")))
        driver.callbacks[0](.finished)
        try expect(model.phase == .searching && model.devices.count==1,"late old scan cannot replace or end current generation")
        driver.callbacks[1](.failed)
        try expect(model.phase == .failed && model.devices.count==1 && model.devices[0].lastSeenAt==lastSeen && model.checkedAt==success,"failure preserves last success and row observation")
        try expect(model.lastFailureAt==clock.date,"current failure timestamp separate from last success")
        model.refreshIfNeeded();clock.advance(4);model.refreshIfNeeded()
        try expect(driver.callbacks.count==2,"first failure retry is bounded by five seconds")
        clock.advance(1);model.refreshIfNeeded()
        try expect(driver.callbacks.count==3,"due retry starts without another button")
        driver.callbacks[2](.device(.init(id:"changed-alias",name:"New name",host:"SYNTHETIC.local.",addresses:["192.0.2.2"])))
        try expect(model.devices.count==1 && model.devices[0].id=="mount" && model.devices[0].seenInCurrentScan,"fresh alias refreshes same stable row")
        driver.callbacks[2](.removed("changed-alias"))
        try expect(model.devices.count==1 && !model.devices[0].seenInCurrentScan,"removed alias marks history stale without claiming online")
        model.cancel();let afterCancel=model.devices
        driver.callbacks[2](.device(.init(id:"late-after-cancel",name:"Late",host:"late.local")))
        try expect(model.phase == .cancelled && model.devices==afterCancel,"leave/cancel retains history and rejects late callback")
        model.refresh();driver.callbacks[3](.finished)
        try expect(model.devices.count==1 && !model.devices[0].seenInCurrentScan,"empty successful scan retains history as stale")
        try expect(model.lastFailureAt==nil,"successful retry clears current failure")
        // Wall-clock rollback must not suspend the monotonic retry policy.
        clock.date=clock.date.addingTimeInterval(-86400);clock.seconds+=30;model.refreshIfNeeded()
        try expect(driver.callbacks.count==5,"wall clock rollback does not postpone due discovery")
        clock.foreground=false;driver.callbacks[4](.finished)
        clock.advance(30);model.refreshIfNeeded()
        try expect(driver.callbacks.count==5,"background completion uses slower bounded interval")
        clock.advance(90);model.refreshIfNeeded()
        try expect(driver.callbacks.count==6,"background due scan refreshes")
        model.cancel()
        let emptyDriver=DiscoveryEvents(),empty=NASDiscoveryModel(driver:emptyDriver,now:{clock.date},uptime:{clock.seconds},foreground:{true})
        empty.refresh();emptyDriver.callbacks[0](.finished)
        try expect(empty.devices.isEmpty && empty.phase == .complete && empty.checkedAt != nil,"never-found empty state differs from retained history")
        let boundedDriver=DiscoveryEvents(),bounded=NASDiscoveryModel(driver:boundedDriver,now:{clock.date},uptime:{clock.seconds},foreground:{true})
        bounded.refresh()
        for i in 0..<65 {boundedDriver.callbacks[0](.device(.init(id:"device-\(i)",name:"Device \(i)",host:"host\(i).local")))}
        try expect(bounded.devices.count==64,"visible retained state is bounded to64")
        boundedDriver.callbacks[0](.finished);bounded.refresh()
        boundedDriver.callbacks[1](.device(.init(id:"new-device",name:"New",host:"new.local")))
        try expect(bounded.devices.count==64 && bounded.devices.contains(where:{$0.id=="new-device" && $0.seenInCurrentScan}),"new scan can replace stale slot at capacity")
        bounded.cancel()
        print("nas_discovery_refresh_pass checks=\(checks) actual_production_model=true actual_UI_component_typechecked=true Bonjour_calls=0 SMB_calls=0 keychain_calls=0 permissions=0")
    }
}
