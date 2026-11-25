# Selling Daylanes with Polar: setup guide

A checklist to follow in the Polar dashboard, Cloudflare and the app's `Info.plist`. Do it once in
Polar's **sandbox** (fake money, test card), check that everything works, then repeat it in the
live organization. It takes about an hour, plus Polar's account review (up to 14 days) before live
sales.

**What you are selling** (decided 2026-11-20 and 2026-11-21):

| | |
|---|---|
| Price | 49 USD once. 29 USD if bought during the 14-day trial. |
| Licence | Works forever. Includes 12 months of updates. 2 Macs per key. |
| Key expiry in Polar | **None.** The app checks the 12 months itself (see "How the pieces fit"). |
| Trial price | A code-less 20 USD discount that only the checkout server can apply. Nobody can share a code. |

## How the pieces fit

```
App (Settings > Account)
  ├─ POST /trial, /checkout ──▶ Cloudflare Worker (server/checkout) ──▶ Polar Checkout API
  │                              holds the Polar token, owns the trial clock,
  │                              adds the 20 USD discount during the trial
  └─ activate / validate / deactivate ──▶ Polar customer-portal licence API (no token needed)
```

- The **Worker** decides whether you are still in the trial, so changing the Mac's clock doesn't
  help. It creates a Polar checkout at 29 or 49 USD and the app opens it in the browser.
- After paying, the customer finds the key on their Polar **purchases page**. Polar's receipt email
  links to it. They paste it into Settings > Account.
- The app reads the purchase date from the key and compares it with the build's release date,
  which `bin/build-desktop` writes into `Info.plist`. A build released more than 12 months after
  the purchase asks for a renewal; older builds keep working.

### Where Stripe fits

You don't need your own Stripe account. Polar is the Merchant of Record: it charges the card,
handles VAT and sales tax, and sends invoices. Stripe only appears when you set up **payouts**:
Polar uses Stripe Connect Express, so you go through Stripe's onboarding (identity, bank account)
from inside Polar. Your bank account must be in the same country as you (Italy is supported) and in
its local currency. Wise, Payoneer and Revolut virtual accounts usually fail Stripe's checks.

Fees on Polar's Starter plan: 5% + 0.50 USD per sale, +1.5% for non-US cards, plus Stripe's payout
fee. A 49 USD sale nets about 45.30 USD, a 29 USD sale about 26.60 USD.

## Step 1. Create the sandbox organization

1. Go to <https://sandbox.polar.sh/start> and create an organization called **Daylanes**.
   The sandbox is a separate account. Nothing there touches real money.
2. Open **Settings** and copy the **Organization ID** (a UUID). You need it in step 6.

## Step 2. Create the licence key benefit

**Products > Benefits > + New Benefit**, type **License Keys**:

| Setting | Value |
|---|---|
| Description | `Daylanes licence key` |
| Prefix (custom branding) | `DAYLANES` |
| Expiration | **Off.** Do not set 1 year: that would expire the key and lock owners out of the version they paid for. |
| Activation limits | **On, 2** |
| Let customers deactivate instances | **On.** They can free a Mac from their purchases page as well as from the app. |
| Usage limit | **Off** |

## Step 3. Create the product

**Products > New Product**:

| Setting | Value |
|---|---|
| Name | `Daylanes` |
| Description | One or two sentences. Polar's review wants a real description. |
| Pricing | **One-time purchase**, **Fixed price**, **49 USD** |
| Benefits | Attach the licence key benefit from step 2 |

Save, then copy the **Product ID** from the product page (or its URL).

## Step 4. Create the trial discount

**Products > Discounts > New Discount**:

| Setting | Value |
|---|---|
| Name | `Trial price` (customers see this name at checkout) |
| Code | **Leave empty.** Without a code it can only be applied through the API, by the Worker. |
| Type | **Fixed Amount Discount**, **20 USD** |
| Recurring | **Once** |
| Products | Only **Daylanes** |
| Starts/ends at, max redemptions | Leave empty |

Copy the **Discount ID**.

## Step 5. Create the access token for the Worker

**Settings > Developers > New Token**:

- Name: `daylanes-checkout-worker`
- Expiration: the longest offered. Put a reminder in your calendar to rotate it before then.
- Scopes: **`checkouts:write`** only.

Copy the token (it starts with `polar_oat_`). It is shown once. Never put it in the app or in Git.

## Step 6. Deploy the checkout Worker on Cloudflare

From the repository, on your Mac:

```sh
cd server/checkout
cp wrangler.example.toml wrangler.toml
npx wrangler login                       # opens Cloudflare in the browser
npx wrangler kv namespace create TRIALS  # prints an id
```

Edit `server/checkout/wrangler.toml`:

- `id` under `[[kv_namespaces]]`: the KV id just printed
- `POLAR_API`: `https://sandbox-api.polar.sh` (already set for testing)
- `PRODUCT_ID`: from step 3
- `TRIAL_DISCOUNT_ID`: from step 4
- `SUCCESS_URL`: leave empty for now (Polar shows its own confirmation page). Later, a thank-you
  page on daylanes.app that says "Find your key on your Polar purchases page and paste it into
  Settings > Account" is nicer.
- Optional: add a Worker route for a domain you manage.

Then:

```sh
npx wrangler secret put POLAR_TOKEN      # paste the token from step 5
npx wrangler deploy                      # prints https://daylanes-checkout.<you>.workers.dev
node --test tests/worker.test.mjs        # optional: the Worker's own tests
```

Quick check (any UUID works as an install ID):

```sh
curl -s -X POST https://daylanes-checkout.<you>.workers.dev/trial \
  -H 'Content-Type: application/json' -d '{"install_id":"3f0c3a8e-2b9d-4c55-9a51-0b6c1f4e7d21"}'
# {"trial_ends_at":"…","trial_days":14,"in_trial":true}
curl -s -X POST https://daylanes-checkout.<you>.workers.dev/checkout \
  -H 'Content-Type: application/json' -d '{"install_id":"3f0c3a8e-2b9d-4c55-9a51-0b6c1f4e7d21"}'
# {"url":"https://sandbox.polar.sh/checkout/…","price":29}
```

Open that URL: the checkout should show 49 USD minus "Trial price" 20 USD = 29 USD.

## Step 7. Point the app at Polar and the Worker

The open-source build runs without payments by default. To test your own paid build, configure these values in `desktop/Info.plist`:

| Key | Value |
|---|---|
| `TrackerPolarAPI` | `https://sandbox-api.polar.sh` while testing |
| `TrackerPolarOrganizationID` | the Organization ID from step 1 |
| `TrackerCheckoutServer` | the Worker URL from step 6, ending in `/` |
| `TrackerCheckoutLink` | optional Polar Checkout Link when no Worker URL is configured (step 9) |
| `TrackerReleaseDate` | leave empty: `bin/build-desktop` writes the build date. Set `TRACKER_RELEASE_DATE=2026-12-01` to override. |

Rebuild with `TRACKER_ENABLE_PAYMENTS=1 bin/build-desktop`. The official `bin/release` entry point always enables payments. A plain `bin/build-desktop` build excludes licensing and the checkout configuration.

## Step 8. Test end to end in the sandbox

Test card: `4242 4242 4242 4242`, any future expiry, any CVC. Sandbox emails only go to members
of the organization, so buy with your own email.

1. **Buy inside the trial.** Settings > Account > "Buy for 29 USD…". Pay. Open your purchases
   page from the receipt email, copy the `DAYLANES-…` key, paste it, Activate. The pane should say
   "Licensed to …" and "Updates included until <a year from today>".
2. **Buy after the trial.** In Cloudflare > Workers KV > TRIALS, edit this Mac's `trial:<id>` value
   to a past date (for example `2020-01-01T00:00:00.000Z`). The Buy button on a second test
   install (or the curl above with a new UUID and an edited KV entry) should show 49 USD.
3. **Third Mac is refused.** Activate the same key twice more (the app on a second Mac, or a curl
   to `https://sandbox-api.polar.sh/v1/customer-portal/license-keys/activate` with
   `{"key":"…","organization_id":"…","label":"test"}`). The third activation must fail with 403.
4. **Deactivate.** "Deactivate this Mac…" frees the slot, and activating elsewhere works again.
5. **Refund.** Refund the order in Polar. On the next daily check the app removes the key and
   returns to the unlicensed state.

## Step 9. Website checkout link (for the Cloudflare site, PR 19)

The site's Buy button doesn't know about a trial, so it sells at 49 USD. Two options:

- **Polar Checkout Link (simplest):** Products > Checkout Links > New, product Daylanes, discount
  codes off. Use the link on the site's Buy button.
- **Worker:** link to `https://<worker>/buy`, which creates a fresh 49 USD checkout and redirects.

The production checkout Worker sets `SUCCESS_URL` to the Daylanes licence page, which verifies
the checkout with Polar before reporting a GA4 `purchase`. A browser sends it only after opt-in
to Analytics. The checkout ID is the transaction ID, and the event value is the discounted
price before tax in the checkout currency. The site connects to the checkout Worker over the
`CheckoutAnalytics` service binding. Deploy the checkout Worker with an empty `SUCCESS_URL`
first when bringing up a new production environment, deploy the site, then enable the redirect.
The licence page is excluded from indexing. Use Polar's Sales report for all purchases and refunds.

In a sandbox, complete an approved test payment and check the GA tag in a non-production stream.
An unpaid checkout or a visit without Analytics consent must never send a `purchase`. A download
link reports `download_click`.

## Step 10. Go live

1. In the live dashboard (<https://polar.sh>), create the **Daylanes** organization and repeat
   steps 2 to 5. IDs and tokens differ from the sandbox.
2. **Finance > Account > Continue with account setup:** choose Italy and go through Stripe's
   onboarding (identity and bank account).
3. Complete Polar's review checklist: product with description, checkout, identity verification,
   payout account, a reachable website (daylanes.app), a verified support email, and social links
   in Settings. Submit the review. It can take up to 14 days, and Polar asks you to have the site
   live before submitting. Don't test with real cards; use the sandbox or a 100% discount code.
4. Update `wrangler.toml` (`POLAR_API = "https://api.polar.sh"`, live product and discount IDs),
   `npx wrangler secret put POLAR_TOKEN` with the live token, and `npx wrangler deploy`.
5. Update `Info.plist` (`TrackerPolarAPI = https://api.polar.sh`, live Organization ID), build,
   sign and notarize the DMG.

## Renewals (after 12 months)

For now a renewal is a new purchase of the same product at 49 USD. It gives a new key, which the
customer pastes in Settings > Account. A cheaper renewal (the plan suggests about 29 USD) needs a
second product, "Daylanes update renewal", with the same licence benefit. That is only needed
before the first owners reach month 12, so there is time.

## App identity

The Mac bundle ships as `Daylanes.app`. The bundle identifier and Keychain service names stay
stable so installed copies can keep their stored trial and licence dates across app-name changes.

## After the trial

An unlicensed copy locks: the main window, Settings and menu bar show only Buy and the licence key
field. Tracking keeps running and nothing is deleted. The bundled CLI and MCP server don't check the licence.
