import { hasTaggedIMAPResponse } from '../src/protocol.ts';

describe('imap tagged response framing', () => {
  it('recognizes a tagged completion on the first response line', () => {
    expect.assertions(1);

    expect(hasTaggedIMAPResponse('a001 OK LOGIN completed\r\n', 'a001')).toBe(
      true,
    );
  });
});
