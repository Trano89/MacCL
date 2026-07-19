import SwiftUI

struct MessageRow: View, Equatable {
    let item: ChatItem
    /// Called with the Task toolUseId when the user clicks a sub-agent link.
    /// Excluded from Equatable on purpose — identity of the closure never
    /// changes what the row displays.
    var onOpenAgent: ((String) -> Void)? = nil

    static func == (lhs: MessageRow, rhs: MessageRow) -> Bool { lhs.item == rhs.item }

    var body: some View {
        switch item.kind {
        case .user(let text, let attachments):
            UserBubble(text: text, attachments: attachments)
        case .assistantText(let text):
            AssistantText(text: text)
        case .thinking(let text):
            ThinkingBlock(text: text)
        case .tool(let activity):
            ToolCallView(activity: activity, onOpenAgent: onOpenAgent)
        case .result(let info):
            ResultFooter(info: info)
        case .notice(let notice):
            NoticeBanner(notice: notice)
        }
    }
}

// MARK: - User

private struct UserBubble: View {
    let text: String
    let attachments: [Attachment]
    var body: some View {
        HStack {
            Spacer(minLength: 40)
            VStack(alignment: .trailing, spacing: 6) {
                if !attachments.isEmpty {
                    VStack(alignment: .trailing, spacing: 5) {
                        ForEach(attachments) { AttachmentChip(attachment: $0) }
                    }
                }
                if !text.isEmpty {
                    Text(text)
                        .textSelection(.enabled)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(Theme.userBubble, in: RoundedRectangle(cornerRadius: Theme.corner))
                }
            }
        }
    }
}

// MARK: - Assistant

private struct AssistantText: View {
    let text: String
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Avatar()
            // Verbatim: exactly the characters the CLI emitted, no markdown
            // re-interpretation — what you'd see in the terminal.
            Text(verbatim: text)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct Avatar: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 7)
                .fill(Theme.accent)
                .frame(width: 26, height: 26)
            Image(systemName: "sparkle")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.white)
        }
    }
}

// MARK: - Thinking

private struct ThinkingBlock: View {
    let text: String
    @State private var expanded = false
    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            Text(text)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .padding(.top, 4)
        } label: {
            Label(L10n.t("reasoning"), systemImage: "brain")
                .foregroundStyle(.secondary)
        }
        .padding(.leading, 38)
    }
}

// MARK: - Result footer

private struct ResultFooter: View {
    let info: ResultInfo
    var body: some View {
        HStack(spacing: 12) {
            if info.isError {
                Label(info.text ?? L10n.t("error"), systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            } else {
                Label(L10n.t("done"), systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green.opacity(0.8))
            }
            Spacer()
            if let d = info.durationMs {
                metric("clock", String(format: "%.1fs", Double(d) / 1000))
            }
            if let n = info.numTurns {
                metric("arrow.triangle.2.circlepath", "\(n)")
            }
        }
        .foregroundStyle(.secondary)
        .padding(.leading, 38)
        .padding(.top, -6)
    }

    private func metric(_ icon: String, _ value: String) -> some View {
        Label(value, systemImage: icon)
    }
}

// MARK: - Notice

private struct NoticeBanner: View {
    let notice: Notice
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: icon)
                    .foregroundStyle(color)
                Text(verbatim: notice.text)
                    .font(notice.text.hasPrefix("$") ? .system(.body, design: .monospaced) : .body)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if notice.detail != nil {
                    Button {
                        withAnimation(.easeOut(duration: 0.15)) { expanded.toggle() }
                    } label: {
                        Image(systemName: expanded ? "chevron.up" : "chevron.down")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(L10n.t(expanded ? "collapse" : "expand"))
                }
            }
            if expanded, let detail = notice.detail {
                ScrollView(.horizontal) {
                    Text(verbatim: detail)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                }
                .padding(8)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
            }
        }
        .padding(12)
        // Info notices wear the SAME quiet card as tool calls — one visual
        // family for everything that isn't a chat message. Only warnings and
        // errors are allowed to raise their voice.
        .background(background, in: RoundedRectangle(cornerRadius: Theme.corner))
        .overlay(RoundedRectangle(cornerRadius: Theme.corner).stroke(border))
        // The infobulle: hover shows the full command without expanding.
        .help(notice.detail ?? notice.text)
    }

    private var icon: String {
        switch notice.level {
        case .info: return "info.circle"
        case .warning: return "exclamationmark.triangle"
        case .error: return "xmark.octagon"
        }
    }
    private var color: Color {
        switch notice.level {
        case .info: return .secondary
        case .warning: return .orange
        case .error: return .red
        }
    }
    private var background: Color {
        switch notice.level {
        case .info: return Theme.card
        case .warning: return .orange.opacity(0.08)
        case .error: return .red.opacity(0.08)
        }
    }
    private var border: Color {
        switch notice.level {
        case .info: return Theme.hairline
        case .warning: return .orange.opacity(0.25)
        case .error: return .red.opacity(0.25)
        }
    }
}
