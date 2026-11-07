import Foundation
import os

// A JSON completion spec, loosely modeled on Fig/withfig autocomplete specs.
//
// {
//   "name": "deploy",
//   "description": "Ship it",
//   "subcommands": [{ "name": ["staging", "stg"], "description": "Deploy to staging" }],
//   "options": [{ "name": ["-f", "--force"], "description": "Skip checks" },
//               { "name": "--region", "args": { "suggestions": ["eu", "us"] } }],
//   "args": { "name": "service", "generators": { "script": "ls services" } }
// }

public final class CompletionSpec: Decodable, Sendable {
    public let names: [String]
    public let description: String?
    public let subcommands: [CompletionSpec]
    public let options: [OptionSpec]
    public let args: [ArgSpec]
    /// Parse `<cmd> --help` for options when the spec has none.
    public let parseHelp: Bool

    enum CodingKeys: String, CodingKey { case name, description, subcommands, options, args, parseHelp }

    public init(names: [String], description: String? = nil, subcommands: [CompletionSpec] = [], options: [OptionSpec] = [], args: [ArgSpec] = [], parseHelp: Bool = false) {
        self.names = names; self.description = description; self.subcommands = subcommands
        self.options = options; self.args = args; self.parseHelp = parseHelp
    }

    public required init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        names = try c.decodeFlexible(String.self, forKey: .name)
        description = try c.decodeIfPresent(String.self, forKey: .description)
        subcommands = try c.decodeFlexible(CompletionSpec.self, forKey: .subcommands)
        options = try c.decodeFlexible(OptionSpec.self, forKey: .options)
        args = try c.decodeFlexible(ArgSpec.self, forKey: .args)
        parseHelp = try c.decodeIfPresent(Bool.self, forKey: .parseHelp) ?? false
    }

    public func subcommand(named n: String) -> CompletionSpec? { subcommands.first { $0.names.contains(n) } }
}

public struct OptionSpec: Decodable, Sendable {
    public var names: [String]
    public var description: String?
    public var args: [ArgSpec]
    /// Also valid on every subcommand below this one.
    public var isPersistent: Bool
    public var isRepeatable: Bool

    enum CodingKeys: String, CodingKey { case name, description, args, isPersistent, isRepeatable }

    public init(names: [String], description: String? = nil, args: [ArgSpec] = [], isPersistent: Bool = false, isRepeatable: Bool = false) {
        self.names = names; self.description = description; self.args = args
        self.isPersistent = isPersistent; self.isRepeatable = isRepeatable
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        names = try c.decodeFlexible(String.self, forKey: .name)
        description = try c.decodeIfPresent(String.self, forKey: .description)
        args = try c.decodeFlexible(ArgSpec.self, forKey: .args)
        isPersistent = try c.decodeIfPresent(Bool.self, forKey: .isPersistent) ?? false
        isRepeatable = try c.decodeIfPresent(Bool.self, forKey: .isRepeatable) ?? false
    }
}

public struct ArgSpec: Decodable, Sendable {
    public var name: String?
    public var description: String?
    public var suggestions: [Suggestion]
    /// "filepaths" and/or "folders"
    public var template: [String]
    public var generators: [GeneratorSpec]
    public var isVariadic: Bool
    public var isOptional: Bool
    /// The argument is itself a command (sudo, xargs, time…).
    public var isCommand: Bool

    enum CodingKeys: String, CodingKey { case name, description, suggestions, template, generators, generator, isVariadic, isOptional, isCommand }

    public init(name: String? = nil, suggestions: [Suggestion] = [], template: [String] = [], generators: [GeneratorSpec] = [], isVariadic: Bool = false, isOptional: Bool = false, isCommand: Bool = false) {
        self.name = name; self.suggestions = suggestions; self.template = template; self.generators = generators
        self.isVariadic = isVariadic; self.isOptional = isOptional; self.isCommand = isCommand
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        description = try c.decodeIfPresent(String.self, forKey: .description)
        suggestions = try c.decodeFlexible(Suggestion.self, forKey: .suggestions)
        template = try c.decodeFlexible(String.self, forKey: .template)
        generators = try c.decodeFlexible(GeneratorSpec.self, forKey: .generators) + c.decodeFlexible(GeneratorSpec.self, forKey: .generator)
        isVariadic = try c.decodeIfPresent(Bool.self, forKey: .isVariadic) ?? false
        isOptional = try c.decodeIfPresent(Bool.self, forKey: .isOptional) ?? false
        isCommand = try c.decodeIfPresent(Bool.self, forKey: .isCommand) ?? false
    }
}

public struct Suggestion: Decodable, Sendable, Hashable {
    public var name: String
    public var description: String?

    public init(name: String, description: String? = nil) { self.name = name; self.description = description }

    public init(from decoder: Decoder) throws {
        if let s = try? decoder.singleValueContainer().decode(String.self) {
            name = s; description = nil; return
        }
        struct Obj: Decodable { var name: String; var description: String? }
        let o = try Obj(from: decoder)
        name = o.name; description = o.description
    }
}

/// Produces suggestions at completion time, either with a built-in native
/// generator (fast) or by running a shell script in the current folder.
public struct GeneratorSpec: Decodable, Sendable {
    /// Name of a native generator, e.g. "git_branches". See `Generators`.
    public var builtin: String?
    /// Shell script; each output line becomes a suggestion.
    public var script: String?
    /// Splits each line into "name<sep>description".
    public var descriptionSeparator: String?
    public var cacheSeconds: Double?

    public init(builtin: String? = nil, script: String? = nil, descriptionSeparator: String? = nil, cacheSeconds: Double? = nil) {
        self.builtin = builtin; self.script = script; self.descriptionSeparator = descriptionSeparator; self.cacheSeconds = cacheSeconds
    }

    public init(from decoder: Decoder) throws {
        if let s = try? decoder.singleValueContainer().decode(String.self) {
            // "generator": "git_branches" is shorthand for a builtin.
            builtin = s; script = nil; descriptionSeparator = nil; cacheSeconds = nil; return
        }
        enum K: String, CodingKey { case builtin, script, descriptionSeparator, cacheSeconds }
        let c = try decoder.container(keyedBy: K.self)
        builtin = try c.decodeIfPresent(String.self, forKey: .builtin)
        script = try c.decodeIfPresent(String.self, forKey: .script)
        descriptionSeparator = try c.decodeIfPresent(String.self, forKey: .descriptionSeparator)
        cacheSeconds = try c.decodeIfPresent(Double.self, forKey: .cacheSeconds)
    }
}

extension KeyedDecodingContainer {
    /// Decodes either a single value or an array of values; missing means empty.
    func decodeFlexible<T: Decodable>(_ type: T.Type, forKey key: Key) throws -> [T] {
        guard contains(key), try !decodeNil(forKey: key) else { return [] }
        if let arr = try? decode([T].self, forKey: key) { return arr }
        return [try decode(T.self, forKey: key)]
    }
}

/// All known specs, keyed by command name. User specs override built-in ones.
public final class SpecRegistry: Sendable {
    /// Imported Fig specs are indexed by name and loaded on first use.
    private struct LazySpec: Sendable { let file: URL; let description: String }
    private struct State: Sendable {
        var specs: [String: CompletionSpec] = [:]
        var lazyIndex: [String: LazySpec] = [:]
        var lazyFailed: Set<String> = []
        var loadErrors: [String] = []
    }
    private let state = OSAllocatedUnfairLock(initialState: State())

    public init() {}

    public var loadErrors: [String] { state.withLock { $0.loadErrors } }

    public func spec(for command: String) -> CompletionSpec? {
        enum Lookup { case found(CompletionSpec), lazy(URL), none }
        let lookup: Lookup = state.withLock { st in
            if let s = st.specs[command] { return .found(s) }
            guard let entry = st.lazyIndex[command], !st.lazyFailed.contains(command) else { return .none }
            return .lazy(entry.file)
        }
        let file: URL
        switch lookup {
        case .found(let s): return s
        case .none: return nil
        case .lazy(let f): file = f
        }
        // Read and decode outside the lock.
        guard let data = try? Data(contentsOf: file),
              let spec = try? JSONDecoder().decode(CompletionSpec.self, from: data) else {
            state.withLock { _ = $0.lazyFailed.insert(command) }
            return nil
        }
        return state.withLock { st in
            // Hand-written specs registered earlier win over imported ones.
            for n in spec.names where st.specs[n] == nil { st.specs[n] = spec }
            return st.specs[command]
        }
    }

    /// A short description of a command, without loading its full spec.
    public func describe(_ command: String) -> String? {
        state.withLock { st in
            if let d = st.specs[command]?.description, !d.isEmpty { return d }
            if let d = st.lazyIndex[command]?.description, !d.isEmpty { return d }
            return nil
        }
    }

    /// Registers a folder of imported specs (with an index.json) for lazy loading.
    public func loadLazy(directory: URL) {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("index.json")),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [String: [String: String]] else { return }
        let entries = raw.compactMap { name, v -> (String, LazySpec)? in
            guard let file = v["file"] else { return nil }
            return (name, LazySpec(file: directory.appendingPathComponent(file + ".json"), description: v["description"] ?? ""))
        }
        state.withLock { st in for (name, e) in entries { st.lazyIndex[name] = e } }
    }

    public var lazyCount: Int { state.withLock { $0.lazyIndex.count } }

    public var commandNames: [String] { state.withLock { Array($0.specs.keys) } }

    public func register(_ spec: CompletionSpec) {
        state.withLock { st in for n in spec.names { st.specs[n] = spec } }
    }

    /// Loads every `*.json` spec file in a directory. Each file holds one spec or an array.
    public func load(directory: URL) {
        let fig = directory.appendingPathComponent("fig")
        if FileManager.default.fileExists(atPath: fig.appendingPathComponent("index.json").path) { loadLazy(directory: fig) }
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
        for f in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) where f.pathExtension == "json" {
            load(file: f)
        }
    }

    public func load(file: URL) {
        guard let data = try? Data(contentsOf: file) else { return }
        do {
            if let many = try? JSONDecoder().decode([CompletionSpec].self, from: data) {
                many.forEach(register)
            } else {
                register(try JSONDecoder().decode(CompletionSpec.self, from: data))
            }
        } catch {
            let message = "\(file.lastPathComponent): \(error)"
            state.withLock { $0.loadErrors.append(message) }
        }
    }

    /// Built-in specs shipped inside AnserCore.
    public func loadBuiltins() {
        if let dir = Bundle.module.url(forResource: "Specs", withExtension: nil) { load(directory: dir) }
    }
}
