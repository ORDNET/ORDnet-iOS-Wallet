import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var store: WalletStore
    @State private var autolock = 15
    @State private var confirmRemove = false

    var body: some View {
        Form {
            Section("Accounts") {
                NavigationLink { AccountsView() } label: {
                    Label("Manage accounts", systemImage: "person.2")
                }
                NavigationLink { BackupView(accountIndex: store.active) } label: {
                    Label("Backup / reveal secret", systemImage: "key")
                }
            }

            Section("Security") {
                Picker("Auto-lock", selection: $autolock) {
                    Text("After 5 minutes").tag(5)
                    Text("After 15 minutes").tag(15)
                    Text("After 1 hour").tag(60)
                    Text("Never").tag(0)
                }
                .onChange(of: autolock) { _, v in store.autolockMinutes = v }
                Button {
                    store.lock()
                } label: {
                    Label("Lock now", systemImage: "lock")
                }
                NavigationLink { ConnectedSitesView() } label: {
                    Label("Connected sites", systemImage: "link")
                }
                // v2.6 — verleende BRC-100-permissies inzien en intrekken
                NavigationLink { Brc100GrantsView() } label: {
                    Label("BRC-100 permissions", systemImage: "checkmark.shield")
                }
            }

            Section("Address book") {
                NavigationLink { AddressBookView() } label: {
                    Label("Trusted recipients", systemImage: "book")
                }
            }

            Section {
                if confirmRemove {
                    Text("This deletes your keys from this device. Coins are only recoverable with your recovery phrase or WIF backup. Are you sure?")
                        .font(.footnote)
                        .foregroundStyle(Theme.statusRed)
                    HStack {
                        Button("Keep wallet") { confirmRemove = false }
                            .buttonStyle(.ordnetOutline)
                        Spacer()
                        Button("Remove wallet", role: .destructive) { store.removeWallet() }
                            .buttonStyle(.borderedProminent)
                    }
                } else {
                    Button(role: .destructive) {
                        confirmRemove = true
                    } label: {
                        Label("Remove wallet from this device", systemImage: "trash")
                    }
                }
            } footer: {
                Text("ORD/net Wallet for iOS · engine parity with Chrome extension V3.4 · keys never leave the Secure Enclave-protected Keychain.")
            }
        }
        .ordnetBackground()
        .navigationTitle("Settings")
        .onAppear { autolock = store.autolockMinutes }
    }
}

// MARK: - Accounts

struct AccountsView: View {
    @EnvironmentObject private var store: WalletStore
    @State private var confirmRemove: Int? = nil
    @State private var renaming: Int? = nil
    @State private var renameText = ""
    @State private var showAdd = false
    @State private var error = ""

    var body: some View {
        List {
            Section("\(store.accounts.count) account\(store.accounts.count == 1 ? "" : "s")") {
                ForEach(Array(store.accounts.enumerated()), id: \.element.id) { i, a in
                    accountRow(i, a)
                }
            }
            Section {
                InlineAlert(kind: .error, text: error)
                Button {
                    showAdd = true
                } label: {
                    Label("Add account", systemImage: "plus")
                }
            }
        }
        .ordnetBackground()
        .navigationTitle("Accounts")
        .sheet(isPresented: $showAdd) {
            AddAccountSheet()
        }
    }

    @ViewBuilder
    private func accountRow(_ i: Int, _ a: Account) -> some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().fill(Color.secondary.opacity(0.15))
                Text(String((a.name.first ?? "A")).uppercased())
                    .font(.callout.weight(.bold))
            }
            .frame(width: 34, height: 34)

            VStack(alignment: .leading, spacing: 2) {
                if renaming == i {
                    TextField("Name", text: $renameText, onCommit: {
                        store.renameAccount(i, to: renameText)
                        renaming = nil
                    })
                    .font(.callout)
                } else {
                    HStack(spacing: 6) {
                        Text(a.name).font(.callout.weight(.medium))
                        if i == store.active {
                            Text("active")
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Capsule().fill(Theme.statusGreen.opacity(0.15)))
                                .foregroundStyle(Theme.statusGreen)
                        }
                    }
                }
                Text(a.address)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Menu {
                if i != store.active {
                    Button { store.setActive(i) } label: { Label("Use this account", systemImage: "arrow.right.circle") }
                }
                Button {
                    renameText = a.name
                    renaming = i
                } label: { Label("Rename", systemImage: "pencil") }
                NavigationLink { BackupView(accountIndex: i) } label: {
                    Label("Export key / backup", systemImage: "key")
                }
                if store.accounts.count > 1 {
                    if confirmRemove == i {
                        Button(role: .destructive) {
                            store.removeAccount(i)
                            confirmRemove = nil
                        } label: { Label("Confirm remove", systemImage: "checkmark") }
                    } else {
                        Button(role: .destructive) {
                            confirmRemove = i
                        } label: { Label("Remove… (tap again to confirm)", systemImage: "trash") }
                    }
                }
            } label: {
                Image(systemName: "ellipsis.circle").foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { if i != store.active { store.setActive(i) } }
    }
}

struct AddAccountSheet: View {
    @EnvironmentObject private var store: WalletStore
    @Environment(\.dismiss) private var dismiss

    enum Mode: String, CaseIterable, Identifiable {
        case generate = "Generate new"
        case importKey = "Import"
        var id: String { rawValue }
    }
    @State private var mode: Mode = .generate
    @State private var seg: ImportWalletView.Seg = .bip44
    @State private var mnemonic = ""
    @State private var wifInput = ""
    @State private var name = ""
    @State private var presets: [[String: Any]] = []
    @State private var presetId = "ordplug"
    @State private var customPath = "m/44'/236'/0'/0/0"
    @State private var pin = ""
    @State private var error = ""

    private var preset: [String: Any]? { presets.first { ($0["id"] as? String) == presetId } }
    private var isCustom: Bool { (preset?["custom"] as? Bool) == true }
    private var needsPin: Bool { (preset?["pin"] as? Bool) == true }

    var body: some View {
        NavigationStack {
            Form {
                Picker("Mode", selection: $mode) {
                    ForEach(Mode.allCases) { m in Text(m.rawValue).tag(m) }
                }
                .pickerStyle(.segmented)

                if mode == .importKey {
                    Picker("Type", selection: $seg) {
                        ForEach(ImportWalletView.Seg.allCases) { s in Text(s.rawValue).tag(s) }
                    }
                    .pickerStyle(.segmented)

                    if seg == .other {
                        Picker("Wallet", selection: $presetId) {
                            ForEach(presets.indices, id: \.self) { i in
                                let p = presets[i]
                                Text((p["name"] as? String) ?? "").tag((p["id"] as? String) ?? "")
                            }
                        }
                        if isCustom {
                            TextField("Derivation path", text: $customPath)
                                .font(.callout.monospaced())
                                .autocorrectionDisabled()
                                .textInputAutocapitalization(.never)
                        }
                        if needsPin {
                            TextField("Wallet PIN (passphrase)", text: $pin).keyboardType(.numberPad)
                        }
                    }
                    if seg == .wif {
                        SecureField("WIF private key", text: $wifInput)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                    } else {
                        TextEditor(text: $mnemonic)
                            .frame(minHeight: 70)
                            .font(.callout.monospaced())
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                    }
                }

                TextField("Account name (optional)", text: $name)

                InlineAlert(kind: .error, text: error)
                Button("Add account") { add() }
                    .buttonStyle(.borderedProminent)
                    .frame(maxWidth: .infinity)
            }
            .ordnetBackground()
            .navigationTitle("Add account")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            .task { presets = (try? store.engine.array("walletPresets")) ?? [] }
        }
    }

    private func add() {
        error = ""
        do {
            if mode == .generate {
                try store.addAccount(name: name, result: nil)
            } else {
                let m: ImportMode
                var path: String? = nil
                var pinVal = ""
                switch seg {
                case .bip44: m = .bip44
                case .legacy: m = .legacy
                case .wif: m = .wif
                case .other:
                    m = .path
                    path = isCustom ? customPath.trimmingCharacters(in: .whitespaces) : (preset?["path"] as? String)
                    pinVal = needsPin ? pin : ""
                }
                let r = try store.resolveImport(mode: m, mnemonic: mnemonic, wifInput: wifInput, presetPath: path, pin: pinVal)
                try store.addAccount(name: name, result: r)
            }
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: - Backup (Face ID gated reveal, port of the password-gated reveal)

struct BackupView: View {
    @EnvironmentObject private var store: WalletStore
    let accountIndex: Int

    @State private var revealed = false
    @State private var error = ""
    @State private var note = ""
    @State private var copied = ""

    private var account: Account? {
        store.accounts.indices.contains(accountIndex) ? store.accounts[accountIndex] : nil
    }

    var body: some View {
        Form {
            if let a = account {
                Section {
                    KVRow(k: "Account", v: "\(a.name) · \(a.originLabel)")
                }
                if !revealed {
                    Section {
                        Text("Your secret is protected by Face ID. Never share it — anyone with the phrase or WIF controls the coins.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        InlineAlert(kind: .error, text: error)
                        Button {
                            reveal()
                        } label: {
                            Label("Reveal secret", systemImage: "faceid")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                    }
                } else {
                    if let phrase = store.sessionPhrases[a.address] {
                        Section("Recovery phrase (\(a.origin == "legacy" ? "legacy" : "BIP44"))") {
                            Text(phrase)
                                .font(.callout.monospaced())
                                .textSelection(.enabled)
                            Button {
                                UIPasteboard.general.string = phrase
                                copied = "Recovery phrase copied to clipboard."
                            } label: {
                                Label("Copy phrase", systemImage: "doc.on.doc")
                            }
                        }
                    } else if !note.isEmpty {
                        Section { InlineAlert(kind: .success, text: note) }
                    }
                    Section("Private key (WIF)") {
                        Text(a.wif)
                            .font(.callout.monospaced())
                            .textSelection(.enabled)
                        Button {
                            UIPasteboard.general.string = a.wif
                            copied = "WIF copied to clipboard."
                        } label: {
                            Label("Copy WIF", systemImage: "doc.on.doc")
                        }
                    }
                    Section {
                        InlineAlert(kind: .success, text: copied)
                        Text("Anything copied to the clipboard can be read by other apps — paste it into your password manager and clear the clipboard.")
                            .font(.caption)
                            .foregroundStyle(Theme.statusYellow)
                    }
                }
            }
        }
        .ordnetBackground()
        .navigationTitle("Backup")
        .onDisappear { revealed = false }
    }

    private func reveal() {
        error = ""
        Task {
            do {
                try await Keychain.authenticate(reason: "Reveal the backup secret for this account")
                if let a = account, store.sessionPhrases[a.address] == nil {
                    note = (a.origin == "wif" || a.origin == "random")
                        ? "This account has no recovery phrase (it was added from a private key). Back up the WIF below."
                        : "The recovery phrase is not held in memory for this account. Back up the WIF below, or re-import the account from its phrase to reveal it."
                }
                revealed = true
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

// MARK: - Address book

struct AddressBookView: View {
    @EnvironmentObject private var store: WalletStore
    var prefillAddress: String = ""

    @State private var name = ""
    @State private var address = ""
    @State private var error = ""

    var body: some View {
        List {
            Section("Add trusted recipient") {
                TextField("Label (e.g. \"Cold storage\")", text: $name)
                TextField("BSV address", text: $address)
                    .font(.callout.monospaced())
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                InlineAlert(kind: .error, text: error)
                Button("Add") {
                    error = ""
                    do {
                        try store.bookAdd(name: name, address: address.trimmingCharacters(in: .whitespaces))
                        name = ""; address = ""
                    } catch { self.error = error.localizedDescription }
                }
            }
            Section {
                if store.addressBook.isEmpty {
                    Text("No saved addresses yet. Add trusted recipients here so you can pick them when sending.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(store.addressBook.sorted { $0.name < $1.name }) { e in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(e.name).font(.callout.weight(.medium))
                            Text(e.address).font(.caption2.monospaced()).foregroundStyle(.secondary)
                        }
                        .swipeActions {
                            Button(role: .destructive) {
                                store.bookRemove(address: e.address)
                            } label: { Label("Remove", systemImage: "trash") }
                        }
                    }
                }
            }
        }
        .ordnetBackground()
        .navigationTitle("Address book")
        .onAppear { if !prefillAddress.isEmpty { address = prefillAddress } }
    }
}

// MARK: - Connected sites

struct ConnectedSitesView: View {
    @EnvironmentObject private var store: WalletStore

    var body: some View {
        List {
            let origins = store.connectedSites.filter { $0.value }.keys.sorted()
            if origins.isEmpty {
                Text("No sites are connected in this session. Sites connect when you approve a wallet request in the .web3 browser.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(origins, id: \.self) { o in
                    HStack {
                        Image(systemName: "link").foregroundStyle(.secondary)
                        Text(o.replacingOccurrences(of: "https://", with: ""))
                            .font(.callout)
                        Spacer()
                        Button(role: .destructive) {
                            store.disconnectSite(o)
                        } label: { Image(systemName: "trash") }
                    }
                }
            }
        }
        .ordnetBackground()
        .navigationTitle("Connected sites")
    }
}
