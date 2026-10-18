import * as Schema from 'effect/Schema';

export const ReportingCodeSchema = Schema.Literals([
  'unhandled-js',
  'native-crash',
  'send-failed',
  'sync-failed',
  'sign-in-failed',
  'operation-failed',
  'backend-failed',
]);
export const ReportingNameSchema = Schema.Literals([
  'Error',
  'TypeError',
  'RangeError',
  'ReferenceError',
  'SyntaxError',
  'URIError',
  'NSException',
  'NSInvalidArgumentException',
  'NSRangeException',
  'NSInternalInconsistencyException',
  'NativeCrash',
  'OperationError',
]);
export const ReportingMessageSchema = Schema.Literals([
  'Cannot convert undefined value to object',
  'Cannot convert undefined or null to object',
  'Maximum call stack size exceeded',
  'Invalid array length',
  'Invalid time value',
  'URI malformed',
  'Native bridge failed',
  'Synthetic native crash',
]);
const position = Schema.Int.check(
  Schema.isBetween({ minimum: 0, maximum: 100_000_000 }),
);
const address = Schema.String.check(Schema.isPattern(/^0x[0-9a-f]{1,16}$/iu));
export const ReportingFrameSchema = Schema.Union([
  Schema.Struct({
    kind: Schema.Literal('javascript'),
    line: position,
    column: position,
  }),
  Schema.Struct({
    kind: Schema.Literal('native'),
    address,
    imageAddress: address,
    imageUuid: Schema.String.check(
      Schema.isPattern(
        /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/iu,
      ),
    ),
  }),
]);
export const ReportingBreadcrumbSchema = Schema.Struct({
  operation: Schema.Literals([
    'app',
    'send',
    'sync',
    'sign-in',
    'account',
    'draft',
    'reader',
    'settings',
  ]),
  stage: Schema.Literals(['open', 'start', 'complete', 'failed', 'retry']),
  elapsedMs: Schema.optionalKey(
    Schema.Int.check(Schema.isBetween({ minimum: 0, maximum: 86_400_000 })),
  ),
  status: Schema.optionalKey(
    Schema.Int.check(Schema.isBetween({ minimum: 100, maximum: 599 })),
  ),
});
export const ErrorReportSchema = Schema.Struct({
  id: Schema.String.check(
    Schema.isPattern(
      /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/iu,
    ),
  ),
  createdAt: Schema.Int.check(
    Schema.isBetween({ minimum: 0, maximum: Number.MAX_SAFE_INTEGER }),
  ),
  code: ReportingCodeSchema,
  name: ReportingNameSchema,
  message: Schema.optionalKey(ReportingMessageSchema),
  frames: Schema.Array(ReportingFrameSchema).check(Schema.isMaxLength(64)),
  causes: Schema.Array(
    Schema.Struct({
      name: ReportingNameSchema,
      message: Schema.optionalKey(ReportingMessageSchema),
    }),
  ).check(Schema.isMaxLength(8)),
  breadcrumbs: Schema.Array(ReportingBreadcrumbSchema).check(
    Schema.isMaxLength(50),
  ),
});
const version = Schema.String.check(
  Schema.isPattern(/^[0-9]{1,8}(?:\.[0-9]{1,8}){0,3}$/u),
);
export const ReportingMetadataSchema = Schema.Struct({
  platform: Schema.Literals(['ios', 'macos', 'backend']),
  appVersion: version,
  build: Schema.String.check(Schema.isPattern(/^[0-9]{1,18}$/u)),
  osVersion: version,
  channel: Schema.Literals(['production', 'testflight', 'qualification']),
});
