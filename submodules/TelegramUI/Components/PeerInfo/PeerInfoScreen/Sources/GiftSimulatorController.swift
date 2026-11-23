import Foundation
import UIKit
import Display
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
import ItemListUI
import PresentationDataUtils
import AccountContext

// MARK: - Gift Simulator
//
// A purely local "what if" sandbox. Nothing here talks to the server except to READ the public
// gift catalog and upgrade previews (real attribute chances). Simulated gifts live only in
// UserDefaults, are never sent, never appear in chats or the profile, and every one of them is
// labelled as a simulation in the UI.

struct GiftSimulatorSettings: Codable, Equatable {
    enum Mode: Int, Codable {
        case original   // real server chances
        case custom     // target chance = luck%
        case bonus      // target chance = original + luck%
    }
    var mode: Mode = .original
    var luck: Int = 0                 // 0...100
    var targetModel: String = ""      // empty = rarest of this attribute
    var targetBackdrop: String = ""
    var targetPattern: String = ""
}

struct GiftSimulatorRolledAttribute: Codable, Equatable {
    var name: String
    var permille: Int32
}

struct GiftSimulatorItem: Codable, Equatable {
    var uid: Int64
    var giftId: Int64
    var title: String
    var number: Int32?
    var model: GiftSimulatorRolledAttribute?
    var backdrop: GiftSimulatorRolledAttribute?
    var pattern: GiftSimulatorRolledAttribute?

    var isUpgraded: Bool { return self.number != nil }
}

struct GiftSimulatorStoredState: Codable, Equatable {
    var settings = GiftSimulatorSettings()
    var items: [GiftSimulatorItem] = []
    var nextUid: Int64 = 1

    private static let key = "GiftSimulator_v1"

    static func load() -> GiftSimulatorStoredState {
        if let data = UserDefaults.standard.data(forKey: key), let value = try? JSONDecoder().decode(GiftSimulatorStoredState.self, from: data) {
            return value
        }
        return GiftSimulatorStoredState()
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: GiftSimulatorStoredState.key)
        }
    }
}

// MARK: - Chance engine

enum GiftSimulatorRoller {
    struct Candidate {
        let name: String
        let permille: Int32
    }

    /// Picks one candidate. `target` empty = rarest candidates (lowest permille).
    static func roll(_ candidates: [Candidate], target: String, settings: GiftSimulatorSettings) -> Candidate? {
        guard !candidates.isEmpty else {
            return nil
        }
        func weight(_ c: Candidate) -> Double {
            return max(Double(c.permille), 0.0001)
        }
        func weightedPick(_ list: [Candidate]) -> Candidate {
            let total = list.reduce(0.0) { $0 + weight($1) }
            var r = Double.random(in: 0 ..< total)
            for c in list {
                r -= weight(c)
                if r < 0 {
                    return c
                }
            }
            return list[list.count - 1]
        }

        if settings.mode == .original {
            return weightedPick(candidates)
        }

        let trimmed = target.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var targets: [Candidate]
        if !trimmed.isEmpty {
            targets = candidates.filter { $0.name.lowercased() == trimmed }
            if targets.isEmpty {
                targets = candidates.filter { $0.name.lowercased().contains(trimmed) }
            }
        } else {
            let minPermille = candidates.map { $0.permille }.min() ?? 0
            targets = candidates.filter { $0.permille == minPermille }
        }
        if targets.isEmpty {
            return weightedPick(candidates)
        }
        let targetNames = Set(targets.map { $0.name })
        let others = candidates.filter { !targetNames.contains($0.name) }

        let total = candidates.reduce(0.0) { $0 + weight($1) }
        let original = targets.reduce(0.0) { $0 + weight($1) } / total
        let luck = Double(max(0, min(100, settings.luck))) / 100.0

        let chance: Double
        switch settings.mode {
        case .original:
            chance = original
        case .custom:
            chance = luck
        case .bonus:
            chance = min(1.0, original + luck)
        }

        if others.isEmpty || Double.random(in: 0 ..< 1) < chance {
            return weightedPick(targets)
        } else {
            return weightedPick(others)
        }
    }

    static func candidates(from preview: StarGiftUpgradePreview) -> (models: [Candidate], backdrops: [Candidate], patterns: [Candidate]) {
        var models: [Candidate] = []
        var backdrops: [Candidate] = []
        var patterns: [Candidate] = []
        for attribute in preview.attributes {
            switch attribute {
            case let .model(name, _, rarity, _):
                models.append(Candidate(name: name, permille: rarity.permilleValue))
            case let .backdrop(name, _, _, _, _, _, rarity):
                backdrops.append(Candidate(name: name, permille: rarity.permilleValue))
            case let .pattern(name, _, rarity):
                patterns.append(Candidate(name: name, permille: rarity.permilleValue))
            default:
                break
            }
        }
        return (models, backdrops, patterns)
    }
}

// MARK: - UI

private final class GiftSimulatorArguments {
    let sendToSelf: (Int64, String) -> Void
    let upgrade: (Int64) -> Void
    let remove: (Int64) -> Void
    let clearAll: () -> Void
    let updateSettings: ((inout GiftSimulatorSettings) -> Void) -> Void

    init(sendToSelf: @escaping (Int64, String) -> Void, upgrade: @escaping (Int64) -> Void, remove: @escaping (Int64) -> Void, clearAll: @escaping () -> Void, updateSettings: @escaping ((inout GiftSimulatorSettings) -> Void) -> Void) {
        self.sendToSelf = sendToSelf
        self.upgrade = upgrade
        self.remove = remove
        self.clearAll = clearAll
        self.updateSettings = updateSettings
    }
}

private enum GiftSimulatorSection: Int32 {
    case info
    case chances
    case inventory
    case catalog
}

private enum GiftSimulatorEntry: ItemListNodeEntry {
    case info(String)

    case chancesHeader
    case mode(index: Int32, title: String, mode: GiftSimulatorSettings.Mode, checked: Bool)
    case luck(Int)
    case target(index: Int32, title: String, value: String, kind: Int)
    case chancesFooter(String)

    case inventoryHeader
    case inventoryItem(index: Int32, item: GiftSimulatorItem)
    case inventoryEmpty
    case clearAll

    case catalogHeader
    case catalogItem(index: Int32, giftId: Int64, title: String, stars: Int64)
    case catalogLoading

    var section: ItemListSectionId {
        switch self {
        case .info:
            return GiftSimulatorSection.info.rawValue
        case .chancesHeader, .mode, .luck, .target, .chancesFooter:
            return GiftSimulatorSection.chances.rawValue
        case .inventoryHeader, .inventoryItem, .inventoryEmpty, .clearAll:
            return GiftSimulatorSection.inventory.rawValue
        case .catalogHeader, .catalogItem, .catalogLoading:
            return GiftSimulatorSection.catalog.rawValue
        }
    }

    var stableId: Int64 {
        switch self {
        case .info:
            return 0
        case .chancesHeader:
            return 10
        case let .mode(index, _, _, _):
            return 11 + Int64(index)
        case .luck:
            return 20
        case let .target(index, _, _, _):
            return 21 + Int64(index)
        case .chancesFooter:
            return 30
        case .inventoryHeader:
            return 100
        case .inventoryEmpty:
            return 101
        case let .inventoryItem(index, _):
            return 1_000 + Int64(index)
        case .clearAll:
            return 99_999
        case .catalogHeader:
            return 100_000
        case .catalogLoading:
            return 100_001
        case let .catalogItem(index, _, _, _):
            return 100_010 + Int64(index)
        }
    }

    static func <(lhs: GiftSimulatorEntry, rhs: GiftSimulatorEntry) -> Bool {
        return lhs.stableId < rhs.stableId
    }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        let arguments = arguments as! GiftSimulatorArguments
        switch self {
        case let .info(text):
            return ItemListTextItem(presentationData: presentationData, text: .markdown(text), sectionId: self.section)
        case .chancesHeader:
            return ItemListSectionHeaderItem(presentationData: presentationData, text: "ШАНСЫ УЛУЧШЕНИЯ", sectionId: self.section)
        case let .mode(_, title, mode, checked):
            return ItemListCheckboxItem(presentationData: presentationData, title: title, style: .left, checked: checked, zeroSeparatorInsets: false, sectionId: self.section, action: {
                arguments.updateSettings { $0.mode = mode }
            })
        case let .luck(value):
            return ItemListSingleLineInputItem(presentationData: presentationData, title: NSAttributedString(string: "Удача, %"), text: "\(value)", placeholder: "0–100", type: .number, sectionId: self.section, textUpdated: { text in
                let parsed = max(0, min(100, Int(text) ?? 0))
                arguments.updateSettings { $0.luck = parsed }
            }, action: {})
        case let .target(_, title, value, kind):
            return ItemListSingleLineInputItem(presentationData: presentationData, title: NSAttributedString(string: title), text: value, placeholder: "пусто = самые редкие", type: .regular(capitalization: false, autocorrection: false), sectionId: self.section, textUpdated: { text in
                arguments.updateSettings { settings in
                    switch kind {
                    case 0:
                        settings.targetModel = text
                    case 1:
                        settings.targetBackdrop = text
                    default:
                        settings.targetPattern = text
                    }
                }
            }, action: {})
        case let .chancesFooter(text):
            return ItemListTextItem(presentationData: presentationData, text: .markdown(text), sectionId: self.section)
        case .inventoryHeader:
            return ItemListSectionHeaderItem(presentationData: presentationData, text: "МОИ ПОДАРКИ · СИМУЛЯЦИЯ", sectionId: self.section)
        case .inventoryEmpty:
            return ItemListTextItem(presentationData: presentationData, text: .plain("Пока пусто. Выберите подарок в каталоге ниже."), sectionId: self.section)
        case let .inventoryItem(_, item):
            if item.isUpgraded {
                let parts: [String] = [item.model, item.backdrop, item.pattern].compactMap { attribute in
                    guard let attribute else { return nil }
                    return "\(attribute.name) \(formatPermille(attribute.permille))"
                }
                return ItemListDisclosureItem(presentationData: presentationData, title: "🧪 \(item.title) #\(item.number ?? 0)", label: "СИМУЛЯЦИЯ", labelStyle: .coloredText(presentationData.theme.list.itemDestructiveColor), additionalDetailLabel: parts.joined(separator: " · "), sectionId: self.section, style: .blocks, disclosureStyle: .none, action: nil)
            } else {
                return ItemListDisclosureItem(presentationData: presentationData, title: "🧪 \(item.title)", label: "Улучшить", additionalDetailLabel: "СИМУЛЯЦИЯ · не улучшен", sectionId: self.section, style: .blocks, action: {
                    arguments.upgrade(item.uid)
                })
            }
        case .clearAll:
            return ItemListActionItem(presentationData: presentationData, title: "Очистить симуляцию", kind: .destructive, alignment: .natural, sectionId: self.section, style: .blocks, action: {
                arguments.clearAll()
            })
        case .catalogHeader:
            return ItemListSectionHeaderItem(presentationData: presentationData, text: "КАТАЛОГ · ПОДАРИТЬ СЕБЕ (СИМУЛЯЦИЯ)", sectionId: self.section)
        case .catalogLoading:
            return ItemListTextItem(presentationData: presentationData, text: .plain("Загрузка каталога…"), sectionId: self.section)
        case let .catalogItem(_, giftId, title, stars):
            return ItemListDisclosureItem(presentationData: presentationData, title: title, label: "Подарить себе", additionalDetailLabel: "в оригинале \(stars) ⭐️ · здесь бесплатно", sectionId: self.section, style: .blocks, action: {
                arguments.sendToSelf(giftId, title)
            })
        }
    }
}

private func formatPermille(_ value: Int32) -> String {
    if value <= 0 {
        return ""
    }
    let percent = Double(value) / 10.0
    if percent.rounded() == percent {
        return "\(Int(percent))%"
    }
    return String(format: "%.1f%%", percent)
}

private struct GiftSimulatorCatalogGift: Equatable {
    let id: Int64
    let title: String
    let stars: Int64
}

private func giftSimulatorEntries(state: GiftSimulatorStoredState, catalog: [GiftSimulatorCatalogGift]?) -> [GiftSimulatorEntry] {
    var entries: [GiftSimulatorEntry] = []
    entries.append(.info("**Режим симуляции.** Подарки здесь ненастоящие: они не отправляются, не тратят звёзды, не существуют на сервере и не видны в чатах, профиле и у других людей. Каждый помечен 🧪 «СИМУЛЯЦИЯ»."))

    let s = state.settings
    entries.append(.chancesHeader)
    entries.append(.mode(index: 0, title: "Оригинальные шансы", mode: .original, checked: s.mode == .original))
    entries.append(.mode(index: 1, title: "Свой шанс (удача = шанс цели)", mode: .custom, checked: s.mode == .custom))
    entries.append(.mode(index: 2, title: "Бонус к оригинальному шансу", mode: .bonus, checked: s.mode == .bonus))
    if s.mode != .original {
        entries.append(.luck(s.luck))
        entries.append(.target(index: 0, title: "Модель", value: s.targetModel, kind: 0))
        entries.append(.target(index: 1, title: "Фон", value: s.targetBackdrop, kind: 1))
        entries.append(.target(index: 2, title: "Узор", value: s.targetPattern, kind: 2))
    }
    entries.append(.chancesFooter("Цель — конкретное название модели, фона или узора. Если поле пустое, целью будут самые редкие варианты. «Свой шанс»: цель выпадает с вероятностью удачи (0–100%). «Бонус»: удача прибавляется к реальному шансу цели. Остальные варианты распределяются по реальным весам."))

    entries.append(.inventoryHeader)
    if state.items.isEmpty {
        entries.append(.inventoryEmpty)
    } else {
        for (i, item) in state.items.reversed().enumerated() {
            entries.append(.inventoryItem(index: Int32(i), item: item))
        }
        entries.append(.clearAll)
    }

    entries.append(.catalogHeader)
    if let catalog {
        for (i, gift) in catalog.enumerated() {
            entries.append(.catalogItem(index: Int32(i), giftId: gift.id, title: gift.title, stars: gift.stars))
        }
    } else {
        entries.append(.catalogLoading)
    }
    return entries
}

func giftSimulatorController(context: AccountContext) -> ViewController {
    let statePromise = ValuePromise(GiftSimulatorStoredState.load(), ignoreRepeated: true)
    let stateValue = Atomic(value: GiftSimulatorStoredState.load())
    let updateState: ((inout GiftSimulatorStoredState) -> Void) -> Void = { f in
        let updated = stateValue.modify { current in
            var current = current
            f(&current)
            return current
        }
        updated.save()
        statePromise.set(updated)
    }

    let previews = Atomic<[Int64: StarGiftUpgradePreview]>(value: [:])
    let upgradeDisposable = DisposableSet()
    var presentTextImpl: ((String) -> Void)?

    let arguments = GiftSimulatorArguments(
        sendToSelf: { giftId, title in
            updateState { state in
                state.items.append(GiftSimulatorItem(uid: state.nextUid, giftId: giftId, title: title, number: nil, model: nil, backdrop: nil, pattern: nil))
                state.nextUid += 1
            }
            presentTextImpl?("🧪 «\(title)» добавлен в симуляцию")
        },
        upgrade: { uid in
            guard let item = stateValue.with({ $0.items.first(where: { $0.uid == uid }) }), !item.isUpgraded else {
                return
            }
            let apply: (StarGiftUpgradePreview) -> Void = { preview in
                let settings = stateValue.with { $0.settings }
                let c = GiftSimulatorRoller.candidates(from: preview)
                let model = GiftSimulatorRoller.roll(c.models, target: settings.targetModel, settings: settings)
                let backdrop = GiftSimulatorRoller.roll(c.backdrops, target: settings.targetBackdrop, settings: settings)
                let pattern = GiftSimulatorRoller.roll(c.patterns, target: settings.targetPattern, settings: settings)
                updateState { state in
                    if let index = state.items.firstIndex(where: { $0.uid == uid }) {
                        state.items[index].number = Int32.random(in: 1 ... 200_000)
                        state.items[index].model = model.flatMap { GiftSimulatorRolledAttribute(name: $0.name, permille: $0.permille) }
                        state.items[index].backdrop = backdrop.flatMap { GiftSimulatorRolledAttribute(name: $0.name, permille: $0.permille) }
                        state.items[index].pattern = pattern.flatMap { GiftSimulatorRolledAttribute(name: $0.name, permille: $0.permille) }
                    }
                }
                let summary = [model?.name, backdrop?.name, pattern?.name].compactMap { $0 }.joined(separator: " · ")
                presentTextImpl?("🧪 Симуляция улучшения: \(summary)")
            }
            if let cached = previews.with({ $0[item.giftId] }) {
                apply(cached)
                return
            }
            upgradeDisposable.add((context.engine.payments.starGiftUpgradePreview(giftId: item.giftId)
            |> take(1)
            |> deliverOnMainQueue).start(next: { preview in
                guard let preview, !preview.attributes.isEmpty else {
                    presentTextImpl?("Для этого подарка нет данных об улучшении")
                    return
                }
                let _ = previews.modify { current in
                    var current = current
                    current[item.giftId] = preview
                    return current
                }
                apply(preview)
            }))
        },
        remove: { uid in
            updateState { state in
                state.items.removeAll(where: { $0.uid == uid })
            }
        },
        clearAll: {
            updateState { state in
                state.items.removeAll()
            }
        },
        updateSettings: { f in
            updateState { state in
                f(&state.settings)
            }
        }
    )

    let catalogSignal: Signal<[GiftSimulatorCatalogGift]?, NoError> = context.engine.payments.cachedStarGifts()
    |> map { gifts -> [GiftSimulatorCatalogGift]? in
        guard let gifts else {
            return nil
        }
        var result: [GiftSimulatorCatalogGift] = []
        for gift in gifts {
            if case let .generic(gift) = gift, gift.upgradeStars != nil {
                result.append(GiftSimulatorCatalogGift(id: gift.id, title: gift.title ?? "Подарок \(gift.id)", stars: gift.price))
            }
        }
        return result
    }

    let signal = combineLatest(queue: .mainQueue(),
        context.sharedContext.presentationData,
        statePromise.get(),
        catalogSignal
    )
    |> map { presentationData, state, catalog -> (ItemListControllerState, (ItemListNodeState, Any)) in
        let controllerState = ItemListControllerState(presentationData: ItemListPresentationData(presentationData), title: .text("Улучшения · симуляция"), leftNavigationButton: nil, rightNavigationButton: nil, backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back))
        let listState = ItemListNodeState(presentationData: ItemListPresentationData(presentationData), entries: giftSimulatorEntries(state: state, catalog: catalog), style: .blocks, animateChanges: false)
        return (controllerState, (listState, arguments))
    }
    |> afterDisposed {
        upgradeDisposable.dispose()
    }

    let controller = ItemListController(context: context, state: signal)
    presentTextImpl = { [weak controller] text in
        guard let controller else {
            return
        }
        let presentationData = context.sharedContext.currentPresentationData.with { $0 }
        let alert = textAlertController(context: context, title: nil, text: text, actions: [TextAlertAction(type: .defaultAction, title: presentationData.strings.Common_OK, action: {})])
        controller.present(alert, in: .window(.root))
    }
    return controller
}
