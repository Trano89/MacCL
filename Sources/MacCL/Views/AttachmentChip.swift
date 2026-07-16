import SwiftUI
import AppKit

/// A compact representation of an attachment. Shows a thumbnail for images,
/// otherwise an icon + filename. Pass `onRemove` to show a delete button.
struct AttachmentChip: View {
    @EnvironmentObject var settings: AppSettings
    let attachment: Attachment
    var onRemove: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 7) {
            thumbnail
            VStack(alignment: .leading, spacing: 1) {
                Text(attachment.filename)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(subtitle)
                    .foregroundStyle(.secondary)
            }
            if let onRemove {
                Button(action: onRemove) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help(L10n.t("remove"))
            }
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 8)
        .frame(maxWidth: 220)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.hairline))
    }

    @ViewBuilder private var thumbnail: some View {
        if attachment.kind == .image, let image = NSImage(contentsOf: attachment.url) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 30, height: 30)
                .clipShape(RoundedRectangle(cornerRadius: 6))
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(settings.accentColor.opacity(0.14))
                    .frame(width: 30, height: 30)
                Image(systemName: attachment.iconName)
                    .foregroundStyle(settings.accentColor)
            }
        }
    }

    private var subtitle: String {
        switch attachment.kind {
        case .image: return "\(L10n.t("image")) · \(attachment.sizeLabel)"
        case .text: return "\(L10n.t("text")) · \(attachment.sizeLabel)"
        case .other: return attachment.sizeLabel
        }
    }
}
