import SwiftUI
import UIKit

extension View {
    /// v2.5.1 — number/decimal pads have NO return key on iPhone, so a stuck
    /// keyboard had no way out. This adds a "Done" button above EVERY keyboard
    /// on the screen plus swipe-to-dismiss while scrolling. Apply once per
    /// screen (on the Form/List).
    func keyboardDismissBar() -> some View {
        self
            .scrollDismissesKeyboard(.interactively)
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") {
                        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder),
                                                        to: nil, from: nil, for: nil)
                    }
                }
            }
    }
}

/// ORDnet design system, translated from the extension's CSS custom properties.
/// Light: warm paper (#fcfaf5) with near-black ink. Dark: deep night (#0a0a0f).
enum Theme {
    static let accent = Color.primary

    /// ORDnet beige (#fbf9f2) in light mode, deep night (#0a0a0f) in dark mode
    static func bgPrimary(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(red: 0.039, green: 0.039, blue: 0.059) : Color(red: 251/255, green: 249/255, blue: 242/255)
    }
    static func bgSecondary(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(red: 0.071, green: 0.071, blue: 0.102) : Color(red: 0.961, green: 0.953, blue: 0.929)
    }
    static let statusGreen = Color(red: 0.133, green: 0.773, blue: 0.369)
    static let statusRed = Color(red: 0.937, green: 0.267, blue: 0.267)
    static let statusYellow = Color(red: 0.918, green: 0.702, blue: 0.031)
    static let statusBlue = Color(red: 0.231, green: 0.510, blue: 0.965)
    static let bsvmapOrange = Color(red: 0.969, green: 0.576, blue: 0.118)
}

struct CardBackground: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    func body(content: Content) -> some View {
        content
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(scheme == .dark ? Color.white.opacity(0.04) : Color.white.opacity(0.85))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(scheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.08))
            )
    }
}

extension View {
    func card() -> some View { modifier(CardBackground()) }
    /// ORDnet beige page background — replaces the default grouped-list grey
    func ordnetBackground() -> some View { modifier(OrdnetBackground()) }
}

struct OrdnetBackground: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    func body(content: Content) -> some View {
        content
            .scrollContentBackground(.hidden)
            .background(Theme.bgPrimary(scheme).ignoresSafeArea())
    }
}

/// ORDnet secondary button: beige fill (app background) + ink outline.
/// The primary action (Send etc.) keeps .borderedProminent (black).
/// Capsule (border-radius: 999px) is the ORDnet signature shape — outline
/// buttons get exactly the same geometry as the prominent (black) buttons.
struct OrdnetOutlineLabel: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    var pressed = false
    func body(content: Content) -> some View {
        content
            .font(.callout.weight(.medium))
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .frame(minHeight: 36)
            .background(Capsule().fill(Theme.bgPrimary(scheme)))
            .overlay(Capsule().strokeBorder(Color.primary, lineWidth: 1.5))
            .foregroundStyle(Color.primary)
            .opacity(pressed ? 0.55 : 1)
            .contentShape(Capsule())
    }
}

struct OrdnetOutlineButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .modifier(OrdnetOutlineLabel(pressed: configuration.isPressed))
    }
}

extension ButtonStyle where Self == OrdnetOutlineButtonStyle {
    static var ordnetOutline: OrdnetOutlineButtonStyle { OrdnetOutlineButtonStyle() }
}

/// black capsule — identical geometry to the outline style, so Send / Receive /
/// History line up pixel-perfect
struct OrdnetProminentButtonStyle: ButtonStyle {
    @Environment(\.colorScheme) private var scheme
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout.weight(.semibold))
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .frame(minHeight: 36)
            .background(Capsule().fill(Color.primary))
            .foregroundStyle(Theme.bgPrimary(scheme))
            .opacity(configuration.isPressed ? 0.7 : 1)
            .contentShape(Capsule())
    }
}

extension ButtonStyle where Self == OrdnetProminentButtonStyle {
    static var ordnetProminent: OrdnetProminentButtonStyle { OrdnetProminentButtonStyle() }
}

extension View {
    /// same look for controls that are not plain Buttons (e.g. PhotosPicker labels)
    func ordnetOutlineLabel() -> some View { modifier(OrdnetOutlineLabel()) }
}

/// inline alert — errors are ALWAYS shown inline, never as popups
struct InlineAlert: View {
    enum Kind { case error, success, warning }
    var kind: Kind
    var text: String

    var color: Color {
        switch kind {
        case .error: return Theme.statusRed
        case .success: return Theme.statusGreen
        case .warning: return Theme.statusYellow
        }
    }
    var icon: String {
        switch kind {
        case .error: return "exclamationmark.triangle"
        case .success: return "checkmark.circle"
        case .warning: return "exclamationmark.circle"
        }
    }

    var body: some View {
        if !text.isEmpty {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: icon).font(.footnote)
                Text(text)
                    .font(.footnote)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                Spacer(minLength: 0)
            }
            .foregroundStyle(color)
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10).fill(color.opacity(0.1)))
        }
    }
}

/// key/value row — port of the extension's .kv rows
struct KVRow: View {
    var k: String
    var v: String
    var mono = false

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(k)
                .font(.footnote)
                .foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(v)
                .font(mono ? .footnote.monospaced() : .footnote)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
        .padding(.vertical, 2)
    }
}

/// status pill for holdings (held / listed / contract)
struct StatusPill: View {
    var holding: Holding

    var body: some View {
        if holding.isListed {
            HStack(spacing: 3) {
                Image(systemName: "tag").font(.system(size: 9))
                if let p = holding.priceSat, p > 0 {
                    Text("\(Fmt.bsv(p)) BSV")
                }
            }
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(Capsule().fill(Theme.statusGreen.opacity(0.15)))
            .foregroundStyle(Theme.statusGreen)
        } else if let usd = holding.domainListedUsd {
            // v2.6.1 — listed on the DOMAIN registry (Domains tab, USD)
            HStack(spacing: 3) {
                Image(systemName: "tag").font(.system(size: 9))
                Text(usd > 0 ? String(format: "For sale · $%.0f", usd) : "For sale")
            }
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(Capsule().fill(Theme.statusGreen.opacity(0.15)))
            .foregroundStyle(Theme.statusGreen)
        } else {
            Text(holding.status)
                .font(.caption2.weight(.semibold))
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(Capsule().fill(Color.secondary.opacity(0.12)))
                .foregroundStyle(.secondary)
        }
    }
}

/// ORD/plug segmented-donut "C" logo (port of the SNS mark SVG)
struct OrdplugLogo: View {
    var size: CGFloat = 44
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
                .fill(Color(red: 0.039, green: 0.039, blue: 0.039))
            Circle()
                .stroke(Color(red: 0.988, green: 0.980, blue: 0.961), lineWidth: size * 0.18)
                .frame(width: size * 0.5, height: size * 0.5)
            // segmentation lines
            Group {
                Rectangle().frame(width: size * 0.07, height: size * 0.44).offset(x: -size * 0.04, y: -size * 0.22)
                Rectangle().frame(width: size * 0.46, height: size * 0.07).offset(x: size * 0.23, y: -size * 0.02)
                Rectangle().frame(width: size * 0.07, height: size * 0.33)
                    .rotationEffect(.degrees(-45))
                    .offset(x: size * 0.17, y: size * 0.17)
            }
            .foregroundStyle(Color(red: 0.039, green: 0.039, blue: 0.039))
        }
        .frame(width: size, height: size)
    }
}
