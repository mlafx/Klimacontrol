import Foundation
import KlimacontrolCore
import MideaKit

// Anzeigetexte und Auswahllisten aus dem Kern (UIOptions, UIText, ACController+DisplayText) für den Schnappschuss.
// Die Windows-Oberfläche zeigt sie nur an.

struct ChoiceDTO: Encodable {
    var label: String
    var seconds: Double
}

struct MarkDTO: Encodable {
    var label: String
    var value: Int
}

struct OffTimerDTO: Encodable {
    var minutes: Int
    var label: String
}

struct ModeOptionDTO: Encodable {
    var id, label, help: String
}

struct StepDTO: Encodable {
    var phase, name: String
}

struct PromptDTO: Encodable, Equatable {
    var title, message, cancel, confirm: String
    var warning: Bool

    init(_ p: ConfirmPrompt) {
        title = p.title
        message = p.message
        cancel = p.cancel
        confirm = p.confirm
        warning = p.warning
    }
}

struct NoticeDTO: Encodable, Equatable {
    var title, message: String

    init(_ n: NoticeText) {
        title = n.title
        message = n.message
    }
}

struct ForgetPromptDTO: Encodable, Equatable {
    var title, message, backup, confirm, cancel: String
    var warning: Bool

    init(_ p: ForgetPrompt) {
        title = p.title
        message = p.message
        backup = p.backup
        confirm = p.confirm
        cancel = p.cancel
        warning = p.warning
    }
}

struct RangeDTO: Encodable {
    var min, max: Double
}

/// Auswahllisten, Grenzen, Standardwerte und feste Rückfragen. Wird je Schnappschuss neu gebaut, weil die Texte der
/// Sprache folgen (kein `static let`, das die erste Sprache festhielte).
struct OptionsDTO: Encodable {
    struct Refresh: Encodable {
        var choices: [ChoiceDTO]
        var min, max, warnBelow: Int
        var customLabel, customHelp, warning: String
    }

    struct Rate: Encodable {
        var choices: [Int]
        var fallback: Int
        var help: String
    }

    struct Fan: Encodable {
        var marks: [MarkDTO]
        var autoKnob: Int
        var lockedText, autoHelp: String
    }

    struct Credentials: Encodable {
        var tokenLength, keyLength, defaultPort: Int
        var addressPlaceholder, addressExample, addressOrHostPrompt, tokenPrompt, keyPrompt: String
    }

    struct Chart: Encodable {
        var ranges: [ChoiceDTO]
        var defaultRange: Double
        var windowCount: Int
        /// Lücke = max(gapMinSeconds, gapFactor × Punktabstand), Punktabstand = Zeitraum / windowCount.
        var gapFactor, gapMinSeconds: Double
        var temperatureAxis, outdoorAxis: RangeDTO
    }

    struct EnergyKind: Encodable {
        var id, label: String
        var count: Int
    }

    struct Energy: Encodable {
        var kinds: [EnergyKind]
        var defaultKind: String
        var title, help, legend, noData: String
    }

    struct Price: Encodable {
        var min, max: Double
        var fractionDigitsMin, fractionDigitsMax: Int
    }

    struct CloudFolder: Encodable {
        /// Pfadteile (nach Umwandlung von `\` in `/`), die einen Cloud-Ordner verraten.
        var markers: [String]
        var title, messageTemplate, cancel, confirm: String
    }

    struct Prompts: Encodable {
        var replaceScenes, selfClean, accountRemove: PromptDTO
        /// „Anlage neu einrichten?“ ohne bzw. mit Hinweis auf noch nicht gesicherte Zugangsdaten (`forgetNeedsBackup`).
        var forget, forgetNeedsBackup: ForgetPromptDTO
        /// Hinweis, wenn „Nur Cloud“ ohne Midea-Konto gewählt wird.
        var cloudNeedsAccount: NoticeDTO
    }

    struct Texts: Encodable {
        var offCaption, offHint, fanModeCaption, connectSlow, retry, accountSignedIn, accountRemoved: String
        var setupLANOnlyChoice, importPanelTitle, importPanelMessage, exportBackupPanelTitle, exportBackupPanelMessage: String
        var exportBackupFileName, exportHistoryPanelTitle, exportHistoryFileName: String
        var updatesHelp, updatesChecking, updatesCurrent, updatesInstallingTemplate, updatesFailed, updatesCheckButton: String
    }

    var temperature: RangeDTO
    var refresh: Refresh
    var rate: Rate
    var price: Price
    var offTimerChoices: [OffTimerDTO]
    var fan: Fan
    var credentials: Credentials
    var chart: Chart
    var energy: Energy
    var connectionModes: [ModeOptionDTO]
    var connectSteps: [StepDTO]
    var cloudFolder: CloudFolder
    var prompts: Prompts
    var texts: Texts

    static var current: OptionsDTO {
        let folder = UIText.cloudFolderPrompt(folder: "{folder}")
        return OptionsDTO(
            temperature: RangeDTO(min: UIOptions.temperatureMin, max: UIOptions.temperatureMax),
            refresh: Refresh(choices: UIOptions.refreshChoices.map { ChoiceDTO(label: $0.label, seconds: Double($0.seconds)) },
                             min: UIOptions.refreshMin, max: UIOptions.refreshMax, warnBelow: UIOptions.refreshWarnBelow,
                             customLabel: UIOptions.refreshCustomLabel, customHelp: UIOptions.refreshCustomHelp,
                             warning: UIOptions.refreshWarning),
            rate: Rate(choices: UIOptions.rateChoices, fallback: UIOptions.rateFallback, help: UIOptions.rateHelp),
            price: Price(min: UIOptions.priceMin, max: UIOptions.priceMax,
                         fractionDigitsMin: UIOptions.priceFractionDigitsMin, fractionDigitsMax: UIOptions.priceFractionDigitsMax),
            offTimerChoices: UIOptions.offTimerChoices.map { OffTimerDTO(minutes: $0.minutes, label: $0.label) },
            fan: Fan(marks: UIOptions.fanMarks.map { MarkDTO(label: $0.label, value: $0.value) },
                     autoKnob: UIOptions.fanAutoKnob, lockedText: UIOptions.fanLockedText, autoHelp: UIOptions.fanAutoHelp),
            credentials: Credentials(tokenLength: UIOptions.tokenLength, keyLength: UIOptions.keyLength,
                                     defaultPort: UIOptions.defaultPort, addressPlaceholder: UIOptions.addressPlaceholder,
                                     addressExample: UIOptions.addressExample, addressOrHostPrompt: UIOptions.addressOrHostPrompt,
                                     tokenPrompt: UIOptions.tokenPrompt, keyPrompt: UIOptions.keyPrompt),
            chart: Chart(ranges: UIOptions.chartRanges.map { ChoiceDTO(label: $0.label, seconds: $0.seconds) },
                         defaultRange: UIOptions.chartRangeDefault, windowCount: UIOptions.chartWindowCount,
                         gapFactor: 3, gapMinSeconds: 180,
                         temperatureAxis: RangeDTO(min: UIOptions.chartTemperatureAxis.lowerBound,
                                                   max: UIOptions.chartTemperatureAxis.upperBound),
                         outdoorAxis: RangeDTO(min: UIOptions.chartOutdoorAxis.lowerBound,
                                               max: UIOptions.chartOutdoorAxis.upperBound)),
            energy: Energy(kinds: UIOptions.energyKinds.map { EnergyKind(id: $0.kind.rawValue, label: $0.label, count: $0.count) },
                           defaultKind: UIOptions.energyKindDefault.rawValue, title: UIText.energyTitle,
                           help: UIText.energyHelp, legend: UIText.energyLegend, noData: UIText.energyNoData),
            connectionModes: ConnectionMode.allCases.map {
                ModeOptionDTO(id: $0.rawValue, label: $0.title, help: UIText.wayHelp($0))
            },
            connectSteps: UIText.connectSteps.map { StepDTO(phase: phaseName($0.phase), name: $0.name) },
            cloudFolder: CloudFolder(markers: UIText.cloudFolderMarkers, title: folder.title, messageTemplate: folder.message,
                                     cancel: folder.cancel, confirm: folder.confirm),
            prompts: Prompts(replaceScenes: PromptDTO(UIText.replaceScenesPrompt), selfClean: PromptDTO(UIText.selfCleanPrompt),
                             accountRemove: PromptDTO(UIText.accountRemovePrompt(host: .windows)),
                             forget: ForgetPromptDTO(UIText.forgetPrompt(needsBackup: false, host: .windows)),
                             forgetNeedsBackup: ForgetPromptDTO(UIText.forgetPrompt(needsBackup: true, host: .windows)),
                             cloudNeedsAccount: NoticeDTO(UIText.cloudNeedsAccount)),
            texts: Texts(offCaption: UIText.offCaption, offHint: UIText.offHint, fanModeCaption: UIText.fanModeCaption,
                         connectSlow: UIText.connectSlowText, retry: UIText.retryButton,
                         accountSignedIn: UIText.accountSignedIn, accountRemoved: UIText.accountRemoved,
                         setupLANOnlyChoice: UIText.setupLANOnlyChoice, importPanelTitle: UIText.importPanelTitle,
                         importPanelMessage: UIText.importPanelMessage, exportBackupPanelTitle: UIText.exportBackupPanelTitle,
                         exportBackupPanelMessage: UIText.exportBackupPanelMessage,
                         exportBackupFileName: UIText.exportBackupFileName,
                         exportHistoryPanelTitle: UIText.exportHistoryPanelTitle,
                         exportHistoryFileName: UIText.exportHistoryFileName,
                         updatesHelp: UIText.updatesHelp(host: .windows), updatesChecking: UIText.updatesChecking,
                         updatesCurrent: UIText.updatesCurrent,
                         updatesInstallingTemplate: UIText.updatesInstalling(version: "{version}"),
                         updatesFailed: UIText.updatesFailed, updatesCheckButton: UIText.updatesCheckButton))
    }
}

struct AvailabilityDTO: Encodable {
    var enabled: Bool
    var why: String?
}

struct CostLineDTO: Encodable {
    var title, value, help: String
}

struct StartupValuesDTO: Encodable {
    var main, caption: String
    var extras: [String]
    var accessibility: String
}

struct ConnectionStatusDTO: Encodable {
    var text: String
    var connected: Bool
}

struct SetupDonePromptDTO: Encodable {
    var title: String
    var paragraphs: [String]
    var lanOnlyChoice: String?
    var primary: String
    var secondary: String?
}

extension Snapshot {
    /// Anzeigetexte und Optionen, die der Kern berechnet (für die Oberfläche nur noch Anzeige).
    @MainActor mutating func applyDisplay(_ c: ACController) {
        options = .current
        availability = Dictionary(uniqueKeysWithValues: UIOptions.ComfortFeature.allCases.map { f in
            let a = c.availability(f)
            return (f.rawValue, AvailabilityDTO(enabled: a.enabled, why: a.why))
        })
        connectionTooltip = c.connectionTooltip
        uiConnectionState = stateName(c.uiConnectionState)
        uiStaleSince = c.uiStaleSince?.timeIntervalSince1970
        staleText = c.staleText
        heroValue = c.heroValue
        heroCaption = c.heroCaption
        heroHint = c.heroHint
        let cost = c.costLine
        costLine = CostLineDTO(title: cost.title, value: cost.value, help: cost.help)
        powerCostHelp = c.powerCostHelp
        menuTitle = c.menuTitle
        let status = c.connectionStatus
        connectionStatus = ConnectionStatusDTO(text: status.text, connected: status.connected)
        connectStepsLine = c.connectStepsLine
        startupValues = c.startupValues.map {
            StartupValuesDTO(main: $0.main, caption: $0.caption, extras: $0.extras, accessibility: $0.accessibility)
        }
        noticeDetail = c.noticeMessage.map { MessageDTO(what: $0.what, todo: $0.todo, code: $0.code) }
        appearanceIsStandard = c.appearanceIsStandard
        onTimerChip = c.onTimerChip
        quitPrompt = c.quitPrompt().map(PromptDTO.init)
        forgetNeedsBackup = c.forgetNeedsBackup
        fanCaption = c.state.map(UIOptions.fanCaption) ?? ""
        maintenanceHints = c.state.map { UIText.maintenanceHints(filterAlert: $0.filterAlert, errorCode: $0.errorCode) } ?? []
        errorCodeValue = UIText.errorCodeValue(c.state?.errorCode ?? 0)
        filterValue = UIText.filterValue(alert: c.state?.filterAlert ?? false)
        accountFooter = UIText.accountFooter(signedIn: c.cloudAccount != nil, host: .windows)
        if let done = c.setup.completion.flatMap({ UIText.setupDonePrompt($0, host: .windows) }) {
            setup.completion?.prompt = SetupDonePromptDTO(title: done.title, paragraphs: done.paragraphs,
                                                          lanOnlyChoice: done.lanOnlyChoice, primary: done.primary,
                                                          secondary: done.secondary)
        }
        exportText = results.exportHistoryText
    }
}
