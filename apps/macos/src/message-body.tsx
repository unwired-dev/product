import type {
  GmailInbox,
  ReceivedAttachment,
} from '@private-email/mail-core/gmail-inbox';
import type {
  BodyLink,
  MessagePresentation,
  ReadableBody,
} from '@private-email/mail-core/message-body';
import type { ReactNode } from 'react';
import type { LayoutChangeEvent } from 'react-native';
import type {
  ShouldStartLoadRequest,
  WebViewEvent,
} from 'react-native-webview/lib/WebViewTypes';

import {
  attachmentCopy,
  messageBodyCopy,
} from '@private-email/mail-core/gmail-inbox';
import {
  inspectLink,
  messageLinkAt,
} from '@private-email/mail-core/link-inspection';
import { decodeMessageContentHeight } from '@private-email/mail-core/message-body';
import { spacing } from '@private-email/mail-core/theme';
import {
  createContext,
  Fragment,
  use,
  useEffect,
  useLayoutEffect,
  useRef,
  useState,
  useSyncExternalStore,
} from 'react';
import {
  ActivityIndicator,
  Clipboard,
  Linking,
  Pressable,
  StyleSheet,
  Text,
  View,
} from 'react-native';
import { WebView } from 'react-native-webview';

import { usePalette } from './theme.ts';

// A taller document scrolls inside its view instead of the reader.
const heightCap = 20_000;

const styles = StyleSheet.create({
  body: { gap: spacing.medium, marginTop: spacing.large },
  paragraph: { fontSize: 17, lineHeight: 28 },
  secondary: { fontSize: 14, lineHeight: 21 },
  confirm: {
    gap: spacing.small,
    padding: spacing.medium,
    borderRadius: 8,
    borderWidth: StyleSheet.hairlineWidth,
  },
  actions: { flexDirection: 'row', flexWrap: 'wrap', gap: spacing.large },
  attachments: {
    gap: spacing.small,
    paddingTop: spacing.medium,
    borderTopWidth: StyleSheet.hairlineWidth,
  },
  attachment: { gap: 2 },
  attachmentName: { fontSize: 15, fontWeight: '600' },
  link: { textDecorationLine: 'underline' },
  linkControl: {
    borderWidth: 2,
    borderRadius: 4,
    minHeight: 44,
    justifyContent: 'center',
    paddingHorizontal: spacing.small,
  },
  rich: { width: '100%', backgroundColor: '#FFFFFF' },
  hidden: { opacity: 0 },
  fill: { flex: 1 },
  bar: {
    paddingHorizontal: spacing.large,
    paddingVertical: spacing.medium,
    borderTopWidth: StyleSheet.hairlineWidth,
  },
});

// A link awaiting confirmation, with the check that its body is still the one on screen and the
// subscription that reports when that may change.
interface PendingLink {
  readonly inbox: GmailInbox;
  readonly id: string;
  readonly link: BodyLink;
  readonly current: () => boolean;
  readonly subscribe: (listener: () => void) => () => void;
}

const noSubscription = () => () => undefined;

const LinkConfirmationContext = createContext<
  ((pending: PendingLink | undefined) => void) | undefined
>(undefined);

async function openLink(href: string) {
  try {
    await Linking.openURL(href);
  } catch {
    // A refused system handoff leaves the reader usable.
  }
}

function Action({
  label,
  accessibilityLabel,
  onPress,
}: {
  readonly label: string;
  readonly accessibilityLabel?: string;
  readonly onPress: () => void;
}) {
  const colors = usePalette();
  return (
    <Pressable
      accessibilityRole="button"
      accessibilityLabel={accessibilityLabel}
      focusable
      onPress={onPress}>
      <Text style={[styles.secondary, { color: colors.accent }]}>{label}</Text>
    </Pressable>
  );
}

// Confirms a link's full destination before the system opens it. A link with warning signs
// explains them and offers copying it instead.
function LinkConfirmation({
  link,
  current,
  onDone,
}: {
  readonly link: BodyLink;
  // Rechecked before revealing or opening the destination: the body or its Inbox may have closed.
  readonly current: () => boolean;
  readonly onDone: () => void;
}) {
  const colors = usePalette();
  const reasons = inspectLink(link.href, link.text);
  const proceed = () => {
    onDone();
    if (current()) {
      void openLink(link.href);
    }
  };
  return (
    <View
      accessibilityLiveRegion="polite"
      style={[styles.confirm, { borderColor: colors.separator }]}>
      <Text style={[styles.secondary, { color: colors.foreground }]}>
        {reasons.length === 0
          ? messageBodyCopy.confirmLink
          : messageBodyCopy.cautionLink}
      </Text>
      {reasons.map((reason) => (
        <Text
          key={reason}
          style={[styles.secondary, { color: colors.foreground }]}>
          {`• ${reason}`}
        </Text>
      ))}
      <Text
        selectable
        style={[styles.secondary, { color: colors.secondary }]}>
        {link.href}
      </Text>
      <View style={styles.actions}>
        {reasons.length === 0 ? (
          <Action
            label="Open link"
            onPress={proceed}
          />
        ) : (
          <>
            <Action
              label="Copy link"
              onPress={() => {
                onDone();
                if (current()) {
                  // oxlint-disable-next-line typescript/no-deprecated -- Core Clipboard remains in both hosts' React Native; a replacement would add a native module.
                  Clipboard.setString(link.href);
                }
              }}
            />
            <Action
              label="Proceed"
              onPress={proceed}
            />
          </>
        )}
        <Action
          label="Cancel"
          onPress={onDone}
        />
      </View>
    </View>
  );
}

// Shows link confirmations below the reader's scrolling content, so a link chosen anywhere in a
// long message is confirmed in view.
export function LinkConfirmationProvider({
  children,
  inbox,
  id,
}: {
  readonly children: ReactNode;
  readonly inbox: object;
  readonly id: string;
}) {
  const colors = usePalette();
  const [pending, setPending] = useState<PendingLink>();
  // Compare the render owner too: layout cleanup has not invalidated the old reader yet.
  const shown = useSyncExternalStore(
    pending?.subscribe ?? noSubscription,
    () => pending?.inbox === inbox && pending?.id === id && pending.current(),
  );
  return (
    <LinkConfirmationContext value={setPending}>
      <View style={styles.fill}>
        {children}
        {pending === undefined || !shown ? null : (
          <View
            style={[
              styles.bar,
              {
                borderTopColor: colors.separator,
                backgroundColor: colors.background,
              },
            ]}>
            <LinkConfirmation
              link={pending.link}
              current={pending.current}
              onDone={() => {
                setPending(undefined);
              }}
            />
          </View>
        )}
      </View>
    </LinkConfirmationContext>
  );
}

// Keyboard and switch access to every link: each control opens the same confirmation.
function MessageLinks({
  links,
  onChoose,
}: {
  readonly links: readonly BodyLink[];
  readonly onChoose: (link: BodyLink) => void;
}) {
  const colors = usePalette();
  const [focused, setFocused] = useState<number>();
  return links.map((link, index) => (
    <Pressable
      // Links of one body never reorder, and a destination may repeat.
      // oxlint-disable-next-line react/no-array-index-key
      key={index}
      accessibilityRole="link"
      accessibilityLabel={`Open link: ${link.text === '' ? link.href : link.text}`}
      accessibilityHint={link.href}
      focusable
      onFocus={() => {
        setFocused(index);
      }}
      onBlur={() => {
        setFocused(undefined);
      }}
      onPress={() => {
        onChoose(link);
      }}
      style={[
        styles.linkControl,
        {
          borderColor: focused === index ? colors.accent : colors.background,
        },
      ]}>
      <Text style={[styles.secondary, { color: colors.accent }]}>
        {`Open link: ${link.text === '' ? link.href : link.text}`}
      </Text>
    </Pressable>
  ));
}

// The plain-text presentation, and the fallback when rich presentation is unavailable.
function ReadableText({
  readable,
  onChoose,
}: {
  readonly readable: ReadableBody;
  readonly onChoose: (link: BodyLink) => void;
}) {
  const colors = usePalette();
  if (readable.paragraphs.length === 0) {
    return (
      <Text style={[styles.paragraph, { color: colors.secondary }]}>
        {messageBodyCopy.empty}
      </Text>
    );
  }
  return readable.paragraphs.map((spans, paragraph) => (
    // Paragraphs of one body never reorder.
    // oxlint-disable-next-line react/no-array-index-key
    <Fragment key={paragraph}>
      <Text
        selectable
        style={[styles.paragraph, { color: colors.foreground }]}>
        {spans.map(({ text, href }, span) =>
          href === undefined ? (
            text
          ) : (
            <Text
              // oxlint-disable-next-line react/no-array-index-key
              key={span}
              accessibilityHint={href}
              accessibilityRole="link"
              onPress={() => {
                onChoose({ href, text });
              }}
              style={[styles.link, { color: colors.accent }]}>
              {text}
            </Text>
          ),
        )}
      </Text>
      <MessageLinks
        links={spans.flatMap(({ text, href }) =>
          href === undefined ? [] : [{ href, text }],
        )}
        onChoose={onChoose}
      />
    </Fragment>
  ));
}

// The sanitized document in an isolated WebKit view: no page JavaScript, non-persistent data,
// no link previews, and every navigation cancelled. A chosen link goes to the confirmation.
// The view stays hidden behind a placeholder until its first layout is measured.
function RichDocument({
  rich,
  onChoose,
  onFailure,
}: {
  readonly rich: NonNullable<MessagePresentation['rich']>;
  readonly onChoose: (link: BodyLink) => void;
  readonly onFailure: () => void;
}) {
  // The laid-out width; a later different width lays the document out and measures it again.
  const width = useRef<number>(undefined);
  const [layout, setLayout] = useState(0);
  const [height, setHeight] = useState<number>();
  const choose = ({ url, navigationType }: ShouldStartLoadRequest) => {
    if (url === 'about:blank') {
      return navigationType === 'other';
    }
    if (navigationType === 'click') {
      const link = messageLinkAt(rich.links, url);
      if (link !== undefined) {
        onChoose(link);
      }
    }
    return false;
  };
  return (
    <View
      onLayout={({ nativeEvent }: LayoutChangeEvent) => {
        const next = Math.round(nativeEvent.layout.width);
        if (width.current !== undefined && width.current !== next) {
          setHeight(undefined);
          setLayout((count) => count + 1);
        }
        width.current = next;
      }}>
      {height === undefined ? (
        <ActivityIndicator accessibilityLabel="Opening message" />
      ) : null}
      {
        <WebView
          key={layout}
          accessibilityLabel="Message"
          allowsInlineMediaPlayback={false}
          allowsLinkPreview={false}
          cacheEnabled={false}
          dataDetectorTypes="none"
          incognito
          javaScriptCanOpenWindowsAutomatically={false}
          javaScriptEnabled={false}
          mediaPlaybackRequiresUserAction
          onContentProcessDidTerminate={onFailure}
          onContentSizeChange={(event: WebViewEvent) => {
            const measured = decodeMessageContentHeight(event.nativeEvent);
            if (measured !== undefined) {
              setHeight(measured);
            }
          }}
          onError={onFailure}
          onShouldStartLoadWithRequest={choose}
          // Every URL reaches `choose`; the wrapper would otherwise open unlisted origins itself.
          originWhitelist={['*']}
          scrollEnabled={height !== undefined && height > heightCap}
          setSupportMultipleWindows={false}
          source={{ html: rich.document }}
          style={[
            styles.rich,
            { height: Math.min(height ?? 1, heightCap) },
            height === undefined ? styles.hidden : undefined,
          ]}
        />
      }
    </View>
  );
}

// Each rich document gets its own native view, so a late failure or size from a replaced
// document cannot reach its replacement.
const documentKeys = new WeakMap<object, number>();
let documents = 0;
const documentKey = (rich: object) => {
  const key = documentKeys.get(rich) ?? (documents += 1);
  documentKeys.set(rich, key);
  return key;
};

function Presentation({
  presentation,
  onChoose,
  onFailure,
}: {
  readonly presentation: MessagePresentation;
  readonly onChoose: (link: BodyLink) => void;
  readonly onFailure: () => void;
}) {
  const colors = usePalette();
  const { rich, readable } = presentation;
  const richKey = rich === undefined ? undefined : documentKey(rich);
  // Keep only the failed document's identity so its HTML and inline bytes can be released.
  const [failed, setFailed] = useState<number>();
  return (
    <>
      {readable.hidesImages ? (
        <Text style={[styles.secondary, { color: colors.secondary }]}>
          {messageBodyCopy.images}
        </Text>
      ) : null}
      {rich === undefined || failed === richKey ? (
        <ReadableText
          readable={readable}
          onChoose={onChoose}
        />
      ) : (
        <>
          <RichDocument
            key={richKey}
            rich={rich}
            onChoose={onChoose}
            onFailure={() => {
              setFailed(richKey);
              onFailure();
            }}
          />
          <MessageLinks
            links={rich.links}
            onChoose={onChoose}
          />
        </>
      )}
    </>
  );
}

const sizeFormat = new Intl.NumberFormat('en', {
  maximumFractionDigits: 1,
});
const fileSize = (bytes: number) => {
  if (bytes < 1024) {
    return `${bytes} bytes`;
  }
  return bytes < 1024 * 1024
    ? `${sizeFormat.format(bytes / 1024)} KB`
    : `${sizeFormat.format(bytes / (1024 * 1024))} MB`;
};

const attachmentStatus = (state: ReceivedAttachment['state']) => {
  if (state.kind === 'downloading') {
    return 'Downloading…';
  }
  if (state.kind === 'oversized') {
    return attachmentCopy.oversized;
  }
  return state.kind === 'unavailable'
    ? attachmentCopy[state.reason]
    : undefined;
};

// One received attachment: its name and size, and what can be done with it now.
function AttachmentRow({
  inbox,
  id,
  attachment,
}: {
  readonly inbox: GmailInbox;
  readonly id: string;
  readonly attachment: ReceivedAttachment;
}) {
  const colors = usePalette();
  const { locator, name, size, state } = attachment;
  const status = attachmentStatus(state);
  let actions: ReactNode = null;
  if (state.kind === 'available') {
    actions = (
      <Action
        label="Download"
        accessibilityLabel={`Download ${name}`}
        onPress={() => {
          void inbox.downloadAttachment(id, locator);
        }}
      />
    );
  } else if (state.kind === 'downloading') {
    actions = (
      <Action
        label="Cancel"
        accessibilityLabel={`Cancel downloading ${name}`}
        onPress={() => {
          inbox.cancelAttachment(id, locator);
        }}
      />
    );
  } else if (state.kind === 'downloaded') {
    actions = (
      <>
        <Action
          label="Open"
          accessibilityLabel={`Open ${name}`}
          onPress={() => {
            void inbox.presentAttachment(id, locator, 'open');
          }}
        />
        <Action
          label="Share"
          accessibilityLabel={`Share ${name}`}
          onPress={() => {
            void inbox.presentAttachment(id, locator, 'share');
          }}
        />
      </>
    );
  } else if (state.kind === 'unavailable') {
    actions =
      state.reason === 'missing' ? null : (
        <Action
          label="Try again"
          accessibilityLabel={`Try downloading ${name} again`}
          onPress={() => {
            void inbox.downloadAttachment(id, locator);
          }}
        />
      );
  }
  return (
    <View style={styles.attachment}>
      <Text
        selectable
        style={[styles.attachmentName, { color: colors.foreground }]}>
        {name}
      </Text>
      <Text style={[styles.secondary, { color: colors.secondary }]}>
        {fileSize(size)}
      </Text>
      {status === undefined ? null : (
        <Text
          accessibilityLiveRegion="polite"
          style={[styles.secondary, { color: colors.secondary }]}>
          {status}
        </Text>
      )}
      <View style={styles.actions}>{actions}</View>
    </View>
  );
}

// A message can carry thousands of parts, so rows render in bounded batches.
const attachmentBatch = 20;

// The opened message's received attachments. Listing them downloads nothing; each downloads
// only when asked, and opens or shares through the system.
function ReceivedAttachments({
  inbox,
  id,
}: {
  readonly inbox: GmailInbox;
  readonly id: string;
}) {
  const colors = usePalette();
  const attachments = useSyncExternalStore(inbox.subscribe, () =>
    inbox.messageAttachments(id),
  );
  const [shown, setShown] = useState(attachmentBatch);
  if (attachments === undefined || attachments.length === 0) {
    return null;
  }
  return (
    <View style={[styles.attachments, { borderTopColor: colors.separator }]}>
      <Text
        accessibilityRole="header"
        style={[styles.secondary, { color: colors.secondary }]}>
        {attachments.length === 1
          ? '1 attachment'
          : `${attachments.length} attachments`}
      </Text>
      {attachments.slice(0, shown).map((attachment) => (
        <AttachmentRow
          key={attachment.locator}
          inbox={inbox}
          id={id}
          attachment={attachment}
        />
      ))}
      {attachments.length > shown ? (
        <Action
          label={`Show ${Math.min(attachmentBatch, attachments.length - shown)} more`}
          accessibilityLabel={`Show more attachments, ${attachments.length - shown} not shown`}
          onPress={() => {
            setShown((count) => count + attachmentBatch);
          }}
        />
      ) : null}
    </View>
  );
}

// The opened Gmail message's body, from this device or downloaded on demand. Links open only
// after the person confirms the destination shown here.
export function GmailMessageBody({
  inbox,
  id,
}: {
  readonly inbox: GmailInbox;
  readonly id: string;
}) {
  const colors = usePalette();
  // oxlint-disable-next-line react/hook-use-state -- This immutable reader identity has no setter.
  const [reader] = useState(() => Symbol('message reader'));
  const body = useSyncExternalStore(inbox.subscribe, () =>
    inbox.messageBody(id, reader),
  );
  const confirm = use(LinkConfirmationContext);
  // The message this reader shows, cleared as soon as it changes or closes, so input queued for a
  // previous message is recognized before any passive cleanup runs.
  const showing = useRef<{ readonly inbox: GmailInbox; readonly id: string }>(
    undefined,
  );
  useLayoutEffect(() => {
    showing.current = { inbox, id };
    return () => {
      showing.current = undefined;
    };
  }, [inbox, id]);
  useEffect(() => {
    const release = inbox.retainMessage(id, reader);
    void inbox.readMessage(id);
    return release;
  }, [inbox, id, reader]);
  // A replaced or closed body discards a confirmation chosen in it.
  useEffect(() => {
    if (body?.kind !== 'ready') {
      return undefined;
    }
    return () => {
      confirm?.(undefined);
    };
  }, [body, confirm]);

  if (body === undefined || body.kind === 'loading') {
    return (
      <ActivityIndicator
        accessibilityLabel="Opening message"
        style={styles.body}
      />
    );
  }

  if (body.kind === 'unavailable') {
    return (
      <View style={styles.body}>
        <Text
          accessibilityRole="alert"
          style={[styles.paragraph, { color: colors.secondary }]}>
          {messageBodyCopy[body.reason]}
        </Text>
        {body.reason === 'missing' ? null : (
          <Action
            label="Try again"
            onPress={() => {
              void inbox.readMessage(id);
            }}
          />
        )}
      </View>
    );
  }

  // Native input can be queued before the owner changes and delivered afterward, so a stale
  // choice shows nothing.
  const current = () =>
    showing.current?.inbox === inbox &&
    showing.current.id === id &&
    inbox.messageBody(id, reader) === body;
  return (
    <View style={styles.body}>
      <Presentation
        presentation={body.presentation}
        onFailure={() => {
          inbox.discardRichMessage(id, body.presentation, reader);
        }}
        onChoose={(link) => {
          if (current()) {
            confirm?.({ inbox, id, link, current, subscribe: inbox.subscribe });
          }
        }}
      />
      <ReceivedAttachments
        inbox={inbox}
        id={id}
      />
    </View>
  );
}
