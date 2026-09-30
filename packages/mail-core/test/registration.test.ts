import { createRegistration } from '../src/registration.ts';
import { createMockRegistrationSession } from '../src/testing/registration-session.ts';

describe('google registration', () => {
  it.each([
    'registration-cancelled',
    'registration-declined',
    'registration-no-gmail',
  ])(
    'retains Product Sign-In after %s and resumes with a different Gmail identity',
    async (scenario) => {
      expect.hasAssertions();
      const session = createMockRegistrationSession(scenario);
      const first = createRegistration(session.native);
      await first.restore();
      await first.register();
      expect(first.getSnapshot()).toMatchObject({
        snapshot: {
          kind: 'mailbox-needed',
          productAccountId: 'synthetic-product-account',
        },
        busy: false,
      });
      const relaunched = createRegistration(session.native);
      await relaunched.restore();
      expect(relaunched.getSnapshot().snapshot).toStrictEqual(
        first.getSnapshot().snapshot,
      );
      await relaunched.authorizeGmail(true);
      expect(relaunched.getSnapshot().snapshot).toStrictEqual({
        kind: 'connected',
        productAccountId: 'synthetic-product-account',
        providerSubject: 'synthetic-alternate-google-subject',
        address: 'other@example.invalid',
      });
    },
  );

  it('publishes the committed Product Account before an interrupted mailbox session and permits retry', async () => {
    expect.hasAssertions();
    const session = createMockRegistrationSession('registration-interrupted');
    const store = createRegistration(session.native);
    await store.register();
    expect(store.getSnapshot()).toMatchObject({
      snapshot: { kind: 'mailbox-needed' },
      failed: true,
    });
    await store.restore();
    await store.authorizeGmail(false);
    expect(store.getSnapshot()).toMatchObject({
      snapshot: { kind: 'connected' },
      failed: false,
    });
  });

  it('rejects malformed native connection data and prevents overlapping consent operations', async () => {
    expect.hasAssertions();
    const session = createMockRegistrationSession('registration-success');
    const gate = Promise.withResolvers<undefined>();
    const store = createRegistration({
      ...session.native,
      signIn: async () => {
        await gate.promise;
        return session.native.signIn();
      },
      authorizeGmail: () => Promise.resolve({ kind: 'connected' }),
    });
    const registration = store.register();
    await store.authorizeGmail(true);
    expect(store.getSnapshot()).toStrictEqual({
      snapshot: { kind: 'signed-out' },
      busy: true,
      failed: false,
    });
    gate.resolve(undefined);
    await registration;
    expect(store.getSnapshot()).toMatchObject({
      snapshot: { kind: 'mailbox-needed' },
      busy: false,
      failed: true,
    });
  });
});
