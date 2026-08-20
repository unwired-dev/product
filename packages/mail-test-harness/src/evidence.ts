export type MailTestVisibleStep =
  | 'archive'
  | 'mark-read'
  | 'move'
  | 'open'
  | 'trash';

export type MailTestVisibleStepOutcome = 'performed' | 'unavailable';

export type MailTestSemanticUIState =
  | MailTestVisibleStepOutcome
  | 'conversation-reader-not-dismissed'
  | 'conversation-reader-not-presented'
  | 'inbox-row-still-present'
  | 'mailbox-not-presented'
  | 'message-row-not-presented'
  | 'move-destination-not-presented'
  | 'not-run'
  | 'read-state-not-presented'
  | 'xctest-failed';

export type MailTestServerAssertionState = 'failed' | 'not-run';

interface MailTestVisibleStepFailureOptions {
  semanticUIState: MailTestSemanticUIState;
  serverAssertion: MailTestServerAssertionState;
  step: MailTestVisibleStep;
}

export class MailTestVisibleStepFailureError extends Error {
  public override name = 'MailTestVisibleStepFailureError';
  public readonly semanticUIState: MailTestSemanticUIState;
  public readonly serverAssertion: MailTestServerAssertionState;
  public readonly step: MailTestVisibleStep;

  public constructor(
    message: string,
    options: Readonly<MailTestVisibleStepFailureOptions>,
  ) {
    super(message);
    this.semanticUIState = options.semanticUIState;
    this.serverAssertion = options.serverAssertion;
    this.step = options.step;
  }
}

export function visibleStepFailureContext(error: unknown):
  | Record<string, never>
  | {
      scenario: 'core-mail-loop';
      semanticUIState: MailTestSemanticUIState;
      serverAssertion: MailTestServerAssertionState;
      step: MailTestVisibleStep;
    } {
  if (!(error instanceof MailTestVisibleStepFailureError)) {
    return {};
  }
  return {
    scenario: 'core-mail-loop',
    semanticUIState: error.semanticUIState,
    serverAssertion: error.serverAssertion,
    step: error.step,
  };
}
