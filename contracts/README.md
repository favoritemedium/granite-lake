# Granite Lake

Granite Lake is a lightweight Sui-based photo and file attestation system.

It allows:

- a contract owner to register domains and rotate domain admins
- a domain admin to authorize wallets and enable or disable them
- enabled wallets to attest photos and uploaded files on-chain
- public verification through Sui events

The system is intentionally designed to:

- minimize gas cost
- use event-only attestation for scalability
- support fast off-chain indexing and verification

---

# Architecture

## High-level Flow

```text
Contract Owner
    ↓
add_domain(domain, admin_wallet)

Domain Admin
    ↓
add_user(domain, user_wallet)

Contract
    ↓
mint UserCap
transfer UserCap → user wallet

User
    ↓
attest_photo(user_cap, registry, hash, gps, altitude, project_id)

Contract
    ↓
emit PhotoAttested event

User
    ↓
attest_file(user_cap, registry, hash, file_id, project_id)

Contract
    ↓
emit FileAttested event
```

---

# Core Design Principles

## 1. Event-Only Attestation

Photo and file attestations are NOT stored in on-chain maps.

Instead:

```move
event::emit(PhotoAttested { ... })
event::emit(FileAttested { ... })
```

This keeps attestation transactions extremely cheap.

Benefits:

- low gas
- infinite scalability
- easy indexing
- fast verification APIs

---

## 2. Capability-Based Authorization

Users receive a `UserCap` object.

Only wallets holding that capability can call:

```move
attest_photo(...)
attest_file(...)
```

The capability also carries the user's domain so the contract can validate the sender against the correct domain record and enforce enabled or disabled state during attestation.

---

# Move Package

Package name:

```text
granite_lake
```

Module:

```text
granite_lake::photo_attestation
```

---

# Main Objects

## OwnerCap

Owned by the contract owner.

Required for:

```move
add_domain()
set_domain_admin()
```

Has `store`, so ownership can be handed off to a new wallet through Sui's standard `public_transfer` without a bespoke transfer function.

---

## Registry

Shared object containing all domains.

Created during package publish.

---

## UserCap

Transferred directly to approved user wallets.

Stores:

```move
domain
user_wallet
```

Required for:

```move
attest_photo()
attest_file()
```

---

# Events

## DomainAdded

Emitted when owner adds a domain.

```move
DomainAdded {
    domain,
    admin_wallet
}
```

---

## UserAdded

Emitted when admin adds a user wallet.

```move
UserAdded {
    domain,
    admin_wallet,
    user_wallet
}
```

---

## UserEnabled

Emitted when admin enables a user wallet.

```move
UserEnabled {
    domain,
    admin_wallet,
    user_wallet
}
```

---

## UserDisabled

Emitted when admin disables a user wallet.

```move
UserDisabled {
    domain,
    admin_wallet,
    user_wallet
}
```

---

## PhotoAttested

Main photo attestation event.

```move
PhotoAttested {
    photo_hash,
    gps,
    altitude,
    project_id,
    user_wallet,
    domain
}
```

This is the primary verification source for photo attestations.

The `domain` field carries attribution so verifiers can read it straight from the event instead of reconstructing it from whichever capability the attesting wallet currently holds.

---

## FileAttested

Main file attestation event.

```move
FileAttested {
    file_hash,
    user_wallet,
    file_id,
    project_id,
    domain
}
```

This is the primary verification source for uploaded files.

The `domain` field carries attribution so verifiers can read it straight from the event.

---

## DomainAdminChanged

Emitted when the owner rotates a domain's admin wallet.

```move
DomainAdminChanged {
    domain,
    old_admin_wallet,
    new_admin_wallet
}
```

---

# Contract Functions

## add_domain

Owner-only.

```move
add_domain(
    domain,
    admin_wallet
)
```

Registers a new domain.

---

## set_domain_admin

Owner-only.

```move
set_domain_admin(
    domain,
    new_admin_wallet
)
```

Rotates a domain's admin wallet.

Gated on `OwnerCap` rather than the domain's current admin so a compromised or lost admin key can still be replaced.

---

## add_user

Domain-admin-only.

```move
add_user(
    domain,
    user_wallet
)
```

Creates and transfers a `UserCap` directly to the user wallet.

New users are enabled by default.

---

## enable_user

Domain-admin-only.

Marks an existing user as enabled.

---

## disable_user

Domain-admin-only.

Marks an existing user as disabled.

---

## attest_photo

User-only.

```move
attest_photo(
    user_cap,
    registry,
    hash,
    gps,
    altitude,
    project_id
)
```

Creates a photo attestation event.

---

## attest_file

User-only.

```move
attest_file(
    user_cap,
    registry,
    hash,
    file_id,
    project_id
)
```

Creates a file attestation event.

---

# Why Events Matter

The verification portal and verification API both rely on event scans.

That means the contract design intentionally keeps attestations event-only rather than storing per-asset objects or maps.
