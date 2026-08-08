import { hasTaggedIMAPResponse } from '../src/protocol.ts';

describe('imap tagged response framing', () => {
  it('recognizes a tagged completion on the first response line', () => {
    expect.assertions(1);

    expect(hasTaggedIMAPResponse('a001 OK LOGIN completed\r\n', 'a001')).toBe(
      true,
    );
  });

  it('recognizes a tagged completion after untagged responses', () => {
    expect.assertions(1);

    expect(
      hasTaggedIMAPResponse(
        '* 1 EXISTS\r\n* 0 RECENT\r\na001 OK SELECT completed\r\n',
        'a001',
      ),
    ).toBe(true);
  });

  it('does not match a tag prefix collision', () => {
    expect.assertions(1);

    expect({
      matches: hasTaggedIMAPResponse('a0010 OK completed\r\n', 'a001'),
    }).toStrictEqual({ matches: false });
  });
});
