import Foundation

/// Tiny helper: collects the text of every element that has no child elements.
/// Good enough for Sonos answers, where each value is a simple element.
enum SimpleXML {
    static func leafValues(in data: Data) -> [String: String] {
        let delegate = LeafParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        return delegate.values
    }

    static func leafValues(in string: String) -> [String: String] {
        leafValues(in: Data(string.utf8))
    }

    private final class LeafParser: NSObject, XMLParserDelegate {
        struct Frame { var name: String; var text = ""; var hasChild = false }
        var stack: [Frame] = []
        var values: [String: String] = [:]

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                    qualifiedName: String?, attributes: [String: String] = [:]) {
            if !stack.isEmpty { stack[stack.count - 1].hasChild = true }
            stack.append(Frame(name: name))
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if !stack.isEmpty { stack[stack.count - 1].text += string }
        }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?,
                    qualifiedName: String?) {
            guard let frame = stack.popLast() else { return }
            if !frame.hasChild { values[frame.name] = frame.text }
        }
    }
}
