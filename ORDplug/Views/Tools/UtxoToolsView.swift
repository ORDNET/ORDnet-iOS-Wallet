import SwiftUI

/// UTXO tools (v2.3) — split & combine, its own tab between ORD/ner and
/// Settings. Both operate on the ordinal-protected UTXO set (1-sat
/// inscriptions can never be spent here) and carry the ORDnet service fees
/// like every other transaction in the app. Two-tap confirm, errors inline.
struct UtxoToolsView: View {
    @EnvironmentObject private var store: WalletStore

    @State private var utxoCount = 0
    @State private var utxoTotal = 0
    @State private var utxoLargest = 0
    @State private var loading = true

    // split form
    @State private var countText = "10"
    @State private var satsText = ""
    @State private var confirmingSplit = false
    // combine
    @State private var confirmingCombine = false

    @State private var error = ""
    @State private var success = ""
    @State private var busy = false
    @State private var fees: Fees?

    private var splitCount: Int { Int(countText) ?? 0 }
    private var splitSats: Int { Int(satsText.replacingOccurrences(of: ".", with: "")) ?? 0 }
    private var splitTotal: Int { splitCount * splitSats }

    var body: some View {
        Form {
            Section("Your spendable UTXOs") {
                if loading {
                    ProgressView()
                } else {
                    KVRow(k: "Count", v: "\(utxoCount)")
                    KVRow(k: "Total", v: "\(Fmt.bsv(utxoTotal)) BSV (\(Fmt.sats(utxoTotal)) sats)")
                    KVRow(k: "Largest", v: "\(Fmt.sats(utxoLargest)) sats")
                    Text("1-sat ordinal inscriptions are excluded by design — they can never be spent here.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Split — make N UTXOs of X sats each") {
                TextField("Number of UTXOs (2–200)", text: $countText)
                    .keyboardType(.numberPad)
                    .onChange(of: countText) { confirmingSplit = false }
                TextField("Sats per UTXO (min 547)", text: $satsText)
                    .keyboardType(.numberPad)
                    .onChange(of: satsText) { confirmingSplit = false }
                if splitCount >= 2 && splitSats >= 547, let f = fees {
                    Text("= \(Fmt.sats(splitTotal)) sats into outputs + ~miner fee + \(Fmt.bsv(f.totalServiceFees)) BSV service")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if confirmingSplit {
                    KVRow(k: "Confirm", v: "\(splitCount) × \(Fmt.sats(splitSats)) sats → your own address")
                    Button {
                        runSplit()
                    } label: {
                        if busy { ProgressView().frame(maxWidth: .infinity) }
                        else { Text("Confirm & split").frame(maxWidth: .infinity) }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(busy)
                } else {
                    Button("Split…") { prepareSplit() }
                        .disabled(busy || loading)
                }
            }

            Section("Combine — merge everything into one UTXO") {
                Text("Spends ALL spendable UTXOs into a single output to your own address. Useful after many small transactions.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if confirmingCombine {
                    KVRow(k: "Confirm", v: "\(utxoCount) UTXOs → 1 output to your own address")
                    Button {
                        runCombine()
                    } label: {
                        if busy { ProgressView().frame(maxWidth: .infinity) }
                        else { Text("Confirm & combine").frame(maxWidth: .infinity) }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(busy)
                } else {
                    Button("Combine…") {
                        error = ""; success = ""
                        guard utxoCount >= 2 else { error = "Nothing to combine — you have \(utxoCount) spendable UTXO\(utxoCount == 1 ? "" : "s")."; return }
                        confirmingCombine = true
                        confirmingSplit = false
                    }
                    .disabled(busy || loading)
                }
            }

            Section {
                InlineAlert(kind: .error, text: error)
                InlineAlert(kind: .success, text: success)
            }
        }
        .ordnetBackground()
        .keyboardDismissBar()   // v2.5.1: numberPads had no way out
        .navigationTitle("UTXO tools")
        .refreshable { await refresh() }
        .task {
            fees = try? store.engine.fees()
            await refresh()
        }
    }

    private func refresh() async {
        loading = true
        if let u = try? await store.utxos() {
            utxoCount = u.count
            utxoTotal = u.compactMap { $0["satoshis"] as? Int }.reduce(0, +)
            utxoLargest = u.compactMap { $0["satoshis"] as? Int }.max() ?? 0
        } else {
            utxoCount = 0; utxoTotal = 0; utxoLargest = 0
        }
        loading = false
    }

    private func prepareSplit() {
        error = ""; success = ""
        confirmingCombine = false
        guard splitCount >= 2, splitCount <= 200 else { error = "Choose between 2 and 200 UTXOs."; return }
        guard splitSats >= 547 else { error = "Each UTXO needs at least 547 sats (above dust)."; return }
        guard let f = fees else { error = "Fee schedule not loaded yet — try again."; return }
        let needed = splitTotal + f.totalServiceFees
        guard utxoTotal > needed else {
            error = "Insufficient spendable balance: this split needs ~\(Fmt.sats(needed)) sats + miner fee, you have \(Fmt.sats(utxoTotal))."
            return
        }
        confirmingSplit = true
    }

    private func runSplit() {
        error = ""; success = ""; busy = true
        Task {
            do {
                let txid = try await store.splitUtxos(count: splitCount, satsEach: splitSats)
                success = "Split done! \(splitCount) × \(Fmt.sats(splitSats)) sats created. TXID: \(txid)"
                confirmingSplit = false
                await refresh()
                await store.refreshBalance()
            } catch {
                self.error = error.localizedDescription
            }
            busy = false
        }
    }

    private func runCombine() {
        error = ""; success = ""; busy = true
        Task {
            do {
                let (txid, outSat) = try await store.combineUtxos()
                success = "Combined into one UTXO of \(Fmt.sats(outSat)) sats. TXID: \(txid)"
                confirmingCombine = false
                await refresh()
                await store.refreshBalance()
            } catch {
                self.error = error.localizedDescription
            }
            busy = false
        }
    }
}
