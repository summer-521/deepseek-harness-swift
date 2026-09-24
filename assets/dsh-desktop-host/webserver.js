import { Service } from "@deepseek-ai/cordis";
import UpstreamWebServer from "@deepseek-ai/dsh-host-webserver";
import {
  CLASSIFICATIONS,
  accessState,
  decideRequest,
  hasReservedDesktopParameter,
  isAdmittedAccountCallback,
  requestPassesLoopbackFence,
} from "./access-state.js";
import { markDesktopServerReady, startDesktopControl } from "./control.js";
import { captureConnection, createBrowserHandoffRoute, createBrowserURLRoute } from "./browser-url-route.js";
import { createLanHTTPIngress } from "./lan-http-ingress.js";
import { NETWORK_EXPOSURES } from "./access-state.js";
import { createLanURLRoute } from "./lan-url-route.js";

const FORBIDDEN_BODY = "forbidden";
const REQUIRED_UPSTREAM_METHODS = ["register", "registerFallback", "registerUpgrade"];

if (
  typeof UpstreamWebServer !== "function" ||
  REQUIRED_UPSTREAM_METHODS.some((method) => typeof UpstreamWebServer.prototype[method] !== "function")
) {
  throw new Error("dsh desktop webserver API is incompatible with the installed DSH runtime");
}

function forbiddenHeaders() {
  return {
    "cache-control": "no-store",
    "content-type": "text/plain; charset=utf-8",
    "x-content-type-options": "nosniff",
    "content-length": String(Buffer.byteLength(FORBIDDEN_BODY)),
    connection: "close",
  };
}

function rejectHttp(res) {
  if (res.headersSent) {
    res.destroy();
    return;
  }
  res.writeHead(403, forbiddenHeaders());
  res.end(FORBIDDEN_BODY);
}

function rejectUpgrade(socket) {
  if (!socket.destroyed) {
    socket.end(
      `HTTP/1.1 403 Forbidden\r\nCache-Control: no-store\r\nContent-Type: text/plain; charset=utf-8\r\nX-Content-Type-Options: nosniff\r\nContent-Length: ${String(Buffer.byteLength(FORBIDDEN_BODY))}\r\nConnection: close\r\n\r\n${FORBIDDEN_BODY}`,
    );
  }
}

function requestAllowed(request, classification, state) {
  if (classification === CLASSIFICATIONS.denied) {
    // Exactly one route may pass without a credential: the Platform sign-in
    // callback. It arrives as a top-level redirect from the configured Platform
    // origin, so it can never carry the renderer cookie, and the provider
    // authenticates the attempt itself with `state` plus the PKCE verifier.
    // The caller is trusted for nothing — the path, the method and the
    // parameter shape are the whole exception.
    return isAdmittedAccountCallback(request, state);
  }
  if (!requestPassesLoopbackFence(request, state)) return false;
  if (classification !== CLASSIFICATIONS.renderer && hasReservedDesktopParameter(request.url)) return false;
  return true;
}

/**
 * The access check lives at the carrier boundary. Every route registration,
 * fallback, and HTTP upgrade therefore shares the same decision before the
 * upstream handler receives the request.
 */
export default class DesktopWebServer extends UpstreamWebServer {
  constructor(ctx, config) {
    if (config?.host !== "127.0.0.1") throw new Error("dsh desktop webserver must bind to 127.0.0.1");
    super(ctx, config);
    startDesktopControl();
    const getConnection = captureConnection(ctx);
    this.register(createBrowserURLRoute(getConnection));
    this.register(createBrowserHandoffRoute());
    this.register(createLanURLRoute());
    this.lanIngress = createLanHTTPIngress({ backendPort: config.port, state: accessState, getConnection });
    this.unsubscribePolicy = accessState.observePolicy(async ({ ordinaryBrowserEnabled, networkExposure }) => {
      if (!ordinaryBrowserEnabled) accessState.closeOrdinarySockets();
      if (ordinaryBrowserEnabled && networkExposure === NETWORK_EXPOSURES.lan) {
        await this.lanIngress.start();
        accessState.attachLanIngress(this.lanIngress);
      } else {
        await this.lanIngress.stop();
        accessState.detachLanIngress(this.lanIngress);
      }
    });
    ctx.effect(() => () => {
      this.unsubscribePolicy();
      accessState.detachLanIngress(this.lanIngress);
      void this.lanIngress.stop();
    }, "dsh desktop access policy");
  }

  register(route) {
    return super.register({
      ...route,
      handler: (request, response) => {
        const classification = decideRequest(request, accessState);
        if (!requestAllowed(request, classification, accessState)) {
          rejectHttp(response);
          return;
        }
        return route.handler(request, response);
      },
    });
  }

  registerFallback(handler) {
    return super.registerFallback((request, response) => {
      const classification = decideRequest(request, accessState);
      if (!requestAllowed(request, classification, accessState)) {
        rejectHttp(response);
        return;
      }
      return handler(request, response);
    });
  }

  registerUpgrade(route) {
    return super.registerUpgrade({
      ...route,
      handler: (request, socket, head) => {
        const classification = decideRequest(request, accessState);
        // An upgrade is never the sign-in callback: the one exception the gate
        // carries is for a single HTTP GET, so this boundary keeps the strict
        // rule and an unclassified socket is still refused.
        if (classification === CLASSIFICATIONS.denied
            || !requestAllowed(request, classification, accessState)) {
          rejectUpgrade(socket);
          return;
        }
        if (classification === CLASSIFICATIONS.browser) accessState.trackOrdinarySocket(socket);
        return route.handler(request, socket, head);
      },
    });
  }

  async [Service.init]() {
    await super[Service.init]();
    accessState.port = this.port;
    if (accessState.ordinaryBrowserEnabled && accessState.networkExposure === NETWORK_EXPOSURES.lan) {
      await this.lanIngress.start();
      accessState.attachLanIngress(this.lanIngress);
    }
    markDesktopServerReady();
  }
}
