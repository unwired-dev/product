import SwiftUI

/// Displays public product, legal, support, and open-source information.
struct AboutSettingsView: View {
  let information: AboutAppInformation

  init(information: AboutAppInformation = .current()) {
    self.information = information
  }

  var body: some View {
    Form {
      Section(information.appName) {
        LabeledContent("Version", value: information.version)
        LabeledContent("Build", value: information.build)
      }

      Section("Legal") {
        Link("Privacy Policy", destination: AboutAppInformation.privacyPolicyURL)
        Link("Terms of Use", destination: AboutAppInformation.termsOfUseURL)
      }

      Section("Open Source") {
        NavigationLink("Licenses & Acknowledgements") {
          OpenSourceAcknowledgementsView(packages: OpenSourcePackage.all)
        }
      }

      Section("Contact") {
        Link("Support", destination: AboutAppInformation.supportURL)
        Link("Product Website", destination: AboutAppInformation.productWebsiteURL)
      }

      Section {
        Text(information.copyrightNotice)
          .foregroundStyle(.secondary)
      }
    }
  }
}
