import Foundation
import UseCases
import AST
import Resolver
import Algorithms
import Parser
import Formatter

public class Generator {

    private let fileContents: String
    private let line: Int
    private let column: Int
    private let templateName: String
    private let useTabsForIndentation: Bool
    private let indentationWidth: Int
    private let resolver: Resolver

    public init(fromFileContents fileContents: String,
                projectURL: URL,
                line: Int,
                column: Int,
                templateName: String,
                useTabsForIndentation: Bool,
                indentationWidth: Int) {
        self.fileContents = fileContents
        self.line = line
        self.column = column
        self.templateName = templateName
        self.useTabsForIndentation = useTabsForIndentation
        self.indentationWidth = indentationWidth
        let sourceFiles = SourceFileFinder(projectRoot: projectURL).findSourceFiles()
        self.resolver = ResolverFactory.createResolver(filePaths: Generator.filterUniqueFileNames(sourceFiles))
    }

    private static func filterUniqueFileNames(_ fileNames: [URL]) -> [String] {
        var sourceFileSet = Set<String>()
        return fileNames.map { file in
            (file.path, file.lastPathComponent)
        }.compactMap { (file, name) in
            if sourceFileSet.contains(name) {
                return nil
            }
            sourceFileSet.insert(name)
            return file
        }
    }

    public func generateMock() -> (BufferInstructions?, Error?) {
        do {
            return try tryGenerateMock()
        } catch {
            return reply(with: "Failed to parse the file")
        }
    }

    public func tryGenerateMock() throws -> (BufferInstructions?, Error?) {
        let file = try ElementParser.parseFile(fileContents)
        // TODO: create findElementAtLine:column:
        guard let cursorOffset = LocationConverter(from: .utf16, to: .utf32).convert(line: line, column: column, in: fileContents) else {
            return reply(with: "Could not get the cursor position")
        }
        guard let elementUnderCaret = CaretUtil().findElementUnderCaret(in: file, cursorOffset: Int(cursorOffset), type: Element.self) else {
            return reply(with: "No Swift element found under the cursor")
        }
        guard let typeElement = (elementUnderCaret as? TypeDeclaration) ?? ElementTreeUtil().findParentType(elementUnderCaret) else {
            return reply(with: "Place the cursor on a mock class declaration")
        }
        guard let types = typeElement.typeInheritanceClause?.inheritedTypes, types.count > 0 else {
            return reply(with: "MockClass must inherit from a class or implement at least 1 protocol")
        }
        return buildMock(toFile: file, atElement: typeElement)
    }

    private func reply(with message: String) -> (BufferInstructions?, Error?) {
        let nsError = NSError(domain: "MockGenerator.Generator", code: 1, userInfo: [NSLocalizedDescriptionKey : message])
        return (nil, nsError)
    }
    
    private func buildMock(toFile file: Element, atElement element: TypeDeclaration) -> (BufferInstructions?, Error?) {
        let mockClass = transformToMockClass(element: element)
        guard !isEmpty(mockClass: mockClass) else {
            return reply(with: "Could not find a class or protocol on \(element.name)")
        }
        let mockLines = getMockBody(from: mockClass)
        guard !mockLines.isEmpty else {
            return reply(with: "Found inherited types but there was nothing to mock")
        }
        let formatted = format(mockLines, relativeTo: element).map { "\($0)\n" }
        guard let instructions = BufferInstructionsFactory().create(mockClass: element, lines: formatted) else {
            return reply(with: "Could not delete body from: \(element.text)")
        }
        return (instructions, nil)
    }

    private func isEmpty(mockClass: UseCasesMockClass) -> Bool {
        return mockClass.protocols.isEmpty && mockClass.inheritedClass == nil
    }

    private func getMockBody(from mockClass: UseCasesMockClass) -> [String] {
        let templateName = self.templateName
        let view = UseCasesCallbackMockView { model in
            let view = MustacheView(templateName: templateName)
            view.render(model: model)
            return view.result
        }
        let generator = UseCasesGenerator(view: view)
        generator.set(c: mockClass)
        generator.generate()
        return view.result
    }

    private func transformToMockClass(element: Element) -> UseCasesMockClass {
        return TypeDeclarationTransformingVisitor.transformMock(element, resolver: resolver)
    }

    private func format(_ lines: [String], relativeTo element: Element) -> [String] {
        return FormatUtil(useTabs: useTabsForIndentation, spaces: indentationWidth)
                .format(lines, relativeTo: element)
    }
}
