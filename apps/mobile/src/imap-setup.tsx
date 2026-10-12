import type {
  ImapFields,
  ImapProvider,
} from '@private-email/mail-core/imap-setup';
import type {
  ImapFailure,
  MailboxConnection,
  Registration,
} from '@private-email/mail-core/registration';
import type { ComponentProps, ReactNode } from 'react';

import { imapPresetOf, imapSetup } from '@private-email/mail-core/imap-setup';
import { Fragment, useState, useSyncExternalStore } from 'react';
import { Text, TextInput, View } from 'react-native';

import { useLocalization } from './localization.ts';
import { registrationStyles as styles } from './registration-styles.ts';
import { usePalette } from './theme.ts';

const providers = ['icloud', 'fastmail', 'other'] as const;

type Button = (label: string, action: () => Promise<void>) => ReactNode;

// A Standards-Based Mailbox Connection's setup: the provider, the reviewed endpoint and the
// password, which goes no further than this device. `repair` enters the password of an existing
// connection again, at its reviewed endpoint.
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
  const [fields, setFields] = useState<ImapFields>({
    address: repair?.address ?? '',
    password: '',
    host: repair?.imap?.host ?? '',
    port: String(repair?.imap?.port ?? 993),
    username: repair?.imap?.username ?? '',
  });
  const field = (
    name: keyof ImapFields,
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
  // The password leaves this form once it is handed to native storage, or the form is left.
  const forgetPassword = () => {
    setFields((current) => ({ ...current, password: '' }));
  };
  return (
    <View style={styles.device}>
      <Text
        accessibilityRole="header"
        style={[styles.heading, { color: colors.foreground }]}>
        {t(`imap.providers.${guidance}`)}
      </Text>
      <Text style={[styles.text, { color: colors.secondary }]}>
        {t('imap.description')}
      </Text>
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
  // The endpoint a complete form connects to.
  readonly review: Readonly<{ host: string; port: number }> | undefined;
  readonly failure: ImapFailure | undefined;
}) {
  const colors = usePalette();
  const { t } = useLocalization();
  return (
    <>
      {provider === 'other' ? null : (
        <Text style={[styles.text, { color: colors.secondary }]}>
          {t('imap.appPassword', {
            provider: t(`imap.providers.${provider}`),
          })}
        </Text>
      )}
      <Text style={[styles.text, { color: colors.secondary }]}>
        {review === undefined
          ? t('imap.incomplete')
          : t('imap.review', { host: review.host, port: String(review.port) })}
      </Text>
      {failure === undefined ? null : (
        <Text
          accessibilityRole="alert"
          style={[styles.text, { color: colors.foreground }]}>
          {t(`imap.failure.${failure}`)}
        </Text>
      )}
    </>
  );
}

// A manual server's user name and endpoint, which the person reviews before connecting.
function ManualEndpoint({
  field,
}: {
  readonly field: (
    name: keyof ImapFields,
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
