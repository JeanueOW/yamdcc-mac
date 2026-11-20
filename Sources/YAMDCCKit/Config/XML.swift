// XML.swift
// A tiny, dependency-free XML tree used to read and write YAMDCC configs.

import Foundation

public final class XMLNode {
    public var name: String
    public var attributes: [String: String]
    public var children: [XMLNode]
    public var text: String

    public init(name: String, attributes: [String: String] = [:]) {
        self.name = name
        self.attributes = attributes
        self.children = []
        self.text = ""
    }

    public func child(_ name: String) -> XMLNode? {
        children.first { $0.name == name }
    }

    public func children(_ name: String) -> [XMLNode] {
        children.filter { $0.name == name }
    }

    public func string(_ name: String, default fallback: String = "") -> String {
        guard let node = child(name) else { return fallback }
        return node.text
    }

    public func int(_ name: String, default fallback: Int = 0) -> Int {
        Int(string(name).trimmingCharacters(in: .whitespacesAndNewlines)) ?? fallback
    }

    public func bool(_ name: String, default fallback: Bool = false) -> Bool {
        switch string(name).lowercased() {
        case "true", "1": return true
        case "false", "0": return false
        default: return fallback
        }
    }

    public func bytes(_ name: String) -> [UInt8] {
        guard let container = child(name) else { return [] }
        return container.children.compactMap { UInt8($0.text.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }

    public var trimmedText: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public enum XMLParseError: LocalizedError {
    case empty
    case parser(String)

    public var errorDescription: String? {
        switch self {
        case .empty: return "XML 文件为空"
        case .parser(let message): return "XML 解析失败：\(message)"
        }
    }
}

public enum XMLTree {

    public static func parse(data: Data) throws -> XMLNode {
        let delegate = TreeDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.shouldProcessNamespaces = false
        parser.shouldResolveExternalEntities = false
        guard parser.parse(), let root = delegate.root else {
            throw XMLParseError.parser(delegate.errorMessage ?? parser.parserError?.localizedDescription ?? "未知错误")
        }
        return root
    }

    public static func parse(contentsOf url: URL) throws -> XMLNode {
        let data = try Data(contentsOf: url)
        return try parse(data: data)
    }

    private final class TreeDelegate: NSObject, XMLParserDelegate {
        var root: XMLNode?
        private var stack: [XMLNode] = []
        var errorMessage: String?

        func parser(_ parser: XMLParser, didStartElement elementName: String,
                    namespaceURI: String?, qualifiedName qName: String?,
                    attributes attributeDict: [String: String] = [:]) {
            let node = XMLNode(name: elementName, attributes: attributeDict)
            if let parent = stack.last {
                parent.children.append(node)
            } else if root == nil {
                root = node
            }
            stack.append(node)
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            stack.last?.text += string
        }

        func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
            if let text = String(data: CDATABlock, encoding: .utf8) {
                stack.last?.text += text
            }
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String,
                    namespaceURI: String?, qualifiedName qName: String?) {
            stack.last?.text = stack.last?.trimmedText ?? ""
            if !stack.isEmpty { stack.removeLast() }
        }

        func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) {
            errorMessage = parseError.localizedDescription
        }
    }
}

// MARK: - Writer

public struct XMLBuilder {
    private var out: String = ""
    private var depth: Int = 0

    public init() {}

    private var indent: String { String(repeating: "\t", count: depth) }

    public static func escape(_ value: String) -> String {
        var escaped = value
        escaped = escaped.replacingOccurrences(of: "&", with: "&amp;")
        escaped = escaped.replacingOccurrences(of: "<", with: "&lt;")
        escaped = escaped.replacingOccurrences(of: ">", with: "&gt;")
        escaped = escaped.replacingOccurrences(of: "\"", with: "&quot;")
        return escaped
    }

    public mutating func raw(_ line: String) {
        out += line + "\n"
    }

    public mutating func open(_ name: String, attributes: [(String, String)] = []) {
        let attrs = attributes.map { " \($0.0)=\"\(XMLBuilder.escape($0.1))\"" }.joined()
        out += "\(indent)<\(name)\(attrs)>\n"
        depth += 1
    }

    public mutating func close(_ name: String) {
        depth = max(0, depth - 1)
        out += "\(indent)</\(name)>\n"
    }

    public mutating func element(_ name: String, _ value: String) {
        out += "\(indent)<\(name)>\(XMLBuilder.escape(value))</\(name)>\n"
    }

    public mutating func element(_ name: String, _ value: Int) {
        element(name, String(value))
    }

    public mutating func element(_ name: String, _ value: Bool) {
        element(name, value ? "true" : "false")
    }

    public mutating func byteArray(_ name: String, _ values: [UInt8], itemName: String = "unsignedByte") {
        open(name)
        for value in values {
            element(itemName, Int(value))
        }
        close(name)
    }

    public var string: String { out }
}
