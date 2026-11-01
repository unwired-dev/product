import type { Translate } from '@private-email/localization';
import type { GmailInbox } from '@private-email/mail-core/gmail-inbox';
import type {
  Invitation,
  InvitationChoice,
  InvitationDetails,
  InvitationTime,
  ResponseState,
} from '@private-email/mail-core/invitations';
import type { ReactNode } from 'react';

import {
  invitationOf,
  invitationResponses,
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
  title: { ...textStyles.title3Emphasized },
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
  'send' | 'findSent' | 'getSnapshot' | 'subscribe' | 'responseSource'
>;

const choices = ['accepted', 'tentative', 'declined'] as const;
const day = 24 * 60 * 60 * 1000;

const choiceKeys = {
  accepted: 'accept',
  tentative: 'maybe',
  declined: 'decline',
} as const;

const nameOf = ({ organizer }: InvitationDetails) =>
  organizer.name ?? organizer.address;

// When the meeting happens in this Mac's time zone: a day, or a day with its start and end.
function useWhen(details: InvitationDetails) {
  const { t, settings } = useLocalization();
  const formats = useMemo(
    () => ({
      day: new Intl.DateTimeFormat(settings.locale, {
        weekday: 'short',
        day: 'numeric',
        month: 'short',
        year: 'numeric',
      }),
      allDay: new Intl.DateTimeFormat(settings.locale, {
        weekday: 'short',
        day: 'numeric',
        month: 'short',
        year: 'numeric',
        timeZone: 'UTC',
      }),
      time: new Intl.DateTimeFormat(settings.locale, {
        hour: 'numeric',
        minute: '2-digit',
      }),
    }),
    [settings.locale],
  );
  const { start, end } = details;
  if (start.allDay) {
    // An all-day end is exclusive: the meeting's last day is the one before it.
    const last = end?.allDay === true ? end.at - day : start.at;
    return t('invitation.allDay', {
      date:
        last > start.at
          ? t('invitation.dateRange', {
              start: formats.allDay.format(start.at),
              end: formats.allDay.format(last),
            })
          : formats.allDay.format(start.at),
    });
  }
  const at = (time: InvitationTime) =>
    t('invitation.dateTime', {
      date: formats.day.format(time.at),
      time: formats.time.format(time.at),
    });
  if (end === undefined) {
    return at(start);
  }
  return formats.day.format(start.at) === formats.day.format(end.at)
    ? t('invitation.timeRange', {
        date: formats.day.format(start.at),
        start: formats.time.format(start.at),
        end: formats.time.format(end.at),
      })
    : t('invitation.dateRange', {
        start: at(start),
        end: at(end.allDay ? start : end),
      });
}

function DetailRow({
  label,
  children,
}: {
  readonly label: string;
  readonly children: ReactNode;
}) {
  const colors = usePalette();
  return (
    <View style={styles.row}>
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
  readonly invited: ReactNode;
}) {
  const colors = usePalette();
  const { t } = useLocalization();
  const when = useWhen(details);
  return (
    <>
      <View style={styles.heading}>
        <SFSymbol
          name="calendar"
          color={colors.accentInk}
        />
        <Text style={[styles.smallEmphasized, { color: colors.textSecondary }]}>
          {t('invitation.from', { name: nameOf(details) })}
        </Text>
      </View>
      <Text
        accessibilityRole="header"
        style={[styles.title, { color: colors.textPrimary }]}>
        {details.summary ?? t('invitation.untitled')}
      </Text>
      <View style={styles.details}>
        <DetailRow label={t('invitation.when')}>
          <Text style={[styles.text, { color: colors.textPrimary }]}>
            {when}
          </Text>
        </DetailRow>
        {details.location === undefined ? null : (
          <DetailRow label={t('invitation.where')}>
            <Text style={[styles.text, { color: colors.textPrimary }]}>
              {details.location}
            </Text>
          </DetailRow>
        )}
        <DetailRow label={t('invitation.organizer')}>
          <Text style={[styles.text, { color: colors.textPrimary }]}>
            {nameOf(details)}
          </Text>
          {details.organizer.name === undefined ? null : (
            <Text style={[styles.text, { color: colors.textSecondary }]}>
              {details.organizer.address}
            </Text>
          )}
        </DetailRow>
        <DetailRow label={t('invitation.invited')}>{invited}</DetailRow>
      </View>
    </>
  );
}

// The response status row: an icon or a spinner, what happened, and what the person can do next.
function Status({
  icon,
  iconColor,
  busy = false,
  title,
  detail,
  children,
}: {
  readonly icon?: string;
  readonly iconColor?: string;
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
            color={iconColor ?? colors.textSecondary}
          />
        )}
        <View style={styles.statusText}>
          <Text
            accessibilityLiveRegion="polite"
            style={[styles.emphasized, { color: colors.textPrimary }]}>
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

type Shown = Readonly<{
  icon?: string;
  iconColor?: string;
  busy?: boolean;
  title: string;
  detail: string;
}>;

type Describing = Readonly<{
  t: Translate;
  name: string;
  address: string;
  provider: string;
  colors: ReturnType<typeof usePalette>;
  time: Intl.DateTimeFormat;
}>;

type Kind = ResponseState['kind'];

const choiceOf = (t: Translate, state: ResponseState) =>
  'choice' in state ? t(`invitation.${choiceKeys[state.choice]}`) : '';

// How the card describes each response state.
const describe: {
  readonly [K in Kind]: (
    state: ResponseState & { kind: K },
    context: Describing,
  ) => Shown;
} = {
  unanswered: (_, { t, name, address }) => ({
    title: t('invitation.unanswered'),
    detail: t('invitation.unansweredDetail', { name, address }),
  }),
  sending: (state, { t, address }) => ({
    busy: true,
    title: t('invitation.sending'),
    detail: t('invitation.sendingDetail', {
      choice: choiceOf(t, state),
      address,
    }),
  }),
  sent: (state, { t, name, provider, colors, time }) => ({
    icon: 'checkmark.circle.fill',
    iconColor: colors.accentInk,
    title: t(`invitation.${state.choice}`),
    detail: t('invitation.sentDetail', {
      provider,
      name,
      time: time.format(state.at),
    }),
  }),
  refused: (state, { t, name, provider, colors }) => ({
    icon: 'exclamationmark.triangle.fill',
    iconColor: colors.statusDestructive,
    title: t('invitation.refused'),
    detail: t('invitation.refusedDetail', {
      provider,
      choice: choiceOf(t, state),
      name,
    }),
  }),
  unknown: (state, { t, provider, colors }) => ({
    icon: 'exclamationmark.triangle.fill',
    iconColor: colors.statusWarning,
    title: t('invitation.unknown'),
    detail: t('invitation.unknownDetail', {
      provider,
      choice: choiceOf(t, state),
    }),
  }),
  checking: (state, { t, provider }) => ({
    busy: true,
    title: t('invitation.checking', { provider }),
    detail: t('invitation.checkingDetail', { choice: choiceOf(t, state) }),
  }),
  offline: (_, { t }) => ({
    icon: 'wifi.slash',
    title: t('invitation.offline'),
    detail: t('invitation.offlineDetail'),
  }),
  authentication: (_, { t, address, provider, colors }) => ({
    icon: 'exclamationmark.triangle.fill',
    iconColor: colors.statusWarning,
    title: t('invitation.authentication', { provider }),
    detail: t('invitation.authenticationDetail', { address }),
  }),
};

const described = <K extends Kind>(
  state: ResponseState & { kind: K },
  context: Describing,
) => describe[state.kind](state, context);

// An offline Mac or a refused sign-in, which the mailbox's sync names before anything is sent.
const blockedBy = (sync: string | undefined) => {
  if (sync === 'retry') {
    return 'offline';
  }
  return sync === 'authentication' ? 'authentication' : undefined;
};

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
  const colors = usePalette();
  const { t, settings } = useLocalization();
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
  const time = useMemo(
    () =>
      new Intl.DateTimeFormat(settings.locale, {
        hour: 'numeric',
        minute: '2-digit',
      }),
    [settings.locale],
  );
  const name = nameOf(invitation.details);
  const blocked =
    recorded.kind === 'unanswered' ||
    recorded.kind === 'sent' ||
    recorded.kind === 'refused'
      ? blockedBy(sync)
      : undefined;
  const shown = described(
    blocked === undefined ? recorded : { kind: blocked, choice: 'accepted' },
    { t, name, address: invitation.address, provider, colors, time },
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
        choice: t(`invitation.${choiceKeys[choice]}`),
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
    if (current()) {
      await authorizeMailbox(mailbox);
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
                  choice: t(`invitation.${choiceKeys[choice]}`),
                })
              : t(`invitation.${choiceKeys[choice]}`)
          }
          accessibilityLabel={
            chosen === choice
              ? t(`invitation.${choice}`)
              : t(`invitation.${choiceKeys[choice]}`)
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
        <Text style={[styles.smallEmphasized, { color: colors.textSecondary }]}>
          {t('invitation.heading')}
        </Text>
        <Status
          icon="exclamationmark.triangle.fill"
          iconColor={colors.statusWarning}
          title={t('invitation.unreadable')}
          detail={t('invitation.unreadableDetail')}
        />
      </View>
    );
  }
  if (offer.kind === 'elsewhere') {
    return (
      <View style={card}>
        <Details
          details={offer.details}
          invited={
            <>
              <Text style={[styles.text, { color: colors.textPrimary }]}>
                {offer.invited.join(', ')}
              </Text>
              <Text style={[styles.text, { color: colors.textSecondary }]}>
                {t('invitation.notYours')}
              </Text>
            </>
          }
        />
        <Status
          icon="person.crop.circle.badge.exclamationmark"
          title={t('invitation.elsewhere')}
          detail={t('invitation.elsewhereDetail', {
            name: nameOf(offer.details),
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
        invited={
          <>
            <Text style={[styles.text, { color: colors.textPrimary }]}>
              {t('invitation.you')}
            </Text>
            <Text style={[styles.text, { color: colors.textSecondary }]}>
              {t('invitation.yourAddress', {
                address: offer.address,
                provider,
              })}
            </Text>
          </>
        }
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
