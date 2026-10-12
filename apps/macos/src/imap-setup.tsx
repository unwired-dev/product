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
import { spacing } from '@private-email/mail-core/theme';
import { Fragment, useState, useSyncExternalStore } from 'react';
import { Pressable, StyleSheet, Text, TextInput, View } from 'react-native';

import { Label } from './label.tsx';
import { useLocalization } from './localization.ts';
import { registrationStyles as styles } from './registration-styles.ts';
import { usePalette } from './theme.ts';

const providers = ['icloud', 'fastmail', 'other'] as const;
const securities = ['tls', 'starttls'] as const;

const choiceStyles = StyleSheet.create({
  choices: { flexDirection: 'row', flexWrap: 'wrap', gap: spacing.small },
  choice: {
    minHeight: 44,
    justifyContent: 'center',
    paddingHorizontal: spacing.medium,
    borderWidth: 1,
    borderRadius: 10,
    borderCurve: 'continuous',
  },
  label: { fontSize: 15 },
});

// The form's text fields; SMTP security is chosen separately.
type TextField = Exclude<keyof ImapFields, 'smtpSecurity'>;

type Button = (label: string, action: () => Promise<void>) => ReactNode;

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
      {providers.map((choice) => (
        <Fragment key={choice}>
          {button(
            t('imap.choose', { provider: t(`imap.providers.${choice}`) }),
            async () => {
              setProvider(choice);
            },
          )}
        </Fragment>
      ))}
      {onClose === undefined
        ? null
        : button(t('imap.cancel'), async () => {
            onClose();
          })}
    </>
  );
}

// The chosen provider's fields, its reviewed endpoint and the outcome of the latest attempt.
function ImapForm({
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
  const field = (
    name: TextField,
    label: string,
    options: Partial<ComponentProps<typeof TextInput>> = {},
  ) => (
    <TextInput
      accessibilityLabel={label}
      autoCapitalize="none"
      autoCorrect={false}
      onChangeText={(value) => {
        setFields((current) => ({ ...current, [name]: value }));
      }}
      placeholder={label}
      placeholderTextColor={colors.secondary}
      style={[
        styles.input,
        { borderColor: colors.separator, color: colors.foreground },
      ]}
      value={fields[name]}
      {...options}
    />
  );
  // A repair keeps its saved endpoint, but names its provider and the password it needs.
  const guidance =
    repair?.imap === undefined ? provider : imapPresetOf(repair.imap);
  const setup = imapSetup(provider, fields);
  // Passwords leave this form once they are handed to native storage, or the form is left.
  const forgetPassword = () => {
    setFields((current) => ({ ...current, password: '', smtpPassword: '' }));
  };
  return (
    <View style={styles.device}>
      <Label
        accessibilityRole="header"
        style={[styles.heading, { color: colors.foreground }]}>
        {t(`imap.providers.${guidance}`)}
      </Label>
      <Label style={[styles.text, { color: colors.secondary }]}>
        {t('imap.description')}
      </Label>
      {repair === undefined
        ? field('address', t('imap.address'), {
            autoComplete: 'email',
            keyboardType: 'email-address',
            textContentType: 'emailAddress',
          })
        : null}
      {provider === 'other' && repair === undefined ? (
        <ManualEndpoint field={field} />
      ) : null}
      {field('password', t('imap.password'), {
        autoComplete: 'password',
        secureTextEntry: true,
        textContentType: 'password',
      })}
      {guidance === 'other' ? (
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
      {setup === undefined
        ? null
        : button(t('imap.connect'), async () => {
            forgetPassword();
            await store.connectImap(setup);
            if (store.getSnapshot().imapFailure === undefined) {
              onConnected?.();
            }
          })}
      {button(t('imap.cancel'), async () => {
        forgetPassword();
        onCancel();
      })}
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
        <Label style={[styles.text, { color: colors.secondary }]}>
          {t('imap.appPassword', {
            provider: t(`imap.providers.${provider}`),
          })}
        </Label>
      )}
      <Label style={[styles.text, { color: colors.secondary }]}>
        {review === undefined
          ? t('imap.incomplete')
          : t('imap.review', { host: review.host, port: String(review.port) })}
      </Label>
      {review === undefined ? null : (
        <Label style={[styles.text, { color: colors.secondary }]}>
          {t(`imap.sendingReview.${review.smtp.security}`, {
            host: review.smtp.host,
            port: String(review.smtp.port),
          })}
        </Label>
      )}
      {failure === undefined ? null : (
        <Label
          accessibilityRole="alert"
          style={[styles.text, { color: colors.foreground }]}>
          {t(`imap.failure.${failure}`)}
        </Label>
      )}
    </>
  );
}

// A manual server's user name and endpoint, which the person reviews before connecting.
function ManualEndpoint({
  field,
}: {
  readonly field: (
    name: TextField,
    label: string,
    options?: Partial<ComponentProps<typeof TextInput>>,
  ) => ReactNode;
}) {
  const { t } = useLocalization();
  return (
    <>
      {field('username', t('imap.username'), {
        autoComplete: 'username',
        textContentType: 'username',
      })}
      {field('host', t('imap.host'), { keyboardType: 'url' })}
      {field('port', t('imap.port'), { keyboardType: 'number-pad' })}
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
  readonly field: (
    name: TextField,
    label: string,
    options?: Partial<ComponentProps<typeof TextInput>>,
  ) => ReactNode;
  readonly security: SmtpSecurity;
  readonly onSecurity: (security: SmtpSecurity) => void;
}) {
  const colors = usePalette();
  const { t } = useLocalization();
  return (
    <>
      <Label
        accessibilityRole="header"
        style={[styles.text, { color: colors.secondary }]}>
        {t('imap.outgoing')}
      </Label>
      {field('smtpHost', t('imap.smtpHost'), { keyboardType: 'url' })}
      {field('smtpPort', t('imap.smtpPort'), { keyboardType: 'number-pad' })}
      <View
        accessibilityRole="radiogroup"
        style={choiceStyles.choices}>
        {securities.map((choice) => (
          <Pressable
            key={choice}
            accessibilityLabel={`${t('imap.smtpSecurity')}: ${t(`imap.security.${choice}`)}`}
            accessibilityRole="radio"
            accessibilityState={{ checked: choice === security }}
            onPress={() => {
              onSecurity(choice);
            }}
            style={[
              choiceStyles.choice,
              {
                borderColor:
                  choice === security ? colors.accent : colors.separator,
              },
            ]}>
            <Text
              style={[
                choiceStyles.label,
                {
                  color:
                    choice === security ? colors.accent : colors.foreground,
                },
              ]}>
              {t(`imap.security.${choice}`)}
            </Text>
          </Pressable>
        ))}
      </View>
      {field('smtpUsername', t('imap.smtpUsername'), {
        autoComplete: 'username',
        textContentType: 'username',
      })}
      {field('smtpPassword', t('imap.smtpPassword'), {
        autoComplete: 'password',
        secureTextEntry: true,
        textContentType: 'password',
      })}
    </>
  );
}
