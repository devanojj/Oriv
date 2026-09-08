//
//  Theme.swift
//  Oriv
//
//  Semantic colour tokens. Every surface colour in the app resolves through here so
//  that light and dark mode are defined together in one place and can't drift apart.
//
//  Previously the cards were a hardcoded `Color.white` while the text used
//  `Color(uiColor: .label)`, which inverts — producing near-white text on a white card
//  in dark mode. Defining both halves of every token side by side is what prevents that
//  class of bug from coming back.
//

import SwiftUI
import UIKit

public enum Theme {

    // MARK: - Surfaces

    /// App background behind all cards.
    public static let canvas = dynamic(
        light: rgb(0.97, 0.97, 0.98),
        dark: rgb(0.055, 0.055, 0.07)
    )

    /// Elevated card surface (hero card, vitals card).
    public static let card = dynamic(
        light: rgb(1.0, 1.0, 1.0),
        dark: rgb(0.105, 0.105, 0.125)
    )

    /// Recessed surface nested *inside* a card (individual vital cells).
    public static let cardInset = dynamic(
        light: rgb(0.97, 0.97, 0.98),
        dark: rgb(0.155, 0.155, 0.18)
    )

    /// Hairline border used in place of a drop shadow in dark mode.
    public static let cardBorder = dynamic(
        light: rgb(0.0, 0.0, 0.0, alpha: 0.04),
        dark: rgb(1.0, 1.0, 1.0, alpha: 0.09)
    )

    /// Neutral track for progress bars.
    public static let track = dynamic(
        light: rgb(0.0, 0.0, 0.0, alpha: 0.07),
        dark: rgb(1.0, 1.0, 1.0, alpha: 0.13)
    )

    // MARK: - Text

    public static let textPrimary = Color(uiColor: .label)
    public static let textSecondary = Color(uiColor: .secondaryLabel)
    public static let textTertiary = Color(uiColor: .tertiaryLabel)
    public static let textQuaternary = Color(uiColor: .quaternaryLabel)

    // MARK: - Band / accent colours
    //
    // Dark-mode variants are lifted in luminance so they hold contrast against the dark
    // card surface; light-mode variants are darkened so they hold contrast against white.
    // `ThemeContrastTests` asserts every one of these clears WCAG AA in both schemes —
    // the first draft of this palette failed it at 2.5:1 for amber on a white card.

    public static let ready = dynamic(
        light: rgb(0.07, 0.58, 0.47),
        dark: rgb(0.24, 0.88, 0.72)
    )

    public static let good = dynamic(
        light: rgb(0.20, 0.50, 0.94),
        dark: rgb(0.42, 0.70, 1.0)
    )

    public static let fair = dynamic(
        light: rgb(0.72, 0.47, 0.04),
        dark: rgb(1.0, 0.78, 0.32)
    )

    public static let poor = dynamic(
        light: rgb(0.86, 0.24, 0.24),
        dark: rgb(1.0, 0.45, 0.43)
    )

    public static let warning = dynamic(
        light: rgb(0.70, 0.40, 0.02),
        dark: rgb(1.0, 0.70, 0.25)
    )

    // MARK: - Gradients

    public static func gradient(for band: ReadinessBand) -> LinearGradient {
        let base = color(for: band)
        return LinearGradient(
            colors: [base, base.opacity(0.72)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    public static func color(for band: ReadinessBand) -> Color {
        switch band {
        case .ready: return ready
        case .good:  return good
        case .fair:  return fair
        case .poor:  return poor
        }
    }

    /// Colour for a 0–100 subscore, used by the vital cell bars.
    public static func color(forSubscore subscore: Int) -> Color {
        switch subscore {
        case 75...100: return ready
        case 50...74:  return good
        case 30...49:  return fair
        default:       return poor
        }
    }

    // MARK: - Construction helpers

    private static func rgb(_ r: Double, _ g: Double, _ b: Double, alpha: Double = 1.0) -> UIColor {
        UIColor(red: r, green: g, blue: b, alpha: alpha)
    }

    private static func dynamic(light: UIColor, dark: UIColor) -> Color {
        Color(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark ? dark : light
        })
    }
}

// MARK: - Card styling

/// Standard Oriv card chrome: rounded surface, hairline border, and a drop shadow that
/// is suppressed in dark mode (where shadows read as smudges rather than elevation).
public struct CardBackground: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme

    var cornerRadius: CGFloat = 20

    public func body(content: Content) -> some View {
        content
            .background(Theme.card)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Theme.cardBorder, lineWidth: 1)
            )
            .shadow(
                color: .black.opacity(colorScheme == .dark ? 0 : 0.05),
                radius: 10, x: 0, y: 4
            )
    }
}

public extension View {
    func orivCard(cornerRadius: CGFloat = 20) -> some View {
        modifier(CardBackground(cornerRadius: cornerRadius))
    }
}
