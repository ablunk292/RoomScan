// Linked from the App Store subscription screen and the App Store listing, so it is public.
export default function Privacy() {
  return (
    <main className="page privacy">
      <h1>RoomScan Privacy Policy</h1>
      <p className="muted">Last updated November 15, 2026</p>

      <h2>What RoomScan stores</h2>
      <p>
        RoomScan keeps the walkthroughs you create: property names and addresses, customer names you enter,
        room outlines and measurements, items, notes and item photos. On your iPhone they are stored on the
        device. When you sign in, they are also stored in your company's QuoteMaster account so you can edit
        them on the web and turn them into quotes. Only people in your company can see them.
      </p>

      <h2>Your account</h2>
      <p>
        You sign in with your QuoteMaster account (email and password, Google or Microsoft). RoomScan uses your
        email address and account ID to sign you in and to link a subscription to your account.
      </p>

      <h2>Camera and AI</h2>
      <p>
        RoomScan uses the camera to measure rooms. When you run an AI item scan or use the AI helper, the photo
        or walkthrough details are sent to our server and to Anthropic, which provides the AI model, to find
        and describe items. They are used only to answer that request. The camera image is not recorded
        otherwise.
      </p>

      <h2>Purchases</h2>
      <p>
        Subscriptions bought in the app are handled by Apple. RoomScan receives the subscription's status
        and expiry date from Apple to unlock RoomScan Pro. It never sees your payment details.
      </p>

      <h2>What we don't do</h2>
      <p>RoomScan does not sell your data, show ads, or track you across other apps and websites.</p>

      <h2>Deleting your data</h2>
      <p>
        Delete a walkthrough in the app or on the web to remove it and its photos. To delete your account and
        everything in it, contact your QuoteMaster account administrator or QuoteMaster support.
      </p>
    </main>
  );
}
