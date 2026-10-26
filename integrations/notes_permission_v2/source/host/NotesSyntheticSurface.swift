#if NOTES_SYNTHETIC
import Foundation

final class NotesSyntheticStore {
    let plan: NotesFirstUsePlan
    var created = false
    let id = "x-coredata://AABBCCDD-0000-1111-2222-333344445555/ICNote/p101"
    init(plan: NotesFirstUsePlan) { self.plan = plan }
}
final class NotesSyntheticSurface: NotesFirstUseSurface {
    let store: NotesSyntheticStore
    var effectStarted = false
    init(store: NotesSyntheticStore) { self.store = store }
    func preflight(create: Bool) throws {} // no AEDeterminePermission/NativeNotes
    func emptyFolder() throws -> Bool { !store.created }
    func create(title: String, html: String, beforeEffect: () throws -> Void) throws -> String {
        try beforeEffect()
        guard !store.created, title == store.plan.title, html == store.plan.html else { throw NativeFault("proposal_mismatch") }
        effectStarted = true; store.created = true; return store.id
    }
    func snapshot(_ id: String) throws -> [String: Any] {
        guard store.created, id == store.id else { throw NativeFault("not_found") }
        let p = store.plan
        return ["id": id, "account_id": p.binding.account_id,"folder_id": p.binding.folder_id,"title": p.title,
            "html": p.html,"plaintext": p.title + "\n" + p.plaintext,"modified": "synthetic-local",
            "password_protected": false,"shared": false,"attachments": []]
    }
    func search(title: String) throws -> [String: Any] {
        let p = store.plan
        guard store.created, title == p.title else { throw NativeFault("proposal_mismatch") }
        return ["notes": [["id": store.id,"title": p.title,"account_id": p.binding.account_id,"folder_id": p.binding.folder_id,
            "modified": "synthetic-local","password_protected": false,"shared": false]],"scanned": 1,"scan_truncated": false,"unreadable": 0]
    }
}
#endif
