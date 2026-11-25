import assert from "node:assert/strict";
import test from "node:test";

import worker, { paidCheckout, trial } from "../worker.mjs";

const ID = "3f0c3a8e-2b9d-4c55-9a51-0b6c1f4e7d21";

function environment() {
  const store = new Map();
  return {
    TRIALS: {
      getWithMetadata: async (key) => store.get(key) ?? { value: null, metadata: null },
      put: async (key, value, { metadata }) => void store.set(key, { value, metadata }),
    },
    POLAR_TOKEN: "polar_oat_test",
    POLAR_API: "https://sandbox-api.polar.sh",
    PRODUCT_ID: "product-1",
    TRIAL_DISCOUNT_ID: "discount-1",
    SUCCESS_URL: "https://daylanes.app/thanks?checkout_id={CHECKOUT_ID}",
    store,
  };
}

function post(path, body) {
  return new Request(`https://checkout.example${path}`, { method: "POST", body: JSON.stringify(body) });
}

test("the first trial call fixes the end date and later calls keep it", async () => {
  const env = environment();
  const start = new Date("2026-11-21T10:00:00Z");
  const first = await trial(env, ID, start);
  assert.deepEqual(first, { trial_ends_at: "2026-12-05T10:00:00.000Z", trial_days: 14, in_trial: true });
  const later = await trial(env, ID, new Date(first.trial_ends_at));
  assert.equal(later.trial_ends_at, first.trial_ends_at);
  assert.equal(later.in_trial, false);
});

test("existing seven-day trials gain seven days from their original deadline", async () => {
  const env = environment();
  env.store.set(`trial:${ID}`, { value: "2026-11-28T10:00:00.000Z", metadata: null });
  const extended = await trial(env, ID, new Date("2026-11-29T00:00:00Z"));
  assert.deepEqual(extended, { trial_ends_at: "2026-12-05T10:00:00.000Z", trial_days: 14, in_trial: true });
  assert.equal((await trial(env, ID, new Date(extended.trial_ends_at))).in_trial, false);
});

test("checkout applies the trial discount only inside the trial", async (t) => {
  const env = environment();
  const sent = [];
  t.mock.method(globalThis, "fetch", async (url, init) => {
    sent.push({ url, init, body: JSON.parse(init.body) });
    return new Response(JSON.stringify({ url: "https://sandbox.polar.sh/checkout/abc" }), { status: 201 });
  });
  env.store.set(`trial:${ID}`, { value: new Date(Date.now() - 86_400_000).toISOString(), metadata: null });
  const inside = await (await worker.fetch(post("/checkout", { install_id: ID }), env)).json();
  assert.deepEqual(inside, { url: "https://sandbox.polar.sh/checkout/abc", price: 29 });
  assert.equal(sent[0].url, "https://sandbox-api.polar.sh/v1/checkouts/");
  assert.equal(sent[0].init.headers.Authorization, "Bearer polar_oat_test");
  assert.deepEqual(sent[0].body, {
    products: ["product-1"], allow_discount_codes: false,
    success_url: "https://daylanes.app/thanks?checkout_id={CHECKOUT_ID}",
    discount_id: "discount-1", metadata: { install_id: ID },
  });

  env.store.set(`trial:${ID}`, { value: "2020-01-01T00:00:00.000Z", metadata: null });
  const after = await (await worker.fetch(post("/checkout", { install_id: ID }), env)).json();
  assert.equal(after.price, 49);
  assert.equal(sent[1].body.discount_id, undefined);
});

test("bad install IDs and unknown paths are refused", async () => {
  const env = environment();
  assert.equal((await worker.fetch(post("/trial", { install_id: "nope" }), env)).status, 400);
  assert.equal((await worker.fetch(post("/trial", "x"), env)).status, 400);
  assert.equal((await worker.fetch(new Request("https://checkout.example/other"), env)).status, 404);
});

test("a Polar error is reported, not hidden", async (t) => {
  t.mock.method(globalThis, "fetch", async () => new Response("bad token", { status: 401 }));
  const response = await worker.fetch(post("/checkout", { install_id: ID }), environment());
  assert.equal(response.status, 502);
  assert.match((await response.json()).error, /401/);
});

test("without a success URL Polar's own confirmation page is used", async (t) => {
  const env = { ...environment(), SUCCESS_URL: "" };
  let sent;
  t.mock.method(globalThis, "fetch", async (url, init) => {
    sent = JSON.parse(init.body);
    return new Response(JSON.stringify({ url: "https://sandbox.polar.sh/checkout/x" }), { status: 201 });
  });
  await worker.fetch(post("/checkout", { install_id: ID }), env);
  assert.equal("success_url" in sent, false);
});

test("paid checkout exposes the discounted purchase value without customer details", async (t) => {
  const env = environment();
  t.mock.method(globalThis, "fetch", async (url, init) => {
    assert.equal(url, `${env.POLAR_API}/v1/checkouts/${ID}`);
    assert.equal(init.headers.Authorization, "Bearer polar_oat_test");
    return Response.json({
      id: ID, product_id: env.PRODUCT_ID, status: "succeeded", currency: "usd",
      net_amount: 2900, tax_amount: 638, total_amount: 3538,
      customer_email: "unused@example.test", client_secret: "never exposed",
    });
  });
  assert.deepEqual(await paidCheckout(env, ID), {
    transaction_id: ID,
    value: 29,
    currency: "USD",
    items: [{ item_id: env.PRODUCT_ID, item_name: "Daylanes licence", price: 29, quantity: 1 }],
  });
});

test("only a successful Daylanes checkout with a positive amount counts", async (t) => {
  const env = environment();
  const valid = { id: ID, product_id: env.PRODUCT_ID, status: "succeeded", currency: "usd", net_amount: 4900 };
  const fetch = t.mock.method(globalThis, "fetch", async () => Response.json(valid));
  assert.equal(await paidCheckout(env, "../orders"), null);
  assert.equal(fetch.mock.callCount(), 0);
  for (const data of [
    { status: "confirmed" },
    { product_id: "unrelated-product" },
    { id: "mismatched-id" },
    { net_amount: 0 },
  ]) {
    fetch.mock.mockImplementationOnce(async () => Response.json({ ...valid, ...data }));
    assert.equal(await paidCheckout(env, ID), null);
  }
  fetch.mock.mockImplementationOnce(async () => new Response(null, { status: 404 }));
  assert.equal(await paidCheckout(env, ID), null);
  fetch.mock.mockImplementationOnce(async () => new Response(null, { status: 403 }));
  await assert.rejects(paidCheckout(env, ID), /403/);
});
