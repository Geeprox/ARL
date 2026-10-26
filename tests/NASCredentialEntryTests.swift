import AppKit
import SwiftUI

private enum CheckFailure: Error { case failed(String) }
@MainActor private func check(_ condition: Bool, _ label: String) throws {
    if !condition { throw CheckFailure.failed(label) }
}

// No native owner, persistence, discovery action, credential service or network is used.
@MainActor private final class EntryBackend: ARLNASSetupBackend, ARLNASCredentialConsumer {
    var configuration: ARLNASConfiguration?
    var revision: UInt64 = 0
    var effects = 0
    func cachedSnapshot() -> ARLNASSetupSnapshot {
        .init(revision: revision, provider: .available,
              availability: .init(saveConfiguration: .allowed,
                  saveCredential: configuration == nil ? .held(.configurationNotSaved) : .allowed,
                  testConnection: .held(.credentialNotSaved), testRead: .held(.credentialNotSaved),
                  reconnect: .held(.credentialNotSaved)), configuration: configuration,
              currentConfigurationGeneration: configuration == nil ? 0 : 1,
              configurationSaved: configuration == nil ? .unknown : .verified)
    }
    func perform(_ request: ARLNASActionRequest, manualIntent: ARLNASManualIntent) async -> ARLNASActionReply {
        effects += 1
        return .init(request: request, outcome: .held(.disabled), snapshot: cachedSnapshot())
    }
    func save(_ input: ARLNASCredentialInput, request: ARLNASActionRequest,
              manualIntent: ARLNASManualIntent) async -> ARLNASActionReply {
        effects += 1
        return .init(request: request, outcome: .held(.disabled), snapshot: cachedSnapshot())
    }
}

@main enum NASCredentialEntryTests {
    @MainActor static func main() {
        do {
            let app = NSApplication.shared
            app.setActivationPolicy(.prohibited)
            app.finishLaunching()
            let backend = EntryBackend()
            let model = ARLNASSetupModel(backend: backend, credentialConsumer: backend)
            let device = NASDiscoveredDevice(id: "fixture", name: "Fixture", host: "synthetic.invalid")
            model.selectDevice(device, address: "synthetic.invalid")
            try check(model.canEditCredentialFields, "unconfigured_target_allows_local_editing")
            try check(model.credentialSaveGuidance?.contains("共享目录") == true, "missing_share_next_step")
            try check(model.beginManualActionAfterClick(.saveCredential) == nil, "missing_share_cannot_submit")
            let host = NSHostingView(rootView: ARLNASSettingsSection(model: model))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 2400),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = host
            window.orderFront(nil) // Realize the synthetic controls; never activate the production app.
            func settle() {
                for _ in 0..<5 {
                    host.layoutSubtreeIfNeeded()
                    RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.02))
                }
            }
            func fields(_ view: NSView) -> [NSTextField] {
                (view as? NSTextField).map { [$0] } ?? view.subviews.flatMap { fields($0) }
            }
            func field(_ placeholder: String) throws -> NSTextField {
                let native = fields(host)
                let identifier = placeholder == "账号" ? "nas-account" : "nas-password"
                if let result = native.first(where: {
                    $0.accessibilityIdentifier() == identifier || $0.identifier?.rawValue == identifier
                }) { return result }
                // SwiftUI keeps labels/identifiers on AX proxy nodes on this macOS.
                // The production form has one secure field and its account field immediately before it.
                let secure = native.indices.filter { native[$0] is NSSecureTextField }
                guard secure.count == 1, let index = secure.first else {
                    throw CheckFailure.failed("production_view_unique_secure_field_missing")
                }
                if placeholder == "密码" { return native[index] }
                guard let account = native[..<index].last(where: { $0.isEditable && !($0 is NSSecureTextField) }) else {
                    throw CheckFailure.failed("production_view_account_field_missing")
                }
                return account
            }
            func enter(_ name: String, _ value: String) throws {
                let input = try field(name)
                input.stringValue = value
                input.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: input))
            }
            settle()
            try check(try field("账号").isEnabled && field("密码").isEnabled, "real_view_fields_enabled_before_configuration_saved")
            try enter("账号", "fixture-account"); try enter("密码", "synthetic-only")
            backend.revision += 1; model.refreshCachedStatus(); settle()
            try check(try field("账号").stringValue == "fixture-account" && field("密码").stringValue == "synthetic-only", "refresh_preserves_inputs")
            host.rootView = ARLNASSettingsSection(model: model); settle()
            try check(try field("账号").stringValue == "fixture-account" && field("密码").stringValue == "synthetic-only", "parent_rerender_preserves_inputs")
            model.draft.share = "fixture-share"; settle()
            try check(try field("账号").stringValue.isEmpty && field("密码").stringValue.isEmpty, "target_scope_change_clears_inputs")
            try check(model.canEditCredentialFields && !model.admission(for: .saveCredential).isAllowed,
                      "valid_unsaved_target_editable_not_submittable")
            try check(model.credentialSaveGuidance?.contains("先点击上方") == true, "unsaved_configuration_next_step")
            try enter("账号", "fixture-account"); try enter("密码", "synthetic-only")
            backend.configuration = try model.draft.validated().get(); backend.revision += 1
            model.refreshCachedStatus(); settle()
            try check(model.admission(for: .saveCredential).isAllowed && model.credentialSaveGuidance == nil,
                      "exact_saved_target_allows_submission")
            try check(try field("账号").stringValue == "fixture-account" && field("密码").stringValue == "synthetic-only", "saving_same_target_preserves_inputs")
            model.selectDevice(.init(id: "other", name: "Other", host: "other.invalid"), address: "other.invalid"); settle()
            try check(try field("账号").stringValue.isEmpty && field("密码").stringValue.isEmpty, "device_change_clears_inputs")
            model.draft.share = "fixture-share"; settle()
            try check(model.beginManualActionAfterClick(.saveCredential) == nil, "different_target_cannot_submit_to_saved_target")
            try check(!ARLNASSetupModel().canEditCredentialFields, "unavailable_consumer_blocks_input")
            try check(backend.effects == 0, "no_save_network_or_credential_effects")
            window.orderOut(nil)
            window.contentView = nil
            print("{\"status\":\"PASS\",\"groups\":[\"editable_before_save_but_submission_guarded\",\"real_view_unconfigured_expansion_and_enabled_fields\",\"refresh_rerender_same_target_save_preserve_inputs\",\"target_change_clears_and_prevents_wrong_target_submit\"],\"real_swiftui_view\":true,\"real_credentials\":false,\"network\":false,\"persistence\":false}")
        } catch { print("NAS_CREDENTIAL_ENTRY_FAILED: \(error)"); exit(1) }
    }
}
