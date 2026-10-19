import type { InboxFilter } from '@private-email/mail-core/mailboxes';
import type { ReactElement, ReactNode, RefCallback } from 'react';
import type { ScrollViewProps, SectionList } from 'react-native';

import { useCallback, useLayoutEffect, useRef, useState } from 'react';

import type { MailboxView } from './sidebar.tsx';

type Position = Readonly<NonNullable<ScrollViewProps['contentOffset']>>;
type Size = Readonly<{ width: number; height: number }>;
type List = Pick<SectionList<unknown>, 'getScrollResponder'>;
type Restoration = Readonly<{
  target: Position;
  viewport: Size;
  content: Size;
}>;

const top: Position = { x: 0, y: 0 };
const unmeasured: Size = { width: 0, height: 0 };
const fits = ({ target, viewport, content }: Restoration) =>
  viewport.width > 0 &&
  viewport.height > 0 &&
  content.width > 0 &&
  content.height > 0 &&
  target.x <= Math.max(0, content.width - viewport.width) &&
  target.y <= Math.max(0, content.height - viewport.height);

export type InboxLayout = (
  content: Readonly<ReactElement>,
  onBack: (() => void) | undefined,
) => ReactNode;

// The native Inbox content can be recreated without retiring its presentation owner.
export function useInboxPresentation({
  onBack,
  children,
  view,
  search,
  filtering,
}: {
  readonly onBack: (() => void) | undefined;
  readonly children: InboxLayout | undefined;
  readonly view: MailboxView;
  readonly search: Readonly<{
    searching: boolean;
    searched: string;
    searchesAll: boolean;
  }>;
  readonly filtering: Readonly<{ on: boolean; filter: InboxFilter }>;
}) {
  const query = search.searching ? search.searched : undefined;
  const filter = filtering.on ? filtering.filter : undefined;
  const all = search.searchesAll;
  const scrollPosition = useRef(top);
  const savedPosition = useRef(top);
  const list = useRef<List | null>(null);
  const restoring = useRef<Restoration | undefined>(undefined);
  const [snapshot, setSnapshot] = useState({
    view,
    query,
    filter,
    all,
    offset: top,
  });
  const sameScope =
    snapshot.view === view &&
    snapshot.query === query &&
    snapshot.filter === filter &&
    snapshot.all === all;
  if (!sameScope) {
    setSnapshot({ view, query, filter, all, offset: top });
  }
  const contentOffset = sameScope ? snapshot.offset : top;

  useLayoutEffect(() => {
    restoring.current = undefined;
    savedPosition.current = top;
    scrollPosition.current = top;
    // oxlint-disable-next-line react/exhaustive-effect-dependencies -- A changed list scope retires its saved native position.
  }, [view, query, filter, all]);

  const handleList = useCallback<RefCallback<List>>((current) => {
    list.current = current;
    const target = savedPosition.current;
    restoring.current =
      current === null || (target.x === 0 && target.y === 0)
        ? undefined
        : { target, viewport: unmeasured, content: unmeasured };
  }, []);

  const restoreScroll = () => {
    const pending = restoring.current;
    if (pending !== undefined && fits(pending)) {
      list.current?.getScrollResponder()?.scrollTo({
        ...pending.target,
        animated: false,
      });
    }
  };
  const handleLayout: ScrollViewProps['onLayout'] = ({ nativeEvent }) => {
    const pending = restoring.current;
    if (pending !== undefined) {
      restoring.current = { ...pending, viewport: nativeEvent.layout };
      restoreScroll();
    }
  };
  const handleContentSizeChange: ScrollViewProps['onContentSizeChange'] = (
    width,
    height,
  ) => {
    const pending = restoring.current;
    if (pending !== undefined) {
      restoring.current = { ...pending, content: { width, height } };
      restoreScroll();
    }
  };
  const handleBack =
    onBack === undefined
      ? undefined
      : () => {
          const offset = restoring.current?.target ?? scrollPosition.current;
          const saved = { x: Math.max(0, offset.x), y: Math.max(0, offset.y) };
          savedPosition.current = saved;
          setSnapshot({ view, query, filter, all, offset: saved });
          onBack();
        };
  const handleScroll: ScrollViewProps['onScroll'] = ({ nativeEvent }) => {
    if (list.current === null) {
      return;
    }
    scrollPosition.current = nativeEvent.contentOffset;
    const pending = restoring.current;
    if (
      pending !== undefined &&
      nativeEvent.contentOffset.x === pending.target.x &&
      nativeEvent.contentOffset.y === pending.target.y &&
      fits({
        target: pending.target,
        viewport: nativeEvent.layoutMeasurement,
        content: nativeEvent.contentSize,
      })
    ) {
      restoring.current = undefined;
    }
  };
  const handleScrollBeginDrag: ScrollViewProps['onScrollBeginDrag'] = ({
    nativeEvent,
  }) => {
    restoring.current = undefined;
    scrollPosition.current = nativeEvent.contentOffset;
  };
  return {
    handleBack,
    contentOffset,
    handleList,
    handleLayout,
    handleContentSizeChange,
    handleScroll,
    handleScrollBeginDrag,
    render: (content: Readonly<ReactElement>) =>
      children === undefined ? content : children(content, handleBack),
  };
}
