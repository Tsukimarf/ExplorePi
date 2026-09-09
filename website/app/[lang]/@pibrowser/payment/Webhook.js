// =============================================================================
// ExplorePi — Dynamic Webhook Processor (Node.js 20+, ESM)
// Branch: Tsukimarf-patch-1
//
// Mounts at POST /api/webhooks/pi. Handlers are registered dynamically in
// the `handlers` map below — adding support for a new event type never
// touches the route/dispatch logic, only the map.
//
// Backed by:
//   explorepi_payment_update.sql            (payments, fn_payment_mark_*)
//   explorepi_payment_partial_update.sql    (fn_payment_apply_partial)
//   explorepi_payment_tolerance_update.sql  (fn_calculate_tolerance)
//   explorepi_webhook_events_schema.sql     (webhook_events, fn_webhook_*)
//
// Flow per request:
//   1. Verify HMAC signature against the raw body (constant-time compare).
//   2. fn_webhook_claim() — atomic idempotency guard. If it returns NULL,
//      this event_id is already processed/in-flight: ack 200 and stop.
//      This makes Pi's at-least-once webhook delivery safe to retry blindly.
//   3. Dynamic dispatch: look up handlers[event.type], run it inside a
//      single pg transaction.
//   4. fn_webhook_mark_result() — record processed / unhandled / failed.
//   5. Always respond 200 once claimed (Pi/most providers retry on non-2xx,
//      which is only useful for transient DB errors — see catch block).
// =============================================================================

import express from 'express'
import crypto from 'crypto'
import pg from 'pg'
import { approvePayment, completePayment } from './piPayment.js'

const { Pool } = pg
const pool = new Pool({ connectionString: process.env.DATABASE_URL })

const WEBHOOK_SECRET = process.env.PI_WEBHOOK_SECRET  // shared secret from Pi Developer Portal
const MAX_RETRIES = 5

// -----------------------------------------------------------------------------
// Signature verification — HMAC-SHA256 over the raw request body, hex-encoded,
// sent in the X-Pi-Signature header. Constant-time compare to avoid timing
// side-channels.
// -----------------------------------------------------------------------------
function verifySignature(rawBody, signatureHeader) {
    if (!WEBHOOK_SECRET) {
        console.warn('[webhook] PI_WEBHOOK_SECRET not set — skipping signature verification')
        return null  // unknown, not false — lets the route decide policy
    }
    if (!signatureHeader) return false

    const expected = crypto
        .createHmac('sha256', WEBHOOK_SECRET)
        .update(rawBody)
        .digest('hex')

    const a = Buffer.from(expected, 'utf8')
    const b = Buffer.from(signatureHeader, 'utf8')
    if (a.length !== b.length) return false
    return crypto.timingSafeEqual(a, b)
}

// -----------------------------------------------------------------------------
// Dynamic handler registry — key = event.type from the webhook payload.
// Each handler receives (payload, dbClient) and runs inside the caller's
// transaction. Return value is ignored; throw to mark the event 'failed'.
// -----------------------------------------------------------------------------
const handlers = {
    async 'payment.approval'(payload, client) {
        const { paymentId } = payload
        await approvePayment(paymentId)
        await client.query('SELECT fn_payment_mark_approved($1)', [paymentId])
    },

    async 'payment.completion'(payload, client) {
        const { paymentId, txid } = payload
        await completePayment(paymentId, txid)
        await client.query(
            'SELECT fn_payment_mark_completed($1, $2, $3)',
            [paymentId, txid, payload.horizonLedger ?? null]
        )
    },

    async 'payment.cancelled'(payload, client) {
        const { paymentId, reason } = payload
        await client.query(
            'SELECT fn_payment_mark_cancelled($1, $2)',
            [paymentId, reason ?? 'cancelled via webhook']
        )
    },

    async 'payment.error'(payload, client) {
        const { paymentId, error } = payload
        await client.query(
            'SELECT fn_payment_mark_error($1, $2)',
            [paymentId, error ?? 'unspecified error']
        )
    },

    async 'payment.partial'(payload, client) {
        const { paymentId, txid, amount, horizonLedger, note } = payload
        await client.query(
            'SELECT fn_payment_apply_partial($1, $2, $3, $4, $5)',
            [paymentId, txid, amount, horizonLedger ?? null, note ?? null]
        )
    },

    async 'horizon.payment'(payload, client) {
        const { txid, horizonLedger } = payload
        await client.query(
            'SELECT fn_payment_reconcile_from_horizon($1, $2)',
            [txid, horizonLedger]
        )
    },
}

// -----------------------------------------------------------------------------
// Router
// -----------------------------------------------------------------------------
const router = express.Router()

// Raw body needed for signature verification — mount this BEFORE any
// express.json() middleware on this specific route.
router.post('/webhooks/pi', express.raw({ type: 'application/json' }), async (req, res) => {
    const rawBody = req.body  // Buffer, thanks to express.raw()
    const signatureHeader = req.get('x-pi-signature')
    const signatureValid = verifySignature(rawBody, signatureHeader)

    if (signatureValid === false) {
        console.warn('[webhook] rejected: invalid signature')
        return res.status(401).json({ error: 'invalid signature' })
    }

    let event
    try {
        event = JSON.parse(rawBody.toString('utf8'))
    } catch {
        return res.status(400).json({ error: 'invalid JSON body' })
    }

    const eventId = event.id ?? event.eventId
    const eventType = event.type
    const payload = event.data ?? event.payload ?? {}
    const paymentId = payload.paymentId ?? null

    if (!eventId || !eventType) {
        return res.status(400).json({ error: 'missing event id/type' })
    }

    const safeHeaders = { ...req.headers }
    delete safeHeaders['x-pi-signature']
    delete safeHeaders['authorization']

    const client = await pool.connect()
    try {
        // Step 1 — atomic idempotency claim
        const claimResult = await client.query(
            `SELECT * FROM fn_webhook_claim($1,$2,$3,$4,$5,$6,$7,$8)`,
            [eventId, eventType, 'pi-network', paymentId, payload, safeHeaders, signatureValid, MAX_RETRIES]
        )
        const claimed = claimResult.rows[0]

        if (!claimed) {
            // Already processed, currently processing, or retries exhausted.
            // Ack 200 regardless — re-processing would be either redundant
            // or (for exhausted retries) something a human should triage
            // via the webhook_events dead-letter query, not a live retry.
            return res.status(200).json({ status: 'already_handled' })
        }

        // Step 2 — dynamic dispatch
        const handler = handlers[eventType]

        if (!handler) {
            await client.query('SELECT fn_webhook_mark_result($1,$2,$3)', [eventId, 'unhandled', null])
            console.warn(`[webhook] no handler registered for event.type="${eventType}"`)
            return res.status(200).json({ status: 'unhandled', eventType })
        }

        await client.query('BEGIN')
        try {
            await handler(payload, client)
            await client.query('COMMIT')
            await client.query('SELECT fn_webhook_mark_result($1,$2,$3)', [eventId, 'processed', null])
            return res.status(200).json({ status: 'processed', eventType })
        } catch (handlerErr) {
            await client.query('ROLLBACK')
            await client.query('SELECT fn_webhook_mark_result($1,$2,$3)', [eventId, 'failed', handlerErr.message])
            console.error(`[webhook] handler failed for event ${eventId} (${eventType}):`, handlerErr)
            // 200, not 500: we've durably recorded the failure and it will
            // be retried on the NEXT delivery of this event_id (still under
            // MAX_RETRIES) or triaged from the dead-letter query. Returning
            // 500 here would just make the provider hammer us with retries
            // for what might be a permanent, non-transient failure.
            return res.status(200).json({ status: 'failed', eventType })
        }
    } catch (err) {
        // Failure before/around the claim itself (DB unreachable, etc.) —
        // this one IS worth a provider-level retry, so surface 500.
        console.error('[webhook] unhandled error processing webhook:', err)
        return res.status(500).json({ error: 'internal error' })
    } finally {
        client.release()
    }
})

// -----------------------------------------------------------------------------
// Register a new event type at runtime (e.g. from a plugin or feature flag)
// without redeploying the handlers map above.
// -----------------------------------------------------------------------------
export function registerWebhookHandler(eventType, handlerFn) {
    if (typeof handlerFn !== 'function') {
        throw new TypeError('registerWebhookHandler: handlerFn must be a function')
    }
    handlers[eventType] = handlerFn
}

export default router
