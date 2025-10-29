import Foundation
import SwiftUI
import WidgetKit

struct LiveActivityBGLabelLargeView: View {
    var context: ActivityViewContext<LiveActivityAttributes>
    var glucoseColor: Color
    var smallerFont: Bool = false

    var body: some View {
        HStack(alignment: .center) {
            if let trendArrow = context.state.direction {
                Text(context.state.bg)
                    .fontWeight(.bold)
                    .font(!smallerFont ? .title : .title3)
                    .foregroundStyle(context.isStale ? .secondary : glucoseColor)
                    .strikethrough(context.isStale, pattern: .solid, color: .red.opacity(0.6))

                Text(trendArrow)
                    .foregroundStyle(context.isStale ? .secondary : glucoseColor)
                    .fontWeight(.bold)
                    .font(!smallerFont ? .headline : .subheadline)
            } else {
                Text(context.state.bg)
                    .fontWeight(.bold)
                    .font(!smallerFont ? .title : .title3)
                    .foregroundStyle(context.isStale ? .secondary : glucoseColor)
                    .strikethrough(context.isStale, pattern: .solid, color: .red.opacity(0.6))
            }
        }
    }
}
