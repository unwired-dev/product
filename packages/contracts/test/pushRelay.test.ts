import { devicePushRegistrationResponseFixture } from '@private-email/contracts/pushRelay';

describe('device push registration response contract', () => {
  it('uses the shared registration response fixture shape', () => {
    expect.assertions(1);

    expect(devicePushRegistrationResponseFixture).toStrictEqual({
      registered: true,
    });
  });
});
