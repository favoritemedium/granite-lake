import { decodeSuiPrivateKey } from "@mysten/sui/cryptography";
import { Ed25519Keypair } from "@mysten/sui/keypairs/ed25519";
import { SuiGrpcClient } from "@mysten/sui/grpc";
import { Transaction } from "@mysten/sui/transactions";
import type { AppEnv } from "../config/env.js";
import { resolveSecretValue } from "./VaultService.js";

export type AddUserResult = {
  txDigest: string;
  userCapId: string;
};

const TRANSIENT_NETWORK_ERROR_CODES = new Set([
  "ECONNRESET",
  "ECONNREFUSED",
  "ETIMEDOUT",
  "ENOTFOUND",
  "EAI_AGAIN",
  "EPIPE",
  "ECONNABORTED",
]);

// Undici and the gRPC-web transport both collapse real network failures into
// a generic "fetch failed" / RpcError a few `.cause` levels deep.
function isTransientNetworkError(error: unknown, depth = 0): boolean {
  if (!(error instanceof Error) || depth > 5) return false;

  const code = (error as NodeJS.ErrnoException).code;
  if (code && TRANSIENT_NETWORK_ERROR_CODES.has(code)) return true;
  if (error.name === "RpcError" || /fetch failed/i.test(error.message)) return true;

  return isTransientNetworkError((error as { cause?: unknown }).cause, depth + 1);
}

// Retries only transient network failures. Safe to rebuild-and-resubmit here
// because the failures we've seen occur while the SDK resolves gas/coin data
// during Transaction.build(), before anything is signed or broadcast. Each
// attempt must build a fresh Transaction (see callers) rather than reusing
// one across retries, since we can't assume partial build state is clean.
async function withNetworkRetry<T>(fn: () => Promise<T>, attempts = 3, baseDelayMs = 300): Promise<T> {
  for (let attempt = 1; attempt <= attempts; attempt++) {
    try {
      return await fn();
    } catch (error) {
      if (attempt === attempts || !isTransientNetworkError(error)) {
        throw error;
      }
      await new Promise((resolve) => setTimeout(resolve, baseDelayMs * 2 ** (attempt - 1)));
    }
  }

  throw new Error("unreachable");
}

// eslint-disable-next-line @typescript-eslint/no-explicit-any
type ExecuteTransactionResult = any;

export class SuiService {
  private readonly client: SuiGrpcClient;
  private keypair: Ed25519Keypair | null = null;

  constructor(private readonly appEnv: AppEnv) {
    this.client = new SuiGrpcClient({
      network: appEnv.SUI_NETWORK,
      baseUrl: appEnv.SUI_RPC_URL,
    });
  }

  private async initializeKeypair(): Promise<Ed25519Keypair> {
    if (this.keypair) return this.keypair;

    if (!this.appEnv.SUI_PRIVATE_KEY || !this.appEnv.SUI_PACKAGE_ID || !this.appEnv.SUI_REGISTRY_ID) {
      throw new Error("Sui configuration is incomplete. Set SUI_PRIVATE_KEY, SUI_PACKAGE_ID, and SUI_REGISTRY_ID.");
    }

    const privateKey = await resolveSecretValue(this.appEnv, this.appEnv.SUI_PRIVATE_KEY);
    if (!privateKey) {
      throw new Error("Sui private key could not be resolved from configuration.");
    }

    const decoded = decodeSuiPrivateKey(privateKey.trim());
    if (decoded.scheme !== "ED25519") {
      throw new Error(`Unsupported Sui private key scheme: ${decoded.scheme}. Expected ED25519.`);
    }

    const keypair = Ed25519Keypair.fromSecretKey(decoded.secretKey);
    const signerAddress = keypair.toSuiAddress().toLowerCase();
    const expectedAddress = this.appEnv.ADMIN_WALLET.trim().toLowerCase();

    if (signerAddress !== expectedAddress) {
      throw new Error(`Sui signer ${signerAddress} does not match ADMIN_WALLET ${expectedAddress}.`);
    }

    this.keypair = keypair;
    return keypair;
  }

  async addUser(params: { domain: string; userWallet: string }): Promise<AddUserResult> {
    const { digest, result } = await this.executeDomainAdminCall({
      functionName: "add_user",
      domain: params.domain,
      userWallet: params.userWallet,
    });

    // Wait for transaction to be indexed
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    await this.client.waitForTransaction({ result: result as any });

    // Query the transaction to get created objects
    // gRPC uses include.objectTypes + effects.changedObjects instead of objectChanges
    const txDetails = await this.client.getTransaction({
      digest,
      include: {
        objectTypes: true,
        effects: true,
      },
    });

    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const txData: any = txDetails.$kind === "Transaction" ? txDetails.Transaction : txDetails;
    const changedObjects = txData.effects?.changedObjects ?? [];
    const objectTypes = txData.objectTypes ?? {};
    const userCapId = findCreatedObjectId(changedObjects, objectTypes, "::photo_attestation::UserCap");

    if (!userCapId) {
      // Log for debugging
      console.error(
        "UserCap not found in changedObjects. Query result:",
        JSON.stringify(txDetails, null, 2).slice(0, 2000)
      );
      throw new Error("Sui add_user transaction did not create a UserCap.");
    }

    return {
      txDigest: digest,
      userCapId,
    };
  }

  async disableUser(params: { domain: string; userWallet: string }): Promise<string> {
    const { digest } = await this.executeDomainAdminCall({
      functionName: "disable_user",
      domain: params.domain,
      userWallet: params.userWallet,
    });

    return digest;
  }

  async enableUser(params: { domain: string; userWallet: string }): Promise<string> {
    const { digest } = await this.executeDomainAdminCall({
      functionName: "enable_user",
      domain: params.domain,
      userWallet: params.userWallet,
    });

    return digest;
  }

  private async executeDomainAdminCall(params: {
    functionName: "add_user" | "disable_user" | "enable_user";
    domain: string;
    userWallet: string;
  }): Promise<{ digest: string; result: ExecuteTransactionResult }> {
    const keypair = await this.initializeKeypair();

    const result = await withNetworkRetry(() => {
      const tx = new Transaction();

      tx.moveCall({
        target: `${this.appEnv.SUI_PACKAGE_ID}::${this.appEnv.SUI_MODULE}::${params.functionName}`,
        arguments: [
          tx.object(this.appEnv.SUI_REGISTRY_ID),
          tx.pure.vector("u8", Array.from(Buffer.from(params.domain, "utf8"))),
          tx.pure.address(params.userWallet),
        ],
      });

      tx.setGasBudget(this.appEnv.SUI_GAS_BUDGET);

      return keypair.signAndExecuteTransaction({
        transaction: tx,
        client: this.client,
      });
    });

    // Check for failed transaction
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    if (result.$kind === "FailedTransaction") {
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      const status = (result as any).FailedTransaction;
      throw new Error(status?.error?.message ?? "Sui transaction failed.");
    }

    // Get the digest - it could be in different places depending on result structure
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const digest = (result as any).digest ?? (result as any).Transaction?.digest;
    if (!digest) {
      console.error("No digest in result:", JSON.stringify(result, null, 2).slice(0, 1000));
      throw new Error("Transaction executed but no digest found in response.");
    }

    return { digest, result };
  }
}

function findCreatedObjectId(
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  changes: any[],
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  objectTypes: Record<string, any>,
  objectTypeSuffix: string
): string | null {
  const created = changes.find(
    (change) => change.idOperation === "Created" && objectTypes[change.objectId]?.endsWith(objectTypeSuffix)
  );

  return created?.objectId ?? null;
}
