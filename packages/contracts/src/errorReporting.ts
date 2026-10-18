import type { Infer } from 'convex/values';

import { v } from 'convex/values';

export const reportingCodeValidator = v.union(
  v.literal('unhandled-js'),
  v.literal('native-crash'),
  v.literal('send-failed'),
  v.literal('sync-failed'),
  v.literal('sign-in-failed'),
  v.literal('operation-failed'),
  v.literal('backend-failed'),
);

export const reportingNameValidator = v.union(
  v.literal('Error'),
  v.literal('TypeError'),
  v.literal('RangeError'),
  v.literal('ReferenceError'),
  v.literal('SyntaxError'),
  v.literal('URIError'),
  v.literal('NSException'),
  v.literal('NSInvalidArgumentException'),
  v.literal('NSRangeException'),
  v.literal('NSInternalInconsistencyException'),
  v.literal('NativeCrash'),
  v.literal('OperationError'),
);

// Messages are retained only when they match an application-approved constant.
export const reportingMessageValidator = v.union(
  v.literal('Cannot convert undefined value to object'),
  v.literal('Cannot convert undefined or null to object'),
  v.literal('Maximum call stack size exceeded'),
  v.literal('Invalid array length'),
  v.literal('Invalid time value'),
  v.literal('URI malformed'),
  v.literal('Native bridge failed'),
  v.literal('Synthetic native crash'),
);

export const reportingFrameValidator = v.union(
  v.object({
    kind: v.literal('javascript'),
    line: v.number(),
    column: v.number(),
  }),
  v.object({
    kind: v.literal('native'),
    address: v.string(),
    imageUuid: v.string(),
    imageAddress: v.string(),
  }),
);

export const reportingBreadcrumbValidator = v.object({
  operation: v.union(
    v.literal('app'),
    v.literal('send'),
    v.literal('sync'),
    v.literal('sign-in'),
    v.literal('account'),
    v.literal('draft'),
    v.literal('reader'),
    v.literal('settings'),
  ),
  stage: v.union(
    v.literal('open'),
    v.literal('start'),
    v.literal('complete'),
    v.literal('failed'),
    v.literal('retry'),
  ),
  elapsedMs: v.optional(v.number()),
  status: v.optional(v.number()),
});

export const errorReportValidator = v.object({
  id: v.string(),
  createdAt: v.number(),
  code: reportingCodeValidator,
  name: reportingNameValidator,
  message: v.optional(reportingMessageValidator),
  frames: v.array(reportingFrameValidator),
  causes: v.array(
    v.object({
      name: reportingNameValidator,
      message: v.optional(reportingMessageValidator),
    }),
  ),
  breadcrumbs: v.array(reportingBreadcrumbValidator),
});

export const reportingMetadataValidator = v.object({
  platform: v.union(v.literal('ios'), v.literal('macos'), v.literal('backend')),
  appVersion: v.string(),
  build: v.string(),
  osVersion: v.string(),
  channel: v.union(
    v.literal('production'),
    v.literal('testflight'),
    v.literal('qualification'),
  ),
});

export type ErrorReport = Infer<typeof errorReportValidator>;
export type ReportingMetadata = Infer<typeof reportingMetadataValidator>;
export type ReportingCode = Infer<typeof reportingCodeValidator>;
export type ReportingName = Infer<typeof reportingNameValidator>;
export type ReportingMessage = Infer<typeof reportingMessageValidator>;
export type ReportingFrame = Infer<typeof reportingFrameValidator>;
export type ReportingBreadcrumb = Infer<typeof reportingBreadcrumbValidator>;
