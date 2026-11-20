import Foundation
import SwiftData
import ImageIO
import UniformTypeIdentifiers

enum Variant: String, CaseIterable, Identifiable {
    case normal, reverse, holo, firstEdition
    var id: String { rawValue }
    var label: String {
        switch self {
        case .normal: "Normale"
        case .reverse: "Reverse"
        case .holo: "Holo"
        case .firstEdition: "1ère édition"
        }
    }
}

enum Condition: String, CaseIterable, Identifiable {
    case mint = "Mint"
    case nearMint = "Near Mint"
    case excellent = "Excellent"
    case good = "Bon état"
    case lightPlayed = "Légèrement joué"
    case played = "Joué"
    case poor = "Mauvais"
    var id: String { rawValue }
}

/// Une ligne de la collection (ou de la wishlist) : une carte + variante + état.
@Model
final class OwnedCard {
    // Valeurs par défaut partout : requis si tu actives la synchro iCloud (CloudKit) plus tard.
    var cardId: String = ""
    var name: String = ""
    var localId: String = ""
    var setId: String = ""
    var setName: String = ""
    var imageBase: String?
    var variantRaw: String = Variant.normal.rawValue
    var conditionRaw: String = Condition.nearMint.rawValue
    var quantity: Int = 1
    var isWishlist: Bool = false
    var unitPrice: Double?          // EUR, tendance Cardmarket
    @Attribute(.externalStorage) var photo: Data?   // photo prise par l'utilisateur, prioritaire sur l'image en ligne
    var addedAt: Date = Date()
    var language: String = "FR"
    var targetPrice: Double?   // wishlist : prix max souhaité (alerte « bon prix »)
    @Attribute(.externalStorage) var offlineImage: Data?   // copie de l'image en ligne, pour l'affichage sans internet
    var purchasePrice: Double?   // prix payé par exemplaire (EUR)
    var gradeCompany: String?    // PSA, CGC, PCA, BGS… ; nil = carte non gradée
    var gradeNote: Double?       // ex. 10 ou 9,5
    var gradedValue: Double?     // valeur estimée à la main d'une carte gradée : remplace le prix Cardmarket
    var customPrice: Double?     // inutilisé (ancienne saisie « prix FR ») : gardé pour ne pas migrer la base
    var printingKey: String?     // version tamponnée choisie (clé TCGdex), nil = carte classique
    var printingLabel: String?   // nom lisible du tampon, ex. « Prerelease »
    var priceLog: String = ""    // historique Cardmarket, « horodatage=prix » séparés par « ; » (un point par jour)
    var binders: String = ""     // classeurs perso de l'utilisateur, un nom par ligne

    init() {}   // utilisé par l'import (Transfer.swift)

    init(card: CardDetail, variant: Variant, condition: Condition, quantity: Int, isWishlist: Bool, language: String = "FR",
         printing: CardDetail.Printing? = nil) {
        self.language = language
        cardId = card.id
        name = card.name
        localId = card.localId
        setId = card.set.id
        setName = card.set.name
        imageBase = card.image
        variantRaw = variant.rawValue
        conditionRaw = condition.rawValue
        self.quantity = quantity
        self.isWishlist = isWishlist
        printingKey = printing?.key
        printingLabel = printing?.label
        unitPrice = card.price(for: variant, printing: printing?.key)
        if let unitPrice { logPrice(unitPrice) }
    }

    var variant: Variant {
        get { Variant(rawValue: variantRaw) ?? .normal }
        set { variantRaw = newValue.rawValue }
    }

    var condition: Condition {
        get { Condition(rawValue: conditionRaw) ?? .nearMint }
        set { conditionRaw = newValue.rawValue }
    }
}

let cardLanguages = ["FR", "EN", "JP", "DE", "IT", "ES"]

/// Valeur totale de la collection à une date : sert au graphique d'évolution.
@Model
final class ValueSnapshot {
    var date: Date = Date()
    var value: Double = 0
    init(value: Double) { self.value = value }
}

func eur(_ value: Double) -> String { value.formatted(.currency(code: "EUR")) }

/// Réduit une photo (1200 px max) et la réencode en JPEG pour ne pas alourdir la base.
func compressedPhoto(_ data: Data) -> Data? {
    let options = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                   kCGImageSourceThumbnailMaxPixelSize: 1200,
                   kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
          let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else { return nil }
    return jpegData(image)
}

func jpegData(_ image: CGImage) -> Data? {
    let output = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
    CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
    return CGImageDestinationFinalize(destination) ? output as Data : nil
}

extension OwnedCard {
    /// Carte de la wishlist dont le prix actuel est au niveau du prix souhaité, ou en dessous.
    var isGoodDeal: Bool {
        guard isWishlist, let target = targetPrice, let price = unitPrice else { return false }
        return price <= target
    }
}

// MARK: - Valeur, plus-value, gradation, historique, classeurs

let gradeCompanies = ["PSA", "CGC", "PCA", "BGS", "CCC"]
let gradeNotes: [Double] = stride(from: 10.0, through: 1.0, by: -0.5).map { $0 }

struct PricePoint: Identifiable {
    let date: Date
    let price: Double
    var id: Date { date }
}

/// « +12,30 € » ou « -4,10 € ».
func signedEur(_ value: Double) -> String { (value > 0 ? "+" : "") + eur(value) }

extension OwnedCard {
    /// Valeur retenue pour un exemplaire : estimation de la carte gradée, sinon cote Cardmarket
    /// (toutes langues, tous pays) décotée selon l'état.
    var value: Double? { gradedValue ?? unitPrice.map { $0 * condition.priceFactor } }
    var totalValue: Double { (value ?? 0) * Double(quantity) }

    /// Gain (ou perte) par rapport au prix payé, toutes quantités comprises. nil si le prix payé est inconnu.
    var profit: Double? {
        guard let paid = purchasePrice, let value else { return nil }
        return (value - paid) * Double(quantity)
    }

    var isGraded: Bool { gradeCompany != nil }
    var gradeLabel: String? {
        guard let gradeCompany else { return nil }
        return gradeNote.map { "\(gradeCompany) \($0.formatted())" } ?? gradeCompany
    }

    var priceHistory: [PricePoint] {
        priceLog.split(separator: ";").compactMap { item in
            let parts = item.split(separator: "=")
            guard parts.count == 2, let t = Double(parts[0]), let p = Double(parts[1]) else { return nil }
            return PricePoint(date: Date(timeIntervalSince1970: t), price: p)
        }
    }

    /// Ajoute un point de prix (remplace celui du jour s'il existe ; garde un an d'historique).
    func logPrice(_ price: Double, at date: Date = Date()) {
        var points = priceHistory
        if let last = points.last, Calendar.current.isDate(last.date, inSameDayAs: date) { points.removeLast() }
        points.append(PricePoint(date: date, price: price))
        priceLog = points.suffix(365)
            .map { "\(Int($0.date.timeIntervalSince1970))=\($0.price)" }
            .joined(separator: ";")
    }

    /// Écart entre les deux derniers prix connus (jours différents). nil s'il n'y a pas assez d'historique.
    var priceTrend: Double? {
        let points = priceHistory
        guard points.count >= 2 else { return nil }
        let diff = points[points.count - 1].price - points[points.count - 2].price
        return abs(diff) < 0.005 ? nil : diff
    }

    var binderList: [String] {
        get { binders.split(separator: "\n").map(String.init) }
        set { binders = newValue.joined(separator: "\n") }
    }
}

extension Condition {
    /// Part de la cote (Near Mint) retenue selon l'état. Paliers « Near Mint 100 %, Lightly Played 80 %,
    /// Moderately Played 60 %, Heavily Played 30 % » de ValueMyCards (moyenne des annonces Troll and Toad),
    /// rapprochés des états Cardmarket ; « Légèrement joué » et « Mauvais » sont interpolés.
    var priceFactor: Double {
        switch self {
        case .mint, .nearMint: 1
        case .excellent: 0.8
        case .good: 0.6
        case .lightPlayed: 0.45
        case .played: 0.3
        case .poor: 0.15
        }
    }
}
