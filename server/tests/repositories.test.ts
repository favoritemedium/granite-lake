import { beforeEach, describe, expect, it, vi } from "vitest";
import { Ed25519Keypair } from "@mysten/sui/keypairs/ed25519";

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

const addUserMock = vi.fn(async () => ({ txDigest: "0xdigest", userCapId: "0xcap" }));
const suiDisableUserMock = vi.fn();

vi.mock("../src/services/SuiService.js", () => ({
  SuiService: vi.fn().mockImplementation(() => ({
    addUser: addUserMock,
    disableUser: suiDisableUserMock,
    enableUser: vi.fn(),
  })),
}));

vi.mock("../src/services/GoogleChatService.js", () => ({
  GoogleChatService: vi.fn().mockImplementation(() => ({
    sendOtp: vi.fn(),
  })),
}));

// F-03 requires proving possession of userWallet's private key before it is
// bound to an OTP session. That check calls the real Sui signature-verify
// library end to end, so this suite mocks only the DB and the chain write -
// not the check itself - to prove a real Ed25519 keypair produces a
// signature the server actually accepts, and that a tampered one is
// actually rejected rather than merely mocked as rejected (see otp.test.ts
// for the route-level error-mapping coverage, which mocks completeOtpSession
// entirely and so never exercises this). The deactivation tests below rely
// on the same property for disableUserWithSignature.
const queryMock = vi.fn(async (sql: string) => {
  const normalized = sql.trim().toLowerCase();

  if (normalized.startsWith("select") && normalized.includes("from otp_sessions")) {
    return { rows: [currentSession], rowCount: 1 };
  }
  if (normalized.startsWith("select") && normalized.includes("from users") && normalized.includes("deactivate_nonce")) {
    return currentDeactivationUser ? { rows: [currentDeactivationUser], rowCount: 1 } : { rows: [], rowCount: 0 };
  }
  if (normalized.startsWith("select") && normalized.includes("from users") && normalized.includes("user_id = $1")) {
    return currentStoredUser ? { rows: [currentStoredUser], rowCount: 1 } : { rows: [], rowCount: 0 };
  }
  if (normalized.startsWith("select") && normalized.includes("from users")) {
    return { rows: [], rowCount: 0 };
  }
  if (normalized.startsWith("update otp_sessions")) {
    currentSession = { ...currentSession, status: "completed" };
    return { rows: [currentSession], rowCount: 1 };
  }
  if (normalized.startsWith("insert into users")) {
    return { rows: [], rowCount: 1 };
  }
  if (normalized.startsWith("update users") && normalized.includes("deactivate_nonce = null")) {
    return { rows: [], rowCount: consumeNonceRowCount };
  }
  if (normalized.startsWith("update users")) {
    currentStoredUser = { ...currentStoredUser, status: "disabled" };
    return { rows: [currentStoredUser], rowCount: 1 };
  }

  throw new Error(`Unexpected query in test: ${sql}`);
});

vi.mock("../src/db/pool.js", () => ({
  pool: { query: (sql: string) => queryMock(sql) },
}));

const { completeOtpSession, disableUserWithSignature } = await import("../src/db/repositories.js");

const NONCE = Buffer.from("test-nonce-32-bytes-of-entropy!!").toString("base64");

let currentSession: Record<string, unknown>;
let currentDeactivationUser: Record<string, unknown> | null;
let currentStoredUser: Record<string, unknown> | null;
let consumeNonceRowCount: number;

const OTP = "123456";
const OTP_HASH = "8d969eef6ecad3c29a3a629280e686cf0c3f5d5a86aff3ca12020c923adc6c92"; // sha256("123456")

function pendingSession(overrides: Partial<Record<string, unknown>> = {}) {
  return {
    userId: "user-id-1",
    userEmail: "alice@acme.com",
    userWallet: null,
    otpHash: OTP_HASH,
    walletNonce: NONCE,
    status: "pending_verification",
    createdAt: new Date().toISOString(),
    expiresAt: new Date(Date.now() + 60_000).toISOString(),
    verifiedAt: null,
    txDigest: null,
    userCapId: null,
    error: null,
    ...overrides,
  };
}

function deactivationUser(overrides: Partial<Record<string, unknown>> = {}) {
  return {
    userWallet: "0xuser",
    status: "active",
    deactivateNonce: NONCE,
    deactivateNonceExpiresAt: new Date(Date.now() + 60_000).toISOString(),
    ...overrides,
  };
}

function storedUser(overrides: Partial<Record<string, unknown>> = {}) {
  return {
    userId: "user-id-1",
    userEmail: "alice@acme.com",
    userWallet: "0xuser",
    status: "active",
    userCapId: "0xcap",
    addUserTxDigest: "add-digest",
    disableUserTxDigest: null,
    enableUserTxDigest: null,
    createdAt: new Date().toISOString(),
    updatedAt: new Date().toISOString(),
    lastVerifiedAt: new Date().toISOString(),
    disabledAt: null,
    ...overrides,
  };
}

beforeEach(() => {
  vi.clearAllMocks();
  currentSession = pendingSession();
  currentDeactivationUser = deactivationUser();
  currentStoredUser = storedUser();
  consumeNonceRowCount = 1;
});

describe("completeOtpSession wallet signature check (F-03)", () => {
  it("accepts a real signature over the session nonce from the claimed wallet", async () => {
    const keypair = new Ed25519Keypair();
    const { signature } = await keypair.signPersonalMessage(Buffer.from(NONCE, "base64"));

    const result = await completeOtpSession({
      userId: "user-id-1",
      domain: "acme.com",
      otp: OTP,
      userWallet: keypair.toSuiAddress(),
      userWalletSignature: signature,
    });

    expect(result.status).toBe("completed");
    expect(addUserMock).toHaveBeenCalledWith({
      domain: "acme.com",
      userWallet: keypair.toSuiAddress().toLowerCase(),
    });
  });

  it("rejects a valid signature that does not match the claimed wallet address", async () => {
    const signer = new Ed25519Keypair();
    const claimedWallet = new Ed25519Keypair().toSuiAddress(); // different wallet than the signer
    const { signature } = await signer.signPersonalMessage(Buffer.from(NONCE, "base64"));

    await expect(
      completeOtpSession({
        userId: "user-id-1",
        domain: "acme.com",
        otp: OTP,
        userWallet: claimedWallet,
        userWalletSignature: signature,
      })
    ).rejects.toThrow("userWallet does not match the OTP session.");

    expect(addUserMock).not.toHaveBeenCalled();
  });

  it("rejects a valid signature produced over a different session's nonce", async () => {
    const keypair = new Ed25519Keypair();
    const otherNonce = Buffer.from("a-completely-different-nonce!!!!").toString("base64");
    const { signature } = await keypair.signPersonalMessage(Buffer.from(otherNonce, "base64"));

    await expect(
      completeOtpSession({
        userId: "user-id-1",
        domain: "acme.com",
        otp: OTP,
        userWallet: keypair.toSuiAddress(),
        userWalletSignature: signature,
      })
    ).rejects.toThrow("userWallet does not match the OTP session.");

    expect(addUserMock).not.toHaveBeenCalled();
  });

  it("rejects a malformed signature string", async () => {
    const keypair = new Ed25519Keypair();

    await expect(
      completeOtpSession({
        userId: "user-id-1",
        domain: "acme.com",
        otp: OTP,
        userWallet: keypair.toSuiAddress(),
        userWalletSignature: "not-a-real-signature",
      })
    ).rejects.toThrow("userWallet does not match the OTP session.");

    expect(addUserMock).not.toHaveBeenCalled();
  });

  it("rejects when the session predates the wallet_nonce column (null nonce)", async () => {
    currentSession = pendingSession({ walletNonce: null });
    const keypair = new Ed25519Keypair();
    const { signature } = await keypair.signPersonalMessage(Buffer.from(NONCE, "base64"));

    await expect(
      completeOtpSession({
        userId: "user-id-1",
        domain: "acme.com",
        otp: OTP,
        userWallet: keypair.toSuiAddress(),
        userWalletSignature: signature,
      })
    ).rejects.toThrow("userWallet does not match the OTP session.");

    expect(addUserMock).not.toHaveBeenCalled();
  });
});

describe("disableUserWithSignature wallet signature check", () => {
  const DEACTIVATION_MESSAGE = `deactivate:user-id-1:${NONCE}`;

  it("accepts a real signature over deactivate:<userId>:<nonce> from the registered wallet", async () => {
    const keypair = new Ed25519Keypair();
    currentDeactivationUser = deactivationUser({ userWallet: keypair.toSuiAddress() });
    currentStoredUser = storedUser({ userWallet: keypair.toSuiAddress() });
    const { signature } = await keypair.signPersonalMessage(Buffer.from(DEACTIVATION_MESSAGE, "utf8"));

    const result = await disableUserWithSignature({
      userId: "user-id-1",
      userWalletSignature: signature,
    });

    expect(result?.status).toBe("disabled");
    expect(suiDisableUserMock).toHaveBeenCalledWith({
      domain: "acme.com",
      userWallet: keypair.toSuiAddress().toLowerCase(),
    });
  });

  it("rejects a valid signature from a wallet that is not the registered one", async () => {
    const signer = new Ed25519Keypair();
    const registeredWallet = new Ed25519Keypair().toSuiAddress(); // different wallet than the signer
    currentDeactivationUser = deactivationUser({ userWallet: registeredWallet });
    const { signature } = await signer.signPersonalMessage(Buffer.from(DEACTIVATION_MESSAGE, "utf8"));

    await expect(
      disableUserWithSignature({
        userId: "user-id-1",
        userWalletSignature: signature,
      })
    ).rejects.toThrow("userWalletSignature does not match the registered wallet.");

    expect(suiDisableUserMock).not.toHaveBeenCalled();
  });

  it("rejects a valid signature produced over a different challenge's nonce", async () => {
    const keypair = new Ed25519Keypair();
    currentDeactivationUser = deactivationUser({ userWallet: keypair.toSuiAddress() });
    const otherNonce = Buffer.from("a-completely-different-nonce!!!!").toString("base64");
    const { signature } = await keypair.signPersonalMessage(Buffer.from(`deactivate:user-id-1:${otherNonce}`, "utf8"));

    await expect(
      disableUserWithSignature({
        userId: "user-id-1",
        userWalletSignature: signature,
      })
    ).rejects.toThrow("userWalletSignature does not match the registered wallet.");

    expect(suiDisableUserMock).not.toHaveBeenCalled();
  });

  it("rejects a malformed signature string", async () => {
    const keypair = new Ed25519Keypair();
    currentDeactivationUser = deactivationUser({ userWallet: keypair.toSuiAddress() });

    await expect(
      disableUserWithSignature({
        userId: "user-id-1",
        userWalletSignature: "not-a-real-signature",
      })
    ).rejects.toThrow("userWalletSignature does not match the registered wallet.");

    expect(suiDisableUserMock).not.toHaveBeenCalled();
  });

  it("rejects when no challenge was ever issued (null nonce)", async () => {
    const keypair = new Ed25519Keypair();
    currentDeactivationUser = deactivationUser({
      userWallet: keypair.toSuiAddress(),
      deactivateNonce: null,
      deactivateNonceExpiresAt: null,
    });
    const { signature } = await keypair.signPersonalMessage(Buffer.from(DEACTIVATION_MESSAGE, "utf8"));

    await expect(
      disableUserWithSignature({
        userId: "user-id-1",
        userWalletSignature: signature,
      })
    ).rejects.toThrow("No deactivation challenge found.");

    expect(suiDisableUserMock).not.toHaveBeenCalled();
  });

  it("rejects an expired challenge", async () => {
    const keypair = new Ed25519Keypair();
    currentDeactivationUser = deactivationUser({
      userWallet: keypair.toSuiAddress(),
      deactivateNonceExpiresAt: new Date(Date.now() - 60_000).toISOString(),
    });
    const { signature } = await keypair.signPersonalMessage(Buffer.from(DEACTIVATION_MESSAGE, "utf8"));

    await expect(
      disableUserWithSignature({
        userId: "user-id-1",
        userWalletSignature: signature,
      })
    ).rejects.toThrow("Deactivation challenge expired.");

    expect(suiDisableUserMock).not.toHaveBeenCalled();
  });

  it("rejects a replay once the nonce has been consumed", async () => {
    const keypair = new Ed25519Keypair();
    currentDeactivationUser = deactivationUser({ userWallet: keypair.toSuiAddress() });
    consumeNonceRowCount = 0;
    const { signature } = await keypair.signPersonalMessage(Buffer.from(DEACTIVATION_MESSAGE, "utf8"));

    await expect(
      disableUserWithSignature({
        userId: "user-id-1",
        userWalletSignature: signature,
      })
    ).rejects.toThrow("Deactivation challenge already used.");

    expect(suiDisableUserMock).not.toHaveBeenCalled();
  });

  it("returns the record without another on-chain call when the user is already disabled", async () => {
    const keypair = new Ed25519Keypair();
    currentDeactivationUser = deactivationUser({
      userWallet: keypair.toSuiAddress(),
      status: "disabled",
    });
    currentStoredUser = storedUser({ userWallet: keypair.toSuiAddress(), status: "disabled" });
    const { signature } = await keypair.signPersonalMessage(Buffer.from(DEACTIVATION_MESSAGE, "utf8"));

    const result = await disableUserWithSignature({
      userId: "user-id-1",
      userWalletSignature: signature,
    });

    expect(result?.status).toBe("disabled");
    expect(suiDisableUserMock).not.toHaveBeenCalled();
  });

  it("returns null for an unknown user", async () => {
    currentDeactivationUser = null;

    const result = await disableUserWithSignature({
      userId: "missing-user",
      userWalletSignature: "wallet-signature",
    });

    expect(result).toBeNull();
    expect(suiDisableUserMock).not.toHaveBeenCalled();
  });
});
