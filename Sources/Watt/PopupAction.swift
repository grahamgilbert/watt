import SwiftUI

struct PopupAction:View {
    let title:String
    let symbol:String
    let action:()->Void
    var body:some View {
        Button(action:action) {
            HStack(spacing:5) {
                Image(systemName:symbol).allowsHitTesting(false)
                Text(title).allowsHitTesting(false)
            }.font(.system(size:11,weight:.medium))
                .frame(maxWidth:.infinity,minHeight:30)
                .contentShape(Rectangle())
        }.buttonStyle(.plain).foregroundStyle(.secondary)
    }
}
