import type {
  ErrorReportSchema,
  ReportingBreadcrumbSchema,
  ReportingCodeSchema,
  ReportingFrameSchema,
  ReportingMessageSchema,
  ReportingMetadataSchema,
  ReportingNameSchema,
} from './errorReportingSchema.ts';

export type ErrorReport = typeof ErrorReportSchema.Type;
export type ReportingMetadata = typeof ReportingMetadataSchema.Type;
export type ReportingCode = typeof ReportingCodeSchema.Type;
export type ReportingName = typeof ReportingNameSchema.Type;
export type ReportingMessage = typeof ReportingMessageSchema.Type;
export type ReportingFrame = typeof ReportingFrameSchema.Type;
export type ReportingBreadcrumb = typeof ReportingBreadcrumbSchema.Type;
