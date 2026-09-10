import express from 'express'
import { rewardUser } from './piPayment.js'

const router = express.Router()

router.post('/claim', async (req, res) => {
  const { userUid, projectId } = req.body

  // Guard: cek sudah claim hari ini di DB
  const alreadyClaimed = await db.query(
    'SELECT 1 FROM claims WHERE uid=$1 AND claimed_at > NOW() - INTERVAL \'24h\'',
    [userUid]
  )
  if (alreadyClaimed.rows.length) {
    return res.status(429).json({ error: 'Already claimed today' })
  }

  try {
    const { paymentId, txid } = await rewardUser(userUid, 3.1415, 'ExplorePi daily claim', projectId)

    await db.query(
'INSERT INTO claims (user_uid, amount, payment_id, txid, claimed_at) VALUES ($1, 3.1415, $3, $4, NOW())',
      [userUid, projectId, paymentId, txid]
    )

    res.json({ success: true, txid })
  } catch (err) {
    res.status(500).json({ error: err.message })
  }
})

export default router
