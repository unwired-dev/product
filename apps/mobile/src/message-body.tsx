import type { Translate } from '@private-email/localization';
import type { MenuSection } from '@private-email/mail-core/context-menu';
import type { ImapBodyState } from '@private-email/mail-core/imap-inbox';
import type {
  GmailInbox,
  MessageBodyState,
  ReceivedAttachment,
  SavedCopy,
} from '@private-email/mail-core/inbox-store';
import type {
  BodyLink,
  MessagePresentation,
  ReadableBody,
} from '@private-email/mail-core/message-body';
import type { Dispatch, ReactNode, SetStateAction } from 'react';
import type {
  LayoutChangeEvent,
  ScrollViewInstance,
  ScrollViewProps,
  ViewInstance,
} from 'react-native';
import type {
  ShouldStartLoadRequest,
  WebViewEvent,
  WebViewScrollEvent,
} from 'react-native-webview/lib/WebViewTypes';

import {
  Alert,
  Button,
  Host,
  Spacer,
  Text as SwiftUIText,
} from '@expo/ui/swift-ui';
import {
  background,
  buttonStyle,
  contentShape,
  font,
  foregroundStyle,
  frame,
  padding,
  shapes,
} from '@expo/ui/swift-ui/modifiers';
import {
  inspectLink,
  messageLinkAt,
} from '@private-email/mail-core/link-inspection';
import {
  decodeMessageContentSize,
  decodeRemoteImagePositions,
  labelImagePlaceholders,
} from '@private-email/mail-core/message-body';
import { ipadListScale, spacing } from '@private-email/mail-core/theme';
import { setStringAsync } from 'expo-clipboard';
import {
  createContext,
  Fragment,
  use,
  useEffect,
  useLayoutEffect,
  useMemo,
  useRef,
  useState,
  useSyncExternalStore,
} from 'react';
import {
  AccessibilityInfo,
  ActivityIndicator,
  Linking,
  Pressable,
  ScrollView,
  Text,
  View,
} from 'react-native';
import { WebView } from 'react-native-webview';

import { Action } from './action.tsx';
import { ContextMenu, Notice, SFSymbol } from './design.tsx';
import { ipad } from './inbox-styles.ts';
import { InvitationCard } from './invitation.tsx';
import { useLocalization } from './localization.ts';
import { useProviderName } from './mailbox.tsx';
import { styles } from './message-body-styles.ts';
import { AssistanceContext, MessageSummary } from './message-summary.tsx';
import { useMessageZoom, zoomedDocument } from './reading.ts';
import { useRemoteImages } from './remote-content.tsx';
import { usePalette } from './theme.ts';
import { MessageTranslation, TranslationContext } from './translation.tsx';

// A taller document scrolls inside its view instead of the reader.
const heightCap = 20_000;

// A link awaiting confirmation, with the check that its body is still the one on screen and the
// subscription that reports when that may change.
interface PendingLink {
  // The store whose body showed the link; only its identity is compared.
  readonly inbox: object;
  readonly id: string;
  readonly link: BodyLink;
  readonly current: () => boolean;
  readonly subscribe: (listener: () => void) => () => void;
}

const noSubscription = () => () => undefined;

// Discards a pending confirmation chosen in one message's body, keeping one another message of
// the same reader owns.
export const withoutLinkFrom =
  (inbox: object, id: string) => (pending: PendingLink | undefined) =>
    pending?.inbox === inbox && pending.id === id ? undefined : pending;

// What Save to Files did for one of the reader's attachments: the copy it saved, or nothing saved,
// with the action that tries again.
export type SaveOutcome =
  | Readonly<{ kind: 'saved'; copy: SavedCopy }>
  | Readonly<{ kind: 'failed'; name: string; retry: () => void }>;

// Starts a save in the reader showing the message, returning how to report its outcome; none
// outside a reader.
export const SaveOutcomeContext = createContext<
  (() => (outcome: SaveOutcome) => void) | undefined
>(undefined);

export const LinkConfirmationContext = createContext<
  Dispatch<SetStateAction<PendingLink | undefined>> | undefined
>(undefined);

export async function openLink(href: string) {
  try {
    await Linking.openURL(href);
  } catch {
    // A refused system handoff leaves the reader usable.
  }
}

// Confirms a link's full destination before the system opens it. A link with warning signs
// explains them and offers copying it instead. The system alert owns presentation, focus and
// Escape; Cancel's role makes it the dismissal choice.
function LinkConfirmation({
  link,
  current,
  onDone,
}: {
  readonly link: BodyLink;
  // Rechecked before opening or copying the destination: the body or its Inbox may have closed.
  readonly current: () => boolean;
  readonly onDone: () => void;
}) {
  const { t } = useLocalization();
  const reasons = inspectLink(link.href, link.text);
  const proceed = () => {
    onDone();
    if (current()) {
      void openLink(link.href);
    }
  };
  const cancel = (
    <Button
      // oxlint-disable-next-line jsx-a11y/aria-role -- SwiftUI button role, not ARIA.
      role="cancel"
      label={t('common.cancel')}
      onPress={onDone}
    />
  );
  return (
    <Host matchContents>
      <Alert
        testID="link-confirmation"
        title={
          reasons.length === 0
            ? t('messageBody.confirmLink')
            : t('messageBody.cautionTitle')
        }
        isPresented>
        {/* SwiftUI drops an alert attached to an empty view, so it anchors on a zero-size spacer. */}
        <Alert.Trigger>
          <Spacer modifiers={[frame({ width: 0, height: 0 })]} />
        </Alert.Trigger>
        <Alert.Actions>
          {reasons.length === 0 ? (
            <>
              <Button
                label={t('messageBody.openLink')}
                onPress={proceed}
              />
              {cancel}
            </>
          ) : (
            <>
              {cancel}
              <Button
                label={t('messageBody.copyLink')}
                onPress={() => {
                  onDone();
                  if (current()) {
                    void setStringAsync(link.href);
                  }
                }}
              />
              <Button
                // oxlint-disable-next-line jsx-a11y/aria-role -- SwiftUI button role, not ARIA.
                role="destructive"
                label={t('messageBody.proceed')}
                onPress={proceed}
              />
            </>
          )}
        </Alert.Actions>
        <Alert.Message>
          <SwiftUIText>
            {[
              ...(reasons.length === 0
                ? []
                : [
                    t('messageBody.cautionLink'),
                    ...reasons.map((reason) =>
                      t('messageBody.warning', {
                        warning: t(`linkWarnings.${reason}`),
                      }),
                    ),
                    '',
                  ]),
              link.href,
            ].join('\n')}
          </SwiftUIText>
        </Alert.Message>
      </Alert>
    </Host>
  );
}

// Confirms a link above the reader, keeping its choice visible at every scroll position.
export function LinkConfirmationProvider({
  children,
  inbox,
  ids,
}: {
  readonly children: ReactNode;
  readonly inbox: object;
  // The messages the reader shows.
  readonly ids: readonly string[];
}) {
  const [pending, setPending] = useState<PendingLink>();
  // Compare the render owner too: layout cleanup has not invalidated the old reader yet.
  const shown = useSyncExternalStore(
    pending?.subscribe ?? noSubscription,
    () =>
      pending?.inbox === inbox && ids.includes(pending.id) && pending.current(),
  );
  return (
    <LinkConfirmationContext value={setPending}>
      <View style={styles.fill}>
        {children}
        {pending === undefined || !shown ? null : (
          <LinkConfirmation
            link={pending.link}
            current={pending.current}
            onDone={() => {
              setPending((value) => (value === pending ? undefined : value));
            }}
          />
        )}
      </View>
    </LinkConfirmationContext>
  );
}

// Keyboard and switch access to every link: each control opens the same confirmation.
function MessageLinks({
  links,
  onChoose,
  onCopy,
}: {
  readonly links: readonly BodyLink[];
  readonly onChoose: (link: BodyLink) => void;
  readonly onCopy: (link: BodyLink) => void;
}) {
  const colors = usePalette();
  const { t } = useLocalization();
  return links.map((link, index) => (
    <ContextMenu
      // Links of one body never reorder, and a destination may repeat.
      // oxlint-disable-next-line react/no-array-index-key
      key={index}
      sections={[
        {
          items: [
            {
              key: `open\n${link.href}`,
              title: t('contextMenu.openLink'),
              symbol: 'safari',
              run: () => {
                onChoose(link);
              },
            },
            {
              key: `copy\n${link.href}`,
              title: t('contextMenu.copyLink'),
              symbol: 'doc.on.doc',
              run: () => {
                onCopy(link);
              },
            },
          ],
        },
      ]}>
      <Pressable
        testID="message-link-control"
        accessibilityRole="link"
        accessibilityLabel={link.text === '' ? link.href : link.text}
        accessibilityHint={link.href}
        focusable
        onPress={() => {
          onChoose(link);
        }}
        style={({ pressed }) => [
          styles.linkControl,
          {
            backgroundColor: pressed
              ? colors.accentSelectionSubtle
              : 'transparent',
          },
        ]}>
        <Text
          style={[
            styles.secondary,
            { color: colors.accentInk, textDecorationLine: 'underline' },
          ]}>
          {link.text === '' ? link.href : link.text}
        </Text>
      </Pressable>
    </ContextMenu>
  ));
}

// The plain-text presentation, and the fallback when rich presentation is unavailable.
function ReadableText({
  readable,
  onChoose,
  onCopy,
}: {
  readonly readable: ReadableBody;
  readonly onChoose: (link: BodyLink) => void;
  readonly onCopy: (link: BodyLink) => void;
}) {
  const colors = usePalette();
  const { t } = useLocalization();
  if (readable.paragraphs.length === 0) {
    return (
      <Text style={[styles.paragraph, { color: colors.textSecondary }]}>
        {t('messageBody.empty')}
      </Text>
    );
  }
  return readable.paragraphs.map((spans, paragraph) => (
    // Paragraphs of one body never reorder.
    // oxlint-disable-next-line react/no-array-index-key
    <Fragment key={paragraph}>
      <Text
        selectable
        style={[styles.paragraph, { color: colors.textPrimary }]}>
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
              style={[styles.link, { color: colors.accentInk }]}>
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
        onCopy={onCopy}
      />
    </Fragment>
  ));
}

// What the reader's scroll view shows, so Remote Message Content loads only near it.
interface ReaderViewport {
  readonly subscribe: (listener: () => void) => () => void;
  readonly get: () => Readonly<{ offset: number; height: number }>;
  readonly content: () => ScrollViewInstance | null | undefined;
  readonly scrollTo: (offset: number) => void;
}

const ReaderViewportContext = createContext<ReaderViewport | undefined>(
  undefined,
);

// Scrolls the enclosing reader to a content offset.
export function useReaderScrollTo() {
  return use(ReaderViewportContext)?.scrollTo;
}

// The visible range of the enclosing reader, for content that loads only near it.
export function useReaderViewport() {
  return use(ReaderViewportContext);
}

// The reader's scrolling content, reporting its visible range to the documents inside it.
export function ReaderScrollView({
  children,
  contentContainerStyle,
  maintainVisibleContentPosition,
  onScrollBeginDrag,
}: Pick<
  ScrollViewProps,
  | 'children'
  | 'contentContainerStyle'
  | 'maintainVisibleContentPosition'
  | 'onScrollBeginDrag'
>) {
  const scroll = useRef<ScrollViewInstance>(null);
  // oxlint-disable-next-line react/hook-use-state -- The viewport store is created once and updates its listeners.
  const [viewport] = useState(() => {
    const listeners = new Set<() => void>();
    let visible = { offset: 0, height: 0 };
    const update = (next: Partial<typeof visible>) => {
      visible = { ...visible, ...next };
      for (const listener of listeners) {
        listener();
      }
    };
    return {
      subscribe: (listener: () => void) => {
        listeners.add(listener);
        return () => {
          listeners.delete(listener);
        };
      },
      get: () => visible,
      content: () => scroll.current?.getNativeScrollRef(),
      scrollTo: (offset: number) => {
        scroll.current?.scrollTo({ y: offset, animated: false });
        update({ offset });
      },
      update,
    };
  });
  return (
    <ReaderViewportContext value={viewport}>
      <ScrollView
        ref={scroll}
        contentContainerStyle={contentContainerStyle}
        maintainVisibleContentPosition={maintainVisibleContentPosition}
        onScrollBeginDrag={onScrollBeginDrag}
        scrollEventThrottle={100}
        onLayout={({ nativeEvent }) => {
          viewport.update({ height: nativeEvent.layout.height });
        }}
        onScroll={({ nativeEvent }) => {
          viewport.update({
            offset: nativeEvent.contentOffset.y,
            height: nativeEvent.layoutMeasurement.height,
          });
        }}>
        {children}
      </ScrollView>
    </ReaderViewportContext>
  );
}

// The sanitized document in an isolated WebKit view: no page JavaScript, non-persistent data,
// no link previews, and every navigation cancelled. A chosen link goes to the confirmation.
// The view stays hidden behind a placeholder until its first layout is measured. Blocked remote
// images within one viewport of the visible range are reported as they come near. The document
// takes the reader's Message Zoom.
function RichDocument({
  rich,
  zoom,
  onChoose,
  onFailure,
  onNear,
}: {
  readonly rich: NonNullable<MessagePresentation['rich']>;
  readonly zoom: number;
  readonly onChoose: (link: BodyLink) => void;
  readonly onFailure: () => void;
  readonly onNear: (urls: readonly string[]) => void;
}) {
  const colors = usePalette();
  const { t } = useLocalization();
  // The laid-out width; a later different width lays the document out and measures it again.
  const [width, setWidth] = useState<number>();
  // oxlint-disable-next-line react/hook-use-state -- This mounted navigation keeps its original source.
  const [source] = useState(() => ({
    html: zoomedDocument(
      labelImagePlaceholders(
        rich.initialDocument,
        t('messageBody.imageNotLoaded'),
      ),
      zoom,
    ),
  }));
  const container = useRef<ViewInstance>(null);
  const viewport = use(ReaderViewportContext);
  const [layout, setLayout] = useState(0);
  const [height, setHeight] = useState<number>();
  const [contentWidth, setContentWidth] = useState(0);
  const [positions, setPositions] = useState<
    ReturnType<typeof decodeRemoteImagePositions>
  >([]);
  // How far the view has scrolled inside its document and its pinch zoom, and the check it reruns.
  const inner = useRef({ offset: 0, scale: 1 });
  const near = useRef<() => void>(undefined);
  // The shown view's `layout`, advanced as soon as it is replaced so its late events are ignored.
  const live = useRef(0);
  // An outgoing document, such as one replaced by a Message Zoom change, withdraws its images.
  const withdraw = useRef(onNear);
  useEffect(() => {
    withdraw.current = onNear;
  });
  useEffect(
    () => () => {
      withdraw.current([]);
    },
    [],
  );
  useEffect(() => {
    if (
      viewport === undefined ||
      height === undefined ||
      positions.length === 0
    ) {
      return undefined;
    }
    let active = true;
    let measurement = 0;
    const shown = live.current;
    const request = () => {
      if (live.current !== shown) {
        return;
      }
      measurement += 1;
      const revision = measurement;
      const { offset, height: visible } = viewport.get();
      const content = viewport.content();
      if (content === undefined || content === null) {
        return;
      }
      container.current?.measureLayout(content, (_left, top) => {
        if (!active || revision !== measurement || live.current !== shown) {
          return;
        }
        // The document scrolls and pinch-zooms inside its view; only images inside the view count.
        const { offset: scrolled, scale } = inner.current;
        const start = top - scrolled;
        const bottom = top + Math.min(height, heightCap);
        const urls = positions
          .filter((position) => {
            const upper = Math.max(start + position.top * scale, top);
            const lower = Math.min(start + position.bottom * scale, bottom);
            return (
              upper < lower &&
              lower >= offset - visible &&
              upper <= offset + 2 * visible
            );
          })
          .flatMap(({ index }) => rich.remote.images[index] ?? []);
        onNear(urls);
      });
    };
    request();
    near.current = request;
    const unsubscribe = viewport.subscribe(request);
    return () => {
      active = false;
      near.current = undefined;
      unsubscribe();
    };
  }, [viewport, height, positions, rich, onNear]);
  // Wider content, such as unwrappable text, scrolls sideways inside the view.
  const wide = width !== undefined && contentWidth > width;
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
      ref={container}
      onLayout={({ nativeEvent }: LayoutChangeEvent) => {
        const next = Math.round(nativeEvent.layout.width);
        if (width !== undefined && width !== next) {
          // The replacement view reports its images afresh; the old ones are withdrawn.
          live.current += 1;
          inner.current = { offset: 0, scale: 1 };
          onNear([]);
          setHeight(undefined);
          setLayout(live.current);
        }
        setWidth(next);
      }}>
      {height === undefined ? (
        <ActivityIndicator accessibilityLabel={t('messageBody.opening')} />
      ) : null}
      {
        <WebView
          key={layout}
          accessibilityLabel={t('messageBody.message')}
          allowsInlineMediaPlayback={false}
          allowsLinkPreview={false}
          cacheEnabled={false}
          dataDetectorTypes="none"
          incognito
          javaScriptCanOpenWindowsAutomatically={false}
          javaScriptEnabled={false}
          mediaPlaybackRequiresUserAction
          onContentProcessDidTerminate={onFailure}
          onContentSizeChange={(event: WebViewEvent): void => {
            const measured = decodeMessageContentSize(event.nativeEvent);
            if (measured !== undefined && layout === live.current) {
              setPositions(decodeRemoteImagePositions(event.nativeEvent));
              setHeight(measured.height);
              setContentWidth(measured.width);
            }
          }}
          onError={onFailure}
          onShouldStartLoadWithRequest={choose}
          onScroll={({ nativeEvent }: WebViewScrollEvent) => {
            if (layout === live.current) {
              inner.current = {
                offset: nativeEvent.contentOffset.y,
                scale: nativeEvent.zoomScale ?? 1,
              };
              near.current?.();
            }
          }}
          // Every URL reaches `choose`; the wrapper would otherwise open unlisted origins itself.
          originWhitelist={['*']}
          // Without bounce, a sideways scroll keeps a normal-height document pinned vertically.
          bounces={height !== undefined && height > heightCap}
          scrollEnabled={height !== undefined && (height > heightCap || wide)}
          setSupportMultipleWindows={false}
          source={source}
          nativeConfig={{ props: { remoteImageUpdates: rich.remote.updates } }}
          style={[
            styles.rich,
            {
              backgroundColor: colors.surfaceContent,
              height: Math.min(height ?? 1, heightCap),
            },
            height === undefined ? styles.hidden : undefined,
          ]}
        />
      }
    </View>
  );
}

export function Presentation({
  presentation,
  onChoose,
  onCopy,
  onFailure,
  onNear,
  onLoadImages,
}: {
  readonly presentation: MessagePresentation;
  readonly onChoose: (link: BodyLink) => void;
  readonly onCopy: (link: BodyLink) => void;
  readonly onFailure: () => void;
  readonly onNear: (urls: readonly string[]) => void;
  // Present while this presentation still needs consent to load its remote images.
  readonly onLoadImages: (() => void) | undefined;
}) {
  const colors = usePalette();
  const { t } = useLocalization();
  const { rich, readable } = presentation;
  const zoom = useMessageZoom();
  // A new source gets a new native view; remote-image node changes keep this navigation.
  const [navigation, setNavigation] = useState(() => ({
    document: rich?.initialDocument,
    key: 0,
  }));
  let current = navigation;
  if (navigation.document !== rich?.initialDocument) {
    current = { document: rich?.initialDocument, key: navigation.key + 1 };
    setNavigation(current);
  }
  const richKey = current.key;
  // Keep only the failed document's identity so its HTML and inline bytes can be released.
  const [failed, setFailed] = useState<number>();
  const offered =
    onLoadImages !== undefined &&
    rich !== undefined &&
    failed !== richKey &&
    rich.remote.pending.length > 0;
  let notice: ReactNode = null;
  if (offered) {
    notice = (
      <Notice
        icon="photo"
        message={t('messageBody.remoteImages')}>
        <Action
          label={t('messageBody.loadImages')}
          onPress={onLoadImages}
        />
      </Notice>
    );
  } else if (readable.hidesImages) {
    notice = (
      <Text style={[styles.secondary, { color: colors.textSecondary }]}>
        {t('messageBody.images')}
      </Text>
    );
  }
  return (
    <>
      {notice}
      {rich === undefined || failed === richKey ? (
        <ReadableText
          readable={readable}
          onChoose={onChoose}
          onCopy={onCopy}
        />
      ) : (
        <>
          <RichDocument
            key={`${richKey}:${zoom}`}
            rich={rich}
            zoom={zoom / 100}
            onNear={onNear}
            onChoose={onChoose}
            onFailure={() => {
              setFailed(richKey);
              onFailure();
            }}
          />
          <MessageLinks
            links={rich.links}
            onChoose={onChoose}
            onCopy={onCopy}
          />
        </>
      )}
    </>
  );
}

export const fileSize = (
  t: Translate,
  format: Intl.NumberFormat,
  bytes: number,
) => {
  if (bytes < 1024) {
    return t('attachment.bytes', { count: bytes, size: format.format(bytes) });
  }
  return bytes < 1024 * 1024
    ? t('attachment.kilobytes', { size: format.format(bytes / 1024) })
    : t('attachment.megabytes', {
        size: format.format(bytes / (1024 * 1024)),
      });
};

const attachmentStatus = (
  t: Translate,
  state: ReceivedAttachment['state'],
  provider: string | undefined,
) => {
  if (state.kind === 'downloading') {
    return t('attachment.downloading');
  }
  if (state.kind === 'oversized') {
    return t('attachment.oversized');
  }
  // An IMAP connection's copy names its mail server, not a provider.
  return state.kind === 'unavailable'
    ? t(
        `attachment.${state.reason}`,
        provider === undefined ? { context: 'imap' } : { provider },
      )
    : undefined;
};

// A Downloaded Attachment as a Draft can copy it, through its mailbox's current generation.
export type SavedAttachment = NonNullable<
  ReturnType<GmailInbox['attachmentFile']>
>;
// The Gmail, Microsoft or IMAP Inbox whose received attachments a reader shows.
type AttachmentSource = Pick<
  GmailInbox,
  | 'subscribe'
  | 'messageAttachments'
  | 'downloadAttachment'
  | 'cancelAttachment'
  | 'presentAttachment'
  | 'saveAttachmentCopy'
  | 'attachmentFile'
>;
// Starts a new message with a Downloaded Attachment, where the reader can open a composer.
export const AttachContext = createContext<
  ((attachment: SavedAttachment) => void) | undefined
>(undefined);

// One received attachment: its name and size, and what can be done with it now.
function AttachmentRow({
  inbox,
  id,
  attachment,
  current,
  provider,
}: {
  readonly inbox: AttachmentSource;
  readonly id: string;
  readonly attachment: ReceivedAttachment;
  // The mailbox provider's name, which status copy refers to; an IMAP mail server has none.
  readonly provider: string | undefined;
  // False once native input from a previous reader arrives after the message changed.
  readonly current: () => boolean;
}) {
  const colors = usePalette();
  const attach = use(AttachContext);
  const report = use(SaveOutcomeContext);
  const { t, settings } = useLocalization();
  const sizeFormat = useMemo(
    () => new Intl.NumberFormat(settings.locale, { maximumFractionDigits: 1 }),
    [settings.locale],
  );
  const { locator, name, size, state } = attachment;
  const status = attachmentStatus(t, state, provider);
  let actions: ReactNode = null;
  let menu: readonly MenuSection[] = [];
  if (state.kind === 'available') {
    actions = (
      <Action
        label={t('attachment.downloadAction')}
        accessibilityLabel={t('attachment.downloadLabel', { name })}
        onPress={() => {
          if (current()) {
            void inbox.downloadAttachment(id, locator);
          }
        }}
      />
    );
  } else if (state.kind === 'downloading') {
    actions = (
      <Action
        label={t('common.cancel')}
        accessibilityLabel={t('attachment.cancelLabel', { name })}
        onPress={() => {
          if (current()) {
            inbox.cancelAttachment(id, locator);
          }
        }}
      />
    );
  } else if (state.kind === 'downloaded') {
    const open = () => {
      if (current()) {
        void inbox.presentAttachment(id, locator, 'open');
      }
    };
    const share = () => {
      if (current()) {
        void inbox.presentAttachment(id, locator, 'share');
      }
    };
    // Saves a copy where the person chooses, and tells the reader what happened unless they
    // cancelled; the reader drops a result once it stopped showing the message.
    const saveCopy = async (shown: (outcome: SaveOutcome) => void) => {
      const saved = await inbox.saveAttachmentCopy(id, locator);
      if (saved === 'cancelled') {
        return;
      }
      shown(
        saved === 'failed'
          ? {
              kind: 'failed',
              name,
              retry: () => {
                void saveCopy(shown);
              },
            }
          : { kind: 'saved', copy: saved },
      );
    };
    const save = () => {
      if (current() && report !== undefined) {
        void saveCopy(report());
      }
    };
    menu = [
      {
        items: [
          {
            key: 'quickLook',
            title: t('contextMenu.quickLook'),
            symbol: 'eye',
            run: open,
          },
        ],
      },
      {
        items: [
          ...(report === undefined
            ? []
            : [
                {
                  key: 'saveToFiles',
                  title: t('attachment.saveToFiles'),
                  symbol: 'folder',
                  run: save,
                },
              ]),
          {
            key: 'share',
            title: t('contextMenu.share'),
            symbol: 'square.and.arrow.up',
            run: share,
          },
        ],
      },
    ];
    actions = (
      <>
        <Action
          label={t('attachment.open')}
          accessibilityLabel={t('attachment.openLabel', { name })}
          onPress={open}
        />
        <Action
          label={t('attachment.share')}
          accessibilityLabel={t('attachment.shareLabel', { name })}
          onPress={share}
        />
        {attach === undefined ? null : (
          <Action
            label={t('attachment.attachToNew')}
            accessibilityLabel={t('attachment.attachToNewLabel', { name })}
            onPress={() => {
              const saved = inbox.attachmentFile(id, locator);
              if (current() && saved !== undefined) {
                attach(saved);
              }
            }}
          />
        )}
      </>
    );
  } else if (state.kind === 'unavailable') {
    actions =
      state.reason === 'missing' ? null : (
        <Action
          label={t('common.retry')}
          accessibilityLabel={t('attachment.retryLabel', { name })}
          onPress={() => {
            if (current()) {
              void inbox.downloadAttachment(id, locator);
            }
          }}
        />
      );
  }
  return (
    <ContextMenu
      title={name}
      sections={menu}>
      <View style={[styles.attachment, { backgroundColor: colors.fillQuiet }]}>
        <SFSymbol
          name="doc"
          color={colors.textSecondary}
        />
        <View style={styles.attachmentText}>
          <Text style={[styles.attachmentName, { color: colors.textPrimary }]}>
            {name}
          </Text>
          <Text style={[styles.secondary, { color: colors.textSecondary }]}>
            {fileSize(t, sizeFormat, size)}
          </Text>
          {status === undefined ? null : (
            <Text
              accessibilityLiveRegion="polite"
              style={[styles.secondary, { color: colors.textSecondary }]}>
              {status}
            </Text>
          )}
          <View style={styles.actions}>{actions}</View>
        </View>
      </View>
    </ContextMenu>
  );
}

// A message can carry thousands of parts, so rows render in bounded batches.
const attachmentBatch = 20;

// The opened message's received attachments. Listing them downloads nothing; each downloads
// only when asked, and opens or shares through the system.
export function ReceivedAttachments({
  inbox,
  id,
  current,
  provider,
}: {
  readonly inbox: AttachmentSource;
  readonly id: string;
  readonly current: () => boolean;
  readonly provider: string | undefined;
}) {
  const colors = usePalette();
  const { t } = useLocalization();
  const attachments = useSyncExternalStore(inbox.subscribe, () =>
    inbox.messageAttachments(id),
  );
  // The expansion belongs to one Inbox and message; Gmail IDs repeat across mailboxes.
  const [expanded, setExpanded] = useState({
    inbox,
    id,
    count: attachmentBatch,
  });
  const shown =
    expanded.inbox === inbox && expanded.id === id
      ? expanded.count
      : attachmentBatch;
  if (attachments === undefined || attachments.length === 0) {
    return null;
  }
  return (
    <View style={[styles.attachments, { borderTopColor: colors.separator }]}>
      <Text
        accessibilityRole="header"
        style={[styles.secondary, { color: colors.textSecondary }]}>
        {t('attachment.count', { count: attachments.length })}
      </Text>
      <View style={styles.attachmentList}>
        {attachments.slice(0, shown).map((attachment) => (
          <AttachmentRow
            key={attachment.locator}
            inbox={inbox}
            id={id}
            attachment={attachment}
            current={current}
            provider={provider}
          />
        ))}
      </View>
      {attachments.length > shown ? (
        <Action
          label={t('attachment.more', {
            count: Math.min(attachmentBatch, attachments.length - shown),
          })}
          accessibilityLabel={t('attachment.moreLabel', {
            count: attachments.length - shown,
          })}
          onPress={() => {
            setExpanded({ inbox, id, count: shown + attachmentBatch });
          }}
        />
      ) : null}
    </View>
  );
}

// How readers inside show a body's quoted history: in full, or collapsed behind Show Quoted Text
// as the Thread view does.
export const QuotedHistoryContext = createContext<'shown' | 'collapsible'>(
  'shown',
);

// The failure sentence VoiceOver last heard for each of the Thread's messages, so a body scrolled
// away and back stays quiet until its failure changes or the person chooses Try Again.
export const AnnouncedFailuresContext = createContext<
  Map<string, string> | undefined
>(undefined);

// The iPad frame's six lines, as fractions of its 439pt column.
const placeholderLines = ['100%', '96%', '88%', '100%', '92%', '54%'] as const;

// Where the body will be while it opens, under the header that already shows. The iPad frame
// names the provider above still lines, so Reduce Motion has nothing to stop; the iPhone frame
// centres the indicator above its caption. VoiceOver hears either as one progress element.
export function BodyLoading({
  provider,
}: {
  // Undefined for an IMAP mailbox's server.
  readonly provider: string | undefined;
}) {
  const colors = usePalette();
  const { t } = useLocalization();
  if (!ipad) {
    return (
      <View
        accessible
        accessibilityLabel={t('messageBody.loading')}
        accessibilityRole="progressbar"
        style={styles.loading}>
        <ActivityIndicator />
        <Text style={[styles.secondary, { color: colors.textSecondary }]}>
          {t('messageBody.loading')}
        </Text>
      </View>
    );
  }
  const caption =
    provider === undefined
      ? t('messageBody.downloadingFrom', { context: 'imap' })
      : t('messageBody.downloadingFrom', { provider });
  return (
    <View style={styles.downloading}>
      <View
        accessible
        accessibilityLabel={caption}
        accessibilityRole="progressbar"
        style={styles.caption}>
        <ActivityIndicator />
        <Text style={[styles.captionText, { color: colors.textSecondary }]}>
          {caption}
        </Text>
      </View>
      <View style={styles.placeholders}>
        {placeholderLines.map((width, line) => (
          <View
            // oxlint-disable-next-line react/no-array-index-key -- A fixed list that never reorders.
            key={line}
            style={[
              styles.placeholder,
              { width, backgroundColor: colors.fillQuiet },
            ]}
          />
        ))}
      </View>
    </View>
  );
}

type UnavailableReason =
  | Extract<MessageBodyState, { kind: 'unavailable' }>['reason']
  | Extract<ImapBodyState, { kind: 'unavailable' }>['reason'];

// A body that cannot be shown, in the Schedule Banner recipe: the reason's sentence, which
// VoiceOver hears once after current speech, and Try Again unless the message is gone. A failed download says what
// each device's frame says.
export function BodyUnavailable({
  id,
  reason,
  provider,
  onTryAgain,
}: {
  readonly id: string;
  readonly reason: UnavailableReason;
  readonly provider: string | undefined;
  readonly onTryAgain: () => void;
}) {
  const colors = usePalette();
  const { t } = useLocalization();
  const scale = ipad ? ipadListScale : 1;
  const download = reason === 'download' || reason === 'imap-download';
  const sentence = t(`messageBody.${reason}`, {
    provider,
    ...(download ? { context: ipad ? 'ipad' : 'iphone' } : {}),
  });
  const announced = use(AnnouncedFailuresContext);
  // Queued, so a Thread's other failing messages never cut off what VoiceOver is saying.
  useEffect(() => {
    if (announced?.get(id) !== sentence) {
      announced?.set(id, sentence);
      AccessibilityInfo.announceForAccessibilityWithOptions(sentence, {
        queue: true,
      });
    }
  }, [announced, id, sentence]);
  return (
    <View
      style={[
        ipad ? styles.padBanner : styles.banner,
        { backgroundColor: colors.fillQuiet },
      ]}>
      <View style={styles.marker}>
        <SFSymbol
          name="exclamationmark.triangle.fill"
          color={colors.statusWarning}
          size={13 * scale}
        />
        <Text
          style={[
            ipad ? styles.padBannerTitle : styles.bannerTitle,
            { color: colors.textPrimary },
          ]}>
          {t('messageBody.unavailable')}
        </Text>
      </View>
      <Text
        accessibilityRole="alert"
        style={[
          ipad ? styles.padBannerText : styles.bannerText,
          { color: colors.textSecondary },
        ]}>
        {sentence}
      </Text>
      {reason === 'missing' || reason === 'imap-missing' ? null : (
        <Host matchContents>
          <Button
            onPress={() => {
              announced?.delete(id);
              onTryAgain();
            }}
            modifiers={[buttonStyle('plain')]}>
            {/* The frame's 28pt capsule, inside a 44pt touch target. */}
            <SwiftUIText
              modifiers={[
                ipad
                  ? font({ size: 13 * scale, weight: 'semibold' })
                  : font({ textStyle: 'footnote', weight: 'semibold' }),
                foregroundStyle(colors.textPrimary),
                padding({
                  horizontal: spacing.m * scale,
                  vertical: 6 * scale,
                }),
                background(colors.fillTrack, shapes.capsule()),
                frame({ minHeight: 44 }),
                contentShape(shapes.rectangle()),
              ]}>
              {t('common.retry')}
            </SwiftUIText>
          </Button>
        </Host>
      )}
    </View>
  );
}

// The opened Gmail message's body, from this device or downloaded on demand. Links open only
// after the person confirms the destination shown here.
export function GmailMessageBody({
  inbox,
  id,
  subject,
  connection,
}: {
  readonly inbox: GmailInbox;
  readonly id: string;
  // Read by an explicitly requested summary with the body.
  readonly subject?: string | undefined;
  // The Mailbox Connection whose remote content policy applies.
  readonly connection?: string | undefined;
}) {
  const { t } = useLocalization();
  const quotes = use(QuotedHistoryContext);
  const [quotedRevision, setQuotedRevision] = useState(0);
  const quotedShown = quotedRevision % 2 === 1;
  const provider = useProviderName();
  // oxlint-disable-next-line react/hook-use-state -- This immutable reader identity has no setter.
  const [reader] = useState(() => Symbol('message reader'));
  const remoteImages = useRemoteImages({
    inbox,
    id,
    reader,
    connection,
    current,
  });
  const body = useSyncExternalStore(inbox.subscribe, () =>
    inbox.messageBody(id, reader),
  );
  const confirm = use(LinkConfirmationContext);
  // The message this reader shows, cleared as soon as it changes or closes, so input queued for a
  // previous message is recognized before any passive cleanup runs.
  const showing = useRef<{
    readonly inbox: GmailInbox;
    readonly id: string;
    readonly quotedRevision: number;
  }>(undefined);
  useLayoutEffect(() => {
    showing.current = { inbox, id, quotedRevision };
    return () => {
      showing.current = undefined;
    };
  }, [inbox, id, quotedRevision]);
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
      confirm?.(withoutLinkFrom(inbox, id));
    };
  }, [body, confirm, inbox, id]);

  if (body === undefined || body.kind === 'loading') {
    return <BodyLoading provider={provider} />;
  }

  if (body.kind === 'unavailable') {
    return (
      <BodyUnavailable
        id={id}
        reason={body.reason}
        provider={provider}
        onTryAgain={() => {
          void inbox.readMessage(id);
        }}
      />
    );
  }

  // Native input can be queued before the owner changes and delivered afterward, so a stale
  // choice shows nothing.
  function current() {
    return (
      showing.current?.inbox === inbox &&
      showing.current.id === id &&
      showing.current.quotedRevision === quotedRevision &&
      inbox.messageBody(id, reader) === body
    );
  }
  const { withoutQuotedHistory } = body.presentation;
  const collapsible =
    quotes === 'collapsible' && withoutQuotedHistory !== undefined;
  return (
    <View style={styles.body}>
      <AssistanceRow>
        <MessageSummary
          source={inbox}
          id={id}
          subject={subject}
          body={body.presentation.readable}
        />
        <MessageTranslation
          source={inbox}
          id={id}
          body={body.presentation.readable}
        />
      </AssistanceRow>
      <InvitationCard
        inbox={inbox}
        id={id}
        connection={connection}
        current={current}
      />
      <Presentation
        onCopy={(link) => {
          if (current()) {
            void setStringAsync(link.href);
          }
        }}
        presentation={
          collapsible && !quotedShown ? withoutQuotedHistory : body.presentation
        }
        onNear={remoteImages.handleNear}
        onLoadImages={remoteImages.handleLoadImages}
        onFailure={() => {
          if (current()) {
            inbox.discardRichMessage(id, body.presentation, reader);
          }
        }}
        onChoose={(link) => {
          if (current()) {
            confirm?.({ inbox, id, link, current, subscribe: inbox.subscribe });
          }
        }}
      />
      {collapsible ? (
        <Action
          expanded={quotedShown}
          label={
            quotedShown
              ? t('messageBody.hideQuoted')
              : t('messageBody.showQuoted')
          }
          onPress={() => {
            if (current() && showing.current !== undefined) {
              confirm?.(withoutLinkFrom(inbox, id));
              const next = quotedRevision + 1;
              showing.current = { ...showing.current, quotedRevision: next };
              setQuotedRevision(next);
            }
          }}
        />
      ) : null}
      <ReceivedAttachments
        inbox={inbox}
        id={id}
        current={current}
        provider={provider}
      />
    </View>
  );
}

// The reader's Summarize and Translate row. While neither can run, it takes no place, so the body
// keeps the reader's 16pt rhythm beneath the message header.
export function AssistanceRow({ children }: { readonly children: ReactNode }) {
  const assistance = use(AssistanceContext);
  const translation = use(TranslationContext);
  return assistance === undefined && translation === undefined ? null : (
    <View style={styles.assistance}>{children}</View>
  );
}
