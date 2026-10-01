const equality = new Set(['===', '!==', '==', '!=']);

function isTypeofObject(left, right) {
  return (
    left.type === 'UnaryExpression' &&
    left.operator === 'typeof' &&
    right.type === 'Literal' &&
    right.value === 'object'
  );
}

export default {
  meta: { name: 'effect-boundaries' },
  rules: {
    'no-object-typeof-guard': {
      meta: {
        type: 'suggestion',
        schema: [],
        messages: {
          guard:
            'Decode unknown values with Schema, or narrow them with the Predicate module, instead of a typeof "object" guard.',
        },
      },
      create(context) {
        return {
          BinaryExpression(node) {
            if (
              equality.has(node.operator) &&
              (isTypeofObject(node.left, node.right) ||
                isTypeofObject(node.right, node.left))
            ) {
              context.report({ node, messageId: 'guard' });
            }
          },
        };
      },
    },
    'no-json-parse': {
      meta: {
        type: 'suggestion',
        schema: [],
        messages: {
          parse:
            'Decode JSON text with Schema.fromJsonString(schema), or Schema.UnknownFromJsonString for unknown shapes, instead of JSON.parse.',
        },
      },
      create(context) {
        return {
          CallExpression(node) {
            if (context.sourceCode.getText(node.callee) === 'JSON.parse') {
              context.report({ node, messageId: 'parse' });
            }
          },
        };
      },
    },
  },
};
