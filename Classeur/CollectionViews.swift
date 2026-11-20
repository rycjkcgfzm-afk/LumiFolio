import SwiftUI
import SwiftData
import PhotosUI

struct CollectionView: View {
    @Query(filter: #Predicate<OwnedCard> { !$0.isWishlist },
           sort: \OwnedCard.addedAt, order: .reverse)
    private var cards: [OwnedCard]
    @Query private var everything: [OwnedCard]   // collection + wishlist, pour l'export / import
    @Environment(\.modelContext) private var context
    @State private var filter = ""
    @State private var refreshing = false
    @State private var exportFile: CollectionFile?
    @State private var exporting = false
    @State private var importing = false
    @State private var choosingBackupFolder = false   // le même sélecteur sert à importer un fichier ou choisir un dossier
    @State private var transferMessage: String?
    @State private var showingStats = false
    @AppStorage("tri") private var sort: SortOrder = .recent
    @AppStorage("objectifs") private var goalsRaw = ""
    @State private var onlyShiny = false
    @State private var onlyDuplicates = false
    @State private var binderFilter = ""   // "" = tous les classeurs

    enum SortOrder: String, CaseIterable, Identifiable {
        case recent = "Ajout récent", name = "Nom", value = "Valeur", set = "Extension"
        var id: String { rawValue }
    }

    private var shown: [OwnedCard] {
        var list = filter.isEmpty ? cards : cards.filter {
            $0.name.localizedCaseInsensitiveContains(filter) || $0.setName.localizedCaseInsensitiveContains(filter)
        }
        if onlyShiny { list = list.filter { $0.variant != .normal } }
        if onlyDuplicates { list = list.filter { $0.quantity > 1 } }
        if !binderFilter.isEmpty { list = list.filter { $0.binderList.contains(binderFilter) } }
        switch sort {
        case .recent: break   // déjà trié par la requête
        case .name: list.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .value: list.sort { ($0.value ?? 0) > ($1.value ?? 0) }
        case .set: list.sort { ($0.setName, Int($0.localId) ?? 0) < ($1.setName, Int($1.localId) ?? 0) }
        }
        return list
    }

    /// Texte à envoyer à un ami : mes doublons et ce que je cherche.
    private var tradeText: String {
        let doubles = cards.filter { $0.quantity > 1 }
            .map { "• \($0.name) – \($0.setName) n°\($0.localId) (\($0.variant.label), \($0.language)) ×\($0.quantity - 1)" }
        let wanted = everything.filter(\.isWishlist)
            .map { "• \($0.name) – \($0.setName) n°\($0.localId)" }
        return "Mes doublons à échanger :\n" + (doubles.isEmpty ? "(aucun)" : doubles.joined(separator: "\n"))
            + "\n\nJe recherche :\n" + (wanted.isEmpty ? "(rien pour l'instant)" : wanted.joined(separator: "\n"))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                if cards.isEmpty {
                    EmptyBinder(title: "Ton classeur est vide",
                                message: "Ajoute tes premières cartes depuis l'onglet Recherche, ou scanne-les avec l'appareil photo.")
                } else {
                    summary
                    FeaturedCard(cards: cards)
                    PremiumShortcuts(cards: cards)
                    let goals = Goal.parse(goalsRaw)
                    if !goals.isEmpty { GoalsSection(goals: goals, owned: cards) }
                }
                LazyVGrid(columns: gridColumns, spacing: 12) {
                    ForEach(shown) { card in
                        NavigationLink(value: card) { OwnedThumb(card: card) }
                            .buttonStyle(.plain)
                    }
                }
                .padding()
            }
            .nightBackground()
            .navigationTitle("Collection")
            .navigationDestination(for: OwnedCard.self) { OwnedCardView(card: $0) }
            .navigationDestination(for: Goal.self) { SetDetailView(setId: $0.id) }
            .navigationDestination(for: CardBrief.self) { CardDetailView(cardId: $0.id) }
            .searchable(text: $filter, prompt: "Filtrer par nom ou extension")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { Task { await refreshPrices() } } label: {
                        Label("Actualiser les prix", systemImage: "arrow.clockwise")
                    }
                    .disabled(refreshing || cards.isEmpty)
                }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Picker("Trier par", selection: $sort) {
                            ForEach(SortOrder.allCases) { Text($0.rawValue).tag($0) }
                        }
                        Toggle("Seulement holo / reverse", isOn: $onlyShiny)
                        Toggle("Seulement les doublons", isOn: $onlyDuplicates)
                        let binders = Array(Set(cards.flatMap(\.binderList))).sorted()
                        if !binders.isEmpty || !binderFilter.isEmpty {
                            Picker("Classeur", selection: $binderFilter) {
                                Text("Tous les classeurs").tag("")
                                ForEach(binders, id: \.self) { Text($0).tag($0) }
                            }
                        }
                    } label: {
                        Label("Trier et filtrer", systemImage: onlyShiny || onlyDuplicates || !binderFilter.isEmpty
                              ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button { showingStats = true } label: { Label("Statistiques", systemImage: "chart.xyaxis.line") }
                        .disabled(cards.isEmpty)
                }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        ShareLink(item: tradeText) {
                            Label("Partager mes doublons et ma wishlist", systemImage: "arrow.2.squarepath")
                        }
                        Button {
                            do {
                                exportFile = try CollectionFile(cards: everything)
                                exporting = true
                            } catch {
                                transferMessage = "Export impossible : \(error.localizedDescription)"
                            }
                        } label: { Label("Exporter ma collection", systemImage: "square.and.arrow.up") }
                        .disabled(everything.isEmpty)
                        Button { choosingBackupFolder = false; importing = true } label: {
                            Label("Importer une collection", systemImage: "square.and.arrow.down")
                        }
                        Section("Sauvegarde automatique (1 fois par jour)") {
                            Button { choosingBackupFolder = true; importing = true } label: {
                                Label(AutoBackup.isConfigured ? "Changer le dossier de sauvegarde" : "Choisir le dossier de sauvegarde",
                                      systemImage: "folder.badge.gearshape")
                            }
                            Button { transferMessage = AutoBackup.run(cards: everything, force: true) } label: {
                                Label("Sauvegarder maintenant", systemImage: "externaldrive.badge.checkmark")
                            }
                            .disabled(!AutoBackup.isConfigured)
                            if let last = AutoBackup.lastDate {
                                Text("Dernière : \(last.formatted(date: .abbreviated, time: .shortened))")
                            }
                        }
                    } label: { Label("Transférer", systemImage: "arrow.left.arrow.right.circle") }
                }
            }
            .fileExporter(isPresented: $exporting, document: exportFile, contentType: .json,
                          defaultFilename: "Collection Lumifolio") { result in
                if case .success = result { transferMessage = "Collection exportée (\(everything.count) lignes)." }
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: choosingBackupFolder ? [.folder] : [.json]) { result in
                switch result {
                case .success(let url) where choosingBackupFolder:
                    do {
                        try AutoBackup.setFolder(url)
                        transferMessage = AutoBackup.run(cards: everything, force: true)
                    } catch {
                        transferMessage = "Ce dossier ne peut pas être utilisé : \(error.localizedDescription)"
                    }
                case .success(let url): transferMessage = importCollection(from: url, into: context, existing: everything)
                case .failure(let error): transferMessage = "Opération impossible : \(error.localizedDescription)"
                }
            }
            .task { if let problem = AutoBackup.run(cards: everything) { transferMessage = problem } }
            .task(id: everything.count) { await downloadOfflineImages(everything) }
            .sheet(isPresented: $showingStats) { StatsView() }
            .alert(transferMessage ?? "", isPresented: Binding(get: { transferMessage != nil },
                                                               set: { if !$0 { transferMessage = nil } })) {
                Button("OK") { transferMessage = nil }
            }
        }
    }

    private var summary: some View {
        let count = cards.reduce(0) { $0 + $1.quantity }
        let value = cards.reduce(0.0) { $0 + $1.totalValue }
        return VStack(spacing: 10) {
            HStack(spacing: 0) {
                stat("rectangle.stack.fill", "\(count)", "cartes")
                Divider().overlay(.white.opacity(0.4)).frame(height: 40)
                stat("square.grid.2x2.fill", "\(cards.count)", "différentes")
                Divider().overlay(.white.opacity(0.4)).frame(height: 40)
                stat("eurosign.circle.fill", eur(value), refreshing ? "actualisation…" : "valeur estimée")
            }
            .foregroundStyle(.white)
            ProfitLine(cards: cards).padding(.horizontal)
        }
        .padding(.vertical, 18)
        .background(HoloBanner())
        .shadow(color: Color.classeur.opacity(0.35), radius: 12, y: 6)
        .padding(.horizontal)
        .padding(.top, 8)
    }

    private func stat(_ icon: String, _ value: String, _ label: String) -> some View {
        VStack(spacing: 4) {
            Image(systemName: icon).font(.title3).opacity(0.85)
            Text(value).font(.title2.bold()).monospacedDigit().lineLimit(1).minimumScaleFactor(0.6)
            Text(label).font(.caption).opacity(0.85)
        }
        .frame(maxWidth: .infinity)
    }

    private func refreshPrices() async {
        refreshing = true
        defer { refreshing = false }
        await updatePrices(cards)
        recordValue(cards, in: context)
    }

}

struct WishlistView: View {
    @Query(filter: #Predicate<OwnedCard> { $0.isWishlist },
           sort: \OwnedCard.addedAt, order: .reverse)
    private var cards: [OwnedCard]
    @State private var refreshing = false
    @State private var deals: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                if cards.isEmpty {
                    EmptyBinder(title: "Aucune carte recherchée",
                                message: "Ajoute les cartes que tu cherches depuis la Recherche : Lumifolio te dira quand leur prix est bon.",
                                systemImage: "star.fill")
                }
                LazyVGrid(columns: gridColumns, spacing: 12) {
                    ForEach(cards) { card in
                        NavigationLink(value: card) { OwnedThumb(card: card) }
                            .buttonStyle(.plain)
                    }
                }
                .padding()
            }
            .nightBackground()
            .navigationTitle("Wishlist")
            .navigationDestination(for: OwnedCard.self) { OwnedCardView(card: $0) }
            .toolbar {
                Button {
                    Task {
                        refreshing = true
                        await updatePrices(cards)
                        refreshing = false
                        let good = cards.filter(\.isGoodDeal)
                        deals = good.isEmpty
                            ? "Prix à jour. Aucune carte n'est encore à ton prix."
                            : "Bon prix pour :\n" + good.map { "\($0.name) – \(eur($0.unitPrice ?? 0))" }.joined(separator: "\n")
                    }
                } label: { Label("Vérifier les prix", systemImage: refreshing ? "hourglass" : "bell.badge") }
                .disabled(refreshing || cards.isEmpty)
            }
            .alert(deals ?? "", isPresented: Binding(get: { deals != nil }, set: { if !$0 { deals = nil } })) {
                Button("OK") { deals = nil }
            }
        }
    }
}

/// Modifier ou supprimer une carte de la collection / wishlist.
struct OwnedCardView: View {
    /// Nouvelle variante ou nouveau tampon : prix de cette version, et historique repris de zéro
    /// (l'ancien concernait une autre version). Hors connexion, on attend la prochaine actualisation.
    private func repriceForNewVersion() {
        guard let detail else { return }
        card.unitPrice = detail.price(for: card.variant, printing: card.printingKey)
        card.priceLog = ""
        if let price = card.unitPrice { card.logPrice(price) }
    }

    @Bindable var card: OwnedCard
    @State private var pickedPhoto: PhotosPickerItem?
    @State private var takingPhoto = false
    @State private var viewing = false
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @AppStorage("vedette") private var featuredKey = ""
    @Query(filter: #Predicate<OwnedCard> { !$0.isWishlist }) private var collection: [OwnedCard]
    @State private var detail: CardDetail?   // chargé pour proposer les versions tamponnées
    @State private var deleting = false
    @State private var imageMissing = false   // aucune image en ligne : on propose la photo en haut de la fiche

    var body: some View {
        Form {
            Section {
                CardThumb(imageBase: card.imageBase, cardId: card.cardId, high: true,
                          photo: card.photo ?? card.offlineImage, missingHint: "Aucune image en ligne pour cette carte",
                          onResult: { imageMissing = !$0 })
                    .frame(maxHeight: 360)
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                    .onTapGesture { viewing = true }
                    .accessibilityAddTraits(.isButton)
                    .accessibilityHint("Affiche la carte en grand")
                if imageMissing && card.photo == nil {
                    // Directement sous la carte : c'est ici qu'on remarque qu'elle n'a pas d'image.
                    #if os(iOS)
                    if CameraPicker.isAvailable {
                        Button { takingPhoto = true } label: { Label("Prendre la carte en photo", systemImage: "camera.fill") }
                            .fontWeight(.semibold)
                    }
                    #endif
                    PhotosPicker(selection: $pickedPhoto, matching: .images) {
                        Label("Choisir une photo de la carte", systemImage: "photo.on.rectangle")
                    }
                } else {
                    Text("Touche la carte pour l'admirer en grand").font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                }
                if !card.isWishlist {
                    let pinned = featuredKey == card.featureKey
                    Button {
                        withAnimation { featuredKey = pinned ? "" : card.featureKey }
                    } label: {
                        Label(pinned ? "Retirer de la vedette" : "Mettre en vedette dans ma Collection",
                              systemImage: pinned ? "pin.slash" : "pin.fill")
                    }
                }
            }
            Section("Carte") {
                LabeledContent("Extension", value: card.setName)
                LabeledContent("Numéro", value: card.localId)
                if let detail, !detail.stampedPrintings.isEmpty {
                    Picker("Tampon", selection: Binding(
                        get: { card.printingKey ?? "" },
                        set: { key in
                            let printing = detail.stampedPrintings.first { $0.key == key }
                            card.printingKey = printing?.key
                            card.printingLabel = printing?.label
                            repriceForNewVersion()
                        })) {
                        Text("Sans tampon").tag("")
                        ForEach(detail.stampedPrintings, id: \.key) { p in
                            Text(p.label + (detail.price(for: card.variant, printing: p.key).map { " · " + eur($0) } ?? "")).tag(p.key)
                        }
                    }
                } else if let stamp = card.printingLabel {
                    LabeledContent("Tampon", value: stamp)   // hors connexion : on affiche le tampon enregistré
                }
                LabeledContent("Cote Cardmarket (toutes langues)", value: card.unitPrice.map(eur) ?? "inconnue")
                if let detail { EditionNote(variant: card.variant, ratio: detail.firstEditionRatio) }
                if card.gradedValue == nil, card.condition.priceFactor < 1, let price = card.unitPrice {
                    LabeledContent("Estimée en \(card.condition.rawValue) (\(Int(card.condition.priceFactor * 100)) %)",
                                   value: eur(price * card.condition.priceFactor))
                }
            }
            Section(card.isWishlist ? "Recherchée" : "Mon exemplaire") {
                Picker("Variante", selection: $card.variant) {
                    ForEach(Variant.allCases) { Text($0.label).tag($0) }
                }
                Picker("État", selection: $card.condition) {
                    ForEach(Condition.allCases) { Text($0.rawValue).tag($0) }
                }
                Picker("Langue", selection: $card.language) {
                    ForEach(cardLanguages, id: \.self) { Text($0).tag($0) }
                }
                if card.isWishlist {
                    LabeledContent("Prix actuel", value: card.unitPrice.map(eur) ?? "inconnu")
                    TextField("Prix max souhaité (€)", value: $card.targetPrice, format: .number)
                        #if os(iOS)
                        .keyboardType(.decimalPad)
                        #endif
                    if card.isGoodDeal {
                        Label("Bon prix : c'est le moment d'acheter !", systemImage: "bell.fill").foregroundStyle(.green)
                    }
                }
                if !card.isWishlist {
                    Stepper("Quantité : \(card.quantity)", value: $card.quantity, in: 1...999)
                    PurchaseFields(card: card)
                }
            }
            if !card.isWishlist {
                GradeSection(card: card)
                BinderSection(card: card, existing: Array(Set(collection.flatMap(\.binderList))).sorted())
            }
            PriceHistorySection(card: card)
            Section("Ma photo") {
                #if os(iOS)
                if CameraPicker.isAvailable {
                    Button { takingPhoto = true } label: { Label("Prendre une photo", systemImage: "camera") }
                }
                #endif
                PhotosPicker(selection: $pickedPhoto, matching: .images) {
                    Label(card.photo == nil ? "Choisir dans mes photos" : "Changer la photo", systemImage: "photo.on.rectangle")
                }
                if card.photo != nil {
                    Button("Revenir à l'image en ligne", role: .destructive) { card.photo = nil }
                }
            }
            Section {
                if card.isWishlist {
                    Button("Je l'ai ! Déplacer dans la collection") {
                        card.isWishlist = false
                        card.addedAt = Date()
                    }
                }
                Button("Supprimer", role: .destructive) {
                    // Supprimée une fois la fiche fermée : la fiche ne doit plus lire une carte effacée.
                    deleting = true
                    dismiss()
                }
            }
        }
        .formStyle(.grouped)
        .scrollBounceBehavior(.basedOnSize)   // pas de rebond quand la fiche tient à l'écran
        .nightBackground()
        .navigationTitle(card.name)
        .toolbar {
            ToolbarItem(placement: .primaryAction) { ShareCardButton(card: card) }
        }
        .task(id: card.cardId) { detail = try? await TCGdex.card(card.cardId) }
        .onChange(of: card.variantRaw) { repriceForNewVersion() }
        .onDisappear { if deleting { context.delete(card) } }
        .cardViewer(isPresented: $viewing, imageBase: card.imageBase, cardId: card.cardId,
                    photo: card.photo ?? card.offlineImage, shine: card.variant != .normal)
        #if os(iOS)
        .fullScreenCover(isPresented: $takingPhoto) {
            CameraPicker { data in
                if let data { card.photo = compressedPhoto(data) ?? data }
                takingPhoto = false
            }
            .ignoresSafeArea()
        }
        #endif
        .onChange(of: pickedPhoto) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self) {
                    card.photo = compressedPhoto(data) ?? data
                }
                pickedPhoto = nil
            }
        }
    }
}
