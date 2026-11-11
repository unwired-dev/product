import type { GmailInbox } from '@private-email/mail-core/inbox-store';
import type {
  EarlierResponse,
  Invitation,
  InvitationChoice,
  InvitationDetails,
  InvitationStatus,
} from '@private-email/mail-core/invitations';
import type { ReactNode } from 'react';

import {
  alsoInvited,
  invitationOf,
  invitationResponses,
  createInvitationFormats,
  invitationBlockedBy,
  invitationChoiceKeys,
  invitationStatus,
  invitationRepeats,
  invitationScope,
  invitationWas,
  invitationWhen,
  organizerName,
} from '@private-email/mail-core/invitations';
import { radius, spacing } from '@private-email/mail-core/theme';
import {
  createContext,
  use,
  useEffect,
  useLayoutEffect,
  useMemo,
  useRef,
  useSyncExternalStore,
} from 'react';
import { ActivityIndicator, StyleSheet, Text, View } from 'react-native';

import { askInSheet, Button, SFSymbol } from './design.tsx';
import { useLocalization } from './localization.ts';
import { useMailboxes, useProviderName } from './mailbox.tsx';
import { AccountContext } from './registration-gate.tsx';
import { textStyles, usePalette } from './theme.ts';

// Opens another message of the reader's mailbox in its place, such as an invitation's newer
// version; a reader without it opens none.
export const OpenMessageContext = createContext<
  ((id: string) => void) | undefined
>(undefined);

const styles = StyleSheet.create({
  card: {
    gap: spacing.m,
    padding: spacing.m,
    borderRadius: radius.card,
    borderCurve: 'continuous',
  },
  heading: { flexDirection: 'row', alignItems: 'center', gap: spacing.s },
  headingText: { flex: 1 },
  badge: {
    paddingHorizontal: spacing.s,
    paddingVertical: 2,
    borderRadius: radius.badgeMac,
    borderCurve: 'continuous',
  },
  title: { ...textStyles.title3Emphasized },
  struck: { textDecorationLine: 'line-through' },
  details: { gap: 6 },
  row: { flexDirection: 'row', gap: spacing.s },
  label: { ...textStyles.body, width: 76 },
  value: { flex: 1, gap: 2 },
  text: { ...textStyles.body },
  emphasized: { ...textStyles.bodyEmphasized },
  smallEmphasized: { ...textStyles.subheadlineEmphasized },
  status: {
    gap: 10,
    paddingTop: spacing.m,
    borderTopWidth: StyleSheet.hairlineWidth,
  },
  statusRow: { flexDirection: 'row', gap: spacing.s },
  statusText: { flex: 1, gap: 2 },
  actions: { flexDirection: 'row', flexWrap: 'wrap', gap: spacing.s },
});

type InvitationInbox = Pick<
  GmailInbox,
  | 'send'
  | 'findSent'
  | 'findMessage'
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

// React Native macOS doesn't expose plain Text to VoiceOver, so each row is one element that speaks
// its label and values.
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
  older,
  unanswerable,
}: {
  readonly details: InvitationDetails;
  // Who was invited, then secondary lines about them; a meeting nobody can answer has no row.
  readonly invited?: readonly string[];
  // The response to an earlier revision at another time, which marks this one as updated.
  readonly earlier?: EarlierResponse | undefined;
  // A revision older than one the person answered, which has no Invited row.
  readonly older?: boolean;
  // Why nobody can answer it: a cancellation is struck through, and a series update that
  // names no one meeting has no repeats line.
  readonly unanswerable?: 'cancelled' | 'ambiguous';
}) {
  const colors = usePalette();
  const { t } = useLocalization();
  const formats = useFormats();
  const when = invitationWhen(t, formats, details);
  const repeats =
    unanswerable === 'ambiguous'
      ? undefined
      : invitationRepeats(t, formats, details);
  const was =
    earlier === undefined ? undefined : invitationWas(t, formats, earlier);
  const cancelled = unanswerable === 'cancelled';
  const invitedBy =
    details.recurrence === undefined
      ? 'invitation.from'
      : 'invitation.fromOneMeeting';
  const from = t(cancelled ? 'invitation.cancelledBy' : invitedBy, {
    name: organizerName(details),
  });
  const revised = older
    ? t('invitation.olderVersion')
    : was && t('invitation.updated');
  const badge = cancelled ? t('invitation.cancelled') : revised;
  const title = details.summary ?? t('invitation.untitled');
  const organizer = [
    ...new Set([organizerName(details), details.organizer.address]),
  ];
  return (
    <>
      <View
        accessible
        accessibilityLabel={
          was === undefined && !older ? from : `${from}, ${badge}`
        }
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
          spoken={[when, repeats, was].filter((line) => line !== undefined)}>
          <Text style={[styles.text, { color: colors.textPrimary }]}>
            {when}
          </Text>
          {repeats === undefined ? null : (
            <Text style={[styles.text, { color: colors.textSecondary }]}>
              {repeats}
            </Text>
          )}
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
        {invited === undefined || older ? null : (
          <DetailRow
            label={t('invitation.invited')}
            spoken={invited}>
            {invited.map((line, index) => (
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
          accessibilityLiveRegion="polite"
          style={styles.statusText}>
          <Text style={[styles.emphasized, { color: colors.textPrimary }]}>
            {title}
          </Text>
          <Text style={[styles.text, { color: colors.textSecondary }]}>
            {detail}
          </Text>
        </View>
      </View>
      {children === undefined ? null : (
        <View style={styles.actions}>{children}</View>
      )}
    </View>
  );
}

function Responding({
  inbox,
  invitation,
  earlier,
  others,
  connection,
  current,
}: {
  readonly inbox: InvitationInbox;
  readonly invitation: Invitation;
  readonly earlier: EarlierResponse | undefined;
  // How many of the Profile's other addresses the invitation also names.
  readonly others: number;
  readonly connection: string | undefined;
  readonly current: () => boolean;
}) {
  const { t } = useLocalization();
  const provider = useProviderName();
  const account = use(AccountContext);
  const anchor = useRef<View>(null);
  // Leaving the message closes a Respond Again question asked in it.
  const asked = useRef<ReturnType<typeof askInSheet>>(undefined);
  useLayoutEffect(
    () => () => {
      asked.current?.retire();
    },
    [],
  );
  const responses = invitationResponses(inbox);
  const recorded = useSyncExternalStore(responses.subscribe, () =>
    responses.state(invitation),
  );
  const latest = useSyncExternalStore(responses.subscribe, () =>
    responses.latest(invitation),
  );
  const older = recorded.kind === 'older';
  // An archived newer revision is asked of Gmail, so Show Latest can open it.
  useEffect(() => {
    if (older && latest === undefined) {
      void responses.findLatest(invitation);
    }
  }, [responses, invitation, older, latest]);
  const open = use(OpenMessageContext);
  const sync = useSyncExternalStore(inbox.subscribe, () => {
    const state = inbox.getSnapshot();
    return state.kind === 'ready' ? state.sync : undefined;
  });
  const formats = useFormats();
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
      time: formats.time,
      scope: invitationScope(t, formats, invitation.details),
      alsoInvited: others,
      earlier: earlier?.choice,
    },
  );
  const copy = (choice: InvitationChoice) => ({
    subject: t(`invitation.${choice}Subject`, {
      summary: invitation.details.summary ?? t('invitation.untitled'),
    }),
    text: t(`invitation.${choice}Text`, {
      address: invitation.address,
    }),
  });
  const respondAgain = async (choice: InvitationChoice) => {
    if (!current()) {
      return;
    }
    const question = askInSheet(anchor.current, {
      title: t('invitation.respondAgainTitle'),
      detail: t('invitation.respondAgainDetail', {
        provider,
        choice: t(`invitation.${invitationChoiceKeys[choice]}`),
        name,
      }),
      buttons: [t('invitation.respondAgainConfirm'), t('common.cancel')],
    });
    asked.current = question;
    if ((await question.answer) === 0 && current()) {
      await responses.respondAgain(invitation, choice, copy(choice));
    }
  };
  const signIn = async (
    { authorizeMailbox }: NonNullable<typeof account>,
    mailbox: string,
  ) => {
    if (!current()) {
      return;
    }
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
      );
    if (signedIn && current()) {
      responses.signedIn(invitation);
    }
  };
  // A mailbox removed while sending answers nothing, and no other mailbox answers for it.
  if (recorded.kind === 'removed') {
    return <Status {...shown} />;
  }
  // An older revision cannot respond, so it only points to the newer one.
  if (older) {
    return (
      <Status {...shown}>
        {latest === undefined || open === undefined ? undefined : (
          <Button
            label={t('invitation.showLatest')}
            onPress={() => {
              if (current()) {
                open(latest);
              }
            }}
          />
        )}
      </Status>
    );
  }
  if (blocked === 'authentication' || recorded.kind === 'authentication') {
    return (
      <Status {...shown}>
        {account === undefined || connection === undefined ? undefined : (
          <Button
            label={t('invitation.signIn')}
            onPress={() => {
              void signIn(account, connection);
            }}
          />
        )}
      </Status>
    );
  }
  if (recorded.kind === 'unknown' || recorded.kind === 'checking') {
    const checking = recorded.kind === 'checking';
    return (
      <View
        ref={anchor}
        collapsable={false}>
        <Status {...shown}>
          <Button
            label={t('invitation.checkAgain')}
            disabled={checking}
            onPress={() => {
              if (current()) {
                void responses.check(invitation);
              }
            }}
          />
          <Button
            label={t('invitation.respondAgain')}
            disabled={checking}
            onPress={() => {
              void respondAgain(recorded.choice);
            }}
          />
        </Status>
      </View>
    );
  }
  const chosen = recorded.kind === 'sent' ? recorded.choice : undefined;
  return (
    <Status {...shown}>
      {choices.map((choice) => (
        <Button
          key={choice}
          fill={chosen === choice ? 'accent' : 'quiet'}
          label={
            chosen === choice
              ? t('invitation.chosen', {
                  choice: t(`invitation.${invitationChoiceKeys[choice]}`),
                })
              : t(`invitation.${invitationChoiceKeys[choice]}`)
          }
          accessibilityLabel={
            chosen === choice
              ? t(`invitation.${choice}`)
              : t(`invitation.${invitationChoiceKeys[choice]}`)
          }
          disabled={recorded.kind === 'sending' || blocked === 'offline'}
          onPress={() => {
            if (current()) {
              void responses.respond(invitation, choice, copy(choice));
            }
          }}
        />
      ))}
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
  if (offer === undefined) {
    return null;
  }
  const card = [styles.card, { backgroundColor: colors.fillQuiet }];
  if (offer.kind === 'unreadable') {
    return (
      <View style={card}>
        <View
          accessible
          accessibilityLabel={t('invitation.heading')}>
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
        <Details
          details={offer.details}
          unanswerable="cancelled"
        />
        <Status
          icon="xmark"
          title={t('invitation.meetingCancelled')}
          detail={t('invitation.meetingCancelledDetail')}
        />
      </View>
    );
  }
  if (offer.kind === 'ambiguous') {
    return (
      <View style={card}>
        <Details
          details={offer.details}
          unanswerable="ambiguous"
        />
        <Status
          icon="exclamationmark.triangle.fill"
          tone="statusWarning"
          title={t('invitation.ambiguous')}
          detail={t('invitation.ambiguousDetail', {
            name: organizerName(offer.details),
          })}
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
    <Invited
      inbox={inbox}
      invitation={offer}
      connection={connection}
      current={current}
    />
  );
}

// An invitation the opened mailbox's address can answer.
function Invited({
  inbox,
  invitation,
  connection,
  current,
}: {
  readonly inbox: InvitationInbox;
  readonly invitation: Invitation;
  readonly connection: string | undefined;
  readonly current: () => boolean;
}) {
  const colors = usePalette();
  const { t } = useLocalization();
  const provider = useProviderName();
  // Invited at other addresses of the Profile too, each address is listed instead of You.
  const others = alsoInvited(invitation, useMailboxes());
  const responses = invitationResponses(inbox);
  const earlier = useSyncExternalStore(responses.subscribe, () =>
    responses.earlier(invitation),
  );
  const older = useSyncExternalStore(
    responses.subscribe,
    () => responses.state(invitation).kind === 'older',
  );
  const yours = t('invitation.yourAddress', {
    address: invitation.address,
    provider,
  });
  return (
    <View style={[styles.card, { backgroundColor: colors.fillQuiet }]}>
      <Details
        details={invitation.details}
        earlier={earlier}
        older={older}
        invited={
          others.length === 0
            ? [t('invitation.you'), yours]
            : [
                yours,
                ...others.map(({ address: other, provider: kind }) =>
                  t('invitation.yourAddress', {
                    address: other,
                    provider: t(`mailProviders.${kind ?? 'gmail'}`),
                  }),
                ),
              ]
        }
      />
      <Responding
        inbox={inbox}
        invitation={invitation}
        others={others.length}
        earlier={earlier}
        connection={connection}
        current={current}
      />
    </View>
  );
}
