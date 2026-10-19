const diagram = document.getElementById('diagram');
const reportHeight = () => {
  window.webkit.messageHandlers.mermaidHeight.postMessage(Math.ceil(diagram.getBoundingClientRect().height + 12));
};

new ResizeObserver(reportHeight).observe(diagram);

window.renderDiagram = async (source, dark) => {
  mermaid.initialize({
    startOnLoad: false,
    securityLevel: 'strict',
    htmlLabels: false,
    theme: dark ? 'dark' : 'default',
    maxTextSize: 20000,
    maxEdges: 200,
    flowchart: { useMaxWidth: true }
  });
  const id = 'typeflux-mermaid-' + Math.random().toString(36).slice(2);
  const result = await mermaid.render(id, source);
  diagram.innerHTML = result.svg;
  reportHeight();
  return true;
};
