//
//  ProfileView.swift
//  Oriv
//
//  The app's first settings surface. Reached from the toolbar in ContentView.
//
//  Account deletion is intentionally absent in M1 — it lands in M2 with the Edge Function
//  that can actually perform it. Guideline 5.1.1(v) makes it mandatory before any release
//  that ships accounts; see AUTH_DESIGN.md §8.
//

import SwiftUI

struct ProfileView: View {
    let auth: AuthManager

    @Environment(\.dismiss) private var dismiss
    @State private var isConfirmingSignOut = false

    private static let memberFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .long
        formatter.timeStyle = .none
        return formatter
    }()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    switch auth.state {
                    case .signedIn(let user):
                        accountCard(user)
                        signOutButton
                    default:
                        anonymousCard
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 32)
            }
            .background(Theme.canvas)
            .scrollContentBackground(.hidden)
            .navigationTitle("Account")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Theme.canvas, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                }
            }
        }
    }

    // MARK: - Signed in

    private func accountCard(_ user: UserProfile) -> some View {
        VStack(spacing: 0) {
            VStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(Theme.good.opacity(0.12))
                        .frame(width: 72, height: 72)

                    Text(initials(for: user))
                        .font(.system(size: 26, weight: .bold, design: .rounded))
                        .foregroundStyle(Theme.good)
                }

                if let name = user.displayName {
                    Text(name)
                        .font(.system(size: 19, weight: .bold, design: .rounded))
                        .foregroundStyle(Theme.textPrimary)
                }
            }
            .padding(.top, 26)
            .padding(.bottom, 22)

            Divider().overlay(Theme.cardBorder)

            row("Email", user.email ?? "Hidden")
            Divider().overlay(Theme.cardBorder).padding(.leading, 18)
            row("Signed in with", user.signInMethod.displayName)
            Divider().overlay(Theme.cardBorder).padding(.leading, 18)
            row("Member since", Self.memberFormatter.string(from: user.createdAt))
        }
        .frame(maxWidth: .infinity)
        .orivCard()
    }

    private var signOutButton: some View {
        Button(role: .destructive) {
            isConfirmingSignOut = true
        } label: {
            Text("Sign Out")
                .font(.system(size: 16, weight: .semibold, design: .rounded))
                .foregroundStyle(Theme.poor)
                .frame(maxWidth: .infinity)
                .frame(height: 52)
                .orivCard(cornerRadius: 16)
        }
        .buttonStyle(.plain)
        .disabled(auth.isBusy)
        .confirmationDialog(
            "Sign out of Oriv?",
            isPresented: $isConfirmingSignOut,
            titleVisibility: .visible
        ) {
            Button("Sign Out", role: .destructive) {
                Task {
                    await auth.signOut()
                    dismiss()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your Health data stays on this device and is not affected.")
        }
    }

    // MARK: - Anonymous

    private var anonymousCard: some View {
        VStack(spacing: 20) {
            ZStack {
                Circle()
                    .fill(Theme.good.opacity(0.12))
                    .frame(width: 88, height: 88)

                Image(systemName: "person.crop.circle.badge.plus")
                    .font(.system(size: 34, weight: .medium))
                    .foregroundStyle(Theme.good)
            }

            VStack(spacing: 8) {
                Text("No Account")
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.textPrimary)

                Text("You're using Oriv without an account. Everything works, but your history lives only on this device.")
                    .font(.system(size: 14, weight: .medium, design: .rounded))
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
            }

            Button {
                auth.presentSignIn()
                dismiss()
            } label: {
                Text("Sign In")
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                    .background(Theme.good)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 34)
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity)
        .orivCard()
    }

    // MARK: - Helpers

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 14, weight: .medium, design: .rounded))
                .foregroundStyle(Theme.textSecondary)

            Spacer(minLength: 12)

            Text(value)
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .foregroundStyle(Theme.textPrimary)
                .multilineTextAlignment(.trailing)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    private func initials(for user: UserProfile) -> String {
        if let name = user.displayName, !name.isEmpty {
            let parts = name.split(separator: " ").prefix(2)
            let letters = parts.compactMap { $0.first.map(String.init) }
            if !letters.isEmpty { return letters.joined().uppercased() }
        }
        if let first = user.email?.first { return String(first).uppercased() }
        return "?"
    }
}

#Preview("Anonymous") {
    ProfileView(auth: AuthManager(service: InMemoryAuthService(), sessionStore: InMemorySessionStore()))
}
