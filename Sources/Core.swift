import Foundation
import CoreGraphics

struct ScrollDelta: Equatable {
    var x: Int32
    var y: Int32
}

enum DragMath {
    /// Дельта прокрутки в пикселях по сдвигу мыши.
    /// Обычный режим: контент следует за мышью (как «рука»). Инверсия: против мыши.
    static func scroll(dx: Int, dy: Int, inverted: Bool, speed: Double = 1) -> ScrollDelta {
        let sign: Double = inverted ? -1 : 1
        return ScrollDelta(x: Int32((Double(dx) * speed * sign).rounded()),
                           y: Int32((Double(dy) * speed * sign).rounded()))
    }

    /// То же, но дробный остаток копится в `rest`, чтобы при малой скорости движение не терялось.
    static func scroll(dx: Int, dy: Int, inverted: Bool, speed: Double,
                       rest: inout (x: Double, y: Double)) -> ScrollDelta {
        let sign: Double = inverted ? -1 : 1
        let fx = Double(dx) * speed * sign + rest.x
        let fy = Double(dy) * speed * sign + rest.y
        let ix = fx.rounded(.towardZero), iy = fy.rounded(.towardZero)
        rest = (fx - ix, fy - iy)
        return ScrollDelta(x: Int32(ix), y: Int32(iy))
    }

    /// Скорость с учётом клавиши ускорения (умножается на `factor`, пока клавиша нажата).
    static func boosted(speed: Double, active: Bool, factor: Double) -> Double { active ? speed * factor : speed }

    /// Сдвиг меньше порога считаем обычным правым кликом.
    static func isClick(totalDx: Int, totalDy: Int, threshold: Double = 4) -> Bool {
        (Double(totalDx * totalDx + totalDy * totalDy)).squareRoot() < threshold
    }
}

enum CursorPath {
    /// Точка на пути курсора, t от 0 до 1; ease-out (быстро в начале, мягко в конце).
    static func point(from a: CGPoint, to b: CGPoint, t: Double) -> CGPoint {
        let c = min(max(t, 0), 1)
        let e = 1 - pow(1 - c, 3)
        return CGPoint(x: a.x + (b.x - a.x) * e, y: a.y + (b.y - a.y) * e)
    }

    /// Чем дальше, тем дольше, но не меньше 0.15 с и не больше 0.7 с.
    static func duration(distance: Double) -> Double {
        min(max(0.15 + distance / 2500, 0.15), 0.7)
    }
}
