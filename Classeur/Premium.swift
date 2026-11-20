import SwiftUI
import SwiftData
import Charts
import ImageIO

// MARK: - Plus-value

/// Ligne « Plus-value » du bandeau : gain ou perte sur les cartes dont le prix payé est connu.
struct ProfitLine: View {
    let cards: [OwnedCard]

    var body: some View {
        let known = cards.filter { $0.purchasePrice != nil && $0.value != nil }
        if !known.isEmpty {
            let paid = known.reduce(0.0) { $0 + ($1.purchasePrice ?? 0) * Double($1.quantity) }
            let profit = known.reduce(0.0) { $0 + ($1.profit ?? 0) }
            let percent = paid > 0 ? profit / paid : 0
            HStack(spacing: 6) {
                Image(systemName: profit >= 0 ? "arrow.up.right.circle.fill" : "arrow.down.right.circle.fill")
                Text("Plus-value \(signedEur(profit))").fontWeight(.semibold).monospacedDigit()
                Text("(\(percent.formatted(.percent.precision(.fractionLength(0)))) · payé \(eur(paid)))")
                    .opacity(0.75).monospacedDigit()
            }
            .font(.footnote)
            .foregroundStyle(profit >= 0 ? Color.green : Color.red)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
        }
    }
}

/// Champs « prix payé » et plus-value d'un exemplaire.
struct PurchaseFields: View {
    @Bindable var card: OwnedCard

    var body: some View {
        TextField("Prix payé (€ par carte)", value: $card.purchasePrice, format: .number)
            #if os(iOS)
            .keyboardType(.decimalPad)
            #endif
        if let profit = card.profit {
            LabeledContent("Plus-value") {
                Text(signedEur(profit)).monospacedDigit().fontWeight(.semibold)
                    .foregroundStyle(profit >= 0 ? .green : .red)
            }
        }
    }
}

// MARK: - Cartes gradées

struct GradeSection: View {
    @Bindable var card: OwnedCard

    var body: some View {
        Section {
            Toggle("Carte gradée", isOn: Binding(
                get: { card.isGraded },
                set: { graded in
                    withAnimation {
                        card.gradeCompany = graded ? "PSA" : nil
                        card.gradeNote = graded ? 10 : nil
                        if !graded { card.gradedValue = nil }
                    }
                }))
            if card.isGraded {
                Picker("Société", selection: Binding(get: { card.gradeCompany ?? "PSA" }, set: { card.gradeCompany = $0 })) {
                    ForEach(gradeCompanies, id: \.self) { Text($0).tag($0) }
                }
                Picker("Note", selection: Binding(get: { card.gradeNote ?? 10 }, set: { card.gradeNote = $0 })) {
                    ForEach(gradeNotes, id: \.self) { Text($0.formatted()).tag($0) }
                }
                TextField("Valeur estimée (€)", value: $card.gradedValue, format: .number)
                    #if os(iOS)
                    .keyboardType(.decimalPad)
                    #endif
            }
        } header: {
            Text("Gradation")
        } footer: {
            if card.isGraded {
                Text("La valeur estimée remplace le prix Cardmarket (qui concerne les cartes non gradées) dans tes totaux.")
            }
        }
    }
}

/// Petit badge « PSA 10 » posé sur les vignettes.
struct GradeBadge: View {
    let label: String

    var body: some View {
        Text(label)
            .font(.caption2.weight(.heavy))
            .foregroundStyle(.black)
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(LinearGradient.holo, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            .shadow(radius: 2)
    }
}

// MARK: - Historique de prix

struct PriceHistorySection: View {
    let card: OwnedCard

    var body: some View {
        let points = card.priceHistory
        Section("Évolution du prix Cardmarket") {
            if points.count < 2 {
                Text("La courbe se dessinera au fil des actualisations des prix (un point par jour).")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if !points.isEmpty {
                Chart(points) { point in
                    AreaMark(x: .value("Date", point.date), y: .value("Prix", point.price))
                        .foregroundStyle(LinearGradient(colors: [Color.classeur.opacity(0.35), .clear],
                                                        startPoint: .top, endPoint: .bottom))
                    LineMark(x: .value("Date", point.date), y: .value("Prix", point.price))
                        .foregroundStyle(Color.classeur)
                    PointMark(x: .value("Date", point.date), y: .value("Prix", point.price))
                        .foregroundStyle(Color.classeur)
                }
                .chartYAxis { AxisMarks { AxisGridLine(); AxisValueLabel(format: .currency(code: "EUR")) } }
                .frame(height: 180)
                .padding(.vertical, 6)
                if let first = points.first, let last = points.last, points.count >= 2 {
                    LabeledContent("Depuis le \(first.date.formatted(date: .abbreviated, time: .omitted))") {
                        Text(signedEur(last.price - first.price)).monospacedDigit()
                            .foregroundStyle(last.price >= first.price ? .green : .red)
                    }
                }
            }
        }
    }
}

/// Flèche ↑ / ↓ selon la dernière variation de prix.
struct TrendArrow: View {
    let trend: Double?

    var body: some View {
        if let trend {
            Image(systemName: trend > 0 ? "arrow.up.right" : "arrow.down.right")
                .fontWeight(.bold)
                .foregroundStyle(trend > 0 ? .green : .red)
                .accessibilityLabel(trend > 0 ? "Prix en hausse" : "Prix en baisse")
        }
    }
}

// MARK: - Partage en image

/// Image stylée d'une carte (format 4:5, idéal pour les réseaux).
struct ShareCardView: View {
    let image: CGImage?
    let name: String
    let subtitle: String
    let price: String?
    let grade: String?

    var body: some View {
        ZStack {
            LinearGradient.night
            VStack(spacing: 12) {
                Group {
                    if let image {
                        Image(decorative: image, scale: 1).resizable().scaledToFit()
                    } else {
                        RoundedRectangle(cornerRadius: 12).fill(.white.opacity(0.08))
                            .aspectRatio(63.0 / 88.0, contentMode: .fit)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(LinearGradient.holo, lineWidth: 2))
                .shadow(color: Color.classeur.opacity(0.6), radius: 18)
                .frame(height: 280)
                .padding(.top, 8)

                Text(name).font(.system(size: 24, weight: .heavy, design: .rounded)).lineLimit(1).minimumScaleFactor(0.6)
                Text(subtitle).font(.system(size: 13, design: .rounded)).opacity(0.7).lineLimit(1)
                HStack(spacing: 8) {
                    if let grade { GradeBadge(label: grade) }
                    if let price {
                        Text(price).font(.system(size: 18, weight: .bold, design: .rounded)).monospacedDigit()
                    }
                }
                Spacer(minLength: 0)
                HStack(spacing: 6) {
                    Image(systemName: "sparkle").foregroundStyle(LinearGradient.holo)
                    Text("Lumifolio").font(.system(size: 13, weight: .bold, design: .rounded))
                }
                .opacity(0.85)
            }
            .foregroundStyle(.white)
            .padding(20)
        }
        .frame(width: 360, height: 450)
        .overlay(Rectangle().strokeBorder(LinearGradient.holo, lineWidth: 3))
    }
}

/// Bouton de partage : prépare l'image de la carte dès que possible (hors connexion si l'image est enregistrée).
struct ShareCardButton: View {
    let card: OwnedCard
    @State private var rendered: Image?

    var body: some View {
        Group {
            if let rendered {
                ShareLink(item: rendered, preview: SharePreview(card.name, image: rendered)) {
                    Label("Partager en image", systemImage: "square.and.arrow.up")
                }
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .task(id: "\(card.cardId)|\(card.value ?? 0)|\(card.gradeLabel ?? "")|\(card.photo?.count ?? 0)") {
            rendered = await render()
        }
    }

    @MainActor
    private func render() async -> Image? {
        var cg: CGImage?
        if let data = card.photo ?? card.offlineImage, let source = CGImageSourceCreateWithData(data as CFData, nil) {
            cg = CGImageSourceCreateImageAtIndex(source, 0, nil)
        }
        if cg == nil {
            for url in cardImageURLs(imageBase: card.imageBase, cardId: card.cardId, high: true) {
                if let found = await ImageLoader.shared.image(url) { cg = found; break }
            }
        }
        let view = ShareCardView(image: cg, name: card.name,
                                 subtitle: "\(card.setName) · \(card.localId) · \(card.variant.label)",
                                 price: card.value.map(eur), grade: card.gradeLabel)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 3   // 1080 × 1350 px
        guard let output = renderer.cgImage else { return nil }
        return Image(decorative: output, scale: 1)
    }
}

// MARK: - Succès

struct Achievement: Identifiable {
    let id: String
    let title: String
    let detail: String
    let icon: String
    let progress: Double   // 0…1
    var unlocked: Bool { progress >= 1 }
}

func achievements(_ cards: [OwnedCard]) -> [Achievement] {
    let count = Double(cards.reduce(0) { $0 + $1.quantity })
    let value = cards.reduce(0.0) { $0 + $1.totalValue }
    let sets = Double(Set(cards.map(\.setId)).count)
    let shiny = Double(cards.filter { $0.variant != .normal }.count)
    let graded = Double(cards.filter(\.isGraded).count)
    let perfect = Double(cards.filter { $0.isGraded && $0.gradeNote == 10 }.count)
    let languages = Double(Set(cards.map(\.language)).count)
    let doubles = Double(cards.filter { $0.quantity > 1 }.count)

    func step(_ id: String, _ title: String, _ detail: String, _ icon: String, _ current: Double, _ target: Double) -> Achievement {
        Achievement(id: id, title: title, detail: detail, icon: icon, progress: min(current / target, 1))
    }
    return [
        step("c1", "Premier pas", "Ajouter ta première carte", "sparkle", count, 1),
        step("c10", "Petite collection", "Posséder 10 cartes", "rectangle.stack", count, 10),
        step("c50", "Collectionneur", "Posséder 50 cartes", "rectangle.stack.fill", count, 50),
        step("c100", "Centurion", "Posséder 100 cartes", "rosette", count, 100),
        step("c250", "Maître du classeur", "Posséder 250 cartes", "crown.fill", count, 250),
        step("v50", "Trésor naissant", "Collection à 50 €", "eurosign.circle", value, 50),
        step("v250", "Coffre-fort", "Collection à 250 €", "eurosign.circle.fill", value, 250),
        step("v1000", "Dragon sur son tas d'or", "Collection à 1 000 €", "flame.fill", value, 1000),
        step("s5", "Explorateur", "Cartes de 5 extensions", "books.vertical", sets, 5),
        step("s15", "Globe-trotter", "Cartes de 15 extensions", "map.fill", sets, 15),
        step("h5", "Ça brille !", "5 cartes holo ou reverse", "sparkles", shiny, 5),
        step("d5", "Prêt à échanger", "5 cartes en double", "arrow.2.squarepath", doubles, 5),
        step("l3", "Polyglotte", "Cartes en 3 langues", "globe.europe.africa.fill", languages, 3),
        step("g1", "Sous plastique", "Une carte gradée", "checkmark.seal.fill", graded, 1),
        step("g10", "Gemme parfaite", "Une carte gradée 10", "diamond.fill", perfect, 1),
    ]
}

struct AchievementsView: View {
    let cards: [OwnedCard]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let list = achievements(cards)
        NavigationStack {
            ScrollView {
                Text("\(list.filter(\.unlocked).count) / \(list.count) débloqués")
                    .font(.headline).foregroundStyle(.secondary)
                    .padding(.top, 8)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
                    ForEach(list) { item in
                        VStack(spacing: 8) {
                            Image(systemName: item.icon)
                                .font(.title2.bold())
                                .foregroundStyle(item.unlocked ? AnyShapeStyle(Color.black) : AnyShapeStyle(Color.white.opacity(0.35)))
                                .frame(width: 54, height: 54)
                                .background(item.unlocked ? AnyShapeStyle(LinearGradient.holo) : AnyShapeStyle(Color.white.opacity(0.06)),
                                            in: Circle())
                            Text(item.title).font(.subheadline.bold()).multilineTextAlignment(.center)
                            Text(item.detail).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                            if !item.unlocked {
                                ProgressBar(value: item.progress, color: .classeur).frame(height: 6)
                            }
                        }
                        .frame(maxWidth: .infinity, minHeight: 150)
                        .padding(12)
                        .background(Color.white.opacity(item.unlocked ? 0.08 : 0.03),
                                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay {
                            if item.unlocked {
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .strokeBorder(LinearGradient.holo, lineWidth: 1).opacity(0.7)
                            }
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityValue(item.unlocked ? "Débloqué" : "\(Int(item.progress * 100)) %")
                    }
                }
                .padding()
            }
            .nightBackground()
            .navigationTitle("Succès")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("OK") { dismiss() } } }
        }
        .frame(minWidth: 420, idealWidth: 560, minHeight: 380, idealHeight: 620)   // tient dans une petite fenêtre
    }
}

// MARK: - Mode vitrine

/// Diaporama plein écran des plus belles cartes (les plus chères ayant une image).
struct VitrineView: View {
    let cards: [OwnedCard]
    @State private var index = 0
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            LinearGradient.night.ignoresSafeArea()
            if cards.isEmpty {
                Text("Ajoute des cartes pour les exposer ici.").foregroundStyle(.secondary)
            } else {
                let card = cards[index % cards.count]
                VStack(spacing: 18) {
                    CardThumb(imageBase: card.imageBase, cardId: card.cardId, high: true, shine: true,
                              photo: card.photo ?? card.offlineImage)
                        .frame(maxWidth: 440, maxHeight: 560)
                        .shadow(color: Color.classeur.opacity(0.5), radius: 30)
                    Text(card.name).font(.largeTitle.bold()).lineLimit(1).minimumScaleFactor(0.6)
                    Text("\(card.setName) · \(card.localId)").foregroundStyle(.secondary)
                    HStack(spacing: 10) {
                        if let grade = card.gradeLabel { GradeBadge(label: grade) }
                        if let price = card.value { Text(eur(price)).font(.title3.bold()).monospacedDigit() }
                    }
                    Text("\(index % cards.count + 1) / \(cards.count)").font(.caption).foregroundStyle(.tertiary)
                }
                .foregroundStyle(.white)
                .padding(32)
                .id(card.persistentModelID)
                .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                                        removal: .move(edge: .leading).combined(with: .opacity)))
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { next() }
        .overlay(alignment: .topTrailing) {
            Button { dismiss() } label: {
                Image(systemName: "xmark.circle.fill").font(.largeTitle)
                    .symbolRenderingMode(.hierarchical).foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .padding()
            .accessibilityLabel("Fermer")
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                if !Task.isCancelled { next() }
            }
        }
        #if os(macOS)
        .frame(minWidth: 520, idealWidth: 640, minHeight: 560, idealHeight: 780)
        #endif
    }

    private func next() {
        guard !cards.isEmpty else { return }
        withAnimation(.spring(duration: 0.7)) { index = (index + 1) % cards.count }
    }
}

/// Raccourcis « Succès » et « Vitrine » sous le bandeau de la Collection.
struct PremiumShortcuts: View {
    let cards: [OwnedCard]
    @State private var showingAchievements = false
    @State private var showingVitrine = false

    var body: some View {
        let list = achievements(cards)
        HStack(spacing: 10) {
            Button { showingAchievements = true } label: {
                Label("Succès \(list.filter(\.unlocked).count)/\(list.count)", systemImage: "trophy.fill")
                    .frame(maxWidth: .infinity)
            }
            Button { showingVitrine = true } label: {
                Label("Mode vitrine", systemImage: "play.rectangle.fill").frame(maxWidth: .infinity)
            }
        }
        .buttonStyle(.bordered)
        .tint(.classeur)
        .font(.subheadline.weight(.semibold))
        .lineLimit(1)
        .padding(.horizontal)
        .padding(.top, 12)
        .sheet(isPresented: $showingAchievements) { AchievementsView(cards: cards) }
        #if os(iOS)
        .fullScreenCover(isPresented: $showingVitrine) { VitrineView(cards: showcase) }
        #else
        .sheet(isPresented: $showingVitrine) { VitrineView(cards: showcase) }
        #endif
    }

    /// Les 30 cartes les plus chères ayant une image enregistrée (à défaut, les 30 plus chères).
    private var showcase: [OwnedCard] {
        let withImage = cards.filter { $0.photo != nil || $0.offlineImage != nil }
        return Array((withImage.isEmpty ? cards : withImage).sorted { ($0.value ?? 0) > ($1.value ?? 0) }.prefix(30))
    }
}

// MARK: - Classeurs perso

struct BinderSection: View {
    @Bindable var card: OwnedCard
    let existing: [String]
    @State private var naming = false
    @State private var newName = ""

    var body: some View {
        Section("Mes classeurs") {
            if card.binderList.isEmpty {
                Text("Range cette carte dans tes propres classeurs (« Deck », « À vendre »…).")
                    .font(.callout).foregroundStyle(.secondary)
            }
            ForEach(card.binderList, id: \.self) { name in
                HStack {
                    Label(name, systemImage: "folder.fill")
                    Spacer()
                    Button(role: .destructive) {
                        card.binderList.removeAll { $0 == name }
                    } label: { Image(systemName: "minus.circle.fill") }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Retirer de \(name)")
                }
            }
            Menu {
                ForEach(existing.filter { !card.binderList.contains($0) }, id: \.self) { name in
                    Button(name) { card.binderList.append(name) }
                }
                Divider()
                Button("Nouveau classeur…") { naming = true }
            } label: {
                Label("Ajouter à un classeur", systemImage: "folder.badge.plus")
            }
        }
        .alert("Nouveau classeur", isPresented: $naming) {
            TextField("Nom du classeur", text: $newName)
            Button("Créer") {
                let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
                    .replacingOccurrences(of: "\n", with: " ")
                if !name.isEmpty && !card.binderList.contains(name) { card.binderList.append(name) }
                newName = ""
            }
            Button("Annuler", role: .cancel) { newName = "" }
        }
    }
}

/// Explique d'où vient le prix d'une 1ère édition.
struct EditionNote: View {
    let variant: Variant
    let ratio: Double?

    var body: some View {
        if variant == .firstEdition {
            Text(ratio.map { "1ère édition estimée : cote × \($0.formatted(.number.precision(.fractionLength(1)))) (écart 1ère éd. / illimitée observé sur TCGplayer)" }
                 ?? "Pas de cote 1ère édition connue : prix de l'édition illimitée.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
