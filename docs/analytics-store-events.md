# Paywall & StoreKit Analytics Events

This document enumerates the commerce-focused analytics events emitted by `Store` via `AnalyticsLogging`. Use these helpers to avoid string drift and to keep telemetry privacy-safe.

## Catalog lifecycle

| Event name | Trigger | Params |
| --- | --- | --- |
| `paywall_catalog_load_started` | `Store.loadProducts()` begins a refresh. | – |
| `paywall_catalog_load_succeeded` | Live catalog fetch returns successfully. | `count` — number of products returned. |
| `paywall_catalog_load_recovered_from_cache` | Network lookup failed but a fresh cache was served. | `count` — number of cached products. |
| `paywall_catalog_load_failed` | Catalog refresh failed without a usable cache. | `error_code` — sanitized code from `AppError`/`NSError` when available. |

## Purchase flow

| Event name | Trigger | Params |
| --- | --- | --- |
| `paywall_purchase_started` | User initiates a purchase from the paywall. | `product_id` |
| `paywall_purchase_succeeded` | Transaction verified and entitlement granted. | `product_id` |
| `paywall_purchase_cancelled` | Customer dismissed the purchase sheet. | `product_id` |
| `paywall_purchase_pending` | StoreKit reports a pending transaction (e.g., Ask to Buy). | `product_id` |
| `paywall_purchase_failed` | Purchase failed for a recoverable or fatal error. | `product_id`, optional `error_code` |
| `paywall_consumable_delivered` | Consumable product was fulfilled. | `product_id` |
| `paywall_purchase_revoked` | Apple revoked a previously granted entitlement. | `product_id` |

## Restore & subscription health

| Event name | Trigger | Params |
| --- | --- | --- |
| `paywall_restore_started` | Manual restore flow kicked off. | – |
| `paywall_restore_succeeded` | Restore flow completed with at least one product. | `count` — entitlements restored. |
| `paywall_restore_failed` | Restore flow failed or returned empty. | optional `error_code` |
| `paywall_subscription_inactive` | Subscription status indicates expired or revoked access. | `product_id` |

## Offer codes

| Event name | Trigger | Params |
| --- | --- | --- |
| `paywall_offer_code_redemption_shown` | Offer-code redemption sheet presented. | – |

## Error codes

`error_code` values are sanitized strings:

* `app_<code>` for `AppError` (see `Errors.swift` for stable IDs).
* `storekit_<code>` for `StoreKit` errors.
* `<domain>_<code>` for all other `NSError` types with the domain periods replaced by underscores.

Always pipe failures through `Store.analyticsErrorCode(from:)` to keep this encoding stable.
