import type { FastifyPluginAsync } from "fastify";
import { z } from "zod";
import { env } from "../config/env.js";
import {
  completeOtpSession,
  createDeactivationChallenge,
  createOtpSession,
  disableUserWithSignature,
  findOtpSession,
} from "../db/repositories.js";
import { VaultConnectionError } from "../services/VaultService.js";
import { requireAppApiKey } from "../utils/auth.js";
import { RateLimiter, otpRequestLimiter, otpVerifyLimiter, resetAllRateLimiters } from "../utils/rateLimit.js";

// Export for testing
export { resetAllRateLimiters };

const otpRequestSchema = z.object({
  domain: z.string().min(1),
  user_email: z.string().email(),
});

const otpVerifySchema = z.object({
  userId: z.string().min(1),
  otp: z.string().min(1),
  domain: z.string().min(1),
  userWallet: z.string().min(1),
  userWalletSignature: z.string().min(1),
});

const deactivateSchema = z.object({
  userWalletSignature: z.string().min(1),
});

export const otpRoutes: FastifyPluginAsync = async (app) => {
  app.addHook("onRequest", async (request, reply) => {
    if (!requireAppApiKey(request, reply)) {
      return;
    }
  });

  // Rate limiting via preHandler - apply to all OTP routes
  app.addHook("preHandler", async (request, reply) => {
    const path = request.url;

    // Rate limit /otp/request by IP
    if (path === "/otp/request") {
      const ip = request.ip || (request.headers["x-forwarded-for"] as string) || "unknown";
      const key = `otp_request:${ip}`;

      if (!otpRequestLimiter.isAllowed(key)) {
        const retryAfter = otpRequestLimiter.getRetryAfter(key);
        reply.header("Retry-After", retryAfter);
        return reply.status(429).send({
          error: "rate_limit_exceeded",
          message: `Too many OTP requests. Limit: 5 per minute. Try again in ${retryAfter} seconds.`,
        });
      }
    }

    // Rate limit /otp/verify by userId
    if (path === "/otp/verify") {
      if (request.body) {
        const body = parseJsonStringBody(request.body) as Record<string, unknown> | undefined;
        const userId = body?.userId as string | undefined;

        if (userId) {
          const key = `otp_verify:${userId}`;

          if (!otpVerifyLimiter.isAllowed(key)) {
            const retryAfter = otpVerifyLimiter.getRetryAfter(key);
            reply.header("Retry-After", retryAfter);
            return reply.status(429).send({
              error: "rate_limit_exceeded",
              message: `Too many OTP verification attempts. Limit: 10 per 15 minutes. Try again in ${retryAfter} seconds.`,
            });
          }
        }
      }
    }
  });

  app.post("/otp/request", async (request, reply) => {
    const parsedBody = otpRequestSchema.safeParse(parseJsonStringBody(request.body));

    if (!parsedBody.success) {
      return reply.status(400).send({
        error: "invalid_request",
        message: "Request body must be a JSON object with domain and user_email.",
      });
    }

    const body = parsedBody.data;

    if (emailDomain(body.user_email) !== env.DOMAIN.trim().toLowerCase()) {
      return reply.status(400).send({
        error: "invalid_email_domain",
        message: `user_email must belong to ${env.DOMAIN}.`,
      });
    }

    let session;

    try {
      session = await createOtpSession({
        domain: body.domain,
        userEmail: body.user_email,
        ttlMs: env.OTP_TTL_MS,
      });
    } catch (error) {
      if (error instanceof Error && error.message.includes("is already registered")) {
        return reply.status(409).send({
          error: "user_email_exists",
          message: error.message,
        });
      }

      throw error;
    }

    return reply.status(201).send({
      userId: session.userId,
      expiresAt: session.expiresAt,
      domain: session.domain,
      userEmail: session.userEmail,
      // The wallet claimed at /otp/verify must sign this nonce to prove
      // possession of its private key.
      walletNonce: session.walletNonce,
    });
  });

  app.get("/otp/:userId", async (request, reply) => {
    const userId = z
      .string()
      .min(1)
      .parse((request.params as { userId: string }).userId);
    const session = await findOtpSession(userId);

    if (!session) {
      return reply.status(404).send({
        error: "not_found",
        message: "No OTP session found.",
      });
    }

    return {
      userId: session.userId,
      domain: session.domain,
      userEmail: session.userEmail,
      userWallet: session.userWallet,
      adminWallet: session.adminWallet,
      txDigest: session.txDigest,
      userCapId: session.userCapId,
      status: session.status,
      createdAt: session.createdAt,
      expiresAt: session.expiresAt,
      verifiedAt: session.verifiedAt,
      error: session.error,
    };
  });

  // Self-service account deletion: when a user deletes the app's local
  // copy of their account, nothing previously told the server, so it and
  // the chain kept listing them as active indefinitely. The app API key
  // alone used to authorize this, but that static key is extractable from
  // any app build and never proved the request came from the account
  // owner, so deactivation now follows a challenge-response: the wallet
  // registered to the account must sign a short-lived, single-use
  // server-issued nonce before anything is disabled.
  app.post("/otp/:userId/deactivate/challenge", async (request, reply) => {
    const userId = z
      .string()
      .min(1)
      .parse((request.params as { userId: string }).userId);
    const challenge = await createDeactivationChallenge(userId);

    if (!challenge) {
      return reply.status(404).send({
        error: "not_found",
        message: "No user found.",
      });
    }

    return reply.status(201).send({
      userId: challenge.userId,
      nonce: challenge.nonce,
      expiresAt: challenge.expiresAt,
    });
  });

  app.patch("/otp/:userId/deactivate", async (request, reply) => {
    const userId = z
      .string()
      .min(1)
      .parse((request.params as { userId: string }).userId);
    const parsedBody = deactivateSchema.safeParse(parseJsonStringBody(request.body));

    if (!parsedBody.success) {
      return reply.status(400).send({
        error: "invalid_request",
        message: "Request body must be a JSON object with userWalletSignature.",
      });
    }

    let user;

    try {
      user = await disableUserWithSignature({
        userId,
        userWalletSignature: parsedBody.data.userWalletSignature,
      });
    } catch (error) {
      if (
        error instanceof Error &&
        (error.message === "No deactivation challenge found." ||
          error.message === "Deactivation challenge expired." ||
          error.message === "Deactivation challenge already used." ||
          error.message === "userWalletSignature does not match the registered wallet.")
      ) {
        return reply.status(401).send({
          error: "invalid_signature",
          message: error.message,
        });
      }

      throw error;
    }

    if (!user) {
      return reply.status(404).send({
        error: "not_found",
        message: "No user found.",
      });
    }

    return reply.send({
      message: "User disabled successfully.",
      user,
    });
  });

  app.post("/otp/verify", async (request, reply) => {
    // Rate limit verify attempts by userId (check before validation)
    const rawBody = parseJsonStringBody(request.body) as Record<string, unknown> | undefined;
    const userIdForRateLimit = rawBody?.userId as string | undefined;

    if (userIdForRateLimit) {
      const key = `otp_verify:${userIdForRateLimit}`;

      if (!otpVerifyLimiter.isAllowed(key)) {
        const retryAfter = otpVerifyLimiter.getRetryAfter(key);
        reply.header("Retry-After", retryAfter);
        return reply.status(429).send({
          error: "rate_limit_exceeded",
          message: `Too many OTP verification attempts. Limit: 10 per 15 minutes. Try again in ${retryAfter} seconds.`,
        });
      }
    }

    const parsedBody = otpVerifySchema.safeParse(rawBody);

    if (!parsedBody.success) {
      return reply.status(400).send({
        error: "invalid_request",
        message: "Request body must be a JSON object with userId, otp, domain, userWallet, and userWalletSignature.",
      });
    }

    const body = parsedBody.data;

    let session;

    try {
      session = await completeOtpSession(body);
    } catch (error) {
      if (error instanceof Error) {
        if (error.message === "OTP already used.") {
          return reply.status(409).send({
            error: "otp_already_used",
            message: error.message,
          });
        }

        if (
          error.message === "OTP is invalid." ||
          error.message === "OTP expired." ||
          error.message === "userWallet must be a Sui address." ||
          error.message === "userWallet does not match the OTP session." ||
          error.message.startsWith("This container is configured for")
        ) {
          return reply.status(400).send({
            error: "otp_verification_failed",
            message: error.message,
          });
        }

        if (error.message.startsWith("No OTP session for")) {
          return reply.status(404).send({
            error: "not_found",
            message: error.message,
          });
        }

        if (error instanceof VaultConnectionError) {
          return reply.status(502).send({
            error: "vault_unavailable",
            message: `Vault is unavailable at ${error.address ?? "<unset>"}. Check VAULT_ADDR and ensure the Vault service is running.`,
          });
        }

        const suiHttpStatus = readSuiHttpStatus(error);
        if (suiHttpStatus != null) {
          return reply.status(502).send({
            error: "sui_rpc_failed",
            message: `Sui RPC request failed (${suiHttpStatus.status} ${suiHttpStatus.statusText}). Check SUI_RPC_URL and SUI_NETWORK configuration.`,
          });
        }
      }

      throw error;
    }

    return reply.send({
      userId: session.userId,
      domain: session.domain,
      userWallet: session.userWallet,
      txDigest: session.txDigest,
      userCapId: session.userCapId,
      status: session.status,
      verifiedAt: session.verifiedAt,
    });
  });
};

function emailDomain(email: string): string {
  const normalized = email.trim().toLowerCase();
  const atIndex = normalized.lastIndexOf("@");

  return atIndex === -1 ? "" : normalized.slice(atIndex + 1);
}

function parseJsonStringBody(body: unknown): unknown {
  if (typeof body !== "string") {
    return body;
  }

  try {
    return JSON.parse(body);
  } catch {
    return body;
  }
}

function readSuiHttpStatus(error: Error): { status: number; statusText: string } | null {
  const candidate = error as Error & { status?: unknown; statusText?: unknown };

  if (typeof candidate.status !== "number") {
    return null;
  }

  return {
    status: candidate.status,
    statusText: typeof candidate.statusText === "string" ? candidate.statusText : "Unknown",
  };
}
