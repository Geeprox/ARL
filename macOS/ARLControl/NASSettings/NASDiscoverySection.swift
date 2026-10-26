import SwiftUI

@MainActor struct NASDiscoverySection: View {
    @ObservedObject var discovery: NASDiscoveryModel
    @ObservedObject var setup: ARLNASSetupModel
    var body: some View {
        Section("网络中的设备") {
            HStack {
                if discovery.phase == .searching {
                    ProgressView().controlSize(.small)
                    Text("正在查找…").foregroundStyle(.secondary)
                } else if discovery.phase == .failed {
                    Text("最近查找未完成").foregroundStyle(.secondary)
                } else if let checked=discovery.checkedAt {
                    Text(checked,format:.dateTime.hour().minute()).foregroundStyle(.secondary)
                }
                Spacer()
                Button("重新查找",systemImage:"arrow.clockwise") {discovery.refresh()}
                    .disabled(setup.isPerforming || discovery.phase == .searching)
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
                            }.padding(.vertical,4).contentShape(Rectangle())
                        }.buttonStyle(.plain).help("使用此设备地址")
                        let alternatives=device.addresses.filter{$0.caseInsensitiveCompare(host) != .orderedSame}
                        if !alternatives.isEmpty {
                            DisclosureGroup("其他地址") {
                                ForEach(alternatives,id:\.self) { address in
                                    Button(address) {setup.selectDevice(device,address:address)}
                                }
                            }.font(.caption)
                        }
                    } else {
                        Text(device.name).fontWeight(.medium)
                        Text("地址尚未解析，可手动填写").font(.caption).foregroundStyle(.secondary)
                    }
                    if device.mounted {Text("已有挂载记录").font(.caption).foregroundStyle(.secondary)}
                    if !device.seenInCurrentScan,let seen=device.lastSeenAt {
                        HStack(spacing:4) {
                            Text("最近发现")
                            Text(seen,format:.dateTime.month().day().hour().minute())
                        }.font(.caption).foregroundStyle(.secondary)
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
