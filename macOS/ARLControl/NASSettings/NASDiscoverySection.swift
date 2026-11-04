import SwiftUI

@MainActor struct NASDiscoverySection: View {
    @ObservedObject var discovery: NASDiscoveryModel
    @ObservedObject var setup: ARLNASSetupModel
    var body: some View {
        VStack(alignment:.leading,spacing:8) {
            HStack {
                if discovery.phase == .searching {
                    ProgressView().controlSize(.small)
                    Text("正在查找…").foregroundStyle(.secondary)
                } else if discovery.phase == .failed {
                    Text("未能完成查找").foregroundStyle(.secondary)
                } else if !discovery.devices.isEmpty {
                    Text("已发现 \(discovery.devices.count) 台设备").foregroundStyle(.secondary)
                }
                Spacer()
                if discovery.phase == .failed || discovery.devices.isEmpty && discovery.phase == .complete {
                    Button("重试",systemImage:"arrow.clockwise") {discovery.refresh()}
                        .disabled(setup.isPerforming)
                }
            }.font(.caption)
            ForEach(discovery.devices) { device in
                VStack(alignment:.leading,spacing:4) {
                    if let host=device.host {
                        Button {setup.selectDevice(device,address:host)} label: {
                            HStack {
                                VStack(alignment:.leading,spacing:3) {
                                    Text(device.name).fontWeight(.medium)
                                    Text(host+":"+String(device.port)).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if selected(device) {Image(systemName:"checkmark").foregroundStyle(.secondary)}
                            }.padding(12).contentShape(Rectangle())
                                .background(selected(device) ? EditorialStyle.accent.opacity(0.055):Color.primary.opacity(0.025),in:RoundedRectangle(cornerRadius:8))
                                .overlay {RoundedRectangle(cornerRadius:8).strokeBorder(selected(device) ? EditorialStyle.accent.opacity(0.4):EditorialStyle.rule,lineWidth:0.5).allowsHitTesting(false)}
                        }.buttonStyle(.plain).help("使用此设备地址")
                    } else {
                        Text(device.name).fontWeight(.medium)
                        Text("地址尚未解析，可手动填写").font(.caption).foregroundStyle(.secondary)
                    }
                }.disabled(setup.isPerforming)
            }
            if discovery.devices.isEmpty,discovery.phase == .complete {
                Text("未发现设备，也可在下方填写地址").foregroundStyle(.secondary)
            } else if discovery.phase == .failed {
                Text("已保留最近发现的设备，可稍后再查找").font(.caption).foregroundStyle(.secondary)
            }
        }
        .task {
            while !Task.isCancelled {
                if !setup.isPerforming {discovery.refreshIfNeeded()}
                do {try await Task.sleep(for:.seconds(5))} catch {return}
            }
        }
        .onDisappear {discovery.cancel()}
    }
    private func selected(_ device:NASDiscoveredDevice) -> Bool {
        guard let host=device.host,let input=try? NASAddressInput(setup.draft.address,port:setup.draft.port) else{return false}
        let trim=CharacterSet(charactersIn:".")
        return input.host.lowercased().trimmingCharacters(in:trim)==host.lowercased().trimmingCharacters(in:trim) && input.port==device.port
    }
}
