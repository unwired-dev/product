// Constant opacity calculations have no layout or variable basis. Parse only number/percentage
// arithmetic and calc/min/max/clamp, with CSS operator whitespace, types and arities. Unsupported
// functions are outside this source grammar; never let malformed math erase a hidden fallback.
const numeric = /^[+-]?(?:\d+(?:\.\d+)?|\.\d+)(?:e[+-]?\d+)?(?<unit>%?)/iu;
const constants = new Map([
  ['infinity', Infinity],
  ['-infinity', -Infinity],
  ['nan', Number.NaN],
  ['pi', Math.PI],
  ['e', Math.E],
]);
interface Scalar {
  readonly amount: number;
  readonly power: number;
}

const clampResult = (args: ReadonlyArray<Scalar | undefined>, first: Scalar) =>
  args.length === 3
    ? {
        amount: Math.max(
          args[0]?.amount ?? -Infinity,
          Math.min(first.amount, args[2]?.amount ?? Infinity),
        ),
        power: first.power,
      }
    : undefined;
const mathResult = (
  name: string | undefined,
  args: ReadonlyArray<Scalar | undefined>,
) => {
  const first = name === 'clamp' ? args[1] : args[0];
  if (
    first === undefined ||
    args.some((arg) => arg !== undefined && arg.power !== first.power)
  ) {
    return undefined;
  }
  if (name === 'calc') {
    return args.length === 1 ? first : undefined;
  }
  if (name === 'clamp') {
    return clampResult(args, first);
  }
  const amounts = args.map((arg) => arg?.amount ?? Number.NaN);
  return {
    amount: name === 'min' ? Math.min(...amounts) : Math.max(...amounts),
    power: first.power,
  };
};

export function opacityNumber(raw: string): number | undefined {
  const literal = numeric.exec(raw);
  if (literal?.[0] === raw) {
    return Number(raw.replace(/%$/u, '')) / (literal[1] === '%' ? 100 : 1);
  }
  let at = 0;
  let work = 0;
  const whitespace = () => {
    while (/[\t\n\f\r ]/u.test(raw[at] ?? '') && at < raw.length) {
      at += 1;
    }
  };
  const take = (token: string) => {
    whitespace();
    if (raw[at] !== token) {
      return false;
    }
    at += 1;
    return true;
  };
  function value(): Scalar | undefined {
    whitespace();
    work += 1;
    if (work > 64) {
      return undefined;
    }
    const number = numeric.exec(raw.slice(at));
    if (number !== null) {
      at += number[0].length;
      return {
        amount: Number(number[0].replace(/%$/u, '')),
        power: number[1] === '%' ? 1 : 0,
      };
    }
    const constant = /^(?:-?infinity|nan|pi|e)\b/iu.exec(raw.slice(at));
    if (constant !== null) {
      at += constant[0].length;
      return {
        amount: constants.get(constant[0].toLowerCase()) ?? Number.NaN,
        power: 0,
      };
    }
    if (take('(')) {
      const inner = sum();
      return take(')') ? inner : undefined;
    }
    return call();
  }
  function call(): Scalar | undefined {
    const fn = /^(?<name>calc|min|max|clamp)\(/iu.exec(raw.slice(at));
    if (fn === null) {
      return undefined;
    }
    at += fn[0].length;
    const name = fn[1]?.toLowerCase();
    const args: Array<Scalar | undefined> = [];
    do {
      if (name === 'clamp' && args.length >= 3) {
        return undefined;
      }
      whitespace();
      if (name === 'clamp' && /^none\b/iu.test(raw.slice(at))) {
        at += 4;
        args.push(undefined);
      } else {
        const arg = sum();
        if (arg === undefined) {
          return undefined;
        }
        args.push(arg);
      }
    } while (take(','));
    if (!take(')')) {
      return undefined;
    }
    return mathResult(name, args);
  }

  function product(): Scalar | undefined {
    let left = value();
    while (left !== undefined) {
      const before = at;
      whitespace();
      const operator = raw[at];
      if (operator !== '*' && operator !== '/') {
        at = before;
        break;
      }
      at += 1;
      const right = value();
      if (right === undefined) {
        return undefined;
      }
      left = {
        amount:
          operator === '*'
            ? left.amount * right.amount
            : left.amount / right.amount,
        power:
          operator === '*'
            ? left.power + right.power
            : left.power - right.power,
      };
    }
    return left;
  }
  function sum(): Scalar | undefined {
    let left = product();
    while (left !== undefined) {
      whitespace();
      const operator = raw[at];
      if (operator !== '+' && operator !== '-') {
        break;
      }
      // Unlike multiplication/division, CSS sums require whitespace on both sides.
      if (!/[\t\n\f\r ][+-][\t\n\f\r ]/u.test(raw.slice(at - 1, at + 2))) {
        return undefined;
      }
      at += 1;
      const right = product();
      if (right === undefined || right.power !== left.power) {
        return undefined;
      }
      left = {
        amount:
          operator === '+'
            ? left.amount + right.amount
            : left.amount - right.amount,
        power: left.power,
      };
    }
    return left;
  }
  // Parentheses/constants/operators are valid only within a math function.
  if (!/^(?:calc|min|max|clamp)\(/iu.test(raw)) {
    return undefined;
  }
  const result = value();
  whitespace();
  return result === undefined ||
    at !== raw.length ||
    (result.power !== 0 && result.power !== 1)
    ? undefined
    : result.amount / (result.power === 1 ? 100 : 1);
}
