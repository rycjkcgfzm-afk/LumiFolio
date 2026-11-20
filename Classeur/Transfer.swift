import SwiftUI
import SwiftData
import UniformTypeIdentifiers

/// Une carte telle qu'elle est écrite dans le fichier d'export (JSON).
struct CardExport: Codable {
    var cardId: String
    var name: String
    var localId: String
    var setId: String
    var setName: String
    var imageBase: String?
    var variant: String
    var condition: String
    var quantity: Int
    var isWishlist: Bool
    var unitPrice: Double?
    var photo: Data?
    var addedAt: Date
    var language: String?   // absent des fichiers exportés avant l'ajout de la langue
    var targetPrice: Double?
    var purchasePrice: Double?
    var gradeCompany: String?
    var gradeNote: Double?
    var gradedValue: Double?
    var customPrice: Double?
    var printingKey: String?
    var printingLabel: String?
    var priceLog: String?
    var binders: String?
}

extension OwnedCard {
    var export: CardExport {
        CardExport(cardId: cardId, name: name, localId: localId, setId: setId, setName: setName,
                   imageBase: imageBase, variant: variantRaw, condition: conditionRaw, quantity: quantity,
                   isWishlist: isWishlist, unitPrice: unitPrice, photo: photo, addedAt: addedAt, language: language,
                   targetPrice: targetPrice, purchasePrice: purchasePrice, gradeCompany: gradeCompany,
                   gradeNote: gradeNote, gradedValue: gradedValue, customPrice: customPrice,
                   printingKey: printingKey, printingLabel: printingLabel, priceLog: priceLog, binders: binders)
    }

    convenience init(_ e: CardExport) {
        self.init()
        cardId = e.cardId; name = e.name; localId = e.localId; setId = e.setId; setName = e.setName
        imageBase = e.imageBase; variantRaw = e.variant; conditionRaw = e.condition
        quantity = min(max(e.quantity, 1), 999)   // mêmes bornes que le réglage « Quantité » de la fiche
        isWishlist = e.isWishlist; unitPrice = e.unitPrice
        photo = e.photo; addedAt = e.addedAt; language = e.language ?? "FR"; targetPrice = e.targetPrice
        purchasePrice = e.purchasePrice; gradeCompany = e.gradeCompany; gradeNote = e.gradeNote
        gradedValue = e.gradedValue; customPrice = e.customPrice
        printingKey = e.printingKey; printingLabel = e.printingLabel; priceLog = e.priceLog ?? ""; binders = e.binders ?? ""
    }
}

/// Fichier .json contenant toute la collection et la wishlist.
struct CollectionFile: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: Data

    init(cards: [OwnedCard]) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .prettyPrinted
        data = try encoder.encode(cards.map(\.export))
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

/// Ajoute les cartes du fichier à la collection. Une carte déjà présente (même carte, variante, état, liste)
/// n'est pas dupliquée : on garde la plus grande quantité et on récupère la photo si elle manquait.
@MainActor
func importCollection(from url: URL, into context: ModelContext, existing: [OwnedCard]) -> String {
    let access = url.startAccessingSecurityScopedResource()
    defer { if access { url.stopAccessingSecurityScopedResource() } }
    do {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        // Fichier venu d'ailleurs : on refuse l'énorme (risque de saturer la mémoire) avant de le lire.
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= 500_000_000 else { return "Ce fichier est trop volumineux pour être une collection Lumifolio." }
        let items = try decoder.decode([CardExport].self, from: Data(contentsOf: url))
        var added = 0, merged = 0
        var known = existing   // + les cartes ajoutées par ce fichier, pour fusionner ses propres doublons
        for item in items {
            if let match = known.first(where: {
                $0.cardId == item.cardId && $0.variantRaw == item.variant &&
                $0.conditionRaw == item.condition && $0.isWishlist == item.isWishlist &&
                $0.language == (item.language ?? "FR") && $0.printingKey == item.printingKey
            }) {
                match.quantity = min(max(match.quantity, item.quantity), 999)
                if match.photo == nil { match.photo = item.photo }
                if match.purchasePrice == nil { match.purchasePrice = item.purchasePrice }
                if match.gradeCompany == nil, item.gradeCompany != nil {
                    match.gradeCompany = item.gradeCompany; match.gradeNote = item.gradeNote; match.gradedValue = item.gradedValue
                }
                if match.priceLog.isEmpty { match.priceLog = item.priceLog ?? "" }
                let binders = (item.binders ?? "").split(separator: "\n").map(String.init)
                match.binderList = match.binderList + binders.filter { !match.binderList.contains($0) }
                merged += 1
            } else {
                let card = OwnedCard(item)
                context.insert(card)
                known.append(card)
                added += 1
            }
        }
        return "\(added) carte(s) ajoutée(s), \(merged) déjà présente(s)."
    } catch {
        return "Ce fichier n'a pas pu être importé : \(error.localizedDescription)"
    }
}

/// Sauvegarde automatique : un fichier réécrit au plus une fois par jour dans un dossier choisi par l'utilisateur
/// (iCloud Drive conseillé). Le dossier est mémorisé par un « signet » d'accès accordé une seule fois.
enum AutoBackup {
    private static let folderKey = "dossierSauvegarde"
    private static let lastKey = "derniereSauvegarde"
    static let fileName = "Lumifolio - sauvegarde.json"
    static let historyFolder = "Lumifolio - historique"
    static let historyCount = 7

    #if os(macOS)
    private static let createOptions: URL.BookmarkCreationOptions = .withSecurityScope
    private static let resolveOptions: URL.BookmarkResolutionOptions = .withSecurityScope
    #else
    private static let createOptions: URL.BookmarkCreationOptions = []
    private static let resolveOptions: URL.BookmarkResolutionOptions = []
    #endif

    static var lastDate: Date? { UserDefaults.standard.object(forKey: lastKey) as? Date }
    static var isConfigured: Bool { UserDefaults.standard.data(forKey: folderKey) != nil }

    static func setFolder(_ url: URL) throws {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let bookmark = try url.bookmarkData(options: createOptions, includingResourceValuesForKeys: nil, relativeTo: nil)
        UserDefaults.standard.set(bookmark, forKey: folderKey)
        UserDefaults.standard.removeObject(forKey: lastKey)   // première sauvegarde tout de suite
    }

    private static func folder() throws -> URL? {
        guard let bookmark = UserDefaults.standard.data(forKey: folderKey) else { return nil }
        var stale = false
        let url = try URL(resolvingBookmarkData: bookmark, options: resolveOptions, relativeTo: nil, bookmarkDataIsStale: &stale)
        if stale { try? setFolder(url) }
        return url
    }

    /// Copie datée du jour dans « Lumifolio - historique », en ne gardant que les `historyCount` plus récentes :
    /// une suppression par erreur reste rattrapable plusieurs jours.
    private static func keepHistory(_ data: Data, in dir: URL) throws {
        let folder = dir.appending(path: historyFolder)
        let files = FileManager.default
        try files.createDirectory(at: folder, withIntermediateDirectories: true)
        let day = Date().formatted(.iso8601.year().month().day())   // 2026-11-18 : l'ordre alphabétique est chronologique
        try data.write(to: folder.appending(path: "sauvegarde \(day).json"), options: .atomic)
        let copies = try files.contentsOfDirectory(atPath: folder.path())
            .filter { $0.hasPrefix("sauvegarde ") && $0.hasSuffix(".json") }
            .sorted()
        for old in copies.dropLast(historyCount) {   // seulement nos propres copies datées
            try? files.removeItem(at: folder.appending(path: old))
        }
    }

    /// Écrit la sauvegarde si la dernière date d'hier ou avant (ou toujours si `force`).
    /// Renvoie un message à afficher, ou nil quand il n'y avait rien à faire.
    @MainActor
    static func run(cards: [OwnedCard], force: Bool = false) -> String? {
        if !force, let last = lastDate, Calendar.current.isDateInToday(last) { return nil }
        // Ne jamais écraser une bonne sauvegarde par une collection vide (app réinstallée, données perdues…).
        guard !cards.isEmpty else { return force ? "Rien à sauvegarder : la collection est vide." : nil }
        do {
            guard let dir = try folder() else { return force ? "Choisis d'abord un dossier de sauvegarde." : nil }
            let access = dir.startAccessingSecurityScopedResource()
            defer { if access { dir.stopAccessingSecurityScopedResource() } }
            let data = try CollectionFile(cards: cards).data
            try data.write(to: dir.appending(path: fileName), options: .atomic)
            try? keepHistory(data, in: dir)   // l'historique est un bonus : son échec ne bloque pas la sauvegarde
            UserDefaults.standard.set(Date(), forKey: lastKey)
            return force ? "Sauvegarde enregistrée dans « \(dir.lastPathComponent) »." : nil
        } catch {
            return "Sauvegarde automatique impossible : \(error.localizedDescription)"
        }
    }
}
