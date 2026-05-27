import SwiftUI

struct BreadcrumbView: View {
    var store: OutlineStore

    var body: some View {
        HStack(spacing: 5) {
            ForEach(Array(store.breadcrumbs.enumerated()), id: \.element.id) { index, crumb in
                if index > 0 {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.quaternary)
                }

                let isLast = index == store.breadcrumbs.count - 1

                Button {
                    store.zoomTo(nodeId: crumb.id)
                } label: {
                    Text(crumb.text)
                        .font(.system(size: 12, weight: isLast ? .medium : .regular))
                        .foregroundStyle(isLast ? .secondary : .tertiary)
                        .lineLimit(1)
                        .frame(maxWidth: 200, alignment: .leading)
                }
                .buttonStyle(.plain)
            }

            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .background(.bar)
    }
}
