import Foundation

/// Decimal helpers shared by the renderers. Money and hours stay in Decimal throughout.
enum ReportNumber {
    static func rounded(_ value: Decimal, places: Int) -> Decimal {
        var input = value
        var result = Decimal()
        NSDecimalRound(&result, &input, places, .plain)
        return result
    }

    /// Hours with two decimals, from milliseconds.
    static func hours(millis: Int) -> Decimal {
        rounded(Decimal(millis) / Decimal(3_600_000), places: 2)
    }

    /// A plain number for spreadsheets: no grouping, a fixed number of decimals, "." or ",".
    static func plain(_ value: Decimal, places: Int, decimalComma: Bool) -> String {
        let number = rounded(value, places: places)
        var text = number.description
        var negative = false
        if text.hasPrefix("-") {
            negative = true
            text.removeFirst()
        }
        let pieces = text.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        var whole = pieces.isEmpty ? "0" : String(pieces[0])
        if whole.isEmpty { whole = "0" }
        var fraction = pieces.count > 1 ? String(pieces[1]) : ""
        while fraction.count < places { fraction += "0" }
        if fraction.count > places { fraction = String(fraction.prefix(places)) }
        var result = whole
        if places > 0 { result += (decimalComma ? "," : ".") + fraction }
        let isZero = number == Decimal(0)
        return negative && !isZero ? "-" + result : result
    }
}

/// Report labels in English, Italian, French, Spanish and German, and locale-aware formatting.
struct ReportStrings: Sendable {
    let language: ReportLanguage
    /// The ledger currency code, such as "EUR".
    let currency: String
    /// The ledger time zone, for times of day.
    let timeZone: TimeZone
    let locale: Locale
    /// The person whose time the report shows, as the client reads it. Empty means `consultant`.
    let personName: String

    init(language: ReportLanguage, currency: String = "EUR", timezone: String = "UTC", personName: String = "") {
        self.language = language
        self.currency = currency
        self.personName = personName.trimmingCharacters(in: .whitespacesAndNewlines)
        self.timeZone = TimeZone(identifier: timezone) ?? TimeZone(secondsFromGMT: 0) ?? TimeZone.current
        self.locale = Locale(identifier: language.rawValue)
    }

    init(document: ReportDocument) {
        self.init(language: document.header.language, currency: document.header.currency,
                  timezone: document.header.timezone, personName: document.header.personName)
    }

    private func pick(_ en: String, _ it: String, _ fr: String, _ es: String, _ de: String) -> String {
        switch language {
        case .en: return en
        case .it: return it
        case .fr: return fr
        case .es: return es
        case .de: return de
        }
    }

    // MARK: Header

    var defaultTitle: String { pick("Work report", "Report delle attività", "Rapport d’activité", "Informe de actividad", "Tätigkeitsbericht") }
    var period: String { pick("Period", "Periodo", "Période", "Periodo", "Zeitraum") }
    var from: String { pick("From", "Da", "De", "De", "Von") }
    var client: String { pick("Client", "Cliente", "Client", "Cliente", "Kunde") }
    var projects: String { pick("Projects", "Progetti", "Projets", "Proyectos", "Projekte") }
    var reference: String { pick("Reference", "Riferimento", "Référence", "Referencia", "Referenz") }
    var note: String { pick("Note", "Nota", "Remarque", "Nota", "Hinweis") }
    var summary: String { pick("Summary", "Riepilogo", "Récapitulatif", "Resumen", "Übersicht") }
    var noEntries: String {
        pick("No entries in this period.", "Nessuna voce in questo periodo.", "Aucune entrée sur cette période.",
             "No hay entradas en este periodo.", "Keine Einträge in diesem Zeitraum.")
    }

    func title(_ header: ReportHeader) -> String {
        let custom = header.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return custom.isEmpty ? defaultTitle : custom
    }

    func generated(_ date: Date) -> String {
        let text = formatGeneratedDate(date)
        let template = pick("Generated on {date}", "Generato il {date}", "Généré le {date}", "Generado el {date}",
                            "Erstellt am {date}")
        return template.replacingOccurrences(of: "{date}", with: text)
    }

    func pageLabel(page: Int, count: Int) -> String {
        let template = pick("Page {page} of {count}", "Pagina {page} di {count}", "Page {page} sur {count}",
                            "Página {page} de {count}", "Seite {page} von {count}")
        return template.replacingOccurrences(of: "{page}", with: String(page))
            .replacingOccurrences(of: "{count}", with: String(count))
    }

    // MARK: Sections and lines

    var sectionWork: String { pick("Work", "Lavoro", "Travail", "Trabajo", "Arbeit") }
    /// The document is read by the client, so the person's section has a neutral title, never "Your time".
    var sectionYou: String {
        pick("Work hours", "Ore di lavoro", "Heures de travail", "Horas de trabajo", "Arbeitsstunden")
    }
    var sectionAgents: String { pick("AI agents", "Agenti IA", "Agents IA", "Agentes de IA", "KI-Agenten") }
    var sectionExpenses: String { pick("Expenses", "Spese", "Dépenses", "Gastos", "Ausgaben") }
    /// The neutral label for the person when no name is set.
    var consultant: String { pick("Consultant", "Consulente", "Consultant", "Consultor", "Berater") }
    /// Who did the person's work, as the client reads it: the name, or "Consultant".
    var person: String { personName.isEmpty ? consultant : personName }
    var agents: String { sectionAgents }
    var noTask: String { pick("No task", "Nessuna attività", "Sans tâche", "Sin tarea", "Ohne Aufgabe") }
    var noDescription: String {
        pick("No description", "Nessuna descrizione", "Sans description", "Sin descripción", "Ohne Beschreibung")
    }
    /// An agent entry with nothing to describe it (no task, only a generic branch).
    var agentSession: String {
        pick("Agent session", "Sessione dell’agente", "Session de l’agent", "Sesión del agente", "Agentensitzung")
    }
    var subtotal: String { pick("Subtotal", "Subtotale", "Sous-total", "Subtotal", "Zwischensumme") }
    var total: String { pick("Total", "Totale", "Total", "Total", "Gesamt") }

    /// A section table's total when it is not the document's total (a cap, expenses or other sections apply).
    func sectionTotal(_ kind: ReportSectionKind) -> String {
        switch kind {
        case .work: return pick("Total work", "Totale lavoro", "Total travail", "Total trabajo", "Summe Arbeit")
        case .you:
            return pick("Total work hours", "Totale ore di lavoro", "Total heures de travail",
                        "Total horas de trabajo", "Summe Arbeitsstunden")
        case .agents:
            return pick("Total AI agents", "Totale agenti IA", "Total agents IA", "Total agentes de IA",
                        "Summe KI-Agenten")
        case .expenses: return pick("Total expenses", "Totale spese", "Total dépenses", "Total gastos", "Summe Ausgaben")
        }
    }

    /// A group title repeated at the top of a new page.
    func continued(_ title: String) -> String {
        let suffix = pick("(continued)", "(continua)", "(suite)", "(continuación)", "(Fortsetzung)")
        return "\(title) \(suffix)"
    }

    func sectionTitle(_ kind: ReportSectionKind) -> String {
        switch kind {
        case .work: return sectionWork
        case .you: return sectionYou
        case .agents: return sectionAgents
        case .expenses: return sectionExpenses
        }
    }

    // MARK: Columns

    var columnDate: String { pick("Date", "Data", "Date", "Fecha", "Datum") }
    var columnTime: String { pick("Time", "Orario", "Horaire", "Horario", "Uhrzeit") }
    var columnStart: String { pick("Start", "Inizio", "Début", "Inicio", "Beginn") }
    var columnEnd: String { pick("End", "Fine", "Fin", "Fin", "Ende") }
    var columnDescription: String { pick("Description", "Descrizione", "Description", "Descripción", "Beschreibung") }
    var columnWho: String { pick("Who", "Chi", "Qui", "Quién", "Wer") }
    var columnModels: String { pick("Models", "Modelli", "Modèles", "Modelos", "Modelle") }
    var columnTokens: String { pick("Tokens", "Token", "Tokens", "Tokens", "Tokens") }
    var columnAPIValue: String { pick("API value (USD)", "Valore API (USD)", "Valeur API (USD)", "Valor API (USD)", "API-Wert (USD)") }
    var columnHours: String { pick("Hours", "Ore", "Heures", "Horas", "Stunden") }
    var columnRate: String { pick("Rate", "Tariffa", "Taux", "Tarifa", "Satz") }
    /// The time part of a hybrid amount (hours × rate).
    var columnTimeAmount: String { pick("Time", "Tempo", "Temps", "Tiempo", "Zeit") }
    /// The usage part of a hybrid amount (API value × markup).
    var columnUsageAmount: String { pick("Usage", "Utilizzo", "Usage", "Uso", "Nutzung") }
    /// The CSV names the parts in full, since there they sit beside Hours with no table around them.
    var csvTimeAmount: String {
        pick("Time amount", "Importo tempo", "Montant temps", "Importe tiempo", "Betrag Zeit")
    }
    var csvUsageAmount: String {
        pick("Usage amount", "Importo utilizzo", "Montant usage", "Importe uso", "Betrag Nutzung")
    }
    var columnAmount: String { pick("Amount", "Importo", "Montant", "Importe", "Betrag") }
    var columnSection: String { pick("Section", "Sezione", "Section", "Sección", "Abschnitt") }
    var columnGroup: String { pick("Group", "Gruppo", "Groupe", "Grupo", "Gruppe") }
    var columnCurrency: String { pick("Currency", "Valuta", "Devise", "Moneda", "Währung") }

    func columnTitle(_ column: ReportColumn) -> String {
        switch column {
        case .date: return columnDate
        case .timeRange: return columnTime
        case .description: return columnDescription
        case .who: return columnWho
        case .model: return columnModels
        case .tokens: return columnTokens
        case .aiCost: return columnAPIValue
        case .hours: return columnHours
        case .rate: return columnRate
        case .timeAmount: return columnTimeAmount
        case .usageAmount: return columnUsageAmount
        case .amount: return columnAmount
        }
    }

    // MARK: Summary and warnings

    var summaryTokens: String { pick("Tokens used", "Token utilizzati", "Tokens utilisés", "Tokens utilizados", "Verwendete Tokens") }
    var monthlyCap: String {
        pick("Monthly cap on agents", "Tetto mensile sugli agenti", "Plafond mensuel des agents",
             "Límite mensual de agentes", "Monatliche Obergrenze für Agenten")
    }

    /// `singleClient`: the report is for one client, so a cap line does not repeat the client's name.
    func summaryLabel(_ item: ReportSummaryItem, singleClient: Bool = false) -> String {
        switch item {
        case .you: return person
        case .agents: return sectionAgents
        case .tokens: return summaryTokens
        case .aiCost: return columnAPIValue
        case .capAdjustment(let client, let cap, _):
            return capLabel(client: singleClient ? "" : client, monthlyCap: cap)
        case .expenses: return sectionExpenses
        case .total: return total
        }
    }

    /// "Monthly cap on agents (€400.00)", or "Monthly cap on agents (Acme, €400.00)" with a client name.
    func capLabel(client: String, monthlyCap cap: Decimal?) -> String {
        var details: [String] = []
        if !client.isEmpty { details.append(client) }
        if let cap { details.append(formatMoney(cap)) }
        return details.isEmpty ? monthlyCap : "\(monthlyCap) (\(details.joined(separator: ", ")))"
    }

    func warning(_ warning: ReportWarning) -> String {
        switch warning {
        case .missingHumanRate:
            return pick("Some work hours have no hourly rate, so they are not priced.",
                        "Alcune ore di lavoro non hanno una tariffa oraria, quindi non sono valorizzate.",
                        "Certaines heures de travail n’ont pas de taux horaire et ne sont donc pas valorisées.",
                        "Algunas horas de trabajo no tienen tarifa por hora, así que no tienen importe.",
                        "Für einige Arbeitsstunden ist kein Stundensatz festgelegt, daher sind sie nicht berechnet.")
        case .needsExchangeRate:
            return pick("Agent usage is not priced because no USD exchange rate is set.",
                        "L’uso degli agenti non è valorizzato perché manca il tasso di cambio del dollaro.",
                        "L’utilisation des agents n’est pas valorisée, car aucun taux de change USD n’est défini.",
                        "El uso de los agentes no tiene importe porque no hay un tipo de cambio del dólar definido.",
                        "Die Agentennutzung ist nicht berechnet, da kein USD-Wechselkurs festgelegt ist.")
        case .tokensWithoutPrice(let count):
            let template = pick("{count} tokens have no API price and are not included in the API value.",
                                "{count} token non hanno un prezzo API e sono esclusi dal valore API.",
                                "{count} tokens n’ont pas de prix API et ne sont pas inclus dans la valeur API.",
                                "{count} tokens no tienen precio de API y no se incluyen en el valor de API.",
                                "{count} Tokens haben keinen API-Preis und sind im API-Wert nicht enthalten.")
            return template.replacingOccurrences(of: "{count}", with: formatTokens(count))
        }
    }

    // MARK: Labels

    func whoText(_ who: ReportWhoValue) -> String {
        var parts: [String] = []
        if who.you { parts.append(person) }
        parts.append(contentsOf: who.agents)
        return parts.isEmpty ? agents : parts.joined(separator: ", ")
    }

    /// A line's main text and, when it has one, the context printed under it (project and task).
    func text(_ label: ReportLabel) -> (primary: String, secondary: String?) {
        switch label {
        case .project(let name):
            return (name, nil)
        case .task(let project, let task):
            return (task ?? noTask, project)
        case .day(let day):
            return (formatDay(day), nil)
        case .who(let who):
            return (whoText(who), nil)
        case .agentSession(let project, let task):
            if let task { return (task, project) }
            return (agentSession, project)
        case .entry(let description, let project, let task):
            let trimmed = description.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                if let task { return (task, project) }
                return (noDescription, project)
            }
            // A description that is the task already says it; repeating it underneath is noise.
            let shownTask = task == trimmed ? nil : task
            let context = [project, shownTask].compactMap { $0 }.joined(separator: " · ")
            return (trimmed, context.isEmpty ? nil : context)
        case .subtotal:
            return (subtotal, nil)
        case .total:
            return (total, nil)
        }
    }

    /// A label on one line: "Project · Task", or "Description (Project · Task)".
    func singleLine(_ label: ReportLabel) -> String {
        let parts = text(label)
        guard let secondary = parts.secondary else { return parts.primary }
        switch label {
        case .task:
            return "\(secondary) · \(parts.primary)"
        default:
            return "\(parts.primary) (\(secondary))"
        }
    }

    // MARK: Formatting

    func formatMoney(_ value: Decimal) -> String {
        Decimal.FormatStyle.Currency(code: currency, locale: locale).format(value)
    }

    func formatUSD(_ value: Decimal) -> String {
        Decimal.FormatStyle.Currency(code: "USD", locale: locale).format(value)
    }

    /// "1.50" (with the language's decimal separator) or "1h 30m".
    func formatHours(_ millis: Int, style: ReportHoursFormat) -> String {
        switch style {
        case .decimal:
            let hours = ReportNumber.hours(millis: millis)
            return Decimal.FormatStyle(locale: locale).precision(.fractionLength(2)).format(hours)
        case .clock:
            return formatClock(minutes: (max(0, millis) + 30_000) / 60_000)
        }
    }

    /// Whole minutes as "1h 30m".
    func formatClock(minutes: Int) -> String {
        let value = max(0, minutes)
        return "\(value / 60)h " + String(format: "%02ldm", value % 60)
    }

    /// Hours where no column header says what the number is: "1.50 h" or "1h 30m".
    func formatHoursWithUnit(_ millis: Int, style: ReportHoursFormat) -> String {
        style == .decimal ? formatHours(millis, style: style) + " h" : formatHours(millis, style: style)
    }

    /// Hours already reconciled by the builder: "1.50" or "1h 30m".
    func formatShown(_ shown: ReportShownHours, style: ReportHoursFormat) -> String {
        switch style {
        case .decimal:
            return Decimal.FormatStyle(locale: locale).precision(.fractionLength(2)).format(shown.hours)
        case .clock:
            return formatClock(minutes: shown.minutes)
        }
    }

    func formatShownWithUnit(_ shown: ReportShownHours, style: ReportHoursFormat) -> String {
        style == .decimal ? formatShown(shown, style: style) + " h" : formatShown(shown, style: style)
    }

    /// A table line's hours as printed: its reconciled value, or a dash when it has no time at all.
    func formatLineHours(_ line: ReportLine, style: ReportHoursFormat) -> String {
        guard let hours = line.displayHours, let minutes = line.displayMinutes else { return "—" }
        return formatShown(ReportShownHours(hours: hours, minutes: minutes), style: style)
    }

    private func dateStyle(timeZone zone: TimeZone) -> Date.FormatStyle {
        var style = Date.FormatStyle()
        style.locale = locale
        style.calendar = Calendar(identifier: .gregorian)
        style.timeZone = zone
        return style
    }

    private var utc: TimeZone { TimeZone(secondsFromGMT: 0) ?? TimeZone.current }

    /// A calendar day ("yyyy-MM-dd") as a medium localized date, such as "Nov 3, 2026" or "3 nov 2026".
    func formatDate(_ day: String) -> String {
        guard let date = ReportCalendar.date(day) else { return day }
        return dateStyle(timeZone: utc).day().month(.abbreviated).year().format(date)
    }

    /// A calendar day with its weekday, such as "Mon, Nov 3, 2026".
    func formatDay(_ day: String) -> String {
        guard let date = ReportCalendar.date(day) else { return day }
        return dateStyle(timeZone: utc).weekday(.abbreviated).day().month(.abbreviated).year().format(date)
    }

    func formatPeriod(start: String, end: String) -> String {
        start == end ? formatDate(start) : "\(formatDate(start)) – \(formatDate(end))"
    }

    func formatGeneratedDate(_ date: Date) -> String {
        dateStyle(timeZone: timeZone).day().month(.abbreviated).year().format(date)
    }

    /// "HH:mm" in the ledger time zone.
    func formatTime(_ millis: Int) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let date = Date(timeIntervalSince1970: Double(millis) / 1000)
        let components = calendar.dateComponents([.hour, .minute], from: date)
        return String(format: "%02ld:%02ld", components.hour ?? 0, components.minute ?? 0)
    }

    /// "09:00–10:30", or "" without a start.
    func formatTimeRange(start: Int?, end: Int?) -> String {
        guard let start else { return "" }
        guard let end else { return formatTime(start) }
        return "\(formatTime(start))–\(formatTime(end))"
    }

    /// Grouped digits, such as "1,234,567" or "1.234.567".
    func formatTokens(_ count: Int) -> String {
        IntegerFormatStyle<Int>(locale: locale).format(count)
    }

    /// Short counts for tight columns with three significant digits, such as "3.96B", "337M", "7.10M" and
    /// "659K" (or "3,96 Mld" in Italian). Counts under a thousand stay whole.
    func formatCompactTokens(_ count: Int) -> String {
        if abs(count) < 1000 { return formatTokens(count) }
        let style: IntegerFormatStyle<Int> = IntegerFormatStyle<Int>(locale: locale)
            .notation(.compactName)
            .precision(.significantDigits(3...3))
        return style.format(count)
    }
}
