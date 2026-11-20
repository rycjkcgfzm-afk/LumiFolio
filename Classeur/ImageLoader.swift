import Foundation
import ImageIO
import CryptoKit
import SwiftUI

/// Télécharge les images de cartes en écartant les « fausses » images :
/// certains serveurs renvoient un dos de carte (code 200) au lieu d'une erreur quand l'image n'existe pas.
/// On demande une fois une carte inexistante à chaque serveur pour connaître son image de remplacement,
/// puis on rejette toute réponse identique à celle-ci.
actor ImageLoader {
    static let shared = ImageLoader()

    private let cache = NSCache<NSURL, CGImageWrapper>()
    private var placeholders: [String: Data?] = [:]   // clé : serveur + langue + qualité
    // Dans une même extension, deux cartes n'ont jamais exactement la même image :
    // des octets identiques pour deux adresses de la même extension = un dos de carte posé en guise d'image.
    // (D'une extension à l'autre, une réédition ou une Énergie peut légitimement avoir la même image.)
    private var firstURLForData: [String: URL] = [:]   // clé : extension + empreinte SHA-256
    private var rejectedData: Set<Data> = []
    private var rejectedURLs: Set<URL> = []

    func isRejected(_ url: URL) -> Bool { rejectedURLs.contains(url) }

    func image(_ url: URL) async -> CGImage? {
        if let hit = cache.object(forKey: url as NSURL) { return hit.image }
        guard let data = await fetch(url) else { return nil }
        let key = placeholderKey(url)
        if placeholders[key] == nil {
            placeholders[key] = .some(await fetch(probeURL(for: url)))
        }
        if let placeholder = placeholders[key] ?? nil, placeholder == data { return nil }
        let digest = Data(SHA256.hash(data: data))
        if rejectedData.contains(digest) { rejectedURLs.insert(url); return nil }
        let sameSetKey = setKey(url) + "|" + digest.base64EncodedString()
        if let first = firstURLForData[sameSetKey], first != url {
            rejectedData.insert(digest)
            rejectedURLs.formUnion([first, url])
            cache.removeObject(forKey: first as NSURL)
            // La première carte qui affichait ce dos doit se recharger.
            await MainActor.run { NotificationCenter.default.post(name: .cardPlaceholderLearned, object: nil) }
            return nil
        }
        firstURLForData[sameSetKey] = url
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        cache.setObject(CGImageWrapper(image), forKey: url as NSURL)
        return image
    }

    private func fetch(_ url: URL) async -> Data? {
        // Cache d'abord : une image déjà téléchargée s'affiche même sans internet.
        let request = URLRequest(url: url, cachePolicy: .returnCacheDataElseLoad)
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              http.url == url   // une redirection = image par défaut
        else { return nil }
        return data
    }

    private func placeholderKey(_ url: URL) -> String {
        let parts = url.pathComponents
        return [url.host ?? "", parts.count > 1 ? parts[1] : "", url.lastPathComponent.contains("hires") || url.lastPathComponent.hasPrefix("high") ? "high" : "low"].joined(separator: "|")
    }

    /// Serveur + dossier de l'extension : « assets.tcgdex.net/fr/swsh/swsh3 », « images.pokemontcg.io/sv6 ».
    private func setKey(_ url: URL) -> String {
        let parts = url.pathComponents.dropFirst()   // sans le « / » initial
        let drop = url.host == "images.pokemontcg.io" ? 1 : 2   // fichier (+ numéro de carte chez TCGdex)
        return ([url.host ?? ""] + parts.dropLast(drop)).joined(separator: "/")
    }

    /// Même adresse, mais avec un numéro de carte qui n'existe pas.
    private func probeURL(for url: URL) -> URL {
        var parts = url.pathComponents
        if url.host == "images.pokemontcg.io" {
            parts[parts.count - 1] = url.lastPathComponent.contains("_hires") ? "999999_hires.png" : "999999.png"
        } else if parts.count >= 2 {
            parts[parts.count - 2] = "999999"
        }
        var comps = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        comps.path = "/" + parts.dropFirst().joined(separator: "/")
        return comps.url ?? url
    }
}

extension Notification.Name {
    static let cardPlaceholderLearned = Notification.Name("cardPlaceholderLearned")
}

final class CGImageWrapper {
    let image: CGImage
    init(_ image: CGImage) { self.image = image }
}
