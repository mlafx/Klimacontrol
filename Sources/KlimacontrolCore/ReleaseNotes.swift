import Foundation

/// Ein Abschnitt des CHANGELOG (eine Version).
public struct ReleaseNote: Equatable, Sendable {
    public struct Section: Equatable, Sendable {
        /// „Hinzugefügt“ usw.; leer bei Absätzen ohne Überschrift.
        public let title: String
        public let items: [String]
    }

    public let version: String
    /// nil bei „in Arbeit“ bzw. „in progress“.
    public let date: String?
    public let sections: [Section]
}

/// CHANGELOG zerlegen und für die Anzeige nach einem Update aufbereiten.
public enum ReleaseNotes {
    /// Zerlegt das Markdown des CHANGELOG; Markdown-Zeichen (`**`, Backticks) fallen weg, Text bleibt sonst unverändert.
    /// Folgezeilen eines Punkts werden angehängt, Unterpunkte als Zeilen mit „– “ unter den Punkt gesetzt.
    public static func parse(_ markdown: String) -> [ReleaseNote] {
        var notes: [ReleaseNote] = []
        var version: String?
        var date: String?
        var sections: [ReleaseNote.Section] = []
        var title = ""
        var items: [String] = []
        var open = false

        func closeSection() {
            if !items.isEmpty { sections.append(.init(title: title, items: items)) }
            items = []
        }
        func closeVersion() {
            closeSection()
            if let v = version { notes.append(ReleaseNote(version: v, date: date, sections: sections)) }
            version = nil
            date = nil
            sections = []
            title = ""
        }

        for raw in markdown.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if line.hasPrefix("## [") {
                closeVersion()
                guard let end = line.firstIndex(of: "]") else { continue }
                version = String(line[line.index(line.startIndex, offsetBy: 4)..<end])
                let rest = line[line.index(after: end)...].trimmingCharacters(in: .whitespaces)
                let stamp = rest.drop { $0 == "–" || $0 == "-" || $0 == " " }
                date = stamp.isEmpty || stamp == "in Arbeit" || stamp == "in progress" ? nil : String(stamp)
                open = false
            } else if version == nil {
                continue
            } else if line.hasPrefix("### ") {
                closeSection()
                title = plain(String(line.dropFirst(4)))
                open = false
            } else if line.hasPrefix("- ") {
                items.append(plain(String(line.dropFirst(2))))
                open = true
            } else if line.hasPrefix(" "), open {
                let text = line.trimmingCharacters(in: .whitespaces)
                if text.hasPrefix("- ") {
                    items[items.count - 1] += "\n– " + plain(String(text.dropFirst(2)))
                } else if !text.isEmpty {
                    items[items.count - 1] += " " + plain(text)
                }
            } else if !line.trimmingCharacters(in: .whitespaces).isEmpty {
                // Absatz ohne Aufzählung (z. B. „Erste öffentliche Fassung …“): eigener Abschnitt ohne Titel.
                if !title.isEmpty || !items.isEmpty { closeSection(); title = "" }
                items.append(plain(line))
                open = false
            } else {
                open = false
            }
        }
        closeVersion()
        return notes
    }

    private static func plain(_ s: String) -> String {
        s.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
            .trimmingCharacters(in: .whitespaces)
    }

    /// Punkte für eine Plattform: „Windows:“-Punkte fehlen am Mac, „Mac:“-Punkte unter Windows; das Präfix der eigenen
    /// Plattform fällt weg. Leere Abschnitte und Versionen ohne Punkte bleiben weg.
    public static func notes(_ notes: [ReleaseNote], for host: HostWords) -> [ReleaseNote] {
        let own = host == .mac ? "Mac:" : "Windows:"
        let other = host == .mac ? "Windows:" : "Mac:"
        return notes.compactMap { note in
            let sections = note.sections.compactMap { section -> ReleaseNote.Section? in
                let items = section.items.compactMap { item -> String? in
                    if item.hasPrefix(other) { return nil }
                    if item.hasPrefix(own) { return String(item.dropFirst(own.count)).trimmingCharacters(in: .whitespaces) }
                    return item
                }
                return items.isEmpty ? nil : ReleaseNote.Section(title: section.title, items: items)
            }
            return sections.isEmpty ? nil : ReleaseNote(version: note.version, date: note.date, sections: sections)
        }
    }

    /// Abschnitte für die Anzeige in `language`: Deutsch aus `changelog`; Englisch aus `changelogEnglish`, wobei jede
    /// Version ohne englischen Abschnitt deutsch erscheint, mit `UIText.whatsNewGermanOnly` als erstem Abschnitt
    /// (Titel leer).
    public static func all(for language: AppLanguage) -> [ReleaseNote] {
        let german = parse(changelog)
        guard language == .en else { return german }
        return merged(german: german, english: parse(changelogEnglish), hint: UIText.whatsNewGermanOnly)
    }

    /// Kern von `all(for:)`: Reihenfolge und Versionen nach `german`; Versionen nur in `english` fallen weg.
    static func merged(german: [ReleaseNote], english: [ReleaseNote], hint: String) -> [ReleaseNote] {
        german.map { note in
            if let en = english.first(where: { $0.version == note.version }) { return en }
            return ReleaseNote(version: note.version, date: note.date,
                               sections: [.init(title: "", items: [hint])] + note.sections)
        }
    }
}

/// Wann nach einem Update „Neu in dieser Version“ erscheint.
public enum WhatsNew {
    /// - Parameters:
    ///   - lastSeen: zuletzt bestätigte Version (nil = noch nie gemerkt).
    ///   - current: laufende Version.
    ///   - usedBefore: eine Anlage ist schon eingerichtet.
    /// - Returns: Abschnitte von `lastSeen` (ausgeschlossen) bis `current`, neueste zuerst; leer, wenn nichts zu zeigen ist.
    public static func pending(lastSeen: String?, current: String, usedBefore: Bool, notes: [ReleaseNote]) -> [ReleaseNote] {
        guard let cur = AppVersion(current)?.base, lastSeen != current else { return [] }
        guard notes.contains(where: { AppVersion($0.version) == cur }) else { return [] }
        let range: [ReleaseNote]
        if let seenFull = lastSeen.flatMap(AppVersion.init), seenFull.isBeta, seenFull.base == cur {
            range = notes.filter { AppVersion($0.version) == cur }
        } else if let seen = lastSeen.flatMap(AppVersion.init)?.base {
            range = notes.filter {
                guard let v = AppVersion($0.version) else { return false }
                return v > seen && v <= cur
            }
        } else if usedBefore {
            range = notes.filter { AppVersion($0.version) == cur }
        } else {
            return []
        }
        return range.sorted { (AppVersion($0.version) ?? cur) > (AppVersion($1.version) ?? cur) }
    }
}
