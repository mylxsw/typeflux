import Testing
@testable import Typeflux

@Suite("Ask Mermaid fences")
struct AskMermaidFencesTests {
    @Test func `extracts complete Mermaid fences and keeps surrounding Markdown`() {
        let source = """
        # Plan

        ```mermaid
        flowchart TD
          A[Start] --> B[Done]
        ```

        Follow up.
        """
        #expect(AskMermaidFences.split(source) == [
            .markdown("# Plan"),
            .diagram("flowchart TD\n  A[Start] --> B[Done]"),
            .markdown("Follow up.")
        ])
    }

    @Test func `incomplete fences remain ordinary text`() {
        let source = "Before\n```mermaid\nflowchart TD\n A --> B"
        #expect(AskMermaidFences.split(source) == [.markdown(source)])
    }

    @Test func `does not find Mermaid syntax inside another code block`() {
        let source = """
        ````text
        ```mermaid
        flowchart TD
        ```
        ````
        """
        #expect(AskMermaidFences.split(source) == [.markdown(source)])
    }

    @Test func `accepts tildes and language case but leaves oversized diagrams as code`() {
        let valid = "~~~ Mermaid\nflowchart LR\nA --> B\n~~~"
        #expect(AskMermaidFences.split(valid) == [.diagram("flowchart LR\nA --> B")])
        let oversized = "```mermaid\n" + String(repeating: "A", count: 20_001) + "\n```"
        #expect(AskMermaidFences.split(oversized) == [.markdown(oversized)])
    }
}
