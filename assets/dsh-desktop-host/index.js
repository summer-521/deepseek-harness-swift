import { accessState } from "./access-state.js";
import { startDesktopControl } from "./control.js";

export const name = "dsh-desktop-host";

// Control protocol line the shell reads as an action rather than as log
// content. Keeping it on stdout reuses the channel the shell already drains for
// readiness and policy acknowledgements, so the browser handoff needs no second
// transport; the shell matches the whole line and keeps it out of its log.
export const OPEN_EXTERNAL_PREFIX = "dsh desktop open external: ";

// The attempt whose URL was announced. The account state stream re-yields the
// same attempt on every unrelated change, and the browser must open once per
// attempt, not once per frame.
let announcedAttemptId;

/**
 * Report the Platform authorization page of a sign-in that is waiting for the
 * browser. The account provider validates `authorize_url` against the
 * configured Platform origin before it appears in this state, and the shell
 * re-checks it again before opening anything.
 * @param view - one account state frame from the provider.
 */
function announceSignIn(view) {
  if (!accessState.managedLaunch) return;
  const attempt = view?.attempt;
  if (attempt?.phase !== "waiting-browser") return;
  const authorizeUrl = attempt.authorizeUrl;
  if (typeof authorizeUrl !== "string" || authorizeUrl.length === 0) return;
  if (announcedAttemptId === attempt.id) return;
  // A control line is newline-delimited: never carry a character that could
  // make one URL look like two.
  if (/[\u0000-\u0020\u007f]/.test(authorizeUrl)) return;
  announcedAttemptId = attempt.id;
  process.stdout.write(`${OPEN_EXTERNAL_PREFIX}${authorizeUrl}\n`);
}

// The profile Loader imports this entry after the replacement webserver. Start
// control eagerly as a second, idempotent safety net; the webserver constructor
// also starts it so requests remain denied during any activation ordering.
export function apply(ctx) {
  startDesktopControl();
  // The account provider is optional by design: this bridge must come up in a
  // Profile that has no account plugin at all, so the service is injected
  // rather than declared as a dependency.
  ctx.inject(["deepseekAccount"], (scope) => {
    const lifetime = new AbortController();
    scope.effect(() => () => lifetime.abort(), "dsh desktop sign-in watch");
    void (async () => {
      for await (const view of scope.deepseekAccount.watch(lifetime.signal)) announceSignIn(view);
    })().catch(() => undefined);
  });
}
