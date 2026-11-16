import type { Translate } from '@private-email/localization';
import type { NativeAssistance } from '@private-email/mail-core/assistance';
import type {
  AccountRemoval,
  EnrollmentFailure,
  MailboxConnection,
  MailboxRemovalFailure,
  MailProfile,
  RecoveryFailure,
  RecoveryKeyFailure,
  Registration,
  RegistrationScreen,
  RemovalFailure,
} from '@private-email/mail-core/registration';

import { Host, Button as SwiftUIButton } from '@expo/ui/swift-ui';
import {
  buttonStyle,
  font,
  foregroundStyle,
  frame,
} from '@expo/ui/swift-ui/modifiers';
import { profileName } from '@private-email/mail-core/profile-windows';
import {
  profilesOf,
  recoveryKeyEntry,
} from '@private-email/mail-core/registration';
import { palette, typography } from '@private-email/mail-core/theme';
import { useEffect, useState, useSyncExternalStore } from 'react';
import {
  AccessibilityInfo,
  ActivityIndicator,
  AppState,
  Platform,
  Pressable,
  Text,
  TextInput,
  View,
} from 'react-native';

import type { SettingsButton, SettingsDestination } from './settings.tsx';

import {
  AnnouncedAlert,
  Button,
  MenuButton,
  Notice,
  SFSymbol,
  useOutcomeAnnouncement,
} from './design.tsx';
import { ImapSetup } from './imap-setup.tsx';
import { useLocalization } from './localization.ts';
import { MailAssistanceSettings } from './mail-assistance.tsx';
import { updatedOf, useAllMailboxes, useNow } from './mailbox-state.ts';
import { NotificationSettings } from './notification-settings.tsx';
import { OnboardingAction, TrustCard } from './onboarding.tsx';
import { MailProfilesSettings } from './profile-settings.tsx';
import { registrationStyles as styles } from './registration-styles.ts';
import { RemoteContentSettings } from './remote-content.tsx';
import {
  settingsColumns,
  SettingsBlock,
  SettingsGroup,
  SettingsRow,
} from './settings.tsx';
import { SignatureSettings } from './signature-settings.tsx';
import { SpamTrashFolders } from './spam-trash-settings.tsx';
import { usePalette } from './theme.ts';
import { TrustedDevices } from './trusted-devices.tsx';

// The device a failed removal names.
const device = Platform.OS === 'ios' && Platform.isPad ? 'ipad' : 'iphone';
// iPhone draws trust steps on the brand fill, one step at a time.
const phone = Platform.OS === 'ios' && !Platform.isPad;
// iPad draws the Recovery Key steps on the brand fill too, at its onboarding sizes.
const ipad = Platform.OS === 'ios' && Platform.isPad;
// How often the iPhone approval step checks for its approval while it is on screen and the app is
// not in the background; a request and its approval each last 15 minutes.
const approvalInterval = 10_000;

// Confirms removing a Mailbox Connection. It stays open until removal settles, and a failure
// replaces the description and is announced at once.
function RemoveConfirmation({
  address,
  description,
  button,
  remove,
  onClose,
}: {
  readonly address: string;
  readonly description: string;
  readonly button: SettingsButton;
  readonly remove: () => Promise<MailboxRemovalFailure | undefined>;
  readonly onClose: () => void;
}) {
  const colors = usePalette();
  const { t } = useLocalization();
  const [removing, setRemoving] = useState(false);
  const [failed, setFailed] = useState<string>();
  return (
    <>
      {failed === undefined ? (
        <Text style={[styles.removalText, { color: colors.textPrimary }]}>
          {description}
        </Text>
      ) : (
        <View style={styles.inline}>
          <SFSymbol
            name="exclamationmark.triangle.fill"
            color={colors.statusWarning}
          />
          <View style={styles.grow}>
            <Text style={[styles.removalText, { color: colors.textPrimary }]}>
              {failed}
            </Text>
          </View>
        </View>
      )}
      <View style={styles.inline}>
        {removing ? (
          <ActivityIndicator
            size="small"
            color={colors.textSecondary}
          />
        ) : null}
        {button(
          removing
            ? t('mailboxes.removing')
            : t('mailboxes.remove', { address }),
          async () => {
            setFailed(undefined);
            setRemoving(true);
            const failure = await remove();
            setRemoving(false);
            if (failure === undefined) {
              onClose();
              return;
            }
            const message = t(
              failure === 'unconfirmed'
                ? 'mailboxes.removeUnconfirmed'
                : 'mailboxes.removeFailed',
              failure === 'offline'
                ? { address, context: device }
                : { address },
            );
            setFailed(message);
            AccessibilityInfo.announceForAccessibility(message);
          },
          // iPhone's row has room for Remove and Cancel only without the address.
          {
            tone: 'destructive',
            ...(device === 'iphone' &&
              !removing && { title: t('settings.remove') }),
          },
        )}
        {button(t('mailboxes.cancel'), async () => {
          onClose();
        })}
      </View>
    </>
  );
}

// A connected mailbox's provider and Profile, then when it last synchronized once it has. iPad
// reports that at the row's end instead.
const connectedSummary = (
  t: Translate,
  summary: Readonly<{
    provider: string;
    profile: string;
    updated: string | undefined;
  }>,
) =>
  summary.updated === undefined || settingsColumns
    ? t('mailboxes.connectedProfile', summary)
    : t('mailboxes.connectedProfileUpdated', summary);

// When a connected mailbox last synchronized, at the end of its iPad row as the frames show it.
function LastSynchronized({
  updated,
}: {
  readonly updated: string | undefined;
}) {
  const colors = usePalette();
  return settingsColumns && updated !== undefined ? (
    <Text style={[typography.ipadList.body, { color: colors.textSecondary }]}>
      {updated}
    </Text>
  ) : null;
}

// A row that runs one action, its title in the row's text column.
function ActionRow({
  label,
  title,
  tone,
  disabled,
  onPress,
}: {
  readonly label: string;
  readonly title: string;
  readonly tone?: 'destructive';
  readonly disabled: boolean;
  readonly onPress: () => void;
}) {
  const colors = usePalette();
  return (
    <Pressable
      accessibilityRole="button"
      accessibilityLabel={label}
      accessibilityState={{ disabled }}
      disabled={disabled}
      onPress={onPress}
      style={({ pressed }) =>
        pressed && { backgroundColor: colors.accentSelectionSubtle }
      }>
      <SettingsRow
        title={title}
        titleTone={tone}
        disabled={disabled}
      />
    </Pressable>
  );
}

// A connection's Enter the Password… and Remove…, each absent while its form is open. iPhone gives
// an IMAP connection's actions rows of their own below it, so its address keeps the row's width;
// elsewhere they are push buttons in the connection's row.
function ConnectionActions({
  place,
  imap,
  address,
  button,
  busy,
  repair,
  remove,
}: {
  readonly place: 'row' | 'below';
  readonly imap: boolean;
  readonly address: string;
  readonly button: SettingsButton;
  readonly busy: boolean;
  readonly repair: (() => void) | undefined;
  readonly remove: (() => void) | undefined;
}) {
  const { t } = useLocalization();
  const rows = imap && !settingsColumns;
  if (rows !== (place === 'below')) {
    return null;
  }
  const repairLabel = t('mailboxes.enterPassword', { address });
  const removeLabel = t('mailboxes.remove', { address });
  return rows ? (
    <>
      {repair === undefined ? null : (
        <ActionRow
          label={repairLabel}
          title={t('settings.enterPassword')}
          disabled={busy}
          onPress={repair}
        />
      )}
      {remove === undefined ? null : (
        <ActionRow
          label={removeLabel}
          title={t('settings.remove')}
          tone="destructive"
          disabled={busy}
          onPress={remove}
        />
      )}
    </>
  ) : (
    <>
      {repair === undefined
        ? null
        : button(
            repairLabel,
            async () => {
              repair();
            },
            { title: t('settings.enterPassword') },
          )}
      {remove === undefined
        ? null
        : button(
            removeLabel,
            async () => {
              remove();
            },
            { title: t('settings.remove') },
          )}
    </>
  );
}

// Each Mailbox Connection with its state, adding another, and removal after confirmation.
function Mailboxes({
  mailboxes,
  profiles,
  button,
  microsoft,
  store,
}: {
  readonly mailboxes: readonly MailboxConnection[];
  // The Mail Profiles besides the Default Profile, which name each connection's owner.
  readonly profiles: readonly MailProfile[];
  readonly button: SettingsButton;
  readonly microsoft: boolean;
  readonly store: Registration;
}) {
  const colors = usePalette();
  const { t } = useLocalization();
  const { busy } = useSyncExternalStore(store.subscribe, store.getSnapshot);
  // Each connection's open Inbox, whose last synchronization the summary reports.
  const inboxes = useAllMailboxes();
  const now = useNow();
  const updatedFor = (mailbox: MailboxConnection) =>
    mailbox.state === 'connected'
      ? updatedOf(t, inboxes.find(({ id }) => id === mailbox.id)?.state, now)
      : undefined;
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
        const actions = {
          imap: imapMailbox,
          address: mailbox.address,
          button,
          busy,
          repair:
            imapMailbox && !repairing
              ? () => {
                  setImap({ kind: 'repair', id: mailbox.id });
                }
              : undefined,
          remove:
            confirming === mailbox.id
              ? undefined
              : () => {
                  setConfirming(mailbox.id);
                },
        };
        const updated = updatedFor(mailbox);
        return (
          <View key={mailbox.id}>
            <SettingsRow
              icon="at"
              title={mailbox.address}
              subtitle={
                mailbox.state === 'connected'
                  ? connectedSummary(t, {
                      provider,
                      profile: profileName(t, mailbox.profile, profiles),
                      updated,
                    })
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
              <LastSynchronized updated={updated} />
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
              <ConnectionActions
                place="row"
                {...actions}
              />
            </SettingsRow>
            <ConnectionActions
              place="below"
              {...actions}
            />
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
                  <RemoveConfirmation
                    address={mailbox.address}
                    button={button}
                    description={t(
                      imapMailbox
                        ? 'mailboxes.confirm_imap'
                        : 'mailboxes.confirm',
                      { address: mailbox.address, provider },
                    )}
                    onClose={() => {
                      setConfirming(undefined);
                    }}
                    remove={async () => {
                      await store.removeMailbox(mailbox.id);
                      return store.getSnapshot().mailboxRemovalFailure;
                    }}
                  />
                ) : null}
              </SettingsBlock>
            ) : null}
          </View>
        );
      })}
      {settingsColumns ? (
        // iPad adds every provider from one row's native menu, as the frames group it.
        <MenuButton
          accessibilityLabel={t('mailboxes.addConnection')}
          disabled={busy}
          sections={[
            {
              items: [
                {
                  key: 'gmail',
                  title: t('mailboxes.add'),
                  symbol: '',
                  run: () => store.addMailbox('gmail', true),
                },
                ...(microsoft
                  ? [
                      {
                        key: 'microsoft-graph',
                        title: t('mailboxes.addMicrosoft'),
                        symbol: '',
                        run: () => store.addMailbox('microsoft-graph'),
                      },
                    ]
                  : []),
                {
                  key: 'imap',
                  title: t('mailboxes.addImap'),
                  symbol: '',
                  run: () => {
                    setImap({ kind: 'new' });
                  },
                },
              ],
            },
          ]}>
          <SettingsRow
            title={t('mailboxes.addConnection')}
            titleTone="accent"
          />
        </MenuButton>
      ) : null}
      {settingsColumns && imap?.kind !== 'new' ? null : (
        <SettingsBlock>
          {settingsColumns ? null : (
            <>
              {button(t('mailboxes.add'), () =>
                store.addMailbox('gmail', true),
              )}
              {microsoft
                ? button(t('mailboxes.addMicrosoft'), () =>
                    store.addMailbox('microsoft-graph'),
                  )
                : null}
            </>
          )}
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
      )}
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

// A Recovery Key step's action: white on brand deep, disabled while registration is busy.
function StepAction({
  label,
  action,
  store,
  disabled = false,
}: {
  readonly label: string;
  readonly action: () => Promise<void>;
  readonly store: Registration;
  readonly disabled?: boolean;
}) {
  const { busy } = useSyncExternalStore(store.subscribe, store.getSnapshot);
  return (
    <OnboardingAction
      disabled={busy || disabled}
      fill="onDeep"
      label={label}
      onPress={() => {
        void action();
      }}
    />
  );
}

// A trust step's alternative: a text button in the brand step's ink.
function StepLink({
  label,
  onPress,
}: {
  readonly label: string;
  readonly onPress: () => void;
}) {
  const colors = usePalette();
  return (
    <Host
      matchContents
      style={styles.stepLink}>
      <SwiftUIButton
        label={label}
        modifiers={[
          buttonStyle('plain'),
          font({ textStyle: 'headline' }),
          foregroundStyle(colors.brandOnDeep),
          frame({ minWidth: 44, minHeight: 44 }),
        ]}
        onPress={onPress}
      />
    </Host>
  );
}

// The iPhone approval step waits for a trusted device by checking for itself, so its line stays
// true. VoiceOver hears it once; a check that cannot finish, such as offline, changes nothing and
// the next one tries again. An Apple sign-in from before launch cannot check silently, so the
// person checks once and signs in.
function WaitingForApproval({ store }: { readonly store: Registration }) {
  const { t } = useLocalization();
  const card = useCardButton(store);
  const { snapshot } = useSyncExternalStore(store.subscribe, store.getSnapshot);
  const silent =
    snapshot.kind !== 'device-pending' || snapshot.approvalSignIn !== true;
  const label = t('enrollment.waiting');
  useOutcomeAnnouncement(silent ? label : undefined, true);
  useEffect(() => {
    if (!silent) {
      return;
    }
    let timer: ReturnType<typeof setInterval> | undefined = undefined;
    const watch = (state: typeof AppState.currentState) => {
      clearInterval(timer);
      timer =
        state === 'background'
          ? undefined
          : setInterval(() => {
              void store.checkForApproval();
            }, approvalInterval);
    };
    watch(AppState.currentState);
    const subscription = AppState.addEventListener('change', watch);
    return () => {
      subscription.remove();
      clearInterval(timer);
    };
  }, [silent, store]);
  if (!silent) {
    return card(t('enrollment.check'), store.refreshPrivateSync, 'accent');
  }
  // The brand step's secondary ink.
  const ink = palette.dark.textSecondary;
  return (
    <View style={styles.inline}>
      <ActivityIndicator
        size="small"
        color={ink}
      />
      <Text style={[styles.removalText, { color: ink }]}>{label}</Text>
    </View>
  );
}

// A Recovery Key step's field: outlined on iPhone, in a well on iPad, as the frames draw them.
function brandField(colors: ReturnType<typeof usePalette>) {
  return ipad
    ? {
        placeholderTextColor: `${colors.brandOnDeep}99`,
        style: [
          styles.input,
          styles.ipadBrandInput,
          {
            backgroundColor: colors.brandWell,
            borderColor: colors.brandWellBorder,
            color: colors.textPrimary,
          },
        ],
      }
    : {
        placeholderTextColor: colors.textSecondary,
        style: [
          styles.input,
          { borderColor: colors.separator, color: colors.textPrimary },
        ],
      };
}

// End-to-End Encrypted Product Sync; the Recovery Key stays visible until its setup is confirmed.
function PrivateSync({
  copy,
  failure,
  store,
  onRecoveryKey,
}: {
  readonly copy: RegistrationScreen['privateSync']['copy'];
  readonly failure: RecoveryKeyFailure | undefined;
  readonly store: Registration;
  // On iPhone, opens the Recovery Key step from the approval step.
  readonly onRecoveryKey?: (() => void) | undefined;
}) {
  const schemeColors = usePalette();
  const { t } = useLocalization();
  const card = useCardButton(store);
  const [entry, setEntry] = useState('');
  if (copy === undefined) {
    return null;
  }
  const { recoveryKey, enrollmentCode } = copy;
  // iPad draws only the Recovery Key step on the brand fill.
  const brand =
    recoveryKey !== undefined || (phone && enrollmentCode !== undefined);
  const body = [styles.text, brand && ipad && styles.padSheetText];
  const colors = brand
    ? {
        ...schemeColors,
        textPrimary: schemeColors.brandOnDeep,
        textSecondary: palette.dark.textSecondary,
        fillQuiet: palette.dark.fillQuiet,
        separator: palette.dark.textSecondary,
      }
    : schemeColors;
  const notes = (
    <>
      {copy.mailboxes === undefined ? null : (
        <Text style={[body, { color: colors.textSecondary }]}>
          {copy.mailboxes}
        </Text>
      )}
      {copy.pending === undefined ? null : (
        <Text style={[body, { color: colors.textPrimary }]}>
          {copy.pending}
        </Text>
      )}
    </>
  );
  if (recoveryKey !== undefined) {
    return (
      <TrustCard
        fill="brand"
        icon="key"
        title={copy.title}
        description={copy.description}>
        <Text
          selectable
          testID="recovery-key"
          style={[
            styles.recoveryKey,
            styles.brandRecoveryKey,
            ipad && styles.ipadBrandRecoveryKey,
            {
              color: colors.textPrimary,
              backgroundColor: schemeColors.brandWell,
              borderColor: schemeColors.brandWellBorder,
            },
          ]}>
          {recoveryKey}
        </Text>
        <Text style={[body, { color: colors.textSecondary }]}>
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
          {...brandField(colors)}
          value={entry}
        />
        {failure === undefined ? null : (
          <AnnouncedAlert style={[body, { color: colors.textPrimary }]}>
            {t(`recoveryKeyConfirmation.${failure}`)}
          </AnnouncedAlert>
        )}
        <StepAction
          label={t('recoveryKeyConfirmation.confirm')}
          action={() => store.confirmRecoveryKey(entry)}
          store={store}
          // The frames draw Confirm disabled until the last four characters are entered.
          disabled={entry === ''}
        />
        {notes}
      </TrustCard>
    );
  }
  if (enrollmentCode !== undefined) {
    return (
      <TrustCard
        fill={brand ? 'brand' : 'content'}
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
        {brand ? (
          <WaitingForApproval store={store} />
        ) : (
          card(t('enrollment.check'), store.refreshPrivateSync, 'accent')
        )}
        {notes}
        {onRecoveryKey === undefined ? null : (
          <StepLink
            label={t('enrollment.useRecoveryKey')}
            onPress={onRecoveryKey}
          />
        )}
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
  onBack,
}: {
  // Recovery Key entry is offered only where the account has keys that this device lacks.
  readonly offered: boolean;
  readonly failure: RecoveryFailure | undefined;
  readonly store: Registration;
  // On iPhone, returns to the approval step.
  readonly onBack?: () => void;
}) {
  const schemeColors = usePalette();
  const colors = {
    ...schemeColors,
    textPrimary: schemeColors.brandOnDeep,
    textSecondary: palette.dark.textSecondary,
    separator: palette.dark.textSecondary,
  };
  const { t } = useLocalization();
  const [entry, setEntry] = useState('');
  if (!offered) {
    return null;
  }
  return (
    <>
      <TrustCard
        fill="brand"
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
          {...brandField(colors)}
          value={entry}
        />
        {failure === undefined ? null : (
          <AnnouncedAlert
            style={[
              styles.text,
              ipad && styles.padSheetText,
              { color: colors.textPrimary },
            ]}>
            {t(`recovery.${failure}`)}
          </AnnouncedAlert>
        )}
        <StepAction
          label={t('recovery.unlock')}
          action={() => store.recoverWithRecoveryKey(entry)}
          store={store}
        />
        {onBack === undefined ? null : (
          <StepLink
            label={t('enrollment.waitInstead')}
            onPress={onBack}
          />
        )}
      </TrustCard>
      <Notice
        icon="info.circle"
        message={t('recovery.lost')}
      />
    </>
  );
}

// A Pending Device's Enrollment Code and Recovery Key. iPhone shows them as separate steps, each
// offering the other as a text button.
function PendingApproval({
  copy,
  offersRecovery,
  recoveryFailure,
  recoveryKeyFailure,
  store,
}: {
  readonly copy: RegistrationScreen['privateSync']['copy'];
  readonly offersRecovery: boolean;
  readonly recoveryFailure: RecoveryFailure | undefined;
  readonly recoveryKeyFailure: RecoveryKeyFailure | undefined;
  readonly store: Registration;
}) {
  const [recovering, setRecovering] = useState(false);
  if (!phone) {
    return (
      <>
        <PrivateSync
          copy={copy}
          failure={recoveryKeyFailure}
          store={store}
        />
        <RecoveryKeyUnlock
          offered={offersRecovery}
          failure={recoveryFailure}
          store={store}
        />
      </>
    );
  }
  if (recovering && offersRecovery) {
    return (
      <RecoveryKeyUnlock
        offered
        failure={recoveryFailure}
        store={store}
        onBack={() => {
          setRecovering(false);
        }}
      />
    );
  }
  return (
    <PrivateSync
      copy={copy}
      failure={recoveryKeyFailure}
      store={store}
      onRecoveryKey={
        offersRecovery
          ? () => {
              setRecovering(true);
            }
          : undefined
      }
    />
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
      <AnnouncedAlert style={[styles.text, { color: colors.textPrimary }]}>
        {t(`enrollment.${failure}`)}
      </AnnouncedAlert>
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
            <AnnouncedAlert
              style={[styles.text, { color: colors.textPrimary }]}>
              {failure}
            </AnnouncedAlert>
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
          <AnnouncedAlert style={[styles.text, { color: colors.textPrimary }]}>
            {t(`accountRemoval.${failure}`)}
          </AnnouncedAlert>
        </SettingsBlock>
      )}
      {selected === undefined ? (
        <SettingsRow
          title={t('settings.signOut')}
          // The iPhone frame centres its push button in a 62.4pt row.
          minHeight={settingsColumns ? undefined : 62.4}>
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
    if (!shows('account')) {
      return null;
    }
    return privateSync.copy?.enrollmentCode === undefined ? (
      <>
        {button(t('enrollment.check'), store.refreshPrivateSync)}
        {recovery}
      </>
    ) : (
      <PendingApproval
        copy={privateSync.copy}
        offersRecovery={privateSync.offersRecovery}
        recoveryFailure={recoveryFailure}
        recoveryKeyFailure={recoveryKeyFailure}
        store={store}
      />
    );
  }
  return (
    <>
      {shows('mailboxes') ? (
        <Mailboxes
          mailboxes={mailboxes}
          profiles={profilesOf(snapshot)}
          button={button}
          microsoft={microsoft}
          store={store}
        />
      ) : null}
      {shows('mailboxes') ? (
        <SpamTrashFolders
          mailboxes={mailboxes}
          store={store}
        />
      ) : null}
      {destination === 'profiles' ? (
        <MailProfilesSettings
          account={snapshot.productAccountId}
          profiles={profilesOf(snapshot)}
          mailboxes={mailboxes}
          store={store}
        />
      ) : null}
      {destination === 'signatures' ? (
        <SignatureSettings
          mailboxes={mailboxes}
          store={store}
        />
      ) : null}
      {destination === 'notifications' ? (
        <NotificationSettings
          button={button}
          mailboxes={mailboxes}
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
