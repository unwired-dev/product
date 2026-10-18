const metadata = {
  appNamespace: 'dev.unwired.mail',
  platform: 'ios',
  appVersion: '1.0',
  build: '202610181234',
  osVersion: '27.0',
  channel: 'qualification',
};
export function reportingFixture(
  initial: Readonly<{ enabled?: boolean; document?: string }> = {},
) {
  let state = {
    enabled: false,
    generation: 0,
    document: null as string | null,
    available: true,
    nativeAvailable: false,
    identityAvailable: true,
    metadata,
    ...initial,
  };
  const requests: Array<{
    operation: string;
    body: string;
    generation: number;
  }> = [];
  let offline = false;
  let complete = false;
  const native = {
    errorReportingRead: async () => state,
    errorReportingConsent: async (
      enabled: boolean,
      renewIdentity: boolean,
      generation: number,
    ) => {
      if (enabled && generation !== state.generation) {
        throw Object.assign(new Error('stale'), {
          code: 'error-reporting-stale',
        });
      }
      state = {
        ...state,
        enabled,
        generation: state.generation + 1,
        document: renewIdentity ? null : state.document,
      };
      if (renewIdentity) {
        complete = false;
      }
      return state;
    },
    errorReportingSave: async (generation: number, document: string) => {
      if (state.generation !== generation) {
        return { saved: false };
      }
      state.document = document;
      return { saved: true };
    },
    errorReportingRequest: async (
      operation: string,
      body: string,
      generation: number,
    ) => {
      if (
        generation !== state.generation ||
        ((operation === 'capture' || operation === 'enable') && !state.enabled)
      ) {
        throw new Error('stale');
      }
      if (offline) {
        throw Object.assign(new Error('offline'), { code: 'offline' });
      }
      requests.push({ operation, body, generation });
      const statuses: Record<string, string> = {
        capture: 'accepted',
        enable: 'enabled',
        revoke: 'disabled',
      };
      return {
        status: statuses[operation] ?? (complete ? 'complete' : 'pending'),
      };
    },
    errorReportingTakeNative: async (): Promise<{ reports: unknown[] }> => ({
      reports: [],
    }),
  };
  return {
    native,
    requests,
    state: () => state,
    offline: (value: boolean) => {
      offline = value;
    },
    complete: () => {
      complete = true;
    },
  };
}
