import MancoraCore
import Testing

@testable import MancoraProcess

/// Runs the operation a golden case describes and returns Mancora's outputs.
enum GoldenRunner {
    static func run(_ c: ProcessGolden.Case) throws -> [Hyperstack] {
        let inputs = try c.inputs.map(ProcessGolden.image)
        let p = c.params
        switch c.op {
        case "convert":
            let options = ConversionOptions(scale: p.scale ?? true, rgbWeights: p.weighted == true ? .weighted : .unweighted)
            return [try ImageConverter.convert(inputs[0], to: PixelType(rawValue: p.to!)!, options: options)]
        case "zproject":
            return [
                ZProjector.project(
                    inputs[0], method: ZProjector.Method(rawValue: p.method!)!, slices: (p.start! - 1)...(p.stop! - 1),
                    allTimeFrames: p.allFrames ?? true, frame: (p.frame ?? 1) - 1)
            ]
        case "math":
            return [ImageMath.apply(mathOperation(p), to: inputs[0])]
        case "calc":
            return [
                try ImageCalculator.calculate(
                    inputs[0], calculatorOperation(p.operation!), inputs[1], float32Result: p.float ?? false)
            ]
        case "split":
            return ChannelSplitter.split(inputs[0])
        case "merge":
            var slots = [Hyperstack?](repeating: nil, count: 7)
            for (slot, image) in zip(p.slots!, inputs) { slots[slot] = image }
            return [
                try RGBStackMerge.mergeChannels(slots, createComposite: p.composite ?? true, ignoreLUTs: p.ignoreLUTs ?? false)
            ]
        case "substack":
            return [try SubstackMaker.makeSubstack(inputs[0], p.slices!)]
        case "subhyperstack":
            return [
                try SubstackMaker.makeSubhyperstack(
                    inputs[0], channels: p.channelList!, slices: p.sliceList!, frames: p.frameList!)
            ]
        case "reduce":
            return [
                HyperStackReducer.reduce(
                    inputs[0], keepChannels: p.keepChannels!, keepSlices: p.keepSlices!, keepFrames: p.keepFrames!,
                    channel: p.channel! - 1, slice: p.slice! - 1, frame: p.frame! - 1)
            ]
        case "arrange":
            return [try ChannelArranger.arrange(inputs[0], order: p.order!.map { $0 - 1 })]
        default:
            Issue.record("unknown operation \(c.op)")
            return []
        }
    }

    static func mathOperation(_ p: ProcessGolden.Params) -> ImageMath.Operation {
        let v = p.value ?? 0
        let bits = p.binary.flatMap { Int($0, radix: 2) } ?? 0
        switch p.operation! {
        case "add": return .add(v)
        case "sub": return .subtract(v)
        case "mul": return .multiply(v)
        case "div": return .divide(v)
        case "and": return .and(bits)
        case "or": return .or(bits)
        case "xor": return .xor(bits)
        case "min": return .min(v)
        case "max": return .max(v)
        case "gamma": return .gamma(v)
        case "set": return .set(v)
        case "log": return .log
        case "exp": return .exp
        case "sqr": return .square
        case "sqrt": return .squareRoot
        case "abs": return .abs
        case "reciprocal": return .reciprocal
        case "nan": return .nanBackground(lower: p.lower!, upper: p.upper!)
        case "invert": return .invert
        default: preconditionFailure("unknown math operation \(p.operation!)")
        }
    }

    static func calculatorOperation(_ name: String) -> ImageCalculator.Operation {
        let names: [String: ImageCalculator.Operation] = [
            "add": .add, "sub": .subtract, "mul": .multiply, "div": .divide, "and": .and, "or": .or, "xor": .xor,
            "min": .min, "max": .max, "ave": .average, "diff": .difference, "copy": .copy, "zero": .transparentZero,
        ]
        return names[name]!
    }

    static func check(_ c: ProcessGolden.Case) throws {
        if c.error == true {
            #expect(throws: (any Error).self, "ImageJ refuses this") { _ = try run(c) }
            return
        }
        let outputs = try run(c)
        let expected = try #require(c.outputs)
        try #require(outputs.count == expected.count, "\(outputs.count) outputs, ImageJ made \(expected.count)")
        for (image, golden) in zip(outputs, expected) {
            ProcessGolden.check(image, golden, c.id)
        }
    }
}

@Suite("Type conversions match ImageJ")
struct ConversionGoldenTests {
    @Test func fixturesPresent() {
        #expect(ProcessGolden.convert?.imagej == "1.54p")
        #expect(ProcessGolden.cases(ProcessGolden.convert).count > 150)
    }

    @Test("Image ▸ Type", arguments: ProcessGolden.cases(ProcessGolden.convert))
    func convert(_ c: ProcessGolden.Case) throws { try GoldenRunner.check(c) }
}

@Suite("Z Project matches ImageJ")
struct ZProjectGoldenTests {
    @Test func fixturesPresent() {
        #expect(ProcessGolden.cases(ProcessGolden.zproject).count > 150)
    }

    @Test("Z Project", arguments: ProcessGolden.cases(ProcessGolden.zproject))
    func project(_ c: ProcessGolden.Case) throws { try GoldenRunner.check(c) }
}

@Suite("Process ▸ Math and Image Calculator match ImageJ")
struct MathGoldenTests {
    @Test func fixturesPresent() {
        #expect(ProcessGolden.cases(ProcessGolden.math, op: "math").count > 150)
        #expect(ProcessGolden.cases(ProcessGolden.math, op: "calc").count > 200)
    }

    @Test("Process ▸ Math", arguments: ProcessGolden.cases(ProcessGolden.math, op: "math"))
    func math(_ c: ProcessGolden.Case) throws { try GoldenRunner.check(c) }

    @Test("Image Calculator", arguments: ProcessGolden.cases(ProcessGolden.math, op: "calc"))
    func calculator(_ c: ProcessGolden.Case) throws { try GoldenRunner.check(c) }
}

@Suite("Hyperstack tools match ImageJ")
struct HyperstackGoldenTests {
    @Test func fixturesPresent() {
        #expect(ProcessGolden.cases(ProcessGolden.hyperstack).count > 30)
    }

    @Test("Split, merge, substack, reduce, arrange", arguments: ProcessGolden.cases(ProcessGolden.hyperstack))
    func tool(_ c: ProcessGolden.Case) throws { try GoldenRunner.check(c) }
}
