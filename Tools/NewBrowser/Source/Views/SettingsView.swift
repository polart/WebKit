// Copyright (C) 2024 Apple Inc. All rights reserved.
//
// Redistribution and use in source and binary forms, with or without
// modification, are permitted provided that the following conditions
// are met:
// 1. Redistributions of source code must retain the above copyright
//    notice, this list of conditions and the following disclaimer.
// 2. Redistributions in binary form must reproduce the above copyright
//    notice, this list of conditions and the following disclaimer in the
//    documentation and/or other materials provided with the distribution.
//
// THIS SOFTWARE IS PROVIDED BY APPLE INC. AND ITS CONTRIBUTORS ``AS IS''
// AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO,
// THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
// PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL APPLE INC. OR ITS CONTRIBUTORS
// BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
// CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
// SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
// INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
// CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
// ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF
// THE POSSIBILITY OF SUCH DAMAGE.

import AppKit
import SwiftUI
@_spi(_) import WebKit
import WebKit_Private._WKFeature

// MARK: - Palette

// The Settings window is styled with flat, explicitly dark colors rather than
// system materials, so `SettingsView` forces the dark color scheme.
private enum Palette {
    static let sidebarBackground = Color(white: 0.10)
    static let detailBackground = Color(white: 0.137)
    static let cardBackground = Color(white: 0.17)
    static let controlBackground = Color(white: 0.21)
    static let sidebarSelection = Color(white: 0.20)
    static let searchFieldBackground = Color(white: 0.20)
    static let separator = Color(white: 1.0, opacity: 0.08)
    static let secondaryText = Color(white: 0.63)
}

/// Vertical center of the title bar, shared by the window controls, the page
/// title and the search field so all three sit on the same line.
private enum Metrics {
    static let titleBarHeight: CGFloat = 52
    static let titleBarControlHeight: CGFloat = 30
    static let sidebarWidth: CGFloat = 220
    static let contentInset: CGFloat = 20
    static let rowInset: CGFloat = 10
    static let rowHeight: CGFloat = 43
    static let controlWidth: CGFloat = 173
    static let controlHeight: CGFloat = 27
    // Wide enough for a URL, while still leaving room for a row's title at the
    // window's minimum width.
    static let textFieldWidth: CGFloat = 240
    static let searchFieldWidth: CGFloat = 318
    // Width reserved for a group header's symbol, so titles align across pages
    // whether the header shows a symbol or a disclosure chevron.
    static let groupSymbolWidth: CGFloat = 22
}

// MARK: - Shared controls

// Trailing control of a row: a flat pill matching the row backgrounds rather
// than a system bezel.
private struct SettingsPillButton: View {
    let title: String

    var isEnabled = true

    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 14))
                .foregroundStyle(isEnabled ? .white : Palette.secondaryText)
                .frame(width: Metrics.controlWidth, height: Metrics.controlHeight)
                .background {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Palette.controlBackground)
                }
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
    }
}

private struct SettingsTextField: View {
    let prompt: String

    @Binding
    var text: String

    var body: some View {
        ZStack(alignment: .leading) {
            if text.isEmpty {
                Text(prompt)
                    .font(.system(size: 14))
                    .foregroundStyle(Palette.secondaryText)
            }

            TextField("", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 10)
        .frame(width: Metrics.textFieldWidth, height: Metrics.controlHeight)
        .background {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Palette.controlBackground)
        }
        .accessibilityLabel(prompt)
    }
}

// Trailing control of a row: a fixed-width menu picker whose label lives in the
// row itself.
private struct SettingsPicker<Value: Hashable, Content: View>: View {
    @Binding
    var selection: Value

    let label: String

    @ViewBuilder
    let content: Content

    var body: some View {
        Picker(label, selection: $selection) {
            content
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .frame(width: Metrics.controlWidth)
        .accessibilityLabel(label)
    }
}

private struct SettingsToggle: View {
    @Binding
    var isOn: Bool

    let label: String

    var body: some View {
        Toggle(label, isOn: $isOn)
            .labelsHidden()
            .toggleStyle(.switch)
            .accessibilityLabel(label)
    }
}

// MARK: - Rows and groups

// A single row: a title (optionally with a secondary line beneath it) and a
// trailing control.
private struct SettingsRow<Trailing: View>: View {
    let title: String

    var subtitle: String? = nil

    /// Marks a row whose value differs from its default, as the feature flags page does.
    var isEmphasized = false

    @ViewBuilder
    let trailing: Trailing

    var body: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 15, weight: isEmphasized ? .semibold : .regular))
                    .foregroundStyle(.white)
                    .lineLimit(1)

                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.secondaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Spacer(minLength: 0)

            trailing
        }
        .padding(.horizontal, Metrics.rowInset)
        .padding(.vertical, 6)
        .frame(minHeight: Metrics.rowHeight)
    }
}

// Rounded container that hairline-separates whatever rows it is given. The rows
// arrive as subviews, so callers just list them without interleaving separators.
private struct SettingsCard<Content: View>: View {
    @ViewBuilder
    let content: Content

    var body: some View {
        Group(subviews: content) { subviews in
            VStack(spacing: 0) {
                ForEach(Array(subviews.enumerated()), id: \.offset) { index, subview in
                    if index > 0 {
                        Rectangle()
                            .fill(Palette.separator)
                            .frame(height: 1)
                    }

                    subview
                }
            }
        }
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Palette.cardBackground)
        }
    }
}

private struct SettingsGroupHeader<Accessory: View>: View {
    let title: String

    @ViewBuilder
    let accessory: Accessory

    var body: some View {
        HStack(spacing: 10) {
            accessory
                .frame(width: Metrics.groupSymbolWidth)

            Text(title)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)

            Spacer(minLength: 0)
        }
        .padding(.leading, Metrics.rowInset)
    }
}

// A titled group: symbol and title above a card of rows.
private struct SettingsGroup<Content: View>: View {
    let title: String

    let systemImage: String

    @ViewBuilder
    let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SettingsGroupHeader(title: title) {
                Image(systemName: systemImage)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
            }

            SettingsCard {
                content
            }
        }
    }
}

// Scrolling body of a page, so every page's groups share the same rhythm and
// insets.
private struct SettingsPage<Content: View>: View {
    @ViewBuilder
    let content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                content
            }
            .padding(.top, 18)
            .padding(.horizontal, Metrics.contentInset)
            .padding(.bottom, 24)
        }
    }
}

// MARK: - Pages

private struct GeneralSettingsView: View {
    @AppStorage(AppStorageKeys.homepage)
    private var homepage = "https://www.webkit.org"

    @AppStorage(AppStorageKeys.orientationAndMotionAuthorization)
    private var orientationAndMotionAuthorization = WKPermissionDecision.prompt

    @AppStorage(AppStorageKeys.mediaCaptureAuthorization)
    private var mediaCaptureAuthorization = WKPermissionDecision.prompt

    @AppStorage(AppStorageKeys.scrollBounceBehaviorBasedOnSize)
    private var scrollBounceBehaviorBasedOnSize = false

    @AppStorage(AppStorageKeys.backgroundHidden)
    private var backgroundHidden = false

    @AppStorage(AppStorageKeys.showColorInTabBar)
    private var showColorInTabBar = true

    let currentURL: URL?

    var body: some View {
        SettingsPage {
            SettingsGroup(title: "Homepage", systemImage: "house.fill") {
                SettingsRow(title: "Homepage") {
                    SettingsTextField(prompt: "Homepage URL", text: $homepage)
                }

                SettingsRow(title: "Current Page", subtitle: currentURL?.absoluteString ?? "No page open") {
                    SettingsPillButton(title: "Set as Homepage", isEnabled: currentURL != nil) {
                        if let currentURL {
                            homepage = currentURL.absoluteString
                        }
                    }
                }
            }

            SettingsGroup(title: "Site Permissions", systemImage: "hand.raised.fill") {
                SettingsRow(title: "Camera Access") {
                    PermissionDecisionPicker(
                        permissionDecision: $mediaCaptureAuthorization,
                        label: "Allow sites to access camera"
                    )
                }

                SettingsRow(title: "Sensor Access") {
                    PermissionDecisionPicker(
                        permissionDecision: $orientationAndMotionAuthorization,
                        label: "Allow sites to access sensors"
                    )
                }
            }

            SettingsGroup(title: "Appearance", systemImage: "macwindow") {
                SettingsRow(title: "Scroll Bounce Behavior") {
                    SettingsPicker(selection: $scrollBounceBehaviorBasedOnSize, label: "Scroll Bounce Behavior") {
                        Text("Automatic").tag(false)
                        Text("Based on Size").tag(true)
                    }
                }

                SettingsRow(title: "Hidden Background Behavior") {
                    SettingsPicker(selection: $backgroundHidden, label: "Hidden Background Behavior") {
                        Text("Automatic").tag(false)
                        Text("Always Hide").tag(true)
                    }
                }

                SettingsRow(title: "Show color in tab bar") {
                    SettingsToggle(isOn: $showColorInTabBar, label: "Show color in tab bar")
                }
            }
        }
    }
}

private struct PermissionDecisionPicker: View {
    @Binding
    var permissionDecision: WKPermissionDecision

    let label: String

    var body: some View {
        SettingsPicker(selection: $permissionDecision, label: label) {
            Text("Ask").tag(WKPermissionDecision.prompt)
            Text("Grant").tag(WKPermissionDecision.grant)
            Text("Deny").tag(WKPermissionDecision.deny)
        }
    }
}

// Feature flags are rendered as one collapsible card per category, matching the
// grouped rows of the other pages. The status of each feature is shown as the
// row's secondary line, and its name is emphasized when its value has been
// changed from the default.
private struct FeatureFlagsView: View {
    @Environment(FeatureFlagsModel.self)
    var model

    @State
    private var collapsedCategories: Set<UInt> = []

    private var groupedFeatures: FeatureFlagsModel.GroupedFeatures {
        model.groups(filteredBy: model.searchQuery)
    }

    private func isExpanded(_ category: WebFeatureCategory) -> Bool {
        !collapsedCategories.contains(category.rawValue)
    }

    private func toggleExpansion(of category: WebFeatureCategory) {
        if collapsedCategories.contains(category.rawValue) {
            collapsedCategories.remove(category.rawValue)
        } else {
            collapsedCategories.insert(category.rawValue)
        }
    }

    var body: some View {
        @Bindable
        var model = model

        SettingsPage {
            let groups = groupedFeatures

            if groups.isEmpty {
                Text("No matching features")
                    .font(.system(size: 15))
                    .foregroundStyle(Palette.secondaryText)
                    .padding(.leading, Metrics.rowInset)
            }

            ForEach(groups, id: \.category.rawValue) { group in
                VStack(alignment: .leading, spacing: 10) {
                    Button {
                        withAnimation(.easeOut(duration: 0.15)) {
                            toggleExpansion(of: group.category)
                        }
                    } label: {
                        SettingsGroupHeader(title: group.category.description) {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(Palette.secondaryText)
                                .rotationEffect(.degrees(isExpanded(group.category) ? 90 : 0))
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(group.category.description)
                    .accessibilityHint(isExpanded(group.category) ? "Collapse category" : "Expand category")

                    if isExpanded(group.category) {
                        SettingsCard {
                            ForEach(group.features) { feature in
                                SettingsRow(
                                    title: feature.name,
                                    subtitle: feature.status.description,
                                    isEmphasized: (model.customizedFeatures[feature.key] ?? feature.defaultValue)
                                        != feature.defaultValue
                                ) {
                                    SettingsToggle(
                                        isOn: $model.customizedFeatures[feature.key, default: feature.defaultValue],
                                        label: feature.name
                                    )
                                }
                            }
                        }
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HStack {
                Spacer(minLength: 0)

                SettingsPillButton(title: "Reset Feature Flags") {
                    model.customizedFeatures.removeAll()
                }
            }
            .padding(.horizontal, Metrics.contentInset)
            .padding(.vertical, 12)
            .background {
                Palette.detailBackground
                    .overlay(alignment: .top) {
                        Rectangle()
                            .fill(Palette.separator)
                            .frame(height: 1)
                    }
            }
        }
        .onChange(of: model.customizedFeatures, model.update)
    }
}

private struct DebugOverlaysView: View {
    @AppStorage(AppStorageKeys.debugOverlayNonFastScrollableRegion)
    private var nonFastScrollableRegion = false

    @AppStorage(AppStorageKeys.debugOverlayWheelEventHandlerRegion)
    private var wheelEventHandlerRegion = false

    @AppStorage(AppStorageKeys.debugOverlayTouchActionRegion)
    private var touchActionRegion = false

    @AppStorage(AppStorageKeys.debugOverlayInteractionRegion)
    private var interactionRegion = false

    @AppStorage(AppStorageKeys.debugOverlayEnhancedSecurityRegion)
    private var enhancedSecurityRegion = false

    var body: some View {
        SettingsPage {
            SettingsGroup(title: "Region Overlays", systemImage: "square.dashed") {
                SettingsRow(title: "Non-fast Scrollable Region") {
                    SettingsToggle(isOn: $nonFastScrollableRegion, label: "Non-fast Scrollable Region")
                }

                SettingsRow(title: "Wheel Event Handler Region") {
                    SettingsToggle(isOn: $wheelEventHandlerRegion, label: "Wheel Event Handler Region")
                }

                SettingsRow(title: "Touch Action Region") {
                    SettingsToggle(isOn: $touchActionRegion, label: "Touch Action Region")
                }

                SettingsRow(title: "Interaction Region") {
                    SettingsToggle(isOn: $interactionRegion, label: "Interaction Region")
                }

                SettingsRow(title: "Enhanced Security Region") {
                    SettingsToggle(isOn: $enhancedSecurityRegion, label: "Enhanced Security Region")
                }
            }
        }
    }
}

// Ad blocking: the master toggle plus the catalog of filter lists WebKit
// offers. The always-on lists (Brave's hidden `default_enabled` entries) have
// no toggle, so they are summarized rather than listed.
private struct ContentBlockingView: View {
    @State
    private var model = AdBlockModel.shared

    private static let lastFetchedFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    private func subtitle(for list: AdBlockModel.CatalogList) -> String? {
        guard list.isEnabled else {
            return list.details.isEmpty ? nil : list.details
        }
        guard let lastFetched = list.lastFetched else {
            return "Downloading…"
        }
        let fetched = "Updated \(Self.lastFetchedFormatter.localizedString(for: lastFetched, relativeTo: .now))"
        return list.details.isEmpty ? fetched : "\(list.details) · \(fetched)"
    }

    var body: some View {
        @Bindable
        var model = model

        SettingsPage {
            SettingsGroup(title: "Ad Blocking", systemImage: "shield.lefthalf.filled") {
                SettingsRow(
                    title: "Block Ads and Trackers",
                    subtitle: model.hiddenListCount > 0
                        ? "\(model.hiddenListCount) built-in list\(model.hiddenListCount == 1 ? "" : "s") are always on"
                        : nil
                ) {
                    SettingsToggle(isOn: $model.isEnabled, label: "Block Ads and Trackers")
                }

                SettingsRow(title: "Filter Lists", subtitle: "Re-download every enabled list now") {
                    SettingsPillButton(title: "Update Now", isEnabled: model.isLoaded) {
                        model.refreshLists()
                    }
                }
            }

            SettingsGroup(title: "Sites With Ad Blocking Off", systemImage: "shield.slash") {
                if model.allowlistedSites.isEmpty {
                    SettingsRow(
                        title: "No exceptions",
                        subtitle: "Turn off ad blocking for a site from the shield in the toolbar."
                    ) {
                        EmptyView()
                    }
                } else {
                    ForEach(model.allowlistedSites, id: \.self) { site in
                        SettingsRow(title: site) {
                            SettingsPillButton(title: "Remove") {
                                Task {
                                    await model.setBlocking(true, onSite: site)
                                }
                            }
                        }
                    }
                }
            }

            if model.lists.isEmpty {
                SettingsGroup(title: "Filter Lists", systemImage: "list.bullet.rectangle") {
                    SettingsRow(
                        title: model.isLoaded ? "No filter lists available" : "Loading filter lists…",
                        subtitle: model.isLoaded ? "The bundled catalog could not be read." : nil
                    ) {
                        EmptyView()
                    }
                }
            } else {
                SettingsGroup(title: "Filter Lists", systemImage: "list.bullet.rectangle") {
                    ForEach(model.lists) { list in
                        SettingsRow(
                            title: list.title,
                            subtitle: subtitle(for: list),
                            isEmphasized: list.isEnabled != list.isDefaultEnabled
                        ) {
                            SettingsToggle(
                                isOn: Binding(
                                    get: { list.isEnabled },
                                    set: { model.setList(list, enabled: $0) }
                                ),
                                label: list.title
                            )
                        }
                    }
                }
            }
        }
        .task {
            await model.reloadState()
        }
    }
}

// MARK: - Sidebar

private struct SidebarIcon: View {
    let systemImage: String

    let color: Color

    var body: some View {
        RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(color)
            .frame(width: 28, height: 28)
            .overlay {
                Image(systemName: systemImage)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.white)
            }
    }
}

private struct SidebarRow: View {
    let section: SettingsSection

    let isSelected: Bool

    var body: some View {
        HStack(spacing: 12) {
            SidebarIcon(systemImage: section.systemImage, color: section.iconColor)

            Text(section.title)
                .font(.system(size: 15))
                .foregroundStyle(.white)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isSelected ? Palette.sidebarSelection : .clear)
        }
        .contentShape(.rect)
    }
}

private struct Sidebar: View {
    @Binding
    var selection: SettingsSection

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Left free for the window's close/minimize/zoom buttons.
            Color.clear
                .frame(height: Metrics.titleBarHeight)

            VStack(alignment: .leading, spacing: 2) {
                ForEach(SettingsSection.allCases) { section in
                    Button {
                        selection = section
                    } label: {
                        SidebarRow(section: section, isSelected: section == selection)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.top, 8)

            Spacer(minLength: 24)
        }
        .padding(.horizontal, 10)
        .frame(width: Metrics.sidebarWidth, alignment: .leading)
        .background(Palette.sidebarBackground)
    }
}

// MARK: - Title bar

private struct SettingsSearchField: View {
    @Binding
    var text: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Palette.secondaryText)

            ZStack(alignment: .leading) {
                if text.isEmpty {
                    Text("Search")
                        .font(.system(size: 15))
                        .foregroundStyle(Palette.secondaryText)
                }

                TextField("", text: $text)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15))
                    .foregroundStyle(.white)
            }

            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(Palette.secondaryText)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear Search")
            }
        }
        .padding(.horizontal, 14)
        .frame(width: Metrics.searchFieldWidth, height: Metrics.titleBarControlHeight)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Palette.searchFieldBackground)
        }
    }
}

// Fixed-height header drawn at the top of the detail column, so content starts
// at the same vertical offset no matter which page is selected. Its title shares
// the window controls' center line, as does the search field that pages which
// support searching put in the window's toolbar.
//
// Applied as a top safe area inset rather than as a sibling above the page, so
// that a page's rows scroll underneath it instead of over it: scroll views
// extend their content into the (transparent) titlebar band, and only a safe
// area inset both insets that content and draws above it. Its background is
// therefore opaque.
//
// The header holds nothing interactive on purpose. With `.fullSizeContentView`
// the window's titlebar sits above the content view and consumes mouse events
// over this band, so a control drawn here cannot be clicked; the title is only
// text, and clicks on it drag the window as they would in any titlebar.
private struct SettingsContentHeader: View {
    let title: String

    var body: some View {
        HStack {
            Text(title)
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(.white)
                .fixedSize()

            Spacer(minLength: 0)
        }
        .frame(height: Metrics.titleBarHeight)
        .padding(.leading, Metrics.contentInset)
        .background(Palette.detailBackground)
    }
}

// MARK: - Window chrome

// Strips the Settings window's titlebar down to just the window controls: no
// title text, no backing, no separator, and content extending into the titlebar
// region so the page header occupies that band.
private struct SettingsWindowConfigurator: NSViewRepresentable {
    // Configuring from `viewDidMoveToWindow` rather than `updateNSView` avoids
    // having to wait for the view to be added to a window.
    final class ConfiguringView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            configureWindow()
        }

        func configureWindow() {
            // `NSView.window` is an `unowned(unsafe)` reference, which the
            // project's strict memory safety mode requires acknowledging.
            guard let window = unsafe window else {
                return
            }

            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.titlebarSeparatorStyle = .none
            window.isMovableByWindowBackground = true

            // Lets content occupy the titlebar region, so the page header can
            // sit alongside the window controls.
            window.styleMask.insert(.fullSizeContentView)

            // A unified toolbar makes the titlebar tall enough for the window
            // controls to be centered on the header's line
            // (`Metrics.titleBarHeight`); without it they sit well above the
            // title. The content ignores the safe area the toolbar adds, so it
            // still starts at the top of the window.
            //
            // Pages that search contribute a toolbar item, in which case SwiftUI
            // supplies the toolbar; an empty one stands in for the other pages so
            // that the titlebar keeps its height as pages change.
            window.toolbarStyle = .unified

            if window.toolbar == nil {
                window.toolbar = NSToolbar()
            }
        }
    }

    func makeNSView(context: Context) -> ConfiguringView {
        ConfiguringView(frame: .zero)
    }

    func updateNSView(_ view: ConfiguringView, context: Context) {
        // Reapplied because SwiftUI can reset titlebar state as the selected
        // page changes.
        view.configureWindow()
    }
}

// MARK: - Settings

private enum SettingsSection: String, CaseIterable, Identifiable {
    case general
    case contentBlocking
    case featureFlags
    case debugOverlays

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .contentBlocking: "Content Blocking"
        case .featureFlags: "Feature Flags"
        case .debugOverlays: "Debug Overlays"
        }
    }

    var systemImage: String {
        switch self {
        case .general: "gearshape.fill"
        case .contentBlocking: "shield.lefthalf.filled"
        case .featureFlags: "flag.fill"
        case .debugOverlays: "square.dashed"
        }
    }

    var iconColor: Color {
        switch self {
        case .general: Color(white: 0.38)
        case .contentBlocking: Color(red: 0.98, green: 0.45, blue: 0.09)
        case .featureFlags: Color(red: 0.04, green: 0.52, blue: 1.0)
        case .debugOverlays: Color(red: 0.61, green: 0.36, blue: 0.85)
        }
    }

    var isSearchable: Bool {
        self == .featureFlags
    }
}

struct SettingsView: View {
    let currentURL: URL?

    @State
    private var selection: SettingsSection = .general

    // Owned here rather than created per appearance so the header's search field
    // can bind to it, and so search text survives switching pages.
    @State
    private var featureFlagsModel = FeatureFlagsModel()

    var body: some View {
        @Bindable
        var featureFlagsModel = featureFlagsModel

        HStack(spacing: 0) {
            Sidebar(selection: $selection)

            Group {
                switch selection {
                case .general:
                    GeneralSettingsView(currentURL: currentURL)
                case .contentBlocking:
                    ContentBlockingView()
                case .featureFlags:
                    FeatureFlagsView()
                        .environment(self.featureFlagsModel)
                case .debugOverlays:
                    DebugOverlaysView()
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                SettingsContentHeader(title: selection.title)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Palette.detailBackground)
        }
        .frame(minWidth: 700, idealWidth: 810, minHeight: 480, idealHeight: 660)
        .background(Palette.detailBackground)
        // Both columns draw into the titlebar region, which the window
        // configurator above has made transparent and title-less.
        .ignoresSafeArea(.container, edges: .top)
        .preferredColorScheme(.dark)
        // The search field lives in the toolbar, not in the page header, because
        // the titlebar consumes clicks over the content beneath it. The item is
        // declared for every page so that the toolbar — and with it the height of
        // the titlebar the window controls are centered in — does not come and go.
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                if selection.isSearchable {
                    SettingsSearchField(text: $featureFlagsModel.searchQuery)
                }
            }
        }
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .background {
            SettingsWindowConfigurator()
        }
    }
}

#Preview {
    SettingsView(currentURL: URL(string: "https://www.apple.com"))
}

#Preview("Feature Flags") {
    FeatureFlagsView()
        .environment(FeatureFlagsModel())
        .safeAreaInset(edge: .top, spacing: 0) {
            SettingsContentHeader(title: "Feature Flags")
        }
        .frame(width: 590, height: 620)
        .background(Palette.detailBackground)
        .preferredColorScheme(.dark)
}
