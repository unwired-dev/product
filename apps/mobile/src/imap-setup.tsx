import type {
  ImapFields,
  ImapProvider,
  SmtpSecurity,
} from '@private-email/mail-core/imap-setup';
import type {
  ImapFailure,
  MailboxConnection,
  Registration,
} from '@private-email/mail-core/registration';
import type { ComponentProps, ReactNode } from 'react';

import {
  imapFields,
  imapPresetOf,
  imapSetup,
  smtpSecurityOf,
} from '@private-email/mail-core/imap-setup';
import { radius, spacing } from '@private-email/mail-core/theme';
import { useState, useSyncExternalStore } from 'react';
import { Pressable, StyleSheet, Text, TextInput, View } from 'react-native';

import { useLocalization } from './localization.ts';
import { ProviderList, ProviderRow } from './onboarding.tsx';
import { registrationStyles as styles } from './registration-styles.ts';
import { textStyles, usePalette } from './theme.ts';

const providers = [
  { provider: 'icloud', letter: 'i' },
  { provider: 'fastmail', letter: 'F' },
  { provider: 'other', letter: '@' },
] as const;
const securities = ['tls', 'starttls'] as const;

const formStyles = StyleSheet.create({
  group: {
    overflow: 'hidden',
    borderRadius: radius.insetGroup,
    borderCurve: 'continuous',
  },
  groupTitle: { ...textStyles.footnote, paddingHorizontal: spacing.l },
  row: {
    minHeight: 44,
    flexDirection: 'row',
    alignItems: 'center',
    gap: spacing.m,
    paddingHorizontal: spacing.l,
  },
  label: { ...textStyles.body, width: 104 },
  input: { ...textStyles.body, flex: 1, minHeight: 44 },
  choices: { flex: 1, flexDirection: 'row', flexWrap: 'wrap', gap: spacing.s },
  choice: {
    minHeight: 32,
    justifyContent: 'center',
    paddingHorizontal: spacing.m,
    borderRadius: radius.chip,
    borderCurve: 'continuous',
  },
  choiceLabel: { ...textStyles.subheadline },
  actions: { flexDirection: 'row', justifyContent: 'flex-end', gap: spacing.s },
  notes: { ...textStyles.footnote },
});

// The form's text fields; SMTP security is chosen separately.
type TextField = Exclude<keyof ImapFields, 'smtpSecurity'>;

type Button = (
  label: string,
  action: () => Promise<void>,
  fill?: 'accent',
) => ReactNode;

// A text field's row: its short visible label and the field, whose accessibility label names it
// in full.
type FieldRow = Readonly<{
  name: TextField;
  label: string;
  // The row's visible label, when shorter than the accessibility label.
  visible?: string;
  input?: Partial<ComponentProps<typeof TextInput>>;
  last?: boolean;
}>;
type Field = (row: FieldRow) => ReactNode;

// A Standards-Based Mailbox Connection's setup: the provider, the reviewed IMAP and SMTP endpoints
// and the password, which goes no further than this device. `repair` enters the password of an
// existing connection again, at its reviewed endpoint, which also sets up sending for a connection
// saved before SMTP.
export function ImapSetup({
  store,
  button,
  repair,
  onClose,
}: {
  readonly store: Registration;
  readonly button: Button;
  readonly repair?: MailboxConnection | undefined;
  // Present where the form can be dismissed without choosing a provider.
  readonly onClose?: (() => void) | undefined;
}) {
  const { t } = useLocalization();
  const [provider, setProvider] = useState<ImapProvider | undefined>(
    repair === undefined ? undefined : 'other',
  );
  if (provider !== undefined) {
    return (
      <ImapForm
        button={button}
        onCancel={() => {
          if (repair === undefined) {
            setProvider(undefined);
          } else {
            onClose?.();
          }
        }}
        onConnected={onClose}
        provider={provider}
        repair={repair}
        store={store}
      />
    );
  }
  return (
    <>
      <ProviderList>
        {providers.map((choice, index) => (
          <ProviderRow
            key={choice.provider}
            detail={t(`onboarding.providers.${choice.provider}.detail`)}
            disabled={false}
            last={index === providers.length - 1}
            letter={choice.letter}
            name={t(`onboarding.providers.${choice.provider}.name`)}
            onPress={() => {
              setProvider(choice.provider);
            }}
          />
        ))}
      </ProviderList>
      {onClose === undefined
        ? null
        : button(t('imap.cancel'), async () => {
            onClose();
          })}
    </>
  );
}

// An inset group of form rows under an optional title.
function FormGroup({
  title,
  children,
}: {
  readonly title?: string;
  readonly children: ReactNode;
}) {
  const colors = usePalette();
  return (
    <>
      {title === undefined ? null : (
        <Text
          accessibilityRole="header"
          style={[formStyles.groupTitle, { color: colors.textSecondary }]}>
          {title}
        </Text>
      )}
      <View style={[formStyles.group, { backgroundColor: colors.fillQuiet }]}>
        {children}
      </View>
    </>
  );
}

// The chosen provider's fields, its reviewed endpoint and the outcome of the latest attempt.
export function ImapForm({
  store,
  button,
  provider,
  repair,
  onCancel,
  onConnected,
}: {
  readonly store: Registration;
  readonly button: Button;
  readonly provider: ImapProvider;
  readonly repair: MailboxConnection | undefined;
  readonly onCancel: () => void;
  readonly onConnected: (() => void) | undefined;
}) {
  const colors = usePalette();
  const { t } = useLocalization();
  const { imapFailure } = useSyncExternalStore(
    store.subscribe,
    store.getSnapshot,
  );
  const [fields, setFields] = useState<ImapFields>(() => imapFields(repair));
  const field: Field = ({
    name,
    label,
    visible = label,
    input = {},
    last = false,
  }) => (
    <View
      style={[
        formStyles.row,
        {
          borderBottomWidth: last ? 0 : StyleSheet.hairlineWidth,
          borderBottomColor: colors.separator,
        },
      ]}>
      <Text
        importantForAccessibility="no"
        accessibilityElementsHidden
        style={[formStyles.label, { color: colors.textPrimary }]}>
        {visible}
      </Text>
      <TextInput
        accessibilityLabel={label}
        autoCapitalize="none"
        autoCorrect={false}
        onChangeText={(value) => {
          setFields((current) => ({ ...current, [name]: value }));
        }}
        placeholder={label}
        placeholderTextColor={colors.textSecondary}
        style={[formStyles.input, { color: colors.textPrimary }]}
        value={fields[name]}
        {...input}
      />
    </View>
  );
  // A repair keeps its saved endpoint, but names its provider and the password it needs.
  const guidance =
    repair?.imap === undefined ? provider : imapPresetOf(repair.imap);
  const setup = imapSetup(provider, fields);
  // Passwords leave this form once they are handed to native storage, or the form is left.
  const forgetPassword = () => {
    setFields((current) => ({ ...current, password: '', smtpPassword: '' }));
  };
  const manual = provider === 'other' && repair === undefined;
  return (
    <View style={styles.device}>
      <Text
        accessibilityRole="header"
        style={[styles.heading, { color: colors.textPrimary }]}>
        {t(`imap.providers.${guidance}`)}
      </Text>
      <Text style={[styles.text, { color: colors.textSecondary }]}>
        {t('imap.description')}
      </Text>
      <FormGroup>
        {repair === undefined
          ? field({
              name: 'address',
              label: t('imap.address'),
              input: {
                autoComplete: 'email',
                keyboardType: 'email-address',
                textContentType: 'emailAddress',
              },
            })
          : null}
        {field({
          name: 'password',
          label: t('imap.password'),
          input: {
            autoComplete: 'password',
            secureTextEntry: true,
            textContentType: 'password',
          },
          last: true,
        })}
      </FormGroup>
      {manual ? (
        <FormGroup title={t('imap.incoming')}>
          {field({
            name: 'username',
            label: t('imap.username'),
            input: {
              autoComplete: 'username',
              textContentType: 'username',
            },
          })}
          {field({
            name: 'host',
            label: t('imap.host'),
            visible: t('imap.server'),
            input: {
              keyboardType: 'url',
            },
          })}
          {field({
            name: 'port',
            label: t('imap.port'),
            input: { keyboardType: 'number-pad' },
            last: true,
          })}
        </FormGroup>
      ) : null}
      {guidance === 'other' || repair?.smtp !== undefined ? (
        <ManualSending
          field={field}
          security={smtpSecurityOf(fields)}
          onSecurity={(security) => {
            setFields((current) => ({ ...current, smtpSecurity: security }));
          }}
        />
      ) : null}
      <FormNotes
        provider={guidance}
        review={setup}
        failure={imapFailure}
      />
      <View style={formStyles.actions}>
        {button(t('imap.cancel'), async () => {
          forgetPassword();
          onCancel();
        })}
        {setup === undefined
          ? null
          : button(
              t('imap.connect'),
              async () => {
                forgetPassword();
                await store.connectImap(setup);
                if (store.getSnapshot().imapFailure === undefined) {
                  onConnected?.();
                }
              },
              'accent',
            )}
      </View>
    </View>
  );
}

// What connecting needs and does, and why the latest attempt failed.
function FormNotes({
  provider,
  review,
  failure,
}: {
  readonly provider: ImapProvider;
  // The endpoints a complete form connects to.
  readonly review:
    | Readonly<{
        host: string;
        port: number;
        smtp: Readonly<{ host: string; port: number; security: SmtpSecurity }>;
      }>
    | undefined;
  readonly failure: ImapFailure | undefined;
}) {
  const colors = usePalette();
  const { t } = useLocalization();
  return (
    <>
      {provider === 'other' ? null : (
        <Text style={[formStyles.notes, { color: colors.textSecondary }]}>
          {t('imap.appPassword', {
            provider: t(`imap.providers.${provider}`),
          })}
        </Text>
      )}
      <Text style={[formStyles.notes, { color: colors.textSecondary }]}>
        {review === undefined
          ? t('imap.incomplete')
          : t('imap.review', { host: review.host, port: String(review.port) })}
      </Text>
      {review === undefined ? null : (
        <Text style={[formStyles.notes, { color: colors.textSecondary }]}>
          {t(`imap.sendingReview.${review.smtp.security}`, {
            host: review.smtp.host,
            port: String(review.smtp.port),
          })}
        </Text>
      )}
      {failure === undefined ? null : (
        <Text
          accessibilityRole="alert"
          style={[styles.text, { color: colors.textPrimary }]}>
          {t(`imap.failure.${failure}`)}
        </Text>
      )}
    </>
  );
}

// A manual server's SMTP endpoint and how it reaches TLS; its user name and password default to
// the incoming ones.
function ManualSending({
  field,
  security,
  onSecurity,
}: {
  readonly field: Field;
  readonly security: SmtpSecurity;
  readonly onSecurity: (security: SmtpSecurity) => void;
}) {
  const colors = usePalette();
  const { t } = useLocalization();
  return (
    <FormGroup title={t('imap.outgoing')}>
      {field({
        name: 'smtpHost',
        label: t('imap.smtpHost'),
        visible: t('imap.server'),
        input: {
          keyboardType: 'url',
        },
      })}
      {field({
        name: 'smtpPort',
        label: t('imap.smtpPort'),
        visible: t('imap.port'),
        input: {
          keyboardType: 'number-pad',
        },
      })}
      <View
        style={[
          formStyles.row,
          {
            borderBottomWidth: StyleSheet.hairlineWidth,
            borderBottomColor: colors.separator,
          },
        ]}>
        <Text
          importantForAccessibility="no"
          accessibilityElementsHidden
          style={[formStyles.label, { color: colors.textPrimary }]}>
          {t('imap.securityLabel')}
        </Text>
        <View
          accessibilityRole="radiogroup"
          style={formStyles.choices}>
          {securities.map((choice) => {
            const selected = choice === security;
            return (
              <Pressable
                key={choice}
                accessibilityLabel={`${t('imap.smtpSecurity')}: ${t(`imap.security.${choice}`)}`}
                accessibilityRole="radio"
                accessibilityState={{ checked: selected }}
                onPress={() => {
                  onSecurity(choice);
                }}
                style={[
                  formStyles.choice,
                  {
                    backgroundColor: selected
                      ? colors.accentFill
                      : colors.fillQuiet,
                  },
                ]}>
                <Text
                  style={[
                    formStyles.choiceLabel,
                    {
                      color: selected
                        ? colors.accentOnFill
                        : colors.textPrimary,
                      fontWeight: selected ? '600' : '400',
                    },
                  ]}>
                  {t(`imap.security.${choice}`)}
                </Text>
              </Pressable>
            );
          })}
        </View>
      </View>
      {field({
        name: 'smtpUsername',
        label: t('imap.smtpUsername'),
        visible: t('imap.username'),
        input: {
          autoComplete: 'username',
          placeholder: t('imap.sameAsIncoming'),
          textContentType: 'username',
        },
      })}
      {field({
        name: 'smtpPassword',
        label: t('imap.smtpPassword'),
        visible: t('imap.password'),
        input: {
          autoComplete: 'password',
          placeholder: t('imap.sameAsIncoming'),
          secureTextEntry: true,
          textContentType: 'password',
        },
        last: true,
      })}
    </FormGroup>
  );
}
