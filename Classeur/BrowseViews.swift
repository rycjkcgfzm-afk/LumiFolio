import SwiftUI
import SwiftData

struct SearchView: View {
    @State private var query = ""
    @State private var results: [CardBrief] = []
    @State private var loading = false
    @State private var error: String?
    @State private var scanning = false
    @State private var showFilters = false
    @State private var rarity = ""
    @State private var type = ""
    @State private var illustrator = ""
    @State private var rarities: [String] = []
    @State private var types: [String] = []

    private var hasFilters: Bool { !rarity.isEmpty || !type.isEmpty || !illustrator.isEmpty }

    var body: some View {
        NavigationStack {
            ScrollView {
                DisclosureGroup(isExpanded: $showFilters) {
                    VStack(alignment: .leading, spacing: 10) {
                        Picker("Rareté", selection: $rarity) {
                            Text("Toutes").tag("")
                            ForEach(rarities, id: \.self) { Text($0).tag($0) }
                        }
                        Picker("Type", selection: $type) {
                            Text("Tous").tag("")
                            ForEach(types, id: \.self) { Text($0).tag($0) }
                        }
                        TextField("Illustrateur (ex. Mitsuhiro Arita)", text: $illustrator)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { Task { await search() } }
                        HStack {
                            Button("Rechercher") { Task { await search() } }
                                .buttonStyle(.borderedProminent)
                            if hasFilters {
                                Button("Effacer les filtres") { rarity = ""; type = ""; illustrator = "" }
                            }
                        }
                    }
                    .padding(.top, 8)
                } label: {
                    Label(hasFilters ? "Filtres avancés (actifs)" : "Filtres avancés",
                          systemImage: "line.3.horizontal.decrease.circle")
                }
                .padding(.horizontal)
                .task(id: showFilters) {
                    guard showFilters, rarities.isEmpty else { return }
                    rarities = (try? await TCGdex.values("rarities")) ?? []
                    types = (try? await TCGdex.values("types")) ?? []
                }
                if loading { ProgressView().padding() }
                if let error { Text(error).foregroundStyle(.red).padding() }
                if !loading, error == nil, results.isEmpty {
                    EmptyBinder(title: "Cherche une carte",
                                message: "Tape un nom en français (ex. Dracaufeu) ou le numéro imprimé sur la carte (ex. 49/100, SVP 85).",
                                systemImage: "magnifyingglass")
                }
                LazyVGrid(columns: gridColumns, spacing: 12) {
                    ForEach(results) { card in
                        NavigationLink(value: card) {
                            VStack(spacing: 4) {
                                CardThumb(imageBase: card.image, cardId: card.id)
                                Text(card.name).font(.caption).lineLimit(1)
                                Text(card.id).font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding()
            }
            .nightBackground()
            .navigationTitle("Recherche")
            .searchable(text: $query, prompt: "Nom ou numéro (ex. 49/100)")
            .onSubmit(of: .search) { Task { await search() } }
            .navigationDestination(for: CardBrief.self) { CardDetailView(cardId: $0.id) }
            #if os(iOS)
            .toolbar {
                if CardScanner.isAvailable {
                    Button { scanning = true } label: { Label("Scanner", systemImage: "camera.viewfinder") }
                }
            }
            .fullScreenCover(isPresented: $scanning) {
                NavigationStack {
                    CardScanner { result in
                        scanning = false
                        Task { await scan(result) }
                    }
                    .ignoresSafeArea()
                    .navigationTitle("Vise le numéro en bas de la carte")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar { Button("Annuler") { scanning = false } }
                }
            }
            #endif
        }
    }

    private func scan(_ result: ScanResult) async {
        loading = true
        error = nil
        query = result.label
        defer { loading = false }
        do {
            results = try await TCGdex.cards(for: result)
            if results.isEmpty { error = "Aucune carte « \(result.label) » trouvée." }
        } catch {
            self.error = "Recherche impossible : \(error.localizedDescription)"
        }
    }

    private func search() async {
        let q = query.trimmingCharacters(in: .whitespaces)
        let artist = illustrator.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty || hasFilters else { return }
        // Un numéro tapé (« 49/100 », « SVP 85 ») se cherche comme un scan.
        if !hasFilters, let number = parseScan(q) {
            await scan(number)
            return
        }
        loading = true
        error = nil
        defer { loading = false }
        do {
            results = try await TCGdex.search(name: q, rarity: rarity, type: type, illustrator: artist)
            if results.isEmpty { error = "Aucune carte ne correspond à cette recherche." }
        } catch {
            self.error = "Recherche impossible : \(error.localizedDescription)"
        }
    }
}

/// Fiche d'une carte de l'API, avec ajout à la collection ou à la wishlist.
struct CardDetailView: View {
    let cardId: String
    @Environment(\.modelContext) private var context
    @State private var card: CardDetail?
    @State private var error: String?
    @State private var variant: Variant = .normal
    @State private var condition: Condition = .nearMint
    @State private var quantity = 1
    @State private var language = "FR"
    @State private var printing: CardDetail.Printing?   // version tamponnée, nil = classique
    @State private var confirmation: String?
    @State private var viewing = false
    @State private var addedTick = 0   // déclenche le rebond + la vibration à chaque ajout

    var body: some View {
        Group {
            if let card {
                form(card)
            } else if let error {
                ContentUnavailableView("Erreur", systemImage: "wifi.exclamationmark", description: Text(error))
            } else {
                ProgressView()
            }
        }
        .nightBackground()
        .navigationTitle(card?.name ?? "")
        .task { await load() }
    }

    private func load() async {
        guard card == nil else { return }
        do {
            let detail = try await TCGdex.card(cardId)
            variant = detail.availableVariants.first ?? .normal
            card = detail
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func form(_ c: CardDetail) -> some View {
        Form {
            Section {
                CardThumb(imageBase: c.image, cardId: c.id, high: true)
                    .frame(maxHeight: 360)
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                    .onTapGesture { viewing = true }
                    .accessibilityAddTraits(.isButton)
                    .accessibilityHint("Affiche la carte en grand")
                    .phaseAnimator([1.0, 1.06, 1.0], trigger: addedTick) { view, scale in
                        view.scaleEffect(scale)
                    } animation: { _ in .spring(duration: 0.22, bounce: 0.5) }
            }
            Section("Infos") {
                LabeledContent("Extension", value: c.set.name)
                LabeledContent("Numéro", value: "\(c.localId)/\(c.set.cardCount?.official.map(String.init) ?? "?")")
                if let rarity = c.rarity { LabeledContent("Rareté", value: rarity) }
                if let illustrator = c.illustrator { LabeledContent("Illustrateur", value: illustrator) }
                LabeledContent("Cote Cardmarket (toutes langues)",
                               value: c.price(for: variant, printing: printing?.key).map(eur) ?? "—")
                EditionNote(variant: variant, ratio: c.firstEditionRatio)
                if condition.priceFactor < 1, let price = c.price(for: variant, printing: printing?.key) {
                    LabeledContent("Estimée en \(condition.rawValue) (\(Int(condition.priceFactor * 100)) %)", value: eur(price * condition.priceFactor))
                }
            }
            Section("Ajouter") {
                Picker("Variante", selection: $variant) {
                    ForEach(c.availableVariants) { Text($0.label).tag($0) }
                }
                if !c.stampedPrintings.isEmpty {
                    Picker("Tampon", selection: $printing) {
                        Text("Sans tampon").tag(CardDetail.Printing?.none)
                        ForEach(c.stampedPrintings, id: \.key) { p in
                            Text(p.label + (c.price(for: variant, printing: p.key).map { " · " + eur($0) } ?? "")).tag(Optional(p))
                        }
                    }
                }
                Picker("État", selection: $condition) {
                    ForEach(Condition.allCases) { Text($0.rawValue).tag($0) }
                }
                Picker("Langue", selection: $language) {
                    ForEach(cardLanguages, id: \.self) { Text($0).tag($0) }
                }
                Stepper("Quantité : \(quantity)", value: $quantity, in: 1...999)
                Button("Ajouter à la collection") { add(c, wishlist: false) }
                Button("Ajouter à la wishlist") { add(c, wishlist: true) }
                if let confirmation {
                    Label(confirmation, systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .symbolEffect(.bounce, value: addedTick)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
        }
        .formStyle(.grouped)
        .scrollBounceBehavior(.basedOnSize)   // pas de rebond quand la fiche tient à l'écran
        .sensoryFeedback(.success, trigger: addedTick)
        .cardViewer(isPresented: $viewing, imageBase: c.image, cardId: c.id, photo: nil, shine: variant != .normal)
    }

    private func add(_ c: CardDetail, wishlist: Bool) {
        // Même carte + variante + état + langue déjà présente : on augmente la quantité au lieu de dupliquer.
        let id = c.id, v = variant.rawValue, cond = condition.rawValue, lang = language, key = printing?.key
        let descriptor = FetchDescriptor<OwnedCard>(predicate: #Predicate {
            $0.cardId == id && $0.variantRaw == v && $0.conditionRaw == cond && $0.isWishlist == wishlist && $0.language == lang
                && $0.printingKey == key
        })
        if let existing = try? context.fetch(descriptor).first {
            if !wishlist { existing.quantity += quantity }
        } else {
            context.insert(OwnedCard(card: c, variant: variant, condition: condition,
                                     quantity: wishlist ? 1 : quantity, isWishlist: wishlist, language: language,
                                     printing: printing))
        }
        withAnimation(.spring(duration: 0.35)) {
            confirmation = wishlist ? "Ajoutée à la wishlist" : "Ajoutée à la collection (×\(quantity))"
        }
        addedTick += 1
    }
}

struct SetsView: View {
    @Query(filter: #Predicate<OwnedCard> { !$0.isWishlist }) private var owned: [OwnedCard]
    @State private var sets: [SetBrief] = []
    @State private var groups: [SetGroup] = []   // vide si les séries n'ont pas pu être chargées
    @State private var error: String?
    @State private var filter = ""

    var body: some View {
        // Nombre de cartes différentes possédées par extension.
        let counts = Dictionary(grouping: owned, by: \.setId).mapValues { Set($0.map(\.cardId)).count }
        let shown = filter.isEmpty ? sets : sets.filter { $0.name.localizedCaseInsensitiveContains(filter) }
        let started = shown.filter { counts[$0.id] != nil }

        NavigationStack {
            List {
                if let error { Text(error).foregroundStyle(.red) }
                if !started.isEmpty {
                    Section("Commencées") {
                        ForEach(started) { row($0, have: counts[$0.id] ?? 0) }
                    }
                }
                if groups.isEmpty {
                    Section("Toutes les extensions") {
                        ForEach(shown) { row($0, have: counts[$0.id] ?? 0) }
                    }
                } else {
                    let visible = Set(shown.map(\.id))
                    ForEach(groups) { group in
                        let sets = group.sets.filter { visible.contains($0.id) }
                        if !sets.isEmpty {
                            Section(group.name) {
                                ForEach(sets) { row($0, have: counts[$0.id] ?? 0) }
                            }
                        }
                    }
                }
            }
            .overlay { if sets.isEmpty && error == nil { ProgressView() } }
            .nightBackground()
            .navigationTitle("Extensions")
            .searchable(text: $filter, prompt: "Filtrer les extensions")
            .navigationDestination(for: SetBrief.self) { SetDetailView(setId: $0.id) }
            .navigationDestination(for: CardBrief.self) { CardDetailView(cardId: $0.id) }
            .task { await load() }
        }
    }

    private func row(_ set: SetBrief, have: Int) -> some View {
        let total = set.cardCount?.official ?? 0
        let complete = total > 0 && have >= total
        return NavigationLink(value: set) {
            HStack(spacing: 12) {
                AssetImage(base: set.symbol ?? set.logo) {
                    Image(systemName: "rectangle.stack").foregroundStyle(.secondary)
                }
                .frame(width: 28, height: 28)

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(set.name).fontWeight(have > 0 ? .semibold : .regular)
                        Spacer()
                        if complete {
                            Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
                        }
                        Text("\(have)/\(total)").monospacedDigit().foregroundStyle(.secondary)
                    }
                    if total > 0 {
                        ProgressBar(value: Double(have) / Double(total), color: complete ? .green : .classeur)
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }

    private func load() async {
        guard sets.isEmpty else { return }
        do {
            sets = Array(try await TCGdex.sets().reversed())   // plus récentes en premier
        } catch {
            self.error = "Chargement impossible : \(error.localizedDescription)"
            return
        }
        groups = (try? await TCGdex.grouped(sets)) ?? []   // échec : on garde la liste à plat
    }
}

struct SetDetailView: View {
    let setId: String
    @Query(filter: #Predicate<OwnedCard> { !$0.isWishlist }) private var owned: [OwnedCard]
    @State private var detail: SetDetail?
    @State private var error: String?
    @State private var missingOnly = false
    @AppStorage("vueClasseur") private var binder = false
    @AppStorage("objectifs") private var goalsRaw = ""
    @Environment(\.modelContext) private var context
    @State private var selecting = false            // mode « cocher les cartes que j'ai »
    @State private var selected: Set<String> = []
    @State private var adding = false
    @State private var batchMessage: String?
    @State private var addedTick = 0

    /// Ajoute toutes les cartes cochées (variante normale, Near Mint, FR, sans tampon).
    /// Une carte déjà présente dans exactement cette version voit sa quantité augmenter.
    @MainActor
    private func addSelected() async {
        adding = true
        defer { adding = false }
        let ids = Array(selected)
        let details = await withTaskGroup(of: CardDetail?.self) { group in
            for id in ids { group.addTask { try? await TCGdex.card(id) } }
            var all: [CardDetail] = []
            for await detail in group { if let detail { all.append(detail) } }
            return all
        }
        for detail in details {
            let variant = detail.availableVariants.first ?? .normal
            let id = detail.id, v = variant.rawValue, cond = Condition.nearMint.rawValue
            let descriptor = FetchDescriptor<OwnedCard>(predicate: #Predicate {
                $0.cardId == id && $0.variantRaw == v && $0.conditionRaw == cond && !$0.isWishlist
                    && $0.language == "FR" && $0.printingKey == nil
            })
            if let existing = try? context.fetch(descriptor).first {
                existing.quantity += 1
            } else {
                context.insert(OwnedCard(card: detail, variant: variant, condition: .nearMint, quantity: 1, isWishlist: false))
            }
        }
        let failed = ids.count - details.count
        withAnimation(.spring(duration: 0.35)) {
            batchMessage = "\(details.count) carte\(details.count > 1 ? "s" : "") ajoutée\(details.count > 1 ? "s" : "")"
                + (failed > 0 ? " · \(failed) introuvable\(failed > 1 ? "s" : "") (connexion ?)" : "")
            selecting = false
            selected = []
        }
        addedTick += 1
    }

    var body: some View {
        let ownedIds = Set(owned.filter { $0.setId == setId }.map(\.cardId))
        let cards = (detail?.cards ?? []).filter { !missingOnly || !ownedIds.contains($0.id) }

        ScrollView {
            if let error { Text(error).foregroundStyle(.red).padding() }
            if detail == nil && error == nil { ProgressView().padding() }
            if let detail {
                let total = detail.cardCount?.official ?? detail.cards.count
                VStack(spacing: 10) {
                    AssetImage(base: detail.logo) {
                        Text(detail.name).font(.title.bold())
                    }
                    .frame(maxHeight: 80)
                    ProgressBar(value: Double(ownedIds.count) / Double(max(total, 1)),
                                color: ownedIds.count >= total ? .green : .classeur)
                        .frame(maxWidth: 320)
                    Text("\(ownedIds.count) / \(total) cartes").font(.headline).monospacedDigit()
                }
                .padding(.top)
            }
            if binder {
                BinderView(cards: detail?.cards ?? [], owned: ownedIds)
                    .padding(.vertical)
            } else {
            LazyVGrid(columns: gridColumns, spacing: 16) {
                ForEach(cards) { card in
                    if selecting {
                        let isOn = selected.contains(card.id)
                        Button {
                            if isOn { selected.remove(card.id) } else { selected.insert(card.id) }
                        } label: {
                            VStack(spacing: 6) {
                                CardThumb(imageBase: card.image, cardId: card.id,
                                          dimmed: !isOn && !ownedIds.contains(card.id))
                                    .overlay(alignment: .topTrailing) {
                                        Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                                            .font(.title2)
                                            .symbolRenderingMode(.palette)
                                            .foregroundStyle(.white, isOn ? Color.classeur : Color.black.opacity(0.4))
                                            .padding(6)
                                    }
                                    .scaleEffect(isOn ? 0.95 : 1)
                                    .animation(.spring(duration: 0.2), value: isOn)
                                Text("\(card.localId) · \(card.name)").font(.caption).lineLimit(1)
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(isOn ? .isSelected : [])
                    } else {
                        NavigationLink(value: card) {
                            VStack(spacing: 6) {
                                CardThumb(imageBase: card.image, cardId: card.id, dimmed: !ownedIds.contains(card.id))
                                Text("\(card.localId) · \(card.name)").font(.caption).lineLimit(1)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding()
            }
        }
        .nightBackground()
        .navigationTitle(detail?.name ?? "")
        .safeAreaInset(edge: .bottom) {
            if selecting || batchMessage != nil {
                VStack(spacing: 8) {
                    if let batchMessage {
                        Label(batchMessage, systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .symbolEffect(.bounce, value: addedTick)
                    }
                    if selecting {
                        HStack {
                            Button("Annuler") { selecting = false; selected = [] }
                            Spacer()
                            if adding { ProgressView().controlSize(.small) }
                            Button {
                                Task { await addSelected() }
                            } label: {
                                Text(selected.isEmpty ? "Coche tes cartes" : "Ajouter \(selected.count) carte\(selected.count > 1 ? "s" : "")")
                                    .fontWeight(.semibold)
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(selected.isEmpty || adding)
                        }
                    }
                }
                .padding()
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .padding(.horizontal)
                .padding(.bottom, 6)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .sensoryFeedback(.success, trigger: addedTick)
        .toolbar {
            #if os(iOS)
            // Barre trop étroite sur iPhone : affichage et filtre regroupés dans un menu.
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Picker("Affichage", selection: $binder) {
                        Label("Grille", systemImage: "square.grid.3x3").tag(false)
                        Label("Classeur", systemImage: "book.closed").tag(true)
                    }
                    .pickerStyle(.inline)
                    Toggle("Seulement les manquantes", isOn: $missingOnly).disabled(binder)
                    Button {
                        withAnimation { binder = false; selecting = true; batchMessage = nil }
                    } label: { Label("Cocher plusieurs cartes à ajouter", systemImage: "checklist") }
                } label: {
                    Label("Affichage", systemImage: binder ? "book.closed" : (missingOnly ? "line.3.horizontal.decrease.circle.fill" : "square.grid.3x3"))
                }
            }
            #else
            ToolbarItem(placement: .primaryAction) {
                Picker("Affichage", selection: $binder) {
                    Text("Grille").tag(false)
                    Text("Classeur").tag(true)
                }
                .pickerStyle(.segmented)
            }
            ToolbarItem(placement: .primaryAction) {
                Toggle("Manquantes", isOn: $missingOnly).disabled(binder)
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    withAnimation { binder = false; selecting = true; batchMessage = nil }
                } label: { Label("Cocher plusieurs cartes", systemImage: "checklist") }
                .disabled(selecting)
            }
            #endif
            ToolbarItem(placement: .primaryAction) {
                if let detail {
                    let goal = Goal(id: setId, total: detail.cardCount?.official ?? detail.cards.count, name: detail.name)
                    let pinned = Goal.parse(goalsRaw).contains { $0.id == setId }
                    Button { goalsRaw = Goal.toggled(goalsRaw, goal) } label: {
                        Label(pinned ? "Retirer des objectifs" : "Épingler comme objectif",
                              systemImage: pinned ? "pin.fill" : "pin")
                    }
                }
            }
        }
        .task {
            guard detail == nil else { return }
            do { detail = try await TCGdex.set(setId) } catch { self.error = error.localizedDescription }
        }
    }
}
