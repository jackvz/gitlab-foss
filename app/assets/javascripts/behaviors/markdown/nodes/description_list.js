// Transforms generated HTML back to GFM for Banzai::Filter::MarkdownFilter
export default () => ({
  name: 'description_list',
  schema: {
    content: '(description_term+ description_details+)+',
    group: 'block',
    parseDOM: [{ tag: 'dl' }],
    toDOM: () => ['dl', 0],
  },

  toMarkdown(state, node) {
    state.write('<dl>\n');
    state.wrapBlock('  ', null, node, () => state.renderContent(node));
    state.flushClose(1);
    state.ensureNewLine();
    state.write('</dl>');
    state.closeBlock(node);
  },
});
