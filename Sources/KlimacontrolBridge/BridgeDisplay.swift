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

    /// Skala unter dem Regler der Solltemperatur (`UIText.temperatureScale*`). `fraction` ist die Lage auf der Spur
    /// (0 = `min`, 1 = `max`), gemessen zwischen den Knopfmitten des Reglers.
    struct TemperatureScale: Encodable {
        struct Mark: Encodable {
            var value, fraction: Double
            /// Beschriftung („16°“ bzw. „Raum 23,0°“); fehlt bei `emphasized`.
            var text: String?
        }

        var min, max: Double
        var labels, emphasized: [Mark]

        static var current: TemperatureScale {
            TemperatureScale(
                min: UIOptions.temperatureMin, max: UIOptions.temperatureMax,
                labels: UIText.temperatureScaleLabels.map {
                    Mark(value: $0, fraction: UIText.temperatureScaleFraction($0), text: Fmt.target($0))
                },
                emphasized: UIText.temperatureScaleEmphasized.map {
                    Mark(value: $0, fraction: UIText.temperatureScaleFraction($0), text: nil)
                })
        }
    }

    /// Zeitraum des Verlaufs mit der Teilung seiner Zeitachse (`ChartAxis.timeStepMinutes`,
    /// `ChartAxis.timeLabelHalfWidth`); ab 1440 min stehen Daten statt Uhrzeiten an der Achse.
    struct ChartRange: Encodable {
        var label: String
        var seconds: Double
        var tickMinutes: Int
        var tickLabelHalfWidth: Double

        init(_ r: UIOptions.ChartRange) {
            label = r.label
            seconds = r.seconds
            tickMinutes = ChartAxis.timeStepMinutes(range: r.seconds)
            tickLabelHalfWidth = ChartAxis.timeLabelHalfWidth(range: r.seconds)
        }
    }

    struct Chart: Encodable {
        var ranges: [ChartRange]
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

    /// Regeln des Hauptfensters aus `MainWindowLayout` (Breiten der Seitenspalten schließen ihre Trennlinie ein).
    struct Window: Encodable {
        struct Heights: Encodable {
            var compact, normal, large: Double
        }

        struct ChartHeights: Encodable {
            var power, temperature, outdoor, energy: Double

            init(_ h: MainWindowLayout.ChartHeights) {
                power = h.power
                temperature = h.temperature
                outdoor = h.outdoor
                energy = h.energy
            }
        }

        var controlWidth, historyMin, historyBalanced, historyGridFrom, diagnosticsMin, diagnosticsMax: Double
        var controlsOnlyMaxWidth: Double
        var minimumHeight: Heights
        var historyBaseHeight, singleOverhead, gridOverhead, gridRowMax, chartStep, energyBarMaxWidth: Double
        /// Graphenhöhen einspaltig ohne zusätzlichen Platz bzw. ganz ausgereizt, und kleinste Höhen im 2 × 2-Raster.
        var chartMin, chartMax, gridChartMin: ChartHeights
        /// Anteile an zusätzlicher Höhe (`MainWindowLayout.chartWeights`); der Verbrauch bekommt nur den Rest.
        var chartWeights: ChartWeights

        struct ChartWeights: Encodable {
            var power, temperature, outdoor: Double
        }

        static var current: Window {
            // Die Höhen sind im Kern privat; sie kommen hier aus `chartHeights` an den Rändern (kein Platz, unbegrenzt).
            let unlimited = 1_000_000.0
            return Window(
                controlWidth: MainWindowLayout.controlWidth, historyMin: MainWindowLayout.historyMin,
                historyBalanced: MainWindowLayout.historyBalanced, historyGridFrom: MainWindowLayout.historyGridFrom,
                diagnosticsMin: MainWindowLayout.diagnosticsMin, diagnosticsMax: MainWindowLayout.diagnosticsMax,
                controlsOnlyMaxWidth: MainWindowLayout.controlsOnlyMaxWidth,
                minimumHeight: Heights(compact: MainWindowLayout.minimumHeight(.compact),
                                       normal: MainWindowLayout.minimumHeight(.normal),
                                       large: MainWindowLayout.minimumHeight(.large)),
                historyBaseHeight: MainWindowLayout.historyBaseHeight, singleOverhead: MainWindowLayout.singleOverhead,
                gridOverhead: MainWindowLayout.gridOverhead, gridRowMax: MainWindowLayout.gridRowMax,
                chartStep: MainWindowLayout.chartStep, energyBarMaxWidth: MainWindowLayout.energyBarMaxWidth,
                chartMin: ChartHeights(MainWindowLayout.chartHeights(columnHeight: 0)),
                chartMax: ChartHeights(MainWindowLayout.chartHeights(columnHeight: unlimited)),
                gridChartMin: ChartHeights(MainWindowLayout.chartHeights(columnHeight: 0, grid: true)),
                chartWeights: ChartWeights(power: MainWindowLayout.chartWeights[0],
                                           temperature: MainWindowLayout.chartWeights[1],
                                           outdoor: MainWindowLayout.chartWeights[2]))
        }
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

    /// Einstellungen → Allgemein → Updates und Hinweis „Update bereit · Jetzt installieren · Später“
    /// (Updates nicht automatisch installieren). Vorlagen mit `{version}`.
    struct Updates: Encodable {
        var autoInstallTitle, autoInstallHelp, intervalTitle: String
        var intervals: [ModeOptionDTO]
        var heldBackTitle, heldBackMessageTemplate, heldBackStatusTemplate, installNow, later: String
        var reminderSeconds: Int
    }

    var temperature: RangeDTO
    var refresh: Refresh
    var rate: Rate
    var price: Price
    var offTimerChoices: [OffTimerDTO]
    var fan: Fan
    var credentials: Credentials
    var temperatureScale: TemperatureScale
    var chart: Chart
    var window: Window
    var energy: Energy
    var connectionModes: [ModeOptionDTO]
    var connectSteps: [StepDTO]
    var cloudFolder: CloudFolder
    var prompts: Prompts
    var texts: Texts
    var updates: Updates

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
            temperatureScale: .current,
            chart: Chart(ranges: UIOptions.chartRanges.map(ChartRange.init),
                         defaultRange: UIOptions.chartRangeDefault, windowCount: UIOptions.chartWindowCount,
                         gapFactor: UIOptions.chartGapFactor, gapMinSeconds: UIOptions.chartGapMinSeconds,
                         temperatureAxis: RangeDTO(min: UIOptions.chartTemperatureAxis.lowerBound,
                                                   max: UIOptions.chartTemperatureAxis.upperBound),
                         outdoorAxis: RangeDTO(min: UIOptions.chartOutdoorAxis.lowerBound,
                                               max: UIOptions.chartOutdoorAxis.upperBound)),
            window: .current,
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
                         updatesFailed: UIText.updatesFailed, updatesCheckButton: UIText.updatesCheckButton),
            updates: Updates(autoInstallTitle: UIText.updatesAutoInstallTitle, autoInstallHelp: UIText.updatesAutoInstallHelp,
                             intervalTitle: UIText.updatesIntervalTitle,
                             intervals: UpdateInterval.allCases.map { ModeOptionDTO(id: $0.rawValue, label: $0.title, help: "") },
                             heldBackTitle: UIText.updatesHeldBackTitle,
                             heldBackMessageTemplate: UIText.updatesHeldBackMessage(version: "{version}"),
                             heldBackStatusTemplate: UIText.updatesHeldBackStatus(version: "{version}"),
                             installNow: UIText.updatesInstallNow, later: UIText.updatesLater,
                             reminderSeconds: Int(AppUpdate.reminderInterval)))
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
        // Lüftersperre beim Trocknen und Stellbarkeit der Solltemperatur (−/+, Regler, Tastenkürzel): Regeln des Kerns.
        let locked = c.state.map { UIOptions.fanLocked($0.mode) } ?? false
        availability["fan"] = AvailabilityDTO(enabled: !locked, why: locked ? UIOptions.fanLockedText : nil)
        if let mode = c.state?.mode {
            let r = UIOptions.rateAvailability(mode: mode, capabilities: c.state?.capabilities)
            availability["rate"] = AvailabilityDTO(enabled: r.enabled, why: r.why)
        }
        availability["target"] = AvailabilityDTO(enabled: UIText.targetAdjustable(c.state), why: nil)
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
        appearanceCustomized = c.appearanceIsCustomized
        onTimerChip = c.onTimerChip
        quitPrompt = c.quitPrompt().map(PromptDTO.init)
        forgetNeedsBackup = c.forgetNeedsBackup
        fanCaption = c.state.map(UIOptions.fanCaption) ?? ""
        scaleRoom = c.state?.indoorTemperature.map {
            OptionsDTO.TemperatureScale.Mark(value: $0, fraction: UIText.temperatureScaleFraction($0),
                                             text: UIText.temperatureScaleRoom($0))
        }
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
