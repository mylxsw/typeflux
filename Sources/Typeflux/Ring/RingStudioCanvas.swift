import AppKit
import SwiftUI

/// A key the studio canvas reacts to while it has focus.
enum RingStudioKey: Equatable {
    case previous
    case next
    case movePrevious
    case moveNext
    case delete
    case edit
    case insert
    case escape
    case select(Int)
}

/// Settings → Ring's editor: the ring as it will look, on a dark desktop. Click ⊕ to insert there,
/// click a slice to edit it, drag a slice to move it, or try it without running anything.
struct RingStudioCanvas: View {
    enum Mode: Equatable {
        case overview
        case editing
        case inserting
        case replacing
    }

    static let size: CGFloat = 380
    static let warm = Color(red: 1, green: 0.77, blue: 0.34)
    static let selectionBlue = Color(red: 0.35, green: 0.69, blue: 1)

    let slots: [RingStudioSlot]
    let selectedIndex: Int?
    let mode: Mode
    let style: RingStyle
    let centerTitle: String
    let actionCount: Int
    let insertionIndexes: [Int]
    /// Slices whose target is gone; drawn dimmed with a dot.
    let issues: Set<UUID>
    @Binding var drag: RingStudioLayout.Drag?
    @Binding var isTrying: Bool
    var onInsert: (Int) -> Void = { _ in }
    var onSelect: (UUID) -> Void = { _ in }
    var onMove: (UUID, Int) -> Void = { _, _ in }
    var onBackground: () -> Void = {}
    var onKey: (RingStudioKey) -> Void = { _ in }

    @State private var pressedIndex: Int?
    @State private var tryIndex: Int?
    @FocusState private var focused: Bool

    private var geometry: RingPreviewGeometry {
        RingPreviewGeometry(size: Self.size, count: slots.count)
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar.padding(.horizontal, 12).padding(.top, 10)
            ZStack {
                gestureLayer
                RingStudioRing(slots: slots, highlighted: isTrying ? tryIndex : selectedIndex, isTrying: isTrying,
                               style: style, centerTitle: centerTitle, actionCount: actionCount, issues: issues,
                               size: Self.size)
                    .allowsHitTesting(false)
                insertionButtons
            }
            .frame(width: Self.size, height: Self.size)
            Spacer(minLength: 0)
            Text(hint)
                .font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.72))
                .multilineTextAlignment(.center).lineLimit(2)
                .padding(.horizontal, 16).padding(.bottom, 12)
                .accessibilityHidden(true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Self.desktop)
        .environment(\.colorScheme, .dark)
        .focusable()
        .focused($focused)
        .onMoveCommand { direction in
            switch direction {
            case .left, .up: onKey(.previous)
            case .right, .down: onKey(.next)
            @unknown default: break
            }
        }
        .onDeleteCommand { onKey(.delete) }
        .onExitCommand {
            if isTrying {
                isTrying = false
            } else {
                onKey(.escape)
            }
        }
        .modifier(RingStudioKeyPresses(onKey: onKey))
        .onChange(of: isTrying) { _ in tryIndex = nil }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L("ring.studio.accessibility"))
        .accessibilityIdentifier("ring.studio.canvas")
    }

    /// A wallpaper-like backdrop, so Frosted and Liquid Glass look as they do on screen.
    static var desktop: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.11, green: 0.18, blue: 0.36),
                                    Color(red: 0.06, green: 0.23, blue: 0.2)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            RadialGradient(colors: [Color(red: 0.36, green: 0.48, blue: 0.84).opacity(0.85), .clear],
                           center: UnitPoint(x: 0.8, y: 0.05), startRadius: 0, endRadius: 320)
            RadialGradient(colors: [Color(red: 0.18, green: 0.56, blue: 0.42).opacity(0.8), .clear],
                           center: UnitPoint(x: 0, y: 1), startRadius: 0, endRadius: 300)
            LinearGradient(colors: [.clear, .black.opacity(0.25)], startPoint: .center, endPoint: .bottom)
        }
    }

    // MARK: - Chrome

    private var topBar: some View {
        HStack(spacing: 8) {
            let full = actionCount >= RingConfiguration.maxActions
            chip(full ? L("ring.studio.full", actionCount, RingConfiguration.maxActions)
                : L("ring.studio.capacity", actionCount, RingConfiguration.maxActions,
                    RingConfiguration.maxActions - actionCount),
                systemImage: full ? "exclamationmark.triangle" : nil, tint: full ? Self.warm : nil)
            Spacer(minLength: 8)
            Button {
                isTrying.toggle()
                focused = true
            } label: {
                chip(L(isTrying ? "ring.studio.stopTrying" : "ring.studio.try"),
                     systemImage: isTrying ? "xmark" : "play.fill", tint: isTrying ? Self.warm : nil)
            }
            .buttonStyle(.plain)
            .disabled(actionCount == 0)
            .help(L("ring.studio.tryHelp"))
            .accessibilityIdentifier("ring.studio.try")
        }
    }

    private func chip(_ title: String, systemImage: String?, tint: Color?) -> some View {
        HStack(spacing: 5) {
            if let systemImage {
                Image(systemName: systemImage).font(.system(size: 9.5, weight: .bold))
            }
            Text(title).font(.system(size: 11.5, weight: .medium)).monospacedDigit()
        }
        .foregroundStyle(tint ?? .white.opacity(0.9))
        .padding(.horizontal, 10).frame(height: 24)
        .background(Capsule().fill(tint.map { $0.opacity(0.2) } ?? Color.black.opacity(0.35)))
        .overlay(Capsule().strokeBorder(tint.map { $0.opacity(0.6) } ?? Color.white.opacity(0.16), lineWidth: 0.5))
    }

    private var hint: String {
        if isTrying {
            guard let tryIndex, slots.indices.contains(tryIndex) else { return L("ring.studio.hint.try") }
            let action = slots[tryIndex].action
            return issues.contains(action.id) ? L("ring.studio.hint.tryBroken", action.title)
                : L("ring.studio.hint.tryRuns", action.title)
        }
        switch mode {
        case .inserting, .replacing: return L("ring.studio.hint.library")
        case .editing: return L("ring.studio.hint.editing")
        case .overview: return actionCount == 0 ? "" : L("ring.studio.hint.overview")
        }
    }

    // MARK: - Pointer

    private var gestureLayer: some View {
        Color.clear
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged(dragChanged)
                .onEnded(dragEnded))
            .onContinuousHover { phase in
                guard isTrying else { return }
                if case let .active(location) = phase {
                    let index = geometry.index(at: location)
                    if index != tryIndex {
                        tryIndex = index
                    }
                } else {
                    tryIndex = nil
                }
            }
    }

    private func dragChanged(_ value: DragGesture.Value) {
        guard !isTrying else { return }
        if drag == nil, pressedIndex == nil {
            pressedIndex = geometry.index(at: value.startLocation) ?? -1
        }
        let moved = hypot(value.translation.width, value.translation.height) > 6
        if drag == nil, moved, mode == .overview || mode == .editing, let pressedIndex,
           slots.indices.contains(pressedIndex), slots[pressedIndex].role == .action {
            drag = RingStudioLayout.Drag(id: slots[pressedIndex].id, destination: pressedIndex)
        }
        if var current = drag {
            let destination = geometry.nearestIndex(to: value.location)
            if destination != current.destination {
                current.destination = destination
                drag = current
            }
        }
    }

    private func dragEnded(_: DragGesture.Value) {
        defer { pressedIndex = nil }
        focused = true
        if isTrying {
            return
        }
        if let current = drag {
            drag = nil
            onMove(current.id, current.destination)
            return
        }
        if let pressedIndex, slots.indices.contains(pressedIndex), slots[pressedIndex].role == .action {
            onSelect(slots[pressedIndex].id)
        } else {
            onBackground()
        }
    }

    // MARK: - ⊕

    @ViewBuilder private var insertionButtons: some View {
        if !isTrying, drag == nil {
            let rim = RingPreviewGeometry(size: Self.size, count: actionCount)
            ForEach(insertionIndexes, id: \.self) { index in
                RingInsertionButton(position: index + 1,
                                    direction: RingSettingsPresentation.direction(of: index, count: actionCount + 1)) {
                    onInsert(index)
                }
                .position(rim.insertionPoint(for: index))
            }
        }
    }
}

/// ⊕ on the rim between two slices.
struct RingInsertionButton: View {
    let position: Int
    let direction: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "plus")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(Circle().fill(hovering ? TFColors.accent : Color.black.opacity(0.35)))
                .overlay(Circle().strokeBorder(.white.opacity(hovering ? 1 : 0.6),
                                               style: StrokeStyle(lineWidth: 1.2, dash: hovering ? [] : [3, 2.5])))
                .scaleEffect(hovering ? 1.22 : 1)
                .contentShape(Circle().inset(by: -4))
        }
        .buttonStyle(.plain)
        .onHover { value in withAnimation(.spring(response: 0.25, dampingFraction: 0.6)) { hovering = value } }
        .help(L("ring.studio.insertHere", position, direction))
        .accessibilityLabel(L("ring.studio.insertHere", position, direction))
        .accessibilityIdentifier("ring.studio.insert.\(position)")
    }
}

/// Keys that need `onKeyPress` (macOS 14): ⌥ + arrows, digits, + and Return.
struct RingStudioKeyPresses: ViewModifier {
    let onKey: (RingStudioKey) -> Void

    func body(content: Content) -> some View {
        if #available(macOS 14.0, *) {
            content.onKeyPress(phases: .down) { press in
                guard let key = Self.key(for: press.key.character, option: press.modifiers.contains(.option),
                                         isLeft: press.key == .leftArrow || press.key == .upArrow,
                                         isRight: press.key == .rightArrow || press.key == .downArrow,
                                         isReturn: press.key == .return)
                else { return .ignored }
                onKey(key)
                return .handled
            }
        } else {
            content
        }
    }

    static func key(for character: Character, option: Bool, isLeft: Bool, isRight: Bool,
                    isReturn: Bool) -> RingStudioKey? {
        if option, isLeft {
            return .movePrevious
        }
        if option, isRight {
            return .moveNext
        }
        if isReturn {
            return .edit
        }
        if character == "+" || character == "=" {
            return .insert
        }
        if let digit = character.wholeNumberValue, (1 ... RingConfiguration.maxActions).contains(digit) {
            return .select(digit - 1)
        }
        return nil
    }
}
