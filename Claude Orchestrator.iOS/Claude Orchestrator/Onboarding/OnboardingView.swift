import SwiftUI
import VisionKit
import ClrcCore

/// Why sign-in failed, as shown inline (spec 5.1).
enum SignInProblem: Equatable {
    case badURL
    case wrongPassword
    case rateLimited
    case unreachable
    case other(String)

    init(_ error: Error) {
        switch error as? AuthError {
        case .wrongPassword: self = .wrongPassword
        case .rateLimited: self = .rateLimited
        case .unreachable: self = .unreachable
        default: self = .other(error.localizedDescription)
        }
    }

    var passwordMessage: String? {
        switch self {
        case .wrongPassword: return "Неверный пароль. Проверьте пароль relay на Маке."
        case .rateLimited: return "Слишком много попыток. Подождите минуту."
        case .other(let text): return text
        case .badURL, .unreachable: return nil
        }
    }
}

/// Sign in (spec 5.1): QR first, manual entry second; inline errors.
struct OnboardingView: View {
    enum Step { case start, manual }

    @EnvironmentObject var authService: AuthService
    @EnvironmentObject var relay: RelayWebSocket
    @AppStorage("relay_server_url") private var serverURL = ""

    @State private var step: Step
    @State private var password = ""
    @State private var problem: SignInProblem?
    @State private var signingIn = false
    @State private var showScanner = false
    @FocusState private var focusedField: Field?

    private enum Field { case url, password }

    static var cameraAvailable: Bool { DataScannerViewController.isSupported && DataScannerViewController.isAvailable }

    init(step: Step? = nil, problem: SignInProblem? = nil) {
        _step = State(initialValue: step ?? (Self.cameraAvailable ? .start : .manual))
        _problem = State(initialValue: problem)
    }

    var body: some View {
        Group {
            switch step {
            case .start: start
            case .manual: manual
            }
        }
        .background(Palette.bg)
        .sheet(isPresented: $showScanner) {
            ScanToPairView { info in
                serverURL = info.relay
                password = info.password
                step = .manual
                Task { await signIn() }
            }
        }
    }

    // MARK: - Start

    private var start: some View {
        VStack(spacing: 0) {
            Spacer()
            VStack(spacing: 14) {
                AppMark()
                Text("clrc").font(.system(size: 34, weight: .bold))
                Text("Управляйте Claude Code на своём Маке с iPhone")
                    .font(.system(size: 17))
                    .foregroundStyle(Palette.sec)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 280)
            }
            Spacer()
            VStack(spacing: 12) {
                Button { showScanner = true } label: {
                    Label("Сканировать QR с Мака", systemImage: "qrcode.viewfinder")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, minHeight: 52)
                        .background(Palette.tint, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                Text("QR показывает установщик clrc на Маке")
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.meta)
                Button("Ввести вручную") { step = .manual }
                    .font(.system(size: 16, weight: .semibold))
                    .frame(minHeight: Metrics.minTapTarget)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
    }

    // MARK: - Manual

    private var manual: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if Self.cameraAvailable {
                        Button { step = .start } label: {
                            Label("Назад", systemImage: "chevron.left").font(.system(size: 16))
                        }
                        .frame(minHeight: Metrics.minTapTarget)
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Подключение вручную").font(.system(size: 28, weight: .bold))
                        Text("Адрес relay и пароль, которые показал установщик clrc на Маке.")
                            .font(.system(size: 15))
                            .foregroundStyle(Palette.sec)
                    }
                    if problem == .unreachable { unreachableCard }
                    field(title: "Relay URL", error: problem == .badURL ? "Проверьте адрес: например, http://192.168.1.5:8080" : nil) {
                        TextField("https://relay.home.lan", text: $serverURL)
                            .font(.system(size: 16, design: .monospaced))
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .textContentType(.URL)
                            .focused($focusedField, equals: .url)
                            .submitLabel(.next)
                            .onSubmit { focusedField = .password }
                    }
                    field(title: "Пароль", error: problem?.passwordMessage) {
                        SecureField("Пароль relay", text: $password)
                            .textContentType(.password)
                            .focused($focusedField, equals: .password)
                            .submitLabel(.go)
                            .onSubmit { Task { await signIn() } }
                    }
                }
                .padding(24)
            }
            .scrollDismissesKeyboard(.interactively)
            Button { Task { await signIn() } } label: {
                Group {
                    if signingIn { ProgressView().tint(.white) } else { Text("Войти") }
                }
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, minHeight: 52)
                .background(canSignIn ? Palette.tint : Palette.meta, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .disabled(!canSignIn)
            .padding(.horizontal, 24)
            .padding(.vertical, 10)
            .background(.bar)
        }
    }

    private var canSignIn: Bool { !signingIn && !password.isEmpty && !serverURL.trimmingCharacters(in: .whitespaces).isEmpty }

    private var unreachableCard: some View {
        HStack(spacing: 10) {
            StatusDot(color: Palette.red, size: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text("Мак или relay не отвечает").font(.system(size: 15, weight: .semibold))
                Text("Проверьте адрес и что Мак в сети.").font(.system(size: 13)).foregroundStyle(Palette.meta)
            }
            Spacer()
            Button("Повторить") { Task { await signIn() } }
                .font(.system(size: 14, weight: .semibold))
                .frame(minHeight: Metrics.minTapTarget)
        }
        .cardStyle()
    }

    private func field<F: View>(title: String, error: String?, @ViewBuilder content: () -> F) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.sec)
            content()
                .padding(.horizontal, 14)
                .frame(minHeight: 50)
                .background(Palette.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(error == nil ? Color.clear : Palette.red, lineWidth: 1.5)
                )
            if let error {
                Text(error).font(.system(size: 13)).foregroundStyle(Palette.red)
            }
        }
    }

    // MARK: - Sign in

    private func signIn() async {
        guard let url = RelayURL.normalize(serverURL) else {
            problem = .badURL
            return
        }
        serverURL = url.absoluteString
        problem = nil
        signingIn = true
        defer { signingIn = false }
        authService.updateRelayURL(url)
        relay.updateRelayURL(url)
        do {
            try await authService.login(password: password)
            relay.connect()
        } catch {
            problem = SignInProblem(error)
        }
    }
}

/// The app's mark on the sign-in screen.
private struct AppMark: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 22, style: .continuous)
            .fill(Palette.code)
            .frame(width: 96, height: 96)
            .overlay(
                Text(">_")
                    .font(.system(size: 36, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color(hex: 0x0A84FF))
            )
            .accessibilityHidden(true)
    }
}
