import Foundation

// Type-only fixture for metadata declarations unused by this page-state test.
enum AppleDirectStep {case notesAccountName,notesFolderName}
enum AppleDirectValueIssue {case tooLong}
struct AppleDirectFault:Error {
    let code:String
    init(_ code:String,step:AppleDirectStep?=nil,valueIssue:AppleDirectValueIssue?=nil){self.code=code}
}

@main struct NotesPageLifecycleTests {
    static func main()throws {
        var page=NotesDirectPageState(),checks=0
        func expect(_ value:Bool,_ label:String){precondition(value,label);checks+=1}
        let old=page.appear(),oldTicket=page.ticket(folder:nil)!
        let current=page.appear(),currentTicket=page.ticket(folder:nil)!
        expect(!page.disappear(appearance:old),"late old view disappearance cannot hide current view")
        try page.validate(currentTicket,currentFolder:nil)
        expect(page.visible,"new view stays visible")
        do{try page.validate(oldTicket,currentFolder:nil);preconditionFailure("old ticket survived")}catch let error as AppleDirectFault{expect(error.code=="user_action_expired","old view ticket rejected")}
        page.cancel()
        do{try page.validate(currentTicket,currentFolder:nil);preconditionFailure("cancelled ticket survived")}catch let error as AppleDirectFault{expect(error.code=="user_action_expired","cancel still invalidates current request")}
        expect(page.disappear(appearance:current),"current lease may disappear after cancel")
        expect(!page.visible && page.ticket(folder:nil)==nil,"hidden view cannot issue a ticket")
        print("PASS \(checks) Notes appearance-lease checks")
    }
}
