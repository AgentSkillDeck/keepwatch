import AppKit
import SwiftUI

/// Colours and small building blocks shared by the menu and the dashboard.
/// The teal is the awake light in the app icon.
enum Brand {
    /// Icon teal in dark mode, a deeper teal in light mode so text on it stays legible.
    static let teal = dynamic(light: NSColor(red: 0.04, green: 0.55, blue: 0.52, alpha: 1),
                              dark: NSColor(red: 0.18, green: 0.90, blue: 0.81, alpha: 1))
    static let navy = Color(red: 0.05, green: 0.09, blue: 0.25)
    static let live = Color(red: 1.0, green: 0.27, blue: 0.23)

    private static func dynamic(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }
}

/// A rounded panel with a hairline border.
struct Panel<Content: View>: View {
    var padding: CGFloat = 14
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(padding)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.separator.opacity(0.6)))
    }
}

/// An SF Symbol in a tinted rounded square, then a title and an optional subtitle.
struct SectionHeader: View {
    var icon: String
    var title: String
    var subtitle: String?
    var tint: Color = Brand.teal

    /// A heading, not a row: a small inline icon, bold title and a rule
    /// under it, so it can't be mistaken for one of the switches below.
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: icon).font(.system(size: 13, weight: .semibold)).foregroundStyle(tint)
                Text(title).font(.system(size: 15, weight: .bold, design: .rounded))
                if let subtitle { Text(subtitle).font(.caption).foregroundStyle(.secondary) }
            }
            Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 1)
        }
    }
}

struct IconBadge: View {
    var icon: String
    var tint: Color = Brand.teal
    var size: CGFloat = 28

    var body: some View {
        Image(systemName: icon)
            .font(.system(size: size * 0.5, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .background(tint.opacity(0.15), in: RoundedRectangle(cornerRadius: size * 0.28, style: .continuous))
    }
}

/// Small uppercase label above a group of controls.
struct Eyebrow: View {
    var text: String
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .semibold, design: .rounded))
            .tracking(0.8)
            .foregroundStyle(.secondary)
    }
}

/// A selectable tile: a big value and a small caption.
struct TileButtonStyle: ButtonStyle {
    var selected: Bool
    var height: CGFloat = 44

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(maxWidth: .infinity, minHeight: height)
            .foregroundStyle(selected ? Color.black.opacity(0.85) : Color.primary)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(selected ? AnyShapeStyle(Brand.teal) : AnyShapeStyle(.quaternary.opacity(configuration.isPressed ? 1 : 0.6)))
            )
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(selected ? Color.clear : Color.primary.opacity(0.06)))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
            .contentShape(Rectangle())
    }
}

/// A small capsule button that hugs its label, for rows of choices.
struct ChipButtonStyle: ButtonStyle {
    var selected: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold, design: .rounded))
            .padding(.horizontal, 12).frame(minWidth: 44, minHeight: 28)
            .foregroundStyle(selected ? Color.black.opacity(0.85) : Color.primary)
            .background(Capsule().fill(selected ? AnyShapeStyle(Brand.teal)
                                                : AnyShapeStyle(Color.primary.opacity(configuration.isPressed ? 0.14 : 0.07))))
            .overlay(Capsule().strokeBorder(selected ? Color.clear : Color.primary.opacity(0.06)))
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
            .contentShape(Capsule())
    }
}

/// A capsule showing whether the mic or camera is live.
struct StatusChip: View {
    var on: Bool
    var onIcon: String
    var offIcon: String
    var label: String

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: on ? onIcon : offIcon).font(.system(size: 11, weight: .semibold))
            Text(on ? "\(label) live" : "\(label) off").font(.system(size: 12, weight: .medium))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .foregroundStyle(on ? Brand.live : Color.secondary)
        .background((on ? Brand.live.opacity(0.14) : Color.primary.opacity(0.06)), in: Capsule())
        .accessibilityElement(children: .combine)
    }
}

/// The status orb: an eye in a ring. The ring fills with the time left in a
/// timed session and glows teal while the Mac is held awake.
struct StatusOrb: View {
    var icon: String
    var active: Bool
    /// 0...1 time left of a timed session, or nil for no ring progress.
    var progress: Double?
    var size: CGFloat = 46

    var body: some View {
        ZStack {
            Circle().fill(active ? Brand.teal.opacity(0.16) : Color.primary.opacity(0.06))
            Circle().strokeBorder(Color.primary.opacity(0.08), lineWidth: 3)
            if active {
                Circle()
                    .inset(by: 1.5)
                    .trim(from: 0, to: progress ?? 1)
                    .stroke(Brand.teal, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            Image(systemName: icon)
                .font(.system(size: size * 0.38, weight: .semibold))
                .foregroundStyle(active ? Brand.teal : Color.secondary)
        }
        .frame(width: size, height: size)
        .shadow(color: active ? Brand.teal.opacity(0.35) : .clear, radius: 8)
    }
}

/// A big value with a caption, for the dashboard summary. Every tile uses
/// the same three rows (icon, value, caption) so tiles line up across a row.
struct StatTile<Icon: View>: View {
    var value: String
    var caption: String
    var tint: Color = Brand.teal
    @ViewBuilder var icon: Icon

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            icon.frame(height: 24, alignment: .leading)
            Spacer(minLength: 6)
            Text(value)
                .font(.system(size: 22, weight: .semibold, design: .rounded)).monospacedDigit()
                .foregroundStyle(tint == Brand.teal ? Color.primary : tint)
                .lineLimit(1).minimumScaleFactor(0.6)
            Text(caption).font(.caption).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
                .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(12)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

extension StatTile where Icon == TileSymbol {
    init(value: String, caption: String, icon: String, tint: Color = Brand.teal) {
        self.init(value: value, caption: caption, tint: tint) { TileSymbol(name: icon, tint: tint) }
    }
}

struct TileSymbol: View {
    var name: String
    var tint: Color
    var body: some View {
        Image(systemName: name).font(.system(size: 15, weight: .semibold)).foregroundStyle(tint)
    }
}

/// A teal on/off switch that looks the same in every window state.
struct BrandSwitchStyle: ToggleStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                Capsule()
                    .fill(configuration.isOn ? AnyShapeStyle(Brand.teal) : AnyShapeStyle(Color.primary.opacity(0.14)))
                    .frame(width: 38, height: 22)
                Circle()
                    .fill(.white)
                    .shadow(color: .black.opacity(0.25), radius: 1.5, y: 1)
                    .frame(width: 18, height: 18)
                    .padding(2)
                    .overlay {
                        if configuration.isOn {
                            Image(systemName: "checkmark").font(.system(size: 8, weight: .heavy)).foregroundStyle(Brand.teal)
                        }
                    }
            }
            .animation(.snappy(duration: 0.18), value: configuration.isOn)
            .opacity(isEnabled ? 1 : 0.4)
        }
        .buttonStyle(.plain)
        .accessibilityRepresentation { Toggle(isOn: configuration.$isOn) { configuration.label } }
    }
}

/// A monogram badge for an agent CLI. Original art: a coloured tile with
/// letters, never a vendor's logo.
struct AgentBadge: View {
    var name: String
    var count = 1
    var size: CGFloat = 24

    static let styles: [String: (String, Color)] = [
        "Claude Code": ("CC", Color(red: 0.85, green: 0.47, blue: 0.34)),
        "Codex": ("Cx", Color(red: 0.20, green: 0.62, blue: 0.47)),
        "Gemini CLI": ("Ge", Color(red: 0.30, green: 0.50, blue: 0.95)),
        "Aider": ("Ai", Color(red: 0.55, green: 0.40, blue: 0.85)),
        "OpenCode": ("OC", Color(red: 0.35, green: 0.35, blue: 0.40)),
        "Goose": ("Gs", Color(red: 0.90, green: 0.70, blue: 0.20)),
        "Amp": ("Am", Color(red: 0.90, green: 0.30, blue: 0.45)),
        "Cursor Agent": ("Cu", Color(red: 0.25, green: 0.25, blue: 0.30)),
        "Qwen Code": ("Qw", Color(red: 0.45, green: 0.35, blue: 0.95)),
        "Crush": ("Cr", Color(red: 0.95, green: 0.45, blue: 0.70)),
    ]

    var body: some View {
        let style = Self.styles[name] ?? (String(name.prefix(2)), Color.gray)
        Text(style.0)
            .font(.system(size: size * 0.42, weight: .heavy, design: .rounded))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(style.1.gradient, in: RoundedRectangle(cornerRadius: size * 0.3, style: .continuous))
            .overlay(alignment: .topTrailing) {
                if count > 1 {
                    Text(String(count))
                        .font(.system(size: size * 0.36, weight: .bold, design: .rounded))
                        .foregroundStyle(.black.opacity(0.85))
                        .padding(.horizontal, 3)
                        .frame(minWidth: size * 0.5, minHeight: size * 0.5)
                        .background(Brand.teal, in: Capsule())
                        .offset(x: size * 0.25, y: -size * 0.25)
                }
            }
            .help(count > 1 ? "\(name): \(count) sessions" : name)
            .accessibilityLabel(count > 1 ? "\(name), \(count) sessions" : name)
    }
}

/// Agent badges in a row, one per agent with its session count.
struct AgentBadges: View {
    var agents: [String: Int]
    var size: CGFloat = 22

    var body: some View {
        HStack(spacing: size * 0.45) {
            ForEach(agents.keys.sorted(), id: \.self) { AgentBadge(name: $0, count: agents[$0] ?? 1, size: size) }
        }
        .padding(.top, size * 0.25)
        .padding(.trailing, size * 0.25)
    }
}
