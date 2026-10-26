import SwiftUI

extension ResourceSampleState {
    var pressureColor: Color {
        switch current?.pressure {
        case "警告": .orange
        case "严重": .red
        case "正常": .green
        default: .secondary
        }
    }
}
