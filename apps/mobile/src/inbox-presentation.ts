import type { ReactNode } from 'react';
import type { ScrollViewProps } from 'react-native';

import { useRef, useState } from 'react';

export type InboxLayout = (
  content: ReactNode,
  onBack: (() => void) | undefined,
) => ReactNode;

// The native Inbox content can be recreated without retiring its presentation owner.
export function useInboxPresentation({
  onBack,
  children,
}: {
  readonly onBack: (() => void) | undefined;
  readonly children: InboxLayout | undefined;
}) {
  const scrollPosition = useRef({ x: 0, y: 0 });
  const [contentOffset, setContentOffset] = useState({ x: 0, y: 0 });
  const back =
    onBack === undefined
      ? undefined
      : () => {
          setContentOffset(scrollPosition.current);
          onBack();
        };
  const onScroll: ScrollViewProps['onScroll'] = ({ nativeEvent }) => {
    scrollPosition.current = nativeEvent.contentOffset;
  };
  return {
    back,
    contentOffset,
    onScroll,
    render: (content: ReactNode) =>
      children === undefined ? content : children(content, back),
  };
}
