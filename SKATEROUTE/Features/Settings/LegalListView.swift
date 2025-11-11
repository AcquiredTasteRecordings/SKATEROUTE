// Features/Settings/LegalListView.swift
import SwiftUI

public struct LegalListView: View {
    public init() {}
    public var body: some View {
        List {
            NavigationLink("Privacy Policy") { MarkdownDocView(resource: "PrivacyPolicy") }
            NavigationLink("Terms of Use")   { MarkdownDocView(resource: "TermsOfUse") }
        }
        .navigationTitle(Text("Legal"))
        .navigationBarTitleDisplayMode(.inline)
    }
}

public struct MarkdownDocView: View {
    let resource: String // file name (no extension) in Resources/Legal
    public init(resource: String) { self.resource = resource }

    public var body: some View {
        ScrollView {
            Text(loadMarkdown())
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
        }
        .background(Color(UIColor.systemBackground))
        .navigationTitle(title())
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("legal_\(resource.lowercased())")
    }

    private func loadMarkdown() -> AttributedString {
        guard
            let url = Bundle.main.url(forResource: resource, withExtension: "md", subdirectory: "Resources/Legal"),
            let data = try? Data(contentsOf: url),
            let md = String(data: data, encoding: .utf8),
            let attr = try? AttributedString(markdown: md)
        else { return AttributedString("Document unavailable.") }
        return attr
    }

    private func title() -> Text {
        switch resource {
        case "PrivacyPolicy": return Text("Privacy Policy")
        case "TermsOfUse":    return Text("Terms of Use")
        default:              return Text(resource)
        }
    }
}
