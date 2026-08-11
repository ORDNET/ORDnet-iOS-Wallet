import SwiftUI

/// First-run: create a new wallet or import an existing one.
/// Port of the extension's setup view (V11) — including BIP44 / other-wallet
/// presets / legacy / WIF import with address preview.
struct SetupView: View {
    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Spacer()
                OrdplugLogo(size: 84)
                Text("ORD/net Wallet").font(.title.weight(.bold))
                Text("Browse .web3 domains and manage your ORD/net wallet — send & receive BSV, SNS names and BSVmaps on 1SatOrdinals.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
                Spacer()
                VStack(spacing: 12) {
                    NavigationLink {
                        CreateWalletView()
                    } label: {
                        Label("Create a new wallet", systemImage: "plus.circle")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)

                    NavigationLink {
                        ImportWalletView()
                    } label: {
                        Label("Import an existing wallet", systemImage: "square.and.arrow.down")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.ordnetOutline)
                    .controlSize(.large)
                }
                .padding(.horizontal, 24)
                Text("Keys live only on this device, protected by the hardware Keychain and Face ID.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 12)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .ordnetBackground()
        }
    }
}

// MARK: - Create

struct CreateWalletView: View {
    @EnvironmentObject private var store: WalletStore
    @State private var mnemonic = ""
    @State private var address = "—"
    @State private var name = ""
    @State private var error = ""
    @State private var confirmedBackup = false
    @State private var busy = false

    var body: some View {
        Form {
            Section {
                Text("Write these 12 words down in order and keep them offline. They are the ONLY way to restore your wallet.")
                    .font(.footnote)
                    .foregroundStyle(Theme.statusYellow)
            }
            Section("Recovery phrase") {
                if mnemonic.isEmpty {
                    ProgressView()
                } else {
                    let words = mnemonic.split(separator: " ").map(String.init)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 100))], spacing: 8) {
                        ForEach(Array(words.enumerated()), id: \.offset) { i, w in
                            HStack(spacing: 5) {
                                Text("\(i + 1).").font(.caption2).foregroundStyle(.secondary)
                                Text(w).font(.callout.monospaced())
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(.vertical, 4)
                }
                KVRow(k: "First address", v: address, mono: true)
            }
            Section("Account") {
                TextField("Account name (optional)", text: $name)
            }
            Section {
                Toggle("I wrote down my recovery phrase", isOn: $confirmedBackup)
                InlineAlert(kind: .error, text: error)
                Button {
                    create()
                } label: {
                    if busy { ProgressView().frame(maxWidth: .infinity) }
                    else { Text("Create wallet").frame(maxWidth: .infinity) }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!confirmedBackup || mnemonic.isEmpty || busy)
            }
        }
        .ordnetBackground()
        .navigationTitle("New wallet")
        .task { generate() }
    }

    private func generate() {
        do {
            let m = try store.engine.generateMnemonic()
            mnemonic = m
            let wif = try store.engine.wif(fromMnemonic: m, mode: .bip44)
            address = try store.engine.wifToAddress(wif)
        } catch {
            self.error = "Could not generate a wallet: \(error.localizedDescription)"
        }
    }

    private func create() {
        busy = true
        error = ""
        Task {
            do {
                try store.createWallet(mnemonic: mnemonic, accountName: name)
                await store.refreshBalance()
            } catch {
                self.error = error.localizedDescription
            }
            busy = false
        }
    }
}

// MARK: - Import

struct ImportWalletView: View {
    @EnvironmentObject private var store: WalletStore

    enum Seg: String, CaseIterable, Identifiable {
        case bip44 = "BIP44"
        case other = "Other wallet"
        case legacy = "Legacy"
        case wif = "WIF"
        var id: String { rawValue }
    }

    @State private var seg: Seg = .bip44
    @State private var mnemonic = ""
    @State private var wifInput = ""
    @State private var name = ""
    @State private var presets: [[String: Any]] = []
    @State private var presetId = "ordplug"
    @State private var customPath = "m/44'/236'/0'/0/0"
    @State private var pin = ""
    @State private var previewRows: [(String, String)] = []
    @State private var error = ""
    @State private var busy = false

    private var preset: [String: Any]? { presets.first { ($0["id"] as? String) == presetId } }
    private var isCustom: Bool { (preset?["custom"] as? Bool) == true }
    private var needsPin: Bool { (preset?["pin"] as? Bool) == true }

    private var hint: String {
        switch seg {
        case .bip44:  return "Standard BSV derivation (m/44'/236'/0'/0/0) — compatible with most BSV wallets."
        case .other:  return (preset?["note"] as? String) ?? "Pick the app where this wallet was created; the matching derivation path is applied automatically."
        case .legacy: return "ORD/net V9 derivation — use this to restore a wallet created in an earlier ORD/plug extension version."
        case .wif:    return "Paste a single private key in WIF format (starts with K, L or 5)."
        }
    }

    var body: some View {
        Form {
            Section {
                Picker("Import type", selection: $seg) {
                    ForEach(Seg.allCases) { s in Text(s.rawValue).tag(s) }
                }
                .pickerStyle(.segmented)
                Text(hint).font(.footnote).foregroundStyle(.secondary)
            }

            if seg == .other {
                Section("Source wallet") {
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
                        TextField("Wallet PIN (passphrase)", text: $pin)
                            .keyboardType(.numberPad)
                    }
                }
            }

            if seg == .wif {
                Section("Private key") {
                    SecureField("WIF private key", text: $wifInput)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                }
            } else {
                Section("Recovery phrase") {
                    TextEditor(text: $mnemonic)
                        .frame(minHeight: 80)
                        .font(.callout.monospaced())
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                }
                if seg == .other {
                    Section {
                        Button("Preview address") { preview() }
                        ForEach(previewRows, id: \.0) { row in
                            KVRow(k: row.0, v: row.1, mono: true)
                        }
                        if !previewRows.isEmpty {
                            Text("This is the address that will be imported. If your coins are on a different address, try another wallet or a custom path.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            Section("Account") {
                TextField("Account name (optional)", text: $name)
            }

            Section {
                InlineAlert(kind: .error, text: error)
                Button {
                    doImport()
                } label: {
                    if busy { ProgressView().frame(maxWidth: .infinity) }
                    else { Text("Import wallet").frame(maxWidth: .infinity) }
                }
                .buttonStyle(.borderedProminent)
                .disabled(busy)
            }
        }
        .ordnetBackground()
        .navigationTitle("Import wallet")
        .task {
            presets = (try? store.engine.array("walletPresets")) ?? []
        }
    }

    private func importMode() -> (ImportMode, String?, String) {
        switch seg {
        case .bip44:  return (.bip44, nil, "")
        case .legacy: return (.legacy, nil, "")
        case .wif:    return (.wif, nil, "")
        case .other:
            let path = isCustom ? customPath.trimmingCharacters(in: .whitespaces) : (preset?["path"] as? String ?? Fees.bip44Path)
            return (.path, path, needsPin ? pin : "")
        }
    }

    private func preview() {
        error = ""
        previewRows = []
        let m = mnemonic.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard (try? store.engine.validateMnemonic(m)) == true else {
            error = "Enter a valid recovery phrase first."
            return
        }
        let mainPath = isCustom ? customPath.trimmingCharacters(in: .whitespaces) : (preset?["path"] as? String ?? Fees.bip44Path)
        let pinVal = needsPin ? pin : ""
        func tryPath(_ label: String, _ path: String) {
            if let w = try? store.engine.string("mnemonicToWifPath", ["mnemonic": m, "path": path, "passphrase": pinVal]),
               let a = try? store.engine.wifToAddress(w) {
                previewRows.append((label, a))
            } else {
                previewRows.append((label, "invalid path"))
            }
        }
        tryPath("\((preset?["name"] as? String) ?? "wallet") (main)", mainPath)
        for (i, alt) in ((preset?["alt"] as? [String]) ?? []).enumerated() {
            tryPath("alt \(i + 1) (\(alt))", alt)
        }
    }

    private func doImport() {
        busy = true
        error = ""
        Task {
            do {
                let (mode, path, pinVal) = importMode()
                let r = try store.resolveImport(mode: mode, mnemonic: mnemonic, wifInput: wifInput,
                                                presetPath: path, pin: pinVal)
                try store.importWallet(r, accountName: name)
                await store.refreshBalance()
            } catch {
                self.error = error.localizedDescription
            }
            busy = false
        }
    }
}
