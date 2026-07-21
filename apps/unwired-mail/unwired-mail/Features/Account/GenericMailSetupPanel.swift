import SwiftUI

@MainActor
@Observable
final class GenericMailSetupViewModel {
  var authorizationMethod = MailAuthorizationMethod.password
  var connectedDefinition: GenericMailConnectionDefinition?
  var credential = ""
  private var discoveredIncomingEndpoints: [GenericMailEndpoint] = []
  var discoverySource: String?
  var emailAddress = ""
  var errorMessage: String?
  var incomingHostname = ""
  var incomingPort = "993"
  var incomingProtocol = GenericMailProtocol.imap
  var incomingSecurity = MailTransportSecurity.implicitTLS
  var isConnecting = false
  var outgoingHostname = ""
  var outgoingPort = "465"
  var outgoingSecurity = MailTransportSecurity.implicitTLS
  var roleMappings = Dictionary(
    uniqueKeysWithValues: CanonicalMailboxRole.allCases.map { ($0, "") }
  )
  var rolesRequiringMapping: [CanonicalMailboxRole] = []
  var username = ""

  private let productAccountId: ProductAccountId
  private let isSessionCurrent: () -> Bool
  private var isValid = true
  private var roleMappingEmailAddress: String?
  private let service: GenericMailSetupService

  init(
    productAccountId: ProductAccountId,
    isSessionCurrent: @escaping () -> Bool,
    service: GenericMailSetupService = GenericMailSetupService()
  ) {
    self.productAccountId = productAccountId
    self.isSessionCurrent = isSessionCurrent
    self.service = service
  }

  var credentialLabel: String { authorizationMethod.displayName }

  var showsMailboxRoles: Bool {
    incomingProtocol == .imap
      && roleMappingEmailAddress == normalizedEmailAddress
      && !rolesRequiringMapping.isEmpty
  }

  func discover() {
    let trimmedEmail = emailAddress.trimmingCharacters(in: .whitespacesAndNewlines)
    connectedDefinition = nil
    resetRoleMappingState()
    if username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      username = trimmedEmail
    }
    guard let result = service.discover(emailAddress: trimmedEmail) else {
      discoveredIncomingEndpoints = []
      authorizationMethod = .password
      incomingHostname = ""
      incomingPort = ""
      incomingProtocol = .imap
      incomingSecurity = .implicitTLS
      outgoingHostname = ""
      outgoingPort = ""
      outgoingSecurity = .implicitTLS
      discoverySource = "No reviewed provider entry found. Enter server settings manually."
      errorMessage = nil
      return
    }

    discoveredIncomingEndpoints = result.incomingEndpoints
    if let incoming = discoveredIncomingEndpoints.first {
      incomingProtocol = incoming.mailProtocol
      incomingHostname = incoming.hostname
      incomingPort = String(incoming.port)
      incomingSecurity = incoming.security
    }
    outgoingHostname = result.outgoingEndpoint.hostname
    outgoingPort = String(result.outgoingEndpoint.port)
    outgoingSecurity = result.outgoingEndpoint.security
    authorizationMethod = result.preferredAuthorizationMethod
    discoverySource = result.sourceName
    errorMessage = nil
  }

  func loadSaved() {
    do {
      guard
        let authorization = try service.loadAuthorization(
          emailAddress: emailAddress,
          productAccountId: productAccountId
        )
      else {
        errorMessage = "No device-local setup is saved for this address."
        return
      }
      apply(authorization.definition)
      connectedDefinition = authorization.definition
      credential = ""
      discoverySource = "Loaded saved settings. Re-enter authorization to verify changes."
      errorMessage = nil
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  func selectIncomingProtocol(_ mailProtocol: GenericMailProtocol) {
    incomingProtocol = mailProtocol
    rolesRequiringMapping = []
    guard
      let endpoint = discoveredIncomingEndpoints.first(where: {
        $0.mailProtocol == mailProtocol
      })
    else { return }
    incomingHostname = endpoint.hostname
    incomingPort = String(endpoint.port)
    incomingSecurity = endpoint.security
  }

  func connect() async {
    guard !isConnecting, isValid, isSessionCurrent() else { return }
    isConnecting = true
    defer { isConnecting = false }

    do {
      connectedDefinition = try await service.authorize(
        draft: GenericMailSetupDraft(
          authorizationMethod: authorizationMethod,
          emailAddress: emailAddress,
          incomingEndpoint: GenericMailEndpoint(
            mailProtocol: incomingProtocol,
            hostname: incomingHostname,
            port: Int(incomingPort) ?? 0,
            security: incomingSecurity
          ),
          outgoingEndpoint: GenericMailEndpoint(
            mailProtocol: .smtp,
            hostname: outgoingHostname,
            port: Int(outgoingPort) ?? 0,
            security: outgoingSecurity
          ),
          roleMappings: roleMappingEmailAddress == normalizedEmailAddress ? roleMappings : [:],
          username: username
        ),
        credential: credential,
        productAccountId: productAccountId,
        isSessionCurrent: { self.isValid && self.isSessionCurrent() }
      )
      credential = ""
      rolesRequiringMapping = []
      errorMessage = nil
    } catch let GenericMailSetupError.missingRoleMappings(discovered, missing) {
      for (role, mailbox) in discovered {
        roleMappings[role] = mailbox
      }
      roleMappingEmailAddress = normalizedEmailAddress
      rolesRequiringMapping = missing
      let names = missing.map(\.displayName).joined(separator: ", ")
      errorMessage = "Map the remaining provider mailboxes: \(names)."
    } catch is CancellationError {
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  func invalidate() {
    isValid = false
  }

  private func apply(_ definition: GenericMailConnectionDefinition) {
    authorizationMethod = definition.authorizationMethod
    emailAddress = definition.emailAddress
    incomingHostname = definition.incomingEndpoint.hostname
    incomingPort = String(definition.incomingEndpoint.port)
    incomingProtocol = definition.incomingEndpoint.mailProtocol
    incomingSecurity = definition.incomingEndpoint.security
    outgoingHostname = definition.outgoingEndpoint.hostname
    outgoingPort = String(definition.outgoingEndpoint.port)
    outgoingSecurity = definition.outgoingEndpoint.security
    roleMappings = definition.roleMappings
    roleMappingEmailAddress = definition.emailAddress
    rolesRequiringMapping = CanonicalMailboxRole.allCases
    username = definition.username
  }

  private var normalizedEmailAddress: String {
    emailAddress.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
  }

  private func resetRoleMappingState() {
    roleMappingEmailAddress = nil
    roleMappings = [:]
    rolesRequiringMapping = []
  }
}

struct GenericMailSetupPanel: View {
  @Bindable var viewModel: GenericMailSetupViewModel
  @State private var connectTask: Task<Void, Never>?

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      VStack(alignment: .leading, spacing: 4) {
        Text("Other Mail Server")
          .font(.headline)
        Text("Server settings and credentials stay on this device.")
          .font(.subheadline)
          .foregroundStyle(.secondary)
      }

      HStack {
        TextField("Mailbox email address", text: $viewModel.emailAddress)
          .textContentType(.emailAddress)
          .textInputAutocapitalization(.never)
          .autocorrectionDisabled()
        Button("Discover Settings") {
          viewModel.discover()
        }
        .buttonStyle(.bordered)
        .disabled(viewModel.isConnecting)
      }

      Button("Load Saved Setup") {
        viewModel.loadSaved()
      }
      .buttonStyle(.bordered)
      .disabled(viewModel.isConnecting)

      if let discoverySource = viewModel.discoverySource {
        Text(discoverySource)
          .font(.footnote)
          .foregroundStyle(.secondary)
      }

      TextField("Username", text: $viewModel.username)
        .textContentType(.username)
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()

      Picker(
        "Incoming protocol",
        selection: Binding(
          get: { viewModel.incomingProtocol },
          set: { viewModel.selectIncomingProtocol($0) }
        )
      ) {
        Text("IMAP").tag(GenericMailProtocol.imap)
        Text("POP3 (legacy)").tag(GenericMailProtocol.pop3)
      }
      .pickerStyle(.segmented)

      endpointEditor(
        title: viewModel.incomingProtocol.displayName,
        hostname: $viewModel.incomingHostname,
        port: $viewModel.incomingPort,
        security: $viewModel.incomingSecurity
      )
      endpointEditor(
        title: "SMTP",
        hostname: $viewModel.outgoingHostname,
        port: $viewModel.outgoingPort,
        security: $viewModel.outgoingSecurity
      )

      if viewModel.showsMailboxRoles {
        VStack(alignment: .leading, spacing: 8) {
          Text("Mailbox Roles")
            .font(.subheadline.bold())
          Text("Map only the roles the provider did not identify unambiguously.")
            .font(.footnote)
            .foregroundStyle(.secondary)
          ForEach(viewModel.rolesRequiringMapping) { role in
            TextField(
              role.displayName,
              text: Binding(
                get: { viewModel.roleMappings[role] ?? "" },
                set: { viewModel.roleMappings[role] = $0 }
              )
            )
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
          }
        }
      } else if viewModel.incomingProtocol == .pop3 {
        Text("POP3 uses product-owned local roles and does not claim server folder support.")
          .font(.footnote)
          .foregroundStyle(.secondary)
      }

      Picker("Authorization", selection: $viewModel.authorizationMethod) {
        ForEach(MailAuthorizationMethod.allCases) { method in
          Text(method.displayName).tag(method)
        }
      }
      SecureField(viewModel.credentialLabel, text: $viewModel.credential)
        .textContentType(.password)

      Button {
        connectTask?.cancel()
        connectTask = Task {
          await viewModel.connect()
        }
      } label: {
        Label("Verify and Save on This Device", systemImage: "lock.shield")
          .frame(minHeight: 32)
      }
      .buttonStyle(.borderedProminent)
      .disabled(viewModel.isConnecting)

      if viewModel.isConnecting {
        ProgressView("Verifying secure mail transport...")
      }

      if let definition = viewModel.connectedDefinition {
        Label(
          "Saved \(definition.emailAddress) on this device",
          systemImage: "checkmark.circle.fill"
        )
        .foregroundStyle(.green)
        .font(.subheadline)
      }

      if let errorMessage = viewModel.errorMessage {
        Text(errorMessage)
          .foregroundStyle(.red)
          .font(.footnote)
      }
    }
    .onDisappear {
      connectTask?.cancel()
    }
  }

  private func endpointEditor(
    title: String,
    hostname: Binding<String>,
    port: Binding<String>,
    security: Binding<MailTransportSecurity>
  ) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(title)
        .font(.subheadline.bold())
      HStack {
        TextField("Server hostname", text: hostname)
          .textInputAutocapitalization(.never)
          .autocorrectionDisabled()
        TextField("Port", text: port)
          .frame(width: 80)
      }
      Picker("Transport security", selection: security) {
        ForEach(MailTransportSecurity.allCases) { option in
          Text(option.displayName).tag(option)
        }
      }
      .pickerStyle(.segmented)
    }
  }
}
