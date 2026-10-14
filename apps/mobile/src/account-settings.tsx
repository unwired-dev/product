import type { NativeAssistance } from '@private-email/mail-core/assistance';
import type {
  AccountRemoval,
  EnrollmentFailure,
  LinkFailure,
  MailboxConnection,
  PrivateSync as PrivateSyncState,
  RecoveryFailure,
  RecoveryKeyFailure,
  Registration,
  RemovalFailure,
} from '@private-email/mail-core/registration';

import {
  approvesDevices,
  linkFailureCopy,
  mailboxesOf,
  offersRecovery,
  otherSignInProvider,
  privateSyncCopy,
  providerName,
  recoveryKeyEntry,
  signInMethodsCopy,
} from '@private-email/mail-core/registration';
import { useState, useSyncExternalStore } from 'react';
import { Text, TextInput, View } from 'react-native';

import type { SettingsButton, SettingsDestination } from './settings.tsx';

import { ImapSetup } from './imap-setup.tsx';
import { useLocalization } from './localization.ts';
import { MailAssistanceSettings } from './mail-assistance.tsx';
import { registrationStyles as styles } from './registration-styles.ts';
import { RemoteContentSettings } from './remote-content.tsx';
import { SettingsBlock, SettingsGroup, SettingsRow } from './settings.tsx';
import { usePalette } from './theme.ts';
import { TrustedDevices } from './trusted-devices.tsx';

// Each Mailbox Connection with its state, adding another, and removal after confirmation.
function Mailboxes({
  account,
  button,
  microsoft,
  store,
}: {
  readonly account: Readonly<{ mailboxes?: string }>;
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
  const mailboxes = mailboxesOf(account);
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
                  <Text style={[styles.text, { color: colors.textSecondary }]}>
                    {t('mailboxes.receiveOnly')}
                  </Text>
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
                    <Text style={[styles.text, { color: colors.textPrimary }]}>
                      {t(
                        imapMailbox
                          ? 'mailboxes.confirm_imap'
                          : 'mailboxes.confirm',
                        {
                          address: mailbox.address,
                          provider,
                        },
                      )}
                    </Text>
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

// End-to-End Encrypted Product Sync; the Recovery Key stays visible until its setup is confirmed.
function PrivateSync({
  account,
  button,
  failure,
  store,
}: {
  readonly account: Parameters<typeof privateSyncCopy>[1];
  readonly button: SettingsButton;
  readonly failure: RecoveryKeyFailure | undefined;
  readonly store: Registration;
}) {
  const colors = usePalette();
  const { t } = useLocalization();
  const [entry, setEntry] = useState('');
  const copy = privateSyncCopy(t, account);
  if (copy === undefined) {
    return null;
  }
  const { recoveryKey } = copy;
  return (
    <SettingsGroup
      title={copy.title}
      footer={copy.description}>
      {recoveryKey === undefined ? null : (
        <SettingsBlock>
          <Text
            selectable
            testID="recovery-key"
            style={[styles.recoveryKey, { color: colors.textPrimary }]}>
            {recoveryKey}
          </Text>
          <Text style={[styles.text, { color: colors.textSecondary }]}>
            {t('recoveryKeyConfirmation.prompt')}
          </Text>
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
            <Text
              accessibilityRole="alert"
              style={[styles.text, { color: colors.textPrimary }]}>
              {t(`recoveryKeyConfirmation.${failure}`)}
            </Text>
          )}
          {button(t('recoveryKeyConfirmation.confirm'), () =>
            store.confirmRecoveryKey(entry),
          )}
        </SettingsBlock>
      )}
      {copy.enrollmentCode === undefined ? null : (
        <SettingsBlock>
          <Text
            selectable
            testID="enrollment-code"
            style={[styles.recoveryKey, { color: colors.textPrimary }]}>
            {copy.enrollmentCode}
          </Text>
          {button(t('enrollment.check'), store.refreshPrivateSync)}
        </SettingsBlock>
      )}
      {copy.mailboxes === undefined && copy.pending === undefined ? null : (
        <SettingsBlock>
          {copy.mailboxes === undefined ? null : (
            <Text style={[styles.text, { color: colors.textSecondary }]}>
              {copy.mailboxes}
            </Text>
          )}
          {copy.pending === undefined ? null : (
            <Text style={[styles.text, { color: colors.textPrimary }]}>
              {copy.pending}
            </Text>
          )}
        </SettingsBlock>
      )}
    </SettingsGroup>
  );
}

// Without an available trusted device, the Recovery Key unlocks this one; nothing offers a reset.
function RecoveryKeyUnlock({
  account,
  button,
  failure,
  store,
}: {
  readonly account: Readonly<{ privateSync?: PrivateSyncState }>;
  readonly button: SettingsButton;
  readonly failure: RecoveryFailure | undefined;
  readonly store: Registration;
}) {
  const colors = usePalette();
  const { t } = useLocalization();
  const [entry, setEntry] = useState('');
  if (!offersRecovery(account.privateSync)) {
    return null;
  }
  return (
    <SettingsGroup
      title={t('recovery.title')}
      footer={t('recovery.lost')}>
      <SettingsBlock>
        <Text style={[styles.text, { color: colors.textSecondary }]}>
          {t('recovery.description')}
        </Text>
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
          <Text
            accessibilityRole="alert"
            style={[styles.text, { color: colors.textPrimary }]}>
            {t(`recovery.${failure}`)}
          </Text>
        )}
        {button(t('recovery.unlock'), () =>
          store.recoverWithRecoveryKey(entry),
        )}
      </SettingsBlock>
    </SettingsGroup>
  );
}

// A trusted device approves another device only with the code that device shows.
function DeviceApproval({
  account,
  button,
  failure,
  store,
}: {
  readonly account: Readonly<{
    privateSync?: PrivateSyncState;
    enrollmentRequest?: string;
    enrollmentDevice?: string;
  }>;
  readonly button: SettingsButton;
  readonly failure: EnrollmentFailure | undefined;
  readonly store: Registration;
}) {
  const colors = usePalette();
  const { t } = useLocalization();
  const [entry, setEntry] = useState('');
  const { enrollmentRequest: request } = account;
  if (!approvesDevices(account.privateSync)) {
    return null;
  }
  const alert =
    failure === undefined ? null : (
      <Text
        accessibilityRole="alert"
        style={[styles.text, { color: colors.textPrimary }]}>
        {t(`enrollment.${failure}`)}
      </Text>
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
    <SettingsGroup title={t('enrollment.title')}>
      <SettingsBlock>
        <Text style={[styles.text, { color: colors.textSecondary }]}>
          {t('enrollment.description', {
            device: account.enrollmentDevice ?? t('enrollment.device'),
          })}
        </Text>
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
        {button(t('enrollment.approve'), () =>
          store.approveEnrollment(request, entry),
        )}
        {button(t('enrollment.decline'), () =>
          store.declineEnrollment(request),
        )}
        {/* A request that expired or was handled elsewhere is replaced by the newest one. */}
        {button(t('enrollment.find'), store.refreshPrivateSync)}
      </SettingsBlock>
    </SettingsGroup>
  );
}

// Account settings: Linked Sign-Ins never come from a mailbox grant or a matching email.
function SignInMethods({
  account,
  button,
  failure,
  store,
}: {
  readonly account: Parameters<typeof signInMethodsCopy>[1];
  readonly button: SettingsButton;
  readonly failure: LinkFailure | undefined;
  readonly store: Registration;
}) {
  const colors = usePalette();
  const { t } = useLocalization();
  const methods = signInMethodsCopy(t, account);
  const { link } = methods;
  return (
    <SettingsGroup
      title={t('signInMethods.title')}
      footer={methods.description}>
      {failure === undefined && link === undefined ? null : (
        <SettingsBlock>
          {failure === undefined ? null : (
            <Text
              accessibilityRole="alert"
              style={[styles.text, { color: colors.textPrimary }]}>
              {linkFailureCopy(
                t,
                failure,
                otherSignInProvider(account.signInProvider),
              )}
            </Text>
          )}
          {link === undefined
            ? null
            : button(
                t('signInMethods.link', { provider: providerName(t, link) }),
                () => store.link(link),
              )}
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
          <Text
            accessibilityRole="alert"
            style={[styles.text, { color: colors.textPrimary }]}>
            {t(`accountRemoval.${failure}`)}
          </Text>
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
          <Text style={[styles.text, { color: colors.textPrimary }]}>
            {confirmation.description}
          </Text>
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
  store,
}: {
  readonly assistance: NativeAssistance;
  readonly button: SettingsButton;
  // Without one, every section shows, as on the welcome flow's account page.
  readonly destination?: SettingsDestination;
  readonly microsoft: boolean;
  readonly store: Registration;
}) {
  const {
    snapshot,
    linkFailure,
    recoveryKeyFailure,
    recoveryFailure,
    enrollmentFailure,
    revocationFailure,
  } = useSyncExternalStore(store.subscribe, store.getSnapshot);
  const { t } = useLocalization();
  if (snapshot.kind === 'signed-out') {
    return null;
  }
  const shows = (page: SettingsDestination) =>
    destination === undefined || destination === page;
  const recovery = (
    <RecoveryKeyUnlock
      account={snapshot}
      button={button}
      failure={recoveryFailure}
      store={store}
    />
  );
  if (snapshot.kind === 'device-pending') {
    return shows('account') ? (
      <>
        {privateSyncCopy(t, snapshot)?.enrollmentCode === undefined ? (
          button(t('enrollment.check'), store.refreshPrivateSync)
        ) : (
          <PrivateSync
            account={snapshot}
            button={button}
            failure={recoveryKeyFailure}
            store={store}
          />
        )}
        {recovery}
      </>
    ) : null;
  }
  const mailboxes = mailboxesOf(snapshot);
  return (
    <>
      {shows('mailboxes') ? (
        <Mailboxes
          account={snapshot}
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
        />
      ) : null}
      {shows('account') ? (
        <>
          <PrivateSync
            key={snapshot.recoveryKey ?? 'confirmed'}
            account={snapshot}
            button={button}
            failure={recoveryKeyFailure}
            store={store}
          />
          {recovery}
          <DeviceApproval
            // A code typed for one request never carries over to the next.
            key={snapshot.enrollmentRequest ?? 'none'}
            account={snapshot}
            button={button}
            failure={enrollmentFailure}
            store={store}
          />
          <TrustedDevices
            account={snapshot}
            button={button}
            failure={revocationFailure}
            store={store}
          />
          <SignInMethods
            account={snapshot}
            button={button}
            failure={linkFailure}
            store={store}
          />
        </>
      ) : null}
    </>
  );
}
