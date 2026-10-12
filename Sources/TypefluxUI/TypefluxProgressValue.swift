import Foundation

struct TypefluxProgressValue {
    let value: Double?
    let total: Double

    init(value: Double?, total: Double) {
        let safeTotal = total.isFinite && total > 0 ? total : 1
        self.total = safeTotal
        self.value = value.map { $0.isNaN ? 0 : min(safeTotal, max(0, $0)) }
    }
}
