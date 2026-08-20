import {
  MailTestVisibleStepFailureError,
  visibleStepFailureContext,
} from '../src/evidence.ts';

describe('mail test failure evidence', () => {
  it('reports visible step context without including diagnostic text', () => {
    expect.assertions(1);
    const error = new MailTestVisibleStepFailureError(
      'Message content must remain outside structured evidence.',
      {
        semanticUIState: 'performed',
        serverAssertion: 'failed',
        step: 'archive',
      },
    );

    expect(visibleStepFailureContext(error)).toStrictEqual({
      scenario: 'core-mail-loop',
      semanticUIState: 'performed',
      serverAssertion: 'failed',
      step: 'archive',
    });
  });

  it('does not add visible step context to unrelated failures', () => {
    expect.assertions(1);

    expect(visibleStepFailureContext(new Error('unrelated'))).toStrictEqual({});
  });
});
