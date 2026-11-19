import SwiftUI

/// A game's save points (its own saves, newest first) and its spare copy: one can be put back as the save.
struct SaveHistoryView: View {
    let game: Game
    let onRestored: (String) -> Void
    let onSafety: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var points: [SaveHistory.Point] = []
    @State private var chosen: SaveHistory.Point?
    /// The point that holds the save as it is now.
    @State private var current: URL?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if points.isEmpty {
                        Text("Pas encore de sauvegarde gardée : elles s'ajoutent chaque fois que tu sauvegardes dans le jeu.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(points) { point in
                        Button {
                            if point.url != current { chosen = point }
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(point.date.formatted(date: .abbreviated, time: .shortened))
                                        .foregroundStyle(.primary)
                                    Text(point.date.formatted(.relative(presentation: .named)))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if point.url == current {
                                    Text("actuelle").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                } else {
                                    Image(systemName: "arrow.uturn.backward").foregroundStyle(.orange)
                                }
                            }
                        }
                        .disabled(point.url == current)
                    }
                } header: {
                    Text("Tes sauvegardes dans le jeu")
                } footer: {
                    Text("Les \(SaveHistory.keep) dernières fois où tu as sauvegardé. Revenir à l'une d'elles remplace la sauvegarde actuelle, qui reste dans les copies datées.")
                }
                if let date = SafetySave.date(for: game) {
                    Section {
                        Button {
                            onSafety()
                        } label: {
                            Label("Copie de secours du \(date.formatted(date: .abbreviated, time: .shortened))", systemImage: "lifepreserver")
                        }
                    } footer: {
                        Text("La sauvegarde telle qu'elle était au dernier lancement du jeu.")
                    }
                }
            }
            .navigationTitle(PokedexStore.gameTitle(game.name))
            .capsuleScreen()
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Fermer") { dismiss() }
                }
            }
            .onAppear {
                points = SaveHistory.points(for: game)
                let now = try? Data(contentsOf: game.saveURL)
                current = points.first { now != nil && (try? Data(contentsOf: $0.url)) == now }?.url
            }
            .confirmationDialog(
                "Revenir à cette sauvegarde ?",
                isPresented: Binding(get: { chosen != nil }, set: { if !$0 { chosen = nil } }),
                titleVisibility: .visible,
                presenting: chosen
            ) { point in
                Button("Revenir à la sauvegarde du \(point.date.formatted(date: .abbreviated, time: .shortened))", role: .destructive) {
                    do {
                        try SaveHistory.restore(point, for: game)
                        onRestored("La sauvegarde est revenue à celle du \(point.date.formatted(date: .long, time: .shortened)).")
                    } catch {
                        onRestored("La sauvegarde n'a pas pu être remise : \(error.localizedDescription)")
                    }
                }
                Button("Annuler", role: .cancel) { chosen = nil }
            } message: { _ in
                Text("Tout ce qui a été fait dans le jeu depuis sera perdu. La sauvegarde actuelle est gardée dans les copies datées.")
            }
        }
    }
}
