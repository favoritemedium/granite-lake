import { beforeEach, describe, expect, it, vi, afterEach } from "vitest";

process.env.DOMAIN = "acme.com";
process.env.CLIENT_ID = "acme";
process.env.ADMIN_WALLET = "0xabc";
process.env.ADMIN_API_KEY = "admin-key";
process.env.APP_API_KEY = "app-key";
process.env.SUI_NETWORK = "testnet";
process.env.SUI_RPC_URL = "https://fullnode.testnet.sui.io:443";
process.env.SUI_PRIVATE_KEY = "suiprivkey-test";
process.env.SUI_PACKAGE_ID = "0xpackage";
process.env.SUI_REGISTRY_ID = "0xregistry";

const APP_API_KEY_HEADERS = { "x-app-api-key": "app-key" };

const createOtpSession = vi.fn(async (input) => ({
  userId: "user-id-1",
  domain: input.domain,
  userEmail: input.userEmail,
  userWallet: input.userWallet,
  adminWallet: "0xabc",
  otpHash: "otp-hash",
  walletNonce: "test-nonce",
  status: "pending_verification",
  createdAt: new Date().toISOString(),
  expiresAt: new Date().toISOString(),
  verifiedAt: null,
  txDigest: null,
  userCapId: null,
  error: null,
}));

const completeOtpSession = vi.fn();
const createDeactivationChallenge = vi.fn();
const disableUserWithSignature = vi.fn();

vi.mock("../src/db/repositories.js", () => ({
  completeOtpSession,
  createDeactivationChallenge,
  createOtpSession,
  disableUserWithSignature,
  enableUser: vi.fn(),
  findOtpSession: vi.fn(),
  listUsers: vi.fn(async () => []),
}));

const { buildApp } = await import("../src/app.js");

describe("otp routes", () => {
  beforeEach(async () => {
    vi.clearAllMocks();
    // Reset rate limiters before each test
    const { resetAllRateLimiters } = await import("../src/utils/rateLimit.js");
    resetAllRateLimiters();
  });

  it("rejects requests without an app API key", async () => {
    const app = await buildApp();

    const response = await app.inject({
      method: "POST",
      url: "/otp/request",
      payload: {
        domain: "acme.com",
        user_email: "alice@acme.com",
        user_wallet: "0x1111111111111111111111111111111111111111111111111111111111111111",
      },
    });

    expect(response.statusCode).toBe(401);
    expect(response.json()).toEqual({
      error: "unauthorized",
      message: "Invalid app API key.",
    });
    expect(createOtpSession).not.toHaveBeenCalled();

    await app.close();
  });

  it("rejects requests with an invalid app API key", async () => {
    const app = await buildApp();

    const response = await app.inject({
      method: "POST",
      url: "/otp/verify",
      headers: { "x-app-api-key": "wrong-key" },
      payload: {
        userId: "user-id-1",
        otp: "123456",
        domain: "acme.com",
        userWallet: "0x1111111111111111111111111111111111111111111111111111111111111111",
        userWalletSignature: "test-signature",
      },
    });

    expect(response.statusCode).toBe(401);
    expect(response.json()).toEqual({
      error: "unauthorized",
      message: "Invalid app API key.",
    });
    expect(completeOtpSession).not.toHaveBeenCalled();

    await app.close();
  });

  it("requests an OTP for a domain email without returning the OTP", async () => {
    const app = await buildApp();

    const response = await app.inject({
      method: "POST",
      url: "/otp/request",
      headers: APP_API_KEY_HEADERS,
      payload: {
        domain: "acme.com",
        user_email: "alice@acme.com",
        user_wallet: "0x1111111111111111111111111111111111111111111111111111111111111111",
      },
    });

    expect(response.statusCode).toBe(201);
    expect(createOtpSession).toHaveBeenCalledWith({
      domain: "acme.com",
      userEmail: "alice@acme.com",
      userWallet: "0x1111111111111111111111111111111111111111111111111111111111111111",
      ttlMs: 300000,
    });
    const body = response.json();
    expect(body).toHaveProperty("userId", "user-id-1");
    expect(body).toHaveProperty("expiresAt");
    expect(body).toHaveProperty("domain", "acme.com");
    expect(body).toHaveProperty("userEmail", "alice@acme.com");
    expect(body).toHaveProperty("userWallet", "0x1111111111111111111111111111111111111111111111111111111111111111");
    expect(body).not.toHaveProperty("otp");

    await app.close();
  });

  it("accepts an OTP request sent as a JSON string body", async () => {
    const app = await buildApp();

    const response = await app.inject({
      method: "POST",
      url: "/otp/request",
      headers: {
        ...APP_API_KEY_HEADERS,
        "content-type": "text/plain",
      },
      payload: JSON.stringify({
        domain: "acme.com",
        user_email: "alice@acme.com",
        user_wallet: "0x1111111111111111111111111111111111111111111111111111111111111111",
      }),
    });

    expect(response.statusCode).toBe(201);
    expect(createOtpSession).toHaveBeenCalledWith({
      domain: "acme.com",
      userEmail: "alice@acme.com",
      userWallet: "0x1111111111111111111111111111111111111111111111111111111111111111",
      ttlMs: 300000,
    });

    await app.close();
  });

  it("rejects a malformed OTP request body", async () => {
    const app = await buildApp();

    const response = await app.inject({
      method: "POST",
      url: "/otp/request",
      headers: {
        ...APP_API_KEY_HEADERS,
        "content-type": "text/plain",
      },
      payload: "not json",
    });

    expect(response.statusCode).toBe(400);
    expect(response.json()).toEqual({
      error: "invalid_request",
      message: "Request body must be a JSON object with domain, user_email, and user_wallet.",
    });
    expect(createOtpSession).not.toHaveBeenCalled();

    await app.close();
  });

  it("rejects an OTP request for a different email domain", async () => {
    const app = await buildApp();

    const response = await app.inject({
      method: "POST",
      url: "/otp/request",
      headers: APP_API_KEY_HEADERS,
      payload: {
        domain: "acme.com",
        user_email: "alice@example.com",
        user_wallet: "0x1111111111111111111111111111111111111111111111111111111111111111",
      },
    });

    expect(response.statusCode).toBe(400);
    expect(response.json()).toEqual({
      error: "invalid_email_domain",
      message: "user_email must belong to acme.com.",
    });
    expect(createOtpSession).not.toHaveBeenCalled();

    await app.close();
  });

  it("rejects an OTP request for an already registered email", async () => {
    createOtpSession.mockRejectedValueOnce(new Error("User email alice@acme.com is already registered."));

    const app = await buildApp();

    const response = await app.inject({
      method: "POST",
      url: "/otp/request",
      headers: APP_API_KEY_HEADERS,
      payload: {
        domain: "acme.com",
        user_email: "alice@acme.com",
        user_wallet: "0x1111111111111111111111111111111111111111111111111111111111111111",
      },
    });

    expect(response.statusCode).toBe(409);
    expect(response.json()).toEqual({
      error: "user_email_exists",
      message: "User email alice@acme.com is already registered.",
    });

    await app.close();
  });

  it("rejects an OTP request without a wallet address", async () => {
    const app = await buildApp();

    const response = await app.inject({
      method: "POST",
      url: "/otp/request",
      headers: APP_API_KEY_HEADERS,
      payload: {
        domain: "acme.com",
        user_email: "alice@acme.com",
      },
    });

    expect(response.statusCode).toBe(400);
    expect(response.json()).toEqual({
      error: "invalid_request",
      message: "Request body must be a JSON object with domain, user_email, and user_wallet.",
    });
    expect(createOtpSession).not.toHaveBeenCalled();

    await app.close();
  });

  it("rejects an OTP request with a wallet that is not a Sui address", async () => {
    createOtpSession.mockRejectedValueOnce(new Error("userWallet must be a Sui address."));

    const app = await buildApp();

    const response = await app.inject({
      method: "POST",
      url: "/otp/request",
      headers: APP_API_KEY_HEADERS,
      payload: {
        domain: "acme.com",
        user_email: "alice@acme.com",
        user_wallet: "not-a-sui-address",
      },
    });

    expect(response.statusCode).toBe(400);
    expect(response.json()).toEqual({
      error: "invalid_wallet_address",
      message: "userWallet must be a Sui address.",
    });

    await app.close();
  });

  it("rejects OTP verification when the OTP was already used", async () => {
    completeOtpSession.mockRejectedValueOnce(new Error("OTP already used."));

    const app = await buildApp();

    const response = await app.inject({
      method: "POST",
      url: "/otp/verify",
      headers: APP_API_KEY_HEADERS,
      payload: {
        userId: "user-id-1",
        otp: "123456",
        domain: "acme.com",
        userWallet: "0x1111111111111111111111111111111111111111111111111111111111111111",
        userWalletSignature: "test-signature",
      },
    });

    expect(response.statusCode).toBe(409);
    expect(response.json()).toEqual({
      error: "otp_already_used",
      message: "OTP already used.",
    });

    await app.close();
  });

  it("rejects OTP verification when the wallet signature does not prove possession", async () => {
    completeOtpSession.mockRejectedValueOnce(new Error("userWallet does not match the OTP session."));

    const app = await buildApp();

    const response = await app.inject({
      method: "POST",
      url: "/otp/verify",
      headers: APP_API_KEY_HEADERS,
      payload: {
        userId: "user-id-1",
        otp: "123456",
        domain: "acme.com",
        userWallet: "0x1111111111111111111111111111111111111111111111111111111111111111",
        userWalletSignature: "not-a-valid-signature",
      },
    });

    expect(response.statusCode).toBe(400);
    expect(response.json()).toEqual({
      error: "otp_verification_failed",
      message: "userWallet does not match the OTP session.",
    });

    await app.close();
  });

  it("rejects OTP verification with no wallet signature", async () => {
    const app = await buildApp();

    const response = await app.inject({
      method: "POST",
      url: "/otp/verify",
      headers: APP_API_KEY_HEADERS,
      payload: {
        userId: "user-id-1",
        otp: "123456",
        domain: "acme.com",
        userWallet: "0x1111111111111111111111111111111111111111111111111111111111111111",
      },
    });

    expect(response.statusCode).toBe(400);
    expect(response.json()).toEqual({
      error: "invalid_request",
      message: "Request body must be a JSON object with userId, otp, domain, userWallet, and userWalletSignature.",
    });
    expect(completeOtpSession).not.toHaveBeenCalled();

    await app.close();
  });

  it("reports upstream Sui RPC HTTP failures as backend dependency errors", async () => {
    const suiError = new Error("Unexpected status code: 404") as Error & {
      status: number;
      statusText: string;
    };
    suiError.status = 404;
    suiError.statusText = "Not Found";
    completeOtpSession.mockRejectedValueOnce(suiError);

    const app = await buildApp();

    const response = await app.inject({
      method: "POST",
      url: "/otp/verify",
      headers: APP_API_KEY_HEADERS,
      payload: {
        userId: "user-id-1",
        otp: "123456",
        domain: "acme.com",
        userWallet: "0x1111111111111111111111111111111111111111111111111111111111111111",
        userWalletSignature: "test-signature",
      },
    });

    expect(response.statusCode).toBe(502);
    expect(response.json()).toEqual({
      error: "sui_rpc_failed",
      message: "Sui RPC request failed (404 Not Found). Check SUI_RPC_URL and SUI_NETWORK configuration.",
    });

    await app.close();
  });

  it("reports Vault connection failures as backend dependency errors", async () => {
    const { VaultConnectionError } = await import("../src/services/VaultService.js");
    completeOtpSession.mockRejectedValueOnce(
      new VaultConnectionError("http://127.0.0.1:8200", new Error("ECONNREFUSED"))
    );

    const app = await buildApp();

    const response = await app.inject({
      method: "POST",
      url: "/otp/verify",
      headers: APP_API_KEY_HEADERS,
      payload: {
        userId: "user-id-1",
        otp: "123456",
        domain: "acme.com",
        userWallet: "0x1111111111111111111111111111111111111111111111111111111111111111",
        userWalletSignature: "test-signature",
      },
    });

    expect(response.statusCode).toBe(502);
    expect(response.json()).toEqual({
      error: "vault_unavailable",
      message:
        "Vault is unavailable at http://127.0.0.1:8200. Check VAULT_ADDR and ensure the Vault service is running.",
    });

    await app.close();
  });

  it("issues a deactivation challenge for an existing user", async () => {
    const { createDeactivationChallenge } = await import("../src/db/repositories.js");
    vi.mocked(createDeactivationChallenge).mockResolvedValueOnce({
      userId: "user-id-1",
      nonce: "challenge-nonce",
      expiresAt: "2026-10-14T12:00:00.000Z",
    });

    const app = await buildApp();

    const response = await app.inject({
      method: "POST",
      url: "/otp/user-id-1/deactivate/challenge",
      headers: APP_API_KEY_HEADERS,
    });

    expect(response.statusCode).toBe(201);
    expect(createDeactivationChallenge).toHaveBeenCalledWith("user-id-1");
    expect(response.json()).toEqual({
      userId: "user-id-1",
      nonce: "challenge-nonce",
      expiresAt: "2026-10-14T12:00:00.000Z",
    });

    await app.close();
  });

  it("deactivates a user's own account with a wallet signature", async () => {
    const { disableUserWithSignature } = await import("../src/db/repositories.js");
    vi.mocked(disableUserWithSignature).mockResolvedValueOnce({
      userId: "user-id-1",
      domain: "acme.com",
      userEmail: "alice@acme.com",
      userWallet: "0xuser",
      adminWallet: "0xabc",
      status: "disabled",
      userCapId: "0xcap",
      addUserTxDigest: "add-digest",
      disableUserTxDigest: "disable-digest",
      enableUserTxDigest: null,
      createdAt: new Date().toISOString(),
      updatedAt: new Date().toISOString(),
      lastVerifiedAt: new Date().toISOString(),
      disabledAt: new Date().toISOString(),
    });

    const app = await buildApp();

    const response = await app.inject({
      method: "PATCH",
      url: "/otp/user-id-1/deactivate",
      headers: APP_API_KEY_HEADERS,
      payload: { userWalletSignature: "wallet-signature" },
    });

    expect(response.statusCode).toBe(200);
    expect(disableUserWithSignature).toHaveBeenCalledWith({
      userId: "user-id-1",
      userWalletSignature: "wallet-signature",
    });
    expect(response.json()).toMatchObject({
      message: "User disabled successfully.",
      user: { userId: "user-id-1", status: "disabled" },
    });

    await app.close();
  });

  it("rejects account deactivation without an app API key", async () => {
    const app = await buildApp();

    const response = await app.inject({
      method: "PATCH",
      url: "/otp/user-id-1/deactivate",
      payload: { userWalletSignature: "wallet-signature" },
    });

    expect(response.statusCode).toBe(401);

    await app.close();
  });

  it("rejects account deactivation without a wallet signature", async () => {
    const { disableUserWithSignature } = await import("../src/db/repositories.js");

    const app = await buildApp();

    const response = await app.inject({
      method: "PATCH",
      url: "/otp/user-id-1/deactivate",
      headers: APP_API_KEY_HEADERS,
    });

    expect(response.statusCode).toBe(400);
    expect(response.json()).toEqual({
      error: "invalid_request",
      message: "Request body must be a JSON object with userWalletSignature.",
    });
    expect(disableUserWithSignature).not.toHaveBeenCalled();

    await app.close();
  });

  it("rejects account deactivation with an invalid wallet signature", async () => {
    const { disableUserWithSignature } = await import("../src/db/repositories.js");
    vi.mocked(disableUserWithSignature).mockRejectedValueOnce(
      new Error("userWalletSignature does not match the registered wallet.")
    );

    const app = await buildApp();

    const response = await app.inject({
      method: "PATCH",
      url: "/otp/user-id-1/deactivate",
      headers: APP_API_KEY_HEADERS,
      payload: { userWalletSignature: "not-a-valid-signature" },
    });

    expect(response.statusCode).toBe(401);
    expect(response.json()).toEqual({
      error: "invalid_signature",
      message: "userWalletSignature does not match the registered wallet.",
    });

    await app.close();
  });

  it("returns 404 deactivating an unknown account", async () => {
    const { createDeactivationChallenge, disableUserWithSignature } = await import("../src/db/repositories.js");
    vi.mocked(createDeactivationChallenge).mockResolvedValueOnce(null);
    vi.mocked(disableUserWithSignature).mockResolvedValueOnce(null);

    const app = await buildApp();

    const challengeResponse = await app.inject({
      method: "POST",
      url: "/otp/missing-user/deactivate/challenge",
      headers: APP_API_KEY_HEADERS,
    });
    const deactivateResponse = await app.inject({
      method: "PATCH",
      url: "/otp/missing-user/deactivate",
      headers: APP_API_KEY_HEADERS,
      payload: { userWalletSignature: "wallet-signature" },
    });

    expect(challengeResponse.statusCode).toBe(404);
    expect(deactivateResponse.statusCode).toBe(404);

    await app.close();
  });

  it("does not leak internal error details for an unmapped failure", async () => {
    const { findOtpSession } = await import("../src/db/repositories.js");
    vi.mocked(findOtpSession).mockRejectedValueOnce(
      new Error("connection to server at internal-db-host.internal:5432 failed: password authentication failed")
    );

    const app = await buildApp();

    const response = await app.inject({
      method: "GET",
      url: "/otp/user-id-1",
      headers: APP_API_KEY_HEADERS,
    });

    expect(response.statusCode).toBe(500);
    const body = response.json();
    expect(body).toEqual({
      error: "internal_error",
      message: "An unexpected error occurred.",
      correlationId: expect.any(String),
    });
    expect(JSON.stringify(body)).not.toContain("internal-db-host");
    expect(JSON.stringify(body)).not.toContain("password authentication failed");

    await app.close();
  });
});

describe("OTP rate limiting", () => {
  beforeEach(async () => {
    vi.clearAllMocks();
    // Reset rate limiters
    const { resetAllRateLimiters } = await import("../src/utils/rateLimit.js");
    resetAllRateLimiters();
  });

  it("should rate limit OTP requests from same IP", async () => {
    const app = await buildApp();

    // Make 5 requests (limit is 5 per minute)
    const results = [];
    for (let i = 0; i < 6; i++) {
      const response = await app.inject({
        method: "POST",
        url: "/otp/request",
        headers: APP_API_KEY_HEADERS,
        payload: {
          domain: "acme.com",
          user_email: `user${i}@acme.com`,
          user_wallet: "0x1111111111111111111111111111111111111111111111111111111111111111",
        },
      });
      results.push(response.statusCode);
    }

    // First 5 should succeed, 6th should be rate limited
    expect(results.slice(0, 5)).toEqual([201, 201, 201, 201, 201]);
    expect(results[5]).toBe(429);

    await app.close();
  });

  it("should include Retry-After header when rate limited", async () => {
    const app = await buildApp();

    // Exhaust rate limit
    for (let i = 0; i < 5; i++) {
      await app.inject({
        method: "POST",
        url: "/otp/request",
        headers: APP_API_KEY_HEADERS,
        payload: {
          domain: "acme.com",
          user_email: `user${i}@acme.com`,
          user_wallet: "0x1111111111111111111111111111111111111111111111111111111111111111",
        },
      });
    }

    // 6th request should be rate limited
    const response = await app.inject({
      method: "POST",
      url: "/otp/request",
      headers: APP_API_KEY_HEADERS,
      payload: {
        domain: "acme.com",
        user_email: "another@acme.com",
        user_wallet: "0x1111111111111111111111111111111111111111111111111111111111111111",
      },
    });

    expect(response.statusCode).toBe(429);
    expect(response.headers).toHaveProperty("retry-after");
    expect(response.json()).toEqual({
      error: "rate_limit_exceeded",
      message: expect.stringContaining("Too many OTP requests"),
    });

    await app.close();
  });

  it("should rate limit OTP verify attempts per userId", async () => {
    // Mock failed verification attempts
    const { findOtpSession } = await import("../src/db/repositories.js");
    vi.mocked(findOtpSession).mockResolvedValue({
      userId: "user-verify-test",
      domain: "acme.com",
      userEmail: "alice@acme.com",
      userWallet: "0x1111111111111111111111111111111111111111111111111111111111111111",
      adminWallet: "0xabc",
      txDigest: null,
      userCapId: null,
      status: "pending_verification",
      createdAt: new Date().toISOString(),
      expiresAt: new Date().toISOString(),
      verifiedAt: null,
      otpHash: "hash",
      walletNonce: "test-nonce",
      error: null,
    });

    const app = await buildApp();

    // Make 10 failed verify attempts for same userId (limit is 10 per 15 min)
    for (let i = 0; i < 10; i++) {
      await app.inject({
        method: "POST",
        url: "/otp/verify",
        headers: APP_API_KEY_HEADERS,
        payload: {
          userId: "user-verify-test",
          otp: "wrong-otp",
          domain: "acme.com",
          userWallet: "0x1111111111111111111111111111111111111111111111111111111111111111",
        },
      });
    }

    // 11th should be rate limited
    const response = await app.inject({
      method: "POST",
      url: "/otp/verify",
      headers: APP_API_KEY_HEADERS,
      payload: {
        userId: "user-verify-test",
        otp: "wrong-otp-2",
        domain: "acme.com",
        userWallet: "0x1111111111111111111111111111111111111111111111111111111111111111",
        userWalletSignature: "test-signature",
      },
    });

    expect(response.statusCode).toBe(429);
    expect(response.json()).toEqual({
      error: "rate_limit_exceeded",
      message: expect.stringContaining("Too many OTP verification attempts"),
    });

    await app.close();
  });
});
