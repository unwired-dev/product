import SwiftUI

/// Lists the packages and license documents acknowledged by Unwired Mail.
struct OpenSourceAcknowledgementsView: View {
  let packages: [OpenSourcePackage]

  var body: some View {
    List {
      Section {
        Text(
          "Unwired Mail is built with open-source software. Thank you to every contributor."
        )
      }

      ForEach(packages) { package in
        Section(package.name) {
          LabeledContent("License", value: package.license)
          Link("View License", destination: package.licenseURL)
          Link("View Source", destination: package.repositoryURL)
        }
      }
    }
    .navigationTitle("Open Source")
  }
}
