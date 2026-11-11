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
            scenesContent.padding(.top, 8)
        } label: {
            // Gleiche Optik wie die Abschnittstitel LÜFTER/KOMFORT (SectionTitle), damit die Hierarchie durchgeht.
            Text(label).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                .frame(minHeight: 22)
                .contentShape(Rectangle())
        }
        .alert(L.Main.Scene.save, isPresented: $naming) {
            TextField(L.Main.Scene.name, text: $sceneName)
            Button(L.Main.Scene.saveConfirm) {
                let name = sceneName.trimmingCharacters(in: .whitespaces)
                if !name.isEmpty { model.saveCurrentAsScene(named: name) }
                sceneName = ""
            }
            Button(L.Common.cancel, role: .cancel) { sceneName = "" }
        } message: {
            Text(L.Main.Scene.saveMessage)
        }
        .confirmationDialog(L.Main.Scene.deleteTitle(name: deleting?.name ?? ""),
                            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button(L.Main.Scene.deleteConfirm, role: .destructive) {
                if let deleting { model.deleteScene(deleting) }
                deleting = nil
            }
            Button(L.Common.cancel, role: .cancel) { deleting = nil }
        } message: {
            Text(L.Main.Scene.deleteMessage)
        }
    }

    /// Eingeklappt zeigen, welche Szene gerade eingestellt ist.
    private var label: String {
        if let first = scenes.first(where: { activeIDs.contains($0.id) }) { return L.Main.Section.scenesActive(name: first.name) }
        return L.Main.Section.scenes
    }

    private var scenesContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Spacer()
                Button { naming = true } label: {
                    Label(L.Main.Scene.save, systemImage: "plus").font(.caption)
                        .frame(minHeight: 24).contentShape(Rectangle())
                }
                    .buttonStyle(.borderless)
                    .help(L.Main.Scene.saveHelp)
            }
            if scenes.isEmpty {
                Text(L.Main.Scene.empty)
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
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
                                    Text(scene.summaryText).font(.caption2)
                                        .foregroundStyle(active ? theme.label(on: tint).opacity(0.85) : .secondary).lineLimit(1)
                                }
                                Spacer(minLength: 0)
                                if active { Image(systemName: "checkmark").font(.caption.weight(.bold)) }
                            }
                            .padding(.horizontal, 12).padding(.vertical, 8)
                            .foregroundStyle(active ? theme.label(on: tint) : .primary)
                            .klimaInner(tint: active ? tint : nil)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(PressDimStyle())
                        .contextMenu {
                            Button(L.Main.Scene.deleteMenu, role: .destructive) { deleting = scene }
                        }
                        .accessibilityAction(named: L.Main.Scene.deleteAction) { deleting = scene }
                        .help(active ? L.Main.Scene.activeHelp(name: scene.name) : L.Main.Scene.applyHelp(name: scene.name))
                        .accessibilityAddTraits(active ? .isSelected : [])
                    }
                }
            }
        }
    }

    nonisolated static func == (a: ScenesList, b: ScenesList) -> Bool { a.scenes == b.scenes && a.activeIDs == b.activeIDs }
}
