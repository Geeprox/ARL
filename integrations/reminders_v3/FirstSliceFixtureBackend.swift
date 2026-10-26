// This file is compiled only into the isolated signed test app, never shipping.
#if REMINDERS_FIRST_SLICE_FIXTURE
import Foundation
import ARLRemindersCore
final class RemindersFirstFixtureBackend: RemindersSourceAccess, @unchecked Sendable {
    let repository=FixtureRepository()
    let home:String
    private let lock=NSLock()
    private var authorized=false
    private var saves=0
    private var metadataReads=0
    private struct State:Codable {let authorized:Bool;let saves:Int;let metadata_reads:Int;let lists:[ReminderList];let reminders:[ReminderSnapshot]}
    init(home:String)throws {
        self.home=home
        if FileManager.default.fileExists(atPath:home+"/fixture.json"){
            let state=try JSONDecoder().decode(State.self,from:RemindersNativeIO.privateFile(home+"/fixture.json"));authorized=state.authorized;saves=state.saves;metadataReads=state.metadata_reads;repository.listItems=state.lists;repository.reminderItems=state.reminders
        }
        repository.persist={ [weak self] in guard let self else{return};self.lock.lock();defer{self.lock.unlock()};self.saves+=1;try self.persist()}
    }
    private func persist()throws {
        let state=State(authorized:authorized,saves:saves,metadata_reads:metadataReads,lists:repository.listItems,reminders:repository.reminderItems)
        try RemindersNativeIO.atomicWrite(try JSONEncoder().encode(state),to:home+"/fixture.json")
    }
    func authorization()->String{lock.lock();defer{lock.unlock()};return authorized ? "full_access":"not_determined"}
    func authorize(){lock.lock();defer{lock.unlock()};authorized=true;try? persist()}
    func defaultSource()throws->RemindersSelectedSource {
        lock.lock();defer{lock.unlock()};guard authorized else{throw AdapterFault("needs_permission")};metadataReads+=1;try persist()
        return .init(id:"fixture-source",title:"Synthetic local",type:0,default_list_id:"fixture-list",default_list_title:"Synthetic list")
    }
    func verify(_ source:RemindersSelectedSource)throws{guard authorization()=="full_access",source.id=="fixture-source",source.title=="Synthetic local",source.type==0 else{throw AdapterFault("target_changed")}}
}
#endif
