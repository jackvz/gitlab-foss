// Transforms generated HTML back to GFM for Banzai::Filter::MarkdownFilter
export default () => ({
  name: 'table_cell',
  schema: {
    attrs: {
      header: { default: false },
      align: { default: null },
    },
    content: 'inline*',
    isolating: true,
    parseDOM: [
      {
        tag: 'td, th',
        getAttrs: (el) => ({
          header: el.tagName === 'TH',
          align: el.getAttribute('align') || el.style.textAlign,
        }),
      },
    ],
    toDOM: (node) => [node.attrs.header ? 'th' : 'td', { align: node.attrs.align }, 0],
  },
  toMarkdown: (state, node) => {
    state.renderInline(node);
  },
});
