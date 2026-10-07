import Foundation
import Testing

@testable import Elstar

struct AppleCalculatorTests {
    @Test(arguments: [
        ("0.1+0.2", "0.3"),
        ("250*18%+37.5", "82.5"),
        ("(2+3)*4", "20"),
        ("2+3*4", "14"),
        ("-2^2", "-4"),
        ("(-2)^2", "4"),
        ("2^3^2", "512"),
        ("2^-2", "0.25"),
        ("1e3+2.5", "1002.5"),
    ])
    func evaluatesExactExpressions(_ expression: String, _ expected: String) throws {
        let result = try AppleCalculator.evaluate(expression)
        #expect(result.expression == expression)
        #expect(result.value == expected)
        #expect(!result.isApproximate)
    }

    @Test func divisionProducesApproximateResult() throws {
        let result = try AppleCalculator.evaluate("1/3")
        #expect(result.isApproximate)
        var a = Decimal(1)
        var b = Decimal(3)
        var expected = Decimal()
        NSDecimalDivide(&expected, &a, &b, .plain)
        var storage = expected
        #expect(result.value == NSDecimalString(&storage, Locale(identifier: "en_US_POSIX")))
        #expect(result.value.hasPrefix("0.33333333333333333333333333333333333333"))
    }

    @Test(arguments: [
        "",
        "   ",
        "2+",
        "+",
        "*2",
        "1+2 3",
        "1,2",
        "1e",
        "1e+",
        "1..2",
        "1/0",
        "0^0",
        "0^-1",
        "2^1.5",
        "2^1001",
        "2^-1001",
        "1e200",
        "1e-200",
        "1e127*1e127",
        "1e-127/1e127",
        "1e127/1e-127",
        "1e-127*1e-127",
        "1.234567890123456789012345678901234567890",
        "(1",
        "1)",
        "%5",
        "1^.5",
    ])
    func rejectsInvalidExpressions(_ expression: String) {
        #expect(throws: AppleToolError.self) {
            try AppleCalculator.evaluate(expression)
        }
    }

    @Test func largeMultiplicationReportsApproximation() throws {
        let result = try AppleCalculator.evaluate("99999999999999999999999999999999999999*99999999999999999999999999999999999999")
        #expect(result.isApproximate)
    }

    @Test func enforcesInputTokenAndDepthBounds() {
        let oversizedInput = String(repeating: "1+", count: 257)
        #expect(oversizedInput.utf8.count > 512)
        #expect(throws: AppleToolError.self) {
            try AppleCalculator.evaluate(oversizedInput)
        }

        let tokenLimit = stride(from: 1, to: 129, by: 2).map { _ in "1+1" }.joined(separator: "+")
        #expect(throws: AppleToolError.self) {
            try AppleCalculator.evaluate(tokenLimit)
        }

        let unaryChain = String(repeating: "-", count: 40) + "1"
        #expect(throws: AppleToolError.self) {
            try AppleCalculator.evaluate(unaryChain)
        }

        let powerChain = String(repeating: "1^", count: 40) + "1"
        #expect(throws: AppleToolError.self) {
            try AppleCalculator.evaluate(powerChain)
        }

        let parenthesisChain = String(repeating: "(", count: 40) + "1" + String(repeating: ")", count: 40)
        #expect(throws: AppleToolError.self) {
            try AppleCalculator.evaluate(parenthesisChain)
        }
    }
    @Test("Precision loss in addition and subtraction is reported")
    func widelySeparatedOperandsReportApproximation() throws {
        #expect(try AppleCalculator.evaluate("1e39+1").isApproximate)
        #expect(try AppleCalculator.evaluate("1e39-1").isApproximate)
        #expect(try AppleCalculator.evaluate("1e20+1").isApproximate == false)
        #expect(try AppleCalculator.evaluate("0.3-0.1").value == "0.2")
    }

}
