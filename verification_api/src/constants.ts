import "dotenv/config";

export const HOST = process.env.HOST?.trim() || "0.0.0.0";
export const PORT = Number(process.env.PORT || 8081);

export const SUI_RPC_URL = process.env.SUI_RPC_URL?.trim() || "https://graphql.testnet.sui.io/graphql";

// GRANITE_LAKE_PACKAGE_ID is always "whatever package is current". If this
// contract is ever upgraded, set it to the new package id and set
// GRANITE_LAKE_ORIGINAL_PACKAGE_ID to this one - Sui package upgrades
// publish at a new address while events from the original address remain
// permanently queryable only under that address, so both need to be
// recognized to find every attestation regardless of when it was made.
export const GRANITE_LAKE_PACKAGE_ID = process.env.GRANITE_LAKE_PACKAGE_ID?.trim() || "";

export const GRANITE_LAKE_ORIGINAL_PACKAGE_ID =
  process.env.GRANITE_LAKE_ORIGINAL_PACKAGE_ID?.trim() || GRANITE_LAKE_PACKAGE_ID;

export const GRANITE_LAKE_REGISTRY_ID = process.env.GRANITE_LAKE_REGISTRY_ID?.trim() || "";

export const PHOTO_ATTESTED_EVENT_TYPES = [
  `${GRANITE_LAKE_PACKAGE_ID}::photo_attestation::PhotoAttested`,
  `${GRANITE_LAKE_ORIGINAL_PACKAGE_ID}::photo_attestation::PhotoAttested`,
];
export const FILE_ATTESTED_EVENT_TYPES = [
  `${GRANITE_LAKE_PACKAGE_ID}::photo_attestation::FileAttested`,
  `${GRANITE_LAKE_ORIGINAL_PACKAGE_ID}::photo_attestation::FileAttested`,
];
export const DOMAIN_ADDED_EVENT_TYPES = [
  `${GRANITE_LAKE_PACKAGE_ID}::photo_attestation::DomainAdded`,
  `${GRANITE_LAKE_ORIGINAL_PACKAGE_ID}::photo_attestation::DomainAdded`,
];
export const USER_ADDED_EVENT_TYPES = [
  `${GRANITE_LAKE_PACKAGE_ID}::photo_attestation::UserAdded`,
  `${GRANITE_LAKE_ORIGINAL_PACKAGE_ID}::photo_attestation::UserAdded`,
];
export const USER_ENABLED_EVENT_TYPES = [
  `${GRANITE_LAKE_PACKAGE_ID}::photo_attestation::UserEnabled`,
  `${GRANITE_LAKE_ORIGINAL_PACKAGE_ID}::photo_attestation::UserEnabled`,
];
export const USER_DISABLED_EVENT_TYPES = [
  `${GRANITE_LAKE_PACKAGE_ID}::photo_attestation::UserDisabled`,
  `${GRANITE_LAKE_ORIGINAL_PACKAGE_ID}::photo_attestation::UserDisabled`,
];

export const USER_CAP_TYPE = `${GRANITE_LAKE_PACKAGE_ID}::photo_attestation::UserCap`;
export const USER_CAP_TYPE_ORIGINAL = `${GRANITE_LAKE_ORIGINAL_PACKAGE_ID}::photo_attestation::UserCap`;
