import Foundation

var failed = 0
func check(_ ok: Bool, _ name: String) {
    if ok { print("ok   \(name)") } else { print("FAIL \(name)"); failed += 1 }
}

// Контент следует за мышью: мышь вниз/вправо -> положительные дельты
check(DragMath.scroll(dx: 5, dy: 10, inverted: false) == ScrollDelta(x: 5, y: 10), "natural")
// Инверсия: контент движется против мыши
check(DragMath.scroll(dx: 5, dy: -10, inverted: true) == ScrollDelta(x: -5, y: 10), "inverted")
// Скорость
check(DragMath.scroll(dx: 4, dy: 4, inverted: false, speed: 2.5) == ScrollDelta(x: 10, y: 10), "speed")
// Ноль остаётся нулём
check(DragMath.scroll(dx: 0, dy: 0, inverted: true) == ScrollDelta(x: 0, y: 0), "zero")
// Клик или перетаскивание
check(DragMath.isClick(totalDx: 1, totalDy: -2), "small move is click")
check(!DragMath.isClick(totalDx: 3, totalDy: 4), "5px move is drag")

// Плавное перемещение курсора: старт, финиш, замедление к концу
let a = CGPoint(x: 0, y: 0), b = CGPoint(x: 100, y: 200)
check(CursorPath.point(from: a, to: b, t: 0) == a, "path start")
check(CursorPath.point(from: a, to: b, t: 1) == b, "path end")
check(CursorPath.point(from: a, to: b, t: 2) == b, "path clamps t>1")
check(CursorPath.point(from: a, to: b, t: 0.5).x > 50, "ease-out is past midpoint at t=0.5")
check(CursorPath.duration(distance: 0) == 0.15, "min duration")
check(CursorPath.duration(distance: 100000) == 0.7, "max duration")

// Малая скорость не теряет движение: остаток копится
var rest = (x: 0.0, y: 0.0)
var sumY: Int32 = 0
for _ in 0..<10 { sumY += DragMath.scroll(dx: 0, dy: 1, inverted: false, speed: 0.25, rest: &rest).y }
check(sumY == 2, "slow speed accumulates remainder (10 * 0.25 -> 2)")

// Клавиша ускорения удваивает скорость только пока нажата
check(DragMath.boosted(speed: 1.5, active: true, factor: 2) == 3.0, "boost x2")
check(DragMath.boosted(speed: 1.5, active: true, factor: 4) == 6.0, "boost x4")
check(DragMath.boosted(speed: 1.5, active: false, factor: 4) == 1.5, "no boost when key up")

if failed > 0 { print("\(failed) failed"); exit(1) }
print("all passed")
