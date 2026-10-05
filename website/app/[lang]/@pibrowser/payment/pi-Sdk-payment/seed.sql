-- =====================================================================
-- ExplorePi | @pibrowser/payment — seeded demo data
-- Safe to run repeatedly (idempotent via ON CONFLICT)
-- =====================================================================

SET search_path TO pibrowser_payment, public;

INSERT INTO claims (id, pi_uid, pi_username, wallet_address, amount_pi, memo, status, expires_at)
VALUES
  ('11111111-1111-4111-8111-111111111111', 'pi_uid_demo_001', 'tsuki_demo',
   'GDEMO1WALLETADDRESSSTELLARXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX', 5.0000000,
   'ExplorePi Pro subscription', 'claimed', now() + interval '15 minutes'),
  ('22222222-2222-4222-8222-222222222222', 'pi_uid_demo_002', 'alice_pi',
   'GDEMO2WALLETADDRESSSTELLARXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX', 1.5000000,
   'Tip: explorer contribution', 'open', now() + interval '15 minutes'),
  ('33333333-3333-4333-8333-333333333333', 'pi_uid_demo_003', 'bob_pi',
   'GDEMO3WALLETADDRESSSTELLARXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX', 10.0000000,
   'Node API premium tier', 'expired', now() - interval '5 minutes')
ON CONFLICT (id) DO NOTHING;

INSERT INTO payments (id, claim_id, pi_payment_id, pi_uid, pi_username, to_address,
                       amount_requested, amount_paid, tx_id, memo, status, lang)
VALUES
  ('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', '11111111-1111-4111-8111-111111111111',
   'pi_payment_demo_001', 'pi_uid_demo_001', 'tsuki_demo',
   'GDEMO1WALLETADDRESSSTELLARXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX',
   5.0000000, 5.0000000, NULL, 'ExplorePi Pro subscription',
   'completed', 'en'),
  ('bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb', '22222222-2222-4222-8222-222222222222',
   'pi_payment_demo_002', 'pi_uid_demo_002', 'alice_pi',
   'GDEMO2WALLETADDRESSSTELLARXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX',
   1.5000000, 0, NULL, 'Tip: explorer contribution', 'pending', 'id'),
  ('cccccccc-cccc-4ccc-8ccc-cccccccccccc', NULL,
   NULL, 'pi_uid_demo_004', 'charlie_pi',
   'GDEMO4WALLETADDRESSSTELLARXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX',
   2.2500000, 0, NULL, 'Direct payment, no prior claim', 'created', 'zh-CN')
ON CONFLICT (id) DO NOTHING;

INSERT INTO webhook_events (event_id, event_type, pi_payment_id, payload, processed, processed_at)
VALUES
  ('evt_demo_0001', 'payment.completed', 'pi_payment_demo_001',
   '{"identifier":"pi_payment_demo_001","status":{"developer_completed":true}}'::jsonb,
   TRUE, now())
ON CONFLICT (event_id) DO NOTHING;
