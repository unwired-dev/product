# JSDoc Patterns

Use JSDoc for exported TypeScript functions when the call contract is not obvious from the signature alone.

## Document With Examples

Add a JSDoc block with `@example` for:

- Exported functions that are part of a package or backend module boundary.
- Functions that encode product, privacy, or security rules.
- Functions with non-obvious argument constraints or return shapes.
- Helpers that future callers are likely to copy into another slice.
- Test utilities or factories with required setup order.

Do not add JSDoc just to restate names, primitive types, or implementation steps that are already clear from the code.

## Shape

Prefer this structure:

```ts
/**
 * Short contract-focused summary.
 *
 * Add one short paragraph only when the reason, invariant, or privacy boundary
 * matters to callers.
 *
 * @example
 * ```ts
 * const payload = healthPayload(123);
 *
 * expect(payload).toStrictEqual({
 *   service: 'private-email-api',
 *   status: 'ok',
 *   bootstrapVersion: 1,
 *   serverTime: 123,
 * });
 * ```
 */
export const healthPayload = (serverTime: number) => ({
  service: 'private-email-api',
  status: 'ok',
  bootstrapVersion: 1,
  serverTime,
});
```

## Rules

- Keep the first sentence about caller-visible behavior.
- Use `@example` for real, runnable-looking usage.
- Prefer examples that show the full input and output shape.
- Mention privacy boundaries when a function intentionally excludes sensitive data.
- Avoid long lifecycle narratives; use ADRs for durable architecture reasoning.
- Do not document private one-line helpers unless they carry a domain rule.

