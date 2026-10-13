import SwiftUI

extension SystemMonitorMemoryPressure {
    var color: Color { level.color ?? TypefluxColor.success.color }
}
