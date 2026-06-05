import SwiftUI

struct SmokeView<Service: BackendHealthChecking>: View {
  @State private var state: BackendHealthState = .loading

  let service: Service

  var body: some View {
    VStack(alignment: .leading, spacing: 20) {
      VStack(alignment: .leading, spacing: 8) {
        Text("Unwired Mail")
          .font(.largeTitle.bold())
        Text("Backend Health")
          .font(.title2)
          .foregroundStyle(.secondary)
      }

      statusContent

      Button("Retry") {
        Task {
          await loadHealth()
        }
      }
      .buttonStyle(.borderedProminent)
    }
    .padding(32)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .task {
      await loadHealth()
    }
  }

  @ViewBuilder
  private var statusContent: some View {
    switch state {
    case .loading:
      Label("Checking backend...", systemImage: "hourglass")
        .foregroundStyle(.secondary)
    case .healthy(let response):
      VStack(alignment: .leading, spacing: 8) {
        Label("Connected", systemImage: "checkmark.circle.fill")
          .foregroundStyle(.green)
          .font(.headline)
        Text("Service: \(response.service)")
        Text("Version: \(response.bootstrapVersion)")
        Text("Server time: \(response.serverTime)")
          .foregroundStyle(.secondary)
      }
    case .failed(let message):
      VStack(alignment: .leading, spacing: 8) {
        Label("Backend unavailable", systemImage: "xmark.octagon.fill")
          .foregroundStyle(.red)
          .font(.headline)
        Text(message)
          .foregroundStyle(.secondary)
      }
    }
  }

  private func loadHealth() async {
    state = .loading

    do {
      let response = try await service.health()
      state = .healthy(response)
    } catch {
      state = .failed(error.localizedDescription)
    }
  }
}

#Preview("Healthy") {
  SmokeView(service: PreviewBackendHealthService(result: .success(.preview)))
}

#Preview("Failed") {
  SmokeView(
    service: PreviewBackendHealthService(
      result: .failure(BackendHealthError.missingConvexURL)
    )
  )
}
