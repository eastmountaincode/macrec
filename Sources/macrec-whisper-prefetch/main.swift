import Foundation
@preconcurrency import WhisperKit

let defaultModel = "openai_whisper-large-v3-v20240930_626MB"

func modelCacheDirectory() throws -> URL {
    let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
    let directory = appSupport
        .appendingPathComponent("MacRec", isDirectory: true)
        .appendingPathComponent("WhisperKit", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

func argumentValue(after name: String) -> String? {
    let args = CommandLine.arguments
    guard let index = args.firstIndex(of: name), args.indices.contains(index + 1) else {
        return nil
    }
    return args[index + 1]
}

let model = argumentValue(after: "--model") ?? defaultModel

func printLine(_ value: String) {
    FileHandle.standardOutput.write(Data((value + "\n").utf8))
}

do {
    let cacheDirectory = try modelCacheDirectory()
    printLine("Prefetching Whisper model: \(model)")
    printLine("Cache: \(cacheDirectory.path)")
    printLine("Finding model on Hugging Face...")

    let modelFolder = try await WhisperKit.download(variant: model, downloadBase: cacheDirectory) { progress in
        let percent = progress.fractionCompleted.isFinite ? Int(progress.fractionCompleted * 100) : 0
        printLine("Download \(percent)%")
    }

    printLine("Warming up Whisper locally...")
    let config = WhisperKitConfig(
        modelFolder: modelFolder.path,
        tokenizerFolder: cacheDirectory,
        verbose: false,
        logLevel: .error,
        prewarm: false,
        load: true,
        download: false,
        useBackgroundDownloadSession: false
    )
    _ = try await WhisperKit(config)
    printLine("Whisper model ready: \(modelFolder.path)")
} catch {
    FileHandle.standardError.write(Data("Whisper prefetch failed: \(error.localizedDescription)\n".utf8))
    exit(1)
}
