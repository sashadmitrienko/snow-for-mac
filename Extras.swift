// Extras.swift — погода, сосульки, снежная битва, иней, Новый год, звук, горячие клавиши.

import Cocoa
import SpriteKit
import Carbon.HIToolbox

// MARK: - Погода

enum WeatherKind: Int, CaseIterable {
    case snow = 0, rain, leaves, sakura
    var title: String {
        switch self {
        case .snow: return "Снег"
        case .rain: return "Дождь"
        case .leaves: return "Листопад"
        case .sakura: return "Сакура"
        }
    }
}

/// Из чего сделана частица.
enum Mat {
    static let snow: UInt8 = 0
    static let rain: UInt8 = 1
    static let leaf: UInt8 = 2
    static let petal: UInt8 = 3
}

// MARK: - Состояние новых эффектов

struct Icicle {
    var relX: CGFloat
    var len: CGFloat
    var maxLen: CGFloat
    var w: CGFloat
    var rate: CGFloat
}

struct FallingIcicle {
    var x: CGFloat, y: CGFloat      // y — верх сосульки
    var vx: CGFloat, vy: CGFloat
    var len: CGFloat, w: CGFloat
    var rot: CGFloat
}

struct Litter {                      // лежащий лист или лепесток
    var sid: Int
    var relX: CGFloat
    var kind: Int
    var r: CGFloat
    var rot: CGFloat
    var age: CGFloat = 0
}

struct Spark {
    var x: CGFloat, y: CGFloat
    var vx: CGFloat, vy: CGFloat
    var life: CGFloat
    var maxLife: CGFloat
    var color: Int
    var rocket: Bool
    var size: CGFloat
    var kind: UInt8 = 0       // 0 обычная, 1 со шлейфом, 2 мерцает, 3 крестовик, 4 ива, 5 вспышка, 6 дочерний заряд
    var drag: CGFloat = 1.6
    var grav: CGFloat = 160
    var alpha: CGFloat = 1
}

final class SimFX {
    var icicles = true
    var falling: [FallingIcicle] = []
    var litter: [Litter] = []
    var sparks: [Spark] = []
    var fireworksUntil: CGFloat = -1
    var rocketAcc: CGFloat = 0
    var fight = false
    var scoreMe = 0
    var scoreThem = 0
    var enemyTimer: CGFloat = 2
    var frostOn = true
    var frost: CGFloat = 0
    var frostChanging = false
    var idleSeconds: Double = 0
    var idleAcc: CGFloat = 1
    var garland = false
    var garlandRect: CGRect? = nil
    var newYear = true
    var countdown: String? = nil
    var clockAcc: CGFloat = 1
    var iceAcc: CGFloat = 0
    var crunchCooldown: CGFloat = 0
    var dirty = false               // что-то поменялось без движения частиц (таяние)
}

// MARK: - Звук (синтезируется на лету, файлов не нужно)

enum Sfx: CaseIterable {
    case crunch, plop, hit, shatter, boom, crackle, whistle
}

final class SoundBox {
    static let shared = SoundBox()
    var enabled = true
    var volume: Float = 0.5
    private var sounds: [Sfx: [NSSound]] = [:]
    private var next: [Sfx: Int] = [:]
    private var last: [Sfx: CFTimeInterval] = [:]

    private init() {
        for s in Sfx.allCases {
            let data = SoundBox.wav(SoundBox.synth(s))
            sounds[s] = (0..<4).compactMap { _ in NSSound(data: data) }
        }
    }

    func play(_ s: Sfx, gain: Float = 1) {
        guard enabled, let arr = sounds[s], !arr.isEmpty else { return }
        let now = CACurrentMediaTime()
        if let l = last[s], now - l < 0.07 { return }
        last[s] = now
        let i = (next[s] ?? 0) % arr.count
        next[s] = i + 1
        let snd = arr[i]
        snd.stop()
        snd.volume = max(0, min(1, volume * gain))
        snd.play()
    }

    static let rate: Double = 44100

    static func synth(_ s: Sfx) -> [Float] {
        var out: [Float] = []
        func noise() -> Float { Float.random(in: -1...1) }
        switch s {
        case .crunch:                       // хруст снега
            let n = Int(rate * 0.16)
            var lp: Float = 0
            for i in 0..<n {
                let t = Float(i) / Float(n)
                let env = (1 - t) * (1 - t)
                let crack: Float = Float.random(in: 0...1) < 0.05 ? 3 : 1
                lp += (noise() - lp) * 0.35
                out.append(lp * env * crack * 0.6)
            }
        case .plop, .hit:                   // шлепок снежка
            let n = Int(rate * (s == .hit ? 0.3 : 0.2))
            var ph: Float = 0
            var lp: Float = 0
            for i in 0..<n {
                let t = Float(i) / Float(n)
                let f = 210 - 150 * t
                ph += 2 * .pi * f / Float(rate)
                lp += (noise() - lp) * 0.18
                let env = exp(-t * 6)
                out.append((sin(ph) * 0.55 + lp * (s == .hit ? 1.0 : 0.6)) * env)
            }
        case .shatter:                      // звон сосульки
            let n = Int(rate * 0.55)
            let base: [Float] = [2300, 3150, 4200, 5350, 6400]
            let freqs: [Float] = base.map { $0 * Float.random(in: 0.93...1.07) }
            let starts: [Float] = [0, 0.01, 0.03, 0.05, 0.08]
            var hp: Float = 0
            var prev: Float = 0
            for i in 0..<n {
                let t = Float(i) / Float(rate)
                var v: Float = 0
                for (k, f) in freqs.enumerated() where t >= starts[k] {
                    let tt = t - starts[k]
                    v += sin(2 * .pi * f * tt) * exp(-tt * (9 + Float(k) * 3)) * 0.25
                }
                let x = noise()
                hp = 0.7 * (hp + x - prev)
                prev = x
                v += hp * exp(-t * 30) * 0.6
                out.append(v)
            }
        case .crackle:                      // треск блёсток: щелчки после паузы
            let n = Int(rate * 1.4)
            out = [Float](repeating: 0, count: n)
            let start = Int(rate * 0.35)
            var i = start
            while i < n - 200 {
                let t = Float(i - start) / Float(n - start)
                let amp = Float.random(in: 0.3...1) * (1 - t)
                for j in 0..<Int.random(in: 60...160) where i + j < n {
                    out[i + j] += noise() * amp * exp(-Float(j) / 40)
                }
                i += Int(Float.random(in: 150...900) * (1 + t * 2))
            }
        case .whistle:                      // свист ракеты
            let n = Int(rate * 0.9)
            var ph: Float = 0
            for i in 0..<n {
                let t = Float(i) / Float(n)
                let f = 900 + 1300 * t + sin(t * 60) * 40
                ph += 2 * .pi * f / Float(rate)
                let env = min(1, t * 8) * (1 - t)
                out.append(sin(ph) * env * 0.5 + noise() * 0.05 * env)
            }
        case .boom:                         // салют
            let n = Int(rate * 1.3)
            var lp: Float = 0
            var ph: Float = 0
            for i in 0..<n {
                let t = Float(i) / Float(n)
                lp += (noise() - lp) * 0.05
                ph += 2 * .pi * (65 - 35 * t) / Float(rate)
                out.append((lp * 2.6 + sin(ph) * 0.6 * exp(-t * 9)) * exp(-t * 4))
            }
        }
        let peak = out.map { abs($0) }.max() ?? 1
        if peak > 0 { out = out.map { $0 / peak * 0.9 } }
        return out
    }

    static func wav(_ s: [Float]) -> Data {
        var d = Data()
        func u32(_ v: UInt32) { var x = v.littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { var x = v.littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        let dataSize = UInt32(s.count * 2)
        d.append(contentsOf: Array("RIFF".utf8)); u32(36 + dataSize); d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(1); u32(44100); u32(44100 * 2); u16(2); u16(16)
        d.append(contentsOf: Array("data".utf8)); u32(dataSize)
        for v in s { u16(UInt16(bitPattern: Int16(max(-1, min(1, v)) * 32767))) }
        return d
    }
}

// MARK: - Горячие клавиши (работают из любой программы, разрешений не требуют)

enum HotKeys {
    static var handlers: [UInt32: () -> Void] = [:]
    static var refs: [EventHotKeyRef?] = []
    static var installed = false

    static func install() {
        guard !installed else { return }
        installed = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { (_: EventHandlerCallRef?, event: EventRef?, _: UnsafeMutableRawPointer?) -> OSStatus in
            var hk = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
            let id = hk.id
            DispatchQueue.main.async { HotKeys.handlers[id]?() }
            return noErr
        }, 1, &spec, nil, nil)
    }

    /// Регистрирует ⌃⌥⌘ + клавиша.
    static func register(_ id: UInt32, key: Int, _ fn: @escaping () -> Void) {
        install()
        handlers[id] = fn
        var ref: EventHotKeyRef?
        let hkid = EventHotKeyID(signature: OSType(0x534E_4F57), id: id)   // 'SNOW'
        let mods = UInt32(cmdKey | optionKey | controlKey)
        RegisterEventHotKey(UInt32(key), mods, hkid, GetApplicationEventTarget(), 0, &ref)
        refs.append(ref)
    }
}

// MARK: - Реальная погода (Open-Meteo, без ключей и регистрации)

struct WeatherReport {
    let kind: WeatherKind
    let intensity: CGFloat      // 0 — ничего не падает
    let wind: CGFloat
    let temp: Double
    let melting: Bool
    let text: String
}

enum RealWeather {
    static func geocode(_ name: String, done: @escaping ((String, Double, Double)?) -> Void) {
        var c = URLComponents(string: "https://geocoding-api.open-meteo.com/v1/search")!
        c.queryItems = [URLQueryItem(name: "name", value: name),
                        URLQueryItem(name: "count", value: "1"),
                        URLQueryItem(name: "language", value: "ru")]
        guard let url = c.url else { done(nil); return }
        URLSession.shared.dataTask(with: url) { data, _, _ in
            var res: (String, Double, Double)? = nil
            if let data = data,
               let j = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
               let arr = j["results"] as? [[String: Any]], let f = arr.first,
               let la = (f["latitude"] as? NSNumber)?.doubleValue,
               let lo = (f["longitude"] as? NSNumber)?.doubleValue {
                res = ((f["name"] as? String) ?? name, la, lo)
            }
            DispatchQueue.main.async { done(res) }
        }.resume()
    }

    static func fetch(city: String, lat: Double, lon: Double, done: @escaping (WeatherReport?) -> Void) {
        var c = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        c.queryItems = [URLQueryItem(name: "latitude", value: String(lat)),
                        URLQueryItem(name: "longitude", value: String(lon)),
                        URLQueryItem(name: "current", value: "temperature_2m,weather_code,wind_speed_10m")]
        guard let url = c.url else { done(nil); return }
        URLSession.shared.dataTask(with: url) { data, _, _ in
            var rep: WeatherReport? = nil
            if let data = data,
               let j = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
               let cur = j["current"] as? [String: Any],
               let temp = (cur["temperature_2m"] as? NSNumber)?.doubleValue,
               let code = (cur["weather_code"] as? NSNumber)?.intValue {
                let windKmh = (cur["wind_speed_10m"] as? NSNumber)?.doubleValue ?? 5
                let (kind, inten, desc) = RealWeather.map(code: code, temp: temp)
                let t = String(format: "%+.0f°", temp).replacingOccurrences(of: "-", with: "−")
                rep = WeatherReport(kind: kind, intensity: inten,
                                    wind: CGFloat(max(0.1, min(4, windKmh / 12))),
                                    temp: temp, melting: temp > 1,
                                    text: "\(city): \(t), \(desc)")
            }
            DispatchQueue.main.async { done(rep) }
        }.resume()
    }

    /// Код погоды WMO → что показывать.
    static func map(code: Int, temp: Double) -> (WeatherKind, CGFloat, String) {
        switch code {
        case 71: return (.snow, 0.5, "небольшой снег")
        case 73: return (.snow, 1.0, "снег")
        case 75: return (.snow, 2.2, "сильный снег")
        case 77: return (.snow, 0.4, "снежная крупа")
        case 85: return (.snow, 1.0, "снегопад")
        case 86: return (.snow, 2.0, "сильный снегопад")
        case 51, 53, 55: return (.rain, 0.5, "морось")
        case 56, 57: return (.rain, 0.6, "ледяная морось")
        case 61: return (.rain, 0.8, "небольшой дождь")
        case 63: return (.rain, 1.5, "дождь")
        case 65: return (.rain, 2.5, "сильный дождь")
        case 66, 67: return (.rain, 1.2, "ледяной дождь")
        case 80: return (.rain, 1.0, "ливень")
        case 81: return (.rain, 1.8, "сильный ливень")
        case 82: return (.rain, 2.8, "очень сильный ливень")
        case 95, 96, 99: return (.rain, 2.5, "гроза")
        case 45, 48: return (temp <= 0 ? .snow : .rain, 0, "туман")
        case 0: return (temp <= 0 ? .snow : .rain, 0, "ясно")
        default: return (temp <= 0 ? .snow : .rain, 0, "облачно")
        }
    }
}

// MARK: - Картинки для новых эффектов

enum TexX {
    static func image(w: Int, h: Int, _ draw: (CGContext, CGFloat, CGFloat) -> Void) -> CGImage {
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: Tex.rgb, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        draw(ctx, CGFloat(w), CGFloat(h))
        return ctx.makeImage()!
    }

    /// Доп. частицы в атласе: 5–7 листья, 8 лепесток, 9 капля.
    static func extraFlakeImage(_ v: Int) -> CGImage {
        switch v {
        case 5: return leafImage(CGColor(red: 0.93, green: 0.50, blue: 0.12, alpha: 1), CGColor(red: 0.75, green: 0.35, blue: 0.05, alpha: 0.8))
        case 6: return leafImage(CGColor(red: 0.80, green: 0.18, blue: 0.12, alpha: 1), CGColor(red: 0.55, green: 0.08, blue: 0.05, alpha: 0.8))
        case 7: return leafImage(CGColor(red: 0.95, green: 0.76, blue: 0.20, alpha: 1), CGColor(red: 0.75, green: 0.55, blue: 0.08, alpha: 0.8))
        case 8: return petalImage()
        default: return rainImage()
        }
    }

    static func leafImage(_ color: CGColor, _ vein: CGColor) -> CGImage {
        Tex.image(64) { ctx, s in
            let p = CGMutablePath()
            p.move(to: CGPoint(x: s * 0.5, y: s * 0.06))
            p.addQuadCurve(to: CGPoint(x: s * 0.5, y: s * 0.94), control: CGPoint(x: s * 1.02, y: s * 0.42))
            p.addQuadCurve(to: CGPoint(x: s * 0.5, y: s * 0.06), control: CGPoint(x: -s * 0.02, y: s * 0.42))
            ctx.setFillColor(color)
            ctx.addPath(p)
            ctx.fillPath()
            ctx.setStrokeColor(CGColor(red: 0.2, green: 0.08, blue: 0.02, alpha: 0.35))
            ctx.setLineWidth(s * 0.03)
            ctx.addPath(p)
            ctx.strokePath()
            ctx.setStrokeColor(vein)
            ctx.setLineWidth(s * 0.035)
            ctx.move(to: CGPoint(x: s * 0.5, y: 0))
            ctx.addLine(to: CGPoint(x: s * 0.5, y: s * 0.86))
            for k in 1...3 {
                let y = s * (0.25 + CGFloat(k) * 0.15)
                ctx.move(to: CGPoint(x: s * 0.5, y: y - s * 0.08))
                ctx.addLine(to: CGPoint(x: s * 0.3, y: y + s * 0.04))
                ctx.move(to: CGPoint(x: s * 0.5, y: y - s * 0.08))
                ctx.addLine(to: CGPoint(x: s * 0.7, y: y + s * 0.04))
            }
            ctx.strokePath()
        }
    }

    static func petalImage() -> CGImage {
        Tex.image(64) { ctx, s in
            let p = CGMutablePath()
            p.move(to: CGPoint(x: s * 0.5, y: s * 0.08))
            p.addCurve(to: CGPoint(x: s * 0.42, y: s * 0.9),
                       control1: CGPoint(x: s * 0.05, y: s * 0.3), control2: CGPoint(x: s * 0.1, y: s * 0.85))
            p.addLine(to: CGPoint(x: s * 0.5, y: s * 0.8))
            p.addLine(to: CGPoint(x: s * 0.58, y: s * 0.9))
            p.addCurve(to: CGPoint(x: s * 0.5, y: s * 0.08),
                       control1: CGPoint(x: s * 0.9, y: s * 0.85), control2: CGPoint(x: s * 0.95, y: s * 0.3))
            ctx.saveGState()
            ctx.addPath(p)
            ctx.clip()
            ctx.drawLinearGradient(Tex.gradient(CGColor(red: 1, green: 0.62, blue: 0.75, alpha: 1),
                                                CGColor(red: 1, green: 0.90, blue: 0.93, alpha: 1)),
                                   start: CGPoint(x: 0, y: s * 0.1), end: CGPoint(x: 0, y: s * 0.9), options: [])
            ctx.restoreGState()
            ctx.setStrokeColor(CGColor(red: 0.75, green: 0.3, blue: 0.45, alpha: 0.35))
            ctx.setLineWidth(s * 0.025)
            ctx.addPath(p)
            ctx.strokePath()
        }
    }

    static func rainImage() -> CGImage {
        // атлас квадратный, поэтому капля рисуется узкой полоской по центру квадрата
        Tex.image(64) { ctx, s in
            let r = CGRect(x: s * 0.44, y: 0, width: s * 0.12, height: s)
            ctx.saveGState()
            ctx.addPath(CGPath(roundedRect: r, cornerWidth: s * 0.06, cornerHeight: s * 0.06, transform: nil))
            ctx.clip()
            ctx.drawLinearGradient(Tex.gradient(CGColor(red: 0.80, green: 0.88, blue: 1, alpha: 0.85),
                                                CGColor(red: 0.80, green: 0.88, blue: 1, alpha: 0)),
                                   start: CGPoint(x: 0, y: 0), end: CGPoint(x: 0, y: s), options: [])
            ctx.restoreGState()
        }
    }

    static let icicle: SKTexture = {
        let img = TexX.image(w: 24, h: 96) { ctx, W, H in
            let p = CGMutablePath()
            p.move(to: CGPoint(x: 1, y: H))
            p.addLine(to: CGPoint(x: W - 1, y: H))
            p.addQuadCurve(to: CGPoint(x: W * 0.5, y: 1), control: CGPoint(x: W * 0.62, y: H * 0.35))
            p.addQuadCurve(to: CGPoint(x: 1, y: H), control: CGPoint(x: W * 0.4, y: H * 0.35))
            p.closeSubpath()
            ctx.saveGState()
            ctx.addPath(p)
            ctx.clip()
            ctx.drawLinearGradient(Tex.gradient(CGColor(red: 0.76, green: 0.88, blue: 1, alpha: 0.75),
                                                CGColor(red: 1, green: 1, blue: 1, alpha: 0.96)),
                                   start: CGPoint(x: 0, y: 0), end: CGPoint(x: 0, y: H), options: [])
            ctx.restoreGState()
            ctx.setStrokeColor(CGColor(red: 0.1, green: 0.2, blue: 0.4, alpha: 0.25))
            ctx.setLineWidth(1)
            ctx.addPath(p)
            ctx.strokePath()
            ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.9))
            ctx.setLineWidth(1.5)
            ctx.setLineCap(.round)
            ctx.move(to: CGPoint(x: W * 0.38, y: H * 0.93))
            ctx.addLine(to: CGPoint(x: W * 0.47, y: H * 0.3))
            ctx.strokePath()
        }
        let t = SKTexture(cgImage: img)
        t.filteringMode = .linear
        return t
    }()

    static let palette: [NSColor] = [
        NSColor(calibratedRed: 1.00, green: 0.25, blue: 0.25, alpha: 1),
        NSColor(calibratedRed: 1.00, green: 0.80, blue: 0.20, alpha: 1),
        NSColor(calibratedRed: 0.30, green: 0.95, blue: 0.40, alpha: 1),
        NSColor(calibratedRed: 0.30, green: 0.60, blue: 1.00, alpha: 1),
        NSColor(calibratedRed: 1.00, green: 0.45, blue: 0.80, alpha: 1),
        NSColor(calibratedRed: 0.70, green: 0.45, blue: 1.00, alpha: 1),
        NSColor(calibratedRed: 0.35, green: 0.95, blue: 1.00, alpha: 1),
        NSColor(calibratedRed: 1.00, green: 0.55, blue: 0.15, alpha: 1),
        NSColor(calibratedRed: 1.00, green: 1.00, blue: 1.00, alpha: 1),
        NSColor(calibratedRed: 1.00, green: 0.90, blue: 0.65, alpha: 1),
    ]

    /// Иней по краям экрана: белая дымка + ледяные веточки.
    static func frostImage(w: Int, h: Int) -> CGImage {
        image(w: max(1, w), h: max(1, h)) { ctx, W, H in
            let depth = min(W, H) * 0.16
            let g = Tex.gradient(CGColor(red: 0.93, green: 0.97, blue: 1, alpha: 0.5),
                                 CGColor(red: 0.93, green: 0.97, blue: 1, alpha: 0))
            ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: 0), end: CGPoint(x: 0, y: depth), options: [])
            ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: H), end: CGPoint(x: 0, y: H - depth), options: [])
            ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: 0), end: CGPoint(x: depth, y: 0), options: [])
            ctx.drawLinearGradient(g, start: CGPoint(x: W, y: 0), end: CGPoint(x: W - depth, y: 0), options: [])
            ctx.setLineCap(.round)
            ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.45))
            for _ in 0..<170 {
                var p: CGPoint
                var a: CGFloat
                switch Int.random(in: 0..<4) {
                case 0: p = CGPoint(x: rnd(0, W), y: 0); a = .pi / 2
                case 1: p = CGPoint(x: rnd(0, W), y: H); a = -.pi / 2
                case 2: p = CGPoint(x: 0, y: rnd(0, H)); a = 0
                default: p = CGPoint(x: W, y: rnd(0, H)); a = .pi
                }
                a += rnd(-0.7, 0.7)
                TexX.frostBranch(ctx, p, a, len: rnd(depth * 0.4, depth * 1.3), width: rnd(0.8, 1.8), level: 0)
            }
        }
    }

    static func frostBranch(_ ctx: CGContext, _ p: CGPoint, _ a: CGFloat, len: CGFloat, width: CGFloat, level: Int) {
        let segs = 4
        var cur = p
        var ang = a
        var kids: [(CGPoint, CGFloat)] = []
        let path = CGMutablePath()
        path.move(to: cur)
        for s in 0..<segs {
            ang += rnd(-0.25, 0.25)
            let nxt = CGPoint(x: cur.x + cos(ang) * len / CGFloat(segs), y: cur.y + sin(ang) * len / CGFloat(segs))
            path.addLine(to: nxt)
            if level < 2 && s > 0 {
                for side in [-1.0, 1.0] as [CGFloat] where Bool.random() {
                    kids.append((nxt, ang + side * rnd(0.6, 1.0)))
                }
            }
            cur = nxt
        }
        ctx.setLineWidth(width)
        ctx.addPath(path)
        ctx.strokePath()
        for (kp, ka) in kids {
            frostBranch(ctx, kp, ka, len: len * 0.35, width: width * 0.7, level: level + 1)
        }
    }

    /// Точки лампочек гирлянды вдоль верхней кромки окна (координаты Quartz).
    static func garlandPoints(_ r: CGRect) -> [CGPoint] {
        let x0 = r.minX + 26, x1 = r.maxX - 26
        guard x1 > x0 + 40 else { return [] }
        let spans = max(1, Int((x1 - x0) / 120))
        let spanW = (x1 - x0) / CGFloat(spans)
        var pts: [CGPoint] = []
        var x = x0 + 11
        while x < x1 {
            let u = (x - x0).truncatingRemainder(dividingBy: spanW) / spanW
            let sag = 9 * (1 - (2 * u - 1) * (2 * u - 1))
            pts.append(CGPoint(x: x, y: r.minY + 3 + sag))
            x += 22
        }
        return pts
    }

    static func garlandWire(_ r: CGRect) -> CGImage {
        let scale: CGFloat = 2
        let h: CGFloat = 20
        return image(w: Int(r.width * scale), h: Int(h * scale)) { ctx, _, _ in
            ctx.scaleBy(x: scale, y: scale)
            let x0 = r.minX + 26, x1 = r.maxX - 26
            guard x1 > x0 + 40 else { return }
            let spans = max(1, Int((x1 - x0) / 120))
            let spanW = (x1 - x0) / CGFloat(spans)
            let path = CGMutablePath()
            var first = true
            var x = x0
            while x <= x1 {
                let u = (x - x0).truncatingRemainder(dividingBy: spanW) / spanW
                let sag = 9 * (1 - (2 * u - 1) * (2 * u - 1))
                // картинка: ось y вверх, верх картинки = верх окна
                let p = CGPoint(x: x - r.minX, y: h - (3 + sag))
                if first { path.move(to: p); first = false } else { path.addLine(to: p) }
                x += 3
            }
            ctx.setLineCap(.round)
            ctx.setStrokeColor(CGColor(red: 0.08, green: 0.22, blue: 0.1, alpha: 0.9))
            ctx.setLineWidth(1.6)
            ctx.addPath(path)
            ctx.strokePath()
        }
    }
}

// MARK: - Логика новых эффектов

extension Sim {
    func play(_ s: Sfx, _ gain: Float = 1) { sfx?(s, gain) }

    // MARK: Погода

    var weatherRateMul: CGFloat {
        switch weather {
        case .snow: return 1
        case .rain: return 2.2
        case .leaves: return 0.12
        case .sakura: return 0.35
        }
    }

    func makeParticle(_ scr: CGRect) -> Flake {
        let x = rnd(scr.minX - 80, scr.maxX + 80)
        let y = scr.minY - rnd(4, 40)
        switch weather {
        case .rain:
            let r = rnd(1.0, 1.6) * min(1.5, flakeSize)
            return Flake(x: x, y: y - rnd(0, 200), r: r, phase: 0, freq: 1, mass: 0, loose: false, kind: 9, mat: Mat.rain)
        case .leaves:
            let r = rnd(3.0, 5.0) * flakeSize
            return Flake(x: x, y: y, r: r, phase: rnd(0, 2 * .pi), freq: rnd(0.5, 1.2), mass: 0, loose: false,
                         kind: Int.random(in: 5...7), mat: Mat.leaf)
        case .sakura:
            let r = rnd(2.0, 3.0) * flakeSize
            return Flake(x: x, y: y, r: r, phase: rnd(0, 2 * .pi), freq: rnd(0.6, 1.4), mass: 0, loose: false,
                         kind: 8, mat: Mat.petal)
        case .snow:
            let r = rnd(1.0, 3.2) * flakeSize
            return Flake(x: x, y: y, r: r, phase: rnd(0, 2 * .pi), freq: rnd(0.6, 1.8),
                         mass: 0.55 + r / flakeSize * 0.33, loose: false)
        }
    }

    func moveFalling(_ f: inout Flake, _ dt: CGFloat) {
        switch f.mat {
        case Mat.rain:
            f.x += wind * 3 * dt
            f.y += (620 + f.r * 90) * dt
        case Mat.leaf:
            f.x += (sin(t * f.freq * 1.3 + f.phase) * 45 + wind * 1.6) * dt
            f.y += (38 + sin(t * f.freq * 2.1 + f.phase) * 22) * dt
        case Mat.petal:
            f.x += (sin(t * f.freq * 1.6 + f.phase) * 28 + wind * 1.3) * dt
            f.y += (26 + f.r * 5) * dt
        default:
            f.x += (sin(t * f.freq + f.phase) * 14 + wind) * dt
            f.y += (32 + f.r / flakeSize * 18) * (1 + max(0, intensity * envIntensity - 1) * 0.25) * dt
        }
    }

    func emitDrop(x: CGFloat, y: CGFloat, vx: CGFloat, vy: CGFloat) {
        guard flakes.count < Cfg.maxTotal else { return }
        flakes.append(Flake(x: x, y: y, vx: vx, vy: vy, r: 0.8, phase: 0, freq: 1, mass: 0, loose: true, kind: 9, mat: Mat.rain))
    }

    /// Частица долетела до окна или пола.
    func land(_ f: Flake, _ s: Surface, _ i: Int) {
        switch f.mat {
        case Mat.rain:
            guard !f.loose else { return }
            if s.heights[i] > 0 {
                s.heights[i] = max(0, s.heights[i] - 0.35)   // дождь подъедает снег
            }
            if Int.random(in: 0..<3) == 0 {
                for _ in 0..<2 { emitDrop(x: f.x, y: s.surfY(i) - 1, vx: rnd(-60, 60), vy: rnd(-170, -60)) }
            }
        case Mat.leaf, Mat.petal:
            if fx.litter.count >= 450 { fx.litter.removeFirst() }
            fx.litter.append(Litter(sid: s.id, relX: f.x - s.rect.minX, kind: f.kind, r: f.r, rot: rnd(0, 2 * .pi)))
        default:
            let clump: CGFloat = Int.random(in: 0..<14) == 0 ? 3 : 1   // иногда ложится комочек
            s.add(i, f.mass * 0.36 * clump)
            s.add(i - 1, f.mass * 0.22)
            s.add(i + 1, f.mass * 0.22)
            s.add(i - 2, f.mass * 0.10)
            s.add(i + 2, f.mass * 0.10)
        }
    }

    /// Быстрый взмах курсором разбрасывает лежащие листья.
    func sweepLitter(radius R: CGFloat) {
        guard !fx.litter.isEmpty else { return }
        var keep: [Litter] = []
        for l in fx.litter {
            guard let s = surface(l.sid), let i = s.col(s.rect.minX + l.relX) else { continue }
            let x = s.rect.minX + l.relX, y = s.surfY(i)
            if hypot(x - mouse.x, y - mouse.y) < R && flakes.count < Cfg.maxTotal {
                flakes.append(Flake(x: x, y: y - 2, vx: mouseVel.dx * rnd(0.3, 0.7), vy: mouseVel.dy * rnd(0.3, 0.7) - rnd(80, 200),
                                    r: l.r, phase: rnd(0, 2 * .pi), freq: 1, mass: 0, loose: true,
                                    kind: l.kind, mat: l.kind == 8 ? Mat.petal : Mat.leaf))
            } else {
                keep.append(l)
            }
        }
        fx.litter = keep
    }

    // MARK: Каждый кадр

    func updateFeatures(_ dt: CGFloat) {
        fx.dirty = false
        updateMelting(dt)

        fx.iceAcc += dt
        if fx.iceAcc >= 0.5 {
            let stepT = fx.iceAcc
            fx.iceAcc = 0
            updateIcicles(stepT)
        }
        updateFallingIcicles(dt)
        updateLitter(dt)
        updateFight(dt)
        updateFireworks(dt)
        updateFrost(dt)

        fx.clockAcc += dt
        if fx.clockAcc >= 0.25 {
            fx.clockAcc = 0
            checkNewYear()
        }
        fx.garlandRect = fx.garland ? frontToBack.first?.rect : nil
        if fx.crunchCooldown > 0 { fx.crunchCooldown -= dt }
    }

    func updateMelting(_ dt: CGFloat) {
        let rate: CGFloat = weather == .rain ? 0.5 : (melting ? 0.25 : 0)
        guard rate > 0 else { return }
        var changed = false
        for s in surfList {
            for i in 0..<s.heights.count where s.heights[i] > 0 {
                s.heights[i] = max(0, s.heights[i] - rate * dt * (0.5 + s.heights[i] / max(1, s.cap)))
                changed = true
            }
        }
        for b in balls where b.state == .resting {
            b.r -= rate * 0.6 * dt
            if b.r < 3 { b.dead = true }
            changed = true
        }
        if balls.contains(where: { $0.dead }) { balls.removeAll { $0.dead } }
        if changed { fx.dirty = true }
    }

    // MARK: Сосульки

    func updateIcicles(_ dt: CGFloat) {
        guard fx.icicles else {
            for s in windows.values where !s.icicles.isEmpty { s.icicles.removeAll() }
            return
        }
        let grow: CGFloat = (melting || weather == .rain) ? -0.8 : (weather == .snow ? 0.35 : 0)
        for s in windows.values {
            let n = s.heights.count
            let maxCount = Int(s.rect.width / 55)
            if grow > 0 && s.icicles.count < maxCount && n > 0 && CGFloat.random(in: 0...1) < dt * 0.2 {
                let i = Int.random(in: 0..<n)
                let x = s.colX(i) - s.rect.minX
                if s.capMul[i] > 0.6 && s.heights[i] > s.capAt(i) * 0.45 && !s.covered[i]
                    && !s.icicles.contains(where: { abs($0.relX - x) < 14 }) {
                    s.icicles.append(Icicle(relX: x, len: 2, maxLen: rnd(10, 46), w: rnd(4, 8), rate: rnd(0.6, 1.4)))
                }
            }
            for k in s.icicles.indices {
                s.icicles[k].len = min(s.icicles[k].maxLen, s.icicles[k].len + grow * s.icicles[k].rate * dt)
            }
            s.icicles.removeAll { $0.len < 1 }
        }
    }

    /// Окно дёрнули или закрыли — сосульки отрываются.
    func dropIcicles(_ s: Surface, vx: CGFloat, vy: CGFloat) {
        for ic in s.icicles {
            fx.falling.append(FallingIcicle(x: s.rect.minX + ic.relX, y: s.top, vx: vx * rnd(0.3, 0.8), vy: vy * rnd(0.3, 0.8),
                                            len: ic.len, w: ic.w, rot: 0))
        }
        s.icicles.removeAll()
    }

    func icicleUnderCursor() -> (Surface, Int)? {
        for s in frontToBack {
            for (k, ic) in s.icicles.enumerated() {
                let x = s.rect.minX + ic.relX
                if abs(mouse.x - x) < ic.w / 2 + 4 && mouse.y >= s.top - 2 && mouse.y <= s.top + ic.len + 2 {
                    if let i = s.col(x), s.covered[i] { continue }
                    return (s, k)
                }
            }
        }
        return nil
    }

    func breakIcicle(_ s: Surface, _ k: Int) {
        let ic = s.icicles[k]
        fx.falling.append(FallingIcicle(x: s.rect.minX + ic.relX, y: s.top, vx: rnd(-20, 20), vy: 30, len: ic.len, w: ic.w, rot: 0))
        s.icicles.remove(at: k)
        play(.crunch, 0.5)
    }

    func updateFallingIcicles(_ dt: CGFloat) {
        guard !fx.falling.isEmpty else { return }
        var keep: [FallingIcicle] = []
        for var f in fx.falling {
            let tip0 = f.y + f.len
            f.vy += 1500 * dt
            f.x += f.vx * dt
            f.y += f.vy * dt
            f.rot += f.vx * 0.002 * dt * 60
            let tip1 = f.y + f.len
            if landing(x: f.x, y0: tip0, y1: tip1) != nil || tip1 > bounds.maxY {
                // разбилась
                play(.shatter, 0.7)
                for _ in 0..<Int(4 + f.len / 4) {
                    emitLoose(x: f.x + rnd(-3, 3), y: tip1 - rnd(0, 4), mass: 0.3,
                              vx: rnd(-140, 140), vy: rnd(-260, -80))
                }
                continue
            }
            keep.append(f)
        }
        fx.falling = keep
    }

    // MARK: Листья и лепестки на окнах

    func updateLitter(_ dt: CGFloat) {
        guard !fx.litter.isEmpty else { return }
        var keep: [Litter] = []
        keep.reserveCapacity(fx.litter.count)
        for var l in fx.litter {
            l.age += dt
            guard l.age < 300 else { continue }
            guard let s = surface(l.sid), s.col(s.rect.minX + l.relX) != nil else {
                continue   // окно закрыли — листок пропадает вместе с ним
            }
            keep.append(l)
        }
        fx.litter = keep
    }

    // MARK: Снежная битва

    func updateFight(_ dt: CGFloat) {
        guard fx.fight else { return }
        fx.enemyTimer -= dt
        let enemies = balls.filter { $0.enemy && $0.state == .flying }.count
        if fx.enemyTimer <= 0 && enemies < 2 {
            fx.enemyTimer = rnd(2.2, 4.5)
            let scr = screens.first { $0.contains(mouse) } ?? screens.first ?? .zero
            let fromLeft = Bool.random()
            let x0 = fromLeft ? scr.minX - 15 : scr.maxX + 15
            let y0 = scr.minY + scr.height * rnd(0.2, 0.6)
            let tx = mouse.x + rnd(-20, 20), ty = mouse.y + rnd(-20, 20)
            let T = rnd(1.2, 1.7)
            let g = Cfg.ballGravity
            let b = Ball(x: x0, y: y0, r: rnd(9, 13), state: .flying)
            b.enemy = true
            b.vx = (tx - x0) / T * 1.12
            b.vy = (ty - y0) / T - 0.5 * g * T
            balls.append(b)
        }
        // попали в тебя
        for b in balls where b.enemy && b.state == .flying && !b.dead {
            if hypot(b.x - mouse.x, b.y - mouse.y) < b.r + 6 {
                fx.scoreThem += 1
                b.r *= 1.6
                splat(b, decal: true)
            }
        }
    }

    func enemyUnderCursor() -> Ball? {
        guard fx.fight else { return nil }
        return balls.first { $0.enemy && $0.state == .flying && !$0.dead && hypot($0.x - mouse.x, $0.y - mouse.y) < $0.r + 28 }
    }

    // MARK: Салют

    func startFireworks(_ seconds: CGFloat) {
        fx.fireworksUntil = t + seconds
        fx.rocketAcc = 0
    }

    func updateFireworks(_ dt: CGFloat) {
        if t < fx.fireworksUntil {
            fx.rocketAcc -= dt
            if fx.rocketAcc <= 0 {
                let left = fx.fireworksUntil - t
                if left < 3.5 {
                    // финальный шквал
                    fx.rocketAcc = rnd(0.07, 0.16)
                    launchRocket()
                } else {
                    fx.rocketAcc = rnd(0.35, 0.9)
                    launchRocket()
                    if Int.random(in: 0..<4) == 0 { launchRocket() }   // иногда парой
                }
            }
        }
        guard !fx.sparks.isEmpty else { return }
        var keep: [Spark] = []
        keep.reserveCapacity(fx.sparks.count + 200)
        for var s in fx.sparks {
            s.life -= dt
            if s.rocket {
                s.vy += 300 * dt
                s.vx += sin(s.life * 23) * 40 * dt          // лёгкое виляние
                s.x += s.vx * dt
                s.y += s.vy * dt
                keep.append(Spark(x: s.x + rnd(-1, 1), y: s.y + 2, vx: rnd(-25, 25), vy: rnd(20, 60),
                                  life: rnd(0.25, 0.5), maxLife: 0.5, color: 9, rocket: false, size: rnd(1.2, 2.2),
                                  kind: 0, drag: 2, grav: 120))
                if s.vy > -60 || s.life <= 0 {
                    explode(s, into: &keep)
                    continue
                }
            } else {
                s.vy += s.grav * dt
                let d = exp(-s.drag * dt)
                s.vx *= d
                s.vy *= d
                s.x += s.vx * dt
                s.y += s.vy * dt
                // шлейф у хризантемы и ивы
                if (s.kind == 1 || s.kind == 4) && Int.random(in: 0..<2) == 0 && s.life > 0 {
                    let long = s.kind == 4
                    keep.append(Spark(x: s.x, y: s.y, vx: rnd(-6, 6), vy: rnd(-6, 10),
                                      life: long ? rnd(0.6, 1.1) : rnd(0.2, 0.4), maxLife: long ? 1.1 : 0.4,
                                      color: s.color, rocket: false, size: s.size * 0.55,
                                      kind: 0, drag: 3, grav: long ? 70 : 40, alpha: 0.8))
                }
                // крестовик: звезда раскалывается на четыре
                if s.kind == 3 && s.life < s.maxLife * 0.5 {
                    let a0 = atan2(s.vy, s.vx)
                    for q in 0..<4 {
                        let a = a0 + CGFloat(q) * .pi / 2 + .pi / 4
                        keep.append(Spark(x: s.x, y: s.y, vx: s.vx * 0.3 + cos(a) * 110, vy: s.vy * 0.3 + sin(a) * 110,
                                          life: rnd(0.6, 0.9), maxLife: 0.9, color: s.color, rocket: false,
                                          size: s.size * 0.8, kind: 1, drag: 2, grav: 140))
                    }
                    continue
                }
                // маленький дочерний заряд
                if s.kind == 6 && s.life <= 0 {
                    explode(s, into: &keep)
                    continue
                }
                if s.life <= 0 { continue }
            }
            keep.append(s)
        }
        if keep.count > 6000 { keep.removeFirst(keep.count - 6000) }
        fx.sparks = keep
    }

    func launchRocket() {
        guard let scr = screens.randomElement() else { return }
        let h = scr.height * rnd(0.45, 0.78)
        let vy = -sqrt(2 * 300 * h)
        fx.sparks.append(Spark(x: rnd(scr.minX + scr.width * 0.12, scr.maxX - scr.width * 0.12), y: scr.maxY + 5,
                               vx: rnd(-50, 50), vy: vy, life: 4, maxLife: 4, color: 9, rocket: true, size: 3))
        if Int.random(in: 0..<3) == 0 { play(.whistle, 0.22) }
    }

    private func star(_ arr: inout [Spark], _ r: Spark, vx: CGFloat, vy: CGFloat, color: Int,
                      life: CGFloat, size: CGFloat, kind: UInt8 = 0, drag: CGFloat = 1.6, grav: CGFloat = 160) {
        arr.append(Spark(x: r.x, y: r.y, vx: vx, vy: vy, life: life * rnd(0.85, 1.1), maxLife: life,
                         color: color, rocket: false, size: size, kind: kind, drag: drag, grav: grav))
    }

    func explode(_ r: Spark, into arr: inout [Spark]) {
        let big = r.rocket                      // большой залп или маленький дочерний
        let k: CGFloat = big ? 1 : 0.45
        let c1 = Int.random(in: 0...7)
        var c2 = Int.random(in: 0...7)
        if c2 == c1 { c2 = (c1 + 3) % 8 }

        // вспышка: яркое ядро и широкое свечение
        arr.append(Spark(x: r.x, y: r.y, vx: 0, vy: 0, life: 0.16, maxLife: 0.16, color: 8, rocket: false,
                         size: 14 * k, kind: 5, drag: 0, grav: 0, alpha: 1))
        arr.append(Spark(x: r.x, y: r.y, vx: 0, vy: 0, life: 0.4, maxLife: 0.4, color: c1, rocket: false,
                         size: 100 * k, kind: 5, drag: 0, grav: 0, alpha: 0.22))

        let sp = 260 * k
        let type = big ? Int.random(in: 0..<9) : 0
        switch type {
        case 1:   // хризантема: звёзды со шлейфом
            for _ in 0..<70 {
                let a = rnd(0, 2 * .pi), v = sp * rnd(0.8, 1.05)
                star(&arr, r, vx: cos(a) * v, vy: sin(a) * v, color: c1, life: 1.5, size: 3, kind: 1)
            }
        case 2:   // золотая ива: медленно опадающие золотые нити
            for _ in 0..<60 {
                let a = rnd(0, 2 * .pi), v = sp * rnd(0.55, 0.85)
                star(&arr, r, vx: cos(a) * v, vy: sin(a) * v, color: 9, life: 3.2, size: 2.6, kind: 4, drag: 2.2, grav: 110)
            }
            play(.crackle, 0.35)
        case 3:   // наклонное кольцо
            let tilt = rnd(0.3, 1), rot = rnd(0, .pi)
            for q in 0..<64 {
                let a = CGFloat(q) / 64 * 2 * .pi
                let x = cos(a) * sp, y = sin(a) * sp * tilt
                star(&arr, r, vx: x * cos(rot) - y * sin(rot), vy: x * sin(rot) + y * cos(rot),
                     color: c1, life: 1.6, size: 3.2)
            }
        case 4:   // двойное кольцо двух цветов
            for (ring, col) in [(1.0, c1), (0.6, c2)] as [(CGFloat, Int)] {
                for q in 0..<48 {
                    let a = CGFloat(q) / 48 * 2 * .pi + ring
                    star(&arr, r, vx: cos(a) * sp * ring, vy: sin(a) * sp * ring, color: col, life: 1.6, size: 3)
                }
            }
        case 5:   // крестовик: звёзды раскалываются крестом
            for q in 0..<14 {
                let a = CGFloat(q) / 14 * 2 * .pi + rnd(-0.1, 0.1)
                star(&arr, r, vx: cos(a) * sp * 0.75, vy: sin(a) * sp * 0.75, color: c1, life: 1.2, size: 3.6, kind: 3)
            }
        case 6:   // мерцающие блёстки
            for _ in 0..<110 {
                let a = rnd(0, 2 * .pi), v = sp * sqrt(rnd(0.05, 1))
                star(&arr, r, vx: cos(a) * v, vy: sin(a) * v, color: Bool.random() ? 8 : 9, life: 2.0, size: 2.4,
                     kind: 2, drag: 1.8, grav: 90)
            }
            play(.crackle, 0.45)
        case 7:   // сердце
            for q in 0..<72 {
                let tt = CGFloat(q) / 72 * 2 * .pi
                let hx = 16 * pow(sin(tt), 3)
                let hy = 13 * cos(tt) - 5 * cos(2 * tt) - 2 * cos(3 * tt) - cos(4 * tt)
                let m = sp / 17
                star(&arr, r, vx: hx * m, vy: -hy * m, color: Bool.random() ? 0 : 4, life: 1.8, size: 3.2,
                     drag: 1.3, grav: 40)
            }
        case 8:   // пальма + дочерние залпы
            for q in 0..<8 {
                let a = CGFloat(q) / 8 * 2 * .pi + rnd(-0.15, 0.15)
                star(&arr, r, vx: cos(a) * sp * 0.9, vy: sin(a) * sp * 0.9 - 40, color: 9, life: 1.9, size: 4.5,
                     kind: 1, drag: 1.2, grav: 170)
            }
            for _ in 0..<Int.random(in: 3...5) {
                let a = rnd(0, 2 * .pi), v = sp * rnd(0.4, 0.7)
                star(&arr, r, vx: cos(a) * v, vy: sin(a) * v, color: c2, life: rnd(0.5, 0.8), size: 2, kind: 6,
                     drag: 1.5, grav: 120)
            }
        default:  // пион: шар из звёзд двух цветов
            for q in 0..<90 {
                let a = rnd(0, 2 * .pi), v = sp * rnd(0.75, 1.05)
                star(&arr, r, vx: cos(a) * v, vy: sin(a) * v, color: q % 3 == 0 ? c2 : c1, life: 1.5, size: big ? 3.2 : 2.4)
            }
        }
        play(.boom, big ? 0.5 : 0.22)
    }

    // MARK: Новый год

    func checkNewYear() {
        guard fx.newYear else { fx.countdown = nil; return }
        let c = Calendar.current.dateComponents([.month, .day, .hour, .minute, .second], from: Date())
        let sec = c.second ?? 0
        if c.month == 12 && c.day == 31 && c.hour == 23 && c.minute == 59 && sec >= 50 {
            fx.countdown = "\(60 - sec)"
        } else if c.month == 1 && c.day == 1 && c.hour == 0 && c.minute == 0 {
            fx.countdown = "С Новым годом!"
            if fx.fireworksUntil < t { startFireworks(70) }
        } else {
            fx.countdown = nil
        }
    }

    // MARK: Иней

    func updateFrost(_ dt: CGFloat) {
        let old = fx.frost
        let wintry = weather == .snow && !melting
        fx.idleAcc += dt
        if fx.idleAcc >= 0.5 {
            fx.idleAcc = 0
            let st = CGEventSourceStateID.combinedSessionState
            fx.idleSeconds = [CGEventType.mouseMoved, .keyDown, .leftMouseDown, .scrollWheel]
                .map { CGEventSource.secondsSinceLastEventType(st, eventType: $0) }.min() ?? 0
        }
        if fx.frostOn && wintry && fx.idleSeconds > 25 {
            fx.frost = min(1, fx.frost + dt / 100)
        } else {
            fx.frost = max(0, fx.frost - dt * 1.2)
        }
        fx.frostChanging = fx.frost != old
    }

    /// Для паузы отрисовки: что-то из новых эффектов сейчас движется.
    var featuresBusy: Bool {
        !fx.sparks.isEmpty || !fx.falling.isEmpty || fx.frostChanging || fx.garland
            || fx.countdown != nil || fx.fight || fx.dirty
    }

    func clearFeatures() {
        for s in windows.values { s.icicles.removeAll() }
        fx.falling.removeAll()
        fx.litter.removeAll()
    }
}

// MARK: - Отрисовка новых эффектов

final class SceneFX {
    var litter: [SKSpriteNode] = []
    var icicles: [SKSpriteNode] = []
    var sparks: [SKSpriteNode] = []
    var bulbs: [SKSpriteNode] = []
    var glows: [SKSpriteNode] = []
    var frost: SKSpriteNode? = nil
    var wire: SKSpriteNode? = nil
    var wireRect: CGRect? = nil
    var label: SKLabelNode? = nil
    var labelShadow: SKLabelNode? = nil
}

extension SnowScene {
    func pooled(_ arr: inout [SKSpriteNode], _ k: Int, tex: SKTexture, z: CGFloat, add: Bool = false) -> SKSpriteNode {
        if k < arr.count {
            let n = arr[k]
            if n.isHidden { n.isHidden = false }
            return n
        }
        let n = SKSpriteNode(texture: tex)
        n.zPosition = z
        if add { n.blendMode = .add }
        addChild(n)
        arr.append(n)
        return n
    }

    func hideRest(_ arr: [SKSpriteNode], from k: Int) {
        if k < arr.count {
            for j in k..<arr.count where !arr[j].isHidden { arr[j].isHidden = true }
        }
    }

    func syncExtras() {
        let vis = q.insetBy(dx: -60, dy: -60)

        // листья и лепестки, лежащие на окнах
        var k = 0
        for l in sim.fx.litter {
            guard let s = sim.surface(l.sid), let i = s.col(s.rect.minX + l.relX), !s.covered[i] else { continue }
            let x = s.rect.minX + l.relX
            let y = s.surfY(i) - l.r * 0.35
            guard vis.contains(CGPoint(x: x, y: y)) else { continue }
            let n = pooled(&fxn.litter, k, tex: Tex.flakeTex[l.kind], z: 1.6)
            n.texture = Tex.flakeTex[l.kind]
            let d = l.r * 2 * 2.2
            n.size = CGSize(width: d * 0.55, height: d)
            n.position = P(x, y)
            n.zRotation = .pi / 2 + sin(l.rot) * 0.35      // лежат почти плашмя
            n.alpha = l.age > 290 ? max(0, (300 - l.age) / 10) : 1
            k += 1
        }
        hideRest(fxn.litter, from: k)

        // сосульки
        k = 0
        for s in sim.frontToBack where s.rect.intersects(vis) {
            for ic in s.icicles {
                let x = s.rect.minX + ic.relX
                guard let i = s.col(x), !s.covered[i] else { continue }
                let n = pooled(&fxn.icicles, k, tex: TexX.icicle, z: 1.2)
                n.anchorPoint = CGPoint(x: 0.5, y: 1)
                n.size = CGSize(width: ic.w, height: ic.len)
                n.position = P(x, s.baseY(i) - 0.5)
                n.zRotation = 0
                k += 1
            }
        }
        for f in sim.fx.falling where vis.contains(CGPoint(x: f.x, y: f.y)) {
            let n = pooled(&fxn.icicles, k, tex: TexX.icicle, z: 1.2)
            n.anchorPoint = CGPoint(x: 0.5, y: 1)
            n.size = CGSize(width: f.w, height: f.len)
            n.position = P(f.x, f.y)
            n.zRotation = f.rot
            k += 1
        }
        hideRest(fxn.icicles, from: k)

        // искры салюта
        k = 0
        let visBig = q.insetBy(dx: -300, dy: -300)
        for sp in sim.fx.sparks where visBig.contains(CGPoint(x: sp.x, y: sp.y)) {
            let n = pooled(&fxn.sparks, k, tex: Tex.flake, z: 9, add: true)
            let ratio = max(0, sp.life / sp.maxLife)
            // ива к концу краснеет, остальное просто гаснет
            let ci = sp.kind == 4 && ratio < 0.45 ? 7 : sp.color
            n.color = TexX.palette[ci]
            n.colorBlendFactor = 1
            let d: CGFloat
            var a: CGFloat
            if sp.kind == 5 {
                d = sp.size * 2.6
                a = ratio * sp.alpha
            } else {
                d = sp.size * 2.6 * (0.45 + 0.55 * ratio)
                a = min(1, ratio * 1.6) * sp.alpha
            }
            if sp.kind == 2 && Int.random(in: 0..<3) == 0 { a *= 0.12 }   // мерцание
            n.size = CGSize(width: d, height: d)
            n.position = P(sp.x, sp.y)
            n.alpha = a
            k += 1
        }
        hideRest(fxn.sparks, from: k)

        syncGarland()
        syncFrost()
        syncCountdown()
    }

    func syncGarland() {
        guard let r = sim.fx.garlandRect, r.intersects(q) else {
            fxn.wire?.isHidden = true
            hideRest(fxn.bulbs, from: 0)
            hideRest(fxn.glows, from: 0)
            return
        }
        if fxn.wireRect?.size != r.size {
            let tex = SKTexture(cgImage: TexX.garlandWire(r))
            if fxn.wire == nil {
                let w = SKSpriteNode(texture: tex)
                w.zPosition = 6
                addChild(w)
                fxn.wire = w
            }
            fxn.wire?.texture = tex
            fxn.wire?.size = CGSize(width: r.width, height: 20)
        }
        fxn.wireRect = r
        fxn.wire?.isHidden = false
        fxn.wire?.position = P(r.midX, r.minY + 10)

        let pts = TexX.garlandPoints(r)
        for (idx, p) in pts.enumerated() {
            let c = TexX.palette[[0, 1, 2, 3][idx % 4]]
            let blink = 0.5 + 0.5 * sin(sim.t * 2.6 + CGFloat(idx) * 1.7)
            let glow = pooled(&fxn.glows, idx, tex: Tex.flake, z: 6.05, add: true)
            glow.color = c
            glow.colorBlendFactor = 1
            glow.size = CGSize(width: 26, height: 26)
            glow.position = P(p.x, p.y + 5)
            glow.alpha = 0.15 + 0.55 * blink
            let bulb = pooled(&fxn.bulbs, idx, tex: Tex.flake, z: 6.1)
            bulb.color = c
            bulb.colorBlendFactor = 0.85
            bulb.size = CGSize(width: 10, height: 13)
            bulb.position = P(p.x, p.y + 5)
            bulb.alpha = 0.6 + 0.4 * blink
        }
        hideRest(fxn.glows, from: pts.count)
        hideRest(fxn.bulbs, from: pts.count)
    }

    func syncFrost() {
        let a = sim.fx.frost
        if a < 0.01 {
            fxn.frost?.isHidden = true
            return
        }
        if fxn.frost == nil {
            let img = TexX.frostImage(w: Int(q.width), h: Int(q.height))
            let n = SKSpriteNode(texture: SKTexture(cgImage: img))
            n.size = q.size
            n.position = CGPoint(x: q.width / 2, y: q.height / 2)
            n.zPosition = 8
            addChild(n)
            fxn.frost = n
        }
        fxn.frost?.isHidden = false
        fxn.frost?.alpha = a * 0.95
    }

    func syncCountdown() {
        guard let text = sim.fx.countdown else {
            fxn.label?.isHidden = true
            fxn.labelShadow?.isHidden = true
            return
        }
        if fxn.label == nil {
            let sh = SKLabelNode(fontNamed: "HelveticaNeue-Bold")
            sh.fontColor = NSColor(calibratedWhite: 0, alpha: 0.4)
            sh.verticalAlignmentMode = .center
            sh.zPosition = 10.9
            let l = SKLabelNode(fontNamed: "HelveticaNeue-Bold")
            l.fontColor = .white
            l.verticalAlignmentMode = .center
            l.zPosition = 11
            addChild(sh)
            addChild(l)
            fxn.label = l
            fxn.labelShadow = sh
        }
        let size: CGFloat = text.count > 3 ? 84 : 160
        for (n, off) in [(fxn.labelShadow, CGPoint(x: 3, y: -3)), (fxn.label, CGPoint.zero)] {
            guard let n = n else { continue }
            n.isHidden = false
            n.text = text
            n.fontSize = size
            n.position = CGPoint(x: q.width / 2 + off.x, y: q.height / 2 + off.y)
        }
    }
}
