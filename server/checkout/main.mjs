import { WorkerEntrypoint } from "cloudflare:workers";
import { paidCheckout } from "./worker.mjs";

export { default } from "./worker.mjs";

export class CheckoutAnalytics extends WorkerEntrypoint {
  getPaidCheckout(id) {
    return paidCheckout(this.env, id);
  }
}
