import Foundation

struct CalendarDayInfo: Equatable, Sendable {
    var lunar: String
    var lunarDay: String
    var zodiac: String
    var festival: String?
    var solarTerm: String?
    var week: Int
    var ordinal: Int

    init(_ date: Date, dates: CalendarDates = .init()) {
        var chinese = Calendar(identifier: .chinese)
        chinese.timeZone = dates.calendar.timeZone
        let parts = chinese.dateComponents([.year, .month, .day], from: date)
        let month = parts.month ?? 1, day = parts.day ?? 1, year = (parts.year ?? 1) - 1
        let months = ["正月", "二月", "三月", "四月", "五月", "六月", "七月", "八月", "九月", "十月", "冬月", "腊月"]
        let tens = ["初", "十", "廿", "三"], digits = ["一", "二", "三", "四", "五", "六", "七", "八", "九", "十"]
        let dayName = day == 10 ? "初十" : day == 20 ? "二十" : day == 30 ? "三十"
            : tens[(day - 1) / 10] + digits[(day - 1) % 10]
        let monthName = (parts.isLeapMonth == true ? "闰" : "") + months[max(0, min(11, month - 1))]
        lunar = monthName + dayName
        lunarDay = day == 1 ? monthName : dayName
        let stems = Array("甲乙丙丁戊己庚辛壬癸"), branches = Array("子丑寅卯辰巳午未申酉戌亥"), animals = Array("鼠牛虎兔龙蛇马羊猴鸡狗猪")
        zodiac = "\(stems[year % 10])\(branches[year % 12])年 · \(animals[year % 12])年"
        let solar = dates.calendar.dateComponents([.year, .month, .day, .weekday, .weekdayOrdinal], from: date)
        let gregorian: [String: String] = ["1-1": "元旦", "2-14": "情人节", "3-8": "妇女节", "5-1": "劳动节",
                                           "5-4": "青年节", "6-1": "儿童节", "9-10": "教师节", "10-1": "国庆节",
                                           "12-24": "平安夜", "12-25": "圣诞节"]
        let lunisolar: [String: String] = ["1-1": "春节", "1-15": "元宵节", "2-2": "龙抬头", "5-5": "端午节",
                                           "7-7": "七夕", "7-15": "中元节", "8-15": "中秋节", "9-9": "重阳节",
                                           "12-8": "腊八节", "12-23": "小年"]
        let tomorrow = chinese.dateComponents([.month, .day], from: dates.adding(1, to: date))
        festival = gregorian["\(solar.month ?? 0)-\(solar.day ?? 0)"]
            ?? (parts.isLeapMonth == true ? nil : lunisolar["\(month)-\(day)"])
        if tomorrow.month == 1, tomorrow.day == 1, tomorrow.isLeapMonth != true {
            festival = "除夕"
        }
        if solar.weekday == 1, solar.month == 5, solar.weekdayOrdinal == 2 {
            festival = "母亲节"
        }
        if solar.weekday == 1, solar.month == 6, solar.weekdayOrdinal == 3 {
            festival = "父亲节"
        }
        solarTerm = SolarTerms.term(on: date, dates: dates)
        var iso = Calendar(identifier: .iso8601)
        iso.timeZone = dates.calendar.timeZone
        week = iso.component(.weekOfYear, from: date)
        ordinal = dates.calendar.ordinality(of: .day, in: .year, for: date) ?? 1
    }
}

/// Approximate apparent solar longitude, solved for each 15-degree crossing.
/// Dates are civil dates in China; this does not imply an exact astronomical time.
enum SolarTerms {
    static let names = ["小寒", "大寒", "立春", "雨水", "惊蛰", "春分", "清明", "谷雨", "立夏", "小满", "芒种", "夏至",
                        "小暑", "大暑", "立秋", "处暑", "白露", "秋分", "寒露", "霜降", "立冬", "小雪", "大雪", "冬至"]

    static func date(year: Int, index: Int, dates: CalendarDates = .init()) -> Date? {
        guard names.indices.contains(index), let approximate = dates.date(year, index / 2 + 1, index % 2 == 0 ? 6 : 21)
        else { return nil }
        let target = Double((285 + index * 15) % 360)
        var instant = approximate
        for _ in 0 ..< 6 {
            let difference = (longitude(instant) - target + 540).truncatingRemainder(dividingBy: 360) - 180
            instant = instant.addingTimeInterval(-difference / 0.98564736 * 86400)
        }
        var china = Calendar(identifier: .gregorian)
        china.timeZone = TimeZone(secondsFromGMT: 8 * 3600)!
        let civil = china.dateComponents([.year, .month, .day], from: instant)
        return dates.date(civil.year ?? year, civil.month ?? 1, civil.day ?? 1)
    }

    static func term(on day: Date, dates: CalendarDates) -> String? {
        let year = dates.calendar.component(.year, from: day), month = dates.calendar.component(.month, from: day)
        return ((month - 1) * 2 ... (month - 1) * 2 + 1).first {
            date(year: year, index: $0, dates: dates).map { dates.calendar.isDate($0, inSameDayAs: day) } ?? false
        }.map { names[$0] }
    }

    private static func longitude(_ date: Date) -> Double {
        let julian = date.timeIntervalSince1970 / 86400 + 2_440_587.5
        let century = (julian - 2_451_545) / 36525
        let mean = 280.46646 + century * (36000.76983 + 0.0003032 * century)
        let anomaly = (357.52911 + century * (35999.05029 - 0.0001537 * century)) * .pi / 180
        let center = sin(anomaly) * (1.914602 - century * (0.004817 + 0.000014 * century))
            + sin(2 * anomaly) * (0.019993 - 0.000101 * century) + sin(3 * anomaly) * 0.000289
        let omega = (125.04 - 1934.136 * century) * .pi / 180
        let value = (mean + center - 0.00569 - 0.00478 * sin(omega)).truncatingRemainder(dividingBy: 360)
        return (value + 360).truncatingRemainder(dividingBy: 360)
    }
}
