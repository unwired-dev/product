import { english } from '@private-email/localization';

import type {
  InboxChoice,
  Registration,
  RegistrationScreen,
  RegistrationSnapshot,
  SignInOffer,
} from '../src/registration.ts';

import { createRegistration, registrationScreen } from '../src/registration.ts';
import { createRegistrationScenario } from '../src/testing/registration-scenarios.ts';
import { syntheticMailboxes } from '../src/testing/registration-vault.ts';

// The connection list native code reports for one connected synthetic mailbox.
const connectedTo = (address: keyof typeof syntheticMailboxes) =>
  JSON.stringify([
    {
      provider: 'gmail',
      address,
      epoch: 'synthetic-epoch-1',
      id: syntheticMailboxes[address],
      state: 'connected',
    },
  ]);

// One host window over the store: it keeps its own choice and stores back the one the screen
// returns, as both gates do.
const hostWindow = (store: Registration) => {
  let choice: InboxChoice | undefined = undefined;
  const view = () => {
    const screen = registrationScreen(english, store.getSnapshot(), choice);
    ({ choice } = screen);
    return screen;
  };
  return {
    view,
    choose: (destination: InboxChoice['destination']) => {
      const { choices } = view();
      if (choices === undefined) {
        throw new TypeError('No Inbox can open');
      }
      choice = choices[destination];
      return choice;
    },
  };
};

// Google sign-in, Alex's suggested Gmail and the confirmed Recovery Key: launch opens the Inbox.
const connectedAccount = async () => {
  const synthetic = await createRegistrationScenario('registration-success');
  const store = createRegistration(synthetic.vault);
  await store.register('google');
  await store.addMailbox();
  const { snapshot } = store.getSnapshot();
  const recoveryKey =
    snapshot.kind === 'signed-out' ? undefined : snapshot.recoveryKey;
  if (recoveryKey === undefined) {
    throw new TypeError('No Recovery Key shown');
  }
  await store.confirmRecoveryKey(recoveryKey.replaceAll('-', '').slice(-4));
  return { synthetic, store };
};

describe('registration screen', () => {
  it('keeps each window on its own choice between the account page and the Inbox', async () => {
    expect.hasAssertions();
    const { store } = await connectedAccount();
    const first = hostWindow(store);
    const second = hostWindow(store);
    expect(first.view().destination).toBe('inbox');
    first.choose('account');
    expect(first.view().destination).toBe('account');
    expect(second.view()).toMatchObject({
      destination: 'inbox',
      choice: undefined,
    });
  });

  it('forgets a choice when the Product Account signs out, so it cannot return with the account', async () => {
    expect.hasAssertions();
    const { synthetic, store } = await connectedAccount();
    // A Trusted Device of the account approves this device when it signs in again.
    synthetic.sync.approves = true;
    const window = hostWindow(store);
    const earlier = window.choose('account');
    await store.signOut();
    expect(window.view()).toMatchObject({
      destination: 'account',
      choice: undefined,
      choices: undefined,
    });
    await store.register('google');
    await store.refreshPrivateSync();
    await store.addMailbox();
    // The same Product Account's next sign-in lands where its setup decides; the choice made before
    // would still apply to it, which is why the window had to forget it.
    expect(window.view().destination).toBe('inbox');
    expect(
      registrationScreen(english, store.getSnapshot(), earlier).destination,
    ).toBe('account');
  });

  it('shows setup that appears after the person returned to the Inbox', async () => {
    expect.hasAssertions();
    const { synthetic, store } = await connectedAccount();
    // Another installation of the account signs in and asks this Trusted Device for approval.
    const askForApproval = async () => {
      await createRegistration(synthetic.otherDevice().vault).register(
        'google',
      );
    };
    const window = hostWindow(store);
    window.choose('account');
    window.choose('inbox');
    await askForApproval();
    await store.restore();
    // The earlier choice of the Inbox does not hide new setup.
    expect(window.view()).toMatchObject({
      destination: 'account',
      setupPending: true,
      choice: undefined,
    });

    // This device can leave that approval for later; unchanged setup stays bypassed.
    window.choose('inbox');
    await store.resume();
    expect(window.view().destination).toBe('inbox');

    // A later request from yet another device is new setup: it needs attention again.
    synthetic.sync.clock += 1;
    await askForApproval();
    await store.resume();
    expect(window.view()).toMatchObject({
      destination: 'account',
      choice: undefined,
    });
  });

  it('keeps the screen while busy, hides it while locked and offers retry after a failure', () => {
    expect.hasAssertions();
    const snapshot: RegistrationSnapshot = {
      kind: 'connected',
      productAccountId: 'synthetic-product-account',
      signInProvider: 'google',
      privateSync: 'ready',
      mailboxes: connectedTo('alex@example.invalid'),
    };
    const idle = registrationScreen(
      english,
      { snapshot, busy: false, failed: false },
      undefined,
    );
    const busy = registrationScreen(
      english,
      { snapshot, busy: true, failed: false },
      undefined,
    );
    // Hosts disable the same actions while busy; the screen itself does not change, and the
    // Inbox's mailboxes and choices keep their identity so it does not reload.
    expect(busy).toStrictEqual(idle);
    expect(busy.mailboxes).toBe(idle.mailboxes);
    expect(busy.choices).toBe(idle.choices);
    expect(
      registrationScreen(
        english,
        { snapshot, busy: false, failed: false, locked: true },
        idle.choices?.inbox,
      ),
    ).toMatchObject({ destination: 'locked', choice: idle.choices?.inbox });
    expect(
      registrationScreen(
        english,
        { snapshot, busy: false, failed: true },
        undefined,
      ).actions,
    ).toMatchObject({ retry: true, settings: true });
  });

  it('explains a refused link beside the Sign-In Providers, keeping the link offered', async () => {
    expect.hasAssertions();
    const synthetic = await createRegistrationScenario('registration-success');
    const store = createRegistration(synthetic.vault);
    await store.register('google');
    expect(
      registrationScreen(english, store.getSnapshot(), undefined).identity,
    ).toMatchObject({
      provider: 'Signed in with Google.',
      signInMethods: {
        link: { provider: 'apple', label: 'Link Apple sign-in' },
        failure: undefined,
      },
    });
    await store.link('apple');
    expect(
      registrationScreen(english, store.getSnapshot(), undefined).identity
        ?.signInMethods,
    ).toMatchObject({
      link: { provider: 'apple' },
      failure: expect.stringMatching(
        /That Apple sign-in already belongs to another Product Account/u,
      ),
    });
  });
});

describe('registration page copy', () => {
  const account = {
    productAccountId: 'synthetic-product-account',
    signInProvider: 'google',
  } as const;
  const gmail = connectedTo('alex@example.invalid');
  // Any provider besides Gmail makes the page about mail in general.
  const microsoft = JSON.stringify([
    {
      provider: 'microsoft-graph',
      address: 'casey@example.invalid',
      epoch: 'synthetic-epoch-1',
      id: syntheticMailboxes['casey@example.invalid'],
      state: 'cached',
    },
  ]);
  // Each state's title and account line, which both hosts show as given.
  it.each<
    Readonly<{
      snapshot: RegistrationSnapshot;
      title: string;
      account: string | undefined;
    }>
  >([
    {
      snapshot: { kind: 'signed-out' },
      title: 'Welcome to Unwired Mail',
      account: undefined,
    },
    {
      snapshot: { kind: 'signed-out', notice: 'revoked' },
      title: 'This device was removed',
      account: undefined,
    },
    {
      snapshot: { ...account, kind: 'mailbox-needed' },
      title: 'Connect your mail',
      account: 'Signed in with Google.',
    },
    {
      snapshot: {
        ...account,
        kind: 'device-pending',
        privateSync: 'enrollment-pending',
        contactEmail: 'alex@example.invalid',
      },
      title: 'Add this device',
      account: 'Signed in with Google. Contact email: alex@example.invalid.',
    },
    {
      snapshot: { ...account, kind: 'connected', mailboxes: gmail },
      title: 'Gmail connected',
      account: 'Signed in with Google.',
    },
    {
      snapshot: { ...account, kind: 'cached', mailboxes: microsoft },
      title: 'Saved Inbox',
      account: 'Signed in with Google.',
    },
    {
      snapshot: {
        ...account,
        kind: 'mailbox-needed',
        removalPending: 'deletion',
      },
      title: 'Confirm account deletion',
      account: 'Signed in with Google.',
    },
  ])('$title', ({ snapshot, title, account: line }) => {
    expect.hasAssertions();
    expect(
      registrationScreen(
        english,
        { snapshot, busy: false, failed: false },
        undefined,
      ).copy,
    ).toMatchObject({ title, account: line });
  });
});

describe('registration page actions', () => {
  const account = {
    productAccountId: 'synthetic-product-account',
    signInProvider: 'apple',
  } as const;
  const again: readonly SignInOffer[] = [
    { offer: 'signInAgain', provider: 'apple' },
    { offer: 'signInInstead', provider: 'google' },
  ];
  const mailboxes = connectedTo('alex@example.invalid');
  const cases: ReadonlyArray<
    Readonly<{
      name: string;
      snapshot: RegistrationSnapshot;
      failed: boolean;
      // Labels aside: the hosts render each offer's label as given.
      actions: Partial<
        Omit<RegistrationScreen['actions'], 'signIn'> &
          Readonly<{ signIn: readonly SignInOffer[] }>
      >;
    }>
  > = [
    {
      name: 'a signed-out device offers both providers and no account settings',
      snapshot: { kind: 'signed-out' },
      failed: false,
      actions: {
        firstMailbox: false,
        signIn: [
          { offer: 'signInWith', provider: 'apple' },
          { offer: 'signInWith', provider: 'google' },
        ],
        settings: false,
      },
    },
    {
      name: 'a new account asks for its first mailbox without another sign-in',
      snapshot: { kind: 'mailbox-needed', ...account },
      failed: false,
      actions: { firstMailbox: true, signIn: [], settings: true },
    },
    {
      name: 'a failed mailbox setup offers both Sign-In Providers again',
      snapshot: { kind: 'mailbox-needed', ...account, reason: 'cancelled' },
      failed: true,
      actions: { firstMailbox: true, signIn: again, retry: true },
    },
    {
      name: 'an interrupted mailbox setup offers both Sign-In Providers again',
      snapshot: { kind: 'mailbox-needed', ...account, reason: 'interrupted' },
      failed: false,
      actions: { signIn: again, retry: false },
    },
    {
      name: 'a mailbox setup that found registration unavailable offers sign-in again',
      snapshot: { kind: 'mailbox-needed', ...account, reason: 'unavailable' },
      failed: false,
      actions: { signIn: again },
    },
    {
      name: 'a declined grant only asks for the mailbox again',
      snapshot: { kind: 'mailbox-needed', ...account, reason: 'declined' },
      failed: false,
      actions: { firstMailbox: true, signIn: [] },
    },
    {
      name: 'a mailbox waiting for authorization again is not a first mailbox',
      snapshot: {
        kind: 'mailbox-needed',
        ...account,
        mailboxes: JSON.stringify([
          {
            id: syntheticMailboxes['alex@example.invalid'],
            address: 'alex@example.invalid',
            state: 'authorization',
          },
        ]),
      },
      failed: false,
      actions: { firstMailbox: false },
    },
    {
      name: 'Product Sync setup that could not reach the backend offers sign-in again',
      snapshot: {
        kind: 'connected',
        ...account,
        privateSync: 'setup-pending',
        mailboxes,
      },
      failed: false,
      actions: { signIn: again },
    },
    {
      name: 'a mailbox not yet saved to Product Sync offers sign-in again',
      snapshot: {
        kind: 'cached',
        ...account,
        privateSync: 'ready',
        privateSyncPending: 'mailbox',
        mailboxes,
      },
      failed: false,
      actions: { signIn: again },
    },
    {
      name: 'a settled connected account offers no sign-in',
      snapshot: {
        kind: 'connected',
        ...account,
        privateSync: 'ready',
        mailboxes,
      },
      failed: false,
      actions: { firstMailbox: false, signIn: [], settings: true },
    },
    {
      name: 'a Pending Device is admitted by approval or Recovery Key, not another sign-in',
      snapshot: {
        kind: 'device-pending',
        ...account,
        privateSync: 'setup-pending',
      },
      failed: false,
      actions: { firstMailbox: false, signIn: [], settings: true },
    },
    {
      name: 'a Pending Device whose sign-in failed may sign in again',
      snapshot: {
        kind: 'device-pending',
        ...account,
        privateSync: 'enrollment-pending',
      },
      failed: true,
      actions: { signIn: again, retry: true },
    },
    {
      name: 'an unfinished removal offers only the removal',
      snapshot: {
        kind: 'mailbox-needed',
        ...account,
        privateSync: 'setup-pending',
        reason: 'interrupted',
        removalPending: 'deletion',
      },
      failed: true,
      actions: { firstMailbox: false, signIn: [], settings: false },
    },
  ];

  // Each host renders these; its own tests cover only rendering and host differences.
  it.each(cases)('$name', ({ snapshot, failed, actions }) => {
    expect.hasAssertions();
    expect(
      registrationScreen(english, { snapshot, busy: false, failed }, undefined)
        .actions,
    ).toMatchObject(actions);
  });

  it('lets only a device holding the account keys approve or remove devices', () => {
    expect.hasAssertions();
    expect(
      (
        [
          'setup-pending',
          'recovery-key',
          'ready',
          'enrollment-needed',
          'enrollment-pending',
          'unavailable',
          undefined,
        ] as const
      ).filter(
        (privateSync) =>
          registrationScreen(
            english,
            {
              snapshot: {
                ...account,
                kind: 'connected',
                mailboxes,
                privateSync,
              },
              busy: false,
              failed: false,
            },
            undefined,
          ).privateSync.approvesDevices,
      ),
    ).toStrictEqual(['recovery-key', 'ready']);
  });
});
