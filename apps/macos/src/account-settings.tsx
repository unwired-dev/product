import type { NativeAssistance } from '@private-email/mail-core/assistance';
import type {
  AccountRemoval,
  EnrollmentFailure,
  MailboxConnection,
  RecoveryFailure,
  RecoveryKeyFailure,
  Registration,
  RegistrationScreen,
  RemovalFailure,
} from '@private-email/mail-core/registration';

import {
  profilesOf,
  recoveryKeyEntry,
} from '@private-email/mail-core/registration';
import { useState, useSyncExternalStore } from 'react';
import { Text, TextInput, View } from 'react-native';

import type { SettingsButton, SettingsDestination } from './settings.tsx';

import { Button, Notice } from './design.tsx';
import { ImapSetup } from './imap-setup.tsx';
import { Label } from './label.tsx';
import { useLocalization } from './localization.ts';
import { MailAssistanceSettings } from './mail-assistance.tsx';
import { TrustCard } from './onboarding.tsx';
import { registrationStyles as styles } from './registration-styles.ts';
import { RemoteContentSettings } from './remote-content.tsx';
import { SettingsBlock, SettingsGroup, SettingsRow } from './settings.tsx';
import { usePalette } from './theme.ts';
import { TrustedDevices } from './trusted-devices.tsx';

// Each Mailbox Connection with its state, adding another, and removal after confirmation.
function Mailboxes({
  mailboxes,
  button,
  microsoft,
  store,
}: {
  readonly mailboxes: readonly MailboxConnection[];
  readonly button: SettingsButton;
  readonly microsoft: boolean;
  readonly store: Registration;
}) {
  const colors = usePalette();
  const { t } = useLocalization();
  const [confirming, setConfirming] = useState<MailboxConnection['id']>();
  // The IMAP connection whose password is being entered again, or a new one being added.
  const [imap, setImap] = useState<
    { kind: 'repair'; id: MailboxConnection['id'] } | { kind: 'new' }
  >();
  if (mailboxes.length === 0) {
    return null;
  }
  return (
    <SettingsGroup
      title={t('settings.mailboxConnections')}
      footer={t('mailboxes.description')}>
      {mailboxes.map((mailbox) => {
        const provider = t(`mailProviders.${mailbox.provider}`);
        const imapMailbox = mailbox.provider === 'imap';
        const repairing = imap?.kind === 'repair' && imap.id === mailbox.id;
        // Saved before SMTP: entering the password again sets up sending.
        const receiveOnly = imapMailbox && mailbox.smtp === undefined;
        return (
          <View key={mailbox.id}>
            <SettingsRow
              icon="at"
              title={mailbox.address}
              subtitle={
                mailbox.state === 'connected'
                  ? provider
                  : t(
                      imapMailbox
                        ? `mailboxes.states.imap-${mailbox.state}`
                        : `mailboxes.states.${mailbox.state}`,
                      { provider },
                    )
              }
              subtitleTone={
                mailbox.state === 'connected' ? undefined : 'warning'
              }>
              {mailbox.state === 'authorization' && !imapMailbox
                ? button(
                    t('mailboxes.allow', {
                      address: mailbox.address,
                      provider,
                    }),
                    () => store.authorizeMailbox(mailbox.id),
                    { title: t('settings.signIn') },
                  )
                : null}
              {imapMailbox && !repairing
                ? button(
                    t('mailboxes.enterPassword', { address: mailbox.address }),
                    async () => {
                      setImap({ kind: 'repair', id: mailbox.id });
                    },
                    { title: t('settings.enterPassword') },
                  )
                : null}
              {confirming === mailbox.id
                ? null
                : button(
                    t('mailboxes.remove', { address: mailbox.address }),
                    async () => {
                      setConfirming(mailbox.id);
                    },
                    { title: t('settings.remove') },
                  )}
            </SettingsRow>
            {receiveOnly || repairing || confirming === mailbox.id ? (
              <SettingsBlock>
                {receiveOnly ? (
                  <Label style={[styles.text, { color: colors.textSecondary }]}>
                    {t('mailboxes.receiveOnly')}
                  </Label>
                ) : null}
                {repairing ? (
                  <ImapSetup
                    button={button}
                    onClose={() => {
                      setImap(undefined);
                    }}
                    repair={mailbox}
                    store={store}
                  />
                ) : null}
                {confirming === mailbox.id ? (
                  <>
                    <Label style={[styles.text, { color: colors.textPrimary }]}>
                      {t(
                        imapMailbox
                          ? 'mailboxes.confirm_imap'
                          : 'mailboxes.confirm',
                        {
                          address: mailbox.address,
                          provider,
                        },
                      )}
                    </Label>
                    {button(
                      t('mailboxes.remove', { address: mailbox.address }),
                      async () => {
                        setConfirming(undefined);
                        await store.removeMailbox(mailbox.id);
                      },
                      { tone: 'destructive' },
                    )}
                    {button(t('mailboxes.cancel'), async () => {
                      setConfirming(undefined);
                    })}
                  </>
                ) : null}
              </SettingsBlock>
            ) : null}
          </View>
        );
      })}
      <SettingsBlock>
        {button(t('mailboxes.add'), () => store.addMailbox('gmail', true))}
        {microsoft
          ? button(t('mailboxes.addMicrosoft'), () =>
              store.addMailbox('microsoft-graph'),
            )
          : null}
        {imap?.kind === 'new' ? (
          <ImapSetup
            button={button}
            onClose={() => {
              setImap(undefined);
            }}
            store={store}
          />
        ) : (
          button(t('mailboxes.addImap'), async () => {
            setImap({ kind: 'new' });
          })
        )}
      </SettingsBlock>
    </SettingsGroup>
  );
}

// Trust steps are cards whose push buttons follow the design: accent for the step's action,
// destructive text for declining, all disabled while registration is busy.
function useCardButton(store: Registration) {
  const { busy } = useSyncExternalStore(store.subscribe, store.getSnapshot);
  return function cardButton(
    label: string,
    action: () => Promise<void>,
    fill?: 'accent' | 'destructive',
  ) {
    return (
      <Button
        key={label}
        destructive={fill === 'destructive'}
        disabled={busy}
        fill={fill === 'accent' ? 'accent' : 'quiet'}
        label={label}
        onPress={() => {
          void action();
        }}
      />
    );
  };
}

// End-to-End Encrypted Product Sync; the Recovery Key stays visible until its setup is confirmed.
function PrivateSync({
  copy,
  failure,
  store,
}: {
  readonly copy: RegistrationScreen['privateSync']['copy'];
  readonly failure: RecoveryKeyFailure | undefined;
  readonly store: Registration;
}) {
  const colors = usePalette();
  const { t } = useLocalization();
  const card = useCardButton(store);
  const [entry, setEntry] = useState('');
  if (copy === undefined) {
    return null;
  }
  const { recoveryKey, enrollmentCode } = copy;
  const notes = (
    <>
      {copy.mailboxes === undefined ? null : (
        <Label style={[styles.text, { color: colors.textSecondary }]}>
          {copy.mailboxes}
        </Label>
      )}
      {copy.pending === undefined ? null : (
        <Label style={[styles.text, { color: colors.textPrimary }]}>
          {copy.pending}
        </Label>
      )}
    </>
  );
  if (recoveryKey !== undefined) {
    return (
      <TrustCard
        icon="key"
        title={copy.title}
        description={copy.description}>
        <Text
          selectable
          testID="recovery-key"
          style={[
            styles.recoveryKey,
            { color: colors.textPrimary, backgroundColor: colors.fillQuiet },
          ]}>
          {recoveryKey}
        </Text>
        <Label style={[styles.text, { color: colors.textSecondary }]}>
          {t('recoveryKeyConfirmation.prompt')}
        </Label>
        <TextInput
          accessibilityLabel={t('recoveryKeyConfirmation.label')}
          autoCapitalize="characters"
          autoComplete="off"
          autoCorrect={false}
          onChangeText={(text) => {
            setEntry(recoveryKeyEntry(text));
          }}
          placeholder={t('recoveryKeyConfirmation.label')}
          placeholderTextColor={colors.textSecondary}
          style={[
            styles.input,
            { borderColor: colors.separator, color: colors.textPrimary },
          ]}
          value={entry}
        />
        {failure === undefined ? null : (
          <Label
            accessibilityRole="alert"
            style={[styles.text, { color: colors.textPrimary }]}>
            {t(`recoveryKeyConfirmation.${failure}`)}
          </Label>
        )}
        {card(
          t('recoveryKeyConfirmation.confirm'),
          () => store.confirmRecoveryKey(entry),
          'accent',
        )}
        {notes}
      </TrustCard>
    );
  }
  if (enrollmentCode !== undefined) {
    return (
      <TrustCard
        icon="laptopcomputer.and.iphone"
        title={copy.title}
        description={copy.description}>
        <Text
          accessibilityLabel={enrollmentCode}
          selectable
          testID="enrollment-code"
          style={[
            styles.code,
            { color: colors.textPrimary, backgroundColor: colors.fillQuiet },
          ]}>
          {enrollmentCode.replaceAll('-', ' ')}
        </Text>
        {card(t('enrollment.check'), store.refreshPrivateSync, 'accent')}
        {notes}
      </TrustCard>
    );
  }
  return (
    <SettingsGroup
      title={copy.title}
      footer={copy.description}>
      {copy.mailboxes === undefined && copy.pending === undefined ? null : (
        <SettingsBlock>{notes}</SettingsBlock>
      )}
    </SettingsGroup>
  );
}

// Without an available trusted device, the Recovery Key unlocks this one; nothing offers a reset.
function RecoveryKeyUnlock({
  offered,
  failure,
  store,
}: {
  // Recovery Key entry is offered only where the account has keys that this device lacks.
  readonly offered: boolean;
  readonly failure: RecoveryFailure | undefined;
  readonly store: Registration;
}) {
  const colors = usePalette();
  const { t } = useLocalization();
  const card = useCardButton(store);
  const [entry, setEntry] = useState('');
  if (!offered) {
    return null;
  }
  return (
    <TrustCard
      icon="key"
      title={t('recovery.title')}
      description={t('recovery.description')}>
      <TextInput
        accessibilityLabel={t('recovery.label')}
        autoCapitalize="characters"
        autoComplete="off"
        autoCorrect={false}
        onChangeText={setEntry}
        placeholder={t('recovery.label')}
        placeholderTextColor={colors.textSecondary}
        style={[
          styles.input,
          { borderColor: colors.separator, color: colors.textPrimary },
        ]}
        value={entry}
      />
      {failure === undefined ? null : (
        <Label
          accessibilityRole="alert"
          style={[styles.text, { color: colors.textPrimary }]}>
          {t(`recovery.${failure}`)}
        </Label>
      )}
      {card(
        t('recovery.unlock'),
        () => store.recoverWithRecoveryKey(entry),
        'accent',
      )}
      <Notice
        icon="info.circle"
        message={t('recovery.lost')}
      />
    </TrustCard>
  );
}

// A trusted device approves another device only with the code that device shows.
function DeviceApproval({
  account,
  approves,
  button,
  failure,
  store,
}: {
  readonly account: Readonly<{
    enrollmentRequest?: string;
    enrollmentDevice?: string;
  }>;
  // Only a device holding the account keys approves another device.
  readonly approves: boolean;
  readonly button: SettingsButton;
  readonly failure: EnrollmentFailure | undefined;
  readonly store: Registration;
}) {
  const colors = usePalette();
  const { t } = useLocalization();
  const card = useCardButton(store);
  const [entry, setEntry] = useState('');
  const { enrollmentRequest: request } = account;
  if (!approves) {
    return null;
  }
  const alert =
    failure === undefined ? null : (
      <Label
        accessibilityRole="alert"
        style={[styles.text, { color: colors.textPrimary }]}>
        {t(`enrollment.${failure}`)}
      </Label>
    );
  if (request === undefined) {
    return (
      <SettingsGroup>
        <SettingsBlock>
          {alert}
          {button(t('enrollment.find'), store.refreshPrivateSync)}
        </SettingsBlock>
      </SettingsGroup>
    );
  }
  return (
    <TrustCard
      icon="laptopcomputer.and.iphone"
      title={t('enrollment.title')}
      description={t('enrollment.description', {
        device: account.enrollmentDevice ?? t('enrollment.device'),
      })}>
      <TextInput
        accessibilityLabel={t('enrollment.label')}
        autoCapitalize="characters"
        autoComplete="off"
        autoCorrect={false}
        onChangeText={setEntry}
        placeholder={t('enrollment.label')}
        placeholderTextColor={colors.textSecondary}
        style={[
          styles.input,
          { borderColor: colors.separator, color: colors.textPrimary },
        ]}
        value={entry}
      />
      {alert}
      {card(
        t('enrollment.approve'),
        () => store.approveEnrollment(request, entry),
        'accent',
      )}
      {card(
        t('enrollment.decline'),
        () => store.declineEnrollment(request),
        'destructive',
      )}
      {/* A request that expired or was handled elsewhere is replaced by the newest one. */}
      {card(t('enrollment.find'), store.refreshPrivateSync)}
    </TrustCard>
  );
}

// Account settings: Linked Sign-Ins never come from a mailbox grant or a matching email.
function SignInMethods({
  methods,
  button,
  store,
}: {
  readonly methods: NonNullable<
    RegistrationScreen['identity']
  >['signInMethods'];
  readonly button: SettingsButton;
  readonly store: Registration;
}) {
  const colors = usePalette();
  const { t } = useLocalization();
  const { link, failure } = methods;
  return (
    <SettingsGroup
      title={t('signInMethods.title')}
      footer={methods.description}>
      {failure === undefined && link === undefined ? null : (
        <SettingsBlock>
          {failure === undefined ? null : (
            <Label
              accessibilityRole="alert"
              style={[styles.text, { color: colors.textPrimary }]}>
              {failure}
            </Label>
          )}
          {link === undefined
            ? null
            : button(link.label, () => store.link(link.provider))}
        </SettingsBlock>
      )}
    </SettingsGroup>
  );
}

// Leaving this device and deleting the Product Account everywhere are distinct, each confirmed
// here first; deletion then asks for a new sign-in.
export function AccountActions({
  button,
  failure,
  pending,
  store,
}: {
  readonly button: SettingsButton;
  readonly failure: RemovalFailure | undefined;
  readonly pending: AccountRemoval | undefined;
  readonly store: Registration;
}) {
  const colors = usePalette();
  const { t } = useLocalization();
  const [confirming, setConfirming] = useState<AccountRemoval>();
  const selected = pending ?? confirming;
  const confirmation =
    selected === 'sign-out'
      ? {
          description: t('accountRemoval.signOutConfirm'),
          label: t('accountRemoval.signOut'),
          action: store.signOut,
        }
      : {
          description: t('accountRemoval.deleteConfirm'),
          label: t('accountRemoval.deletePermanently'),
          action: store.deleteProductAccount,
        };
  return (
    <SettingsGroup title={t('accountRemoval.title')}>
      {failure === undefined ? null : (
        <SettingsBlock>
          <Label
            accessibilityRole="alert"
            style={[styles.text, { color: colors.textPrimary }]}>
            {t(`accountRemoval.${failure}`)}
          </Label>
        </SettingsBlock>
      )}
      {selected === undefined ? (
        <SettingsRow title={t('settings.signOut')}>
          {button(
            t('accountRemoval.signOut'),
            async () => {
              setConfirming('sign-out');
            },
            { title: t('settings.signOutButton') },
          )}
        </SettingsRow>
      ) : null}
      {selected === undefined ? (
        <SettingsBlock>
          {button(
            t('accountRemoval.delete'),
            async () => {
              setConfirming('deletion');
            },
            { title: t('settings.delete'), tone: 'destructive' },
          )}
        </SettingsBlock>
      ) : (
        <SettingsBlock>
          <Label style={[styles.text, { color: colors.textPrimary }]}>
            {confirmation.description}
          </Label>
          {button(confirmation.label, confirmation.action, {
            tone: selected === 'deletion' ? 'destructive' : undefined,
          })}
          {pending === undefined
            ? button(t('accountRemoval.cancel'), async () => {
                setConfirming(undefined);
              })
            : null}
        </SettingsBlock>
      )}
    </SettingsGroup>
  );
}

// A signed-in account's settings, or one Settings destination's share of them; until a trusted
// device or the Recovery Key admits this device, it offers only that.
export function AccountSettings({
  assistance,
  button,
  destination,
  microsoft,
  screen,
  store,
}: {
  readonly assistance: NativeAssistance;
  readonly button: SettingsButton;
  // Without one, every section shows, as on the welcome flow's account page.
  readonly destination?: SettingsDestination;
  readonly microsoft: boolean;
  readonly screen: RegistrationScreen;
  readonly store: Registration;
}) {
  const {
    snapshot,
    recoveryKeyFailure,
    recoveryFailure,
    enrollmentFailure,
    revocationFailure,
  } = useSyncExternalStore(store.subscribe, store.getSnapshot);
  const { t } = useLocalization();
  const { identity, mailboxes, privateSync } = screen;
  if (snapshot.kind === 'signed-out' || identity === undefined) {
    return null;
  }
  const shows = (page: SettingsDestination) =>
    destination === undefined || destination === page;
  const recovery = (
    <RecoveryKeyUnlock
      offered={privateSync.offersRecovery}
      failure={recoveryFailure}
      store={store}
    />
  );
  if (snapshot.kind === 'device-pending') {
    return shows('account') ? (
      <>
        {privateSync.copy?.enrollmentCode === undefined ? (
          button(t('enrollment.check'), store.refreshPrivateSync)
        ) : (
          <PrivateSync
            copy={privateSync.copy}
            failure={recoveryKeyFailure}
            store={store}
          />
        )}
        {recovery}
      </>
    ) : null;
  }
  return (
    <>
      {shows('mailboxes') ? (
        <Mailboxes
          mailboxes={mailboxes}
          button={button}
          microsoft={microsoft}
          store={store}
        />
      ) : null}
      {shows('privacy') && mailboxes.length > 0 ? (
        <RemoteContentSettings
          button={button}
          mailboxes={mailboxes}
        />
      ) : null}
      {shows('privacy') && snapshot.removalPending === undefined ? (
        <MailAssistanceSettings
          account={snapshot.productAccountId}
          assistance={assistance}
          button={button}
          profiles={profilesOf(snapshot)}
        />
      ) : null}
      {shows('account') ? (
        <>
          <PrivateSync
            key={snapshot.recoveryKey ?? 'confirmed'}
            copy={privateSync.copy}
            failure={recoveryKeyFailure}
            store={store}
          />
          {recovery}
          <DeviceApproval
            // A code typed for one request never carries over to the next.
            key={snapshot.enrollmentRequest ?? 'none'}
            account={snapshot}
            approves={privateSync.approvesDevices}
            button={button}
            failure={enrollmentFailure}
            store={store}
          />
          <TrustedDevices
            account={snapshot}
            approves={privateSync.approvesDevices}
            button={button}
            failure={revocationFailure}
            store={store}
          />
          <SignInMethods
            methods={identity.signInMethods}
            button={button}
            store={store}
          />
        </>
      ) : null}
    </>
  );
}
