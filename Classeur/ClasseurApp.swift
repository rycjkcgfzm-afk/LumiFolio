import ImageIO
import SwiftUI
import SwiftData

@main
struct ClasseurApp: App {
    init() {
        // Les images déjà vues restent disponibles hors connexion (voir ImageLoader.fetch).
        URLCache.shared = URLCache(memoryCapacity: 64 << 20, diskCapacity: 1 << 30)
        #if os(iOS)
        // Titres de navigation en police arrondie, plus marqués.
        func rounded(_ size: CGFloat, _ weight: UIFont.Weight) -> UIFont {
            let base = UIFont.systemFont(ofSize: size, weight: weight)
            return base.fontDescriptor.withDesign(.rounded).map { UIFont(descriptor: $0, size: size) } ?? base
        }
        UINavigationBar.appearance().largeTitleTextAttributes = [.font: rounded(34, .heavy)]
        UINavigationBar.appearance().titleTextAttributes = [.font: rounded(17, .bold)]
        #endif
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(for: [OwnedCard.self, ValueSnapshot.self])
    }
}

struct ContentView: View {
    var body: some View {
        TabView {
            CollectionView()
                .tabItem { Label("Collection", systemImage: "square.grid.2x2") }
            SearchView()
                .tabItem { Label("Recherche", systemImage: "magnifyingglass") }
            SetsView()
                .tabItem { Label("Extensions", systemImage: "books.vertical") }
            WishlistView()
                .tabItem { Label("Wishlist", systemImage: "star") }
        }
        .tint(.classeur)
        .preferredColorScheme(.dark)   // thème « classeur de nuit », assorti à l'icône
        .fontDesign(.rounded)
    }
}

extension Color {
    // Couleurs de l'icône Lumifolio : nuit bleutée et reflets holographiques.
    static let classeur = Color(red: 0.66, green: 0.55, blue: 1.0)        // violet holo
    static let classeurWarm = Color(red: 1.0, green: 0.85, blue: 0.29)    // or holo
    static let nightTop = Color(red: 0.17, green: 0.23, blue: 0.40)
    static let nightBottom = Color(red: 0.07, green: 0.067, blue: 0.09)
    static let holoColors: [Color] = [
        Color(red: 0.50, green: 0.89, blue: 1.0), Color(red: 0.66, green: 0.55, blue: 1.0),
        Color(red: 1.0, green: 0.56, blue: 0.69), Color(red: 1.0, green: 0.85, blue: 0.29),
        Color(red: 0.98, green: 0.60, blue: 0.23),
    ]
}

extension LinearGradient {
    static let night = LinearGradient(colors: [.nightTop, .nightBottom], startPoint: .top, endPoint: .bottom)
    static let holo = LinearGradient(colors: Color.holoColors, startPoint: .topLeading, endPoint: .bottomTrailing)
}

extension View {
    /// Fond bleu nuit derrière les listes, formulaires et défilements.
    func nightBackground() -> some View {
        scrollContentBackground(.hidden)
            .background(LinearGradient.night.ignoresSafeArea())
    }
}

/// Sources essayées dans l'ordre : TCGdex FR, TCGdex EN, pokemontcg.io.
/// Beaucoup de cartes FR n'ont pas d'image chez TCGdex, d'où les replis.
func cardImageURLs(imageBase: String?, cardId: String, high: Bool) -> [URL] {
    var list: [URL] = []
    if let fr = cardImageURL(imageBase, high: high) { list.append(fr) }
    if let base = imageBase, base.contains("/fr/"),
       let en = cardImageURL(base.replacingOccurrences(of: "/fr/", with: "/en/"), high: high) {
        list.append(en)
    }
    if let ptcg = pokemonTCGImageURL(cardId: cardId, high: high) { list.append(ptcg) }
    return list
}

let gridColumns = [GridItem(.adaptive(minimum: 120), spacing: 16)]

struct CardThumb: View {
    let imageBase: String?
    let cardId: String
    var high = false
    var dimmed = false
    var shine = false   // reflet arc-en-ciel des cartes holo / reverse
    var photo: Data? = nil   // photo perso : remplace l'image en ligne
    var missingHint: String? = nil   // texte affiché à la place de « Image indisponible »
    var onResult: ((Bool) -> Void)? = nil   // true : une image s'affiche ; false : aucune trouvée
    @State private var image: CGImage?
    @State private var hovering = false
    @State private var shownURL: URL?
    @State private var failed = false
    @State private var reload = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var urls: [URL] { cardImageURLs(imageBase: imageBase, cardId: cardId, high: high) }

    var body: some View {
        Group {
            if let image {
                Image(decorative: image, scale: 1).resizable().scaledToFit()
                    .transition(.opacity.combined(with: .scale(scale: 0.97)))
            } else if failed {
                missing
            } else {
                loading
            }
        }
        .aspectRatio(63.0 / 88.0, contentMode: .fit)
        .animation(.easeOut(duration: 0.3), value: image != nil)   // fondu à l'arrivée de l'image
        .overlay {
            if shine && image != nil {
                ZStack {
                    LinearGradient(colors: ([.red, .yellow, .green, .cyan, .blue, .purple] as [Color]).map { $0.opacity(0.28) },
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                        .blendMode(.overlay)
                    if !high && !reduceMotion {
                        // Bande de lumière qui traverse la carte quand on fait défiler la collection.
                        LinearGradient(colors: [.clear, .white.opacity(0.35), .clear], startPoint: .leading, endPoint: .trailing)
                            .scaleEffect(x: 0.45)
                            .rotationEffect(.degrees(25))
                            .blendMode(.softLight)
                            .visualEffect { content, proxy in
                                let y = proxy.frame(in: .global).minY
                                let phase = (y / 600).truncatingRemainder(dividingBy: 1)
                                return content.offset(x: (abs(phase) - 0.5) * proxy.size.width * 2.4)
                            }
                    }
                }
                .visualEffect { [reduceMotion] content, proxy in
                    // Les couleurs glissent au défilement (sauf avec « Réduire les animations »).
                    content.hueRotation(.degrees(reduceMotion ? 0 : proxy.frame(in: .global).minY / 3))
                }
                .allowsHitTesting(false)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: high ? 14 : 7, style: .continuous))
        .shadow(color: .black.opacity(dimmed ? 0 : 0.35), radius: hovering ? 10 : 5, y: hovering ? 6 : 3)
        .scaleEffect(hovering && !high ? 1.04 : 1)
        .animation(.spring(duration: 0.25), value: hovering)
        .onHover { hovering = $0 }
        .onReceive(NotificationCenter.default.publisher(for: .cardPlaceholderLearned)) { _ in
            guard let shownURL else { return }
            Task { if await ImageLoader.shared.isRejected(shownURL) { reload += 1 } }
        }
        .task(id: "\(cardId)|\(high)|\(reload)|\(photo?.count ?? 0)") {
            image = nil
            shownURL = nil
            failed = false
            if let photo {
                // Image enregistrée en haute définition : version réduite à la taille d'affichage,
                // décodée en arrière-plan pour ne pas saccader le défilement.
                let maxPixels = high ? 1400 : 480
                if let own = await Task.detached(priority: .userInitiated, operation: { downsampled(photo, maxPixels: maxPixels) }).value {
                    image = own
                    onResult?(true)
                    return
                }
            }
            for url in urls {
                if let found = await ImageLoader.shared.image(url) { image = found; shownURL = url; onResult?(true); return }
                if Task.isCancelled { return }   // cellule sortie de l'écran : on réessaiera au retour
            }
            failed = true
            onResult?(false)
        }
        .grayscale(dimmed ? 1 : 0)
        .opacity(dimmed ? 0.35 : 1)
    }

    private var loading: some View {
        Rectangle().fill(.quaternary).overlay(ProgressView().controlSize(.small))
    }

    private var missing: some View {
        Rectangle()
            .fill(LinearGradient(colors: [.gray.opacity(0.35), .gray.opacity(0.15)], startPoint: .top, endPoint: .bottom))
            .overlay {
                VStack(spacing: 6) {
                    Image(systemName: missingHint == nil ? "photo" : "camera").font(.title2)
                    Text(missingHint ?? "Image indisponible").font(.caption2).multilineTextAlignment(.center)
                }
                .foregroundStyle(.secondary)
                .padding(6)
            }
    }
}

struct OwnedThumb: View {
    let card: OwnedCard

    var body: some View {
        VStack(spacing: 6) {
            CardThumb(imageBase: card.imageBase, cardId: card.cardId, shine: card.variant != .normal,
                      photo: card.photo ?? card.offlineImage, missingHint: "Pas d'image : ajoute ta photo")
                .overlay(alignment: .bottomLeading) {
                    if let grade = card.gradeLabel { GradeBadge(label: grade).offset(x: -4, y: 4) }
                }
                .overlay(alignment: .topTrailing) {
                    if card.quantity > 1 {
                        Text("×\(card.quantity)")
                            .font(.caption.bold())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 7).padding(.vertical, 3)
                            .background(Color.classeur, in: Capsule())
                            .shadow(radius: 2)
                            .offset(x: 6, y: -6)
                    }
                }
            HStack(spacing: 3) {
                Text(card.name).font(.caption.weight(.semibold)).lineLimit(1)
                TrendArrow(trend: card.priceTrend).font(.caption2)
            }
            HStack(spacing: 6) {
                if card.printingLabel != nil {
                    Label("Tampon", systemImage: "seal.fill").foregroundStyle(Color.classeur)
                }
                if card.variant != .normal {
                    Label(card.variant.label, systemImage: "sparkles")
                        .foregroundStyle(Color.classeurWarm)
                }
                if card.isGoodDeal {
                    Label("Bon prix", systemImage: "bell.fill").foregroundStyle(.green).fontWeight(.semibold)
                }
                if card.language != "FR" {
                    Text(card.language).fontWeight(.bold)
                        .padding(.horizontal, 4)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 3))
                }
            }
            .font(.caption2)
        }
    }
}

/// Logo ou symbole d'extension, avec repli si aucune image n'est trouvée.
struct AssetImage<Fallback: View>: View {
    let base: String?
    @ViewBuilder var fallback: Fallback
    @State private var image: CGImage?

    var body: some View {
        Group {
            if let image {
                Image(decorative: image, scale: 1).resizable().scaledToFit()
            } else {
                fallback
            }
        }
        .task(id: base) {
            image = nil
            for url in assetURLs(base) {
                if let found = await ImageLoader.shared.image(url) { image = found; return }
            }
        }
    }
}

/// Barre de progression colorée (ProgressView ignore la couleur sur Mac).
struct ProgressBar: View {
    let value: Double
    let color: Color

    var body: some View {
        GeometryReader { geo in
            let fraction = min(max(value, 0), 1)
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                if fraction > 0 {
                    Capsule().fill(color).frame(width: max(6, geo.size.width * fraction))
                }
            }
        }
        .frame(height: 6)
        .accessibilityElement()
        .accessibilityValue("\(Int(min(max(value, 0), 1) * 100)) %")
    }
}

/// Fond « premium » : nuit bleutée, liseré holographique et un reflet qui balaie lentement.
/// Le reflet est recalculé à chaque image d'après la taille réelle : il reste juste quand la fenêtre change de taille.
struct HoloBanner: View {
    var cornerRadius: CGFloat = 18
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        shape
            .fill(LinearGradient(colors: [.nightTop, Color(red: 0.12, green: 0.11, blue: 0.15)],
                                 startPoint: .topLeading, endPoint: .bottomTrailing))
            .overlay {
                if !reduceMotion {
                    TimelineView(.animation(minimumInterval: 1 / 30)) { context in
                        GeometryReader { geo in
                            let width = geo.size.width, height = geo.size.height
                            let band = min(max(width * 0.35, 120), 320)
                            // Un passage de 3,5 s puis 1 s de pause.
                            let t = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 4.5)
                            let p = min(t / 3.5, 1)
                            let eased = p * p * (3 - 2 * p)
                            LinearGradient(colors: [.clear, .white.opacity(0.12), .clear],
                                           startPoint: .leading, endPoint: .trailing)
                                .frame(width: band, height: height * 2)
                                .rotationEffect(.degrees(20))
                                .position(x: -band + (width + band * 2) * eased, y: height / 2)
                        }
                    }
                    .clipShape(shape)
                    .allowsHitTesting(false)
                }
            }
            .overlay { shape.strokeBorder(LinearGradient.holo, lineWidth: 1.5).opacity(0.8) }
    }
}

/// Écran vide illustré : une page de classeur dont la case centrale brille, comme l'icône.
struct EmptyBinder: View {
    let title: String
    let message: String
    var systemImage = "sparkle"

    var body: some View {
        VStack(spacing: 18) {
            Grid(horizontalSpacing: 8, verticalSpacing: 8) {
                ForEach(0..<3) { row in
                    GridRow {
                        ForEach(0..<3) { col in
                            let center = row == 1 && col == 1
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(center ? AnyShapeStyle(LinearGradient.holo) : AnyShapeStyle(Color.white.opacity(0.04)))
                                .strokeBorder(LinearGradient.holo, lineWidth: center ? 0 : 1.5)
                                .frame(width: 44, height: 62)
                                .overlay { if center { Image(systemName: systemImage).font(.title2.bold()).foregroundStyle(.white) } }
                        }
                    }
                }
            }
            .padding(16)
            .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .accessibilityHidden(true)

            Text(title).font(.title2.bold())
            Text(message).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .padding(.horizontal, 32)
        .padding(.vertical, 48)
        .frame(maxWidth: .infinity)
    }
}

/// Image réduite (côté le plus long ≤ maxPixels) et déjà décodée, prête à afficher.
func downsampled(_ data: Data, maxPixels: Int) -> CGImage? {
    let options = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                   kCGImageSourceThumbnailMaxPixelSize: maxPixels,
                   kCGImageSourceCreateThumbnailWithTransform: true,
                   kCGImageSourceShouldCacheImmediately: true] as CFDictionary
    guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
    return CGImageSourceCreateThumbnailAtIndex(source, 0, options)
}
