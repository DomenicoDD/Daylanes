// Daylanes checkout server: a Cloudflare Worker that owns the trial clock and creates
// Polar checkouts. The Polar access token lives here as a secret; the app never sees it.
//
// POST /trial     {"install_id": "<uuid>"}  -> {"trial_ends_at": ISO date, "trial_days": 14, "in_trial": bool}
// POST /checkout  {"install_id": "<uuid>"}  -> {"url": Polar checkout URL, "price": 29 | 39}
// GET  /buy                                 -> 302 to a Polar checkout at the full price (for the website)
//
// Every checkout accepts discount codes, so promotions (a Black Friday code, say) need only a
// new code in Polar. Polar applies one discount per checkout: a code replaces the trial price.
//
// Bindings (wrangler.toml and `wrangler secret put`):
//   TRIALS             KV namespace, key "trial:<install id>" -> trial end (ISO date) and duration metadata
//   POLAR_TOKEN        secret, Organization Access Token with the checkouts:write scope
//   POLAR_API          https://sandbox-api.polar.sh while testing, https://api.polar.sh live
//   PRODUCT_ID         the Daylanes product's ID
//   TRIAL_DISCOUNT_ID  the code-less 10 USD discount's ID (39 USD list price -> 29 USD)
//   SUCCESS_URL        optional page shown after paying, may contain checkout_id={CHECKOUT_ID}

export const TRIAL_DAYS = 14;
const LEGACY_TRIAL_DAYS = 7;
const DAY_MS = 86_400_000;
const FULL_PRICE = 39;
const TRIAL_PRICE = 29;
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    try {
      if (request.method === "POST" && url.pathname === "/trial") {
        const id = await installID(request);
        return json(await trial(env, id, new Date()));
      }
      if (request.method === "POST" && url.pathname === "/checkout") {
        const id = await installID(request);
        const { in_trial } = await trial(env, id, new Date());
        const checkout = await createCheckout(env, { installID: id, discounted: in_trial });
        return json({ url: checkout.url, price: in_trial ? TRIAL_PRICE : FULL_PRICE });
      }
      if (request.method === "GET" && url.pathname === "/buy") {
        const checkout = await createCheckout(env, { installID: null, discounted: false });
        return Response.redirect(checkout.url, 302);
      }
      return json({ error: "Not found" }, 404);
    } catch (error) {
      const status = error instanceof RequestError ? error.status : 502;
      return json({ error: error.message }, status);
    }
  },
};

class RequestError extends Error {
  constructor(message, status = 400) {
    super(message);
    this.status = status;
  }
}

async function installID(request) {
  let body;
  try {
    body = await request.json();
  } catch {
    throw new RequestError("Send a JSON body with install_id");
  }
  const id = typeof body?.install_id === "string" ? body.install_id.toLowerCase() : "";
  if (!UUID.test(id)) throw new RequestError("install_id must be a UUID");
  return id;
}

// Keep the original start of existing seven-day trials. The stored ISO date stays compatible
// with older Worker versions. New records include their duration so the extension is applied once.
export async function trial(env, id, now) {
  const key = `trial:${id}`;
  const { value, metadata } = await env.TRIALS.getWithMetadata(key);
  const trialDays = metadata?.trial_days ?? LEGACY_TRIAL_DAYS;
  const end = value
    ? new Date(Date.parse(value) + (TRIAL_DAYS - trialDays) * DAY_MS)
    : new Date(now.getTime() + TRIAL_DAYS * DAY_MS);
  const trialEndsAt = end.toISOString();
  if (!value) {
    await env.TRIALS.put(key, trialEndsAt, { metadata: { trial_days: TRIAL_DAYS } });
  }
  return { trial_ends_at: trialEndsAt, trial_days: TRIAL_DAYS, in_trial: now < end };
}

export async function createCheckout(env, { installID, discounted }) {
  const body = { products: [env.PRODUCT_ID], allow_discount_codes: true };
  // Without a success URL Polar shows its own confirmation page.
  if (env.SUCCESS_URL) body.success_url = env.SUCCESS_URL;
  if (discounted) body.discount_id = env.TRIAL_DISCOUNT_ID;
  if (installID) body.metadata = { install_id: installID };
  const response = await fetch(`${env.POLAR_API}/v1/checkouts/`, {
    method: "POST",
    headers: { Authorization: `Bearer ${env.POLAR_TOKEN}`, "Content-Type": "application/json" },
    body: JSON.stringify(body),
  });
  if (!response.ok) {
    throw new RequestError(`Polar refused the checkout (${response.status}): ${await response.text()}`, 502);
  }
  return response.json();
}

// The site gets only ecommerce fields. Customer and payment details stay with Polar.
export async function paidCheckout(env, id) {
  if (typeof id !== "string" || !UUID.test(id)) return null;
  const response = await fetch(`${env.POLAR_API}/v1/checkouts/${id}`, {
    headers: { Authorization: `Bearer ${env.POLAR_TOKEN}` },
  });
  if (response.status === 404) return null;
  if (!response.ok) throw new Error(`Polar checkout lookup failed (${response.status})`);

  const checkout = await response.json();
  if (checkout.id !== id || checkout.product_id !== env.PRODUCT_ID || checkout.status !== "succeeded") return null;
  if (!Number.isSafeInteger(checkout.net_amount) || checkout.net_amount <= 0) return null;
  const currency = checkout.currency?.toUpperCase();
  if (!/^[A-Z]{3}$/.test(currency)) return null;
  const { maximumFractionDigits } = new Intl.NumberFormat("en", { style: "currency", currency }).resolvedOptions();
  const value = checkout.net_amount / 10 ** maximumFractionDigits;
  return {
    transaction_id: checkout.id,
    value,
    currency,
    items: [{ item_id: checkout.product_id, item_name: "Daylanes licence", price: value, quantity: 1 }],
  };
}

function json(value, status = 200) {
  return new Response(JSON.stringify(value), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}
