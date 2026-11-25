import SwiftUI
import ClrcCore

/// Picks a Claude profile from the list the Mac reports. nil = the default,
/// labelled with what it resolves to. Falls back to a text field when the Mac
/// cannot list its profiles (old agent or relay).
struct ProfilePicker: View {
    let title: String
    @Binding var selection: String?
    let profiles: MacProfiles?
    let unavailable: Bool
    let defaultLabel: String

    var body: some View {
        if let profiles {
            NavigationLink {
                ProfileList(title: title, selection: $selection, profiles: profiles, defaultLabel: defaultLabel)
            } label: {
                LabeledContent(title) {
                    if let selection, profiles.profile(named: selection) == nil {
                        Text("\(selection) — нет на Маке").foregroundStyle(Palette.orange)
                    } else {
                        Text(selection ?? defaultLabel).lineLimit(1)
                    }
                }
            }
        } else if unavailable {
            TextField(title, text: Binding(
                get: { selection ?? "" },
                set: { selection = normalizedProfile($0) }))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        } else {
            HStack {
                Text(title)
                Spacer()
                ProgressView()
            }
        }
    }
}

/// The profile choices with their descriptions (name in the row title).
private struct ProfileList: View {
    let title: String
    @Binding var selection: String?
    let profiles: MacProfiles
    let defaultLabel: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            row(name: defaultLabel, description: "", value: nil)
            ForEach(profiles.profiles) { profile in
                row(name: profile.name, description: profile.description, value: profile.name)
            }
            if let missing = selection, profiles.profile(named: missing) == nil {
                Section {
                    row(name: missing, description: "Нет на этом Маке: запуск будет отклонён (harness sync \(missing))",
                        value: missing)
                }
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func row(name: String, description: String, value: String?) -> some View {
        Button {
            selection = value
            dismiss()
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(name).foregroundStyle(Palette.text)
                    if !description.isEmpty {
                        Text(description).font(.system(size: 12)).foregroundStyle(Palette.meta)
                    }
                }
                Spacer()
                if selection == value { Image(systemName: "checkmark").foregroundStyle(Palette.tint) }
            }
            .frame(minHeight: Metrics.minTapTarget)
        }
    }
}

/// A profile badge for project rows: the name, orange when the Mac lacks it.
struct ProfileBadge: View {
    let profile: String
    let missing: Bool

    var body: some View {
        Label(profile, systemImage: missing ? "exclamationmark.triangle.fill" : "person.crop.circle")
            .labelStyle(.titleAndIcon)
            .lineLimit(1)
            .font(.system(size: 12, weight: .semibold, design: .monospaced))
            .accessibilityLabel(missing ? "Профиль \(profile) — нет на Маке" : "Профиль \(profile)")
            .foregroundStyle(missing ? Palette.orange : Palette.sec)
            .padding(.horizontal, 8)
            .frame(height: 22)
            .background(Palette.fill, in: Capsule())
    }
}

extension SessionLaunchMode {
    /// Russian label for pickers.
    var title: String {
        switch self {
        case .chat: return "Chat"
        case .brief: return "Brief"
        case .terminal: return "Terminal"
        }
    }

    var symbol: String {
        switch self {
        case .chat: return "bubble.left.and.text.bubble.right"
        case .brief: return "text.badge.checkmark"
        case .terminal: return "terminal"
        }
    }
}
