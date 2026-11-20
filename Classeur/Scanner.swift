import SwiftUI

/// Ce que le scan a lu sur une carte.
enum ScanResult: Equatable {
    case numbered(number: Int, total: Int)     // « 123/198 »
    case promo(setId: String, number: Int)     // « SVP 085 », « SWSH001 »…

    var label: String {
        switch self {
        case .numbered(let n, let t): "\(n)/\(t)"
        case .promo(let set, let n): "\(set.uppercased()) \(n)"
        }
    }
}

/// Numéro classique d'abord, sinon numéro de promo (Black Star).
func parseScan(_ text: String) -> ScanResult? {
    if let n = parseCardNumber(text) { return .numbered(number: n.number, total: n.total) }
    if let m = text.firstMatch(of: /\b(SVP|MEP)\s?0*(\d{1,3})\b/), let n = Int(m.2), n > 0 {
        return .promo(setId: m.1.lowercased(), number: n)
    }
    if let m = text.firstMatch(of: /\b(SWSH|SM|XY|BW)(\d{2,3})\b/), let n = Int(m.2), n > 0 {
        return .promo(setId: m.1.lowercased() + "p", number: n)   // swshp, smp, xyp, bwp chez TCGdex
    }
    return nil
}

/// Lit le numéro imprimé en bas d'une carte : « 123/198 », « 045 / 091 » → (123, 198).
func parseCardNumber(_ text: String) -> (number: Int, total: Int)? {
    guard let match = text.firstMatch(of: /(\d{1,3})\s*\/\s*(\d{2,3})/),
          let number = Int(match.1), let total = Int(match.2),
          number > 0, total >= 10 else { return nil }
    return (number, total)
}

extension TCGdex {
    static func cards(for result: ScanResult) async throws -> [CardBrief] {
        switch result {
        case .numbered(let number, let total):
            return try await cards(number: number, total: total)
        case .promo(let setId, let number):
            // Les numéros de promo mélangent lettres et chiffres (« SWSH001 ») : on compare la partie chiffrée.
            return (try? await set(setId))?.cards.filter { Int($0.localId.filter(\.isNumber)) == number } ?? []
        }
    }

    /// Cartes portant ce numéro dans les extensions qui ont ce nombre officiel de cartes.
    /// Plusieurs extensions peuvent avoir la même taille : on renvoie tous les candidats.
    static func cards(number: Int, total: Int) async throws -> [CardBrief] {
        let candidates = try await sets().filter { $0.cardCount?.official == total }
        return await withTaskGroup(of: [CardBrief].self) { group in
            for set in candidates {
                group.addTask { (try? await TCGdex.set(set.id))?.cards.filter { Int($0.localId) == number } ?? [] }
            }
            var found: [CardBrief] = []
            for await cards in group { found += cards }
            return found
        }
    }
}

#if os(iOS)
import VisionKit

/// Caméra de l'iPhone qui cherche un numéro de carte dans l'image.
struct CardScanner: UIViewControllerRepresentable {
    let onFound: (ScanResult) -> Void

    @MainActor static var isAvailable: Bool {
        DataScannerViewController.isSupported && DataScannerViewController.isAvailable
    }

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(recognizedDataTypes: [.text()],
                                                qualityLevel: .accurate,
                                                isHighlightingEnabled: true)
        scanner.delegate = context.coordinator
        return scanner
    }

    func updateUIViewController(_ scanner: DataScannerViewController, context: Context) {
        if !scanner.isScanning { try? scanner.startScanning() }
    }

    func makeCoordinator() -> Coordinator { Coordinator(onFound: onFound) }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let onFound: (ScanResult) -> Void
        private var done = false

        init(onFound: @escaping (ScanResult) -> Void) { self.onFound = onFound }

        func dataScanner(_ scanner: DataScannerViewController, didAdd added: [RecognizedItem], allItems: [RecognizedItem]) {
            check(allItems)
        }

        func dataScanner(_ scanner: DataScannerViewController, didUpdate updated: [RecognizedItem], allItems: [RecognizedItem]) {
            check(allItems)
        }

        private func check(_ items: [RecognizedItem]) {
            guard !done else { return }
            for case .text(let text) in items {
                if let found = parseScan(text.transcript) {
                    done = true
                    onFound(found)
                    return
                }
            }
        }
    }
}
#endif
