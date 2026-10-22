import Foundation

extension WorldClockLauncherModel {
    /// What Return does now, for the launcher's header and footer.
    var primaryTitle: String {
        switch query {
        case .search:
            guard let city = chosenCity else { return L("worldclock.action.copy") }
            return listContains(city) ? L("worldclock.action.copy") : L("worldclock.action.add")
        case .convert: return L("worldclock.action.copyResult")
        case .meeting: return L("worldclock.action.copyTimes")
        default: return L("worldclock.action.copy")
        }
    }

    var primaryEnabled: Bool {
        switch query {
        case .unknown: false
        case .search: chosenCity != nil
        case .meeting: chosenMeeting != nil
        default: true
        }
    }

    // One case per key keeps the world clock's key map readable in one place.
    // swiftlint:disable:next cyclomatic_complexity
    func handle(_ key: AskCommandKey, inputEmpty: Bool) -> WorldClockEffect {
        switch key {
        case .commandEnter, .tab, .shiftTab:
            if case .meeting = query, key != .commandEnter {
                cycleSuggestion(key == .tab ? 1 : -1)
            }
            return .handled
        case .escape:
            if !inputEmpty { return .clearInput }
            if pinned != nil { returnToNow(); return .handled }
            return .unhandled
        case .commandT:
            returnToNow()
            return inputEmpty ? .handled : .clearInput
        case .up, .down:
            guard query == .list || !searchResults.isEmpty else { return .handled }
            select(selection + (key == .up ? -1 : 1))
            return .handled
        case .left, .right:
            guard inputEmpty, query == .list else { return .unhandled }
            step(key == .left ? -1 : 1)
            return .handled
        case .commandLeft, .commandRight:
            guard query == .list else { return .unhandled }
            moveDays(key == .commandLeft ? -1 : 1)
            return .handled
        case .optionLeft, .optionRight:
            guard case .meeting = query, chosenMeeting != nil else { return .unhandled }
            nudgeMeeting(key == .optionLeft ? -1 : 1)
            return .handled
        case .optionUp, .optionDown:
            guard query == .list else { return .unhandled }
            return move(by: key == .optionUp ? -1 : 1)
        case .enter:
            if case .search = query, let city = chosenCity, !listContains(city) { return add(city) }
            return primaryEnabled ? copyText.map(WorldClockEffect.copy) ?? .handled : .handled
        case .commandC:
            if case let .timestamp(date, _) = query {
                return .copy(WorldClockFormat.iso(date, in: TimeZone(identifier: "UTC") ?? .gmt))
            }
            return copyText.map(WorldClockEffect.copy) ?? .handled
        case .optionEnter:
            return copyText.map(WorldClockEffect.insert) ?? .handled
        case .commandDelete:
            guard query == .list else { return .unhandled }
            return removeChosen()
        case .commandZ:
            return undoRemoval()
        default:
            return .unhandled
        }
    }

    /// What Return copies and ⌥Return inserts for the current query.
    var copyText: String? {
        let presenter = presenter
        switch query {
        case .list, .search:
            guard let city = chosenCity else { return nil }
            return presenter.line(city, at: query == .list ? moment : now)
        case let .convert(conversion):
            let source = presenter.line(conversion.source ?? localCity, at: conversion.date, format: .full)
            guard let target = conversion.target else { return source }
            return source + " = " + presenter.line(target, at: conversion.date, format: .full)
        case let .meeting(cities):
            guard let slot = chosenMeeting else { return nil }
            let times = cities.map { city in
                let weekday = WorldClockFormat.weekday(slot.start, in: city.timeZone, locale: locale)
                let zone = preferences.meetingAbbreviations
                    ? " " + WorldClockAbbreviations.abbreviation(city.timeZone, at: slot.start) : ""
                return "\(city.name(in: language)) \(weekday) \(presenter.time(slot.start, in: city.timeZone))\(zone)"
            }
            return L("worldclock.meeting.copy", times.joined(separator: " / "))
        case let .timestamp(date, _):
            return presenter.line(localCity, at: date, format: .full)
        case .unknown:
            return nil
        }
    }

    func listContains(_ city: WorldClockCity) -> Bool {
        city.id == localCity.id || preferences.cityIDs.contains(city.id)
    }

    // MARK: - Changing the list

    func add(_ city: WorldClockCity) -> WorldClockEffect {
        guard !listContains(city) else { return .handled }
        var next = preferences
        next.cityIDs.append(city.id)
        replacePreferences(next, showingList: true)
        select(listCities.count - 1)
        return .save(next, clearInput: true, message: L("worldclock.added", city.name(in: language)))
    }

    func removeChosen() -> WorldClockEffect {
        guard query == .list, selection > 0, let city = chosenCity,
              let index = preferences.cityIDs.firstIndex(of: city.id) else { return .handled }
        var next = preferences
        next.cityIDs.remove(at: index)
        let label = next.labels.removeValue(forKey: city.id)
        replacePreferences(next, removed: Removed(id: city.id, index: index, label: label))
        return .save(next, clearInput: false, message: L("worldclock.removed", city.name(in: language)))
    }

    func undoRemoval() -> WorldClockEffect {
        guard let removed, query == .list, !preferences.cityIDs.contains(removed.id) else { return .unhandled }
        var next = preferences
        next.cityIDs.insert(removed.id, at: min(removed.index, next.cityIDs.count))
        if let label = removed.label { next.labels[removed.id] = label }
        replacePreferences(next)
        select(min(removed.index, next.cityIDs.count - 1) + 1)
        let name = directory.city(id: removed.id)?.name(in: language) ?? removed.id
        return .save(next, clearInput: false, message: L("worldclock.restored", name))
    }

    /// ⌥↑↓: the local row stays first.
    func move(by step: Int) -> WorldClockEffect {
        let ids = cities.filter { $0.id != localCity.id }.map(\.id)
        let from = selection - 1, target = from + step
        guard ids.indices.contains(from), ids.indices.contains(target) else { return .handled }
        var next = preferences
        var order = ids
        order.swapAt(from, target)
        next.cityIDs = order + preferences.cityIDs.filter { !order.contains($0) }
        replacePreferences(next)
        select(target + 1)
        return .save(next, clearInput: false, message: "")
    }

    private func cycleSuggestion(_ step: Int) {
        guard let count = meeting?.suggestions.count, count > 0 else { return }
        chooseSuggestion((suggestion + step + count) % count)
    }
}
