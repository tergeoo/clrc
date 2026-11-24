import SwiftUI
import ClrcCore

/// Settings → GitLab: instance address and a personal access token
/// (scope `api`), checked with GET /user before it is kept.
struct GitLabSettingsView: View {
    @State private var url = GitLabCredentials.baseURL
    @State private var token = ""
    @State private var connectedAs: String?
    @State private var status: String?
    @State private var checking = false
    @State private var hasToken = GitLabCredentials.token() != nil

    var body: some View {
        Form {
            Section {
                TextField("https://gitlab.example.com", text: $url)
                    .font(.system(size: 15, design: .monospaced))
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField(hasToken ? "Токен сохранён — введите новый, чтобы заменить" : "Personal access token", text: $token)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            } header: {
                Text("GitLab")
            } footer: {
                Text("Токен с правом api. Хранится только в связке ключей этого iPhone.")
            }
            Section {
                Button {
                    Task { await check() }
                } label: {
                    if checking { ProgressView() } else { Text(hasToken && token.isEmpty ? "Проверить" : "Сохранить и проверить") }
                }
                .disabled(checking || url.trimmingCharacters(in: .whitespaces).isEmpty || (!hasToken && token.isEmpty))
                if let connectedAs {
                    Label("Подключено как \(connectedAs)", systemImage: "checkmark.circle.fill").foregroundStyle(Palette.green)
                }
                if let status {
                    Text(status).foregroundStyle(Palette.red).font(.system(size: 14))
                }
            }
            if hasToken {
                Section {
                    Button("Отключить GitLab", role: .destructive) {
                        GitLabCredentials.delete()
                        hasToken = false
                        connectedAs = nil
                    }
                }
            }
        }
        .navigationTitle("GitLab")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func check() async {
        checking = true
        defer { checking = false }
        status = nil
        connectedAs = nil
        // A saved token only goes to the host it was saved for: a new or
        // mistyped address needs the token typed again.
        let sameHost = GitLabAPI(baseURL: url, token: "x")?.baseURL.host == GitLabAPI(baseURL: GitLabCredentials.baseURL, token: "x")?.baseURL.host
        if token.isEmpty && !sameHost {
            status = "Для нового адреса введите токен ещё раз"
            return
        }
        let candidate = token.isEmpty ? (GitLabCredentials.token() ?? "") : token
        guard let api = GitLabAPI(baseURL: url, token: candidate), let client = GitLabClient(api: api) else {
            status = "Проверьте адрес GitLab и токен"
            return
        }
        do {
            let user = try await client.send(.user, as: GitLabUser.self)
            GitLabCredentials.baseURL = api.baseURL.absoluteString
            url = api.baseURL.absoluteString
            if !token.isEmpty, !GitLabCredentials.save(token: token) {
                status = "Не удалось сохранить токен в связке ключей"
                return
            }
            token = ""
            hasToken = true
            connectedAs = "\(user.name) (@\(user.username))"
        } catch {
            status = error.localizedDescription
        }
    }
}
