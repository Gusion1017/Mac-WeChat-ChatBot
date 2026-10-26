import XCTest
@testable import WeChatAI

final class CommandLineToolsTests: XCTestCase {
    /// 所有 macOS 上都存在且可执行的系统文件，用于验证路径过滤（不启动任何进程）。
    private let executable = "/bin/sh"
    private let otherExecutable = "/usr/bin/xcrun"
    private let missing = "/nonexistent/wechatai/command-line-tools"
    private let developerDirectory = "/Applications/Xcode.app/Contents/Developer"

    func testClassifyWithoutDeveloperDirectoryIsNotReady() {
        let status = CommandLineTools.classify(
            developerDirectory: nil,
            python3Path: nil,
            otoolPath: nil,
            pythonVersion: nil
        )
        XCTAssertNil(status.developerDirectory)
        XCTAssertNil(status.python3Path)
        XCTAssertNil(status.otoolPath)
        XCTAssertNil(status.pythonVersion)
        XCTAssertFalse(status.isReady)
    }

    func testClassifyDeveloperDirectoryOnlyIsNotReady() {
        let status = CommandLineTools.classify(
            developerDirectory: developerDirectory,
            python3Path: nil,
            otoolPath: nil,
            pythonVersion: nil
        )
        XCTAssertEqual(status.developerDirectory, developerDirectory)
        XCTAssertFalse(status.isReady)
    }

    func testClassifyMissingPythonIsNotReady() {
        let status = CommandLineTools.classify(
            developerDirectory: developerDirectory,
            python3Path: nil,
            otoolPath: otherExecutable,
            pythonVersion: "3.9.6"
        )
        XCTAssertNil(status.python3Path)
        XCTAssertEqual(status.otoolPath, otherExecutable)
        XCTAssertFalse(status.isReady)
    }

    func testClassifyMissingOtoolIsNotReady() {
        let status = CommandLineTools.classify(
            developerDirectory: developerDirectory,
            python3Path: executable,
            otoolPath: nil,
            pythonVersion: "3.9.6"
        )
        XCTAssertEqual(status.python3Path, executable)
        XCTAssertNil(status.otoolPath)
        XCTAssertFalse(status.isReady)
    }

    func testClassifyWithExecutableToolsIsReady() {
        let status = CommandLineTools.classify(
            developerDirectory: developerDirectory,
            python3Path: executable,
            otoolPath: otherExecutable,
            pythonVersion: "3.9.6"
        )
        XCTAssertEqual(status.developerDirectory, developerDirectory)
        XCTAssertEqual(status.python3Path, executable)
        XCTAssertEqual(status.otoolPath, otherExecutable)
        XCTAssertEqual(status.pythonVersion, "3.9.6")
        XCTAssertTrue(status.isReady)
    }

    func testClassifyFiltersNonExecutablePaths() {
        let status = CommandLineTools.classify(
            developerDirectory: developerDirectory,
            python3Path: missing,
            otoolPath: otherExecutable,
            pythonVersion: "3.9.6"
        )
        XCTAssertNil(status.python3Path)
        XCTAssertFalse(status.isReady)
    }

    func testClassifyFiltersNonExecutableOtool() {
        let status = CommandLineTools.classify(
            developerDirectory: developerDirectory,
            python3Path: executable,
            otoolPath: missing,
            pythonVersion: "3.9.6"
        )
        XCTAssertNil(status.otoolPath)
        XCTAssertFalse(status.isReady)
    }

    func testClassifyTreatsEmptyStringsAsMissing() {
        let status = CommandLineTools.classify(
            developerDirectory: "   ",
            python3Path: "",
            otoolPath: "\n",
            pythonVersion: " "
        )
        XCTAssertNil(status.developerDirectory)
        XCTAssertNil(status.python3Path)
        XCTAssertNil(status.otoolPath)
        XCTAssertNil(status.pythonVersion)
        XCTAssertFalse(status.isReady)
    }

    func testClassifyTrimsSurroundingWhitespace() {
        let status = CommandLineTools.classify(
            developerDirectory: "  \(developerDirectory)\n",
            python3Path: " \(executable) ",
            otoolPath: "\t\(otherExecutable)\n",
            pythonVersion: " 3.9.6 "
        )
        XCTAssertEqual(status.developerDirectory, developerDirectory)
        XCTAssertEqual(status.python3Path, executable)
        XCTAssertEqual(status.otoolPath, otherExecutable)
        XCTAssertEqual(status.pythonVersion, "3.9.6")
        XCTAssertTrue(status.isReady)
    }
}
