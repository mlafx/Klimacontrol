import MideaKit
import KlimacontrolCore
import SwiftUI

// MARK: - Szenen: Raster statt Scrollreihe, aktive Szene markiert

/// Liest Szenen und Zustand und reicht nur „welche Szenen sind aktiv“ weiter: Neue Messwerte bauen das Raster
/// nicht neu auf.
struct ScenesSection: View {
    @Environment(ACController.self) var model

    var body: some View {
        let scenes = model.scenes
        ScenesList(scenes: scenes, activeIDs: Set(scenes.filter { model.isActive($0) }.map(\.id)))
            .equatable()
    }
}

private struct ScenesList: View, Equatable {
    @Environment(ACController.self) var model
    @Environment(\.klimaTheme) private var theme
    let scenes: [ACScene]
    let activeIDs: Set<String>
    @State private var naming = false
    @State private var sceneName = ""
    /// Szene, deren Löschen noch bestätigt werden muss.
    @State private var deleting: ACScene?
    /// Standardmäßig eingeklappt – Szenen sind optional.
    @AppStorage(SettingsKey.showScenes) private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            scenesContent.padding(.top, 6)
        } label: {
            // Gleiche Optik wie die Abschnittstitel LÜFTER/KOMFORT (SectionTitle), damit die Hierarchie durchgeht.
            Text(label).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                .frame(minHeight: 22)
                .contentShape(Rectangle())
        }
        .alert("Szene sichern", isPresented: $naming) {
            TextField("Name", text: $sceneName)
            Button("Sichern") {
                let name = sceneName.trimmingCharacters(in: .whitespaces)
                if !name.isEmpty { model.saveCurrentAsScene(named: name) }
                sceneName = ""
            }
            Button("Abbrechen", role: .cancel) { sceneName = "" }
        } message: {
            Text("Speichert Ein/Aus, Modus, Temperatur, Lüfter, Schwenken, Eco, Ionisierer und „Außengerät leise“.")
        }
        .confirmationDialog("Szene „\(deleting?.name ?? "")“ löschen?",
                            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("Löschen", role: .destructive) {
                if let deleting { model.deleteScene(deleting) }
                deleting = nil
            }
            Button("Abbrechen", role: .cancel) { deleting = nil }
        } message: {
            Text("Die Szene lässt sich danach nicht wiederherstellen.")
        }
    }

    /// Eingeklappt zeigen, welche Szene gerade eingestellt ist.
    private var label: String {
        if let first = scenes.first(where: { activeIDs.contains($0.id) }) { return "SZENEN · \(first.name) aktiv" }
        return "SZENEN"
    }

    private var scenesContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Spacer()
                Button { naming = true } label: {
                    Label("Szene sichern", systemImage: "plus").font(.caption)
                        .frame(minHeight: 24).contentShape(Rectangle())
                }
                    .buttonStyle(.borderless)
                    .help("Aktuellen Zustand als Szene sichern")
            }
            if scenes.isEmpty {
                Text("Noch keine Szenen – stelle die Anlage ein und sichere den Zustand mit +.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)], spacing: 6) {
                    ForEach(scenes) { scene in
                        let active = activeIDs.contains(scene.id)
                        let tint = OperationalMode(rawValue: scene.mode).map { theme.tint(for: $0) } ?? .accentColor
                        Button { model.apply(scene) } label: {
                            HStack(spacing: 8) {
                                Image(systemName: OperationalMode(rawValue: scene.mode).map(\.symbol) ?? "star")
                                    .foregroundStyle(active ? theme.label(on: tint) : tint)
                                    .frame(width: 18)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(scene.name).font(.callout.weight(.medium)).lineLimit(1)
                                    Text(sceneSummary(scene)).font(.caption2)
                                        .foregroundStyle(active ? theme.label(on: tint).opacity(0.85) : .secondary).lineLimit(1)
                                }
                                Spacer(minLength: 0)
                                if active { Image(systemName: "checkmark").font(.caption.weight(.bold)) }
                            }
                            .padding(.horizontal, 10).padding(.vertical, 7)
                            .foregroundStyle(active ? theme.label(on: tint) : .primary)
                            .klimaCard(tint: active ? tint : nil, radius: 12, interactive: true)
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button("Szene löschen …", role: .destructive) { deleting = scene }
                        }
                        .accessibilityAction(named: "Szene löschen") { deleting = scene }
                        .help(active ? "\(scene.name) ist eingestellt" : "\(scene.name) anwenden – Rechtsklick zum Löschen")
                        .accessibilityAddTraits(active ? .isSelected : [])
                    }
                }
            }
        }
    }

    nonisolated static func == (a: ScenesList, b: ScenesList) -> Bool { a.scenes == b.scenes && a.activeIDs == b.activeIDs }

    /// „Kühlen · 18° · Max“ – mit Modus: das Symbol allein ist bei mehreren Kühl-Szenen nicht eindeutig.
    private func sceneSummary(_ s: ACScene) -> String {
        guard s.powerOn else { return "Aus" }
        let fan = FanSpeed(rawValue: s.fan)?.label ?? "\(s.fan) %"
        let mode = OperationalMode(rawValue: s.mode)?.label
        return [mode, Fmt.target(s.tempC), fan].compactMap { $0 }.joined(separator: " · ")
    }
}
