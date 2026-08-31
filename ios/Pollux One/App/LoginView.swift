import SwiftUI

/// Minimal auth stub — Web is the primary console; iOS just needs to know
/// who's signed in well enough to pull their scripts. Swaps for a real
/// Supabase-auth flow behind the same `AppEnvironment.signIn`.
struct LoginView: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var email = ""
    @State private var password = ""
    @State private var errorMessage: String?
    @State private var isSigningIn = false

    var body: some View {
        VStack(spacing: 16) {
            Text("Pollux One")
                .font(.system(size: 28, weight: .bold, design: .rounded))

            Text("Camera first. Teleprompter second.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            VStack(spacing: 10) {
                TextField("Email", text: $email)
                    .textContentType(.username)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField("Password", text: $password)
                    .textContentType(.password)
            }
            .textFieldStyle(.roundedBorder)
            .padding(.top, 12)

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            Button {
                Task { await signIn() }
            } label: {
                if isSigningIn {
                    ProgressView()
                } else {
                    Text("Continue")
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(email.isEmpty || password.isEmpty || isSigningIn)
        }
        .padding(32)
    }

    private func signIn() async {
        isSigningIn = true
        defer { isSigningIn = false }
        do {
            try await environment.signIn(email: email, password: password)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
