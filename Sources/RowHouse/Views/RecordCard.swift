import RowHouseCore
import SwiftUI

/// A compact, read-only rendering of one cell for cards.
struct CompactValueView: View {
    let session: BaseSession
    let record: RecordModel
    let field: FieldModel

    var body: some View {
        let document = session.document
        let value = document.value(record, field)
        switch value {
        case .choice(let c):
            ChoiceChip(name: c.name, color: c.color, compact: true)
        case .choices(let cs):
            FlowLayout(spacing: 3) { ForEach(cs) { ChoiceChip(name: $0.name, color: $0.color, compact: true) } }
        case .links(let refs):
            FlowLayout(spacing: 3) { ForEach(refs) { LinkChip(title: $0.title) } }
        case .attachments(let atts):
            HStack(spacing: 3) {
                ForEach(atts.prefix(4)) { att in
                    AttachmentThumbnail(url: session.storage.url(for: att), attachment: att, size: 28)
                        .frame(width: 28, height: 28)
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                }
            }
        case .bool(let b) where field.type == .checkbox:
            Image(systemName: b ? "checkmark.square.fill" : "square")
                .foregroundStyle(b ? .green : .secondary)
        case .number(let n) where field.type == .rating:
            HStack(spacing: 1) {
                ForEach(0..<Int(clampedRating(n, max: field.options.ratingMax ?? 5)), id: \.self) { _ in
                    Image(systemName: "star.fill").font(.system(size: 9)).foregroundStyle(Color(nsColor: Theme.star))
                }
            }
        case .list(let items) where field.type == .lookup:
            let target = document.field(field.options.targetFieldID)
            FlowLayout(spacing: 3) {
                ForEach(Array(items.prefix(6).enumerated()), id: \.offset) { _, item in
                    if case .choice(let c) = item {
                        ChoiceChip(name: c.name, color: c.color, compact: true)
                    } else {
                        Text(CellFormatter.string(item, field: target))
                            .font(.caption)
                            .padding(.horizontal, 5)
                            .background(RoundedRectangle(cornerRadius: 4).fill(Color(nsColor: Theme.lookupChipBackground)))
                    }
                }
            }
        case .error:
            Text("#ERROR!").font(.caption).foregroundStyle(.red)
        default:
            Text(document.displayString(record, field))
                .font(.caption)
                .lineLimit(2)
                .monospacedDigit()
        }
    }
}

struct RecordCard: View {
    let session: BaseSession
    let record: RecordModel
    let fields: [FieldModel]
    var coverFieldID: String?
    var coverHeight: CGFloat = 120
    var accent: ChoiceColor?

    var body: some View {
        let document = session.document
        VStack(alignment: .leading, spacing: 0) {
            if let coverFieldID, let coverField = document.field(coverFieldID) {
                cover(document.value(record, coverField))
            }
            VStack(alignment: .leading, spacing: 7) {
                Text(document.primaryTitle(record))
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(2)
                ForEach(fields) { field in
                    if !document.value(record, field).isEmpty {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(field.name.uppercased())
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(.tertiary)
                            CompactValueView(session: session, record: record, field: field)
                        }
                    }
                }
            }
            .padding(10)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .leading) {
            if let accent {
                Rectangle().fill(accent.swiftUI).frame(width: 3)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .cardStyle()
    }

    @ViewBuilder
    private func cover(_ value: CellValue) -> some View {
        if case .attachments(let atts) = value, let first = atts.first(where: \.isImage) ?? atts.first {
            AttachmentThumbnail(url: session.storage.url(for: first), attachment: first, size: 320)
                .frame(height: coverHeight)
                .frame(maxWidth: .infinity)
                .clipped()
        } else {
            Rectangle()
                .fill(Color.primary.opacity(0.04))
                .frame(height: coverHeight * 0.5)
                .overlay(Image(systemName: "photo").foregroundStyle(.quaternary))
        }
    }
}

extension BaseDocument {
    /// Fields shown on cards: the view's visible fields minus the primary and any excluded ones.
    func cardFields(for view: ViewModel, excluding: Set<String>, limit: Int = 5) -> [FieldModel] {
        let primary = primaryField(of: view.tableID)?.id
        return Array(visibleFields(for: view).filter { $0.id != primary && !excluding.contains($0.id) && $0.type != .button }.prefix(limit))
    }
}
