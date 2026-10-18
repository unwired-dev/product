import type { ReactElement, ReactNode } from 'react';
import type { ScrollViewProps } from 'react-native';

import { useRef, useState } from 'react';

export type InboxLayout = (
  content: Readonly<ReactElement>,
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
  const handleBack =
    onBack === undefined
      ? undefined
      : () => {
          setContentOffset(scrollPosition.current);
          onBack();
        };
  const handleScroll: ScrollViewProps['onScroll'] = ({ nativeEvent }) => {
    scrollPosition.current = nativeEvent.contentOffset;
  };
  return {
    handleBack,
    contentOffset,
    handleScroll,
    render: (content: Readonly<ReactElement>) =>
      children === undefined ? content : children(content, handleBack),
  };
}
