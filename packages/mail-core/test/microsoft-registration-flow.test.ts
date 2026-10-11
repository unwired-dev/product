import * as Schema from 'effect/Schema';

import {
  mailboxesOf,
  RegistrationSnapshotSchema,
} from '../src/registration.ts';
import { launch } from './registration-flow-fixture.ts';

const snapshot = Schema.decodeUnknownSync(RegistrationSnapshotSchema);

describe('microsoft registration flow', () => {
  it.each(['google', 'apple'] as const)(
    'connects Microsoft mail first after %s sign-in without Gmail and retains the account on refusal',
    async (provider) => {
      /* oxlint-disable vitest/max-expects -- One journey proves each Microsoft consent outcome and reauthorization. */
      expect.hasAssertions();
      const { flow, relaunch, google, microsoft } = launch();
      await expect(flow.signIn(provider)).resolves.toMatchObject({
        kind: 'mailbox-needed',
        signInProvider: provider,
      });
      const productHints = [...google.hints];
      for (const outcome of ['cancelled', 'declined']) {
        microsoft.outcome = outcome;
        await expect(
          flow.addMailbox('microsoft-graph', false),
        ).resolves.toMatchObject({ kind: 'mailbox-needed', reason: outcome });
      }
      microsoft.outcome = undefined;
      // A Microsoft grant without mail access cannot connect a mailbox.
      microsoft.scopes = ['User.Read', 'offline_access'];
      await expect(
        flow.addMailbox('microsoft-graph', false),
      ).resolves.toMatchObject({ reason: 'declined' });
      // Graph names its scopes in full; an account or tenant without an Outlook mailbox is refused.
      microsoft.scopes = ['https://graph.microsoft.com/Mail.Read'];
      microsoft.mailboxAvailable = false;
      await expect(
        flow.addMailbox('microsoft-graph', false),
      ).resolves.toMatchObject({
        kind: 'mailbox-needed',
        reason: 'microsoft-unavailable',
      });
      microsoft.mailboxAvailable = true;
      const connected = snapshot(
        await relaunch().addMailbox('microsoft-graph', false),
      );
      expect(connected).toMatchObject({
        kind: 'connected',
        signInProvider: provider,
      });
      expect(mailboxesOf(connected)).toStrictEqual([
        {
          id: 'synthetic-connection-casey',
          provider: 'microsoft-graph',
          address: 'casey@example.invalid',
          state: 'connected',
          epoch: expect.any(String),
        },
      ]);
      // Google was never asked for Gmail.
      expect(google.hints).toStrictEqual(productHints);
      await expect(relaunch().restore()).resolves.toStrictEqual(connected);

      // Microsoft refusing the saved grant asks for Microsoft again, never for Gmail.
      microsoft.refreshFailure = 'gmail-unavailable';
      await expect(relaunch().restore()).resolves.toMatchObject({
        kind: 'mailbox-needed',
        reason: 'microsoft-unavailable',
      });
      microsoft.refreshFailure = undefined;
      await expect(
        relaunch().authorizeMailbox('synthetic-connection-casey'),
      ).resolves.toMatchObject({ kind: 'connected' });
      expect(microsoft.hints.at(-1)).toBe('casey@example.invalid');
      expect(google.hints).toStrictEqual(productHints);
    },
  );
});
