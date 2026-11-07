import KlimacontrolCore
import SwiftUI

// Angaben aus dem Kern (`ThirdPartyNotices`) – dieselben wie in THIRD_PARTY_NOTICES.md und unter Windows.

struct NoticesSettings: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Klimacontrol baut auf den folgenden Open-Source-Projekten auf. Ihre Lizenzen verlangen, Urheberrechtsvermerk und Lizenztext mitzugeben.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                ForEach(ThirdPartyNotices.all) { NoticeCard(notice: $0) }
                Text(ThirdPartyNotices.trademarkNote)
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)
            }
            .padding(16)
        }
    }
}

private struct NoticeCard: View {
    let notice: ThirdPartyNotice
    @State private var showText = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                if let url = URL(string: notice.url) {
                    Link(notice.name, destination: url).font(.headline)
                        .help(notice.url)
                } else {
                    Text(notice.name).font(.headline)
                }
                Spacer()
                Text(notice.license)
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Capsule().fill(Color.secondary.opacity(0.15)))
                Text(notice.platforms).font(.caption).foregroundStyle(.secondary)
            }
            ForEach(notice.copyright, id: \.self) { Text($0).font(.caption.monospaced()) }
            Text(notice.usage).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            DisclosureGroup("Lizenztext", isExpanded: $showText) {
                Text(notice.licenseText)
                    .font(.system(size: 10, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary.opacity(0.4)))
            }
            .font(.caption)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.04)))
        .accessibilityElement(children: .contain)
    }
}
