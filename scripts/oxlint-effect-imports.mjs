function isNamespaceImport(node) {
  return (
    node.specifiers.length === 1 &&
    node.specifiers[0].type === 'ImportNamespaceSpecifier'
  );
}

export default {
  meta: { name: 'effect-imports' },
  rules: {
    'namespace-imports': {
      meta: {
        type: 'suggestion',
        schema: [],
        messages: {
          namespace:
            'Use a namespace import: import * as Module from the Effect module subpath.',
          barrel:
            'Import an Effect module subpath, for example: import * as Effect from "effect/Effect".',
        },
      },
      create(context) {
        return {
          ImportDeclaration(node) {
            const source = node.source.value;
            if (source === 'effect') {
              context.report({ node, messageId: 'barrel' });
            } else if (
              /^(effect\/|@effect\/)/u.test(source) &&
              !isNamespaceImport(node)
            ) {
              context.report({ node, messageId: 'namespace' });
            }
          },
        };
      },
    },
  },
};
