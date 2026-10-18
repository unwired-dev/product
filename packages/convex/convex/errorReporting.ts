import {
  ErrorReportSchema,
  ReportingMetadataSchema,
} from '@private-email/contracts/errorReportingSchema';
import { v } from 'convex/values';
import * as Config from 'effect/Config';
import * as Effect from 'effect/Effect';
import * as Option from 'effect/Option';
import * as Schema from 'effect/Schema';

import type { ActionCtx } from './_generated/server.js';

import { internal } from './_generated/api.js';
import { httpAction, internalAction } from './_generated/server.js';
import { call, runConvexProgram } from './effectRuntime.js';

type ErrorReport = typeof ErrorReportSchema.Type;
type ReportingMetadata = typeof ReportingMetadataSchema.Type;

const decodeOperation = Schema.decodeUnknownOption(
  Schema.Literals(['enable', 'capture', 'revoke', 'delete', 'status']),
);
const uuid = Schema.String.check(
  Schema.isPattern(
    /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/iu,
  ),
);
const ProofSchema = Schema.Struct({
  installationId: uuid,
  credential: Schema.String.check(Schema.isPattern(/^[0-9a-f]{64}$/u)),
  generation: Schema.Int.check(
    Schema.isBetween({ minimum: 0, maximum: Number.MAX_SAFE_INTEGER }),
  ),
});
const CaptureSchema = Schema.Struct({
  ...ProofSchema.fields,
  reports: Schema.Array(ErrorReportSchema).check(
    Schema.isMinLength(1),
    Schema.isMaxLength(10),
  ),
  metadata: ReportingMetadataSchema,
});
const decodeProof = Schema.decodeUnknownOption(ProofSchema, {
  onExcessProperty: 'error',
});
const decodeCapture = Schema.decodeUnknownOption(CaptureSchema, {
  onExcessProperty: 'error',
});
const PersonSchema = Schema.Struct({
  id: uuid,
  distinct_ids: Schema.Array(Schema.String),
  properties: Schema.optionalKey(Schema.Unknown),
});
const decodePersons = Schema.decodeUnknownOption(
  Schema.Struct({
    results: Schema.Array(PersonSchema),
    next: Schema.optionalKey(Schema.NullOr(Schema.String)),
  }),
);
const decodeDeletionStatus = Schema.decodeUnknownOption(
  Schema.Struct({
    results: Schema.Array(
      Schema.Struct({
        person_uuid: uuid,
        status: Schema.Literals(['pending', 'completed']),
        delete_verified_at: Schema.NullOr(Schema.String),
      }),
    ),
  }),
);

class ReportingUnavailable extends Schema.TaggedError<ReportingUnavailable>()(
  'ReportingUnavailable',
  { cause: Schema.Defect() },
) {}

const configuration = Effect.gen(function* () {
  const key = yield* Config.String('POSTHOG_PROJECT_KEY');
  const project = yield* Config.String('POSTHOG_PROJECT_ID');
  const personKey = yield* Config.String('POSTHOG_PERSON_API_KEY');
  if (!/^\d+$/u.test(project)) {
    return yield* new ReportingUnavailable({ cause: 'invalid-configuration' });
  }
  return { key, project, personKey };
});

// Kept outside Effect so fetch uses Convex's action context and its abort deadline.
function vendorRequest(url: string, init?: RequestInit): Promise<Response> {
  return fetch(url, {
    ...init,
    redirect: 'error',
    signal: AbortSignal.timeout(10_000),
  });
}
const vendor = Effect.fn('ErrorReporting.vendor')(function* (
  url: string,
  init?: RequestInit,
) {
  const response = yield* Effect.tryPromise({
    try: () => vendorRequest(url, init),
    catch: (cause) => new ReportingUnavailable({ cause }),
  });
  if (!response.ok) {
    return yield* new ReportingUnavailable({ cause: 'vendor-unavailable' });
  }
  return response;
});

function event(
  installationId: string,
  report: ErrorReport,
  metadata: ReportingMetadata,
) {
  const frames = report.frames.map((frame) =>
    frame.kind === 'javascript'
      ? {
          platform:
            metadata.platform === 'backend' ? 'web:javascript' : 'hermes',
          chunk_id: `app:///${metadata.platform}/${metadata.appVersion}/${metadata.build}/index.bundle`,
          filename: `app:///${metadata.platform}/${metadata.appVersion}/${metadata.build}/index.bundle`,
          function: '<unknown>',
          lineno: frame.line,
          colno: frame.column,
          in_app: true,
        }
      : {
          platform: 'apple',
          instruction_addr: frame.address,
          image_addr: frame.imageAddress,
          in_app: true,
        },
  );
  const images = report.frames.flatMap((frame) =>
    frame.kind === 'native'
      ? [
          {
            debug_id: frame.imageUuid.toUpperCase(),
            image_addr: frame.imageAddress,
            type: 'macho',
          },
        ]
      : [],
  );
  return {
    uuid: report.id,
    event: '$exception',
    timestamp: new Date(report.createdAt).toISOString(),
    properties: {
      distinct_id: installationId,
      $geoip_disable: true,
      $process_person_profile: true,
      $set: {},
      $exception_list: [
        {
          type: report.name,
          ...(report.message === undefined ? {} : { value: report.message }),
          stacktrace: { type: 'raw', frames },
        },
        ...report.causes.map((cause) => ({
          type: cause.name,
          ...(cause.message === undefined ? {} : { value: cause.message }),
        })),
      ],
      $debug_images: images,
      reporting_code: report.code,
      reporting_breadcrumbs: report.breadcrumbs.map((crumb) => ({
        operation: crumb.operation,
        stage: crumb.stage,
        ...(crumb.elapsedMs === undefined
          ? {}
          : { elapsedMs: crumb.elapsedMs }),
        ...(crumb.status === undefined ? {} : { status: crumb.status }),
      })),
      app_version: metadata.appVersion,
      app_build: metadata.build,
      os_version: metadata.osVersion,
      platform: metadata.platform,
      release_channel: metadata.channel,
    },
  };
}

function captureBody(
  key: string,
  reports: ReadonlyArray<ReturnType<typeof event>>,
): string {
  return JSON.stringify({ api_key: key, batch: reports });
}

const capture = Effect.fn('ErrorReporting.capture')(function* (
  installationId: string,
  reports: readonly ErrorReport[],
  metadata: ReportingMetadata,
) {
  const config = yield* configuration;
  yield* vendor('https://eu.i.posthog.com/batch/', {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: captureBody(
      config.key,
      reports.map((report) => event(installationId, report, metadata)),
    ),
  });
});

interface DeletionTarget {
  installationId: string;
  base: string;
  headers: { authorization: string };
}

const beginDeletion = Effect.fn('ErrorReporting.beginDeletion')(function* (
  ctx: ActionCtx,
  target: DeletionTarget,
) {
  const { installationId, base, headers } = target;
  const response = yield* vendor(`${base}?distinct_id=${installationId}`, {
    headers,
  });
  const persons = decodePersons(yield* call(() => response.json()));
  if (Option.isNone(persons) || (persons.value.next ?? null) !== null) {
    return;
  }
  const person = persons.value.results.find(
    (candidate) =>
      candidate.distinct_ids.length === 1 &&
      candidate.distinct_ids[0] === installationId,
  );
  // No profile can mean ingestion lag; it is never proof that events were deleted.
  if (person === undefined || persons.value.results.length !== 1) {
    return;
  }
  yield* call(() =>
    ctx.runMutation(internal.errorReportingState.advanceDeletion, {
      installationId,
      personUuid: person.id,
    }),
  );
  yield* vendor(
    `${base}${person.id}/?delete_events=true&delete_recordings=true`,
    { method: 'DELETE', headers },
  );
});

function verifiedDeletion(
  status: ReturnType<typeof decodeDeletionStatus>,
  personUuid: string,
): boolean {
  return (
    Option.isSome(status) &&
    status.value.results.some(
      (item) =>
        item.person_uuid === personUuid &&
        item.status === 'completed' &&
        item.delete_verified_at !== null &&
        item.delete_verified_at.length > 0,
    )
  );
}

function absentProfile(persons: ReturnType<typeof decodePersons>): boolean {
  return (
    Option.isSome(persons) &&
    persons.value.results.length === 0 &&
    (persons.value.next ?? null) === null
  );
}

const verifyDeletion = Effect.fn('ErrorReporting.verifyDeletion')(function* (
  ctx: ActionCtx,
  target: DeletionTarget,
  personUuid: string,
) {
  const { installationId, base, headers } = target;
  const response = yield* vendor(
    `${base}deletion_status/?person_uuid=${personUuid}&status=all`,
    { headers },
  );
  const status = decodeDeletionStatus(yield* call(() => response.json()));
  if (verifiedDeletion(status, personUuid)) {
    const profileResponse = yield* vendor(
      `${base}?distinct_id=${installationId}`,
      { headers },
    );
    const persons = decodePersons(yield* call(() => profileResponse.json()));
    if (absentProfile(persons)) {
      yield* call(() =>
        ctx.runMutation(internal.errorReportingState.advanceDeletion, {
          installationId,
          complete: true,
        }),
      );
    }
  } else if (Option.isSome(status) && status.value.results.length === 0) {
    // Retry a DELETE that may have failed after the person UUID was recorded.
    yield* vendor(
      `${base}${personUuid}/?delete_events=true&delete_recordings=true`,
      { method: 'DELETE', headers },
    );
  }
});

const deleteStep = Effect.fn('ErrorReporting.deleteStep')(function* (
  ctx: ActionCtx,
  installationId: string,
) {
  const current = yield* call(() =>
    ctx.runQuery(internal.errorReportingState.deletionState, {
      installationId,
    }),
  );
  if (
    current.active ||
    (current.state.kind !== 'pending' && current.state.kind !== 'verifying')
  ) {
    return;
  }
  const config = yield* configuration;
  const target = {
    installationId,
    base: `https://eu.posthog.com/api/projects/${config.project}/persons/`,
    headers: { authorization: `Bearer ${config.personKey}` },
  };
  yield* current.state.kind === 'pending'
    ? beginDeletion(ctx, target)
    : verifyDeletion(ctx, target, current.state.personUuid);
});

async function progressDeletion(
  ctx: ActionCtx,
  installationId: string,
): Promise<void> {
  await runConvexProgram(
    deleteStep(ctx, installationId).pipe(Effect.ignore),
    () => new Error('Reporting unavailable'),
  );
}

export const pollDeletion = internalAction({
  args: { installationId: v.string() },
  handler: async (ctx, args) => {
    await progressDeletion(ctx, args.installationId);
    await ctx.runMutation(
      internal.errorReportingState.rescheduleDeletion,
      args,
    );
  },
});

async function digest(credential: string): Promise<string> {
  const value = await crypto.subtle.digest(
    'SHA-256',
    new TextEncoder().encode(credential),
  );
  return [...new Uint8Array(value)]
    .map((byte) => byte.toString(16).padStart(2, '0'))
    .join('');
}

// Bound memory even when Content-Length is absent or deliberately incorrect.
async function boundedBody(request: Request): Promise<unknown> {
  const reader = request.body?.getReader();
  if (reader === undefined) {
    return null;
  }
  const chunks: Uint8Array[] = [];
  let length = 0;
  try {
    while (true) {
      const chunk = await reader.read();
      if (chunk.done) {
        break;
      }
      length += chunk.value.length;
      if (length > 65_536) {
        await reader.cancel();
        return null;
      }
      chunks.push(chunk.value);
    }
    const bytes = new Uint8Array(length);
    let offset = 0;
    for (const chunk of chunks) {
      bytes.set(chunk, offset);
      offset += chunk.length;
    }
    return Option.getOrNull(
      Schema.decodeOption(Schema.fromJsonString(Schema.Unknown))(
        new TextDecoder().decode(bytes),
      ),
    );
  } catch {
    return null;
  }
}

function stateResponse(state: string): Response {
  return Response.json(
    state === 'pending' || state === 'verifying'
      ? { status: 'pending', retryAfterMs: 60_000 }
      : { status: state },
  );
}

function expired(reports: readonly ErrorReport[]): boolean {
  const now = Date.now();
  return reports.some(
    (report) =>
      report.createdAt < now - 86_400_000 || report.createdAt > now + 300_000,
  );
}

export const handle = httpAction(async (ctx, request) => {
  const path = Option.getOrNull(
    decodeOperation(new URL(request.url).pathname.split('/').at(-1)),
  );
  if (path === null) {
    return new Response(null, { status: 404 });
  }
  const body = await boundedBody(request);
  const payload =
    path === 'capture' ? Option.getOrNull(decodeCapture(body)) : null;
  const args = payload ?? Option.getOrNull(decodeProof(body));
  if (args === null || (path === 'capture' && payload === null)) {
    return Response.json(
      { code: 'INVALID_REPORTING_REQUEST' },
      { status: 400 },
    );
  }
  if (payload !== null && expired(payload.reports)) {
    return Response.json(
      { code: 'INVALID_REPORTING_REQUEST' },
      { status: 400 },
    );
  }
  const credentialDigest = await digest(args.credential);
  const control = () =>
    ctx.runMutation(internal.errorReportingState.control, {
      installationId: args.installationId,
      credentialDigest,
      generation: args.generation,
      operation: path,
    });
  if (payload !== null) {
    return runConvexProgram(
      Effect.gen(function* () {
        // Configuration must be usable before recording a possible delivery.
        yield* configuration;
        const controlled = yield* call(control);
        if (controlled.status !== 200) {
          return Response.json(
            { code: 'REPORTING_UNAVAILABLE' },
            { status: controlled.status },
          );
        }
        if (controlled.leaseId === undefined) {
          return stateResponse(controlled.state.kind);
        }
        const { leaseId } = controlled;
        const accepted = yield* capture(
          args.installationId,
          payload.reports,
          payload.metadata,
        ).pipe(
          Effect.as(true),
          Effect.orElseSucceed(() => false),
          Effect.ensuring(
            call(() =>
              ctx.runMutation(internal.errorReportingState.releaseDelivery, {
                leaseId,
              }),
            ).pipe(Effect.orDie),
          ),
        );
        return Response.json(
          accepted
            ? { status: 'accepted' }
            : { status: 'retry', retryAfterMs: 60_000 },
        );
      }).pipe(
        Effect.orElseSucceed(() =>
          Response.json({ status: 'retry', retryAfterMs: 60_000 }),
        ),
      ),
      () => new Error('Reporting unavailable'),
    );
  }
  const controlled = await control();
  if (controlled.status !== 200) {
    return Response.json(
      { code: 'REPORTING_UNAVAILABLE' },
      { status: controlled.status },
    );
  }
  if (
    (path === 'delete' || path === 'status') &&
    (controlled.state.kind === 'pending' ||
      controlled.state.kind === 'verifying')
  ) {
    await progressDeletion(ctx, args.installationId);
    const updated = await ctx.runQuery(
      internal.errorReportingState.deletionState,
      { installationId: args.installationId },
    );
    return stateResponse(updated.state.kind);
  }
  return stateResponse(controlled.state.kind);
});

function serviceHealthBody(key: string): string {
  return JSON.stringify({
    api_key: key,
    event: '$exception',
    properties: {
      distinct_id: 'unwired-backend-service',
      $geoip_disable: true,
      $process_person_profile: false,
      $exception_list: [{ type: 'OperationError' }],
      reporting_code: 'backend-failed',
      reporting_operation: 'apns-wakeup-failed',
      platform: 'backend',
    },
  });
}

// Independent service health has no installation, account, token or foreign error fields.
export const captureServiceHealth = internalAction({
  args: {},
  handler: async () =>
    runConvexProgram(
      Effect.gen(function* () {
        const key = yield* Config.String('POSTHOG_PROJECT_KEY');
        yield* vendor('https://eu.i.posthog.com/capture/', {
          method: 'POST',
          headers: { 'content-type': 'application/json' },
          body: serviceHealthBody(key),
        });
      }).pipe(Effect.ignore),
      () => new Error('Reporting unavailable'),
    ),
});
