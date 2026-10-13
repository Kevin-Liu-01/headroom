import Foundation

/// Decides which processes and shell commands are heavy jobs.
public enum HeavyClassifier {
    /// Executable names whose arguments are worth reading to classify them.
    public static let interpreterNames: Set<String> = [
        "node", "python", "python3", "Python", "bun", "deno", "uv", "java", "ruby",
    ]

    public static func needsArgs(name: String) -> Bool {
        interpreterNames.contains(name) || name.hasPrefix("python3.")
    }

    private static let modelWords = [
        "torch", "transformers", "diffusers", "whisper", "mlx", "model", "infer", "train", "llm",
        "embed", "transcri", "segment", "sam2", "sam3", "generate", "vllm", "llama", "ollama", "demucs",
    ]

    /// Classifies a running process from its name, path and arguments.
    public static func classify(name: String, path: String, args: [String]?, gb: Double) -> HeavyKind? {
        let lower = name.lowercased()
        let lpath = path.lowercased()
        let argText = (args ?? []).dropFirst().joined(separator: " ").lowercased()

        // Claude's own Electron helpers are part of the Claude total, not jobs.
        if lpath.contains("/claude.app/") && !lpath.contains("claude-code/") { return nil }

        if lpath.contains("ms-playwright") || lpath.contains("puppeteer") || lower.contains("chrome-headless-shell")
            || lower == "google chrome" || lower == "google chrome for testing" || lower == "chromium"
            || lower == "firefox" || lower == "microsoft edge" || lower == "brave browser" || lower == "arc" {
            return .browser
        }
        if ["ffmpeg", "ffprobe", "x264", "x265", "handbrakecli", "svtav1encapp", "melt"].contains(lower) {
            return .encoder
        }
        if ["ollama", "llama-server", "llama-cli", "mlx_lm.server", "whisper-cli"].contains(lower) {
            return .model
        }
        if lower.hasPrefix("python") || lower == "uv" {
            if modelWords.contains(where: { argText.contains($0) }) || gb >= 1 { return .model }
            return nil
        }
        if ["swift-build", "swift-frontend", "swift-test", "xcodebuild", "rustc", "cargo", "clang", "ld", "gradle", "go"].contains(lower) {
            return .build
        }
        if lower == "xctest" || lower == "swiftpm-testing-helper" { return .test }
        if lower.hasPrefix("com.docker") || lower.hasPrefix("qemu-system") || lower == "colima" || lower == "orbstack"
            || lpath.contains("/docker.app/") || lpath.contains("virtualization.virtualmachine") {
            return .container
        }
        if ["node", "bun", "deno"].contains(lower) {
            if argText.contains("vitest") || argText.contains("jest") || argText.contains("playwright test") || argText.contains("@playwright/test") {
                return .test
            }
            if argText.contains("next dev") || argText.contains("next-server") || argText.contains("/vite") || argText.contains("vite ")
                || argText.contains("webpack serve") || argText.contains("wrangler dev") || argText.contains("next start") {
                return .devServer
            }
            if argText.contains("next build") || argText.contains("/tsc") || argText.contains("webpack") || argText.contains("turbo")
                || argText.contains("esbuild") || argText.contains("rollup") || argText.contains("hyperframes") || argText.contains("remotion") {
                return .build
            }
            if argText.contains("playwright") || argText.contains("puppeteer") { return .browser }
        }
        return nil
    }

    public struct CommandMatch: Equatable, Sendable {
        public var kind: HeavyKind
        public var what: String
    }

    private static let commandPatterns: [(HeavyKind, String, String)] = [
        (.encoder, #"(^|[\s;&|/(])(ffmpeg|x264|x265|HandBrakeCLI|melt)(\s|$)"#, "an encode"),
        (.encoder, #"\b(hyperframes|remotion)\s+render\b"#, "a video render"),
        (.model, #"(^|[\s;&|/(])(ollama\s+run|llama-cli|llama-server|mlx_lm\.\w+|whisper(-cli)?|torchrun|accelerate\s+launch|vllm)(\s|$)"#, "a model run"),
        (.model, #"(^|[\s;&|/(])(python3?(\.\d+)?|uv\s+run(\s+python3?)?)\s+[^;&|]*(torch|transformers|diffusers|whisper|mlx|model|infer|train|llm|embed|transcri|segment|sam2|sam3|generate|demucs)"#, "a Python model run"),
        (.browser, #"\b(playwright|puppeteer|chromium|chrome-headless-shell|agent-browser|browser-use)\b"#, "a browser"),
        (.browser, #"open\s+-a\s+["']?Google Chrome"#, "a browser"),
        (.devServer, #"\bnext\s+dev\b"#, "a Next.js dev server"),
        (.build, #"\bnext\s+build\b"#, "a Next.js build"),
        (.devServer, #"\b(pnpm|npm|yarn|bun)\s+(run\s+)?(dev|start|serve|storybook)\b"#, "a dev server"),
        (.build, #"\b(pnpm|npm|yarn|bun)\s+(run\s+)?(build|typecheck)\b"#, "a package build"),
        (.build, #"\bturbo\s+(run\s+)?(build|dev|test|typecheck)\b"#, "a turbo run"),
        (.test, #"\bvitest\b"#, "a vitest run"),
        (.test, #"\bjest\b"#, "a jest run"),
        (.test, #"\b(pnpm|npm|yarn|bun)\s+(run\s+)?test\b"#, "a test run"),
        (.devServer, #"\b(vite|webpack-dev-server|wrangler\s+dev)\b"#, "a dev server"),
        (.build, #"\bwebpack\b"#, "a webpack build"),
        (.container, #"\b(docker|docker-compose|podman|colima)\b"#, "a container"),
        (.build, #"\bswift\s+(build|test|run)\b"#, "a Swift build"),
        (.build, #"\bxcodebuild\b"#, "an Xcode build"),
        (.build, #"\bcargo\s+(build|test|run)\b"#, "a Cargo build"),
        (.build, #"\bgo\s+(build|test)\b"#, "a Go build"),
        (.build, #"\b(gradle|gradlew|bazel)\b"#, "a build"),
    ]

    private static let compiled: [(HeavyKind, NSRegularExpression, String)] = commandPatterns.compactMap { kind, pattern, what in
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        return (kind, re, what)
    }

    /// A segment that waits for memory, or runs its job under a memory gate. Heavy segments after it are not flagged.
    private static func isGate(_ segment: String) -> Bool {
        let words = segment.split(separator: " ").map(String.init)
        guard let first = words.first else { return false }
        if (first as NSString).lastPathComponent == "headroom" { return true }
        return words.prefix(3).contains { $0.hasSuffix("heavy.py") }
    }

    /// Tools that only read or print text. A segment that starts with one of them names heavy tools without running them.
    private static let readOnlyTools: Set<String> = [
        "grep", "rg", "cat", "echo", "printf", "git", "gh", "ls", "find", "head", "tail", "sed", "awk", "jq",
        "which", "type", "man", "less", "wc", "sort", "diff", "test", "[", "true", "false", "cd", "export",
    ]

    /// Splits a shell command into segments at ;, &&, || and |.
    static func segments(_ command: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var quote: Character?
        let chars = Array(command)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if let q = quote {
                current.append(c)
                if c == q { quote = nil }
            } else if c == "'" || c == "\"" {
                quote = c
                current.append(c)
            } else if c == ";" || c == "|" || c == "&" || c == "\n" {
                if !current.trimmingCharacters(in: .whitespaces).isEmpty { parts.append(current) }
                current = ""
            } else {
                current.append(c)
            }
            i += 1
        }
        if !current.trimmingCharacters(in: .whitespaces).isEmpty { parts.append(current) }
        return parts
    }

    /// Classifies a shell command an agent is about to run.
    public static func classify(command: String) -> CommandMatch? {
        if command.isEmpty { return nil }
        for segment in segments(command) {
            let trimmed = segment.trimmingCharacters(in: .whitespaces)
            if isGate(trimmed) { return nil }
            let first = trimmed.split(separator: " ", maxSplits: 1).first.map(String.init) ?? ""
            if readOnlyTools.contains(first) { continue }
            let range = NSRange(trimmed.startIndex..., in: trimmed)
            for (kind, re, what) in compiled where re.firstMatch(in: trimmed, options: [], range: range) != nil {
                return CommandMatch(kind: kind, what: what)
            }
        }
        return nil
    }
}
