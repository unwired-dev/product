import type { GmailInbox } from '@private-email/mail-core/gmail-inbox';
import type {
  Invitation,
  InvitationChoice,
  InvitationDetails,
  InvitationStatus,
} from '@private-email/mail-core/invitations';
import type { ReactNode } from 'react';

import {
  invitationOf,
  invitationResponses,
  createInvitationFormats,
  invitationBlockedBy,
  invitationChoiceKeys,
  invitationStatus,
  invitationWhen,
  organizerName,
} from '@private-email/mail-core/invitations';
import { radius, spacing } from '@private-email/mail-core/theme';
import {
  use,
  useLayoutEffect,
  useMemo,
  useRef,
  useSyncExternalStore,
} from 'react';
import { ActivityIndicator, StyleSheet, Text, View } from 'react-native';

import { askInSheet, Button, SFSymbol } from './design.tsx';
import { useLocalization } from './localization.ts';
import { useProviderName } from './mailbox.tsx';
import { AccountContext } from './registration-gate.tsx';
import { textStyles, usePalette } from './theme.ts';

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
    borderRadius: radius.control,
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
}: {
  readonly details: InvitationDetails;
  // Who was invited, then a secondary line about them; a cancelled meeting has no row.
  readonly invited?: readonly [string, string];
}) {
  const colors = usePalette();
  const { t } = useLocalization();
  const formats = useFormats();
  const when = invitationWhen(t, formats, details);
  const cancelled = invited === undefined;
  const from = t(cancelled ? 'invitation.cancelledBy' : 'invitation.from', {
    name: organizerName(details),
  });
  const title = details.summary ?? t('invitation.untitled');
  const organizer = [
    ...new Set([organizerName(details), details.organizer.address]),
  ];
  return (
    <>
      <View
        accessible
        accessibilityLabel={from}
        style={styles.heading}>
        <SFSymbol
          name={cancelled ? 'xmark' : 'calendar'}
          color={colors.accentInk}
        />
        <Text
          style={[
            styles.smallEmphasized,
            styles.headingText,
            { color: colors.textSecondary },
          ]}>
          {from}
        </Text>
        {cancelled ? (
          <View
            style={[
              styles.badge,
              { backgroundColor: colors.accentSelectionSubtle },
            ]}>
            <Text style={[styles.smallEmphasized, { color: colors.accentInk }]}>
              {t('invitation.cancelled')}
            </Text>
          </View>
        ) : null}
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
          spoken={[when]}>
          <Text style={[styles.text, { color: colors.textPrimary }]}>
            {when}
          </Text>
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
  connection,
  current,
}: {
  readonly inbox: InvitationInbox;
  readonly invitation: Invitation;
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
    { t, name, address: invitation.address, provider, time },
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
      />
      <Responding
        inbox={inbox}
        invitation={offer}
        connection={connection}
        current={current}
      />
    </View>
  );
}
