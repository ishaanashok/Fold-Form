import SwiftUI

struct StatsHeader: View {
    let stats: DashboardStats

    var body: some View {
        HStack(spacing: 10) {
            tile("Designs", stats.designs, "square.stack.3d.up.fill", .blue)
            tile("Parts", stats.parts, "cube.fill", .indigo)
            tile("Favourites", stats.favourites, "star.fill", .orange)
            tile("This week", stats.editedThisWeek, "clock.fill", .green)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("statsHeader")
    }

    private func tile(_ title: String, _ value: Int, _ symbol: String, _ tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: symbol).font(.system(size: 13, weight: .semibold)).foregroundStyle(tint)
            Text("\(value)").font(.system(.title2, design: .rounded, weight: .bold)).monospacedDigit()
            Text(title).font(.caption2.weight(.medium)).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}
