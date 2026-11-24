// Snow.swift — снег на экране Mac, который копится на окнах и сметается курсором.
//
// Сборка приложения: bash build.sh  (нужны Command Line Tools: xcode-select --install)
// Быстрый запуск без сборки .app: swiftc -O main.swift Extras.swift -o Snow && ./Snow
//
// Управление — значок ❄︎ в строке меню: сила снега, ветер, размер снежинок,
// пауза, убрать снег, запуск при входе, выход.
//
// Игра: наведи курсор на снег (появится колечко), зажми кнопку мыши — получится снежок. Катай его по снегу,
// чтобы рос; отпусти с размахом — полетит; положи ком на ком — будет снеговик.

import Cocoa
import ServiceManagement
import SpriteKit
import Carbon.HIToolbox

// MARK: - Настройки

enum Cfg {
    static let spawnPerSec: CGFloat = 110        // сколько снежинок в секунду
    static let maxFalling = 1600                 // предел обычных снежинок
    static let maxTotal = 4500                   // предел вместе со сметённым снегом
    static let cell: CGFloat = 3                 // ширина "столбика" сугроба, px
    static let maxPileOnWindow: CGFloat = 32     // макс. высота сугроба на окне
    static let maxPileOnFloor: CGFloat = 56      // макс. высота сугроба внизу экрана
    static let edgeRamp: CGFloat = 18            // скругление сугроба у краёв окна
    // радиус скругления углов окон: в macOS 26 он заметно больше
    static let cornerRadius: CGFloat =
        ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 26 ? 24 : 11
    static let sweepRadius: CGFloat = 36         // радиус "метлы" вокруг курсора
    static let sweepMinSpeed: CGFloat = 450      // с какой скорости курсора снег сметается, px/с
    static let pushRadius: CGFloat = 46          // радиус, в котором курсор раздвигает снежинки
    static let windowPoll: Double = 0.1          // как часто опрашивать положение окон, с
    static let shakeThreshold: CGFloat = 45      // сдвиг окна за опрос, после которого снег слетает
    static let maxBall: CGFloat = 70             // макс. радиус снежного кома
    static let ballGravity: CGFloat = 1500
    static let splatSpeed: CGFloat = 950         // с такой скорости снежок разбивается при ударе
}

// MARK: - Модель

@inline(__always) func rnd(_ a: CGFloat, _ b: CGFloat) -> CGFloat { CGFloat.random(in: a..<max(b, a + 0.0001)) }

struct Flake {
    var x: CGFloat, y: CGFloat
    var vx: CGFloat = 0, vy: CGFloat = 0
    var r: CGFloat
    var phase: CGFloat
    var freq: CGFloat
    var mass: CGFloat          // сколько "высоты" добавит при приземлении
    var loose: Bool            // сметённый/сброшенный снег: летит по баллистике
    var kind: Int = 0          // 0 — точка, 1…4 — кристалл, 5–7 листья, 8 лепесток, 9 капля
    var mat: UInt8 = 0         // снег / дождь / лист / лепесток (см. Mat)
}

final class Surface {
    let id: Int
    let isFloor: Bool
    var rect: CGRect           // координаты Quartz (y вниз)
    var heights: [CGFloat]
    var covered: [Bool]
    var baseOff: [CGFloat] = []    // насколько опускается кромка окна на скруглённых углах
    var icicles: [Icicle] = []
    var capMul: [CGFloat] = []     // предел высоты по столбикам: и углы, и лёгкие волны
    private let p1 = rnd(0, 6.28), p2 = rnd(0, 6.28), p3 = rnd(0, 6.28)

    init(id: Int, rect: CGRect, isFloor: Bool) {
        self.id = id
        self.rect = rect
        self.isFloor = isFloor
        let n = max(1, Int(rect.width / Cfg.cell))
        heights = Array(repeating: 0, count: n)
        covered = Array(repeating: false, count: n)
        rebuildShape()
    }

    func rebuildShape() {
        let n = heights.count
        let R = Cfg.cornerRadius
        baseOff = (0..<n).map { i in
            if isFloor { return 0 }
            let d = CGFloat(min(i, n - 1 - i)) * Cfg.cell + Cfg.cell / 2   // расстояние до края
            guard d < R else { return 0 }
            let t = R - d
            return R - sqrt(max(0, R * R - t * t))
        }
        capMul = (0..<n).map { i in
            let x = CGFloat(i) * Cfg.cell
            let wave = 0.78 + 0.15 * sin(x / 53 + p1) + 0.09 * sin(x / 19 + p2) + 0.04 * sin(x / 8 + p3)
            if isFloor { return wave }
            // на крутой части угла снег не держится, дальше плавно набирает высоту
            let d = CGFloat(min(i, n - 1 - i)) * Cfg.cell + Cfg.cell / 2
            var f = (d - R * 0.4) / (R * 0.9 + Cfg.edgeRamp * 0.5)
            f = min(1, max(0, f))
            return wave * f * f * (3 - 2 * f)
        }
    }

    /// Нижняя кромка снега в столбике (верх окна с учётом скругления).
    func baseY(_ i: Int) -> CGFloat { top + baseOff[i] }
    /// Поверхность снега в столбике.
    func surfY(_ i: Int) -> CGFloat { top + baseOff[i] - heights[i] }

    /// Линия, на которой лежит снег: верх окна или низ экрана.
    var top: CGFloat { isFloor ? rect.maxY : rect.minY }
    var cap: CGFloat { isFloor ? Cfg.maxPileOnFloor : Cfg.maxPileOnWindow }

    func col(_ x: CGFloat) -> Int? {
        let i = Int(floor((x - rect.minX) / Cfg.cell))
        return (i >= 0 && i < heights.count) ? i : nil
    }

    func colX(_ i: Int) -> CGFloat { rect.minX + (CGFloat(i) + 0.5) * Cfg.cell }

    func capAt(_ i: Int) -> CGFloat { cap * capMul[i] }

    func add(_ i: Int, _ m: CGFloat) {
        guard i >= 0 && i < heights.count else { return }
        let c = capAt(i)
        guard c > 0.01 else { return }
        let fill = heights[i] / c
        // ближе к пределу снег держится всё хуже — верх остаётся неровным, а не срезанным
        let stick = max(0, 1 - fill * fill * fill * fill) * rnd(0.6, 1.4)
        heights[i] = min(c, heights[i] + m * stick)
    }

    func resize(to newRect: CGRect) {
        let n = max(1, Int(newRect.width / Cfg.cell))
        if n != heights.count {
            let old = heights
            heights = (0..<n).map { j in old[min(old.count - 1, j * old.count / n)] }
            covered = Array(repeating: false, count: n)
            rect = newRect
            rebuildShape()
        }
        rect = newRect
        for i in 0..<heights.count { heights[i] = min(heights[i], capAt(i)) }
    }

    var hasSnow: Bool { heights.contains { $0 > 0.3 } }
}

// MARK: - Снежки

enum BallState { case held, flying, resting }

final class Ball {
    var x: CGFloat, y: CGFloat, r: CGFloat
    var vx: CGFloat = 0, vy: CGFloat = 0
    var state: BallState
    var onSurface: Int? = nil      // лежит на окне / полу
    weak var onBall: Ball? = nil   // лежит на другом коме
    var relX: CGFloat = 0, relY: CGFloat = 0
    var placedTick = -1
    var dead = false
    var enemy = false              // снежок «противника» в снежной битве

    init(x: CGFloat, y: CGFloat, r: CGFloat, state: BallState) {
        self.x = x; self.y = y; self.r = r; self.state = state
    }
    var area: CGFloat { .pi * r * r }
    var frame: CGRect { CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2) }
}

struct Splat {
    let id: Int
    var x: CGFloat, y: CGFloat, r: CGFloat
    var age: CGFloat = 0
    var blobs: [CGPoint]           // смещения кусочков (в долях r)
    var sizes: [CGFloat]
}

// MARK: - Симуляция

final class Sim {
    var flakes: [Flake] = []
    var windows: [Int: Surface] = [:]
    var order: [Int] = []              // id окон спереди назад
    var floors: [Surface] = []
    var frontToBack: [Surface] = []    // окна спереди назад (кэш, обновляется при опросе)
    var surfList: [Surface] = []       // все окна + полы (кэш)
    var screens: [CGRect] = []         // экраны в координатах Quartz
    var bounds: CGRect = .zero

    var t: CGFloat = 0
    var wind: CGFloat = 0
    var spawnAcc: CGFloat = 0
    var paused = false
    var intensity: CGFloat = 1     // 0…4, сила снегопада
    var windStrength: CGFloat = 1  // 0…4
    var flakeSize: CGFloat = 1     // 0.5…2.5
    var weather: WeatherKind = .snow
    var envIntensity: CGFloat = 1  // множители от реальной погоды
    var envWind: CGFloat = 1
    var melting = false            // на улице плюс — снег тает
    var sfx: ((Sfx, Float) -> Void)? = nil
    let fx = SimFX()

    var balls: [Ball] = []
    var splats: [Splat] = []
    var held: Ball? = nil
    var playEnabled = true
    var interactive = false        // оверлей сейчас ловит мышь (зажат ⌥ или держим ком)
    var wasPressed = false
    var armed = false              // курсор над снегом — следующий клик достанется снегу
    var tickNo = 0
    var splatCounter = 0
    var windowsMoved = true        // окна сдвинулись — сугробы нужно перерисовать

    var mouse = CGPoint.zero
    var mouseVel = CGVector.zero
    private var lastMouse: CGPoint?
    private var pollAcc: Double = 1

    // MARK: Экраны и окна

    static var primaryHeight: CGFloat { NSScreen.screens.first?.frame.height ?? 0 }

    static func quartzRect(_ f: CGRect) -> CGRect {
        CGRect(x: f.minX, y: primaryHeight - f.maxY, width: f.width, height: f.height)
    }

    func updateScreens() {
        screens = NSScreen.screens.map { Sim.quartzRect($0.frame) }
        bounds = screens.reduce(CGRect.null) { $0.union($1) }
        floors = screens.enumerated().map { (i, r) -> Surface in
            // сохраняем снег, если экран не изменился
            if i < floors.count, floors[i].rect == r { return floors[i] }
            return Surface(id: -1 - i, rect: r, isFloor: true)
        }
        surfList = frontToBack + floors
    }

    func updateWindows() {
        let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] else { return }
        let me = Int(ProcessInfo.processInfo.processIdentifier)

        var seen = Set<Int>()
        var newOrder: [Int] = []

        for w in list {
            guard let layer = w[kCGWindowLayer as String] as? Int, layer == 0,
                  let pid = w[kCGWindowOwnerPID as String] as? Int, pid != me,
                  let num = w[kCGWindowNumber as String] as? Int,
                  let bd = w[kCGWindowBounds as String] as? NSDictionary,
                  let r = CGRect(dictionaryRepresentation: bd as CFDictionary),
                  r.width > 80, r.height > 40
            else { continue }
            if let a = w[kCGWindowAlpha as String] as? Double, a < 0.1 { continue }

            seen.insert(num)
            newOrder.append(num)

            if let s = windows[num] {
                let dx = r.minX - s.rect.minX
                let dy = r.minY - s.rect.minY
                let d = hypot(dx, dy)
                if r != s.rect { windowsMoved = true }
                s.resize(to: r)
                if d > Cfg.shakeThreshold {
                    // окно дёрнули — часть снега слетает
                    let frac = min(1, (d - Cfg.shakeThreshold) / 140 + 0.25)
                    let k = CGFloat(1 / Cfg.windowPoll)
                    shed(s, fraction: frac, vx: -dx * k * 0.35, vy: -dy * k * 0.35)
                    launchBalls(onSurface: num, vx: -dx * k * 0.3, vy: -dy * k * 0.3 - 120)
                    dropIcicles(s, vx: -dx * k * 0.3, vy: -dy * k * 0.3)
                }
            } else {
                windows[num] = Surface(id: num, rect: r, isFloor: false)
                windowsMoved = true
            }
        }

        // закрытые/свёрнутые окна: снег осыпается
        for (id, s) in windows where !seen.contains(id) {
            shed(s, fraction: 1, vx: 0, vy: 0)
            launchBalls(onSurface: id, vx: 0, vy: 0)
            dropIcicles(s, vx: 0, vy: 0)
            windows[id] = nil
            windowsMoved = true
        }
        order = newOrder
        frontToBack = order.compactMap { windows[$0] }
        surfList = frontToBack + floors

        // какие участки верхней кромки закрыты окнами спереди
        var front: [CGRect] = []
        for id in order {
            guard let s = windows[id] else { continue }
            for i in 0..<s.heights.count {
                let p = CGPoint(x: s.colX(i), y: s.top - 2)
                s.covered[i] = front.contains { $0.contains(p) }
            }
            front.append(s.rect)
        }
    }

    // MARK: Снег

    func emitLoose(x: CGFloat, y: CGFloat, mass: CGFloat, vx: CGFloat, vy: CGFloat) {
        guard flakes.count < Cfg.maxTotal, mass > 0.15 else { return }
        flakes.append(Flake(x: x, y: y, vx: vx, vy: vy,
                            r: 1.4 + min(mass, 8) * 0.28,
                            phase: 0, freq: 0, mass: mass, loose: true))
    }

    func shed(_ s: Surface, fraction: CGFloat, vx: CGFloat, vy: CGFloat) {
        for i in stride(from: 0, to: s.heights.count, by: 2) {
            var rem: CGFloat = 0
            for j in i..<min(i + 2, s.heights.count) {
                let r = s.heights[j] * fraction
                s.heights[j] -= r
                rem += r
            }
            guard rem > 0.4 else { continue }
            let n = min(3, Int(ceil(rem / 6)))
            for _ in 0..<n {
                emitLoose(x: s.colX(i) + rnd(-1, 1),
                          y: s.surfY(i) - rnd(0, max(1, rem / 2)),
                          mass: rem / CGFloat(n),
                          vx: vx * rnd(0.4, 1.0) + rnd(-50, 50),
                          vy: vy * rnd(0.4, 1.0) - rnd(40, 160))
            }
        }
    }

    func clearAll() {
        for s in windows.values { for i in 0..<s.heights.count { s.heights[i] = 0 } }
        for s in floors { for i in 0..<s.heights.count { s.heights[i] = 0 } }
        flakes.removeAll { $0.loose }
        balls.removeAll()
        splats.removeAll()
        held = nil
        clearFeatures()
    }

    private func spawn(_ dt: CGFloat) {
        guard !screens.isEmpty else { return }
        let eff = intensity * envIntensity
        let rate = Cfg.spawnPerSec * eff * weatherRateMul
        spawnAcc += rate * dt
        let totalW = screens.reduce(0) { $0 + $1.width }
        let falling = flakes.lazy.filter { !$0.loose }.count
        var budget = Int(CGFloat(Cfg.maxFalling) * max(0.2, min(2.5, eff))) - falling
        while spawnAcc >= 1 {
            spawnAcc -= 1
            guard budget > 0, flakes.count < Cfg.maxTotal else { continue }
            budget -= 1
            var pick = rnd(0, totalW)
            var scr = screens[0]
            for s in screens { if pick < s.width { scr = s; break }; pick -= s.width }
            if weather != .snow {
                flakes.append(makeParticle(scr))
                continue
            }
            let r = rnd(1.0, 3.2) * flakeSize
            flakes.append(Flake(x: rnd(scr.minX - 60, scr.maxX + 60),
                                y: scr.minY - rnd(4, 30),
                                r: r,
                                phase: rnd(0, 2 * .pi),
                                freq: rnd(0.6, 1.8),
                                mass: 0.55 + r / flakeSize * 0.33,
                                loose: false,
                                // крупные снежинки — кристаллы, мелкие — мягкие точки
                                kind: r > 2.1 && Int.random(in: 0..<10) < 8 ? Int.random(in: 1...4) : 0))
        }
    }

    func landing(x: CGFloat, y0: CGFloat, y1: CGFloat) -> (Surface, Int)? {
        for s in surfList {
            // быстрый отсев: снежинка далеко от кромки этого окна
            let top = s.top
            if y1 < top - s.cap - 1 || y0 > top + Cfg.cornerRadius + 1 { continue }
            if x < s.rect.minX || x >= s.rect.maxX { continue }
            guard let i = s.col(x), !s.covered[i] else { continue }
            let surf = s.surfY(i)
            if y0 <= surf && y1 >= surf { return (s, i) }
        }
        return nil
    }

    private func sweep() {
        // Сметает только быстрый взмах. Медленно подвести курсор к сугробу можно —
        // снег останется на месте, и его можно взять. Пока держим снежок — не сметаем.
        let speed = hypot(mouseVel.dx, mouseVel.dy)
        guard held == nil, speed > Cfg.sweepMinSpeed else { return }
        let R = Cfg.sweepRadius
        let power = min(1, (speed - Cfg.sweepMinSpeed) / 700)
        sweepLitter(radius: R)
        var sweptTotal: CGFloat = 0
        defer {
            if sweptTotal > 6 && fx.crunchCooldown <= 0 {
                play(.crunch, Float(min(1, sweptTotal / 40)))
                fx.crunchCooldown = 0.15
            }
        }

        for s in surfList {
            guard mouse.x > s.rect.minX - R, mouse.x < s.rect.maxX + R,
                  mouse.y > s.top - s.cap - R, mouse.y < s.top + R * 0.6,
                  let i0 = s.col(max(s.rect.minX, mouse.x - R)),
                  let i1 = s.col(min(s.rect.maxX - 0.01, mouse.x + R)), i0 <= i1 else { continue }
            for i in i0...i1 where !s.covered[i] && s.heights[i] > 0.3 {
                let cx = s.colX(i)
                let surf = s.surfY(i)
                let base = s.baseY(i)
                let dy: CGFloat = mouse.y < surf ? surf - mouse.y : (mouse.y > base ? mouse.y - base : 0)
                let dist = hypot(cx - mouse.x, dy)
                guard dist < R else { continue }
                let k = min(1, (1 - dist / R) * 2.2 * power)
                let removed = s.heights[i] * k
                guard removed > 0.25 else { continue }
                s.heights[i] -= removed
                sweptTotal += removed
                let n = min(2, Int(ceil(removed / 5)))
                for _ in 0..<n {
                    emitLoose(x: cx + rnd(-1.5, 1.5),
                              y: s.surfY(i) - rnd(0, removed),
                              mass: removed / CGFloat(n),
                              vx: mouseVel.dx * rnd(0.35, 0.9) + rnd(-70, 70),
                              vy: mouseVel.dy * rnd(0.35, 0.9) - rnd(90, 260))
                }
            }
        }
    }

    /// С краёв полного сугроба время от времени обваливаются комья.
    private func calve(_ dt: CGFloat) {
        for s in windows.values {
            let n = s.heights.count
            guard n > 40 else { continue }
            for side in 0..<2 {
                // первый столбик от края, где снег вообще может держаться
                var e = side == 0 ? 0 : n - 1
                let step = side == 0 ? 1 : -1
                while e >= 0 && e < n && s.capAt(e) < s.cap * 0.25 { e += step }
                guard e >= 0 && e < n else { continue }
                let w = 10
                var fullness: CGFloat = 0
                for k in 0..<w { let j = e + k * step; if j >= 0 && j < n && !s.covered[j] { fullness += s.heights[j] / max(1, s.capAt(j)) } }
                fullness /= CGFloat(w)
                guard fullness > 0.6, CGFloat.random(in: 0...1) < dt * 0.25 * fullness else { continue }
                let len = Int.random(in: 4...12)
                for k in 0..<len {
                    let j = e + k * step
                    guard j >= 0 && j < n, !s.covered[j] else { continue }
                    let rem = s.heights[j] * rnd(0.35, 0.8) * (1 - CGFloat(k) / CGFloat(len + 2))
                    s.heights[j] -= rem
                    if k % 2 == 0 && rem > 0.5 {
                        emitLoose(x: s.colX(j), y: s.surfY(j) - rnd(0, rem),
                                  mass: rem * 2, vx: CGFloat(-step) * rnd(10, 60), vy: rnd(-40, 10))
                    }
                }
            }
        }
    }

    private func relax() {
        for s in surfList {
            let n = s.heights.count
            guard n > 1 else { continue }
            for i in 0..<(n - 1) {
                let d = s.heights[i] - s.heights[i + 1]
                let ad = abs(d)
                if ad > 1.3 {
                    let tr = (ad - 1.3) * 0.3 * (d > 0 ? 1 : -1)
                    s.heights[i] -= tr
                    s.heights[i + 1] += tr
                }
            }
            // лёгкое сглаживание, чтобы не было «зубчиков» от отдельных снежинок
            var prev = s.heights[0]
            for i in 1..<(n - 1) {
                let cur = s.heights[i]
                s.heights[i] = cur + 0.03 * (prev - 2 * cur + s.heights[i + 1])
                prev = cur
            }
            for i in 0..<n where s.heights[i] > s.capAt(i) { s.heights[i] = s.capAt(i) }
        }
    }

    // MARK: Шаг

    func step(_ dt: CGFloat) {
        t += dt
        let ws = windStrength * envWind
        wind = (sin(t * 0.13) * 18 + sin(t * 0.41) * 8 + sin(t * 1.7) * 3) * ws
             + (ws > 1.5 ? (ws - 1.5) * 25 : 0)

        pollAcc += Double(dt)
        if pollAcc >= Cfg.windowPoll {
            pollAcc = 0
            updateWindows()
        }

        // курсор
        let m = NSEvent.mouseLocation
        let p = CGPoint(x: m.x, y: Sim.primaryHeight - m.y)
        if let lm = lastMouse, dt > 0 {
            let v = CGVector(dx: (p.x - lm.x) / dt, dy: (p.y - lm.y) / dt)
            mouseVel = CGVector(dx: mouseVel.dx * 0.4 + v.dx * 0.6, dy: mouseVel.dy * 0.4 + v.dy * 0.6)
        }
        lastMouse = p
        mouse = p
        let mouseSpeed = hypot(mouseVel.dx, mouseVel.dy)

        if !paused { spawn(dt) }
        updateInteraction()
        updateBalls(dt)
        sweep()

        var keep: [Flake] = []
        keep.reserveCapacity(flakes.count)
        let n0 = flakes.count                 // всё, что добавится во время цикла (брызги), сохраним
        let drag = exp(-1.1 * dt)
        let PR = Cfg.pushRadius

        for var f in flakes {
            let y0 = f.y
            if f.loose {
                let g: CGFloat = f.mat == Mat.snow ? 650 : (f.mat == Mat.rain ? 900 : 240)
                let dg = f.mat >= Mat.leaf ? exp(-2.5 * dt) : drag
                f.vy += g * dt
                f.vx *= dg
                f.vy *= dg
                f.x += (f.vx + wind * 0.6) * dt
                f.y += f.vy * dt
            } else {
                moveFalling(&f, dt)
            }

            // курсор раздвигает снежинки, а быстрым движением — подбрасывает
            let dx = f.x - mouse.x, dy = f.y - mouse.y
            let d2 = dx * dx + dy * dy
            if f.mat != Mat.rain && d2 < PR * PR && d2 > 0.01 {
                let d = sqrt(d2)
                let push = (PR - d) * 0.22
                f.x += dx / d * push
                f.y += dy / d * push * 0.6
                if mouseSpeed > 250 && d < PR * 0.7 {
                    f.loose = true
                    f.vx = mouseVel.dx * rnd(0.3, 0.7)
                    f.vy = mouseVel.dy * rnd(0.3, 0.7) - 60
                }
            }

            if f.y > y0, let (s, i) = landing(x: f.x, y0: y0, y1: f.y) {
                land(f, s, i)
                continue
            }
            if f.y > bounds.maxY + 10 || f.x < bounds.minX - 200 || f.x > bounds.maxX + 200 || f.y < bounds.minY - 800 {
                continue
            }
            keep.append(f)
        }
        if flakes.count > n0 { keep.append(contentsOf: flakes[n0...]) }
        flakes = keep
        if tickNo % 2 == 0 { relax() }
        calve(dt)
        updateFeatures(dt)
    }
}


// MARK: - Игра: снежки и снеговики

extension Sim {
    var allSurfaces: [Surface] { surfList }

    /// На экране ничего не движется — можно не перерисовывать.
    var isIdle: Bool {
        flakes.isEmpty && splats.isEmpty && held == nil && !interactive && !windowsMoved
            && !balls.contains { $0.state != .resting }
            && (balls.count < 2 || hypot(mouseVel.dx, mouseVel.dy) < 1)
            && !featuresBusy
    }

    func surface(_ id: Int) -> Surface? { id >= 0 ? windows[id] : floors.first { $0.id == id } }

    func launchBalls(onSurface id: Int, vx: CGFloat, vy: CGFloat) {
        for b in balls where b.state == .resting && b.onSurface == id {
            knock(b, vx: vx + rnd(-30, 30), vy: vy)
        }
    }

    func knock(_ b: Ball, vx: CGFloat, vy: CGFloat) {
        b.state = .flying
        b.vx = vx; b.vy = vy
        b.onSurface = nil; b.onBall = nil
    }

    func hasBallOnTop(_ o: Ball) -> Bool {
        balls.contains { !$0.dead && $0.state == .resting && $0.onBall === o }
    }

    /// Нижняя поверхность стопки (окно или пол), на которой стоит ком.
    func baseSurface(_ b: Ball) -> Surface? {
        var cur: Ball? = b
        var depth = 0
        while let c = cur, depth < 12 {
            if let sid = c.onSurface { return surface(sid) }
            cur = c.onBall
            depth += 1
        }
        return nil
    }

    /// Ком лежит на окне, которое сейчас закрыто другим окном.
    func isHidden(_ b: Ball) -> Bool {
        guard b.state == .resting, let s = baseSurface(b), !s.isFloor, let i = s.col(b.x) else { return false }
        return s.covered[i]
    }

    // MARK: Мышь

    /// Курсор сейчас над снегом, который можно взять (сугроб или лежащий ком).
    func snowUnderCursor() -> Bool {
        if enemyUnderCursor() != nil || icicleUnderCursor() != nil { return true }
        for b in balls where b.state == .resting && !isHidden(b) && hypot(b.x - mouse.x, b.y - mouse.y) < b.r + 3 {
            return true
        }
        for s in surfList {
            guard let i = s.col(mouse.x), !s.covered[i], s.heights[i] > 2.5 else { continue }
            if mouse.y >= s.surfY(i) - 4 && mouse.y <= s.baseY(i) + 1 { return true }
        }
        return false
    }

    func updateInteraction() {
        // ⌥ по-прежнему работает: с ним можно хватать снег чуть издалека
        let option = NSEvent.modifierFlags.contains(.option)
        let pressed = (NSEvent.pressedMouseButtons & 1) != 0
        // Пока кнопка не нажата, решаем, ловить ли клик: только если курсор прямо на снегу.
        // Так клики по программам проходят как обычно, а клик по снегу достаётся снегу.
        if !pressed {
            armed = playEnabled && held == nil && (option || snowUnderCursor())
        }
        interactive = playEnabled && (armed || held != nil)

        if pressed && !wasPressed && armed && held == nil { grab() }
        if !pressed, let b = held { release(b) }
        wasPressed = pressed

        if let b = held {
            b.x = mouse.x
            b.y = mouse.y
            collect(into: b)
        }
    }

    func grab() {
        // 0) отбить вражеский снежок или отломить сосульку
        if let e = enemyUnderCursor() {
            fx.scoreMe += 1
            play(.crunch, 0.9)
            splat(e, decal: false)
            return
        }
        if let (s, k) = icicleUnderCursor() {
            breakIcicle(s, k)
            return
        }
        // 1) взять лежащий ком (самый верхний под курсором)
        let under = balls.filter { !$0.dead && $0.state == .resting && !isHidden($0)
                                   && hypot($0.x - mouse.x, $0.y - mouse.y) < $0.r + 4 }
        if let b = under.min(by: { $0.y < $1.y }) {
            for top in balls where top.onBall === b { knock(top, vx: 0, vy: 0) }
            b.state = .held
            b.onSurface = nil; b.onBall = nil
            held = b
            play(.crunch, 0.4)
            return
        }
        // 2) зачерпнуть снег из ближайшего сугроба
        var best: (Surface, Int)? = nil
        var bestD: CGFloat = 24
        for s in allSurfaces {
            guard let i = s.col(mouse.x), !s.covered[i], s.heights[i] > 1.5 else { continue }
            let surf = s.surfY(i)
            let base = s.baseY(i)
            let d: CGFloat = mouse.y < surf ? surf - mouse.y : (mouse.y > base ? mouse.y - base : 0)
            if d < bestD { bestD = d; best = (s, i) }
        }
        guard let (s, i) = best else { return }
        var area: CGFloat = 0
        for j in (i - 4)...(i + 4) where j >= 0 && j < s.heights.count && !s.covered[j] {
            let take = min(s.heights[j], 6)
            s.heights[j] -= take
            area += take * Cfg.cell
        }
        guard area > 8 else { return }
        let b = Ball(x: mouse.x, y: mouse.y, r: max(4, sqrt(area / .pi)), state: .held)
        balls.append(b)
        held = b
        play(.crunch, 0.6)
    }

    /// Ком, который катают по сугробу, собирает снег и растёт.
    func collect(into b: Ball) {
        guard b.r < Cfg.maxBall else { return }
        let speed = hypot(mouseVel.dx, mouseVel.dy)
        let rate = min(1, 0.06 + speed / 900)
        var gained: CGFloat = 0
        for s in allSurfaces {
            guard b.x + b.r > s.rect.minX, b.x - b.r < s.rect.maxX,
                  b.y + b.r > s.top - s.cap - 2, b.y - b.r < s.top,
                  let i0 = s.col(max(s.rect.minX, b.x - b.r)),
                  let i1 = s.col(min(s.rect.maxX - 0.01, b.x + b.r)), i0 <= i1 else { continue }
            for i in i0...i1 where !s.covered[i] && s.heights[i] > 0.2 {
                let dx = s.colX(i) - b.x
                let yb = b.y + sqrt(max(0, b.r * b.r - dx * dx))
                let surf = s.surfY(i)
                guard yb > surf else { continue }
                let take = min(s.heights[i], yb - surf) * rate * 0.5
                s.heights[i] -= take
                gained += take * Cfg.cell
            }
        }
        if gained > 0 { b.r = min(Cfg.maxBall, sqrt((b.area + gained) / .pi)) }
    }

    func release(_ b: Ball) {
        held = nil
        var vx = mouseVel.dx, vy = mouseVel.dy
        let sp = hypot(vx, vy)
        if sp > 2600 { vx *= 2600 / sp; vy *= 2600 / sp }
        b.vx = vx; b.vy = vy
        b.state = .flying
        // если ком вдавлен в сугроб — приподнять, чтобы он лёг сверху, а не провалился
        for s in allSurfaces {
            guard let i = s.col(b.x), !s.covered[i] else { continue }
            let surf = s.surfY(i)
            if b.y + b.r * 0.9 > surf && b.y < s.baseY(i) + b.r * 0.5 {
                b.y = surf - b.r * 0.9 - 0.5
                break
            }
        }
    }

    // MARK: Физика комов

    func place(_ b: Ball, depth: Int) {
        if b.placedTick == tickNo { return }
        b.placedTick = tickNo
        if let sid = b.onSurface {
            guard let s = surface(sid), b.relX > -b.r * 0.3, b.relX < s.rect.width + b.r * 0.3 else {
                knock(b, vx: 0, vy: 0); return
            }
            b.x = s.rect.minX + b.relX
            b.y = s.top + b.relY
        } else if let o = b.onBall, depth < 12, !o.dead {
            place(o, depth: depth + 1)
            guard o.state == .resting else { knock(b, vx: o.vx, vy: o.vy); return }
            b.x = o.x + b.relX
            b.y = o.y - o.r * 0.82 - b.r * 0.82
        } else {
            knock(b, vx: 0, vy: 0)
        }
    }

    func splat(_ b: Ball, decal: Bool) {
        b.dead = true
        play(b.enemy ? .hit : .plop, Float(min(1, 0.35 + b.r / 40)))
        if held === b { held = nil }
        let total = b.area / Cfg.cell * 0.85
        let n = max(4, min(40, Int(b.r * 1.2)))
        for _ in 0..<n {
            let a = rnd(0, 2 * .pi)
            let sp = rnd(60, 260) + b.r * 3
            emitLoose(x: b.x + cos(a) * b.r * 0.5, y: b.y + sin(a) * b.r * 0.5,
                      mass: total / CGFloat(n),
                      vx: cos(a) * sp + b.vx * 0.15, vy: sin(a) * sp - 120 + b.vy * 0.05)
        }
        if decal {
            let k = 7
            splatCounter += 1
            splats.append(Splat(id: splatCounter, x: b.x, y: b.y, r: b.r * 1.1,
                                blobs: (0..<k).map { _ in CGPoint(x: rnd(-0.9, 0.9), y: rnd(-0.9, 0.9)) },
                                sizes: (0..<k).map { _ in rnd(0.25, 0.55) }))
            if splats.count > 30 { splats.removeFirst() }
        }
    }

    func updateBalls(_ dt: CGFloat) {
        tickNo += 1
        for b in balls where !b.dead && b.state == .resting { place(b, depth: 0) }

        let drag = exp(-0.25 * dt)
        for b in balls where !b.dead && b.state == .flying {
            let y0 = b.y
            b.vy += Cfg.ballGravity * dt
            b.vx *= drag; b.vy *= drag
            b.x += b.vx * dt
            b.y += b.vy * dt
            let speed = hypot(b.vx, b.vy)

            // столкновение с лежащими комами
            var done = false
            for o in balls where o !== b && !o.dead && o.state == .resting && !isHidden(o) {
                let dx = b.x - o.x, dy = b.y - o.y
                let d = max(0.01, hypot(dx, dy))
                let reach = b.r + o.r * 0.92
                guard d < reach else { continue }
                if speed > Cfg.splatSpeed * 0.7 {
                    knock(o, vx: b.vx * 0.45, vy: b.vy * 0.3 - 180)   // сбили снеговика!
                    splat(b, decal: true)
                    done = true; break
                }
                if dy < 0 && b.vy > 0 && abs(dx) < o.r * 0.65 && !hasBallOnTop(o) {
                    b.state = .resting
                    b.onBall = o
                    b.relX = dx * 0.5
                    b.vx = 0; b.vy = 0
                    done = true; break
                }
                // отскок
                let nx = dx / d, ny = dy / d
                b.x += nx * (reach - d); b.y += ny * (reach - d)
                let vn = b.vx * nx + b.vy * ny
                if vn < 0 { b.vx -= 1.5 * vn * nx; b.vy -= 1.5 * vn * ny }
                b.vx += nx * 40
            }
            if done || b.dead { continue }

            // приземление на окно или пол
            if b.vy > 0, let (s, i) = landing(x: b.x, y0: y0 + b.r * 0.9, y1: b.y + b.r * 0.9) {
                if speed > Cfg.splatSpeed {
                    splat(b, decal: true)
                } else {
                    b.state = .resting
                    b.onSurface = s.id
                    b.relX = b.x - s.rect.minX
                    b.relY = s.baseOff[i] - s.heights[i] - b.r * 0.9
                    b.vx = 0; b.vy = 0
                }
                continue
            }

            // края экрана
            if (b.x - b.r < bounds.minX && b.vx < 0) || (b.x + b.r > bounds.maxX && b.vx > 0) {
                if speed > 500 {
                    b.x = min(max(b.x, bounds.minX + b.r * 0.4), bounds.maxX - b.r * 0.4)
                    if fx.fight && !b.enemy { fx.scoreMe += 1 }   // попал в «противника» за краем экрана
                    splat(b, decal: true)
                } else {
                    b.vx = -b.vx * 0.4
                }
            }
            if b.y - b.r > bounds.maxY + 40 { b.dead = true }
        }
        balls.removeAll { $0.dead }

        for i in splats.indices {
            splats[i].age += dt
            splats[i].y += 7 * dt          // медленно сползает
        }
        splats.removeAll { $0.age > 7 }
    }
}

// MARK: - Отрисовка (SpriteKit: рисует видеокарта)

enum Tex {
    static let rgb = CGColorSpaceCreateDeviceRGB()

    static func make(_ px: Int, _ draw: (CGContext, CGFloat) -> Void) -> SKTexture {
        let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                            space: Tex.rgb, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        draw(ctx, CGFloat(px))
        let t = SKTexture(cgImage: ctx.makeImage()!)
        t.filteringMode = .linear
        return t
    }

    static func gradient(_ a: CGColor, _ b: CGColor) -> CGGradient {
        CGGradient(colorsSpace: Tex.rgb, colors: [a, b] as CFArray, locations: [0, 1])!
    }

    static func image(_ px: Int, _ draw: (CGContext, CGFloat) -> Void) -> CGImage {
        let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                            space: Tex.rgb, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        draw(ctx, CGFloat(px))
        return ctx.makeImage()!
    }

    /// Мягкая точка для мелких снежинок.
    static func dotImage() -> CGImage {
        image(32) { ctx, s in
            let c = CGPoint(x: s / 2, y: s / 2)
            ctx.drawRadialGradient(Tex.gradient(CGColor(red: 0, green: 0, blue: 0.15, alpha: 0.16),
                                                CGColor(red: 0, green: 0, blue: 0.15, alpha: 0)),
                                   startCenter: c, startRadius: s * 0.2, endCenter: c, endRadius: s * 0.5, options: [])
            ctx.drawRadialGradient(Tex.gradient(CGColor(red: 1, green: 1, blue: 1, alpha: 1),
                                                CGColor(red: 1, green: 1, blue: 1, alpha: 0)),
                                   startCenter: c, startRadius: s * 0.26, endCenter: c, endRadius: s * 0.40, options: [])
        }
    }

    /// Шестилучевой кристалл. Варианты отличаются веточками.
    static func crystalImage(_ v: Int) -> CGImage {
        image(96) { ctx, s in
            let c = CGPoint(x: s / 2, y: s / 2)
            let R = s * 0.42
            let p = CGMutablePath()
            func ray(_ a: CGFloat, _ from: CGFloat, _ to: CGFloat) {
                p.move(to: CGPoint(x: c.x + cos(a) * from, y: c.y + sin(a) * from))
                p.addLine(to: CGPoint(x: c.x + cos(a) * to, y: c.y + sin(a) * to))
            }
            func branch(_ a: CGFloat, at f: CGFloat, len: CGFloat, spread: CGFloat) {
                let base = CGPoint(x: c.x + cos(a) * R * f, y: c.y + sin(a) * R * f)
                for side in [-1.0, 1.0] as [CGFloat] {
                    let b = a + side * spread
                    p.move(to: base)
                    p.addLine(to: CGPoint(x: base.x + cos(b) * R * len, y: base.y + sin(b) * R * len))
                }
            }
            for k in 0..<6 {
                let a = CGFloat(k) * .pi / 3 + .pi / 2
                ray(a, 0, R)
                switch v {
                case 1:   // классическая: две пары веточек
                    branch(a, at: 0.45, len: 0.30, spread: .pi / 3)
                    branch(a, at: 0.72, len: 0.20, spread: .pi / 3)
                case 2:   // папоротник: много коротких веточек
                    branch(a, at: 0.30, len: 0.22, spread: .pi / 3.6)
                    branch(a, at: 0.52, len: 0.20, spread: .pi / 3.6)
                    branch(a, at: 0.72, len: 0.15, spread: .pi / 3.6)
                    branch(a, at: 0.88, len: 0.08, spread: .pi / 3.6)
                case 3:   // пластинка: шестиугольник в центре и «стрелки» на концах
                    let h0 = CGPoint(x: c.x + cos(a) * R * 0.36, y: c.y + sin(a) * R * 0.36)
                    let a2 = a + .pi / 3
                    let h1 = CGPoint(x: c.x + cos(a2) * R * 0.36, y: c.y + sin(a2) * R * 0.36)
                    p.move(to: h0); p.addLine(to: h1)
                    branch(a, at: 0.82, len: 0.18, spread: .pi / 4)
                default:  // звёздочка с вилочками на концах
                    branch(a, at: 0.62, len: 0.34, spread: .pi / 5)
                }
            }
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            // тёмная кайма, чтобы кристалл читался на белом окне
            ctx.setStrokeColor(CGColor(red: 0.05, green: 0.08, blue: 0.2, alpha: 0.28))
            ctx.setLineWidth(s * 0.075)
            ctx.addPath(p)
            ctx.strokePath()
            ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            ctx.setLineWidth(s * 0.038)
            ctx.addPath(p)
            ctx.strokePath()
            ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            ctx.fillEllipse(in: CGRect(x: c.x - s * 0.05, y: c.y - s * 0.05, width: s * 0.1, height: s * 0.1))
        }
    }

    /// Все виды снежинок в одном атласе — видеокарта рисует их одним вызовом.
    static let flakeAtlas: SKTextureAtlas = {
        var d: [String: Any] = ["f0": NSImage(cgImage: Tex.dotImage(), size: NSSize(width: 32, height: 32))]
        for v in 1...4 { d["f\(v)"] = NSImage(cgImage: Tex.crystalImage(v), size: NSSize(width: 96, height: 96)) }
        for v in 5...9 { d["f\(v)"] = NSImage(cgImage: TexX.extraFlakeImage(v), size: NSSize(width: 64, height: 64)) }
        return SKTextureAtlas(dictionary: d)
    }()
    static let flakeTex: [SKTexture] = (0...9).map { Tex.flakeAtlas.textureNamed("f\($0)") }
    static let flake: SKTexture = Tex.flakeTex[0]
    static let flakeScale: CGFloat = 1 / 0.6

    /// Снежный ком: объёмный градиент и мягкая тень снизу.
    static let ball: SKTexture = make(256) { ctx, s in
        let c = CGPoint(x: s / 2, y: s / 2)
        let R = s * 0.42
        let sc = CGPoint(x: c.x, y: c.y - s * 0.03)
        ctx.drawRadialGradient(Tex.gradient(CGColor(red: 0, green: 0, blue: 0.1, alpha: 0.32),
                                        CGColor(red: 0, green: 0, blue: 0.1, alpha: 0)),
                               startCenter: sc, startRadius: R * 0.9, endCenter: sc, endRadius: s * 0.5, options: [])
        ctx.saveGState()
        ctx.addEllipse(in: CGRect(x: c.x - R, y: c.y - R, width: R * 2, height: R * 2))
        ctx.clip()
        ctx.drawRadialGradient(Tex.gradient(CGColor(red: 1, green: 1, blue: 1, alpha: 1),
                                        CGColor(red: 0.80, green: 0.86, blue: 0.95, alpha: 1)),
                               startCenter: CGPoint(x: c.x - R * 0.35, y: c.y + R * 0.4), startRadius: 0,
                               endCenter: c, endRadius: R * 1.15, options: [.drawsAfterEndLocation])
        ctx.restoreGState()
    }
    static let ballScale: CGFloat = 1 / 0.84
}

final class SnowSKView: SKView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

final class SnowScene: SKScene {
    let sim: Sim
    let q: CGRect                       // экран в координатах Quartz

    private var flakeNodes: [SKSpriteNode] = []
    private var flakeSizes: [CGFloat] = []
    private var flakeKinds: [Int] = []
    private var ballNodes: [SKSpriteNode] = []
    private var pileNodes: [Int: SKSpriteNode] = [:]
    private var pileDrawn: [Int: (rect: CGRect, h: [CGFloat], cov: [Bool])] = [:]   // что нарисовано сейчас
    private var splatNodes: [Int: SKNode] = [:]
    private let arms = SKShapeNode(), whites = SKShapeNode(), blacks = SKShapeNode()
    private let nose = SKShapeNode(), band = SKShapeNode()
    private let ringOuter = SKShapeNode(circleOfRadius: 15), ringInner = SKShapeNode(circleOfRadius: 15)
    let fxn = SceneFX()

    init(sim: Sim, q: CGRect) {
        self.sim = sim
        self.q = q
        super.init(size: q.size)
        backgroundColor = .clear
        scaleMode = .resizeFill

        arms.strokeColor = NSColor(calibratedRed: 0.42, green: 0.27, blue: 0.14, alpha: 1)
        arms.lineCap = .round
        arms.zPosition = 2.5
        whites.fillColor = .white
        whites.strokeColor = NSColor(calibratedWhite: 0, alpha: 0.35)
        whites.lineWidth = 1
        whites.zPosition = 4
        blacks.fillColor = NSColor(calibratedWhite: 0.07, alpha: 1)
        blacks.strokeColor = .clear
        blacks.lineWidth = 0
        blacks.zPosition = 4.1
        band.fillColor = NSColor(calibratedRed: 0.8, green: 0.1, blue: 0.15, alpha: 1)
        band.strokeColor = .clear
        band.lineWidth = 0
        band.zPosition = 4.15
        nose.fillColor = NSColor(calibratedRed: 0.98, green: 0.50, blue: 0.10, alpha: 1)
        nose.strokeColor = .clear
        nose.lineWidth = 0
        nose.zPosition = 4.2
        ringOuter.strokeColor = NSColor(calibratedWhite: 0, alpha: 0.25)
        ringOuter.lineWidth = 3
        ringInner.strokeColor = NSColor(calibratedWhite: 1, alpha: 0.9)
        ringInner.lineWidth = 1.5
        for r in [ringOuter, ringInner] { r.fillColor = .clear; r.zPosition = 10; r.isHidden = true }
        for n in [arms, whites, blacks, band, nose, ringOuter, ringInner] { addChild(n) }
    }
    required init?(coder: NSCoder) { fatalError() }

    // клики, пока зажат ⌥, просто поглощаем — логика игры работает по состоянию кнопки
    override func mouseDown(with event: NSEvent) {}
    override func mouseDragged(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {}

    func P(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x - q.minX, y: q.maxY - y) }
    private func flipped(_ p: CGPath) -> CGPath? {
        if p.isEmpty { return nil }
        var t = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: -q.minX, ty: q.maxY)
        return p.copy(using: &t)
    }

    func sync(piles: Bool) {
        syncFlakes()
        if piles { syncPiles() }
        syncBalls()
        syncSplats()
        syncExtras()
        let showRing = sim.interactive && sim.held == nil && q.contains(sim.mouse)
        ringOuter.isHidden = !showRing
        ringInner.isHidden = !showRing
        if showRing {
            ringOuter.position = P(sim.mouse.x, sim.mouse.y)
            ringInner.position = ringOuter.position
        }
    }

    private func syncFlakes() {
        let vis = q.insetBy(dx: -8, dy: -8)
        var k = 0
        for f in sim.flakes where vis.contains(CGPoint(x: f.x, y: f.y)) {
            let node: SKSpriteNode
            if k < flakeNodes.count {
                node = flakeNodes[k]
            } else {
                node = SKSpriteNode(texture: Tex.flake)
                node.zPosition = 5
                addChild(node)
                flakeNodes.append(node)
                flakeSizes.append(-1)
                flakeKinds.append(0)
            }
            if node.isHidden { node.isHidden = false }
            node.position = P(f.x, f.y)
            if flakeKinds[k] != f.kind {
                node.texture = Tex.flakeTex[f.kind]
                flakeKinds[k] = f.kind
                flakeSizes[k] = -1
            }
            // размер и поворот зависят от вида частицы
            let scale: CGFloat
            switch f.kind {
            case 0: scale = Tex.flakeScale
            case 1...4: scale = 2.6                // кристаллы
            case 5...7: scale = 2.3                // листья
            case 8: scale = 2.0                    // лепестки
            default: scale = f.loose ? 3 : 9       // капли — вытянутые
            }
            let d = (f.r * 2 * scale * 4).rounded() / 4
            if flakeSizes[k] != d {
                node.size = CGSize(width: d, height: d)
                flakeSizes[k] = d
            }
            switch f.kind {
            case 0:
                if node.zRotation != 0 { node.zRotation = 0 }
            case 9:
                // капля смотрит по направлению полёта
                let vx = f.loose ? f.vx : sim.wind * 3
                let vy = f.loose ? f.vy : 620 + f.r * 90
                node.zRotation = atan2(vx, vy)
            case 5...8:
                node.zRotation = f.phase + sim.t * (f.freq + 0.4) * 1.6 * (f.phase > .pi ? 1 : -1)
            default:
                node.zRotation = f.phase + sim.t * (f.freq - 1.2) * 0.9
            }
            k += 1
        }
        if k < flakeNodes.count {
            for j in k..<flakeNodes.count where !flakeNodes[j].isHidden { flakeNodes[j].isHidden = true }
        }
    }

    /// Сугробы рисуем в картинку через Core Graphics — только когда сугроб изменился.
    /// (Фигуры SpriteKit пересчитывают контур каждый кадр, это и съедало процессор.)
    private func syncPiles() {
        var seen = Set<Int>()
        // снег мягкий, поэтому хватает обычного разрешения: в 4 раза меньше пикселей, чем на Retina
        let scale: CGFloat = 1
        for s in sim.allSurfaces where s.rect.intersects(q.insetBy(dx: 0, dy: -60)) {
            seen.insert(s.id)
            let node: SKSpriteNode
            if let n = pileNodes[s.id] {
                node = n
            } else {
                node = SKSpriteNode()
                node.zPosition = 1
                addChild(node)
                pileNodes[s.id] = node
            }

            // перерисовываем, только если сугроб заметно изменился (больше чем на ~1 px) или окно сдвинулось
            if let d = pileDrawn[s.id], d.rect == s.rect, d.cov == s.covered, d.h.count == s.heights.count {
                var maxDiff: CGFloat = 0
                for i in 0..<s.heights.count {
                    let diff = abs(s.heights[i] - d.h[i])
                    if diff > maxDiff { maxDiff = diff; if maxDiff > 1 { break } }
                }
                if maxDiff <= 1 { continue }
            } else if let d = pileDrawn[s.id], d.rect.size == s.rect.size, d.cov == s.covered,
                      d.h.count == s.heights.count, !node.isHidden {
                // окно просто сдвинули — двигаем готовую картинку, не перерисовывая
                let dx = s.rect.minX - d.rect.minX, dy = s.rect.minY - d.rect.minY
                node.position = CGPoint(x: node.position.x + dx, y: node.position.y - dy)
                pileDrawn[s.id] = (s.rect, d.h, d.cov)
                continue
            }
            pileDrawn[s.id] = (s.rect, s.heights, s.covered)

            let path = CGMutablePath()
            SnowScene.addPile(s, to: path)
            if path.isEmpty {
                node.isHidden = true
                continue
            }
            let bb = path.boundingBox.insetBy(dx: -3, dy: -3).integral
            let w = Int(bb.width * scale), h = Int(bb.height * scale)
            guard w > 0, h > 0,
                  let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: Tex.rgb, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { continue }
            ctx.scaleBy(x: scale, y: scale)
            ctx.translateBy(x: 0, y: bb.height)
            ctx.scaleBy(x: 1, y: -1)
            ctx.translateBy(x: -bb.minX, y: -bb.minY)

            // тень без размытия (размытие было самым дорогим): тот же контур чуть ниже и прозрачнее
            ctx.saveGState()
            ctx.translateBy(x: 0, y: 1)
            ctx.setFillColor(CGColor(red: 0.1, green: 0.15, blue: 0.3, alpha: 0.22))
            ctx.addPath(path)
            ctx.fillPath()
            ctx.restoreGState()

            // объём: сверху белое, внизу чуть голубое
            ctx.saveGState()
            ctx.addPath(path)
            ctx.clip()
            let pb = path.boundingBox
            ctx.drawLinearGradient(SnowScene.pileGradient,
                                   start: CGPoint(x: 0, y: pb.minY), end: CGPoint(x: 0, y: pb.maxY), options: [])
            ctx.restoreGState()

            guard let img = ctx.makeImage() else { continue }
            let tex = SKTexture(cgImage: img)
            tex.filteringMode = .linear
            node.texture = tex
            node.size = bb.size
            node.position = P(bb.midX, bb.midY)
            node.isHidden = false
        }
        for (id, n) in pileNodes where !seen.contains(id) {
            n.removeFromParent()
            pileNodes[id] = nil
            pileDrawn[id] = nil
        }
    }

    static let pileGradient: CGGradient = CGGradient(
        colorsSpace: Tex.rgb,
        colors: [CGColor(red: 1, green: 1, blue: 1, alpha: 1),
                 CGColor(red: 0.97, green: 0.98, blue: 1, alpha: 1),
                 CGColor(red: 0.86, green: 0.90, blue: 0.97, alpha: 1)] as CFArray,
        locations: [0, 0.55, 1])!

    static func addPile(_ s: Surface, to path: CGMutablePath) {
        let n = s.heights.count
        let minH: CGFloat = 0.6
        var i = 0
        while i < n {
            while i < n && (s.covered[i] || s.heights[i] < minH) { i += 1 }
            if i >= n { break }
            let start = i
            while i < n && !s.covered[i] && s.heights[i] >= minH { i += 1 }
            let end = i

            path.move(to: CGPoint(x: s.colX(start) - Cfg.cell / 2, y: s.baseY(start)))
            var prev = CGPoint(x: s.colX(start), y: s.surfY(start))
            path.addLine(to: prev)
            for j in (start + 1)..<end {
                let p = CGPoint(x: s.colX(j), y: s.surfY(j))
                let mid = CGPoint(x: (prev.x + p.x) / 2, y: (prev.y + p.y) / 2)
                path.addQuadCurve(to: mid, control: prev)
                prev = p
            }
            path.addLine(to: prev)
            path.addLine(to: CGPoint(x: s.colX(end - 1) + Cfg.cell / 2, y: s.baseY(end - 1)))
            for j in stride(from: end - 1, through: start, by: -1) {
                path.addLine(to: CGPoint(x: s.colX(j), y: s.baseY(j)))
            }
            path.closeSubpath()
        }
    }

    private func syncBalls() {
        let vis = q.insetBy(dx: -100, dy: -100)
        let list = sim.balls.sorted { $0.y > $1.y }
        var k = 0
        for (idx, b) in list.enumerated() where vis.intersects(b.frame) && !sim.isHidden(b) {
            let node: SKSpriteNode
            if k < ballNodes.count {
                node = ballNodes[k]
            } else {
                node = SKSpriteNode(texture: Tex.ball)
                addChild(node)
                ballNodes.append(node)
            }
            node.isHidden = false
            node.zPosition = 3 + CGFloat(idx) * 0.001
            node.position = P(b.x, b.y)
            let d = b.r * 2 * Tex.ballScale
            node.size = CGSize(width: d, height: d)
            k += 1
        }
        if k < ballNodes.count { for j in k..<ballNodes.count { ballNodes[j].isHidden = true } }
        syncSnowmen()
    }

    private func syncSnowmen() {
        // стопки из 2–3 комов
        var men: [[Ball]] = []
        for base in sim.balls where base.state == .resting && base.onSurface != nil && !sim.isHidden(base) {
            guard q.insetBy(dx: -150, dy: -150).contains(CGPoint(x: base.x, y: base.y)) else { continue }
            var chain = [base]
            while chain.count < 3,
                  let last = chain.last,
                  let up = sim.balls.first(where: { $0.state == .resting && $0.onBall === last }) {
                chain.append(up)
            }
            if chain.count >= 2 && chain[chain.count - 1].r <= chain[chain.count - 2].r * 1.25 {
                men.append(chain)
            }
        }

        let armsP = CGMutablePath(), whitesP = CGMutablePath(), blacksP = CGMutablePath()
        let noseP = CGMutablePath(), bandP = CGMutablePath()
        var armW: CGFloat = 1.5
        let m = sim.mouse

        for chain in men {
            let h = chain[chain.count - 1]
            let r = h.r
            // глаза следят за курсором
            for side in [-1.0, 1.0] as [CGFloat] {
                let ex = h.x + side * r * 0.32, ey = h.y - r * 0.2
                let er = max(1.8, r * 0.14)
                whitesP.addEllipse(in: CGRect(x: ex - er, y: ey - er, width: er * 2, height: er * 2))
                let dx = m.x - ex, dy = m.y - ey
                let d = max(1, hypot(dx, dy))
                let pr = er * 0.55
                let px = ex + dx / d * (er - pr) * 0.9, py = ey + dy / d * (er - pr) * 0.9
                blacksP.addEllipse(in: CGRect(x: px - pr, y: py - pr, width: pr * 2, height: pr * 2))
            }
            // нос-морковка в сторону курсора
            let dir: CGFloat = m.x >= h.x ? 1 : -1
            noseP.move(to: CGPoint(x: h.x, y: h.y - r * 0.1))
            noseP.addLine(to: CGPoint(x: h.x, y: h.y + r * 0.08))
            noseP.addLine(to: CGPoint(x: h.x + dir * r * 0.6, y: h.y + r * 0.02))
            noseP.closeSubpath()
            // улыбка
            for k in -2...2 {
                let t = CGFloat(k) / 2
                let dr = max(0.9, r * 0.045)
                let x = h.x + t * r * 0.36, y = h.y + r * 0.3 + (1 - t * t) * r * 0.1
                blacksP.addEllipse(in: CGRect(x: x - dr, y: y - dr, width: dr * 2, height: dr * 2))
            }
            guard chain.count >= 3 else { continue }
            let b = chain[1]
            // пуговицы
            for k in [-0.4, 0.0, 0.4] as [CGFloat] {
                let rr = max(1.2, b.r * 0.08)
                blacksP.addEllipse(in: CGRect(x: b.x - rr, y: b.y + k * b.r - rr, width: rr * 2, height: rr * 2))
            }
            // руки-веточки
            armW = max(armW, b.r * 0.07)
            for side in [-1.0, 1.0] as [CGFloat] {
                let p0 = CGPoint(x: b.x + side * b.r * 0.7, y: b.y - b.r * 0.1)
                let p1 = CGPoint(x: b.x + side * b.r * 1.75, y: b.y - b.r * 0.75)
                let mid = CGPoint(x: p0.x + (p1.x - p0.x) * 0.7, y: p0.y + (p1.y - p0.y) * 0.7)
                armsP.move(to: p0); armsP.addLine(to: p1)
                armsP.move(to: mid); armsP.addLine(to: CGPoint(x: mid.x + side * b.r * 0.1, y: mid.y - b.r * 0.4))
            }
            // шляпа
            let brimY = h.y - r * 0.8
            blacksP.addRect(CGRect(x: h.x - r * 0.78, y: brimY - r * 0.14, width: r * 1.56, height: r * 0.16))
            blacksP.addRect(CGRect(x: h.x - r * 0.5, y: brimY - r * 0.84, width: r * 1.0, height: r * 0.70))
            bandP.addRect(CGRect(x: h.x - r * 0.5, y: brimY - r * 0.3, width: r * 1.0, height: r * 0.14))
        }

        arms.lineWidth = armW
        arms.path = flipped(armsP)
        whites.path = flipped(whitesP)
        blacks.path = flipped(blacksP)
        nose.path = flipped(noseP)
        band.path = flipped(bandP)
    }

    private func syncSplats() {
        var seen = Set<Int>()
        let vis = q.insetBy(dx: -80, dy: -80)
        for sp in sim.splats where vis.contains(CGPoint(x: sp.x, y: sp.y)) {
            seen.insert(sp.id)
            let node: SKNode
            if let n = splatNodes[sp.id] {
                node = n
            } else {
                node = SKNode()
                node.zPosition = 2
                var parts: [(CGPoint, CGFloat, CGFloat)] = [(.zero, sp.r * 0.6, sp.r * 0.5)]
                for (p, k) in zip(sp.blobs, sp.sizes) {
                    parts.append((CGPoint(x: p.x * sp.r, y: -p.y * sp.r), sp.r * k, sp.r * k))
                }
                for (c, rx, ry) in parts {
                    let shadow = SKShapeNode(ellipseOf: CGSize(width: rx * 2 + 2, height: ry * 2 + 2))
                    shadow.position = CGPoint(x: c.x, y: c.y - 0.5)
                    shadow.fillColor = NSColor(calibratedWhite: 0, alpha: 0.12)
                    shadow.strokeColor = .clear
                    shadow.lineWidth = 0
                    shadow.zPosition = 0
                    node.addChild(shadow)
                }
                for (c, rx, ry) in parts {
                    let e = SKShapeNode(ellipseOf: CGSize(width: rx * 2, height: ry * 2))
                    e.position = c
                    e.fillColor = .white
                    e.strokeColor = .clear
                    e.lineWidth = 0
                    e.zPosition = 0.01
                    node.addChild(e)
                }
                addChild(node)
                splatNodes[sp.id] = node
            }
            node.position = P(sp.x, sp.y)
            node.alpha = 0.95 * max(0, 1 - sp.age / 7)
        }
        for (id, n) in splatNodes where !seen.contains(id) {
            n.removeFromParent()
            splatNodes[id] = nil
        }
    }
}

// MARK: - Приложение

final class AppDelegate: NSObject, NSApplicationDelegate {
    let sim = Sim()
    var overlays: [NSWindow] = []
    var views: [SnowSKView] = []
    var scenes: [SnowScene] = []
    var frameNo = 0
    var sleeping = false
    var hiddenAll = false
    var wasIdle = false
    var fps: Int { defaults.bool(forKey: "eco") ? 30 : 60 }
    var statusItem: NSStatusItem!
    var timer: Timer?
    var weatherTimer: Timer?
    var last = CACurrentMediaTime()
    var labels: [Int: NSTextField] = [:]
    var sliders: [Int: NSSlider] = [:]
    var items: [String: NSMenuItem] = [:]
    var weatherItems: [NSMenuItem] = []
    var lastTitle = ""
    let defaults = UserDefaults.standard

    func applicationDidFinishLaunching(_ note: Notification) {
        buildOverlays()
        buildMenu()
        sim.sfx = { s, g in SoundBox.shared.play(s, gain: g) }
        registerHotKeys()

        NotificationCenter.default.addObserver(
            self, selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)

        // экран спит или заблокирован — останавливаемся полностью
        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(self, selector: #selector(goSleep), name: NSWorkspace.screensDidSleepNotification, object: nil)
        ws.addObserver(self, selector: #selector(goSleep), name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
        ws.addObserver(self, selector: #selector(wakeUp), name: NSWorkspace.screensDidWakeNotification, object: nil)
        ws.addObserver(self, selector: #selector(wakeUp), name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
        ws.addObserver(self, selector: #selector(goSleep), name: NSWorkspace.willSleepNotification, object: nil)
        ws.addObserver(self, selector: #selector(wakeUp), name: NSWorkspace.didWakeNotification, object: nil)

        startTimer()
        if defaults.bool(forKey: "real") { startRealWeather() }

        if !defaults.bool(forKey: "tipHover") {
            defaults.set(true, forKey: "tipHover")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.showHelp() }
        }
    }

    // MARK: Таймер и сон

    func startTimer() {
        timer?.invalidate()
        last = CACurrentMediaTime()
        let tm = Timer(timeInterval: 1.0 / Double(fps), repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(tm, forMode: .common)
        timer = tm
        views.forEach { $0.preferredFramesPerSecond = fps }
    }

    @objc func goSleep() {
        sleeping = true
        timer?.invalidate()
        timer = nil
        views.forEach { $0.isPaused = true }
    }

    @objc func wakeUp() {
        sleeping = false
        // после сна окна со снегом создаём заново: старые могут перестать рисоваться
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self = self, !self.sleeping else { return }
            self.buildOverlays()
            self.sim.windowsMoved = true
            self.wasIdle = false
            if !self.hiddenAll { self.startTimer() }
            if self.defaults.bool(forKey: "real") { self.refreshWeather() }
        }
    }

    @objc func screensChanged() { buildOverlays() }

    func buildOverlays() {
        overlays.forEach { $0.orderOut(nil) }
        overlays.removeAll()
        views.removeAll()
        scenes.removeAll()
        sim.updateScreens()
        sim.windowsMoved = true

        for screen in NSScreen.screens {
            let w = NSPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            w.hidesOnDeactivate = false
            w.becomesKeyOnlyIfNeeded = true
            w.setFrame(screen.frame, display: false)
            w.isOpaque = false
            w.backgroundColor = .clear
            w.hasShadow = false
            w.ignoresMouseEvents = true
            w.level = .screenSaver
            w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
            w.isReleasedWhenClosed = false
            let v = SnowSKView(frame: NSRect(origin: .zero, size: screen.frame.size))
            v.allowsTransparency = true
            v.ignoresSiblingOrder = true
            v.preferredFramesPerSecond = fps
            v.wantsLayer = true
            v.layer?.backgroundColor = .clear
            let scene = SnowScene(sim: sim, q: Sim.quartzRect(screen.frame))
            v.presentScene(scene)
            scenes.append(scene)
            w.contentView = v
            if !hiddenAll { w.orderFrontRegardless() }
            overlays.append(w)
            views.append(v)
        }
    }

    // MARK: Настройки

    func loadSettings() {
        defaults.register(defaults: ["intensity": 1.0, "wind": 1.0, "size": 1.0, "play": true, "eco": false,
                                     "weather": 0, "real": false, "icicles": true, "frost": true,
                                     "garland": false, "newYear": true, "sound": true])
        sim.playEnabled = defaults.bool(forKey: "play")
        sim.intensity = CGFloat(defaults.double(forKey: "intensity"))
        sim.windStrength = CGFloat(defaults.double(forKey: "wind"))
        sim.flakeSize = CGFloat(defaults.double(forKey: "size"))
        sim.weather = WeatherKind(rawValue: defaults.integer(forKey: "weather")) ?? .snow
        sim.fx.icicles = defaults.bool(forKey: "icicles")
        sim.fx.frostOn = defaults.bool(forKey: "frost")
        sim.fx.garland = defaults.bool(forKey: "garland")
        sim.fx.newYear = defaults.bool(forKey: "newYear")
        SoundBox.shared.enabled = defaults.bool(forKey: "sound")
    }

    // MARK: Меню

    let hotMods: NSEvent.ModifierFlags = [.control, .option, .command]

    func item(_ key: String, _ title: String, _ action: Selector, hot: String = "", in menu: NSMenu) -> NSMenuItem {
        let it = NSMenuItem(title: title, action: action, keyEquivalent: hot)
        if !hot.isEmpty { it.keyEquivalentModifierMask = hotMods }
        it.target = self
        menu.addItem(it)
        if !key.isEmpty { items[key] = it }
        return it
    }

    func buildMenu() {
        loadSettings()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "❄︎"
        let menu = NSMenu()
        menu.autoenablesItems = false

        menu.addItem(sliderItem(tag: 0, min: 0, max: 4, value: Double(sim.intensity), action: #selector(intensityChanged(_:))))
        menu.addItem(sliderItem(tag: 1, min: 0, max: 4, value: Double(sim.windStrength), action: #selector(windChanged(_:))))
        menu.addItem(sliderItem(tag: 2, min: 0.5, max: 2.5, value: Double(sim.flakeSize), action: #selector(sizeChanged(_:))))
        menu.addItem(.separator())

        // Погода
        let wMenu = NSMenu()
        wMenu.autoenablesItems = false
        for k in WeatherKind.allCases {
            let it = NSMenuItem(title: k.title, action: #selector(pickWeather(_:)), keyEquivalent: "")
            it.tag = k.rawValue
            it.target = self
            wMenu.addItem(it)
            weatherItems.append(it)
        }
        wMenu.addItem(.separator())
        _ = item("real", "Реальная погода за окном", #selector(toggleReal), in: wMenu)
        _ = item("city", "Город…", #selector(askCity), in: wMenu)
        let status = item("wstatus", "", #selector(noop), in: wMenu)
        status.isEnabled = false
        status.isHidden = true
        let wRoot = NSMenuItem(title: "Погода", action: nil, keyEquivalent: "")
        wRoot.submenu = wMenu
        menu.addItem(wRoot)

        // Эффекты
        let eMenu = NSMenu()
        eMenu.autoenablesItems = false
        _ = item("icicles", "Сосульки", #selector(toggleIcicles), in: eMenu)
        _ = item("frost", "Иней, пока ты не трогаешь Мак", #selector(toggleFrost), in: eMenu)
        _ = item("garland", "Гирлянда на активном окне", #selector(toggleGarland), in: eMenu)
        _ = item("newYear", "Новогодний отсчёт и салют в полночь", #selector(toggleNewYear), in: eMenu)
        _ = item("", "Салют сейчас!", #selector(fireworksNow), hot: "f", in: eMenu)
        let eRoot = NSMenuItem(title: "Эффекты", action: nil, keyEquivalent: "")
        eRoot.submenu = eMenu
        menu.addItem(eRoot)
        menu.addItem(.separator())

        _ = item("fight", "Снежная битва", #selector(toggleFight), hot: "b", in: menu)
        _ = item("play", "Лепить снежки мышкой", #selector(togglePlay), in: menu)
        _ = item("", "Как играть…", #selector(showHelp), in: menu)
        menu.addItem(.separator())

        _ = item("sound", "Звук", #selector(toggleSound), in: menu)
        _ = item("eco", "Экономия энергии (30 кадров/с)", #selector(toggleEco), in: menu)
        _ = item("pause", "Пауза", #selector(togglePause), hot: "s", in: menu)
        _ = item("hide", "Скрыть всё", #selector(toggleHide), hot: "h", in: menu)
        _ = item("", "Убрать весь снег", #selector(clearSnow), hot: "c", in: menu)
        _ = item("", "Горячие клавиши…", #selector(showHotKeys), in: menu)
        menu.addItem(.separator())
        _ = item("login", "Запускать при входе в систему", #selector(toggleLogin), in: menu)
        let quitItem = item("", "Выход", #selector(quit), hot: "q", in: menu)
        quitItem.keyEquivalentModifierMask = [.command]

        statusItem.menu = menu
        refreshLabels()
        refreshMenuState()
        refreshLoginState()
    }

    func refreshMenuState() {
        let real = defaults.bool(forKey: "real")
        for it in weatherItems {
            it.state = it.tag == sim.weather.rawValue ? .on : .off
            it.isEnabled = !real
        }
        items["real"]?.state = real ? .on : .off
        let city = defaults.string(forKey: "city") ?? ""
        items["city"]?.title = city.isEmpty ? "Город…" : "Город: \(city)…"
        items["icicles"]?.state = sim.fx.icicles ? .on : .off
        items["frost"]?.state = sim.fx.frostOn ? .on : .off
        items["garland"]?.state = sim.fx.garland ? .on : .off
        items["newYear"]?.state = sim.fx.newYear ? .on : .off
        items["fight"]?.state = sim.fx.fight ? .on : .off
        items["play"]?.state = sim.playEnabled ? .on : .off
        items["sound"]?.state = SoundBox.shared.enabled ? .on : .off
        items["eco"]?.state = defaults.bool(forKey: "eco") ? .on : .off
        items["pause"]?.state = sim.paused ? .on : .off
        items["hide"]?.title = hiddenAll ? "Показать всё" : "Скрыть всё"
    }

    func sliderItem(tag: Int, min: Double, max: Double, value: Double, action: Selector) -> NSMenuItem {
        let v = NSView(frame: NSRect(x: 0, y: 0, width: 250, height: 48))
        let label = NSTextField(labelWithString: "")
        label.frame = NSRect(x: 20, y: 26, width: 215, height: 17)
        label.font = NSFont.menuFont(ofSize: 13)
        let slider = NSSlider(value: value, minValue: min, maxValue: max, target: self, action: action)
        slider.frame = NSRect(x: 18, y: 4, width: 215, height: 22)
        slider.isContinuous = true
        slider.controlSize = .small
        v.addSubview(label)
        v.addSubview(slider)
        labels[tag] = label
        sliders[tag] = slider
        let item = NSMenuItem()
        item.view = v
        return item
    }

    func refreshLabels() {
        let what = sim.weather == .snow ? "снега" : (sim.weather == .rain ? "дождя" : (sim.weather == .leaves ? "листопада" : "лепестков"))
        labels[0]?.stringValue = sim.intensity < 0.02 ? "Сила \(what): выкл" : "Сила \(what): \(Int((sim.intensity * 100).rounded()))%"
        labels[1]?.stringValue = sim.windStrength < 0.02 ? "Ветер: штиль" : "Ветер: \(Int((sim.windStrength * 100).rounded()))%"
        labels[2]?.stringValue = "Размер: \(Int((sim.flakeSize * 100).rounded()))%"
    }

    @objc func noop() {}

    @objc func intensityChanged(_ s: NSSlider) {
        sim.intensity = CGFloat(s.doubleValue)
        defaults.set(s.doubleValue, forKey: "intensity")
        refreshLabels()
    }
    @objc func windChanged(_ s: NSSlider) {
        sim.windStrength = CGFloat(s.doubleValue)
        defaults.set(s.doubleValue, forKey: "wind")
        refreshLabels()
    }
    @objc func sizeChanged(_ s: NSSlider) {
        sim.flakeSize = CGFloat(s.doubleValue)
        defaults.set(s.doubleValue, forKey: "size")
        refreshLabels()
    }

    func nudgeIntensity(_ d: CGFloat) {
        sim.intensity = min(4, max(0, sim.intensity + d))
        defaults.set(Double(sim.intensity), forKey: "intensity")
        sliders[0]?.doubleValue = Double(sim.intensity)
        refreshLabels()
    }

    // MARK: Погода

    @objc func pickWeather(_ it: NSMenuItem) {
        guard let k = WeatherKind(rawValue: it.tag) else { return }
        setWeather(k)
    }

    func setWeather(_ k: WeatherKind) {
        sim.weather = k
        defaults.set(k.rawValue, forKey: "weather")
        refreshLabels()
        refreshMenuState()
    }

    func cycleWeather() {
        guard !defaults.bool(forKey: "real") else { return }
        let all = WeatherKind.allCases
        let i = all.firstIndex(of: sim.weather) ?? 0
        setWeather(all[(i + 1) % all.count])
    }

    @objc func toggleReal() {
        let on = !defaults.bool(forKey: "real")
        if on && (defaults.string(forKey: "city") ?? "").isEmpty {
            askCity()
            return
        }
        defaults.set(on, forKey: "real")
        if on { startRealWeather() } else { stopRealWeather() }
        refreshMenuState()
    }

    func startRealWeather() {
        weatherTimer?.invalidate()
        let t = Timer(timeInterval: 15 * 60, repeats: true) { [weak self] _ in self?.refreshWeather() }
        RunLoop.main.add(t, forMode: .common)
        weatherTimer = t
        refreshWeather()
    }

    func stopRealWeather() {
        weatherTimer?.invalidate()
        weatherTimer = nil
        sim.weather = WeatherKind(rawValue: defaults.integer(forKey: "weather")) ?? .snow
        sim.envIntensity = 1
        sim.envWind = 1
        sim.melting = false
        items["wstatus"]?.isHidden = true
        refreshLabels()
    }

    func refreshWeather() {
        let city = defaults.string(forKey: "city") ?? ""
        guard !city.isEmpty else { return }
        RealWeather.fetch(city: city, lat: defaults.double(forKey: "lat"), lon: defaults.double(forKey: "lon")) { [weak self] rep in
            guard let self = self, self.defaults.bool(forKey: "real") else { return }
            guard let rep = rep else {
                self.items["wstatus"]?.title = "Не удалось узнать погоду — проверь интернет"
                self.items["wstatus"]?.isHidden = false
                return
            }
            self.sim.weather = rep.kind
            self.sim.envIntensity = rep.intensity
            self.sim.envWind = rep.wind
            self.sim.melting = rep.melting
            self.items["wstatus"]?.title = rep.text
            self.items["wstatus"]?.isHidden = false
            self.refreshLabels()
            self.refreshMenuState()
        }
    }

    @objc func askCity() {
        let a = NSAlert()
        a.messageText = "Твой город"
        a.informativeText = "Снег будет идти, когда он идёт за окном. Погода берётся с open-meteo.com раз в 15 минут."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = defaults.string(forKey: "city") ?? ""
        field.placeholderString = "Например: Москва"
        a.accessoryView = field
        a.addButton(withTitle: "Готово")
        a.addButton(withTitle: "Отмена")
        NSApp.activate(ignoringOtherApps: true)
        a.window.initialFirstResponder = field
        guard a.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        RealWeather.geocode(name) { [weak self] res in
            guard let self = self else { return }
            guard let (title, lat, lon) = res else {
                let e = NSAlert()
                e.messageText = "Не нашла город «\(name)»"
                e.informativeText = "Попробуй написать по-другому, например по-английски, или проверь интернет."
                NSApp.activate(ignoringOtherApps: true)
                e.runModal()
                return
            }
            self.defaults.set(title, forKey: "city")
            self.defaults.set(lat, forKey: "lat")
            self.defaults.set(lon, forKey: "lon")
            self.defaults.set(true, forKey: "real")
            self.startRealWeather()
            self.refreshMenuState()
        }
    }

    // MARK: Эффекты

    @objc func toggleIcicles() {
        sim.fx.icicles.toggle()
        defaults.set(sim.fx.icicles, forKey: "icicles")
        refreshMenuState()
    }
    @objc func toggleFrost() {
        sim.fx.frostOn.toggle()
        defaults.set(sim.fx.frostOn, forKey: "frost")
        refreshMenuState()
    }
    @objc func toggleGarland() {
        sim.fx.garland.toggle()
        defaults.set(sim.fx.garland, forKey: "garland")
        refreshMenuState()
    }
    @objc func toggleNewYear() {
        sim.fx.newYear.toggle()
        defaults.set(sim.fx.newYear, forKey: "newYear")
        refreshMenuState()
    }
    @objc func fireworksNow() { sim.startFireworks(20) }

    @objc func toggleFight() {
        sim.fx.fight.toggle()
        if sim.fx.fight {
            sim.fx.scoreMe = 0
            sim.fx.scoreThem = 0
            sim.fx.enemyTimer = 1.5
            if !sim.playEnabled { togglePlay() }
        }
        refreshMenuState()
    }

    @objc func togglePlay() {
        sim.playEnabled.toggle()
        defaults.set(sim.playEnabled, forKey: "play")
        refreshMenuState()
    }

    @objc func toggleSound() {
        SoundBox.shared.enabled.toggle()
        defaults.set(SoundBox.shared.enabled, forKey: "sound")
        refreshMenuState()
    }

    @objc func toggleEco() {
        defaults.set(!defaults.bool(forKey: "eco"), forKey: "eco")
        if !sleeping && !hiddenAll { startTimer() }
        refreshMenuState()
    }

    @objc func togglePause() {
        sim.paused.toggle()
        refreshMenuState()
    }

    @objc func toggleHide() {
        hiddenAll.toggle()
        if hiddenAll {
            overlays.forEach { $0.orderOut(nil) }
            timer?.invalidate()
            timer = nil
        } else {
            overlays.forEach { $0.orderFrontRegardless() }
            if !sleeping { startTimer() }
        }
        refreshMenuState()
    }

    @objc func clearSnow() { sim.clearAll() }

    // MARK: Горячие клавиши

    func registerHotKeys() {
        HotKeys.register(1, key: kVK_ANSI_S) { [weak self] in self?.togglePause() }
        HotKeys.register(2, key: kVK_ANSI_H) { [weak self] in self?.toggleHide() }
        HotKeys.register(3, key: kVK_ANSI_C) { [weak self] in self?.clearSnow() }
        HotKeys.register(4, key: kVK_UpArrow) { [weak self] in self?.nudgeIntensity(0.25) }
        HotKeys.register(5, key: kVK_DownArrow) { [weak self] in self?.nudgeIntensity(-0.25) }
        HotKeys.register(6, key: kVK_ANSI_W) { [weak self] in self?.cycleWeather() }
        HotKeys.register(7, key: kVK_ANSI_B) { [weak self] in self?.toggleFight() }
        HotKeys.register(8, key: kVK_ANSI_F) { [weak self] in self?.fireworksNow() }
    }

    @objc func showHotKeys() {
        let a = NSAlert()
        a.messageText = "Горячие клавиши"
        a.informativeText = """
        Работают из любой программы. Везде зажаты ⌃ Control + ⌥ Option + ⌘ Command:

        ⌃⌥⌘ S — пауза / продолжить
        ⌃⌥⌘ H — скрыть всё / показать
        ⌃⌥⌘ C — убрать весь снег
        ⌃⌥⌘ ↑ / ↓ — сильнее / слабее
        ⌃⌥⌘ W — следующая погода
        ⌃⌥⌘ B — снежная битва
        ⌃⌥⌘ F — салют
        """
        NSApp.activate(ignoringOtherApps: true)
        a.runModal()
    }

    @objc func showHelp() {
        let a = NSAlert()
        a.messageText = "Как играть со снегом"
        a.informativeText = """
        Наведи курсор на снег на окне или внизу экрана — вокруг курсора появится колечко. Значит, снег можно взять.

        • Зажми кнопку мыши на сугробе — получится снежок.
        • Катай его по снегу — он будет расти.
        • Отпусти с размахом — снежок полетит и разобьётся.
        • Отпусти спокойно над окном — снежок ляжет на него.
        • Положи ком поменьше на большой — у него появится лицо, а с третьим комом выйдет снеговик в шляпе.
        • Резко махни курсором по снегу — сметёшь его.
        • Под снегом на окнах растут сосульки: кликни по сосульке — отломится, дёрни окно — посыплются.

        Снежная битва (⌃⌥⌘ B): из-за краёв экрана летят снежки в курсор. Кликни по летящему снежку — отбил, +1 тебе. Не успела — +1 противнику. Бросай свои снежки в края экрана — тоже +1. Счёт виден рядом с ❄︎.

        Клики мимо снега работают как обычно.
        """
        NSApp.activate(ignoringOtherApps: true)
        a.runModal()
    }

    @objc func quit() { NSApp.terminate(nil) }

    func refreshLoginState() {
        if #available(macOS 13.0, *) {
            items["login"]?.state = SMAppService.mainApp.status == .enabled ? .on : .off
        } else {
            items["login"]?.isHidden = true
        }
    }

    @objc func toggleLogin() {
        guard #available(macOS 13.0, *) else { return }
        let svc = SMAppService.mainApp
        do {
            if svc.status == .enabled { try svc.unregister() } else { try svc.register() }
        } catch {
            let a = NSAlert()
            a.messageText = "Не получилось включить автозапуск"
            a.informativeText = "Переложи Snow.app в папку «Программы» и попробуй ещё раз.\n\n\(error.localizedDescription)"
            NSApp.activate(ignoringOtherApps: true)
            a.runModal()
        }
        refreshLoginState()
    }

    // MARK: Кадр

    func tick() {
        let now = CACurrentMediaTime()
        let dt = CGFloat(min(now - last, 1.0 / 20.0))
        last = now
        sim.step(dt)
        let ignore = !sim.interactive
        for w in overlays where w.ignoresMouseEvents != ignore { w.ignoresMouseEvents = ignore }

        // счёт снежной битвы рядом со снежинкой в строке меню
        let title = sim.fx.fight ? "❄︎ \(sim.fx.scoreMe):\(sim.fx.scoreThem)" : "❄︎"
        if title != lastTitle {
            statusItem.button?.title = title
            lastTitle = title
        }

        frameNo += 1
        if sim.isIdle {
            // ничего не движется — один последний кадр, и видеокарта отдыхает
            if !wasIdle { scenes.forEach { $0.sync(piles: true) } }
            else { views.forEach { if !$0.isPaused { $0.isPaused = true } } }
            wasIdle = true
            return
        }
        wasIdle = false
        let piles = sim.windowsMoved || sim.fx.dirty || frameNo % 6 == 0
        sim.windowsMoved = false
        scenes.forEach { $0.sync(piles: piles) }
        views.forEach { if $0.isPaused { $0.isPaused = false } }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
