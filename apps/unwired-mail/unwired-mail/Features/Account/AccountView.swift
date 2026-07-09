import SwiftUI

struct AccountView: View {
  let session: ProductAccountSession
  let snapshot: ProductAccountSessionSnapshot

  @State private var categoryViewModel: CustomCategoryViewModel
  @State private var gmailViewModel: GmailProviderConnectionViewModel

  init(
    session: ProductAccountSession,
    snapshot: ProductAccountSessionSnapshot,
    categorySyncService: CustomCategorySyncing = CustomCategorySyncService(),
    gmailConnectionService: GmailProviderConnecting = GmailProviderConnectionService()
  ) {
    self.session = session
    self.snapshot = snapshot
    _categoryViewModel = State(
      initialValue: CustomCategoryViewModel(
        service: categorySyncService,
        session: snapshot
      )
    )
    _gmailViewModel = State(
      initialValue: GmailProviderConnectionViewModel(
        service: gmailConnectionService,
        session: snapshot
      )
    )
  }

  var body: some View {
    ScrollView {
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

        GmailProviderConnectionPanel(viewModel: gmailViewModel)

        SmokeView(service: ConvexBackendHealthService())

        Button("Sign Out", role: .destructive) {
          session.signOut()
        }
        .buttonStyle(.bordered)
      }
      .padding(32)
      .frame(maxWidth: .infinity, alignment: .topLeading)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .task {
      await categoryViewModel.load()
      await gmailViewModel.load()
    }
  }
}

@MainActor
@Observable
private final class GmailProviderConnectionViewModel {
  var accessToken = ""
  var connection: GmailProviderConnectionStatus?
  var emailAddress = ""
  var errorMessage: String?
  var isConnecting = false
  var isLoading = false
  var providerAccountIdentifier = ""
  var refreshToken = ""

  private let service: GmailProviderConnecting
  private let session: ProductAccountSessionSnapshot

  init(service: GmailProviderConnecting, session: ProductAccountSessionSnapshot) {
    self.service = service
    self.session = session
  }

  var canConnect: Bool {
    !isConnecting
      && !isLoading
      && !emailAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && !providerAccountIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && !accessToken.isEmpty
      && !refreshToken.isEmpty
  }

  var isEditingDisabled: Bool {
    isConnecting || isLoading
  }

  func load() async {
    isLoading = true
    defer {
      isLoading = false
    }

    do {
      connection = try await service.loadConnection(session: session)
      errorMessage = nil
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  func connect() async {
    let trimmedEmailAddress = emailAddress.trimmingCharacters(in: .whitespacesAndNewlines)
    let trimmedProviderAccountIdentifier = providerAccountIdentifier.trimmingCharacters(
      in: .whitespacesAndNewlines
    )
    guard
      !trimmedEmailAddress.isEmpty,
      !trimmedProviderAccountIdentifier.isEmpty,
      !accessToken.isEmpty,
      !refreshToken.isEmpty
    else {
      return
    }

    isConnecting = true
    defer {
      isConnecting = false
    }

    do {
      connection = try await service.completeConnection(
        verifiedAccount: VerifiedGmailAccount(
          emailAddress: trimmedEmailAddress,
          providerAccountIdentifier: trimmedProviderAccountIdentifier,
          tokens: GmailProviderTokens(
            accessToken: accessToken,
            refreshToken: refreshToken
          )
        ),
        session: session
      )
      accessToken = ""
      refreshToken = ""
      errorMessage = nil
    } catch {
      errorMessage = error.localizedDescription
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

  private var hasLoadedCategory = false
  private let service: CustomCategorySyncing
  private let session: ProductAccountSessionSnapshot

  init(service: CustomCategorySyncing, session: ProductAccountSessionSnapshot) {
    self.service = service
    self.session = session
  }

  var canSave: Bool {
    let hasName = !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    return hasLoadedCategory && hasName && !isSaving && !isSyncing
  }

  var isEditingDisabled: Bool {
    isSaving || isSyncing
  }

  func load() async {
    isSyncing = true
    defer {
      isSyncing = false
    }

    do {
      let syncedCategory = try await service.loadCategory(session: session)
      apply(syncedCategory)
      hasLoadedCategory = true
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
        .disabled(viewModel.isEditingDisabled)
      }

      VStack(alignment: .leading, spacing: 12) {
        TextField("Category name", text: $viewModel.name)
          .textFieldStyle(.roundedBorder)
          .disabled(viewModel.isEditingDisabled)

        TextField("Optional category description", text: $viewModel.description, axis: .vertical)
          .lineLimit(2...4)
          .textFieldStyle(.roundedBorder)
          .disabled(viewModel.isEditingDisabled)
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
          .disabled(viewModel.isEditingDisabled)
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

private struct GmailProviderConnectionPanel: View {
  @Bindable var viewModel: GmailProviderConnectionViewModel

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack {
        VStack(alignment: .leading, spacing: 4) {
          Text("Gmail")
            .font(.headline)
          if let connection = viewModel.connection {
            Label(connection.emailAddress, systemImage: "checkmark.circle.fill")
              .foregroundStyle(.green)
              .font(.subheadline)
            Text("Provider account: \(connection.providerAccountIdentifier)")
              .font(.footnote)
              .foregroundStyle(.secondary)
          } else {
            Text("Not connected")
              .font(.subheadline)
              .foregroundStyle(.secondary)
          }
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
        .disabled(viewModel.isEditingDisabled)
      }

      VStack(alignment: .leading, spacing: 12) {
        TextField("Gmail address", text: $viewModel.emailAddress)
          .textFieldStyle(.roundedBorder)
          .disabled(viewModel.isEditingDisabled)

        TextField("Gmail account ID", text: $viewModel.providerAccountIdentifier)
          .textFieldStyle(.roundedBorder)
          .disabled(viewModel.isEditingDisabled)

        SecureField("Access token", text: $viewModel.accessToken)
          .textFieldStyle(.roundedBorder)
          .disabled(viewModel.isEditingDisabled)

        SecureField("Refresh token", text: $viewModel.refreshToken)
          .textFieldStyle(.roundedBorder)
          .disabled(viewModel.isEditingDisabled)
      }

      Button(viewModel.connection == nil ? "Connect Gmail" : "Update Gmail") {
        Task {
          await viewModel.connect()
        }
      }
      .buttonStyle(.borderedProminent)
      .disabled(!viewModel.canConnect)

      if viewModel.isLoading || viewModel.isConnecting {
        ProgressView(viewModel.isConnecting ? "Connecting Gmail..." : "Loading Gmail...")
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
