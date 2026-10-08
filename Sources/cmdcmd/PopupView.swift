import SwiftUI

/// The cmdcmd mini-panel: context chips, a one-line prompt box with @-file
/// and /-command autocomplete, and a compact transcript once the agent runs.
struct PopupView: View {
    @ObservedObject var session: AgentSession
    var screenshot: URL?          // captured at trigger time
    var frontApp: String          // app that was frontmost when triggered
    var onClose: () -> Void

    @ObservedObject private var chat: ChatModel
    @StateObject private var mentions = MentionSearch()

    @State private var input = ""
    @State private var files: [URL] = []
    @State private var shot: URL?
    @State private var picked = 0
    @FocusState private var focused: Bool

    init(session: AgentSession, screenshot: URL?, frontApp: String,
         onClose: @escaping () -> Void) {
        self.session = session
        self.screenshot = screenshot
        self.frontApp = frontApp
        self.onClose = onClose
        _chat = ObservedObject(wrappedValue: session.chat)
        _shot = State(initialValue: screenshot)
    }

    // MARK: suggestion state

    /// Active autocomplete query: "@foo" at the end of the input, or "/cmd".
    private var suggestionKind: String? {
        if input.hasPrefix("/"), !input.contains(" "),
           !chat.commands.isEmpty { return "slash" }
        if let m = input.range(of: #"@([^\s@]*)$"#, options: .regularExpression),
           m.upperBound == input.endIndex { return "file" }
        return nil
    }

    private var slashQuery: String {
        String(input.dropFirst())
    }

    private var slashMatches: [SlashCommand] {
        chat.commands.filter {
            slashQuery.isEmpty || $0.name.lowercased().hasPrefix(slashQuery.lowercased())
        }.prefix(8).map { $0 }
    }

    private var suggestionCount: Int {
        suggestionKind == "slash" ? slashMatches.count : mentions.results.count
    }

    // MARK: body

    var body: some View {
        VStack(spacing: 0) {
            header
            if !chat.entries.isEmpty { transcript }
            chips
            inputBox
        }
        .frame(width: 600)
        .fixedSize(horizontal: false, vertical: true)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16)
            .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.35), radius: 24, y: 10)
        .onAppear { focused = true }
    }

    // MARK: header

    private var header: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(statusColor)
                .frame(width: 7, height: 7)
                .shadow(color: statusColor.opacity(0.8), radius: chat.busy ? 3 : 0)
            Menu {
                ForEach(Config.agents) { a in
                    Button {
                        Config.current.selectedAgent = a.id
                        Config.save()
                        session.reconnect()
                    } label: {
                        if a.id == Config.current.selectedAgent {
                            Label(a.name, systemImage: "checkmark")
                        } else { Text(a.name) }
                    }
                }
                Divider()
                Button("Edit config.json…") {
                    NSWorkspace.shared.open(Config.url)
                }
            } label: {
                Text(chat.agentName.isEmpty ? Config.agent.name : chat.agentName)
                    .font(.system(size: 12, weight: .semibold))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            Text("⌘⌘")
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundStyle(.tertiary)

            Spacer()

            if !chat.statusLine.isEmpty {
                Text(chat.statusLine)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            if !chat.modes.isEmpty {
                Menu {
                    ForEach(chat.modes) { m in
                        Button {
                            session.setMode(m.id)
                        } label: {
                            if m.id == chat.currentMode {
                                Label(m.name, systemImage: "checkmark")
                            } else { Text(m.name) }
                        }
                    }
                } label: {
                    Text(chat.modes.first { $0.id == chat.currentMode }?.name ?? "mode")
                        .font(.system(size: 10, weight: .medium))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.white.opacity(0.08), in: Capsule())
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }

            Button { session.newChat() } label: {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 11))
            }
            .buttonStyle(.plain).foregroundStyle(.secondary)
            .help("New chat")

            Button { onClose() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
            }
            .buttonStyle(.plain).foregroundStyle(.secondary)
            .help("Close (Esc)")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    private var statusColor: Color {
        switch chat.state {
        case .idle: return .gray
        case .starting, .prompting: return .orange
        case .ready: return .green
        case .error: return .red
        }
    }

    // MARK: transcript

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(chat.entries) { e in
                        entryRow(e).id(e.id)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
            }
            .frame(maxHeight: 280)
            .onChange(of: chat.entries.count) {
                if let last = chat.entries.last {
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
            .onChange(of: chat.entries.last?.body) {
                if let last = chat.entries.last {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
        }
    }

    @ViewBuilder
    private func entryRow(_ e: Entry) -> some View {
        switch e.kind {
        case .user:
            VStack(alignment: .leading, spacing: 4) {
                if let img = e.imageURL, let ns = NSImage(contentsOf: img) {
                    Image(nsImage: ns)
                        .resizable().aspectRatio(contentMode: .fit)
                        .frame(maxHeight: 90)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                if !e.files.isEmpty {
                    Text(e.files.map { $0.lastPathComponent }.joined(separator: ", "))
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
                if !e.body.isEmpty { Text(e.body).font(.system(size: 13)) }
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(Color.accentColor.opacity(0.14),
                        in: RoundedRectangle(cornerRadius: 10))
            .frame(maxWidth: .infinity, alignment: .leading)

        case .agentText:
            markdown(e.body)
                .font(.system(size: 13))
                .textSelection(.enabled)

        case .thought:
            Text(e.body)
                .font(.system(size: 11))
                .italic()
                .foregroundStyle(.secondary)
                .lineLimit(4)

        case .tool:
            HStack(spacing: 6) {
                toolIcon(e)
                Text(e.title)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(Color.white.opacity(0.05),
                        in: RoundedRectangle(cornerRadius: 7))

        case .plan:
            Text(e.body)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .padding(8)
                .background(Color.white.opacity(0.05),
                            in: RoundedRectangle(cornerRadius: 8))

        case .permission:
            VStack(alignment: .leading, spacing: 7) {
                Label(e.title, systemImage: "hand.raised.fill")
                    .font(.system(size: 12, weight: .semibold))
                HStack(spacing: 6) {
                    ForEach(e.options, id: \.id) { o in
                        Button(o.name.isEmpty ? o.id : o.name) {
                            session.answerPermission(e, optionId: o.id)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .tint(o.kind.hasPrefix("allow") ? .accentColor : .red.opacity(0.7))
                    }
                    Button("Dismiss") { session.answerPermission(e, optionId: nil) }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                        .font(.system(size: 11))
                }
            }
            .padding(9)
            .background(Color.orange.opacity(0.12),
                        in: RoundedRectangle(cornerRadius: 10))

        case .note:
            Text(e.body)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.red.opacity(0.08),
                            in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private func toolIcon(_ e: Entry) -> some View {
        let (name, color): (String, Color) = switch e.status {
        case "completed": ("checkmark.circle.fill", .green)
        case "failed": ("xmark.circle.fill", .red)
        case "in_progress": ("ellipsis.circle.fill", .orange)
        default: ("circle", .gray)
        }
        return Image(systemName: name).font(.system(size: 11)).foregroundStyle(color)
    }

    private func markdown(_ s: String) -> Text {
        if let a = try? AttributedString(markdown: s,
                                         options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            return Text(a)
        }
        return Text(s)
    }

    // MARK: chips

    @ViewBuilder
    private var chips: some View {
        if shot != nil || !files.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    if let shot, let ns = NSImage(contentsOf: shot) {
                        chip {
                            HStack(spacing: 5) {
                                Image(nsImage: ns)
                                    .resizable().aspectRatio(contentMode: .fill)
                                    .frame(width: 30, height: 20)
                                    .clipShape(RoundedRectangle(cornerRadius: 3))
                                Text("Screen" + (frontApp.isEmpty ? "" : " · \(frontApp)"))
                            }
                        } onRemove: { self.shot = nil }
                    }
                    ForEach(files, id: \.self) { f in
                        chip {
                            Label(f.lastPathComponent, systemImage: "doc")
                        } onRemove: {
                            files.removeAll { $0 == f }
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
            }
        }
    }

    private func chip<V: View>(@ViewBuilder _ label: () -> V,
                               onRemove: @escaping () -> Void) -> some View {
        HStack(spacing: 4) {
            label().font(.system(size: 11))
            Button(action: onRemove) {
                Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
            }
            .buttonStyle(.plain).foregroundStyle(.secondary)
        }
        .padding(.leading, 6).padding(.trailing, 5).padding(.vertical, 4)
        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: input + suggestions

    private var inputBox: some View {
        VStack(spacing: 0) {
            if let kind = suggestionKind, suggestionCount > 0 {
                suggestionList(kind)
            }
            HStack(spacing: 8) {
                TextField(placeholder, text: $input)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .focused($focused)
                    .onSubmit(send)
                    .onChange(of: input) { refreshSuggestions() }
                    .onKeyPress(.upArrow) {
                        guard suggestionKind != nil else { return .ignored }
                        picked = max(0, picked - 1); return .handled
                    }
                    .onKeyPress(.downArrow) {
                        guard suggestionKind != nil else { return .ignored }
                        picked = min(suggestionCount - 1, picked + 1); return .handled
                    }
                    .onKeyPress(.tab) {
                        guard suggestionKind != nil else { return .ignored }
                        acceptSuggestion(); return .handled
                    }
                    .onKeyPress(.return) {
                        if suggestionKind != nil && suggestionCount > 0 {
                            acceptSuggestion(); return .handled
                        }
                        send(); return .handled
                    }
                    .onKeyPress(.escape) {
                        if suggestionKind != nil {
                            input.append(" ")   // break the @ / / trigger
                            input.removeLast()
                            picked = 0
                            return .handled
                        }
                        onClose(); return .handled
                    }

                Button(action: pickFile) {
                    Image(systemName: "paperclip").font(.system(size: 12))
                }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .help("Attach a file")

                if chat.state == .prompting {
                    Button(action: { session.cancel() }) {
                        Image(systemName: "stop.fill").font(.system(size: 11))
                    }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .help("Stop")
                } else {
                    Button(action: send) {
                        Image(systemName: "arrow.up").font(.system(size: 12, weight: .bold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white)
                    .padding(5)
                    .background(canSend ? Color.accentColor : Color.gray.opacity(0.4),
                                in: Circle())
                    .disabled(!canSend)
                    .help("Send (↩)")
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
        }
    }

    private var placeholder: String {
        if shot != nil { return "Ask about your screen — @ to add files" }
        return "Ask \(Config.agent.name) — @ to add files"
    }

    private var canSend: Bool {
        !chat.busy && (!input.trimmingCharacters(in: .whitespaces).isEmpty || shot != nil || !files.isEmpty)
    }

    private func refreshSuggestions() {
        picked = 0
        if suggestionKind == "file" {
            let q = String(input[input.range(of: #"@([^\s@]*)$"#,
                                           options: .regularExpression)!.lowerBound...].dropFirst())
            mentions.query(q, root: Config.workspaceURL)
        }
    }

    private func suggestionList(_ kind: String) -> some View {
        VStack(spacing: 0) {
            if kind == "slash" {
                ForEach(Array(slashMatches.enumerated()), id: \.element.id) { i, c in
                    suggestionRow(
                        selected: i == picked,
                        icon: "slash.circle",
                        title: "/\(c.name)",
                        subtitle: c.description
                    ) { acceptSlash(c) }
                }
            } else {
                ForEach(Array(mentions.results.enumerated()), id: \.element.rel) { i, f in
                    suggestionRow(
                        selected: i == picked,
                        icon: "doc",
                        title: f.url.lastPathComponent,
                        subtitle: f.rel
                    ) { acceptFile(f.url) }
                }
            }
        }
        .padding(.vertical, 4)
        .background(.ultraThickMaterial)
        .overlay(alignment: .bottom) { Divider().opacity(0.5) }
    }

    private func suggestionRow(selected: Bool, icon: String, title: String,
                               subtitle: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                Text(title).font(.system(size: 12, weight: .medium))
                Text(subtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1).truncationMode(.middle)
                Spacer()
            }
            .padding(.horizontal, 14).padding(.vertical, 5)
            .background(selected ? Color.accentColor.opacity(0.18) : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: actions

    private func acceptSuggestion() {
        switch suggestionKind {
        case "slash":
            if picked < slashMatches.count { acceptSlash(slashMatches[picked]) }
        case "file":
            if picked < mentions.results.count { acceptFile(mentions.results[picked].url) }
        default: break
        }
    }

    private func acceptSlash(_ c: SlashCommand) {
        input = "/\(c.name) "
        picked = 0
    }

    private func acceptFile(_ url: URL) {
        // strip the active @query from the input, attach the file
        if let r = input.range(of: #"@([^\s@]*)$"#, options: .regularExpression) {
            input.removeSubrange(r)
            input = input.trimmingCharacters(in: .whitespaces)
        }
        if !files.contains(url) { files.append(url) }
        picked = 0
    }

    private func pickFile() {
        let p = NSOpenPanel()
        p.allowsMultipleSelection = true
        p.canChooseDirectories = false
        p.directoryURL = Config.workspaceURL
        if p.runModal() == .OK {
            for u in p.urls where !files.contains(u) { files.append(u) }
        }
    }

    private func send() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canSend else { return }
        session.send(text: text, image: shot, files: files)
        input = ""
        files = []
        shot = nil
        picked = 0
    }
}
