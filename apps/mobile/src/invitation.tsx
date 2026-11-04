import type { GmailInbox } from '@private-email/mail-core/gmail-inbox';
import type {
  EarlierResponse,
  Invitation,
  InvitationChoice,
  InvitationDetails,
  InvitationStatus,
} from '@private-email/mail-core/invitations';
import type { ReactNode } from 'react';

import {
  Alert,
  Button,
  Host,
  HStack,
  Label,
  Spacer,
  Text as SwiftUIText,
  VStack,
} from '@expo/ui/swift-ui';
import {
  accessibilityAddTraits,
  accessibilityLabel as spokenLabel,
  buttonBorderShape,
  buttonStyle,
  disabled,
  font,
  frame,
  tint,
} from '@expo/ui/swift-ui/modifiers';
import {
  invitationOf,
  invitationResponses,
  createInvitationFormats,
  invitationBlockedBy,
  invitationChoiceKeys,
  invitationStatus,
  invitationWas,
  invitationWhen,
  organizerName,
} from '@private-email/mail-core/invitations';
import { radius, spacing } from '@private-email/mail-core/theme';
import {
  use,
  useEffect,
  useMemo,
  useRef,
  useState,
  useSyncExternalStore,
} from 'react';
import {
  AccessibilityInfo,
  ActivityIndicator,
  Platform,
  StyleSheet,
  Text,
  useWindowDimensions,
  View,
} from 'react-native';

import { SFSymbol } from './design.tsx';
import { useLocalization } from './localization.ts';
import { useProviderName } from './mailbox.tsx';
import { AccountContext } from './registration-gate.tsx';
import { textStyles, usePalette } from './theme.ts';

// The iPhone and iPad card follows the Mac one in touch sizes: 14pt inset, Subheadline text, 18pt
// corners on iPhone and the 10pt card corners iPad shares with Mac.
// A row's value moves below its label when larger text leaves it too little room.
const styles = StyleSheet.create({
  card: {
    gap: spacing.m,
    padding: 14,
    borderRadius:
      Platform.OS === 'ios' && Platform.isPad ? radius.card : radius.touchCard,
    borderCurve: 'continuous',
  },
  heading: { flexDirection: 'row', alignItems: 'center', gap: spacing.s },
  headingText: { flex: 1 },
  badge: {
    paddingHorizontal: spacing.s,
    paddingVertical: 2,
    borderRadius: radius.badgeTouch,
    borderCurve: 'continuous',
  },
  title: { ...textStyles.headline },
  struck: { textDecorationLine: 'line-through' },
  details: { gap: 6 },
  row: { flexDirection: 'row', flexWrap: 'wrap', gap: spacing.s },
  label: { ...textStyles.subheadline, minWidth: 76 },
  value: { flexGrow: 1, flexShrink: 1, flexBasis: 160, gap: 2 },
  text: { ...textStyles.subheadline },
  emphasized: { ...textStyles.subheadline, fontWeight: '600' },
  smallEmphasized: { ...textStyles.footnote, fontWeight: '600' },
  status: {
    gap: 10,
    paddingTop: spacing.m,
    borderTopWidth: StyleSheet.hairlineWidth,
  },
  statusRow: { flexDirection: 'row', gap: spacing.s },
  statusText: { flex: 1, gap: 2 },
});

type InvitationInbox = Pick<
  GmailInbox,
  | 'send'
  | 'findSent'
  | 'getSnapshot'
  | 'subscribe'
  | 'responseSource'
  | 'load'
  | 'recordResponse'
>;

const choices = ['accepted', 'tentative', 'declined'] as const;
// The meeting's date and time formats in the person's language.
const useFormats = () => {
  const { settings } = useLocalization();
  return useMemo(
    () => createInvitationFormats(settings.locale),
    [settings.locale],
  );
};

// Each row is one VoiceOver element that speaks its label and values.
function DetailRow({
  label,
  spoken,
  children,
}: {
  readonly label: string;
  readonly spoken: readonly string[];
  readonly children: ReactNode;
}) {
  const colors = usePalette();
  return (
    <View
      accessible
      accessibilityLabel={[label, ...spoken].join(', ')}
      style={styles.row}>
      <Text style={[styles.label, { color: colors.textSecondary }]}>
        {label}
      </Text>
      <View style={styles.value}>{children}</View>
    </View>
  );
}

function Details({
  details,
  invited,
  earlier,
}: {
  readonly details: InvitationDetails;
  // Who was invited, then a secondary line about them; a cancelled meeting has no row.
  readonly invited?: readonly [string, string];
  // The response to an earlier revision at another time, which marks this one as updated.
  readonly earlier?: EarlierResponse | undefined;
}) {
  const colors = usePalette();
  const { t } = useLocalization();
  const formats = useFormats();
  const when = invitationWhen(t, formats, details);
  const was =
    earlier === undefined ? undefined : invitationWas(t, formats, earlier);
  const cancelled = invited === undefined;
  const from = t(cancelled ? 'invitation.cancelledBy' : 'invitation.from', {
    name: organizerName(details),
  });
  const badge = cancelled
    ? t('invitation.cancelled')
    : was === undefined
      ? undefined
      : t('invitation.updated');
  const title = details.summary ?? t('invitation.untitled');
  const organizer = [
    ...new Set([organizerName(details), details.organizer.address]),
  ];
  return (
    <>
      <View
        accessible
        accessibilityLabel={was === undefined ? from : `${from}, ${badge}`}
        style={styles.heading}>
        <SFSymbol
          name={cancelled ? 'xmark' : 'calendar'}
          color={cancelled ? colors.textSecondary : colors.accentInk}
        />
        <Text
          style={[
            styles.smallEmphasized,
            styles.headingText,
            { color: colors.textSecondary },
          ]}>
          {from}
        </Text>
        {badge === undefined ? null : (
          <View
            style={[
              styles.badge,
              { backgroundColor: colors.accentSelectionSubtle },
            ]}>
            <Text style={[styles.smallEmphasized, { color: colors.accentInk }]}>
              {badge}
            </Text>
          </View>
        )}
      </View>
      <View
        accessible
        accessibilityRole="header"
        accessibilityLabel={title}>
        <Text
          style={[
            styles.title,
            cancelled && styles.struck,
            { color: colors.textPrimary },
          ]}>
          {title}
        </Text>
      </View>
      <View style={styles.details}>
        <DetailRow
          label={t('invitation.when')}
          spoken={was === undefined ? [when] : [when, was]}>
          <Text style={[styles.text, { color: colors.textPrimary }]}>
            {when}
          </Text>
          {was === undefined ? null : (
            <Text style={[styles.text, { color: colors.textSecondary }]}>
              {was}
            </Text>
          )}
        </DetailRow>
        {details.location === undefined ? null : (
          <DetailRow
            label={t('invitation.where')}
            spoken={[details.location]}>
            <Text style={[styles.text, { color: colors.textPrimary }]}>
              {details.location}
            </Text>
          </DetailRow>
        )}
        <DetailRow
          label={t('invitation.organizer')}
          spoken={organizer}>
          {organizer.map((line, index) => (
            <Text
              key={line}
              style={[
                styles.text,
                {
                  color:
                    index === 0 ? colors.textPrimary : colors.textSecondary,
                },
              ]}>
              {line}
            </Text>
          ))}
        </DetailRow>
        {invited === undefined ? null : (
          <DetailRow
            label={t('invitation.invited')}
            spoken={invited}>
            <Text style={[styles.text, { color: colors.textPrimary }]}>
              {invited[0]}
            </Text>
            <Text style={[styles.text, { color: colors.textSecondary }]}>
              {invited[1]}
            </Text>
          </DetailRow>
        )}
      </View>
    </>
  );
}

// The response status row: an icon or a spinner, what happened, and what the person can do next.
function Status({
  icon,
  tone,
  busy = false,
  title,
  detail,
  children,
}: {
  readonly icon?: string;
  readonly tone?: InvitationStatus['tone'];
  readonly busy?: boolean;
  readonly title: string;
  readonly detail: string;
  readonly children?: ReactNode;
}) {
  const colors = usePalette();
  return (
    <View style={[styles.status, { borderTopColor: colors.separator }]}>
      <View style={styles.statusRow}>
        {busy ? (
          <ActivityIndicator size="small" />
        ) : (
          <SFSymbol
            name={icon ?? 'circle'}
            color={tone === undefined ? colors.textSecondary : colors[tone]}
          />
        )}
        <View
          accessible
          accessibilityLabel={`${title}. ${detail}`}
          style={styles.statusText}>
          <Text style={[styles.emphasized, { color: colors.textPrimary }]}>
            {title}
          </Text>
          <Text style={[styles.text, { color: colors.textSecondary }]}>
            {detail}
          </Text>
        </View>
      </View>
      {children}
    </View>
  );
}

// A row of native push buttons: the three choices share the width, the other actions keep theirs.
// From the first accessibility text size the buttons stack at full width, since a row would cut
// their labels short.
const useStacked = () => useWindowDimensions().fontScale > 1.4;

function Actions({
  fill = false,
  children,
}: {
  readonly fill?: boolean;
  readonly children: ReactNode;
}) {
  const stacked = useStacked();
  return (
    <Host matchContents={{ vertical: true }}>
      {stacked ? (
        <VStack spacing={spacing.s}>{children}</VStack>
      ) : (
        <HStack spacing={spacing.s}>
          {children}
          {fill ? null : <Spacer />}
        </HStack>
      )}
    </Host>
  );
}

function Action({
  label,
  spoken,
  chosen = false,
  fill = false,
  off = false,
  onPress,
}: {
  readonly label: string;
  readonly spoken?: string;
  readonly chosen?: boolean;
  readonly fill?: boolean;
  readonly off?: boolean;
  readonly onPress: () => void;
}) {
  const colors = usePalette();
  const stacked = useStacked();
  const wide = fill || stacked;
  const text = [
    font({ textStyle: 'subheadline', weight: 'semibold' }),
    ...(wide ? [frame({ maxWidth: Infinity })] : []),
  ];
  return (
    <Button
      onPress={onPress}
      modifiers={[
        buttonStyle(chosen ? 'borderedProminent' : 'bordered'),
        buttonBorderShape('capsule'),
        tint(chosen ? colors.accentFill : colors.accentInk),
        disabled(off),
        spokenLabel(spoken ?? label),
        ...(chosen ? [accessibilityAddTraits(['isSelected'])] : []),
      ]}>
      {chosen ? (
        <Label
          title={label}
          systemImage="checkmark"
          modifiers={text}
        />
      ) : (
        <SwiftUIText modifiers={text}>{label}</SwiftUIText>
      )}
    </Button>
  );
}

function Responding({
  inbox,
  invitation,
  earlier,
  connection,
  current,
}: {
  readonly inbox: InvitationInbox;
  readonly invitation: Invitation;
  readonly earlier: EarlierResponse | undefined;
  readonly connection: string | undefined;
  readonly current: () => boolean;
}) {
  const { t } = useLocalization();
  const provider = useProviderName();
  const account = use(AccountContext);
  // The choice a Respond Again alert asks about; leaving the message unmounts the alert.
  const [asking, setAsking] = useState<InvitationChoice>();
  const responses = invitationResponses(inbox);
  const recorded = useSyncExternalStore(responses.subscribe, () =>
    responses.state(invitation),
  );
  const sync = useSyncExternalStore(inbox.subscribe, () => {
    const state = inbox.getSnapshot();
    return state.kind === 'ready' ? state.sync : undefined;
  });
  const { time } = useFormats();
  const name = organizerName(invitation.details);
  const blocked =
    recorded.kind === 'unanswered' ||
    recorded.kind === 'sent' ||
    recorded.kind === 'refused'
      ? invitationBlockedBy(sync)
      : undefined;
  const shown = invitationStatus(
    blocked === undefined ? recorded : { kind: blocked, choice: 'accepted' },
    {
      t,
      name,
      address: invitation.address,
      provider,
      time,
      earlier: earlier?.choice,
    },
  );
  // iOS ignores live regions, so VoiceOver hears the status when it changes, not when it opens.
  const spoken = `${shown.title}. ${shown.detail}`;
  const previousSpoken = useRef(spoken);
  useEffect(() => {
    if (spoken !== previousSpoken.current) {
      previousSpoken.current = spoken;
      AccessibilityInfo.announceForAccessibilityWithOptions(spoken, {
        queue: true,
      });
    }
  }, [spoken]);
  const copy = (choice: InvitationChoice) => ({
    subject: t(`invitation.${choice}Subject`, {
      summary: invitation.details.summary ?? t('invitation.untitled'),
    }),
    text: t(`invitation.${choice}Text`, {
      address: invitation.address,
    }),
  });
  // One sign-in at a time: a second tap while the mailbox reloads starts nothing.
  const signingIn = useRef(false);
  const signIn = async (
    { authorizeMailbox }: NonNullable<typeof account>,
    mailbox: string,
  ) => {
    if (!current() || signingIn.current) {
      return;
    }
    signingIn.current = true;
    // Authorization also resolves when the person cancels it, so the buttons return only once the
    // reloaded mailbox no longer needs signing in.
    const signedIn = await authorizeMailbox(mailbox)
      .then(() => inbox.load())
      .then(
        () => {
          const state = inbox.getSnapshot();
          return state.kind === 'ready' && state.sync !== 'authentication';
        },
        () => false,
      )
      .finally(() => {
        signingIn.current = false;
      });
    if (signedIn && current()) {
      responses.signedIn(invitation);
    }
  };
  if (blocked === 'authentication' || recorded.kind === 'authentication') {
    return (
      <Status {...shown}>
        {account === undefined || connection === undefined ? undefined : (
          <Actions>
            <Action
              label={t('invitation.signIn')}
              onPress={() => {
                void signIn(account, connection);
              }}
            />
          </Actions>
        )}
      </Status>
    );
  }
  if (recorded.kind === 'unknown' || recorded.kind === 'checking') {
    const checking = recorded.kind === 'checking';
    const choice = t(`invitation.${invitationChoiceKeys[recorded.choice]}`);
    return (
      <Status {...shown}>
        <Actions>
          <Action
            label={t('invitation.checkAgain')}
            off={checking}
            onPress={() => {
              if (current()) {
                void responses.check(invitation);
              }
            }}
          />
          <Action
            label={t('invitation.respondAgain')}
            off={checking}
            onPress={() => {
              if (current()) {
                setAsking(recorded.choice);
              }
            }}
          />
          {/* The system alert owns focus and dismissal; Cancel's role makes it the dismissal choice. */}
          <Alert
            testID="respond-again"
            title={t('invitation.respondAgainTitle')}
            isPresented={asking !== undefined}
            onIsPresentedChange={(presented) => {
              if (!presented) {
                setAsking(undefined);
              }
            }}>
            {/* SwiftUI drops an alert attached to an empty view, so it anchors on a zero-size spacer. */}
            <Alert.Trigger>
              <Spacer modifiers={[frame({ width: 0, height: 0 })]} />
            </Alert.Trigger>
            <Alert.Actions>
              <Button
                label={t('invitation.respondAgainConfirm')}
                onPress={() => {
                  setAsking(undefined);
                  if (asking !== undefined && current()) {
                    void responses.respondAgain(
                      invitation,
                      asking,
                      copy(asking),
                    );
                  }
                }}
              />
              <Button
                // oxlint-disable-next-line jsx-a11y/aria-role -- SwiftUI button role, not ARIA.
                role="cancel"
                label={t('common.cancel')}
                onPress={() => {
                  setAsking(undefined);
                }}
              />
            </Alert.Actions>
            <Alert.Message>
              <SwiftUIText>
                {t('invitation.respondAgainDetail', { provider, choice, name })}
              </SwiftUIText>
            </Alert.Message>
          </Alert>
        </Actions>
      </Status>
    );
  }
  const chosen = recorded.kind === 'sent' ? recorded.choice : undefined;
  return (
    <Status {...shown}>
      <Actions fill>
        {choices.map((choice) => (
          <Action
            key={choice}
            fill
            chosen={chosen === choice}
            label={t(`invitation.${invitationChoiceKeys[choice]}`)}
            spoken={
              chosen === choice
                ? t(`invitation.${choice}`)
                : t(`invitation.${invitationChoiceKeys[choice]}`)
            }
            off={recorded.kind === 'sending' || blocked === 'offline'}
            onPress={() => {
              if (current()) {
                void responses.respond(invitation, choice, copy(choice));
              }
            }}
          />
        ))}
      </Actions>
    </Status>
  );
}

// The opened Gmail message's meeting invitation: the meeting, and Accept, Maybe and Decline for
// the mailbox the invitation names. A response is sent only when the person chooses it.
export function InvitationCard({
  inbox,
  id,
  connection,
  current,
}: {
  readonly inbox: InvitationInbox;
  readonly id: string;
  readonly connection: string | undefined;
  readonly current: () => boolean;
}) {
  const colors = usePalette();
  const { t } = useLocalization();
  const provider = useProviderName();
  const document = useSyncExternalStore(inbox.subscribe, () =>
    inbox.responseSource(id),
  );
  const address = useSyncExternalStore(inbox.subscribe, () => {
    const state = inbox.getSnapshot();
    return state.kind === 'ready' ? state.address : undefined;
  });
  const offer = useMemo(
    () =>
      document === undefined || address === undefined
        ? undefined
        : invitationOf(document, address),
    [document, address],
  );
  const responses = invitationResponses(inbox);
  const earlier = useSyncExternalStore(responses.subscribe, () =>
    offer?.kind === 'invited' ? responses.earlier(offer) : undefined,
  );
  if (offer === undefined) {
    return null;
  }
  const card = [styles.card, { backgroundColor: colors.fillQuiet }];
  if (offer.kind === 'unreadable') {
    return (
      <View style={card}>
        <View
          accessible
          accessibilityLabel={t('invitation.heading')}
          style={styles.heading}>
          <SFSymbol
            name="exclamationmark.triangle.fill"
            color={colors.statusWarning}
          />
          <Text
            style={[styles.smallEmphasized, { color: colors.textSecondary }]}>
            {t('invitation.heading')}
          </Text>
        </View>
        <Status
          icon="exclamationmark.triangle.fill"
          tone="statusWarning"
          title={t('invitation.unreadable')}
          detail={t('invitation.unreadableDetail')}
        />
      </View>
    );
  }
  if (offer.kind === 'cancelled') {
    return (
      <View style={card}>
        <Details details={offer.details} />
        <Status
          icon="xmark"
          title={t('invitation.meetingCancelled')}
          detail={t('invitation.meetingCancelledDetail')}
        />
      </View>
    );
  }
  if (offer.kind === 'elsewhere') {
    return (
      <View style={card}>
        <Details
          details={offer.details}
          invited={[offer.invited.join(', '), t('invitation.notYours')]}
        />
        <Status
          icon="person.crop.circle.badge.exclamationmark"
          title={t('invitation.elsewhere')}
          detail={t('invitation.elsewhereDetail', {
            name: organizerName(offer.details),
            addresses: offer.invited.join(', '),
          })}
        />
      </View>
    );
  }
  return (
    <View style={card}>
      <Details
        details={offer.details}
        invited={[
          t('invitation.you'),
          t('invitation.yourAddress', { address: offer.address, provider }),
        ]}
        earlier={earlier}
      />
      {/* A new invitation starts with no open question or announcement from the last one. */}
      <Responding
        key={`${offer.address}\n${offer.uid}\n${offer.sequence}`}
        inbox={inbox}
        invitation={offer}
        earlier={earlier}
        connection={connection}
        current={current}
      />
    </View>
  );
}
