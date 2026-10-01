const equality = new Set(['===', '!==', '==', '!=']);

function isTypeofObject(left, right) {
  return (
    left.type === 'UnaryExpression' &&
    left.operator === 'typeof' &&
    right.type === 'Literal' &&
    right.value === 'object'
  );
}

function memberName(member) {
  return member.computed ? member.property.value : member.property.name;
}

// Matches JSON.parse and JSON['parse'], whatever whitespace or comments separate them.
function isJsonParse(callee) {
  return (
    callee.type === 'MemberExpression' &&
    callee.object.type === 'Identifier' &&
    callee.object.name === 'JSON' &&
    memberName(callee) === 'parse'
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
            if (isJsonParse(node.callee)) {
              context.report({ node, messageId: 'parse' });
            }
          },
        };
      },
    },
  },
};
