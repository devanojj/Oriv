//
//  ThemeContrastTests.swift
//  OrivTests
//
//  Guards the bug this theme layer exists to prevent: card surfaces that were a
//  hardcoded `Color.white` while the text on them used `UIColor.label`, which inverts.
//  In dark mode that produced near-white text on a white card.
//
//  These tests resolve each token under both trait collections and check the actual
//  contrast, so a future hardcoded colour fails here rather than in a screenshot.
//

import XCTest
import SwiftUI
import UIKit
@testable import Oriv

final class ThemeContrastTests: XCTestCase {

    private let light = UITraitCollection(userInterfaceStyle: .light)
    private let dark = UITraitCollection(userInterfaceStyle: .dark)

    // MARK: - Contrast helpers

    /// WCAG relative luminance.
    private func luminance(_ color: UIColor) -> CGFloat {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.getRed(&r, green: &g, blue: &b, alpha: &a)

        func channel(_ c: CGFloat) -> CGFloat {
            c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(r) + 0.7152 * channel(g) + 0.0722 * channel(b)
    }

    /// WCAG contrast ratio, 1.0 (identical) to 21.0 (black on white).
    private func contrastRatio(_ a: UIColor, _ b: UIColor) -> CGFloat {
        let l1 = luminance(a), l2 = luminance(b)
        let lighter = max(l1, l2), darker = min(l1, l2)
        return (lighter + 0.05) / (darker + 0.05)
    }

    private func resolve(_ color: Color, _ traits: UITraitCollection) -> UIColor {
        UIColor(color).resolvedColor(with: traits)
    }

    // MARK: - The original bug

    func testCardSurfaceAdaptsToColorScheme() {
        let lightCard = resolve(Theme.card, light)
        let darkCard = resolve(Theme.card, dark)

        XCTAssertNotEqual(lightCard, darkCard,
                          "Theme.card must not be a fixed colour — that was the original bug")
        XCTAssertGreaterThan(luminance(lightCard), 0.5, "Light card should be light")
        XCTAssertLessThan(luminance(darkCard), 0.1, "Dark card should be dark")
    }

    func testPrimaryTextIsReadableOnCardsInBothSchemes() {
        for (name, traits) in [("light", light), ("dark", dark)] {
            let card = resolve(Theme.card, traits)
            let text = resolve(Theme.textPrimary, traits)
            let ratio = contrastRatio(card, text)

            XCTAssertGreaterThanOrEqual(
                ratio, 4.5,
                "Primary text on a card fails WCAG AA in \(name) mode (ratio \(ratio))"
            )
        }
    }

    func testSecondaryTextIsReadableOnCardsInBothSchemes() {
        for (name, traits) in [("light", light), ("dark", dark)] {
            let card = resolve(Theme.card, traits)
            let text = resolve(Theme.textSecondary, traits)
            let ratio = contrastRatio(card, text)

            // Secondary text is intentionally quieter; AA large-text is the bar.
            XCTAssertGreaterThanOrEqual(
                ratio, 3.0,
                "Secondary text on a card is illegible in \(name) mode (ratio \(ratio))"
            )
        }
    }

    func testInsetCellsAreDistinguishableFromTheirCard() {
        for (name, traits) in [("light", light), ("dark", dark)] {
            let card = resolve(Theme.card, traits)
            let inset = resolve(Theme.cardInset, traits)

            XCTAssertNotEqual(card, inset,
                              "Vital cells must be visible against the card in \(name) mode")
        }
    }

    func testCanvasIsDistinguishableFromCards() {
        for (name, traits) in [("light", light), ("dark", dark)] {
            let canvas = resolve(Theme.canvas, traits)
            let card = resolve(Theme.card, traits)

            XCTAssertNotEqual(canvas, card,
                              "Cards must be visible against the canvas in \(name) mode")
        }
    }

    // MARK: - Band colours

    func testEveryBandColourIsReadableOnItsCardInBothSchemes() {
        for band in ReadinessBand.allCases {
            for (name, traits) in [("light", light), ("dark", dark)] {
                let card = resolve(Theme.card, traits)
                let tint = resolve(Theme.color(for: band), traits)
                let ratio = contrastRatio(card, tint)

                XCTAssertGreaterThanOrEqual(
                    ratio, 3.0,
                    "\(band.rawValue) band colour is illegible on a card in \(name) mode (ratio \(ratio))"
                )
            }
        }
    }

    func testBandColoursAdaptToColorScheme() {
        for band in ReadinessBand.allCases {
            XCTAssertNotEqual(
                resolve(Theme.color(for: band), light),
                resolve(Theme.color(for: band), dark),
                "\(band.rawValue) should be lifted in dark mode to hold contrast"
            )
        }
    }

    func testSubscoreColoursCoverTheFullRange() {
        // Every 0–100 subscore must map to a colour, and the mapping must change
        // across the band boundaries rather than returning one flat tint.
        let colours = Set((0...100).map { resolve(Theme.color(forSubscore: $0), light) })
        XCTAssertEqual(colours.count, 4, "Expected one colour per band")
    }
}
