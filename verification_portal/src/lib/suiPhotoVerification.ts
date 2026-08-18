import {
  FILE_ATTESTED_EVENT_TYPES,
  GRANITE_LAKE_PACKAGE_ID,
  GRANITE_LAKE_ORIGINAL_PACKAGE_ID,
  GRANITE_LAKE_REGISTRY_ID,
  PHOTO_ATTESTED_EVENT_TYPES,
  SUI_RPC_URL,
  USER_DISABLED_EVENT_TYPES,
  USER_ENABLED_EVENT_TYPES,
} from "../constants";

type SuiEventCursor = {
  txDigest: string;
  eventSeq: string;
  graphqlCursor?: string;
};

type SuiEvent = {
  id: SuiEventCursor;
  packageId: string;
  sender: string;
  timestampMs?: string;
  parsedJson?: Record<string, unknown>;
  typeRepr?: string;
};

type SuiEventPage = {
  data?: SuiEvent[];
  hasNextPage?: boolean;
  nextCursor?: SuiEventCursor | null;
};

type SuiRpcError = {
  message?: string;
};

type SuiRpcResponse<T> = {
  data?: T;
  errors?: SuiRpcError[];
};

function getEventTypeSuffix(eventType: string): string {
  return eventType.split("::").pop()?.toLowerCase() ?? "";
}

function matchesExpectedEventType(event: SuiEvent, eventType: string): boolean {
  const expected = getEventTypeSuffix(eventType);
  if (!expected) return false;
  return event.typeRepr?.toLowerCase().endsWith(`::${expected}`) ?? false;
}

export type ScanProgress = {
  pagesScanned: number;
  eventsScanned: number;
};

export type PhotoAttestationRecord = {
  txDigest: string;
  eventSeq: string;
  timestampMs: string | null;
  checkpointTime: string;
  photoHashHex: string;
  gpsRawHex: string;
  gpsDecoded: string;
  altitudeRawHex: string;
  altitudeDecoded: string;
  projectIdRawHex: string;
  projectIdDecoded: string;
  userWallet: string;
  domain: string | null;
  domainAdminWallet: string | null;
  userEnabledAtAttestation: boolean | null;
};

export type FileAttestationRecord = {
  txDigest: string;
  eventSeq: string;
  timestampMs: string | null;
  checkpointTime: string;
  fileHashHex: string;
  fileIdRawHex: string;
  fileIdDecoded: string;
  projectIdRawHex: string;
  projectIdDecoded: string;
  userWallet: string;
  domain: string | null;
  domainAdminWallet: string | null;
  userEnabledAtAttestation: boolean | null;
};

export type VerificationResult =
  | {
      hasMatch: false;
      progress: ScanProgress;
    }
  | {
      hasMatch: true;
      collision: false;
      progress: ScanProgress;
      record: PhotoAttestationRecord;
    }
  | {
      // More than one distinct wallet attested this exact hash. The contract
      // has no link between an attestation and file ownership, so this is
      // not resolved automatically — every candidate is returned instead of
      // silently picking one.
      hasMatch: true;
      collision: true;
      progress: ScanProgress;
      records: PhotoAttestationRecord[];
    };

export type FileVerificationResult =
  | {
      hasMatch: false;
      progress: ScanProgress;
    }
  | {
      hasMatch: true;
      collision: false;
      progress: ScanProgress;
      record: FileAttestationRecord;
    }
  | {
      hasMatch: true;
      collision: true;
      progress: ScanProgress;
      records: FileAttestationRecord[];
    };

export type WalletAttestType = "attest_photo" | "attest_file";

export type WalletAttestationRecord = {
  attestType: WalletAttestType;
  txDigest: string;
  eventSeq: string;
  packageId: string;
  timestampMs: string | null;
  checkpointTime: string;
  hashHex: string;
  projectIdRawHex: string;
  projectIdDecoded: string;
  userWallet: string;
  domain: string | null;
  domainAdminWallet: string | null;
  userEnabledAtAttestation: boolean | null;
  photoHashHex?: string;
  fileHashHex?: string;
  fileIdRawHex?: string;
  fileIdDecoded?: string;
  gpsRawHex?: string;
  gpsDecoded?: string;
  altitudeRawHex?: string;
  altitudeDecoded?: string;
};

export type WalletAttestationsResult = {
  wallet: string;
  pagesScanned: number;
  eventsScanned: number;
  photoCount: number;
  fileCount: number;
  events: WalletAttestationRecord[];
};

function normalizeHex(value: string): string {
  return value.toLowerCase().replace(/^0x/, "");
}

function isByteArray(value: unknown): value is number[] {
  return Array.isArray(value) && value.every((item) => Number.isInteger(item) && item >= 0 && item <= 255);
}

function parseVectorU8(value: unknown): Uint8Array | null {
  if (value instanceof Uint8Array) return value;

  if (isByteArray(value)) {
    return new Uint8Array(value);
  }

  if (typeof value === "string") {
    const normalizedBase64 = value.trim().replace(/\s+/g, "");
    if (
      normalizedBase64.length > 0 &&
      normalizedBase64.length % 4 === 0 &&
      /^[A-Za-z0-9+/]+={0,2}$/.test(normalizedBase64)
    ) {
      try {
        const binary = atob(normalizedBase64);
        return Uint8Array.from(binary, (char) => char.charCodeAt(0));
      } catch {
        // Fall through to the existing hex / text handling.
      }
    }

    const normalized = normalizeHex(value);
    if (/^[a-f0-9]+$/i.test(normalized) && normalized.length % 2 === 0) {
      const bytes = normalized.match(/.{1,2}/g)?.map((byte) => parseInt(byte, 16)) ?? [];
      return new Uint8Array(bytes);
    }

    return new TextEncoder().encode(value);
  }

  if (typeof value === "object" && value && "bytes" in value) {
    const bytes = (value as { bytes?: unknown }).bytes;
    if (isByteArray(bytes)) {
      return new Uint8Array(bytes);
    }
  }

  return null;
}

function bytesToHex(bytes: Uint8Array): string {
  return Array.from(bytes, (value) => value.toString(16).padStart(2, "0")).join("");
}

// BCS encoders for dynamic-field lookup keys (see getRegistryDomainRecord).
// Table<K, V> stores each entry as a dynamic field keyed by the raw BCS
// encoding of K, so these must match sui::table's on-chain key types exactly:
// vector<u8> for Registry.domains, address for DomainRecord.users.
function bcsEncodeVectorU8(bytes: Uint8Array): string {
  const lenBytes: number[] = [];
  let remaining = bytes.length;
  do {
    let byte = remaining & 0x7f;
    remaining >>>= 7;
    if (remaining !== 0) byte |= 0x80;
    lenBytes.push(byte);
  } while (remaining !== 0);

  const encoded = new Uint8Array(lenBytes.length + bytes.length);
  encoded.set(lenBytes, 0);
  encoded.set(bytes, lenBytes.length);
  return btoa(String.fromCharCode(...encoded));
}

function bcsEncodeAddress(address: string): string {
  const hex = normalizeHex(address).padStart(64, "0");
  const bytes = hex.match(/.{2}/g)?.map((byte) => parseInt(byte, 16)) ?? [];
  return btoa(String.fromCharCode(...bytes));
}

function tryDecodeUtf8(bytes: Uint8Array): string {
  if (bytes.length === 0) return "";
  try {
    const decoded = new TextDecoder().decode(bytes);
    return decoded.trim();
  } catch {
    return "";
  }
}

function decodeVector(value: unknown): { hex: string; decoded: string } {
  const bytes = parseVectorU8(value);
  if (!bytes) return { hex: "", decoded: "" };

  const hex = bytesToHex(bytes);
  const decoded = tryDecodeUtf8(bytes);
  return { hex, decoded };
}

function decodePhotoHash(value: unknown): string {
  const decoded = decodeVector(value);

  if (decoded.decoded) {
    const candidate = normalizeHex(decoded.decoded);
    if (/^[a-f0-9]{64}$/i.test(candidate)) {
      return candidate;
    }
  }

  const candidate = normalizeHex(decoded.hex);
  if (/^[a-f0-9]{64}$/i.test(candidate)) {
    return candidate;
  }

  return "";
}

function safeAddress(value: unknown): string {
  return typeof value === "string" ? value : "";
}

function isAllowedPackageId(packageId: string): boolean {
  const normalized = normalizeHex(packageId);
  return (
    normalized === normalizeHex(GRANITE_LAKE_PACKAGE_ID) ||
    normalized === normalizeHex(GRANITE_LAKE_ORIGINAL_PACKAGE_ID)
  );
}

async function suiRpcCall<T>(method: string, params: unknown[]): Promise<T> {
  const response = await fetch(normalizeGraphQlUrl(SUI_RPC_URL), {
    method: "POST",
    headers: {
      "content-type": "application/json",
    },
    body: JSON.stringify(buildGraphQlRequest(method, params)),
  });

  if (!response.ok) {
    throw new Error(`Sui GraphQL request failed: ${response.status} ${response.statusText}`);
  }

  const payload = (await response.json()) as SuiRpcResponse<T>;

  if (payload.errors?.length) {
    const message = payload.errors
      .map((entry) => entry.message?.trim())
      .filter((entry): entry is string => Boolean(entry))
      .join("\n");
    throw new Error(message || "Sui GraphQL returned an error");
  }

  if (!payload.data) {
    throw new Error("Sui GraphQL returned no result payload");
  }

  return extractGraphQlResult<T>(method, payload.data as Record<string, unknown>);
}

function normalizeGraphQlUrl(url: string): string {
  const trimmed = url.trim();
  if (!trimmed) return trimmed;

  try {
    const parsed = new URL(trimmed);
    const host = parsed.host.toLowerCase();
    if (host === "fullnode.testnet.sui.io" || host === "rpc.ankr.com") {
      return "https://graphql.testnet.sui.io/graphql";
    }
    if (host === "fullnode.mainnet.sui.io") {
      return "https://graphql.mainnet.sui.io/graphql";
    }
    if (host === "fullnode.devnet.sui.io") {
      return "https://graphql.devnet.sui.io/graphql";
    }
    if (host.startsWith("graphql.") && !parsed.pathname.endsWith("/graphql")) {
      parsed.pathname = "/graphql";
      return parsed.toString();
    }
    return trimmed;
  } catch {
    return trimmed;
  }
}

function buildGraphQlRequest(method: string, params: unknown[]): { query: string; variables: Record<string, unknown> } {
  switch (method) {
    case "suix_queryEvents": {
      const [filter, cursor, limit] = params as [
        { MoveEventType?: string },
        SuiEventCursor | null,
        number | undefined,
        boolean | undefined,
      ];
      const moveEventType = filter.MoveEventType ?? "";
      const moduleFilter = moveEventType.includes("::")
        ? moveEventType.substring(0, moveEventType.lastIndexOf("::"))
        : moveEventType;
      return {
        query: `query($module:String!,$first:Int!,$after:String){
          events(first:$first, after:$after, filter:{ module:$module }){
            pageInfo { hasNextPage endCursor }
            nodes {
              sequenceNumber
              timestamp
              sender { address }
              transaction { digest }
              transactionModule { name package { address } }
              contents {
                type { repr }
                json
              }
            }
          }
        }`,
        variables: {
          module: moduleFilter,
          first: typeof limit === "number" ? limit : 50,
          after: encodeEventCursor(cursor),
        },
      };
    }
    case "sui_getObject": {
      // Queried via the Address interface rather than Query.object: the
      // Registry's `domains` Table (and DomainRecord's nested `users`
      // Table) are wrapped child objects, and Query.object returns null
      // for those — only Address resolves them.
      const [objectId] = params as [string];
      return {
        query: `query($address:SuiAddress!){
          address(address:$address){
            asObject{
              asMoveObject{
                contents{ json }
              }
            }
          }
        }`,
        variables: { address: objectId },
      };
    }
    case "suix_getDynamicFieldObject": {
      const [parentId, name] = params as [string, { type: string; bcs: string }];
      return {
        query: `query($address:SuiAddress!,$type:String!,$bcs:Base64!){
          address(address:$address){
            dynamicField(name:{ type:$type, bcs:$bcs }){
              value{
                __typename
                ... on MoveValue { json }
              }
            }
          }
        }`,
        variables: { address: parentId, type: name.type, bcs: name.bcs },
      };
    }
    default:
      throw new Error(`Unsupported GraphQL migration path for method ${method}`);
  }
}

function extractGraphQlResult<T>(method: string, data: Record<string, unknown>): T {
  switch (method) {
    case "suix_queryEvents":
      return mapEventsGraphQlResult(data) as T;
    case "sui_getObject":
      return mapGetObjectGraphQlResult(data) as T;
    case "suix_getDynamicFieldObject":
      return mapDynamicFieldGraphQlResult(data) as T;
    default:
      throw new Error(`Unsupported GraphQL result mapping for method ${method}`);
  }
}

function mapGetObjectGraphQlResult(data: Record<string, unknown>): { json: Record<string, unknown> | null } {
  const address = asRecord(data.address);
  const asObject = asRecord(address?.asObject);
  const asMoveObject = asRecord(asObject?.asMoveObject);
  const contents = asRecord(asMoveObject?.contents);
  return { json: asRecord(contents?.json) };
}

function mapDynamicFieldGraphQlResult(data: Record<string, unknown>): { json: unknown } {
  const address = asRecord(data.address);
  const dynamicField = asRecord(address?.dynamicField);
  const value = asRecord(dynamicField?.value);
  return { json: value?.json ?? null };
}

function mapEventsGraphQlResult(data: Record<string, unknown>): SuiEventPage {
  const events = asRecord(data.events);
  const pageInfo = asRecord(events?.pageInfo);
  const nodes = asArray(events?.nodes);
  return {
    data: nodes.map((node) => {
      const entry = asRecord(node);
      const sender = asRecord(entry?.sender);
      const transaction = asRecord(entry?.transaction);
      const module = asRecord(entry?.transactionModule);
      const modulePackage = asRecord(module?.package);
      const contents = asRecord(entry?.contents);
      const contentType = asRecord(contents?.type);
      return {
        id: {
          txDigest: asString(transaction?.digest),
          eventSeq: String(entry?.sequenceNumber ?? ""),
        },
        packageId: asString(modulePackage?.address),
        sender: asString(sender?.address),
        timestampMs: toTimestampMs(asString(entry?.timestamp) || undefined),
        parsedJson: asRecord(contents?.json) ?? undefined,
        typeRepr: asString(contentType?.repr),
      } satisfies SuiEvent;
    }),
    hasNextPage: pageInfo?.hasNextPage === true,
    nextCursor: decodeEventCursor(asString(pageInfo?.endCursor) || null),
  };
}

function encodeEventCursor(cursor: SuiEventCursor | null): string | null {
  if (!cursor) return null;
  return cursor.graphqlCursor ?? null;
}

function decodeEventCursor(cursor: string | null): SuiEventCursor | null {
  if (!cursor) return null;
  return {
    txDigest: "",
    eventSeq: "",
    graphqlCursor: cursor,
  };
}

function toTimestampMs(value: string | undefined): string | undefined {
  if (!value) return undefined;
  const timestamp = Date.parse(value);
  return Number.isFinite(timestamp) ? String(timestamp) : undefined;
}

function asRecord(value: unknown): Record<string, unknown> | null {
  return value && typeof value === "object" && !Array.isArray(value) ? (value as Record<string, unknown>) : null;
}

function asArray(value: unknown): unknown[] {
  return Array.isArray(value) ? value : [];
}

function asString(value: unknown): string {
  return typeof value === "string" ? value : "";
}

// The Registry's `domains` field is a Move Table, which stores its entries
// as dynamic fields under the Table's own object id (not the Registry's).
// That id never changes once the Registry is created, so it is safe to
// cache for the life of the page rather than re-fetching the Registry on
// every lookup.
let registryDomainsTableIdCache: Promise<string | null> | null = null;

async function getRegistryDomainsTableId(): Promise<string | null> {
  if (!registryDomainsTableIdCache) {
    registryDomainsTableIdCache = suiRpcCall<{ json: Record<string, unknown> | null }>("sui_getObject", [
      GRANITE_LAKE_REGISTRY_ID,
    ])
      .then((result) => asString(asRecord(result.json?.domains)?.id) || null)
      .catch((error) => {
        registryDomainsTableIdCache = null;
        throw error;
      });
  }
  return registryDomainsTableIdCache;
}

type RegistryDomainRecord = {
  adminWallet: string | null;
  usersTableId: string | null;
};

// Reads the DomainRecord straight off the live Registry object instead of
// reconstructing it from DomainAdded/UserAdded events, which the network
// prunes and which can never reflect a key rotation the events didn't
// record.
async function getRegistryDomainRecord(domain: string): Promise<RegistryDomainRecord | null> {
  const tableId = await getRegistryDomainsTableId();
  if (!tableId) return null;

  const domainBytes = new TextEncoder().encode(domain);
  const result = await suiRpcCall<{ json: unknown }>("suix_getDynamicFieldObject", [
    tableId,
    { type: "vector<u8>", bcs: bcsEncodeVectorU8(domainBytes) },
  ]);

  const record = asRecord(result.json);
  if (!record) return null;

  return {
    adminWallet: safeAddress(record.admin_wallet) || null,
    usersTableId: asString(asRecord(record.users)?.id) || null,
  };
}

async function getDomainAdminWallet(domain: string | null): Promise<string | null> {
  if (!domain) {
    return null;
  }

  const record = await getRegistryDomainRecord(domain);
  return record?.adminWallet ?? null;
}

// Registration writes DomainRecord.users[wallet] = true but emits no event
// for it, so a freshly-enrolled user with no enable/disable history has no
// event trail to derive standing from. Read the live flag off the Registry
// for that case instead of reporting it as unavailable.
async function getRegistryEnabledFlag(domain: string, userWallet: string): Promise<boolean | null> {
  const record = await getRegistryDomainRecord(domain);
  if (!record?.usersTableId) return null;

  const result = await suiRpcCall<{ json: unknown }>("suix_getDynamicFieldObject", [
    record.usersTableId,
    { type: "address", bcs: bcsEncodeAddress(userWallet) },
  ]);

  return typeof result.json === "boolean" ? result.json : null;
}

type StatusPoint = {
  enabled: boolean;
  timestampMs: number;
};

function sameDomain(eventDomainValue: unknown, domain: string | null): boolean {
  if (!domain) return false;
  const fromEvent = decodeVector(eventDomainValue).decoded;
  return fromEvent.toLowerCase() === domain.toLowerCase();
}

async function findLatestStatusPoint(params: {
  eventTypes: string[];
  userWallet: string;
  domain: string | null;
  attestationTimestampMs: number;
  enabled: boolean;
}): Promise<StatusPoint | null> {
  let latest: StatusPoint | null = null;

  for (const eventType of params.eventTypes) {
    let cursor: SuiEventCursor | null = null;

    do {
      const page: SuiEventPage = await suiRpcCall<SuiEventPage>("suix_queryEvents", [
        {
          MoveEventType: eventType,
        },
        cursor,
        50,
        true,
      ]);

      for (const event of page.data ?? []) {
        if (!isAllowedPackageId(event.packageId) || !matchesExpectedEventType(event, eventType)) {
          continue;
        }

        const parsed = event.parsedJson;
        const timestamp = Number(event.timestampMs ?? 0);
        if (!parsed || !Number.isFinite(timestamp) || timestamp <= 0) {
          continue;
        }

        if (timestamp > params.attestationTimestampMs) {
          continue;
        }

        const userWallet = safeAddress(parsed.user_wallet);
        if (userWallet.toLowerCase() !== params.userWallet.toLowerCase()) {
          continue;
        }

        if (!sameDomain(parsed.domain, params.domain)) {
          continue;
        }

        if (!latest || timestamp > latest.timestampMs) {
          latest = {
            enabled: params.enabled,
            timestampMs: timestamp,
          };
        }
      }

      cursor = page.hasNextPage ? (page.nextCursor ?? null) : null;
    } while (cursor);
  }

  return latest;
}

async function getEnabledAtAttestation(params: {
  userWallet: string;
  domain: string | null;
  attestationTimestampMs: number;
}): Promise<boolean | null> {
  if (!params.domain || !Number.isFinite(params.attestationTimestampMs) || params.attestationTimestampMs <= 0) {
    return null;
  }

  const [enabledPoint, disabledPoint] = await Promise.all([
    findLatestStatusPoint({
      eventTypes: USER_ENABLED_EVENT_TYPES,
      userWallet: params.userWallet,
      domain: params.domain,
      attestationTimestampMs: params.attestationTimestampMs,
      enabled: true,
    }),
    findLatestStatusPoint({
      eventTypes: USER_DISABLED_EVENT_TYPES,
      userWallet: params.userWallet,
      domain: params.domain,
      attestationTimestampMs: params.attestationTimestampMs,
      enabled: false,
    }),
  ]);

  if (!enabledPoint && !disabledPoint) {
    // No enable/disable event exists before this attestation — the common
    // case for a user who has never been toggled since registration, since
    // add_user sets the flag without emitting an event for it. Fall
    // back to the Registry's live flag rather than reporting unavailable.
    return getRegistryEnabledFlag(params.domain, params.userWallet);
  }
  if (enabledPoint && !disabledPoint) {
    return true;
  }
  if (!enabledPoint && disabledPoint) {
    return false;
  }

  return (enabledPoint?.timestampMs ?? 0) >= (disabledPoint?.timestampMs ?? 0);
}

function toRecord(
  event: SuiEvent,
  domain: string | null,
  domainAdminWallet: string | null,
  enabled: boolean | null
): PhotoAttestationRecord | null {
  const parsed = event.parsedJson;
  if (!parsed) return null;

  const hash = decodePhotoHash(parsed.photo_hash);
  const gps = decodeVector(parsed.gps);
  const altitude = decodeVector(parsed.altitude);
  const projectId = decodeVector(parsed.project_id);
  const userWallet = safeAddress(parsed.user_wallet);

  if (!hash || !userWallet) {
    return null;
  }

  const timestampMs = event.timestampMs ?? null;

  return {
    txDigest: event.id.txDigest,
    eventSeq: event.id.eventSeq,
    timestampMs,
    checkpointTime: timestampMs ? new Date(Number(timestampMs)).toLocaleString() : "Unavailable",
    photoHashHex: hash,
    gpsRawHex: gps.hex,
    gpsDecoded: gps.decoded,
    altitudeRawHex: altitude.hex,
    altitudeDecoded: altitude.decoded,
    projectIdRawHex: projectId.hex,
    projectIdDecoded: projectId.decoded,
    userWallet,
    domain,
    domainAdminWallet,
    userEnabledAtAttestation: enabled,
  };
}

function toFileRecord(
  event: SuiEvent,
  domain: string | null,
  domainAdminWallet: string | null,
  enabled: boolean | null
): FileAttestationRecord | null {
  const parsed = event.parsedJson;
  if (!parsed) return null;

  const hash = decodePhotoHash(parsed.file_hash);
  const fileId = decodeVector(parsed.file_id);
  const projectId = decodeVector(parsed.project_id);
  const userWallet = safeAddress(parsed.user_wallet);

  if (!hash || !userWallet) {
    return null;
  }

  const timestampMs = event.timestampMs ?? null;

  return {
    txDigest: event.id.txDigest,
    eventSeq: event.id.eventSeq,
    timestampMs,
    checkpointTime: timestampMs ? new Date(Number(timestampMs)).toLocaleString() : "Unavailable",
    fileHashHex: hash,
    fileIdRawHex: fileId.hex,
    fileIdDecoded: fileId.decoded,
    projectIdRawHex: projectId.hex,
    projectIdDecoded: projectId.decoded,
    userWallet,
    domain,
    domainAdminWallet,
    userEnabledAtAttestation: enabled,
  };
}

function normalizeWalletAddress(value: string): string {
  return normalizeHex(value);
}

function matchesWallet(event: SuiEvent, wallet: string): boolean {
  const target = normalizeWalletAddress(wallet);
  const senderMatches = normalizeWalletAddress(event.sender) === target;
  const parsedWallet = safeAddress(event.parsedJson?.user_wallet);
  const parsedMatches = parsedWallet ? normalizeWalletAddress(parsedWallet) === target : false;
  return senderMatches || parsedMatches;
}

function toWalletPhotoRecord(
  event: SuiEvent,
  domain: string | null,
  domainAdminWallet: string | null,
  enabled: boolean | null
): WalletAttestationRecord | null {
  const parsed = event.parsedJson;
  if (!parsed) return null;

  const hash = decodePhotoHash(parsed.photo_hash);
  const gps = decodeVector(parsed.gps);
  const altitude = decodeVector(parsed.altitude);
  const projectId = decodeVector(parsed.project_id);
  const userWallet = safeAddress(parsed.user_wallet);

  if (!hash || !userWallet) {
    return null;
  }

  const timestampMs = event.timestampMs ?? null;

  return {
    attestType: "attest_photo",
    txDigest: event.id.txDigest,
    eventSeq: event.id.eventSeq,
    packageId: event.packageId,
    timestampMs,
    checkpointTime: timestampMs ? new Date(Number(timestampMs)).toLocaleString() : "Unavailable",
    hashHex: hash,
    photoHashHex: hash,
    gpsRawHex: gps.hex,
    gpsDecoded: gps.decoded,
    altitudeRawHex: altitude.hex,
    altitudeDecoded: altitude.decoded,
    projectIdRawHex: projectId.hex,
    projectIdDecoded: projectId.decoded,
    userWallet,
    domain,
    domainAdminWallet,
    userEnabledAtAttestation: enabled,
  };
}

function toWalletFileRecord(
  event: SuiEvent,
  domain: string | null,
  domainAdminWallet: string | null,
  enabled: boolean | null
): WalletAttestationRecord | null {
  const parsed = event.parsedJson;
  if (!parsed) return null;

  const hash = decodePhotoHash(parsed.file_hash);
  const fileId = decodeVector(parsed.file_id);
  const projectId = decodeVector(parsed.project_id);
  const userWallet = safeAddress(parsed.user_wallet);

  if (!hash || !userWallet) {
    return null;
  }

  const timestampMs = event.timestampMs ?? null;

  return {
    attestType: "attest_file",
    txDigest: event.id.txDigest,
    eventSeq: event.id.eventSeq,
    packageId: event.packageId,
    timestampMs,
    checkpointTime: timestampMs ? new Date(Number(timestampMs)).toLocaleString() : "Unavailable",
    hashHex: hash,
    fileHashHex: hash,
    fileIdRawHex: fileId.hex,
    fileIdDecoded: fileId.decoded,
    projectIdRawHex: projectId.hex,
    projectIdDecoded: projectId.decoded,
    userWallet,
    domain,
    domainAdminWallet,
    userEnabledAtAttestation: enabled,
  };
}

export async function getWalletAttestationsByWallet(options: {
  wallet: string;
  onProgress?: (progress: ScanProgress) => void;
}): Promise<WalletAttestationsResult> {
  const wallet = options.wallet.trim();
  const collected: Array<{ attestType: WalletAttestType; event: SuiEvent }> = [];
  const seen = new Set<string>();
  let pagesScanned = 0;
  let eventsScanned = 0;

  const scanTypes: Array<{ eventType: string; attestType: WalletAttestType }> = [
    ...PHOTO_ATTESTED_EVENT_TYPES.map((eventType) => ({ eventType, attestType: "attest_photo" as const })),
    ...FILE_ATTESTED_EVENT_TYPES.map((eventType) => ({ eventType, attestType: "attest_file" as const })),
  ];

  for (const { eventType, attestType } of scanTypes) {
    let cursor: SuiEventCursor | null = null;

    do {
      const page: SuiEventPage = await suiRpcCall<SuiEventPage>("suix_queryEvents", [
        {
          MoveEventType: eventType,
        },
        cursor,
        50,
        true,
      ]);

      pagesScanned += 1;
      eventsScanned += page.data?.length ?? 0;
      options.onProgress?.({ pagesScanned, eventsScanned });

      for (const event of page.data ?? []) {
        if (!isAllowedPackageId(event.packageId)) {
          continue;
        }
        if (!matchesExpectedEventType(event, eventType)) {
          continue;
        }
        if (!matchesWallet(event, wallet)) {
          continue;
        }

        const key = `${event.id.txDigest}:${event.id.eventSeq}:${attestType}`;
        if (seen.has(key)) {
          continue;
        }
        seen.add(key);
        collected.push({ attestType, event });
      }

      cursor = page.hasNextPage ? (page.nextCursor ?? null) : null;
    } while (cursor);
  }

  if (collected.length === 0) {
    return {
      wallet,
      pagesScanned,
      eventsScanned,
      photoCount: 0,
      fileCount: 0,
      events: [],
    };
  }

  // Cached by domain, not by wallet: domain comes off each event
  // individually (see F-05), so a wallet whose attestations span more than
  // one domain must not have every record collapsed onto a single answer.
  const domainAdminWalletByDomain = new Map<string, Promise<string | null>>();
  function resolveDomainAdminWallet(domain: string | null): Promise<string | null> {
    if (!domain) return Promise.resolve(null);
    const key = domain.toLowerCase();
    let cached = domainAdminWalletByDomain.get(key);
    if (!cached) {
      cached = getDomainAdminWallet(domain);
      domainAdminWalletByDomain.set(key, cached);
    }
    return cached;
  }

  const events: WalletAttestationRecord[] = [];
  for (const item of collected) {
    // Attribution comes straight from the event, never from whichever
    // capability the wallet currently happens to hold (see F-05).
    const domain = decodeVector(item.event.parsedJson?.domain).decoded || null;
    const domainAdminWallet = await resolveDomainAdminWallet(domain);
    const enabled = await getEnabledAtAttestation({
      userWallet: wallet,
      domain,
      attestationTimestampMs: Number(item.event.timestampMs ?? 0),
    });

    const record =
      item.attestType === "attest_photo"
        ? toWalletPhotoRecord(item.event, domain, domainAdminWallet, enabled)
        : toWalletFileRecord(item.event, domain, domainAdminWallet, enabled);

    if (record) {
      events.push(record);
    }
  }

  events.sort((left, right) => Number(right.timestampMs ?? 0) - Number(left.timestampMs ?? 0));

  return {
    wallet,
    pagesScanned,
    eventsScanned,
    photoCount: events.filter((event) => event.attestType === "attest_photo").length,
    fileCount: events.filter((event) => event.attestType === "attest_file").length,
    events,
  };
}

// Cached by domain, not by wallet: domain comes off each event individually
// (see F-05), so two attestations from the same wallet across different
// domains must not have one's admin wallet answer bleed into the other's.
function resolveDomainAdminWalletCached(
  domain: string | null,
  cache: Map<string, Promise<string | null>>
): Promise<string | null> {
  if (!domain) return Promise.resolve(null);
  const key = domain.toLowerCase();
  let cached = cache.get(key);
  if (!cached) {
    cached = getDomainAdminWallet(domain);
    cache.set(key, cached);
  }
  return cached;
}

export async function verifyPhotoHash(options: {
  photoHashHex: string;
  onProgress?: (progress: ScanProgress) => void;
}): Promise<VerificationResult> {
  const targetHash = normalizeHex(options.photoHashHex);
  let pagesScanned = 0;
  let eventsScanned = 0;
  const matchedEvents: SuiEvent[] = [];
  const seen = new Set<string>();

  for (const eventType of PHOTO_ATTESTED_EVENT_TYPES) {
    let cursor: SuiEventCursor | null = null;

    do {
      const page: SuiEventPage = await suiRpcCall<SuiEventPage>("suix_queryEvents", [
        {
          MoveEventType: eventType,
        },
        cursor,
        50,
        true,
      ]);

      pagesScanned += 1;
      eventsScanned += page.data?.length ?? 0;
      options.onProgress?.({ pagesScanned, eventsScanned });

      for (const event of page.data ?? []) {
        if (!isAllowedPackageId(event.packageId)) {
          continue;
        }
        if (!matchesExpectedEventType(event, eventType)) {
          continue;
        }

        const parsed = event.parsedJson;
        const eventPhotoHash = decodePhotoHash(parsed?.photo_hash);
        if (!eventPhotoHash || normalizeHex(eventPhotoHash) !== targetHash) {
          continue;
        }

        const key = `${event.id.txDigest}:${event.id.eventSeq}`;
        if (seen.has(key)) continue;
        seen.add(key);
        matchedEvents.push(event);
      }

      cursor = page.hasNextPage ? (page.nextCursor ?? null) : null;
    } while (cursor);
  }

  if (matchedEvents.length === 0) {
    return {
      hasMatch: false,
      progress: { pagesScanned, eventsScanned },
    };
  }

  const domainAdminWalletCache = new Map<string, Promise<string | null>>();
  const records: PhotoAttestationRecord[] = [];

  for (const event of matchedEvents) {
    const userWallet = safeAddress(event.parsedJson?.user_wallet);
    if (!userWallet) continue;

    // Attribution comes straight from the event, never from whichever
    // capability the wallet currently happens to hold (see F-05).
    const domain = decodeVector(event.parsedJson?.domain).decoded || null;
    const domainAdminWallet = await resolveDomainAdminWalletCached(domain, domainAdminWalletCache);
    const enabled = await getEnabledAtAttestation({
      userWallet,
      domain,
      attestationTimestampMs: Number(event.timestampMs ?? 0),
    });

    const record = toRecord(event, domain, domainAdminWallet, enabled);
    if (record) records.push(record);
  }

  if (records.length === 0) {
    return {
      hasMatch: false,
      progress: { pagesScanned, eventsScanned },
    };
  }

  const distinctWallets = new Set(records.map((record) => normalizeWalletAddress(record.userWallet)));
  const progress = { pagesScanned, eventsScanned };

  if (distinctWallets.size > 1) {
    return {
      hasMatch: true,
      collision: true,
      progress,
      records,
    };
  }

  return {
    hasMatch: true,
    collision: false,
    progress,
    record: records[0],
  };
}

export async function verifyFileHash(options: {
  fileHashHex: string;
  onProgress?: (progress: ScanProgress) => void;
}): Promise<FileVerificationResult> {
  const targetHash = normalizeHex(options.fileHashHex);
  let pagesScanned = 0;
  let eventsScanned = 0;
  const matchedEvents: SuiEvent[] = [];
  const seen = new Set<string>();

  for (const eventType of FILE_ATTESTED_EVENT_TYPES) {
    let cursor: SuiEventCursor | null = null;

    do {
      const page: SuiEventPage = await suiRpcCall<SuiEventPage>("suix_queryEvents", [
        {
          MoveEventType: eventType,
        },
        cursor,
        50,
        true,
      ]);

      pagesScanned += 1;
      eventsScanned += page.data?.length ?? 0;
      options.onProgress?.({ pagesScanned, eventsScanned });

      for (const event of page.data ?? []) {
        if (!isAllowedPackageId(event.packageId)) {
          continue;
        }
        if (!matchesExpectedEventType(event, eventType)) {
          continue;
        }

        const parsed = event.parsedJson;
        const eventFileHash = decodePhotoHash(parsed?.file_hash);
        if (!eventFileHash || normalizeHex(eventFileHash) !== targetHash) {
          continue;
        }

        const key = `${event.id.txDigest}:${event.id.eventSeq}`;
        if (seen.has(key)) continue;
        seen.add(key);
        matchedEvents.push(event);
      }

      cursor = page.hasNextPage ? (page.nextCursor ?? null) : null;
    } while (cursor);
  }

  if (matchedEvents.length === 0) {
    return {
      hasMatch: false,
      progress: { pagesScanned, eventsScanned },
    };
  }

  const domainAdminWalletCache = new Map<string, Promise<string | null>>();
  const records: FileAttestationRecord[] = [];

  for (const event of matchedEvents) {
    const userWallet = safeAddress(event.parsedJson?.user_wallet);
    if (!userWallet) continue;

    // Attribution comes straight from the event, never from whichever
    // capability the wallet currently happens to hold (see F-05).
    const domain = decodeVector(event.parsedJson?.domain).decoded || null;
    const domainAdminWallet = await resolveDomainAdminWalletCached(domain, domainAdminWalletCache);
    const enabled = await getEnabledAtAttestation({
      userWallet,
      domain,
      attestationTimestampMs: Number(event.timestampMs ?? 0),
    });

    const record = toFileRecord(event, domain, domainAdminWallet, enabled);
    if (record) records.push(record);
  }

  if (records.length === 0) {
    return {
      hasMatch: false,
      progress: { pagesScanned, eventsScanned },
    };
  }

  const distinctWallets = new Set(records.map((record) => normalizeWalletAddress(record.userWallet)));
  const progress = { pagesScanned, eventsScanned };

  if (distinctWallets.size > 1) {
    return {
      hasMatch: true,
      collision: true,
      progress,
      records,
    };
  }

  return {
    hasMatch: true,
    collision: false,
    progress,
    record: records[0],
  };
}
