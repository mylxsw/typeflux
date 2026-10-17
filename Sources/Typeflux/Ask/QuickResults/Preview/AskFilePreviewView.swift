import AppKit
import SwiftUI
import TypefluxMediaProtocol

struct AskFilePreviewView: View {
    @ObservedObject var state: AskFilePreviewState
    @Environment(\.interfaceStyle) private var style
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        VStack(spacing: 0) {
            header.frame(height: 50)
            Divider().opacity(0.4)
            GeometryReader { geometry in
                ZStack {
                    if state.skeleton {
                        skeleton.transition(.opacity)
                    } else if let content = state.content {
                        preview(content).id(state.contentID).transition(.opacity)
                    }
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(StudioTheme.textPrimary.opacity(0.035))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .padding(10)
            Divider().opacity(0.4)
            footer.frame(height: state.hit?.hasPDFLocationEvidence == true ? 66 : 38)
        }
        .environment(\.askContextImageAccess, state.imageAccess)
        .background(AskGlassBackground(material: .resolve(reduceTransparency: reduceTransparency, style: style),
                                       corner: 16, opaqueFill: AskTheme.surface))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L("launcher.search.preview"))
    }

    private var header: some View {
        HStack(spacing: 9) {
            AskNativeIconView(icon: headerIcon)
                .frame(width: 28, height: 28).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(state.hit?.name ?? "").font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    .truncationMode(.middle)
                Text(state.detail ?? L("ask.preview.loading"))
                    .font(.system(size: 10)).foregroundStyle(StudioTheme.textSecondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }.padding(.horizontal, 14)
    }

    private var headerIcon: MediaNativeIcon {
        let suffix = state.hit?.url.pathExtension ?? ""
        return suffix.isEmpty ? .init(kind: .type, value: "public.data") : .init(kind: .fileExtension, value: suffix)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 5) {
            if state.hit?.hasPDFLocationEvidence == true {
                Text(L("ask.quick.file.pdf.preview"))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("ask.file.pdf.openCapability")
            }
            HStack(spacing: 10) {
                Text(state.hit.map { ($0.folder as NSString).abbreviatingWithTildeInPath } ?? "")
                    .lineLimit(1).truncationMode(.head)
                Spacer(minLength: 0)
                Text("⌘Y " + L("ask.quick.action.quickLook")).fixedSize()
            }
        }.font(.system(size: 10)).foregroundStyle(StudioTheme.textSecondary).padding(.horizontal, 14)
    }

    private var skeleton: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(0 ..< 7) { index in
                RoundedRectangle(cornerRadius: 4).fill(StudioTheme.textPrimary.opacity(0.07))
                    .frame(width: index % 3 == 0 ? 170 : nil, height: 9)
            }
            Spacer()
        }.padding(18).accessibilityLabel(L("ask.preview.loading"))
    }

    @ViewBuilder private func preview(_ content: AskFilePreviewContent) -> some View {
        switch content.kind {
        case .image, .document, .video:
            ZStack(alignment: .bottomTrailing) {
                if content.kind == .image {
                    checkerboard
                }
                if let image = content.images.first {
                    Image(nsImage: image).resizable().scaledToFit().padding(8)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                textLocationFallback(content)
                if content.kind == .video {
                    Text(AskFilePreviewContent.time(content.duration) + " · " + L("ask.preview.noAutoplay"))
                        .font(.system(size: 10)).padding(7).background(.ultraThinMaterial, in: Capsule()).padding(10)
                }
            }
        case .pdf:
            ScrollView {
                VStack(spacing: 10) {
                    ForEach(Array(content.images.enumerated()), id: \.offset) { index, image in
                        if content.pageNumbers.indices.contains(index) {
                            Text(L("semantic.page", content.pageNumbers[index]))
                                .font(.system(size: 10)).foregroundStyle(StudioTheme.textSecondary)
                        }
                        Image(nsImage: image).resizable().scaledToFit().background(.white).shadow(radius: 2)
                    }
                    Text(String(format: L("ask.preview.pages"), content.pageCount)).font(.system(size: 10))
                }.padding(10)
            }.overlay(alignment: .bottomTrailing) { textLocationFallback(content) }
        case .text: text(content)
        case .markdown:
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(content.text.components(separatedBy: "\n").enumerated()), id: \.offset) { _, line in
                        markdownLine(line)
                    }
                    truncation(content)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(14)
            }
        case .table: table(content)
        case .audio: audio(content)
        }
    }

    @ViewBuilder private func textLocationFallback(_ content: AskFilePreviewContent) -> some View {
        if content.imageTextLocated == false {
            Text(L("ask.preview.textLocationUnavailable"))
                .font(.system(size: 10)).padding(7).background(.ultraThinMaterial, in: Capsule()).padding(10)
        }
    }

    private func audio(_ content: AskFilePreviewContent) -> some View {
        VStack(spacing: 20) {
            Canvas { context, size in
                for (index, peak) in content.waveform.enumerated() {
                    let width = size.width / CGFloat(max(1, content.waveform.count))
                    let height = max(2, CGFloat(peak) * size.height)
                    context.fill(Path(roundedRect: CGRect(x: CGFloat(index) * width, y: (size.height - height) / 2,
                                                          width: max(1, width - 2), height: height),
                                      cornerRadius: 2),
                                 with: .color(AskTheme.accent))
                }
            }.frame(height: 90)
            Text(AskFilePreviewContent.time(content.duration)).font(.system(
                size: 20,
                weight: .medium,
                design: .monospaced
            ))
            Text(L("ask.preview.noAutoplay")).font(.system(size: 11)).foregroundStyle(StudioTheme.textSecondary)
        }.padding(20)
    }

    private var checkerboard: some View {
        Canvas { context, size in
            for row in 0 ..< Int(ceil(size.height / 10)) {
                for column in 0 ..< Int(ceil(size.width / 10)) where (row + column).isMultiple(of: 2) {
                    context.fill(Path(CGRect(x: column * 10, y: row * 10, width: 10, height: 10)),
                                 with: .color(.gray.opacity(0.12)))
                }
            }
        }
    }

    private func text(_ content: AskFilePreviewContent) -> some View {
        GeometryReader { geometry in
            ScrollView([.vertical, .horizontal]) {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(content.text.components(separatedBy: "\n").enumerated()),
                            id: \.offset) { index, line in
                        HStack(alignment: .top, spacing: 12) {
                            Text("\(index + 1)").foregroundStyle(StudioTheme.textTertiary).frame(
                                width: 28,
                                alignment: .trailing
                            )
                            Text(highlight(line)).fixedSize(horizontal: true, vertical: false)
                        }
                    }
                    truncation(content)
                }.font(.system(size: 11, design: .monospaced)).padding(12)
                    .frame(minWidth: geometry.size.width, minHeight: geometry.size.height, alignment: .topLeading)
            }
        }
    }

    private func highlight(_ line: String) -> AttributedString {
        var value = AttributedString(line)
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("//") || trimmed.hasPrefix("#") {
            value.foregroundColor = .secondary; return value
        }
        // swiftlint:disable:next line_length
        let pattern = #""(?:[^"\\]|\\.)*"|\b(?:func|let|var|const|return|if|else|import|class|struct|enum|def|for|while|true|false|null|nil)\b|\b\d+(?:\.\d+)?\b"#
        if let regex = try? NSRegularExpression(pattern: pattern) {
            for match in regex.matches(in: line, range: NSRange(line.startIndex..., in: line)) {
                guard let range = Range(match.range, in: line),
                      let attributedRange = Range(range, in: value) else { continue }
                let token = line[range]
                value[attributedRange].foregroundColor = token.hasPrefix("\"") ? .green : token.first?
                    .isNumber == true ? .orange : .purple
            }
        }
        return value
    }

    private func markdownLine(_ line: String) -> some View {
        let heading = line.prefix { $0 == "#" }.count
        let display = heading > 0 ? String(line.dropFirst(heading)).trimmingCharacters(in: .whitespaces) :
            line.hasPrefix("- ") || line.hasPrefix("* ") ? "• " + line.dropFirst(2) : line
        return Text((try? AttributedString(
            markdown: display,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(display))
            .font(.system(
                size: heading > 0 ? CGFloat(max(13, 22 - heading * 2)) : 12,
                weight: heading > 0 ? .semibold : .regular
            ))
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func table(_ content: AskFilePreviewContent) -> some View {
        let rows = AskFilePreviewText.table(
            content.text,
            separator: state.hit?.url.pathExtension.lowercased() == "tsv" ? "\t" : ","
        )
        return GeometryReader { geometry in
            ScrollView([.horizontal, .vertical]) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                        HStack(spacing: 0) {
                            ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                                Text(cell).lineLimit(3).frame(width: 110, alignment: .leading).padding(7)
                            }
                        }.font(.system(size: 11, weight: index == 0 ? .semibold : .regular))
                            .background(StudioTheme.textPrimary.opacity(index == 0 ? 0.08 : index % 2 == 0 ? 0.025 : 0))
                        Divider()
                    }
                    truncation(content)
                }.padding(8)
                    .frame(minWidth: geometry.size.width, minHeight: geometry.size.height, alignment: .topLeading)
            }
        }
    }

    @ViewBuilder private func truncation(_ content: AskFilePreviewContent) -> some View {
        if content
            .truncated {
            Text(L("ask.preview.truncated")).font(.system(size: 10)).foregroundStyle(StudioTheme.textSecondary)
        }
    }
}
