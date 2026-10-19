import SwiftUI

struct ItemPreviewView: View {
    @ObservedObject var controller: AppController
    @State private var revealSecret = false

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.l) {
            if let item = controller.selectedItem {
                HStack(spacing: DS.Space.s) {
                    if let icon = controller.icons.appIcon(bundleID: item.sourceBundleID) {
                        Image(nsImage: icon).resizable().frame(width: 18, height: 18)
                    }
                    Text("\(item.detail?.label ?? item.kind.label) · \(item.sourceName.isEmpty ? "未知应用" : item.sourceName) · \(item.lastCopiedAt.formatted(.dateTime.month().day().hour().minute()))")
                        .font(.ds(DS.Size.body)).foregroundStyle(DS.secondary)
                    Spacer()
                    Button { controller.toggleFavorite(item.id) } label: {
                        Image(systemName: item.isFavorite ? "star.fill" : "star").foregroundStyle(item.isFavorite ? DS.accent : DS.secondary)
                    }
                    .buttonStyle(.plain).accessibilityLabel(item.isFavorite ? "取消收藏" : "收藏")
                }
                Text(item.detail == .sensitive && !revealSecret ? "敏感内容" : (item.linkTitle.flatMap { $0.isEmpty ? nil : $0 } ?? item.title))
                    .font(.ds(DS.Size.display, .semibold)).textSelection(.enabled).lineLimit(3)
                Rectangle().fill(DS.line).frame(height: 1)
                ScrollView {
                    VStack(alignment: .leading, spacing: DS.Space.l) {
                        if item.kind == .image, let image = controller.previewImage(for: item) {
                            Image(nsImage: image).resizable().scaledToFit().frame(maxWidth: .infinity)
                                .clipShape(RoundedRectangle(cornerRadius: DS.Radius.small))
                        }
                        if let ocr = item.ocrText, !ocr.isEmpty {
                            VStack(alignment: .leading, spacing: DS.Space.s) {
                                Label("图片中的文字", systemImage: "text.viewfinder").font(.ds(DS.Size.caption, .semibold)).foregroundStyle(DS.secondary)
                                Text(ocr).font(.ds(DS.Size.emphasis)).lineSpacing(5).textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .padding(DS.Space.m)
                            .background(DS.surface, in: RoundedRectangle(cornerRadius: DS.Radius.card))
                        }
                        if item.detail == .sensitive && !revealSecret {
                            Button { revealSecret = true } label: {
                                Label("显示敏感内容", systemImage: "eye").font(.ds(DS.Size.body, .medium))
                            }
                        } else if !item.text.isEmpty {
                            Group {
                                if item.detail == .code {
                                    Text(SyntaxHighlighter.attributed(String(item.text.prefix(20_000))))
                                        .font(.system(size: DS.Size.body, design: .monospaced)).lineSpacing(3)
                                } else {
                                    Text(item.text).font(.system(size: 14)).lineSpacing(6)
                                }
                            }
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                HStack {
                    Text("空格或 esc 返回抽屉").font(.ds(DS.Size.caption)).foregroundStyle(DS.secondary)
                    Spacer()
                    Button("仅复制") { controller.useSelected(copyOnly: true) }
                    Button(controller.accessibilityGranted ? "粘贴" : "复制") { controller.useSelected() }.buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(.horizontal, DS.Space.xxl).padding(.top, 36).padding(.bottom, DS.Space.xxl)
        .background(DS.background)
        .foregroundStyle(DS.ink).tint(DS.accent)
        .frame(minWidth: 440, minHeight: 320)
        .onChange(of: controller.selectedID) { _ in revealSecret = false }
    }
}
