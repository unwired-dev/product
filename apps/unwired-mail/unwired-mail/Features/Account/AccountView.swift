import SwiftUI

struct AccountView: View {
  let session: ProductAccountSession
  let snapshot: ProductAccountSessionSnapshot

  @State private var categoryViewModel: CustomCategoryViewModel

  init(
    session: ProductAccountSession,
    snapshot: ProductAccountSessionSnapshot,
    categorySyncService: CustomCategorySyncing = CustomCategorySyncService()
  ) {
    self.session = session
    self.snapshot = snapshot
    _categoryViewModel = State(
      initialValue: CustomCategoryViewModel(
        service: categorySyncService,
        session: snapshot
      )
    )
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 24) {
      VStack(alignment: .leading, spacing: 8) {
        Text("Unwired Mail")
          .font(.largeTitle.bold())
        Text("Product Account")
          .font(.title2)
          .foregroundStyle(.secondary)
      }

      VStack(alignment: .leading, spacing: 8) {
        Label("Signed in with Apple", systemImage: "checkmark.circle.fill")
          .foregroundStyle(.green)
          .font(.headline)
        Text("Product account: \(snapshot.productAccountId)")
        Text("Trusted device: \(snapshot.trustedDeviceId)")
          .foregroundStyle(.secondary)
      }

      CustomCategoryPanel(viewModel: categoryViewModel)

      SmokeView(service: ConvexBackendHealthService())

      Button("Sign Out", role: .destructive) {
        session.signOut()
      }
      .buttonStyle(.bordered)
    }
    .padding(32)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .task {
      await categoryViewModel.load()
    }
  }
}

@MainActor
@Observable
private final class CustomCategoryViewModel {
  var category: CustomCategory?
  var description = ""
  var errorMessage: String?
  var isSaving = false
  var isSyncing = false
  var name = ""

  private let service: CustomCategorySyncing
  private let session: ProductAccountSessionSnapshot

  init(service: CustomCategorySyncing, session: ProductAccountSessionSnapshot) {
    self.service = service
    self.session = session
  }

  var canSave: Bool {
    !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isSaving
  }

  func load() async {
    isSyncing = true
    defer {
      isSyncing = false
    }

    do {
      let syncedCategory = try await service.loadCategory(session: session)
      apply(syncedCategory)
      errorMessage = nil
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  func save() async {
    let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedName.isEmpty else {
      return
    }

    let trimmedDescription = description.trimmingCharacters(in: .whitespacesAndNewlines)
    isSaving = true
    defer {
      isSaving = false
    }

    do {
      let savedCategory = try await service.saveCategory(
        CustomCategory(
          name: trimmedName,
          description: trimmedDescription.isEmpty ? nil : trimmedDescription
        ),
        session: session
      )
      apply(savedCategory)
      errorMessage = nil
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  func delete() async {
    isSaving = true
    defer {
      isSaving = false
    }

    do {
      try await service.deleteCategory(session: session)
      apply(nil)
      errorMessage = nil
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  private func apply(_ syncedCategory: CustomCategory?) {
    category = syncedCategory
    name = syncedCategory?.name ?? ""
    description = syncedCategory?.description ?? ""
  }
}

private struct CustomCategoryPanel: View {
  @Bindable var viewModel: CustomCategoryViewModel

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack {
        VStack(alignment: .leading, spacing: 4) {
          Text("Product Categories")
            .font(.headline)
          Text(
            "Custom categories sync between trusted devices separately from provider folders or labels."
          )
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }

        Spacer()

        Button {
          Task {
            await viewModel.load()
          }
        } label: {
          Label("Refresh", systemImage: "arrow.clockwise")
        }
        .buttonStyle(.bordered)
        .disabled(viewModel.isSyncing)
      }

      VStack(alignment: .leading, spacing: 12) {
        TextField("Category name", text: $viewModel.name)
          .textFieldStyle(.roundedBorder)

        TextField("Optional category description", text: $viewModel.description, axis: .vertical)
          .lineLimit(2...4)
          .textFieldStyle(.roundedBorder)
      }

      HStack {
        Button(viewModel.category == nil ? "Create Category" : "Save Category") {
          Task {
            await viewModel.save()
          }
        }
        .buttonStyle(.borderedProminent)
        .disabled(!viewModel.canSave)

        if viewModel.category != nil {
          Button("Delete", role: .destructive) {
            Task {
              await viewModel.delete()
            }
          }
          .buttonStyle(.bordered)
          .disabled(viewModel.isSaving)
        }
      }

      if viewModel.isSyncing {
        ProgressView("Syncing category...")
      }

      if let errorMessage = viewModel.errorMessage {
        Text(errorMessage)
          .foregroundStyle(.red)
          .font(.footnote)
      }
    }
  }
}

#Preview {
  AccountView(
    session: ProductAccountSession(
      appleSignInService: PreviewAppleSignInService(
        credential: AppleSignInCredential(
          appleUserIdentifier: "apple-user-preview",
          identityToken: "preview-token"
        )
      ),
      productAccountService: PreviewProductAccountService(response: .preview)
    ),
    snapshot: ProductAccountSessionSnapshot(
      appleUserIdentifier: "apple-user-preview",
      identityToken: "preview-token",
      productAccountId: "productAccountFixtureId",
      trustedDeviceId: "trustedDeviceFixtureId"
    )
  )
}
