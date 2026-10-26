import Foundation
@main enum NotesIdentityInspector {
    static func main() throws {
        if CommandLine.arguments.count == 3 && CommandLine.arguments[1] == "--configuration" {
            let value = try NotesV2ObservedIdentity.inspectConfiguration(URL(fileURLWithPath: CommandLine.arguments[2]))
            FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])); return
        }
        let identity = try NotesV2ObservedIdentity.inspect(URL(fileURLWithPath: CommandLine.arguments[1]))
        var value = identity.object; value["requirement"] = identity.requirement
        FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]))
    }
}
