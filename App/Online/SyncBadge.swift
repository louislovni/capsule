import SwiftUI

/// The cloud's state on the home screen, under the title: syncing or sending a save (turning arrows), the last sync's
/// time (a cloud with a tick, "à l'instant" / "il y a 5 min"), or a failure (orange, until one goes through).
/// A tap opens the account page (its "Synchroniser maintenant" and the last sync's details).
struct SyncBadge: View {
    @ObservedObject var cloud: CloudSync

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            HStack(spacing: 6) {
                if cloud.syncing {
                    // Turning only while it syncs: its angle from the clock, so it stops dead with the sync (a
                    // repeating animation kept the tick turning once the sync was over).
                    TimelineView(.animation) { frame in
                        Image(systemName: icon)
                            .font(.system(size: 12, weight: .bold))
                            .rotationEffect(.degrees(frame.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1) * 360))
                    }
                } else {
                    Image(systemName: icon)
                        .font(.system(size: 12, weight: .bold))
                }
                Text(text(now: context.date))
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(cloud.lastFailed && !cloud.syncing ? Color.orange : Color.capsuleCream.opacity(0.75))
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(Color.capsulePanel, in: Capsule())
        }
        .accessibilityElement(children: .combine)
        .accessibilityHint("Ouvre le compte et la synchronisation")
    }

    private var icon: String {
        if cloud.syncing { return "arrow.triangle.2.circlepath" }
        if cloud.lastFailed { return "exclamationmark.icloud" }
        return cloud.lastSync == nil ? "icloud" : "checkmark.icloud"
    }

    private func text(now: Date) -> String {
        if cloud.syncing { return cloud.pushing ? "Envoi de ta sauvegarde…" : "Synchronisation…" }
        if cloud.lastFailed { return "Synchro impossible · hors ligne ?" }
        guard let last = cloud.lastSync else { return "Pas encore synchronisé" }
        let minutes = Int(now.timeIntervalSince(last) / 60)
        switch minutes {
        case ..<1: return "Synchronisé à l'instant"
        case ..<60: return "Synchronisé il y a \(minutes) min"
        case ..<1440: return "Synchronisé il y a \(minutes / 60) h"
        default: return "Synchronisé le \(last.formatted(date: .abbreviated, time: .omitted))"
        }
    }
}
