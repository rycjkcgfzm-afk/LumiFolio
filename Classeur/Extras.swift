import SwiftUI
import SwiftData
import Charts
#if os(iOS)
import UIKit
import CoreMotion
#endif

// MARK: - Historique de valeur

/// Enregistre la valeur totale de la collection : un point par jour (le dernier de la journée l'emporte).
@MainActor
func recordValue(_ cards: [OwnedCard], in context: ModelContext) {
    let total = cards.reduce(0.0) { $0 + $1.totalValue }
    let startOfDay = Calendar.current.startOfDay(for: Date())
    let today = FetchDescriptor<ValueSnapshot>(predicate: #Predicate { $0.date >= startOfDay })
    if let existing = try? context.fetch(today).first {
        existing.value = total
        existing.date = Date()
    } else {
        context.insert(ValueSnapshot(value: total))
    }
}

/// Met à jour le prix Cardmarket de chaque carte (collection ou wishlist).
/// Une requête par carte différente, 6 en parallèle. Une réponse sans prix ne remplace pas un prix connu.
@MainActor
func updatePrices(_ cards: [OwnedCard]) async {
    let ids = Array(Set(cards.map(\.cardId)))
    let details = await withTaskGroup(of: (String, CardDetail?).self) { group in
        var pending = ids.makeIterator()
        for _ in 0..<6 {
            guard let id = pending.next() else { break }
            group.addTask { (id, try? await TCGdex.card(id)) }
        }
        var found: [String: CardDetail] = [:]
        for await (id, detail) in group {
            if let detail { found[id] = detail }
            if let id = pending.next() { group.addTask { (id, try? await TCGdex.card(id)) } }
        }
        return found
    }
    for card in cards {
        guard let price = details[card.cardId]?.price(for: card.variant, printing: card.printingKey) else { continue }
        card.unitPrice = price
        card.logPrice(price)
    }
}

// MARK: - Statistiques

struct GroupStat: Identifiable {
    let name: String
    let count: Int
    let value: Double
    var id: String { name }
}

/// Regroupe les cartes (en tenant compte des quantités), trié par valeur décroissante.
func groupStats(_ cards: [OwnedCard], by key: (OwnedCard) -> String) -> [GroupStat] {
    Dictionary(grouping: cards, by: key).map { name, group in
        GroupStat(name: name,
                  count: group.reduce(0) { $0 + $1.quantity },
                  value: group.reduce(0) { $0 + $1.totalValue })
    }
    .sorted { ($0.value, $0.count) > ($1.value, $1.count) }
}

struct StatsView: View {
    @Query(sort: \ValueSnapshot.date) private var history: [ValueSnapshot]
    @Query(filter: #Predicate<OwnedCard> { !$0.isWishlist }) private var cards: [OwnedCard]
    @Environment(\.dismiss) private var dismiss

    private var top: [OwnedCard] {
        Array(cards.filter { $0.value != nil }.sorted { ($0.value ?? 0) > ($1.value ?? 0) }.prefix(10))
    }

    var body: some View {
        NavigationStack {
            List {
                Section("Valeur de la collection") {
                    if history.count < 2 {
                        Text("Touche « Actualiser les prix » de temps en temps (un point par jour) pour voir l'évolution ici.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    if !history.isEmpty {
                        Chart(history) { point in
                            AreaMark(x: .value("Date", point.date), y: .value("Valeur", point.value))
                                .foregroundStyle(LinearGradient(colors: [Color.classeur.opacity(0.35), .clear],
                                                                startPoint: .top, endPoint: .bottom))
                            LineMark(x: .value("Date", point.date), y: .value("Valeur", point.value))
                                .foregroundStyle(Color.classeur)
                            PointMark(x: .value("Date", point.date), y: .value("Valeur", point.value))
                                .foregroundStyle(Color.classeur)
                        }
                        .chartYAxis { AxisMarks { AxisGridLine(); AxisValueLabel(format: .currency(code: "EUR")) } }
                        .frame(height: 220)
                        .padding(.vertical, 8)
                    }
                }
                Section("Top 10 de mes cartes") {
                    if top.isEmpty { Text("Aucun prix connu pour l'instant.").foregroundStyle(.secondary) }
                    ForEach(Array(top.enumerated()), id: \.element.id) { rank, card in
                        HStack(spacing: 12) {
                            Text("\(rank + 1)").font(.headline.monospacedDigit()).frame(width: 24)
                            CardThumb(imageBase: card.imageBase, cardId: card.cardId, photo: card.photo ?? card.offlineImage)
                                .frame(width: 44)
                            VStack(alignment: .leading) {
                                Text(card.name).fontWeight(.semibold)
                                Text("\(card.setName) · \(card.variant.label)").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(eur(card.value ?? 0)).monospacedDigit().fontWeight(.semibold)
                        }
                    }
                }
                Section("Valeur par extension") {
                    let bySet = groupStats(cards) { $0.setName }
                    Chart(bySet.prefix(8)) { row in
                        BarMark(x: .value("Valeur", row.value), y: .value("Extension", row.name))
                            .foregroundStyle(Color.classeur)
                    }
                    .chartXAxis { AxisMarks { AxisGridLine(); AxisValueLabel(format: .currency(code: "EUR")) } }
                    .frame(height: CGFloat(min(bySet.count, 8)) * 30 + 30)
                    ForEach(bySet) { row in
                        LabeledContent(row.name, value: "\(row.count) cartes · \(eur(row.value))")
                    }
                }
                Section("Par variante") {
                    ForEach(groupStats(cards) { $0.variant.label }) { row in
                        LabeledContent(row.name, value: "\(row.count) cartes · \(eur(row.value))")
                    }
                }
                Section("Par langue") {
                    ForEach(groupStats(cards) { $0.language }) { row in
                        LabeledContent(row.name, value: "\(row.count) cartes · \(eur(row.value))")
                    }
                }
            }
            .nightBackground()
            .navigationTitle("Statistiques")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("OK") { dismiss() } } }
        }
        .frame(minWidth: 420, minHeight: 520)
    }
}

// MARK: - Vue classeur (pages de 9)

/// Une page de classeur : 3 × 3 pochettes, vides pour les cartes manquantes.
struct BinderPage: View {
    let cards: [CardBrief]
    let owned: Set<String>
    let page: Int
    let pageCount: Int

    var body: some View {
        VStack(spacing: 10) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 10) {
                ForEach(cards) { card in
                    if owned.contains(card.id) {
                        NavigationLink(value: card) { CardThumb(imageBase: card.image, cardId: card.id) }
                            .buttonStyle(.plain)
                    } else {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                            .foregroundStyle(.secondary.opacity(0.6))
                            .background(RoundedRectangle(cornerRadius: 7).fill(.quaternary.opacity(0.4)))
                            .aspectRatio(63.0 / 88.0, contentMode: .fit)
                            .overlay {
                                VStack(spacing: 4) {
                                    Text(card.localId).font(.headline.monospacedDigit())
                                    Text(card.name).font(.caption2).lineLimit(2).multilineTextAlignment(.center)
                                }
                                .foregroundStyle(.secondary)
                                .padding(4)
                            }
                    }
                }
            }
            Text("Page \(page) / \(pageCount)").font(.caption).foregroundStyle(.secondary)
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.background.secondary))
        .padding(.horizontal)
        .frame(maxWidth: 560)
    }
}

/// Toutes les pages d'une extension, en défilement horizontal page par page.
struct BinderView: View {
    let cards: [CardBrief]
    let owned: Set<String>

    var body: some View {
        let pages = stride(from: 0, to: cards.count, by: 9).map { Array(cards[$0..<min($0 + 9, cards.count)]) }
        ScrollView(.horizontal) {
            LazyHStack(spacing: 0) {
                ForEach(pages.indices, id: \.self) { index in
                    BinderPage(cards: pages[index], owned: owned, page: index + 1, pageCount: pages.count)
                        .containerRelativeFrame(.horizontal)
                }
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.paging)
        .scrollIndicators(.hidden)
    }
}

// MARK: - Images hors ligne

/// Cartes dont aucune image n'a été trouvée pendant cette session : on ne les redemande pas à chaque ajout.
@MainActor private var offlineImageMisses: Set<String> = []

/// Garde une copie de l'image de chaque carte possédée ou recherchée, pour l'afficher sans internet.
@MainActor
func downloadOfflineImages(_ cards: [OwnedCard]) async {
    for card in cards where card.offlineImage == nil && card.photo == nil && !offlineImageMisses.contains(card.cardId) {
        var found = false
        for url in cardImageURLs(imageBase: card.imageBase, cardId: card.cardId, high: true) {
            if Task.isCancelled { return }
            if let image = await ImageLoader.shared.image(url) {
                card.offlineImage = jpegData(image)
                found = true
                break
            }
        }
        if !found && !Task.isCancelled { offlineImageMisses.insert(card.cardId) }
    }
}

// MARK: - Effet holo 3D

/// Inclinaison lue par le gyroscope, relative à la position du téléphone à l'ouverture
/// (fonctionne que l'iPhone soit tenu droit, penché ou posé à plat).
@Observable
final class TiltMotion {
    var tilt = CGSize.zero   // de -1 à 1 sur chaque axe
    #if os(iOS)
    private let manager = CMMotionManager()
    private var reference: CMAttitude?

    func start() {
        guard manager.isDeviceMotionAvailable, !manager.isDeviceMotionActive else { return }
        manager.deviceMotionUpdateInterval = 1.0 / 60
        manager.startDeviceMotionUpdates(to: .main) { [weak self] data, _ in
            guard let self, let attitude = data?.attitude else { return }
            if let reference { attitude.multiply(byInverseOf: reference) } else { reference = attitude.copy() as? CMAttitude }
            // ±0,45 rad (~25°) de mouvement = inclinaison maximale de la carte.
            tilt = CGSize(width: min(max(attitude.roll / 0.45, -1), 1),
                          height: min(max(attitude.pitch / 0.45, -1), 1))
        }
    }

    func stop() {
        manager.stopDeviceMotionUpdates()
        reference = nil
    }
    #else
    func start() {}
    func stop() {}
    #endif
}

/// Incline la carte et fait glisser un reflet : gyroscope sur iPhone, glisser du doigt ou de la souris partout.
struct HoloTilt: ViewModifier {
    @State private var motion = TiltMotion()
    @State private var drag: CGSize?

    private func clamp(_ v: Double) -> Double { min(max(v, -1), 1) }

    func body(content: Content) -> some View {
        let tilt = drag ?? motion.tilt
        content
            .overlay {
                LinearGradient(colors: [.clear, .white.opacity(0.55), .clear],
                               startPoint: UnitPoint(x: 0.2 - tilt.width * 0.7, y: 0.0 - tilt.height * 0.7),
                               endPoint: UnitPoint(x: 0.8 - tilt.width * 0.7, y: 1.0 - tilt.height * 0.7))
                    .blendMode(.overlay)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .allowsHitTesting(false)
            }
            .rotation3DEffect(.degrees(tilt.width * 16), axis: (x: 0, y: 1, z: 0), perspective: 0.6)
            .rotation3DEffect(.degrees(-tilt.height * 16), axis: (x: 1, y: 0, z: 0), perspective: 0.6)
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { drag = CGSize(width: clamp($0.translation.width / 120), height: clamp($0.translation.height / 120)) }
                .onEnded { _ in withAnimation(.spring(duration: 0.5)) { drag = nil } })
            .onAppear { motion.start() }
            .onDisappear { motion.stop() }
    }
}

/// La carte en grand, sur fond noir, avec l'effet holo.
struct CardViewer: View {
    let imageBase: String?
    let cardId: String
    let photo: Data?
    let shine: Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 24) {
                CardThumb(imageBase: imageBase, cardId: cardId, high: true, shine: shine, photo: photo)
                    .modifier(HoloTilt())
                    .padding(32)
                    .frame(maxWidth: 520)
                #if os(iOS)
                Text("Incline ton iPhone ou fais glisser la carte")
                #else
                Text("Fais glisser la carte pour l'incliner")
                #endif
            }
            .font(.footnote)
            .foregroundStyle(.white.opacity(0.6))
        }
        .overlay(alignment: .topTrailing) {
            Button { dismiss() } label: {
                Image(systemName: "xmark.circle.fill").font(.largeTitle)
                    .symbolRenderingMode(.hierarchical).foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .padding()
            .accessibilityLabel("Fermer")
        }
        #if os(macOS)
        .frame(minWidth: 520, minHeight: 720)
        #endif
    }
}

extension View {
    /// Plein écran sur iPhone, fenêtre sur Mac.
    func cardViewer(isPresented: Binding<Bool>, imageBase: String?, cardId: String, photo: Data?, shine: Bool) -> some View {
        let viewer = CardViewer(imageBase: imageBase, cardId: cardId, photo: photo, shine: shine)
        #if os(iOS)
        return fullScreenCover(isPresented: isPresented) { viewer }
        #else
        return sheet(isPresented: isPresented) { viewer }
        #endif
    }
}

// MARK: - Appareil photo (iPhone)

#if os(iOS)
struct CameraPicker: UIViewControllerRepresentable {
    let onDone: (Data?) -> Void

    static var isAvailable: Bool { UIImagePickerController.isSourceTypeAvailable(.camera) }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ picker: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onDone: onDone) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let onDone: (Data?) -> Void
        init(onDone: @escaping (Data?) -> Void) { self.onDone = onDone }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            onDone((info[.originalImage] as? UIImage)?.jpegData(compressionQuality: 0.9))
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { onDone(nil) }
    }
}
#endif

// MARK: - Objectifs de complétion

/// Extension épinglée comme objectif. Stockée en texte (« id|total|nom » par ligne) pour marcher hors connexion.
struct Goal: Hashable, Identifiable {
    let id: String
    let total: Int
    let name: String

    static func parse(_ raw: String) -> [Goal] {
        raw.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "|", maxSplits: 2).map(String.init)
            guard parts.count == 3, let total = Int(parts[1]) else { return nil }
            return Goal(id: parts[0], total: total, name: parts[2])
        }
    }

    /// Ajoute l'objectif s'il est absent, le retire sinon.
    static func toggled(_ raw: String, _ goal: Goal) -> String {
        var list = parse(raw)
        if let i = list.firstIndex(where: { $0.id == goal.id }) { list.remove(at: i) } else { list.append(goal) }
        return list.map { "\($0.id)|\($0.total)|\($0.name)" }.joined(separator: "\n")
    }
}

/// Jauges des extensions épinglées, en haut de la Collection.
struct GoalsSection: View {
    let goals: [Goal]
    let owned: [OwnedCard]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Objectifs", systemImage: "target").font(.headline)
            ForEach(goals) { goal in
                let have = Set(owned.filter { !$0.isWishlist && $0.setId == goal.id }.map(\.cardId)).count
                let done = have >= goal.total
                NavigationLink(value: goal) {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(goal.name).fontWeight(.semibold).lineLimit(1)
                            Spacer()
                            if done { Image(systemName: "checkmark.seal.fill").foregroundStyle(.green) }
                            Text("\(have)/\(goal.total)").monospacedDigit().foregroundStyle(.secondary)
                        }
                        ProgressBar(value: Double(have) / Double(max(goal.total, 1)), color: done ? .green : .classeur)
                    }
                    .padding(12)
                    .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal)
        .padding(.top, 12)
    }
}

// MARK: - Carte vedette

extension OwnedCard {
    /// Clé stable d'un exemplaire (carte + variante + état + langue), pour retenir la carte épinglée.
    /// Le tampon n'est ajouté que s'il existe : les cartes déjà épinglées gardent leur clé.
    var featureKey: String { ([cardId, variantRaw, conditionRaw, language] + [printingKey].compactMap { $0 }).joined(separator: "|") }
}

/// Une carte mise en avant en haut de la Collection : celle épinglée, sinon la plus chère ; ou une au hasard.
struct FeaturedCard: View {
    let cards: [OwnedCard]
    @State private var randomPick: PersistentIdentifier?   // nil = carte épinglée, ou la plus chère
    @State private var showMax = false   // forcer la plus chère même si une carte est épinglée
    @AppStorage("vedette") private var featuredKey = ""

    private var pinned: OwnedCard? {
        featuredKey.isEmpty ? nil : cards.first { $0.featureKey == featuredKey }
    }

    /// Cartes dont l'image est connue (photo perso ou image enregistrée hors connexion) ; à défaut, toutes.
    private var candidates: [OwnedCard] {
        let withImage = cards.filter { $0.photo != nil || $0.offlineImage != nil }
        return withImage.isEmpty ? cards : withImage
    }

    private var card: OwnedCard? {
        if let randomPick, let found = cards.first(where: { $0.persistentModelID == randomPick }) { return found }
        return showMax ? mostValuable : (pinned ?? mostValuable)
    }

    private var mostValuable: OwnedCard? { candidates.max { ($0.value ?? 0) < ($1.value ?? 0) } }

    var body: some View {
        if let card {
            VStack(alignment: .leading, spacing: 12) {
                NavigationLink(value: card) {
                    HStack(spacing: 16) {
                        CardThumb(imageBase: card.imageBase, cardId: card.cardId, shine: true,
                                  photo: card.photo ?? card.offlineImage)
                            .frame(width: 96)
                            .id(card.persistentModelID)
                            .transition(.asymmetric(insertion: .scale(scale: 0.8).combined(with: .opacity), removal: .opacity))
                        VStack(alignment: .leading, spacing: 6) {
                            let isPinned = card.featureKey == featuredKey
                            Label(isPinned ? "Ta carte épinglée" : randomPick != nil ? "Carte au hasard" : "Ta carte la plus chère",
                                  systemImage: isPinned ? "pin.fill" : "sparkles")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(Color.classeurWarm)
                            Text(card.name).font(.title3.bold()).lineLimit(2)
                            Text("\(card.setName) · \(card.localId)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            if let price = card.value {
                                Text(eur(price)).font(.headline).monospacedDigit()
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                // Boutons sous la carte, hors du lien (sinon un clic ouvrirait la fiche).
                // Trop étroit pour le texte (iPhone) : on n'affiche que les icônes.
                let list = actions(card)
                ViewThatFits(in: .horizontal) {
                    row(list)
                    VStack(alignment: .leading, spacing: 8) {   // iPhone : deux lignes, texte gardé
                        row(Array(list.prefix(2)))
                        row(Array(list.dropFirst(2)))
                    }
                    row(list).labelStyle(.iconOnly)
                }
            }
            .padding(14)
            .foregroundStyle(.white)
            .background(HoloBanner())
            .padding(.horizontal)
            .padding(.top, 12)
        }
    }

    private struct Action: Identifiable {
        let title: String
        let icon: String
        let run: () -> Void
        var id: String { title }
    }

    /// Boutons proposés selon la carte affichée.
    private func actions(_ card: OwnedCard) -> [Action] {
        let isPinned = card.featureKey == featuredKey
        var list = [Action(title: "Au hasard", icon: "shuffle") {
            let others = candidates.filter { $0.persistentModelID != card.persistentModelID }
            randomPick = (others.randomElement() ?? card).persistentModelID
        }]
        if card.persistentModelID != mostValuable?.persistentModelID {
            list.append(Action(title: "La plus chère", icon: "crown") { randomPick = nil; showMax = true })
        }
        if pinned != nil, !isPinned {
            list.append(Action(title: "Mon épinglée", icon: "pin.circle") { randomPick = nil; showMax = false })
        }
        if isPinned {
            list.append(Action(title: "Désépingler", icon: "pin.slash") { featuredKey = ""; randomPick = nil; showMax = false })
        } else {
            list.append(Action(title: "Épingler", icon: "pin") { featuredKey = card.featureKey; randomPick = nil; showMax = false })
        }
        return list
    }

    private func row(_ list: [Action]) -> some View {
        HStack(spacing: 8) {
            ForEach(list) { action in
                Button { withAnimation(.spring(duration: 0.4)) { action.run() } } label: {
                    Label(action.title, systemImage: action.icon)
                }
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .font(.caption)
        .lineLimit(1)
        .fixedSize()
    }
}
