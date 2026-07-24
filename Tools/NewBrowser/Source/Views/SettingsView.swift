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

import SwiftUI
@_spi(_) import WebKit
import WebKit_Private._WKFeature

private struct PermissionDecisionView: View {
    @Binding
    var permissionDecision: WKPermissionDecision

    let label: String

    var body: some View {
        Picker(selection: $permissionDecision) {
            Text("Ask").tag(WKPermissionDecision.prompt)
            Text("Grant").tag(WKPermissionDecision.grant)
            Text("Deny").tag(WKPermissionDecision.deny)
        } label: {
            Text(label)
        }
    }
}

private struct BinaryValuePicker: View {
    @Binding
    var value: Bool

    let description: String

    let falseLabel: String
    let trueLabel: String

    var body: some View {
        Picker(selection: $value) {
            Text(falseLabel).tag(false)
            Text(trueLabel).tag(true)
        } label: {
            Text(description)
        }
    }
}

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
        Form {
            Section {
                TextField("Homepage:", text: $homepage)

                Button("Set to Current Page") {
                    if let currentURL {
                        homepage = currentURL.absoluteString
                    } else {
                        fatalError()
                    }
                }
            }

            Section {
                PermissionDecisionView(
                    permissionDecision: $mediaCaptureAuthorization,
                    label: "Allow sites to access camera:"
                )
                .padding(.top)

                PermissionDecisionView(
                    permissionDecision: $orientationAndMotionAuthorization,
                    label: "Allow sites to access sensors:"
                )
            }

            Section {
                BinaryValuePicker(
                    value: $scrollBounceBehaviorBasedOnSize,
                    description: "Scroll Bounce Behavior",
                    falseLabel: "Automatic",
                    trueLabel: "Based on Size"
                )

                BinaryValuePicker(
                    value: $backgroundHidden,
                    description: "Hidden Background Behavior",
                    falseLabel: "Automatic",
                    trueLabel: "Always Hide"
                )
            }

            Section {
                Toggle("Show color in tab bar", isOn: $showColorInTabBar)
                    .padding(.top)
            }
        }
    }
}

// Feature flags rendered as a `Table` with collapsible category groups via
// `DisclosureTableRow`, giving real column headers and an outline-style
// (indented, disclosure-triangle) grouping. Note: the column header row is
// pinned, but the category (disclosure) rows scroll with their content —
// `Table` has no sticky group-header support.
private struct FeatureFlagsTableView: View {
    @Environment(FeatureFlagsModel.self)
    var model

    @State
    private var collapsedCategories: Set<UInt> = []

    // `DisclosureTableRow` requires the label row and its child rows to share a
    // single `TableRowValue`, so both categories and features are wrapped here.
    private struct Row: Identifiable {
        enum Kind {
            case category(WebFeatureCategory)
            case feature(_WKFeature)
        }

        let kind: Kind

        var id: String {
            switch kind {
            case .category(let category): "category-\(category.rawValue)"
            case .feature(let feature): feature.id
            }
        }
    }

    private var groupedFeatures: FeatureFlagsModel.GroupedFeatures {
        model.groups(filteredBy: model.searchQuery)
    }

    private func expansion(for category: WebFeatureCategory) -> Binding<Bool> {
        Binding(
            get: { !collapsedCategories.contains(category.rawValue) },
            set: { isExpanded in
                if isExpanded {
                    collapsedCategories.remove(category.rawValue)
                } else {
                    collapsedCategories.insert(category.rawValue)
                }
            }
        )
    }

    var body: some View {
        @Bindable
        var model = model

        Table(of: Row.self) {
            TableColumn("Feature") { row in
                switch row.kind {
                case .category(let category):
                    Text(category.description)
                        .font(.headline)
                case .feature(let feature):
                    Text(feature.name)
                        .bold((model.customizedFeatures[feature.key] ?? feature.defaultValue) != feature.defaultValue)
                }
            }

            TableColumn("Enabled") { row in
                if case .feature(let feature) = row.kind {
                    Toggle("", isOn: $model.customizedFeatures[feature.key, default: feature.defaultValue])
                        .labelsHidden()
                        .toggleStyle(.checkbox)
                }
            }
            .width(60)
            .alignment(.center)

            TableColumn("Status") { row in
                if case .feature(let feature) = row.kind {
                    Text(feature.status.description)
                        .foregroundStyle(.secondary)
                }
            }
            .width(min: 80, ideal: 90)
        } rows: {
            ForEach(groupedFeatures, id: \.category.rawValue) { group in
                DisclosureTableRow(Row(kind: .category(group.category)), isExpanded: expansion(for: group.category)) {
                    ForEach(group.features) { feature in
                        TableRow(Row(kind: .feature(feature)))
                    }
                }
            }
        }
        .searchable(text: $model.searchQuery, prompt: "Search")
        .safeAreaInset(edge: .bottom) {
            HStack {
                Spacer()
                Button("Reset Feature Flags") {
                    model.customizedFeatures.removeAll()
                }
            }
            .padding()
            .background(.bar)
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
        Form {
            Section("Region Overlays") {
                Toggle("Non-fast Scrollable Region", isOn: $nonFastScrollableRegion)
                Toggle("Wheel Event Handler Region", isOn: $wheelEventHandlerRegion)
                Toggle("Touch Action Region", isOn: $touchActionRegion)
                Toggle("Interaction Region", isOn: $interactionRegion)
                Toggle("Enhanced Security Region", isOn: $enhancedSecurityRegion)
            }
        }
    }
}

private enum SettingsSection: String, CaseIterable, Identifiable {
    case general
    case featureFlags
    case debugOverlays

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .featureFlags: "Feature Flags"
        case .debugOverlays: "Debug Overlays"
        }
    }

    var systemImage: String {
        switch self {
        case .general: "gear"
        case .featureFlags: "flag.filled.and.flag.crossed"
        case .debugOverlays: "squareshape.split.2x2.dotted.inside.and.outside"
        }
    }
}

struct SettingsView: View {
    let currentURL: URL?

    @State
    private var selection: SettingsSection = .general

    var body: some View {
        NavigationSplitView {
            List(SettingsSection.allCases, selection: $selection) { section in
                Label(section.title, systemImage: section.systemImage)
                    .tag(section)
            }
            .navigationSplitViewColumnWidth(215)
            .toolbar(removing: .sidebarToggle)
        } detail: {
            Group {
                switch selection {
                case .general:
                    GeneralSettingsView(currentURL: currentURL)
                case .featureFlags:
                    FeatureFlagsTableView()
                        .environment(FeatureFlagsModel())
                case .debugOverlays:
                    DebugOverlaysView()
                }
            }
            .navigationTitle(selection.title)
            .frame(minWidth: 400, minHeight: 400, idealHeight: 500, maxHeight: .infinity)
        }
        .navigationSplitViewStyle(.balanced)
    }
}

#Preview {
    SettingsView(currentURL: URL(string: "https://www.apple.com"))
}

#Preview("Feature Flags") {
    FeatureFlagsTableView()
        .environment(FeatureFlagsModel())
        .frame(width: 520, height: 520)
}
