import Foundation

// Client minimal de l'API TCGdex (gratuite, sans clé) : https://tcgdex.dev

struct CardCount: Decodable, Hashable {
    let total: Int?
    let official: Int?
}

struct CardBrief: Decodable, Identifiable, Hashable {
    let id: String
    let localId: String
    let name: String
    let image: String?
}

struct SetBrief: Decodable, Identifiable, Hashable {
    let id: String
    let name: String
    let cardCount: CardCount?
    let logo: String?
    let symbol: String?
}

struct SerieBrief: Decodable { let id: String; let name: String }
struct SerieDetail: Decodable { let id: String; let name: String; let sets: [SetBrief] }
struct SetGroup: Identifiable { let id: String; let name: String; var sets: [SetBrief] }

struct SetDetail: Decodable {
    let id: String
    let name: String
    let cardCount: CardCount?
    let logo: String?
    let cards: [CardBrief]
}

/// Logos et symboles TCGdex : URL de base sans extension. Beaucoup manquent en français, on retente en anglais.
func assetURLs(_ base: String?) -> [URL] {
    guard let base else { return [] }
    return [base, base.replacingOccurrences(of: "/fr/", with: "/en/")]
        .reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        .compactMap { URL(string: $0 + ".png") }
}

struct CardDetail: Decodable, Identifiable {
    let id: String
    let localId: String
    let name: String
    let image: String?
    let rarity: String?
    let illustrator: String?
    let set: SetBrief
    let variants: Variants?
    let pricing: Pricing?
    let printings: [Printing]   // versions détaillées (tampons…), chacune avec sa propre fiche Cardmarket

    struct Variants: Decodable {
        let normal, reverse, holo, firstEdition: Bool?
    }

    struct Pricing: Decodable {
        let cardmarket: Cardmarket?
        let tcgplayer: TCGPlayerPrices?   // USD, marché US : sert seulement à estimer l'écart 1ère édition / illimitée

        enum CodingKeys: String, CodingKey { case cardmarket, tcgplayer }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            cardmarket = try? c.decodeIfPresent(Cardmarket.self, forKey: .cardmarket)
            tcgplayer = try? c.decodeIfPresent(TCGPlayerPrices.self, forKey: .tcgplayer)
        }
    }

    /// Prix TCGplayer par version (« 1st-edition-holofoil », « unlimited »…). Les champs qui ne sont pas des prix
    /// (« unit », « updated ») sont ignorés.
    struct TCGPlayerPrices: Decodable {
        let byKey: [String: Double]

        private struct Key: CodingKey {
            var stringValue: String
            init?(stringValue: String) { self.stringValue = stringValue }
            var intValue: Int? { nil }
            init?(intValue: Int) { nil }
        }
        private struct Entry: Decodable { let marketPrice, midPrice: Double? }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Key.self)
            var result: [String: Double] = [:]
            for key in c.allKeys {
                if let entry = try? c.decode(Entry.self, forKey: key), let price = entry.marketPrice ?? entry.midPrice, price > 0 {
                    result[key.stringValue.lowercased()] = price
                }
            }
            byKey = result
        }
    }

    struct Cardmarket: Decodable {
        let avg, low, trend, trendHolo: Double?
        enum CodingKeys: String, CodingKey {
            case avg, low, trend
            case trendHolo = "trend-holo"   // prix des versions reverse sur Cardmarket
        }
    }

    /// Une version précise d'une carte (champ `variants_detailed` de TCGdex) : tampon, type, finition, prix propre.
    struct Printing: Decodable, Hashable {
        let type: String?
        let subtype: String?
        let size: String?
        let stamp: [String]?
        let foil: String?
        let cardmarket: Cardmarket?

        enum CodingKeys: String, CodingKey { case type, subtype, size, stamp, foil, pricing }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            type = try? c.decodeIfPresent(String.self, forKey: .type)
            subtype = try? c.decodeIfPresent(String.self, forKey: .subtype)
            size = try? c.decodeIfPresent(String.self, forKey: .size)
            // `stamp` est une liste, mais on accepte aussi une simple chaîne.
            if let list = try? c.decodeIfPresent([String].self, forKey: .stamp) { stamp = list }
            else if let one = try? c.decodeIfPresent(String.self, forKey: .stamp) { stamp = [one] }
            else { stamp = nil }
            foil = try? c.decodeIfPresent(String.self, forKey: .foil)
            let pricing = try? c.decodeIfPresent(Pricing.self, forKey: .pricing)
            cardmarket = pricing?.cardmarket
        }

        static func == (a: Printing, b: Printing) -> Bool { a.key == b.key }
        func hash(into hasher: inout Hasher) { hasher.combine(key) }

        /// Reverse holo, ou tampon « logo de l'extension » (porté par les reverses des anciennes extensions).
        var isReverseLike: Bool {
            type?.lowercased() == "reverse" || stamps.contains { $0.lowercased().contains("logo") }
        }

        /// Tampons hors « 1ère édition » (déjà gérée comme variante).
        var stamps: [String] { (stamp ?? []).filter { $0 != "1st-edition" } }

        /// Identifiant stable, stocké avec la carte : « pre-release|holo ».
        var key: String { ([stamps.joined(separator: "+"), type ?? "", foil ?? "", size ?? ""]).joined(separator: "|") }

        var label: String {
            var parts = stamps.map(stampLabel)
            if let type = type?.lowercased(), type != "normal" { parts.append(type == "reverse" ? "Reverse" : type.capitalized) }
            if let foil = foil?.lowercased(), !["normal", "standard", "none"].contains(foil) { parts.append(foil.capitalized) }
            if size == "jumbo" { parts.append("Jumbo") }
            return parts.joined(separator: " · ")
        }

        /// Prix Cardmarket de cette version (nil si TCGdex n'en a pas : on n'emprunte jamais le prix d'une autre version).
        var price: Double? {
            guard let cm = cardmarket else { return nil }
            if type?.lowercased() == "reverse" { return cm.trendHolo ?? cm.trend ?? cm.avg }
            return cm.trend ?? cm.avg
        }
    }

    enum CodingKeys: String, CodingKey {
        case id, localId, name, image, rarity, illustrator, set, variants, pricing
        case variantsDetailed = "variants_detailed"
    }

    /// Un élément illisible de `variants_detailed` est ignoré au lieu de faire échouer toute la liste.
    private struct Lossy: Decodable {
        let value: Printing?
        init(from decoder: Decoder) throws { value = try? Printing(from: decoder) }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        localId = try c.decode(String.self, forKey: .localId)
        name = try c.decode(String.self, forKey: .name)
        image = try c.decodeIfPresent(String.self, forKey: .image)
        rarity = try c.decodeIfPresent(String.self, forKey: .rarity)
        illustrator = try c.decodeIfPresent(String.self, forKey: .illustrator)
        set = try c.decode(SetBrief.self, forKey: .set)
        // Variantes et prix sont des bonus : un format inattendu ne doit pas casser toute la carte.
        variants = try? c.decodeIfPresent(Variants.self, forKey: .variants)
        pricing = try? c.decodeIfPresent(Pricing.self, forKey: .pricing)
        let detailed = try? c.decodeIfPresent([Lossy].self, forKey: .variantsDetailed)
        printings = detailed?.compactMap(\.value) ?? []
    }

    /// Versions tamponnées proposées à l'ajout (une seule par clé).
    var stampedPrintings: [Printing] {
        var seen = Set<String>()
        return printings.filter { !$0.stamps.isEmpty && seen.insert($0.key).inserted }
    }

    /// Prix d'une version précise si elle est choisie, sinon prix de la variante classique.
    func price(for variant: Variant, printing key: String?) -> Double? {
        if let key, !key.isEmpty {
            guard let printing = printings.first(where: { $0.key == key }) else { return nil }
            if let own = printing.price { return own }
            // Cartes anciennes (époque EX…) : la version « logo de l'extension » est la reverse holo,
            // que Cardmarket cote comme la reverse de la carte.
            if printing.isReverseLike { return pricing?.cardmarket?.trendHolo }
            return nil
        }
        return price(for: variant)
    }

    var availableVariants: [Variant] {
        guard let v = variants else { return [.normal] }
        let list: [Variant] = [
            v.normal == true ? .normal : nil,
            v.reverse == true ? .reverse : nil,
            v.holo == true ? .holo : nil,
            v.firstEdition == true ? .firstEdition : nil,
        ].compactMap { $0 }
        return list.isEmpty ? [.normal] : list
    }

    func price(for variant: Variant) -> Double? {
        guard let cm = pricing?.cardmarket else { return nil }
        if variant == .reverse, let reverse = cm.trendHolo { return reverse }
        let base = cm.trend ?? cm.avg
        // Cardmarket ne sépare pas 1ère édition et illimitée : on applique l'écart observé sur TCGplayer.
        if variant == .firstEdition, let base, let ratio = firstEditionRatio { return base * ratio }
        return base
    }

    /// Prix 1ère édition ÷ prix édition illimitée sur TCGplayer, pour la même finition (holo ou non). nil si inconnu.
    /// Les clés sont triées : le résultat ne dépend pas de l'ordre (aléatoire) du dictionnaire.
    var firstEditionRatio: Double? {
        guard let prices = pricing?.tcgplayer?.byKey else { return nil }
        let keys = prices.keys.sorted()
        let isFirst = { (k: String) in k.contains("1st") || k.contains("first") }
        let firstKeys = keys.filter(isFirst)
        // Carte qui n'existe qu'en holo : on compare les prix holo ; sinon les prix non holo.
        let holo = variants?.holo == true && variants?.normal != true
        guard let first = firstKeys.first(where: { $0.contains("holo") == holo }) ?? firstKeys.first else { return nil }
        let firstHolo = first.contains("holo")
        guard let unlimited = keys.first(where: { $0.contains("unlimited") && $0.contains("holo") == firstHolo })
                ?? keys.first(where: { !isFirst($0) && !$0.contains("reverse") && $0.contains("holo") == firstHolo }),
              let firstPrice = prices[first], let unlimitedPrice = prices[unlimited], unlimitedPrice > 0 else { return nil }
        let ratio = firstPrice / unlimitedPrice
        return ratio.isFinite && ratio > 0 ? ratio : nil
    }
}

enum APIError: Error {
    case status(Int)
}

enum TCGdex {
    static let base = URL(string: "https://api.tcgdex.net/v2/fr")!

    static func get<T: Decodable>(_ path: String, query: [URLQueryItem] = []) async throws -> T {
        var comps = URLComponents(url: base.appending(path: path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { comps.queryItems = query }
        let (data, response) = try await URLSession.shared.data(from: comps.url!)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw APIError.status(http.statusCode)
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    /// Recherche par nom et/ou filtres (rareté, type, illustrateur). Les champs vides sont ignorés.
    static func search(name: String, rarity: String = "", type: String = "", illustrator: String = "") async throws -> [CardBrief] {
        let filters = [("name", name), ("rarity", rarity), ("types", type), ("illustrator", illustrator)]
            .filter { !$0.1.isEmpty }
            .map { URLQueryItem(name: $0.0, value: $0.1) }
        do {
            return try await get("cards", query: filters + [URLQueryItem(name: "pagination:itemsPerPage", value: "250")])
        } catch APIError.status(404) {
            return []
        }
    }

    /// Listes de valeurs possibles : "rarities", "types"…
    static func values(_ endpoint: String) async throws -> [String] { try await get(endpoint) }

    static func card(_ id: String) async throws -> CardDetail { try await get("cards/\(id)") }
    static func sets() async throws -> [SetBrief] { try await get("sets") }
    static func set(_ id: String) async throws -> SetDetail { try await get("sets/\(id)") }
    static func series() async throws -> [SerieBrief] { try await get("series") }
    static func serie(_ id: String) async throws -> SerieDetail { try await get("series/\(id)") }

    /// Extensions regroupées par série (Écarlate et Violet, Épée et Bouclier…), dans l'ordre de `sets`.
    /// Les extensions sans série connue finissent dans « Autres ».
    static func grouped(_ sets: [SetBrief]) async throws -> [SetGroup] {
        let briefs = try await series()
        let details = try await withThrowingTaskGroup(of: SerieDetail.self) { group in
            for b in briefs { group.addTask { try await serie(b.id) } }
            var all: [SerieDetail] = []
            for try await detail in group { all.append(detail) }
            return all
        }
        var serieOf: [String: SerieDetail] = [:]
        for d in details { for s in d.sets { serieOf[s.id] = d } }
        var groups: [SetGroup] = []
        var index: [String: Int] = [:]
        for set in sets {
            let key = serieOf[set.id]?.id ?? "autres"
            if let i = index[key] {
                groups[i].sets.append(set)
            } else {
                index[key] = groups.count
                groups.append(SetGroup(id: key, name: serieOf[set.id]?.name ?? "Autres", sets: [set]))
            }
        }
        return groups
    }
}

/// Image de secours sur pokemontcg.io, déduite de l'id TCGdex : « sv06-001 » → sv6/1.png,
/// « sv03.5-199 » → sv3pt5/199.png. Si la correspondance rate, l'URL renvoie 404 et on passe à la suite.
func pokemonTCGImageURL(cardId: String, high: Bool = false) -> URL? {
    guard let dash = cardId.lastIndex(of: "-") else { return nil }
    var set = String(cardId[..<dash]).lowercased().replacingOccurrences(of: ".5", with: "pt5")
    set = set.replacing(/([a-z])0+(\d)/) { "\($0.1)\($0.2)" }   // sv06 → sv6
    var number = String(cardId[cardId.index(after: dash)...])
    if let n = Int(number) { number = String(n) }                 // 001 → 1, garde SWSH001 tel quel
    return URL(string: "https://images.pokemontcg.io/\(set)/\(number)\(high ? "_hires" : "").png")
}

/// TCGdex renvoie une URL de base ; on ajoute la qualité et le format.
func cardImageURL(_ base: String?, high: Bool = false) -> URL? {
    guard let base else { return nil }
    return URL(string: base + (high ? "/high.png" : "/low.png"))
}

/// Nom lisible d'un tampon TCGdex (« pre-release » → « Prerelease »).
func stampLabel(_ raw: String) -> String {
    let known = [
        "pre-release": "Prerelease", "w-promo": "W Promo", "staff": "Staff",
        "30th-anniversary": "30 ans", "20th-anniversary": "20 ans", "25th-anniversary": "25 ans",
        "league": "Ligue", "league-1st": "Ligue 1er", "league-2nd": "Ligue 2e", "league-3rd": "Ligue 3e",
        "worlds": "Championnats du monde", "regional-championship": "Régionaux",
        "national-championship": "Nationaux", "pokemon-center": "Pokémon Center", "set-logo": "Logo de l'extension",
    ]
    let text = raw.replacingOccurrences(of: "-", with: " ")
    return known[raw] ?? (text.prefix(1).uppercased() + text.dropFirst())   // « Logo de la série », pas « Logo De La Série »
}
