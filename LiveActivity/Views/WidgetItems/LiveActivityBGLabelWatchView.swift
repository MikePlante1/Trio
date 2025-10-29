import SwiftUI
import WidgetKit

struct LiveActivityBGLabelWatchView: View {
    var context: ActivityViewContext<LiveActivityAttributes>
    var glucoseColor: Color

    private var dateFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }

    var body: some View {
        HStack {
            Text(context.state.bg)
                .fontWeight(.bold)
                .font(.callout)
                .foregroundStyle(context.isStale ? .secondary : glucoseColor)
                .strikethrough(context.isStale, pattern: .solid, color: .red.opacity(0.6))

            if let trendArrow = context.state.direction {
                Text(trendArrow)
                    .fontWeight(.bold)
                    .font(.callout)
                    .foregroundStyle(context.isStale ? .secondary : glucoseColor)
                    .strikethrough(context.isStale, pattern: .solid, color: .red.opacity(0.6))
            }

            Text(context.state.change)
                .font(.callout)
                .foregroundStyle(.primary)
                .strikethrough(context.isStale, pattern: .solid, color: .red.opacity(0.6))

            Spacer()

            Text("\((context.state.date != nil) ? dateFormatter.string(from: context.state.date!) : "--")")
                .font(.callout)
                .bold()
                .foregroundStyle(context.isStale ? .red.opacity(0.6) : .secondary)
                .strikethrough(context.isStale, pattern: .solid, color: .red.opacity(0.6))
        }
    }
}
